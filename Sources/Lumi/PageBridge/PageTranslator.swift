import Foundation
import Synchronization

/// One batch of paragraphs from a web page, as the extension sends it.
struct PageTranslationRequest: Decodable, Sendable {
    struct Segment: Decodable, Sendable {
        /// Opaque to Lumi; echoed back so the extension can put each
        /// translation under the paragraph it came from.
        let id: String
        let text: String
        /// Tail of the paragraph above this one on the page.
        let previous: String?
        /// Position among all translatable paragraphs on the page, 1-based.
        let index: Int?
    }

    /// A `WorkbenchEngineID` raw value: "online" or "offline".
    let engine: String
    let target: String
    let title: String?
    /// The reader's own background for this site — domain, glossary.
    let notes: String?
    /// How many translatable paragraphs the page has in total.
    let count: Int?
    let segments: [Segment]
}

struct PageTranslationResult: Encodable, Sendable {
    struct Item: Encodable, Sendable {
        let id: String
        var text: String?
        var error: String?
        /// Already in the target language — the extension leaves it alone.
        var skipped: Bool?
    }

    /// The name the extension shows, e.g. "DeepSeek" or "本机翻译".
    let engine: String
    let results: [Item]
}

/// Turns a page batch into workbench jobs.
///
/// A web page is a document, and Lumi already has a document translator: the
/// workbench engines take a title, the reader's notes and the preceding
/// paragraph, and every LLM provider turns those into a prompt that keeps
/// terms consistent and resolves "this" and "the latter". Reusing them is what
/// makes a page translated here read better than one translated a paragraph
/// at a time by a sentence-level API — and means a fix to the document prompt
/// improves both windows at once.
enum PageTranslator {
    /// Longer than any sane batch takes; a batch that hits it is reported per
    /// segment, and whatever finished before the deadline is still returned.
    static let deadline: Double = 90

    static func translate(_ request: PageTranslationRequest) async -> PageTranslationResult {
        guard let target = Language(rawValue: request.target), target != .auto else {
            return failAll(request, engine: "Lumi", message: tDetached("不支持的目标语言 %@", request.target))
        }
        let engineID = WorkbenchEngineID(rawValue: request.engine) ?? .online
        let provider = await MainActor.run { AppSettings.shared.workbenchOnlineProvider() }
        let engine: any WorkbenchEngine = switch engineID {
        case .online:  OnlineWorkbenchEngine(provider: provider)
        case .offline: OfflineWorkbenchEngine()
        }

        // Grouped by detected source language, not detected once per batch: a
        // page quoting French inside English prose is common, and the
        // on-device engine needs the true source to load the right model.
        // Paragraphs already in the target language are answered here — the
        // extension's own script test cannot tell French from English.
        var items = request.segments.map { PageTranslationResult.Item(id: $0.id) }
        var groups: [Language: [Int]] = [:]
        for (offset, segment) in request.segments.enumerated() {
            let source = Language.detect(segment.text)
            if Language.sameLanguage(source, target) {
                items[offset].skipped = true
            } else {
                groups[source, default: []].append(offset)
            }
        }

        for (source, offsets) in groups {
            let availability = await engine.availability(source: source, target: target)
            guard availability == .ready else {
                let why = availability.message ?? tDetached("%@ 不可用", engine.displayName)
                for offset in offsets { items[offset].error = why }
                continue
            }
            // Several short pieces go to a language model as one call; what
            // the batch reply leaves out falls through to one call each.
            var remaining = offsets
            if engineID == .online, let provider, offsets.count > 1 {
                let answered = await batch(
                    provider, offsets.map { request.segments[$0].text },
                    source: source, target: target,
                    title: request.title ?? "", notes: request.notes ?? ""
                )
                for (position, text) in answered { items[offsets[position]].text = text }
                remaining = offsets.enumerated().filter { answered[$0.offset] == nil }.map(\.element)
                if remaining.isEmpty { continue }
            }

            let jobs = remaining.map { offset in
                let segment = request.segments[offset]
                return WorkbenchJob(
                    index: offset,
                    text: segment.text,
                    context: DocumentContext(
                        title: request.title ?? "",
                        notes: request.notes ?? "",
                        index: segment.index ?? offset + 1,
                        count: max(request.count ?? request.segments.count, segment.index ?? 0),
                        previous: engine.usesDocumentContext ? segment.previous : nil
                    )
                )
            }
            let outcomes = await run(engine, jobs, source: source, target: target)
            for offset in remaining {
                switch outcomes[offset] {
                case .finished(_, let text)?:
                    items[offset].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                case .failed(_, let message)?:
                    items[offset].error = message
                case nil:
                    items[offset].error = tDetached("超时未返回")
                }
            }
        }
        return PageTranslationResult(engine: engine.displayName, results: items)
    }

    /// One call for several pieces, answered as `<<n>> translation` lines.
    /// Returns what could be matched back, by position in `texts`; anything
    /// missing, duplicated or out of range is simply not in the result.
    private static func batch(
        _ provider: any TranslationProvider, _ texts: [String],
        source: Language, target: Language, title: String, notes: String
    ) async -> [Int: String] {
        let body = texts.enumerated()
            .map { "\(Prompts.batchMarker($0.offset + 1)) \($0.element)" }
            .joined(separator: "\n")
        let request = TranslationRequest(
            text: body, source: source, target: target,
            instructions: Prompts.pageBatch(target: target, count: texts.count, title: title, notes: notes)
        )
        let output = try? await withTimeout(deadline) {
            var output = ""
            for try await event in provider.translate(request) {
                switch event {
                case .delta(let chunk):  output += chunk
                case .replace(let full): output = full
                case .dictionary:        break
                }
            }
            return output
        }
        return parseBatch(output ?? "", count: texts.count)
    }

    static func parseBatch(_ output: String, count: Int) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: /<<(\d+)>>\s*(.*)/),
                  let number = Int(match.1), (1...count).contains(number)
            else { continue }
            let text = String(match.2).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, result[number - 1] == nil { result[number - 1] = text }
        }
        return result
    }

    /// Collects events until the stream ends or the deadline passes. Results
    /// land in a shared box rather than being returned from the timed closure,
    /// so a deadline costs only the segments still outstanding.
    private static func run(
        _ engine: any WorkbenchEngine, _ jobs: [WorkbenchJob],
        source: Language, target: Language
    ) async -> [Int: WorkbenchEvent] {
        let collected = Collected()
        _ = try? await withTimeout(deadline) {
            for await event in engine.run(jobs, source: source, target: target) {
                collected.record(event)
            }
        }
        return collected.snapshot
    }

    private static func failAll(
        _ request: PageTranslationRequest, engine: String, message: String
    ) -> PageTranslationResult {
        PageTranslationResult(
            engine: engine,
            results: request.segments.map { .init(id: $0.id, error: message) }
        )
    }
}

private final class Collected: Sendable {
    private let events = Mutex<[Int: WorkbenchEvent]>([:])

    func record(_ event: WorkbenchEvent) {
        let index = switch event {
        case .finished(let index, _), .failed(let index, _): index
        }
        events.withLock { $0[index] = event }
    }

    var snapshot: [Int: WorkbenchEvent] { events.withLock { $0 } }
}

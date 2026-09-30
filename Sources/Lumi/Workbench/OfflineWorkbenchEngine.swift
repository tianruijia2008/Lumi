import Foundation
import Translation

/// The on-device engine: Apple's Translation framework, one segment at a time.
///
/// Chosen over a bundled NLLB-200 after measuring both on this machine against
/// real paper prose. NLLB-200 3.3B (3.2 GB, int8) rendered "annealed" and
/// "cosine" as `<unk>`, "covariance matrix" as 共变矩阵, German
/// "stochastisch" as 静态 and "Konvergenz" as 融合, and took 24s on a
/// paragraph the system translator did in 4.8s with every one of those terms
/// correct. A 200-language model buys breadth by giving up exactly the
/// precision a paper needs, and the reader cannot see it happening — a wrong
/// term arrives as fluent prose.
///
/// What this engine genuinely cannot do is read the document it is part of:
/// no title, no glossary, no previous paragraph. That is a property of
/// sentence-level MT, not a missing feature, and the UI says so.
struct OfflineWorkbenchEngine: WorkbenchEngine {
    let id = WorkbenchEngineID.offline
    let displayName = "本机翻译"
    let detail = "离线可用。逐句翻译，读不到上下文与术语表。"
    let requiresNetwork = false
    let usesDocumentContext = false

    /// How many segments go into one `translate(batch:)` call.
    ///
    /// The batch API is only ~1.1x faster than awaiting one at a time — the
    /// on-device model is already saturated — so this is not about throughput.
    /// It is about blast radius: a call that throws takes its whole batch down,
    /// and 16 is small enough that one poisoned segment costs 15 others a
    /// retry rather than costing the document.
    private static let chunkSize = 16

    func availability(source: Language, target: Language) async -> ProviderAvailability {
        guard let from = source.localeLanguage, let to = target.localeLanguage else {
            return .unavailable("语言未指定")
        }
        switch await LanguageAvailability().status(from: from, to: to) {
        case .installed:   return .ready
        case .supported:   return .needsSetup("需先在「系统设置 › 通用 › 语言与地区 › 翻译语言」下载语言包")
        case .unsupported: return .unavailable("系统翻译不支持 \(source.displayName) → \(target.displayName)")
        @unknown default:  return .unavailable("未知状态")
        }
    }

    func run(_ jobs: [WorkbenchJob], source: Language, target: Language)
        -> AsyncStream<WorkbenchEvent>
    {
        AsyncStream { continuation in
            // TranslationSession is not Sendable and its inference runs out of
            // process, so living on the main actor costs nothing and avoids
            // having to reason about it.
            let task = Task { @MainActor in
                guard let from = source.localeLanguage else {
                    for job in jobs {
                        continuation.yield(.failed(index: job.index, message: "不支持的语言"))
                    }
                    continuation.finish()
                    return
                }
                var session = TranslationSession(installedSource: from, target: target.localeLanguage)

                // A multi-line job goes a line at a time. Measured: handed a
                // Markdown table or list whole, the system translator puts a
                // blank line after every row and drops the indentation, which
                // turns a table into five paragraphs. Blank lines and table
                // rules are structure, not words, and are kept as they were.
                var lines: [Int: [String?]] = [:]
                var pieces: [(job: Int, line: Int, text: String)] = []
                var masks: [String: [String]] = [:]
                for job in jobs {
                    let parts = job.text.components(separatedBy: "\n")
                    var kept: [String?] = []
                    for (offset, part) in parts.enumerated() {
                        let bare = part.trimmingCharacters(in: .whitespaces)
                        if bare.isEmpty || Markdown.isTableDelimiter(part) {
                            kept.append(part)
                        } else {
                            kept.append(nil)
                            if job.context.markdown {
                                let (masked, spans) = Markdown.mask(part)
                                masks["\(job.index):\(offset)"] = spans
                                pieces.append((job.index, offset, masked))
                            } else {
                                pieces.append((job.index, offset, part))
                            }
                        }
                    }
                    lines[job.index] = kept
                }
                var finished = Set<Int>()
                func deliverIfComplete(_ index: Int) {
                    guard !finished.contains(index), let kept = lines[index],
                          kept.allSatisfy({ $0 != nil }) else { return }
                    finished.insert(index)
                    continuation.yield(.finished(index: index, text: kept.map { $0! }.joined(separator: "\n")))
                }
                // A job with nothing to translate is already whole.
                for job in jobs { deliverIfComplete(job.index) }

                for chunk in pieces.chunked(into: Self.chunkSize) {
                    if Task.isCancelled { break }
                    // Job and line ride along in clientIdentifier, so responses
                    // may come back in any order without being mismatched.
                    let requests = chunk.map {
                        TranslationSession.Request(
                            sourceText: $0.text, clientIdentifier: "\($0.job):\($0.line)"
                        )
                    }
                    do {
                        for try await response in session.translate(batch: requests) {
                            guard let id = response.clientIdentifier?.split(separator: ":"),
                                  id.count == 2, let index = Int(id[0]), let line = Int(id[1]),
                                  let original = chunk.first(where: { $0.job == index && $0.line == line })
                            else { continue }
                            // Indentation is layout; the translator drops it.
                            let indent = original.text.prefix { $0 == " " || $0 == "\t" }
                            var text = response.targetText
                            if let spans = masks["\(index):\(line)"] { text = Markdown.unmask(text, spans) }
                            lines[index]?[line] = indent + text
                            deliverIfComplete(index)
                        }
                    } catch {
                        // A thrown batch loses the pieces it had not yet
                        // answered. The session may be in a bad state, so the
                        // next chunk starts a fresh one.
                        Log.window.error("offline batch failed: \(error.localizedDescription, privacy: .public)")
                        session = TranslationSession(
                            installedSource: from, target: target.localeLanguage
                        )
                    }
                }
                for job in jobs where !finished.contains(job.index) {
                    continuation.yield(.failed(index: job.index, message: "本机翻译未返回结果"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

import Foundation
import SwiftUI

/// One long text, cut into aligned segments.
///
/// The panel's `AppState` models *a query* — one input, several services
/// racing, the winner shown. This models *a document*: many segments, each
/// with its own state, all belonging to one piece of work. They are different
/// enough that sharing a type would mean a type that is mostly `nil`.
///
/// Reading and proofreading are two uses of the same thing. A document read
/// here gets its translation from an engine; a document brought in for
/// proofreading arrives with someone else's. Either can then be reviewed —
/// which is why review state lives on the segment, beside the translation it
/// judges, rather than in a second model.
@MainActor
@Observable
final class WorkbenchDocument {
    enum SegmentStatus: Equatable {
        case pending
        case running
        case done
        /// The translator answered, and answered with something that lost part
        /// of the source. Kept distinct from `failed` because nobody reports it
        /// and nothing looks wrong — it is the silent dropped sentence this
        /// whole window exists to catch.
        case dropped(String)
        case failed(String)
    }

    enum ReviewState: Equatable {
        case none
        case running
        case done
        case failed(String)
    }

    struct Segment: Identifiable, Equatable {
        let id: Int
        var source: String
        var translation: String = ""
        var status: SegmentStatus = .pending
        var block: SegmentBlock = .paragraph
        var issues: [ProofIssue] = []
        /// How this translation rendered the segment's terms, as the reviewer
        /// read it. What the consistency pass compares across segments.
        var terms: [TermPair] = []
        var review: ReviewState = .none
        /// The reader changed the translation by hand or by accepting a
        /// suggestion.
        var edited = false

        var openIssues: [ProofIssue] { issues.filter { $0.state == .open } }
        /// Verbatim blocks are shown, never worked on.
        var isWork: Bool { !block.isVerbatim }
    }

    enum Activity: Equatable {
        case translating
        case reviewing
    }

    /// Which saved document this is. A new one on every fresh load; the
    /// saved one's when a document is reopened.
    private(set) var id = UUID()
    private var created = Date()
    private var fingerprint = ""
    /// Who translated it, as the start page names them.
    private(set) var engineLabel = ""
    /// Who reviewed it: "机检" or the model's name.
    private(set) var reviewerLabel = ""
    private(set) var format: TextFormat = .plain
    private(set) var purpose: DocumentPurpose = .read

    var title = "未命名"
    /// Domain, terminology and register, folded into every segment's prompt —
    /// but only by an engine that can read it. See `engine.usesDocumentContext`.
    /// Glossary lines in it ("attention = 注意力") are also checked by machine.
    var context = "" { didSet { if context != oldValue { touch() } } }
    private(set) var segments: [Segment] = []
    /// The segment at the top of the reader, so reopening the document lands
    /// where the reader left off instead of on its title.
    var readingPosition = 0 { didSet { if readingPosition != oldValue { touch() } } }
    /// A saved place the reader has not been scrolled back to yet. Until it
    /// is on screen, what is visible is the top of a list that has not moved,
    /// and recording it would overwrite the place being restored.
    private(set) var placeToRestore: Int?
    /// A segment something outside the reader — the sidebar — wants shown.
    private(set) var scrollRequest: Int?

    /// The reader is about to be rebuilt from the top — coming back from the
    /// start page — and should land where it was, not at the title.
    func resumeReading() {
        placeToRestore = readingPosition > 0 ? readingPosition : nil
    }

    func noteVisible(top: Int, all visible: [Int]) {
        if let place = placeToRestore {
            guard top == place else { return }
            placeToRestore = nil
        }
        readingPosition = top
    }

    /// Gives up on reaching the saved place exactly — a last paragraph can
    /// never scroll to the top — and lets scrolling record again.
    func finishRestoring() {
        placeToRestore = nil
    }

    func reveal(_ id: Int) {
        placeToRestore = nil
        scrollRequest = id
    }

    func clearScrollRequest() { scrollRequest = nil }

    /// Which engine translates. Persisted, because it is a standing preference
    /// about how the reader works, not a per-document choice.
    var engineID: WorkbenchEngineID {
        didSet {
            guard engineID != oldValue else { return }
            AppSettings.shared.workbenchEngine = engineID
        }
    }

    private(set) var activity: Activity?
    /// A proofreading pair is being paired by the model, before it loads.
    var aligning = false
    /// The whole-document terminology pass is out.
    private(set) var checkingTerms = false
    var isRunning: Bool { activity != nil }
    /// Set when the chosen engine cannot run at all — no key, no language pack,
    /// no network. Distinct from a segment failing.
    private(set) var engineProblem: String?
    private(set) var resolvedSource: Language = .english
    private(set) var resolvedTarget: Language = .simplifiedChinese

    private var runTask: Task<Void, Never>?

    init() {
        engineID = AppSettings.shared.workbenchEngine
    }

    var isLoaded: Bool { !segments.isEmpty }
    var isProof: Bool { purpose == .proof }

    /// Decides the document's direction once, from its own opening.
    ///
    /// Letting each segment detect its own language would flip direction on a
    /// segment that happens to be an equation or a citation block. A document
    /// brought in for proofreading already has both languages, and keeps them.
    private func resolveDirection() {
        guard purpose == .read else { return }
        let settings = AppSettings.shared
        resolvedSource = Language.detect(sample(\.source))
        resolvedTarget = Language.target(
            for: resolvedSource, first: settings.firstLanguage, second: settings.secondLanguage
        )
    }

    private func sample(_ side: KeyPath<Segment, String>) -> String {
        segments.lazy.filter(\.isWork).prefix(6).map { Markdown.visibleText($0[keyPath: side]) }
            .joined(separator: "\n")
    }

    /// The translation as one document, for the reader who wants to take it
    /// somewhere else. Markdown comes back as Markdown — headings, lists and
    /// code where they were. Segments with nothing in them are skipped rather
    /// than left as blank gaps, because the gap would be indistinguishable
    /// from a paragraph break in the result.
    var exportedTranslation: String {
        let parts: [(SegmentBlock, String)] = segments.compactMap { segment in
            let text = segment.block.isVerbatim
                ? (segment.translation.isEmpty ? segment.source : segment.translation)
                : segment.translation
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (segment.block, text)
        }
        switch format {
        case .markdown: return Markdown.join(parts)
        case .plain: return parts.map(\.1).joined(separator: "\n\n")
        }
    }

    /// Every open review note, as a Markdown list — for sending back to
    /// whoever made the translation.
    var reviewReport: String {
        var lines = ["# 校对意见：\(title)", ""]
        let flagged = segments.filter { !$0.openIssues.isEmpty }
        lines.append("共 \(workSegments.count) 段，\(openIssueCount) 处待改。")
        for segment in flagged {
            lines.append("")
            lines.append("## 第 \(segment.id + 1) 段")
            lines.append("")
            lines.append("> " + Markdown.plainText(segment.source).replacingOccurrences(of: "\n", with: " "))
            lines.append("")
            for issue in segment.openIssues {
                var line = "- **\(issue.kind.label)**"
                if !issue.quote.isEmpty {
                    line += " 「\(issue.quote)」"
                    if let suggestion = issue.suggestion { line += " → 「\(suggestion)」" }
                } else if let suggestion = issue.suggestion {
                    line += " 建议：「\(suggestion)」"
                }
                line += "：\(issue.note)"
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Segment ids that need a second look, in reading order — what the
    /// warning count in the header jumps between.
    var flaggedIDs: [Int] {
        segments.filter { segment in
            switch segment.status {
            case .dropped, .failed: return true
            default: break
            }
            if case .failed = segment.review { return true }
            return !segment.openIssues.isEmpty
        }.map(\.id)
    }

    var engine: any WorkbenchEngine {
        switch engineID {
        case .offline: OfflineWorkbenchEngine()
        case .online:
            // Passes nil straight through when nothing is configured; the
            // engine's own `availability` is what tells the reader why.
            OnlineWorkbenchEngine(provider: AppSettings.shared.workbenchOnlineProvider())
        }
    }

    // MARK: - Progress

    var workSegments: [Segment] { segments.filter(\.isWork) }

    var doneCount: Int {
        workSegments.count { if case .pending = $0.status { false } else if case .running = $0.status { false } else { true } }
    }
    var droppedCount: Int {
        workSegments.count { if case .dropped = $0.status { true } else { false } }
    }
    var failedCount: Int {
        workSegments.count { if case .failed = $0.status { true } else { false } }
    }
    var reviewedCount: Int { workSegments.count { $0.review == .done } }
    var reviewFailedCount: Int {
        workSegments.count { if case .failed = $0.review { true } else { false } }
    }
    var openIssueCount: Int { segments.reduce(0) { $0 + $1.openIssues.count } }
    var hasReview: Bool { segments.contains { $0.review != .none } }

    /// Translation progress for a read document, review progress for one
    /// brought in to be proofread — each is the work that document is for.
    var progress: Double {
        let total = workSegments.count
        guard total > 0 else { return 0 }
        if isProof || activity == .reviewing {
            return Double(workSegments.count { $0.review != .none && $0.review != .running }) / Double(total)
        }
        return Double(doneCount) / Double(total)
    }

    var headings: [(id: Int, level: Int, title: String)] {
        segments.compactMap { segment in
            guard case .heading(let level) = segment.block else { return nil }
            return (segment.id, level, Markdown.plainText(segment.source))
        }
    }

    // MARK: - Loading

    /// Loads a text to read. A text read before comes back as it was left —
    /// translations, flags, place — rather than as a fresh, unpaid-for copy.
    func load(_ text: String, fallbackTitle: String? = nil, format hint: TextFormat? = nil) {
        let print = DocumentStore.fingerprint(of: text)
        if let saved = DocumentStore.shared.existing(fingerprint: print) {
            restore(saved)
            return
        }
        cancel()
        let (format, blocks) = DocumentParser.parse(text, format: hint)
        begin(fingerprint: print, format: format, purpose: .read)
        segments = blocks.enumerated().map { offset, block in
            var segment = Segment(id: offset, source: block.text, block: block.kind)
            if block.kind.isVerbatim {
                segment.translation = block.text
                segment.status = .done
            }
            return segment
        }
        self.title = DocumentParser.title(of: blocks, raw: text) ?? fallbackTitle ?? "未命名"
        // Resolved here and not only in `run`, because the header shows the
        // direction: a chip reading 英文 → 中文 over a German paper, right up
        // until the moment you press 翻译, is worse than no chip at all.
        resolveDirection()
        touch()
    }

    /// Loads a source and a translation made elsewhere, paired paragraph to
    /// paragraph, ready to be reviewed.
    /// A proofreading pair, cut and paired, not yet on screen.
    struct ProofDraft {
        let fingerprint: String
        let format: TextFormat
        let source: [TextBlock]
        let target: [TextBlock]
        let from: Language
        let to: Language
        let rawSource: String
        /// Set when the model paired the paragraphs.
        var pairs: [Aligner.Pair]?
    }

    static func prepareProof(source: String, translation: String, format hint: TextFormat?) -> ProofDraft {
        let format = hint ?? (Markdown.looksLikeMarkdown(source) || Markdown.looksLikeMarkdown(translation)
                              ? .markdown : .plain)
        let (_, sourceBlocks) = DocumentParser.parse(source, format: format)
        let (_, targetBlocks) = DocumentParser.parse(translation, format: format)
        return ProofDraft(
            fingerprint: DocumentStore.fingerprint(of: source + "\n\u{1}\n" + translation),
            format: format, source: sourceBlocks, target: targetBlocks,
            from: Language.detect(sourceBlocks.prefix(8).map { Markdown.visibleText($0.text) }.joined(separator: "\n")),
            to: Language.detect(targetBlocks.prefix(8).map { Markdown.visibleText($0.text) }.joined(separator: "\n")),
            rawSource: source
        )
    }

    func loadProof(source: String, translation: String, fallbackTitle: String? = nil,
                   format hint: TextFormat? = nil) {
        loadProof(Self.prepareProof(source: source, translation: translation, format: hint),
                  fallbackTitle: fallbackTitle)
    }

    func loadProof(_ draft: ProofDraft, fallbackTitle: String? = nil) {
        if let saved = DocumentStore.shared.existing(fingerprint: draft.fingerprint) {
            restore(saved)
            return
        }
        cancel()
        let format = draft.format, sourceBlocks = draft.source, targetBlocks = draft.target
        let source = draft.rawSource
        begin(fingerprint: draft.fingerprint, format: format, purpose: .proof)
        resolvedSource = draft.from
        resolvedTarget = draft.to

        let pairs = draft.pairs ?? Aligner.align(source: sourceBlocks, target: targetBlocks,
                                                 ratio: Aligner.ratio(from: resolvedSource, to: resolvedTarget))
        segments = pairs.enumerated().map { offset, pair in
            let kind = pair.source.first.map { sourceBlocks[$0].kind }
                ?? targetBlocks[pair.target[0]].kind
            let src = pair.source.map { sourceBlocks[$0].text }.joined(separator: "\n\n")
            var out = pair.target.map { targetBlocks[$0].text }.joined(separator: "\n\n")
            if kind.isVerbatim, out.isEmpty { out = src }
            return Segment(id: offset, source: src, translation: out, status: .done, block: kind)
        }
        engineLabel = "外来译文"
        self.title = DocumentParser.title(of: sourceBlocks, raw: source) ?? fallbackTitle ?? "未命名"
        Log.window.info("""
            proof loaded: source=\(sourceBlocks.count, privacy: .public) \
            target=\(targetBlocks.count, privacy: .public) \
            pairs=\(pairs.count, privacy: .public) format=\(format.rawValue, privacy: .public) \
            by=\(draft.pairs == nil ? "length" : "model", privacy: .public)
            """)
        touch()
    }

    private func begin(fingerprint: String, format: TextFormat, purpose: DocumentPurpose) {
        id = UUID()
        created = Date()
        self.fingerprint = fingerprint
        self.format = format
        self.purpose = purpose
        engineLabel = ""
        reviewerLabel = ""
        context = ""
        readingPosition = 0
        placeToRestore = nil
        scrollRequest = nil
        engineProblem = nil
    }

    /// Puts a saved document back on screen exactly as it was kept.
    func restore(_ saved: SavedDocument) {
        cancel()
        id = saved.id
        created = saved.created
        fingerprint = saved.fingerprint
        engineLabel = saved.engineLabel
        reviewerLabel = saved.reviewerLabel ?? ""
        format = saved.format ?? .plain
        purpose = saved.purpose ?? .read
        title = saved.title
        segments = saved.segments.enumerated().map { offset, kept in
            let status: SegmentStatus = switch kept.kind {
            case .pending: .pending
            case .done: .done
            case .dropped: .dropped(kept.note ?? "")
            case .failed: .failed(kept.note ?? "")
            }
            let review: ReviewState = if let note = kept.reviewNote { .failed(note) }
                else if kept.reviewed == true { .done } else { .none }
            return Segment(id: offset, source: kept.source, translation: kept.translation,
                           status: status, block: kept.block ?? .paragraph,
                           issues: kept.issues ?? [], terms: kept.terms ?? [],
                           review: review, edited: kept.edited ?? false)
        }
        context = saved.context
        readingPosition = min(saved.readingPosition, max(segments.count - 1, 0))
        placeToRestore = readingPosition > 0 ? readingPosition : nil
        scrollRequest = nil
        resolvedSource = saved.source
        resolvedTarget = saved.target
        engineProblem = nil
        // Opening counts as reading: it moves the document to the top of the
        // recents list.
        touch()
    }

    func reset() {
        cancel()
        segments = []
        title = "未命名"
        engineProblem = nil
    }

    // MARK: - Keeping

    /// Hands the current state to the store. Cheap to call often: the store
    /// debounces the write.
    private func touch() {
        guard isLoaded else { return }
        DocumentStore.shared.scheduleSave(snapshot)
    }

    private var snapshot: SavedDocument {
        SavedDocument(
            id: id, title: title, context: context, engine: engineID,
            engineLabel: engineLabel,
            source: resolvedSource, target: resolvedTarget,
            segments: segments.map { segment in
                var kept: SavedSegment = switch segment.status {
                // A segment still in flight is kept as untranslated: if the
                // app quits now, nothing will ever finish it.
                case .pending, .running:
                    SavedSegment(source: segment.source, translation: "", kind: .pending)
                case .done:
                    SavedSegment(source: segment.source, translation: segment.translation, kind: .done)
                case .dropped(let why):
                    SavedSegment(source: segment.source, translation: segment.translation, kind: .dropped, note: why)
                case .failed(let why):
                    SavedSegment(source: segment.source, translation: segment.translation, kind: .failed, note: why)
                }
                if segment.block != .paragraph { kept.block = segment.block }
                if !segment.issues.isEmpty { kept.issues = segment.issues }
                if !segment.terms.isEmpty { kept.terms = segment.terms }
                if segment.edited { kept.edited = true }
                switch segment.review {
                case .done: kept.reviewed = true
                case .failed(let why): kept.reviewNote = why
                case .none, .running: break
                }
                return kept
            },
            readingPosition: readingPosition,
            created: created, modified: Date(),
            fingerprint: fingerprint,
            format: format, purpose: purpose, reviewerLabel: reviewerLabel
        )
    }

    // MARK: - Translating

    func translateAll() {
        guard !segments.isEmpty else { return }
        run(indices: workSegments.map(\.id))
    }

    /// Re-runs the segments that have nothing usable — after a network came
    /// back, or after the reader filled in a key.
    func retryUnfinished() {
        let ids = workSegments.filter {
            switch $0.status {
            case .done, .dropped: false
            default: true
            }
        }.map(\.id)
        run(indices: ids)
    }

    func retry(_ id: Int) { run(indices: [id]) }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        activity = nil
        checkingTerms = false
        for index in segments.indices {
            if segments[index].status == .running { segments[index].status = .pending }
            if segments[index].review == .running { segments[index].review = .none }
        }
        touch()
    }

    private func run(indices ids: [Int]) {
        guard !ids.isEmpty else { return }
        runTask?.cancel()

        resolveDirection()
        let source = resolvedSource
        let target = resolvedTarget

        let engine = self.engine
        let wanted = Set(ids)
        var jobs: [WorkbenchJob] = []
        for (offset, segment) in segments.enumerated() where wanted.contains(segment.id) && segment.isWork {
            jobs.append(WorkbenchJob(
                index: segment.id,
                text: segment.source,
                context: documentContext(at: offset, reading: engine.usesDocumentContext)
            ))
        }
        guard !jobs.isEmpty else { return }
        let running = Set(jobs.map(\.index))

        for index in segments.indices where running.contains(segments[index].id) {
            segments[index].status = .running
            segments[index].translation = ""
            // A new translation voids every judgement made about the old one.
            segments[index].issues = []
            segments[index].terms = []
            segments[index].review = .none
            segments[index].edited = false
        }
        activity = .translating
        engineProblem = nil
        engineLabel = switch engineID {
        case .offline: "本机"
        case .online: AppSettings.shared.workbenchOnlineProvider()?.displayName ?? "联网"
        }

        runTask = Task { [weak self] in
            switch await engine.availability(source: source, target: target) {
            case .ready:
                break
            case .needsSetup(let message), .unavailable(let message), .notApplicable(let message):
                guard let self else { return }
                self.engineProblem = message
                for index in self.segments.indices where running.contains(self.segments[index].id) {
                    self.segments[index].status = .pending
                }
                self.activity = nil
                return
            }

            var answered = 0
            for await event in engine.run(jobs, source: source, target: target) {
                guard let self else { return }
                if Task.isCancelled { break }
                answered += 1
                switch event {
                case .finished(let index, let text):
                    self.deliver(index: index, text: text)
                case .failed(let index, let message):
                    self.apply(index: index) { $0.status = .failed(message) }
                }
            }
            guard let self else { return }
            // A document the reader stopped on purpose is not an engine that
            // failed: `cancel` has already put its segments back to 待翻译, and
            // the rescue below would relabel every one of them as a failure.
            if Task.isCancelled { return }

            // Every requested segment must end in a state the reader can see.
            //
            // Not a belt-and-braces guard: measured, a slow provider ended its
            // stream after 7 events for 18 jobs and left 11 segments sitting at
            // 待翻译 with no spinner and no error — indistinguishable from a
            // document nobody had asked to translate yet. Whatever causes an
            // engine to under-deliver, it must not be able to do it quietly.
            if answered < jobs.count {
                Log.window.error("""
                    engine under-delivered: jobs=\(jobs.count, privacy: .public) \
                    events=\(answered, privacy: .public)
                    """)
            }
            for index in self.segments.indices where running.contains(self.segments[index].id) {
                switch self.segments[index].status {
                case .running, .pending:
                    self.segments[index].status = .failed("引擎没有返回这一段，可点重试")
                default:
                    break
                }
            }
            self.activity = nil
            self.touch()
            Log.window.info("""
                translate finished: jobs=\(jobs.count, privacy: .public) \
                events=\(answered, privacy: .public) \
                done=\(self.doneCount, privacy: .public) \
                dropped=\(self.droppedCount, privacy: .public) \
                failed=\(self.failedCount, privacy: .public)
                """)
        }
    }

    private func documentContext(at offset: Int, reading: Bool) -> DocumentContext {
        // The tail of the previous segment, not the whole thing: it is there
        // to resolve a pronoun, and paying for a full extra paragraph of input
        // on every segment would roughly double the bill.
        let previous = segments[..<offset].last(where: \.isWork).map { String($0.source.suffix(320)) }
        return DocumentContext(
            title: title, notes: context,
            index: offset + 1, count: segments.count,
            previous: reading ? previous : nil,
            hint: segments[offset].block.promptHint,
            markdown: format == .markdown
        )
    }

    /// Records a translation and judges whether it actually translated the
    /// segment.
    private func deliver(index: Int, text: String) {
        let markdown = format == .markdown
        apply(index: index) { segment in
            let clean = segment.block.strippingEchoedSyntax(
                text.trimmingCharacters(in: .whitespacesAndNewlines), source: segment.source)
            segment.translation = clean
            guard !clean.isEmpty else {
                segment.status = .dropped("整段没有译文")
                return
            }
            let source = markdown ? Markdown.visibleText(segment.source) : segment.source
            let out = markdown ? Markdown.visibleText(clean) : clean
            let missing = DropCheck.missingTokens(source: source, translation: out)
            if !missing.isEmpty {
                // Numbers and acronyms are reproduced verbatim by any usable
                // translation, so a missing one is a missing claim.
                segment.status = .dropped("原文里的 \(missing.prefix(3).joined(separator: "、")) 没出现在译文里")
                return
            }
            // 0.45 against a worst observed good case of 0.20 (English →
            // Chinese) and 0.17 (Chinese → English) — better than twice the
            // margin, because a false "漏译" on a correct paragraph costs the
            // reader more than a missed one: it teaches them to ignore the flag.
            if let short = DropCheck.shortfall(
                source: source, translation: out,
                from: resolvedSource, to: resolvedTarget
            ), short > 0.45 {
                segment.status = .dropped("译文比预期短 \(Int(short * 100))%，可能有整句没译")
                return
            }
            segment.status = .done
        }
    }

    private func apply(index: Int, _ mutate: (inout Segment) -> Void) {
        guard let position = segments.firstIndex(where: { $0.id == index }) else { return }
        mutate(&segments[position])
        touch()
    }

    // MARK: - Reviewing

    /// Whether the chosen engine can read meaning, or only run the machine
    /// checks.
    var reviewsWithModel: Bool {
        engineID == .online && AppSettings.shared.workbenchOnlineProvider() != nil
    }

    /// Checks translations against their sources.
    ///
    /// The machine checks run first and land at once — they need nothing and
    /// are never wrong about what they say. Then, when a language model is
    /// chosen, each segment is read by it, and finally every segment's terms
    /// are laid side by side for the one problem no single segment can show.
    func review(_ ids: [Int]? = nil) {
        runTask?.cancel()
        checkingTerms = false
        let wanted = ids.map(Set.init)
        let targets = segments.indices.filter { index in
            let segment = segments[index]
            guard segment.isWork, wanted?.contains(segment.id) ?? true else { return false }
            // A read document's untranslated segments have nothing to judge.
            if purpose == .read {
                switch segment.status {
                case .done, .dropped: return !segment.translation.isEmpty
                default: return false
                }
            }
            return true
        }
        guard !targets.isEmpty else { return }

        let glossary = ProofCheck.glossary(from: context)
        let source = resolvedSource, target = resolvedTarget
        for index in targets {
            var segment = segments[index]
            // Judgements the reader already acted on stay: an accepted one
            // can still be undone, a dismissed one must not come back.
            segment.issues.removeAll { $0.state == .open }
            let skipDrop: Bool = switch segment.status {
            case .dropped, .failed: true
            default: false
            }
            let machine = ProofCheck.machine(
                source: segment.source, translation: segment.translation, block: segment.block,
                format: format, glossary: glossary, from: source, to: target, skipDropChecks: skipDrop
            )
            segment.issues += machine.filter { issue in !segment.issues.contains { Self.same($0, issue) } }
            segments[index] = segment
        }

        guard engineID == .online, let provider = AppSettings.shared.workbenchOnlineProvider() else {
            for index in targets { segments[index].review = .done }
            reviewerLabel = "机检"
            if engineID == .online {
                engineProblem = "逐句审读要用语言模型。在设置里开启一个（如 DeepSeek）并填好 Key；现在只做了机检。"
            }
            refreshConsistency()
            touch()
            return
        }

        engineProblem = nil
        reviewerLabel = provider.displayName
        var jobs: [ReviewJob] = []
        for index in targets {
            let segment = segments[index]
            // Nothing for a model to read on one side: the machine check has
            // already said all there is to say.
            if segment.source.isEmpty || segment.translation.isEmpty {
                segments[index].review = .done
                continue
            }
            segments[index].review = .running
            jobs.append(ReviewJob(
                index: segment.id, source: segment.source, translation: segment.translation,
                block: segment.block, context: documentContext(at: index, reading: true)
            ))
        }
        guard !jobs.isEmpty else {
            refreshConsistency()
            touch()
            return
        }
        activity = .reviewing
        let running = Set(jobs.map(\.index))
        let markdown = format == .markdown

        runTask = Task { [weak self] in
            let online = await MainActor.run { NetworkMonitor.shared.isOnline }
            if provider.requiresNetwork, !online {
                guard let self else { return }
                self.engineProblem = "当前离线，只做了机检。联网后再点校对。"
                for index in self.segments.indices where running.contains(self.segments[index].id) {
                    self.segments[index].review = .done
                }
                self.activity = nil
                self.touch()
                return
            }
            let reviewer = ModelReviewer(provider: provider)
            let clock = ContinuousClock.now
            for await event in reviewer.run(jobs, source: source, target: target, markdown: markdown) {
                guard let self else { return }
                if Task.isCancelled { break }
                switch event {
                case .finished(let index, let issues, let terms):
                    self.apply(index: index) { segment in
                        for issue in issues where !segment.issues.contains(where: { Self.same($0, issue) }) {
                            segment.issues.append(issue)
                        }
                        // A machine note the model has restated — with the
                        // place and the fix — is the same note, less useful.
                        let restated = issues.map { $0.sourceQuote + " " + ($0.suggestion ?? "") + " " + $0.note }
                        segment.issues.removeAll { kept in
                            kept.origin == .machine && kept.state == .open && !kept.sourceQuote.isEmpty
                                && restated.contains { $0.contains(kept.sourceQuote) }
                        }
                        segment.terms = terms
                        segment.review = .done
                    }
                case .failed(let index, let message):
                    self.apply(index: index) { $0.review = .failed(message) }
                }
            }
            guard let self, !Task.isCancelled else { return }
            for index in self.segments.indices
            where running.contains(self.segments[index].id) && self.segments[index].review == .running {
                self.segments[index].review = .failed("模型没有返回这一段，可点重试")
            }
            let segmentsTook = ContinuousClock.now - clock
            self.refreshConsistency()
            self.activity = nil
            self.touch()
            // The whole-document terminology pass, only after a whole-document
            // review — one segment re-read is not a reason to re-judge all.
            // After the review is marked done, not before it: its notes are a
            // bonus, and waiting on them made a finished review look stuck.
            if ids == nil {
                let terms = self.segments.filter { $0.isWork && !$0.terms.isEmpty }.map { ($0.id, $0.terms) }
                if TermConsistency.candidates(terms).count >= 2 {
                    self.checkingTerms = true
                    let fixes = await reviewer.consistency(terms, source: source, target: target, notes: self.context)
                    self.checkingTerms = false
                    guard !Task.isCancelled else { return }
                    self.addDocumentFindings(fixes)
                    self.touch()
                }
            }
            Log.window.info("review timing: segments=\(segmentsTook.description, privacy: .public) total=\((ContinuousClock.now - clock).description, privacy: .public)")
            Log.window.info("""
                review finished: jobs=\(jobs.count, privacy: .public) \
                issues=\(self.openIssueCount, privacy: .public) \
                failed=\(self.reviewFailedCount, privacy: .public)
                """)
        }
    }

    private func addDocumentFindings(_ fixes: [(segment: Int, issue: ProofIssue)]) {
        for (segmentID, issue) in fixes {
            guard let index = segments.firstIndex(where: { $0.id == segmentID }),
                  segments[index].translation.contains(issue.quote),
                  !segments[index].issues.contains(where: { $0.quote == issue.quote && $0.kind == .terminology })
            else { continue }
            segments[index].issues.append(issue)
        }
    }

    /// Two notes about the same thing: same kind, same place, or same words.
    private static func same(_ a: ProofIssue, _ b: ProofIssue) -> Bool {
        guard a.kind == b.kind else { return a.note == b.note }
        if !a.quote.isEmpty || !b.quote.isEmpty { return a.quote == b.quote }
        return a.note == b.note || (!a.sourceQuote.isEmpty && a.sourceQuote == b.sourceQuote)
    }

    /// Re-derives the cross-segment terminology notes from every segment's
    /// terms. Cheap, so it runs after anything that changes a translation.
    private func refreshConsistency() {
        let glossary = ProofCheck.glossary(from: context)
        let findings = TermConsistency.findings(
            terms: segments.filter(\.isWork).map { ($0.id, $0.terms, $0.translation) },
            glossary: glossary
        )
        for index in segments.indices {
            segments[index].issues.removeAll { $0.origin == .consistency && $0.state == .open }
        }
        for finding in findings {
            guard let index = segments.firstIndex(where: { $0.id == finding.segment }) else { continue }
            let places = finding.elsewhere.prefix(4).map { "第 \($0 + 1) 段" }.joined(separator: "、")
            let issue = ProofIssue(
                kind: .terminology, origin: .consistency, quote: finding.used,
                sourceQuote: finding.term, suggestion: finding.preferred,
                note: places.isEmpty
                    ? "术语表要求把 \(finding.term) 译作「\(finding.preferred)」"
                    : "\(finding.term) 在\(places)译作「\(finding.preferred)」，这里是「\(finding.used)」"
            )
            if segments[index].issues.contains(where: { Self.same($0, issue) }) { continue }
            segments[index].issues.append(issue)
        }
    }

    // MARK: - Repairing the pairing

    /// The translation has no paragraph for this source paragraph: leave
    /// this row's translation empty and move it, and everything after it,
    /// down one row.
    func insertGap(at segmentID: Int) {
        guard let start = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        cancel()
        let tail = segments[start...].map(\.translation)
        let shifted = [""] + tail.dropLast()
        for (offset, index) in segments.indices[start...].enumerated() {
            segments[index].translation = shifted[offset]
        }
        // The last translation needs a row of its own: one with no source.
        if let spill = tail.last, !spill.isEmpty {
            segments.append(Segment(id: segments.count, source: "", translation: spill, status: .done))
        }
        realigned(from: start)
    }

    /// The translator split this paragraph in two: join the next row's
    /// translation onto this one and move everything after it up a row.
    func pullNext(into segmentID: Int) {
        guard let start = segments.firstIndex(where: { $0.id == segmentID }),
              start + 1 < segments.count else { return }
        cancel()
        let joined = [segments[start].translation, segments[start + 1].translation]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        segments[start].translation = joined
        for index in (start + 1)..<segments.count {
            segments[index].translation = index + 1 < segments.count ? segments[index + 1].translation : ""
        }
        // A trailing row with nothing on either side is gone, not empty.
        while let last = segments.last, last.source.isEmpty, last.translation.isEmpty { segments.removeLast() }
        realigned(from: start)
    }

    /// Every row from `start` on now holds a different translation: what
    /// was said about the old one no longer applies.
    private func realigned(from start: Int) {
        segments = segments.enumerated().map { offset, segment in
            var fresh = Segment(id: offset, source: segment.source, translation: segment.translation,
                                status: .done, block: segment.block)
            if offset < start {
                fresh.issues = segment.issues
                fresh.terms = segment.terms
                fresh.review = segment.review
                fresh.edited = segment.edited
            }
            return fresh
        }
        let glossary = ProofCheck.glossary(from: context)
        for index in start..<segments.count where segments[index].isWork {
            segments[index].issues = ProofCheck.machine(
                source: segments[index].source, translation: segments[index].translation,
                block: segments[index].block, format: format, glossary: glossary,
                from: resolvedSource, to: resolvedTarget
            )
        }
        refreshConsistency()
        touch()
    }

    // MARK: - Acting on review notes

    func accept(_ issueID: UUID, in segmentID: Int) {
        apply(index: segmentID) { segment in
            guard let k = segment.issues.firstIndex(where: { $0.id == issueID }),
                  let suggestion = segment.issues[k].suggestion,
                  !segment.issues[k].quote.isEmpty,
                  let range = segment.translation.range(of: segment.issues[k].quote) else { return }
            let old = segment.issues[k].quote
            segment.translation.replaceSubrange(range, with: suggestion)
            segment.issues[k].state = .accepted
            segment.issues[k].replaced = old
            segment.edited = true
            // Other notes quoting a span that contained the words just
            // replaced still point at the same place — move them with it.
            for j in segment.issues.indices where j != k && segment.issues[j].state == .open {
                let quote = segment.issues[j].quote
                if !quote.isEmpty, quote.contains(old), !segment.translation.contains(quote) {
                    segment.issues[j].quote = quote.replacingOccurrences(of: old, with: suggestion)
                    if segment.issues[j].suggestion == segment.issues[j].quote { segment.issues[j].suggestion = nil }
                }
            }
        }
        afterEdit(segmentID, dropVanished: false)
    }

    func undoAccept(_ issueID: UUID, in segmentID: Int) {
        apply(index: segmentID) { segment in
            guard let k = segment.issues.firstIndex(where: { $0.id == issueID }),
                  let replaced = segment.issues[k].replaced,
                  let suggestion = segment.issues[k].suggestion,
                  let range = segment.translation.range(of: suggestion) else { return }
            segment.translation.replaceSubrange(range, with: replaced)
            segment.issues[k].state = .open
            segment.issues[k].replaced = nil
        }
        afterEdit(segmentID, dropVanished: false)
    }

    func dismiss(_ issueID: UUID, in segmentID: Int) {
        apply(index: segmentID) { segment in
            guard let k = segment.issues.firstIndex(where: { $0.id == issueID }) else { return }
            segment.issues[k].state = .dismissed
        }
    }

    func restoreDismissed(in segmentID: Int) {
        apply(index: segmentID) { segment in
            for k in segment.issues.indices where segment.issues[k].state == .dismissed {
                segment.issues[k].state = .open
            }
        }
    }

    /// The reader's own wording replaces the translation.
    func edit(_ segmentID: Int, to text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        apply(index: segmentID) { segment in
            guard clean != segment.translation else { return }
            segment.translation = clean
            segment.edited = true
            // The reader has looked at it and written what they meant; the
            // engine's doubts about its own output no longer apply.
            if case .dropped = segment.status { segment.status = .done }
            if case .failed = segment.status, !clean.isEmpty { segment.status = .done }
            if case .pending = segment.status, !clean.isEmpty { segment.status = .done }
        }
        afterEdit(segmentID)
    }

    /// Notes that pointed at text which is no longer there have been dealt
    /// with; the machine checks are simply run again.
    private func afterEdit(_ segmentID: Int, dropVanished: Bool = true) {
        let glossary = ProofCheck.glossary(from: context)
        let format = self.format, source = resolvedSource, target = resolvedTarget
        apply(index: segmentID) { segment in
            let text = segment.translation
            segment.issues.removeAll { issue in
                issue.state == .open && (issue.origin == .machine
                    || (dropVanished && !issue.quote.isEmpty && !text.contains(issue.quote)))
            }
            // Terms the reviewer read are stale where they no longer appear.
            segment.terms.removeAll { !text.contains($0.target) }
            guard segment.review != .none else { return }
            let machine = ProofCheck.machine(
                source: segment.source, translation: text, block: segment.block,
                format: format, glossary: glossary, from: source, to: target
            )
            segment.issues += machine.filter { issue in !segment.issues.contains { Self.same($0, issue) } }
        }
        if hasReview { refreshConsistency() }
        touch()
    }
}

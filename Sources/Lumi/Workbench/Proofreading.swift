import Foundation

// MARK: - What a reviewer says

/// One thing wrong with one segment's translation.
///
/// Anchored to a quoted span of the translation rather than to offsets:
/// offsets die the moment the reader edits the text, a quote survives
/// anything that does not touch it — and when it stops matching, that is
/// exactly the signal that the problem was fixed.
struct ProofIssue: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case omission, addition, mistranslation, terminology, number, grammar, style, format

        var label: String {
            switch self {
            case .omission: "漏译"
            case .addition: "增译"
            case .mistranslation: "错译"
            case .terminology: "术语"
            case .number: "数字"
            case .grammar: "语病"
            case .style: "措辞"
            case .format: "格式"
            }
        }

        /// Meaning changed, versus something missing, versus polish. Three
        /// weights and no more: a colour per kind would be a legend nobody
        /// reads.
        var severity: Severity {
            switch self {
            case .mistranslation, .number: .serious
            case .omission, .addition, .terminology: .warning
            case .grammar, .style, .format: .minor
            }
        }
    }

    enum Severity: Int, Comparable, Sendable {
        case minor, warning, serious
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    /// Who raised it. Machine checks are certain about less and wrong about
    /// less; the model reads meaning and can be mistaken. The reader deserves
    /// to know which is which.
    enum Origin: String, Codable, Sendable {
        case machine
        case model
        /// Found by comparing segments' terms with each other, by machine.
        case consistency
        /// Found by the model reading every segment's terms side by side.
        case document

        var label: String? {
            switch self {
            case .machine: "机检"
            case .consistency, .document: "全文比对"
            case .model: nil
            }
        }
    }

    enum State: String, Codable, Sendable {
        case open, accepted, dismissed
    }

    var id = UUID()
    var kind: Kind
    var origin: Origin
    /// Exact text in the translation. Empty when the problem has no one
    /// place — a number that is missing is missing everywhere.
    var quote: String
    /// The corresponding text in the source, when the reviewer named it.
    var sourceQuote: String = ""
    /// What `quote` should read instead. Nil when the check can only say
    /// something is wrong, not what is right.
    var suggestion: String?
    var note: String
    var state: State = .open
    /// The text the suggestion replaced, so accepting can be undone.
    var replaced: String?

    var canApply: Bool { suggestion != nil && !quote.isEmpty }
}

/// How the translation renders one source term.
struct TermPair: Codable, Hashable, Sendable {
    var source: String
    var target: String
}

// MARK: - Checks that need no model

/// What can be checked without understanding a word.
///
/// Every check here is a certainty, not an opinion: a number is present or
/// it is not; a code span came through or it did not. That is what earns
/// them a place alongside a model that reads meaning — they never cry wolf,
/// and they run offline, instantly, for free.
enum ProofCheck {
    static func machine(
        source: String, translation: String, block: SegmentBlock, format: TextFormat,
        glossary: [TermPair], from: Language, to: Language, skipDropChecks: Bool = false
    ) -> [ProofIssue] {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if block.isVerbatim { return [] }
        if src.isEmpty, !out.isEmpty {
            return [ProofIssue(kind: .addition, origin: .machine, quote: "",
                               note: "原文里没有对应的段落，译文多出了这一段")]
        }
        if out.isEmpty {
            guard !src.isEmpty else { return [] }
            return [ProofIssue(kind: .omission, origin: .machine, quote: "",
                               note: "这一段在译文里找不到对应")]
        }

        var issues: [ProofIssue] = []
        let visibleSource = format == .markdown ? Markdown.visibleText(src) : src
        let visibleOut = format == .markdown ? Markdown.visibleText(out) : out

        // Same text on both sides, in a pair that changes script: nobody
        // translated it.
        let stillSource = to.isHanScript ? !to.appears(in: visibleOut)
                                         : hanShare(visibleOut) > 0.5
        if from.isHanScript != to.isHanScript, visibleSource.count >= 12,
           stillSource || normalised(visibleSource) == normalised(visibleOut) {
            issues.append(ProofIssue(kind: .omission, origin: .machine, quote: "",
                                     note: "这一段看起来没有翻译，仍是\(from.displayName)"))
            return issues
        }

        if !skipDropChecks, block != .table {
            let missing = DropCheck.missingTokens(source: visibleSource, translation: visibleOut)
            if !missing.isEmpty {
                issues.append(ProofIssue(
                    kind: .number, origin: .machine, quote: "", sourceQuote: missing.first ?? "",
                    note: "原文里的 \(missing.prefix(3).joined(separator: "、")) 没出现在译文里"
                ))
            }
            if let short = DropCheck.shortfall(source: visibleSource, translation: visibleOut, from: from, to: to),
               short > 0.45 {
                issues.append(ProofIssue(kind: .omission, origin: .machine, quote: "",
                                         note: "译文比预期短 \(Int(short * 100))%，可能有整句没译"))
            }
        }

        if format == .markdown {
            let lostCode = Markdown.codeSpans(src).filter { !out.contains($0) }
            if let first = lostCode.first {
                issues.append(ProofIssue(kind: .format, origin: .machine, quote: "", sourceQuote: "`\(first)`",
                                         note: "行内代码 `\(first)` 应原样保留，译文里没有"))
            }
            let lostLinks = Markdown.linkTargets(src).filter { !out.contains($0) }
            if let first = lostLinks.first {
                issues.append(ProofIssue(kind: .format, origin: .machine, quote: "", sourceQuote: first,
                                         note: "链接地址 \(first) 在译文里丢了"))
            }
        }

        for term in glossary where contains(term: term.source, in: src) && !out.contains(term.target) {
            issues.append(ProofIssue(
                kind: .terminology, origin: .machine, quote: "", sourceQuote: term.source,
                note: "术语表要求把 \(term.source) 译作「\(term.target)」，这一段没有用"
            ))
        }
        return issues
    }

    /// Whole-word for Latin terms, so "art" is not found inside "start";
    /// plain containment for everything else.
    static func contains(term: String, in text: String) -> Bool {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if t.allSatisfy({ $0.isASCII }) {
            let lower = text.lowercased()
            var searchRange = lower.startIndex..<lower.endIndex
            let needle = t.lowercased()
            while let found = lower.range(of: needle, range: searchRange) {
                let before = found.lowerBound == lower.startIndex ? nil : lower[lower.index(before: found.lowerBound)]
                let after = found.upperBound == lower.endIndex ? nil : lower[found.upperBound]
                let boundary: (Character?) -> Bool = { c in c.map { !($0.isLetter || $0.isNumber) } ?? true }
                if boundary(before), boundary(after) { return true }
                searchRange = found.upperBound..<lower.endIndex
            }
            return false
        }
        return text.contains(t)
    }

    private static func hanShare(_ s: String) -> Double {
        let letters = s.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return 0 }
        return Double(letters.count { Language.isHan($0) }) / Double(letters.count)
    }

    private static func normalised(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Glossary lines in the document notes: "attention = 注意力",
    /// "attention → 注意力", "attention：注意力". Anything else in the notes
    /// is prose for the model and is left alone.
    static func glossary(from notes: String) -> [TermPair] {
        notes.split(whereSeparator: \.isNewline).compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*•· "))
            guard let match = s.wholeMatch(of: /(.+?)\s*(?:=|→|->|=>|：|:)\s*(.+)/) else { return nil }
            let left = String(match.1).trimmingCharacters(in: .whitespaces)
            let right = String(match.2).trimmingCharacters(in: CharacterSet(charactersIn: " 。.;；,，"))
            guard !left.isEmpty, !right.isEmpty, left.count <= 60, right.count <= 40 else { return nil }
            return TermPair(source: left, target: right)
        }
    }
}

// MARK: - Consistency across segments

/// One term, rendered two ways, in two places.
///
/// No single segment can see this: each rendering is fine on its own. It
/// only shows up when every segment's terms are laid side by side, which is
/// why it runs after the review rather than inside it.
enum TermConsistency {
    struct Finding: Equatable {
        let segment: Int
        let term: String
        let used: String
        let preferred: String
        let elsewhere: [Int]
    }

    static func findings(
        terms: [(segment: Int, pairs: [TermPair], translation: String)],
        glossary: [TermPair]
    ) -> [Finding] {
        var renderings: [String: [(segment: Int, target: String)]] = [:]
        var display: [String: String] = [:]
        for entry in terms {
            for pair in entry.pairs {
                let key = pair.source.lowercased().trimmingCharacters(in: .whitespaces)
                let target = pair.target.trimmingCharacters(in: .whitespaces)
                // Only renderings actually in the text count; a model that
                // misreports its own reading is not evidence.
                guard !key.isEmpty, !target.isEmpty, entry.translation.contains(target),
                      target.lowercased() != key else { continue }
                if renderings[key]?.contains(where: { $0.segment == entry.segment }) == true { continue }
                renderings[key, default: []].append((entry.segment, target))
                display[key] = display[key] ?? pair.source
            }
        }

        var findings: [Finding] = []
        for (key, uses) in renderings {
            let groups = Dictionary(grouping: uses, by: \.target)
            guard groups.count > 1 else { continue }
            let preferred: String
            if let fixed = glossary.first(where: { $0.source.lowercased() == key })?.target {
                preferred = fixed
            } else {
                preferred = groups.max { a, b in
                    a.value.count != b.value.count ? a.value.count < b.value.count
                        : a.value[0].segment > b.value[0].segment
                }!.key
            }
            let canonical = groups[preferred]?.map(\.segment) ?? []
            for (target, group) in groups where target != preferred {
                // 注意力 and 注意力机制 are one rendering, not two.
                if target.contains(preferred) || preferred.contains(target) { continue }
                for use in group {
                    findings.append(Finding(segment: use.segment, term: display[key] ?? key,
                                            used: target, preferred: preferred, elsewhere: canonical))
                }
            }
        }
        return findings.sorted { $0.segment < $1.segment }
    }

    /// The term lines worth a model's look: a source word that appears in
    /// the terms of two segments, rendered two different ways — "attention
    /// layers" as 注意力层 and "attention patterns" as 关注模式. Most documents
    /// have none, and then there is nothing to ask.
    static func candidates(_ terms: [(segment: Int, pairs: [TermPair])]) -> [(segment: Int, pair: TermPair)] {
        var byWord: [String: [(segment: Int, pair: TermPair)]] = [:]
        for entry in terms {
            for pair in entry.pairs {
                let words = pair.source.lowercased()
                    .split(whereSeparator: { !$0.isLetter })
                    .map(String.init)
                    .filter { $0.count >= 4 || !$0.allSatisfy(\.isASCII) }
                for word in Set(words) { byWord[word, default: []].append((entry.segment, pair)) }
            }
        }
        var picked: [(segment: Int, pair: TermPair)] = []
        for uses in byWord.values where Set(uses.map(\.segment)).count >= 2 {
            let targets = Set(uses.map(\.pair.target))
            // Renderings that share a character run are variations of one
            // rendering (注意力 / 注意力层); only strangers are suspicious.
            let related = targets.allSatisfy { a in
                targets.allSatisfy { b in a == b || sharesRun(a, b) }
            }
            if targets.count >= 2, !related { picked += uses }
        }
        var seen = Set<String>()
        return picked.filter { seen.insert("\($0.segment)|\($0.pair.source)|\($0.pair.target)").inserted }
            .sorted { $0.segment < $1.segment }
    }

    private static func sharesRun(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard x.count >= 2, y.count >= 2 else { return a.contains(b) || b.contains(a) }
        let pairs = Set(zip(x, x.dropFirst()).map { String([$0, $1]) })
        return zip(y, y.dropFirst()).contains { pairs.contains(String([$0, $1])) }
    }
}

// MARK: - Pairing a source with someone else's translation

/// Pairs the blocks of a source with the blocks of a translation made
/// elsewhere.
///
/// The two never cut the same way: translators merge short paragraphs,
/// split long ones and drop the odd one. Pairing by position would make
/// every segment after the first merge compare against the wrong text, so
/// this is a small Gale–Church alignment — lengths should be in the
/// proportion the language pair predicts, numbers should reappear — with
/// structure (headings, code) as strong hints.
enum Aligner {
    struct Pair: Equatable {
        var source: [Int]
        var target: [Int]
    }

    static func align(source: [TextBlock], target: [TextBlock], ratio: Double) -> [Pair] {
        let n = source.count, m = target.count
        if n == 0 { return target.indices.map { Pair(source: [], target: [$0]) } }
        if m == 0 { return source.indices.map { Pair(source: [$0], target: []) } }

        let sLen = source.map { Double(Markdown.visibleText($0.text).count) }
        let tLen = target.map { Double(Markdown.visibleText($0.text).count) }

        // Same cut, same structure, and every pair the length it should be:
        // nothing to decide. The length test is not optional — measured, a
        // translation that split one paragraph and dropped another has the
        // same count as its source, and pairing by position then compares
        // every paragraph after the split with the wrong one.
        if n == m, zip(source, target).allSatisfy({ compatible($0.kind, $1.kind) }),
           (0..<n).allSatisfy({ abs(log((tLen[$0] + 8) / (sLen[$0] * ratio + 8))) < 0.55 }) {
            return (0..<n).map { Pair(source: [$0], target: [$0]) }
        }
        let sAnchors = source.map { DropCheck.anchors(in: $0.text) }
        let tAnchors = target.map { DropCheck.anchors(in: $0.text) }

        func cost(_ si: Range<Int>, _ ti: Range<Int>) -> Double {
            if si.isEmpty || ti.isEmpty {
                let lone = si.isEmpty ? target[ti.lowerBound] : source[si.lowerBound]
                // Losing a verbatim block costs nothing to explain; losing
                // a paragraph is what the proofreader is here to find, but
                // it must be the cheaper story only when nothing fits.
                return lone.kind.isVerbatim ? 1.5 : 3.2
            }
            let ls = si.reduce(0) { $0 + sLen[$1] }
            let lt = ti.reduce(0) { $0 + tLen[$1] }
            let delta = log((lt + 8) / (ls * ratio + 8))
            var c = delta * delta * 4
            if si.count > 1 || ti.count > 1 { c += 1.4 }

            let sk = source[si.lowerBound].kind, tk = target[ti.lowerBound].kind
            if sk.isVerbatim != tk.isVerbatim { c += 5 }
            else if sk.isVerbatim {
                c = source[si.lowerBound].text == target[ti.lowerBound].text ? 0 : 0.6
            }
            if sk.isHeading != tk.isHeading { c += 1.6 }
            if (sk == .table) != (tk == .table) { c += 2 }

            let sa = si.reduce(into: Set<String>()) { $0.formUnion(sAnchors[$1]) }
            let ta = ti.reduce(into: Set<String>()) { $0.formUnion(tAnchors[$1]) }
            let shared = sa.intersection(ta).count
            c -= Double(min(shared, 3)) * 0.45
            if sa.count >= 2, shared == 0 { c += 0.6 }
            return c
        }

        let moves: [(Int, Int)] = [(1, 1), (1, 0), (0, 1), (2, 1), (1, 2)]
        var best = Array(repeating: Array(repeating: Double.infinity, count: m + 1), count: n + 1)
        var back = Array(repeating: Array(repeating: (0, 0), count: m + 1), count: n + 1)
        best[0][0] = 0
        for i in 0...n {
            for j in 0...m where best[i][j] < .infinity {
                for (di, dj) in moves where i + di <= n && j + dj <= m {
                    let c = best[i][j] + cost(i..<(i + di), j..<(j + dj))
                    if c < best[i + di][j + dj] {
                        best[i + di][j + dj] = c
                        back[i + di][j + dj] = (di, dj)
                    }
                }
            }
        }

        var pairs: [Pair] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            let (di, dj) = back[i][j]
            if di == 0 && dj == 0 { break }
            pairs.append(Pair(source: Array((i - di)..<i), target: Array((j - dj)..<j)))
            i -= di; j -= dj
        }
        return pairs.reversed()
    }

    private static func compatible(_ a: SegmentBlock, _ b: SegmentBlock) -> Bool {
        a.isVerbatim == b.isVerbatim && a.isHeading == b.isHeading && (a == .table) == (b == .table)
    }

    /// Characters of target text per character of source, measured for the
    /// on-device translator (see `DropCheck.shortfall`). Scripts, not
    /// languages, are what move it.
    static func ratio(from: Language, to: Language) -> Double {
        switch (from.isHanScript, to.isHanScript) {
        case (false, true): 0.3
        case (true, false): 3.6
        default: 1.05
        }
    }
}

/// Pairs paragraphs by meaning, with a language model.
///
/// Length and numbers cannot always decide. Measured on a short story whose
/// translator split one paragraph and dropped another: every wrong pairing
/// was as plausible by length as the right one, and a story has no numbers.
/// The on-device translator could supply meaning, but at ~100 characters a
/// second it would make a ten-page proofread wait a minute before starting.
/// One model call over paragraph openings and endings takes a few seconds.
enum ModelAligner {
    static func align(source: [TextBlock], target: [TextBlock], from: Language, to: Language,
                      provider: any TranslationProvider) async -> [Aligner.Pair]? {
        guard source.count >= 2 || target.count >= 2, source.count + target.count <= 800 else { return nil }
        func gist(_ block: TextBlock) -> String {
            if block.kind.isVerbatim { return "[code or image, kept verbatim]" }
            let text = Markdown.plainText(block.text).replacingOccurrences(of: "\n", with: " ")
            guard text.count > 120 else { return text }
            return String(text.prefix(80)) + " … " + String(text.suffix(35))
        }
        let listing = source.enumerated().map { "S\($0.offset + 1): \(gist($0.element))" }.joined(separator: "\n")
            + "\n\n"
            + target.enumerated().map { "T\($0.offset + 1): \(gist($0.element))" }.joined(separator: "\n")
        let system = """
        You align a document in \(from.promptName) with its translation into \(to.promptName). \
        The user message lists the numbered paragraphs of the SOURCE (S) and of the \
        TRANSLATION (T), each shortened to its beginning and end. The translator kept \
        the order but may have merged, split, dropped or added paragraphs.

        Pair them by meaning. Answer with one JSON object and nothing else:
        {"pairs":[{"s":[1],"t":[1]},{"s":[2],"t":[2,3]},{"s":[3],"t":[]},{"s":[4,5],"t":[4]}]}
        - Every S number and every T number appears exactly once, in increasing order.
        - A paragraph with no counterpart gets an empty list on the other side.
        """
        let request = TranslationRequest(text: listing, source: from, target: to, instructions: system)
        var text = ""
        do {
            for try await event in provider.translate(request) {
                switch event {
                case .delta(let chunk): text += chunk
                case .replace(let full): text = full
                case .dictionary: break
                }
            }
        } catch {
            Log.window.error("align failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        struct Answer: Decodable {
            struct P: Decodable { var s: [Int]?; var t: [Int]? }
            var pairs: [P]
        }
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(String(text[open...close]).utf8))
        else { return nil }
        let pairs = answer.pairs.map { Aligner.Pair(source: ($0.s ?? []).map { $0 - 1 }, target: ($0.t ?? []).map { $0 - 1 }) }
        // Trusted only if it is a complete, ordered partition of both sides;
        // anything else falls back to the length alignment.
        guard pairs.allSatisfy({ !$0.source.isEmpty || !$0.target.isEmpty }),
              pairs.flatMap(\.source) == Array(0..<source.count),
              pairs.flatMap(\.target) == Array(0..<target.count) else {
            Log.window.error("align answer rejected")
            return nil
        }
        return pairs
    }
}

// MARK: - The model as reviewer

struct ReviewJob: Sendable {
    let index: Int
    let source: String
    let translation: String
    let block: SegmentBlock
    let context: DocumentContext
}

enum ReviewEvent: Sendable {
    case finished(index: Int, issues: [ProofIssue], terms: [TermPair])
    case failed(index: Int, message: String)
}

/// Reads each segment's translation against its source with a language
/// model, three at a time, and reports what it would fix.
struct ModelReviewer: Sendable {
    let provider: any TranslationProvider
    private static let width = 3

    func run(_ jobs: [ReviewJob], source: Language, target: Language, markdown: Bool)
        -> AsyncStream<ReviewEvent>
    {
        AsyncStream { continuation in
            let provider = self.provider
            let task = Task {
                await withTaskGroup(of: ReviewEvent.self) { group in
                    var next = jobs.startIndex
                    var running = 0
                    func launch() {
                        guard next < jobs.endIndex else { return }
                        let job = jobs[next]
                        next += 1
                        running += 1
                        group.addTask {
                            await Self.review(job, source: source, target: target,
                                              markdown: markdown, provider: provider)
                        }
                    }
                    for _ in 0..<Self.width { launch() }
                    while running > 0, let event = await group.next() {
                        running -= 1
                        continuation.yield(event)
                        if Task.isCancelled { break }
                        launch()
                    }
                    group.cancelAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func review(
        _ job: ReviewJob, source: Language, target: Language, markdown: Bool,
        provider: any TranslationProvider
    ) async -> ReviewEvent {
        let request = TranslationRequest(
            text: ReviewPrompt.message(source: job.source, translation: job.translation),
            source: source, target: target,
            instructions: ReviewPrompt.system(
                source: source, target: target, context: job.context,
                block: job.block, markdown: markdown
            )
        )
        var text = ""
        do {
            for try await event in provider.translate(request) {
                try Task.checkCancellation()
                switch event {
                case .delta(let chunk): text += chunk
                case .replace(let full): text = full
                case .dictionary: break
                }
            }
        } catch is CancellationError {
            return .failed(index: job.index, message: "已取消")
        } catch {
            return .failed(index: job.index, message: error.localizedDescription)
        }
        guard let parsed = ReviewPrompt.parse(text, translation: job.translation) else {
            Log.window.error("review unparseable: \(text.prefix(300), privacy: .public)")
            return .failed(index: job.index, message: "模型的回答读不懂，可重试")
        }
        return .finished(index: job.index, issues: parsed.issues, terms: parsed.terms)
    }
}

extension ModelReviewer {
    /// One call over the whole document's terms: the check no single segment
    /// can make, for the cases plain string comparison cannot see — "attention
    /// layers" and "attention patterns" are one concept to a reader and two
    /// strings to a program.
    func consistency(
        _ terms: [(segment: Int, pairs: [TermPair])], source: Language, target: Language,
        notes: String
    ) async -> [(segment: Int, issue: ProofIssue)] {
        let listing = TermConsistency.candidates(terms).map {
            "§\($0.segment + 1): \($0.pair.source) → \($0.pair.target)"
        }
        guard listing.count >= 2 else { return [] }
        var system = """
        You check terminology consistency in a translation from \(source.promptName) \
        into \(target.promptName). You are given every technical term of one document \
        and how the translation renders it, segment by segment (§ numbers).

        Find the same source concept rendered in different ways — including when it \
        appears inside different compounds (e.g. one word translated one way in \
        "X layers" and another way in "X patterns"). For each inconsistent place, \
        give the rendering to replace and the consistent one to use instead, \
        following the majority or the glossary. Report only the same word in the \
        same sense translated with different words. A compound that names \
        something else is not an inconsistency — a "lighthouse keeper" is not a \
        "lighthouse" — and neither are grammatical variation or two correct \
        renderings of two different senses. When unsure, leave it out.

        Answer with one JSON object and nothing else:
        {"fixes":[{"segment":13,"quote":"…","suggestion":"…","note":"…"}]}
        - quote: the exact inconsistent words as they appear in that segment's rendering.
        - suggestion: what those words should be, consistent with the other segments.
        - note: one short sentence in Simplified Chinese naming the term and where \
          it is rendered the other way.
        If everything is consistent, return {"fixes":[]}.
        """
        if !notes.isEmpty { system += "\n\nThe reader's glossary and notes, binding:\n\(notes)" }
        let request = TranslationRequest(
            text: listing.joined(separator: "\n"), source: source, target: target,
            instructions: system
        )
        let provider = self.provider
        let text: String
        do {
            // A check nobody asked for directly must not be the reason the
            // review looks unfinished.
            text = try await withTimeout(25) {
                var text = ""
                for try await event in provider.translate(request) {
                    switch event {
                    case .delta(let chunk): text += chunk
                    case .replace(let full): text = full
                    case .dictionary: break
                    }
                }
                return text
            }
        } catch {
            Log.window.error("consistency failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        struct Answer: Decodable {
            struct Fix: Decodable {
                var segment: Int?
                var quote: String?
                var suggestion: String?
                var note: String?
            }
            var fixes: [Fix]?
        }
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(String(text[open...close]).utf8))
        else { return [] }
        return (answer.fixes ?? []).compactMap { fix in
            guard let number = fix.segment, let quote = fix.quote?.trimmingCharacters(in: .whitespaces),
                  !quote.isEmpty, let note = fix.note, !note.isEmpty else { return nil }
            let suggestion = fix.suggestion?.trimmingCharacters(in: .whitespaces)
            return (number - 1, ProofIssue(
                kind: .terminology, origin: .document, quote: quote,
                suggestion: suggestion == quote || suggestion?.isEmpty == true ? nil : suggestion,
                note: note
            ))
        }
    }
}

enum ReviewPrompt {
    static func system(source: Language, target: Language, context: DocumentContext,
                       block: SegmentBlock, markdown: Bool) -> String {
        var prompt = """
        You are a senior translation reviewer. You are given segment \(context.index) \
        of \(context.count) from one document: the SOURCE in \(source.promptName) and a \
        TRANSLATION into \(target.promptName) made by someone else. Compare them and \
        report only real problems that a careful editor would fix.
        """
        if !context.title.isEmpty { prompt += "\n\nThe document is titled: \(context.title)" }
        if let hint = block.promptHint { prompt += "\n\nThis segment is \(hint)." }
        if block.isHeading {
            // Measured: "Setup" rendered 实验设置 was reported as an addition
            // on two runs of two. Translators title freely; that is the craft.
            prompt += " Headings are often rendered freely, e.g. with a clarifying word added; that is not a problem."
        }
        if !context.notes.isEmpty {
            prompt += """

            The reader's notes on domain, terminology and register — a glossary \
            here is binding:
            \(context.notes)
            """
        }
        if let previous = context.previous, !previous.isEmpty {
            prompt += """

            For reference only, the source just before this segment ended with:
            \(previous)
            """
        }
        prompt += """

        Problem types:
        - omission: content of the source is missing from the translation
        - addition: the translation says something the source does not
        - mistranslation: meaning changed, reversed, or wrong
        - terminology: a technical term rendered wrongly or against the glossary
        - number: a number, unit, date or proper name changed
        - grammar: a grammatical error or typo in the translation
        - style: wrong register or clearly unidiomatic phrasing — only when clearly \
          wrong, never a matter of taste

        Answer with one JSON object and nothing else:
        {"issues":[{"type":"…","quote":"…","source":"…","suggestion":"…","note":"…"}],\
        "terms":[{"source":"…","target":"…"}]}

        - quote: copied character for character from the TRANSLATION — the shortest \
          span that contains the problem. For an omission, quote the few words of \
          the translation where the missing content belongs.
        - source: the matching span of the SOURCE, copied exactly.
        - suggestion: the corrected text that replaces quote, in \(target.promptName). \
          For an omission, the quoted words with the missing content inserted.
        - note: one short sentence in Simplified Chinese saying what is wrong.
        - terms: up to 8 technical terms or names in this segment, each with the \
          exact words the TRANSLATION uses for it.
        - Acceptable alternatives, word order and stylistic freedom are not problems, \
          and neither is an idiomatic rendering that adds no information even if it \
          is not literal. If the translation is correct, return "issues": [].
        """
        if markdown {
            prompt += """

            - The texts are Markdown. Syntax, inline code, URLs and HTML tags stay \
              untranslated and are not problems in themselves.
            """
        }
        return prompt
    }

    static func message(source: String, translation: String) -> String {
        """
        SOURCE:
        <<<
        \(source)
        >>>

        TRANSLATION:
        <<<
        \(translation)
        >>>
        """
    }

    private struct Answer: Decodable {
        struct Issue: Decodable {
            var type: String?
            var quote: String?
            var source: String?
            var suggestion: String?
            var note: String?
        }
        struct Term: Decodable {
            var source: String?
            var target: String?
        }
        var issues: [Issue]?
        var terms: [Term]?
    }

    /// Reads the model's JSON, forgiving the ways models dress it up — a code
    /// fence, a sentence before it — and dropping anything that does not
    /// point at the text it was given.
    static func parse(_ raw: String, translation: String) -> (issues: [ProofIssue], terms: [TermPair])? {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close,
              let data = String(raw[open...close]).data(using: .utf8),
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }

        let issues: [ProofIssue] = (answer.issues ?? []).compactMap { item in
            let note = (item.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else { return nil }
            let kind = ProofIssue.Kind(rawValue: (item.type ?? "").lowercased()) ?? .mistranslation
            var quote = (item.quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // A quote that is not in the text cannot be highlighted or
            // replaced; the note still stands, anchored to nothing.
            if !quote.isEmpty, !translation.contains(quote) { quote = "" }
            var suggestion = item.suggestion?.trimmingCharacters(in: .whitespacesAndNewlines)
            if suggestion?.isEmpty == true || suggestion == quote { suggestion = nil }
            // Models quote a sentence without its full stop and then suggest
            // one with it; replacing would leave two.
            if let s = suggestion, let last = s.last, last.isPunctuation, !quote.isEmpty,
               quote.last != last, let range = translation.range(of: quote),
               range.upperBound < translation.endIndex, translation[range.upperBound] == last {
                suggestion = String(s.dropLast())
            }
            return ProofIssue(kind: kind, origin: .model, quote: quote,
                              sourceQuote: item.source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                              suggestion: suggestion, note: note)
        }
        let terms: [TermPair] = (answer.terms ?? []).compactMap { term in
            guard let s = term.source?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
                  let t = term.target?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            return TermPair(source: s, target: t)
        }
        return (issues, terms)
    }
}

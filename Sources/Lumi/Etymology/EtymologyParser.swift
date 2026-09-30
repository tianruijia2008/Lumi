import Foundation

/// Turns one Wiktionary page into an `EtymologyEntry`.
///
/// Two renderings of the same page are read, each for what it is good at. The
/// wikitext carries the etymology as template calls, which is a chain a
/// program can follow. The rendered HTML carries the senses and quotations
/// with their dates already expanded — a Shakespeare citation is written as
/// `{{RQ:Shakespeare Taming of the Shrew}}` in the source, and only the
/// rendered page knows that means "c. 1590–1592".
enum EtymologyParser {
    enum Failure: Error, Equatable {
        case noEnglishEntry
    }

    /// A reconstructed root the entry names but does not place in its chain —
    /// `{{root|en|ine-pro|*skey-}}`. Reading its own page is a second request,
    /// made by the caller.
    struct Root: Equatable, Sendable {
        let lang: String
        let form: String

        /// `Reconstruction:Proto-Indo-European/skey-`
        var pageTitle: String? {
            guard let family = Self.families[lang] else { return nil }
            let bare = form.hasPrefix("*") ? String(form.dropFirst()) : form
            return "Reconstruction:\(family)/\(bare)"
        }

        private static let families = [
            "ine-pro": "Proto-Indo-European", "gem-pro": "Proto-Germanic",
            "gmw-pro": "Proto-West Germanic", "itc-pro": "Proto-Italic",
        ]
    }

    static func parse(word: String, wikitext: String, html: String) throws -> (EtymologyEntry, Root?) {
        guard let english = WikiText.section(wikitext, heading: "English", level: 2) else {
            throw Failure.noEnglishEntry
        }
        var entry = EtymologyEntry(word: word)
        entry.pages = [word]
        entry.ipa = ipa(in: english)

        var root: Root?
        if let etymology = etymologySection(english) {
            let chain = self.chain(from: etymology)
            entry.chain = chain.nodes
            entry.folk = chain.folk
            // A root already standing in the chain needs no second request.
            if let named = chain.root, !entry.chain.contains(where: { $0.lang == named.lang }) {
                root = named
            }
        }

        if let fragment = englishFragment(html) {
            let read = readSenses(fragment)
            entry.partOfSpeech = read.partOfSpeech
            entry.senses = read.senses
            entry.quotes = chooseQuotes(read.quotes)
        }

        // The last step is the word itself. Only added when there is a chain
        // to end — a lone "today" box would be a chain of one.
        if !entry.chain.isEmpty {
            entry.chain.append(EtymNode(
                id: entry.chain.count, lang: "en", form: word,
                gloss: entry.senses.first?.label, isToday: true
            ))
        }
        return (entry, root)
    }

    // MARK: - Etymology

    private static func etymologySection(_ english: String) -> String? {
        let lines = english.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == "===Etymology===" || t == "===Etymology 1==="
        }) else { return nil }
        // Up to the next heading of any level: the part-of-speech sections
        // nest *inside* a numbered etymology, and their text is not etymology.
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("=") { break }
            body.append(line)
        }
        return body.joined(separator: "\n")
    }

    private static func ipa(in english: String) -> String? {
        for token in WikiText.tokens(of: english) {
            guard case .template(let t) = token, t.name == "ipa", t.arg(1) == "en",
                  let value = t.arg(2) else { continue }
            // Wiktionary marks the non-syllabic half of a diphthong (naɪ̯s); a
            // reader expects the dictionary spelling (naɪs).
            return value.replacingOccurrences(of: "\u{032F}", with: "")
        }
        return nil
    }

    private static let chainTemplates: Set<String> = [
        "inh", "inh+", "inh-lite", "der", "der+", "der-lite", "bor", "bor+", "lbor", "slbor",
        "obor", "ubor", "uder", "cal", "calque", "psm", "lbor+", "translit", "sl",
    ]
    private static let mentionTemplates: Set<String> = ["m", "m+", "l", "l+", "m-lite", "l-lite"]
    private static let asideWords = [
        "compare", "cognate", "equivalent", "doublet", "related to", "akin", "see also",
        "whence", "displaced", "replaced", "influenced",
    ]
    private static let folkWords = [
        "folk etymology", "popular etymology", "false etymology", "folk-etymology",
        "unfounded", "not from", "is a myth", "no evidence",
    ]

    struct Chain {
        var nodes: [EtymNode]
        var folk: [FolkClaim]
        var root: Root?
    }

    /// Reads "From A, from B, from C" as a chain.
    ///
    /// The rules are about which calls are *steps*. A chain template (`inh`,
    /// `der`, `bor`) is a step. A mention (`m`) is a step only when the prose
    /// before it says "from"; after "compare" or "cognate with" it is a side
    /// remark. A mention in the same language as the step before it is that
    /// step's alternative spelling, not a new step. Two calls joined by `+`
    /// are one step built from parts. A sentence the source flags as a folk
    /// etymology is lifted out whole, parts and all.
    static func chain(from etymology: String) -> Chain {
        var steps: [EtymNode] = []           // newest first, as written
        var sideParts: [Part] = []           // a `+` compound seen outside the chain
        var folk: [FolkClaim] = []
        var root: Root?

        // Split into sentences at the prose level, so a folk-etymology
        // sentence can be judged before any of its calls are used.
        var sentences: [[WikiText.Token]] = [[]]
        for token in WikiText.tokens(of: etymology) {
            guard case .text(let prose) = token else {
                sentences[sentences.count - 1].append(token); continue
            }
            var buffer = ""
            let chars = Array(prose)
            for (i, c) in chars.enumerated() {
                buffer.append(c)
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if c == ".", next == nil || next!.isWhitespace {
                    sentences[sentences.count - 1].append(.text(buffer))
                    buffer = ""
                    sentences.append([])
                }
            }
            if !buffer.isEmpty { sentences[sentences.count - 1].append(.text(buffer)) }
        }

        var chainOpen = true
        for sentence in sentences where !sentence.isEmpty {
            let prose = sentence.compactMap { if case .text(let t) = $0 { t } else { nil } }
                .joined().lowercased()

            if folkWords.contains(where: prose.contains) {
                let parts = sentence.compactMap { token -> Part? in
                    guard case .template(let t) = token else { return nil }
                    return part(from: t)
                }
                if !parts.isEmpty {
                    folk.append(FolkClaim(parts: parts, sourceSentence: visible(sentence)))
                }
                continue
            }

            // A later sentence continues the chain only if it opens by saying
            // so; otherwise it is commentary.
            let opening = prose.trimmingCharacters(in: .whitespacesAndNewlines)
            if !steps.isEmpty, !opening.hasPrefix("from"), !opening.hasPrefix("ultimately") {
                chainOpen = false
            }

            // Within a sentence the chain can only end: once the prose has
            // said "compare" or "cognate with", every later call in the same
            // sentence is part of that aside, "from" or not.
            var main = chainOpen
            var between = ""
            var parens = 0
            var previous: (part: Part, stepIndex: Int?)?

            for token in sentence {
                switch token {
                case .text(let text):
                    var outside = ""
                    for c in text {
                        if c == "(" { parens += 1 }
                        else if c == ")" { parens = max(0, parens - 1) }
                        else if parens == 0 { outside.append(c) }
                    }
                    between += outside
                    if asideWords.contains(where: outside.lowercased().contains) { main = false }

                case .template(let t):
                    if t.name == "root", root == nil, let lang = t.arg(2), let form = t.arg(3) {
                        root = Root(lang: lang, form: form)
                        between = ""
                        continue
                    }
                    // Inside parentheses is commentary on the step before it.
                    guard parens == 0, let part = part(from: t) else { continue }
                    let gap = between.lowercased()
                    between = ""

                    if gap.contains("+"), let prev = previous {
                        if let index = prev.stepIndex {
                            steps[index].addends.append(part)
                        } else {
                            if sideParts.isEmpty { sideParts.append(prev.part) }
                            sideParts.append(part)
                        }
                        previous = (part, nil)
                        continue
                    }

                    let isChain = chainTemplates.contains(t.name)
                    let isMention = mentionTemplates.contains(t.name)
                    guard main, isChain || isMention else {
                        previous = (part, nil)
                        continue
                    }
                    if let last = steps.last, last.lang == part.lang {
                        // Another spelling of the step just taken. Its gloss is
                        // kept when the first spelling came without one.
                        if steps[steps.count - 1].gloss == nil {
                            steps[steps.count - 1].gloss = part.gloss
                        }
                        previous = (part, steps.count - 1)
                        continue
                    }
                    guard isChain || gap.contains("from") else {
                        previous = (part, nil)
                        continue
                    }
                    steps.append(EtymNode(id: 0, lang: part.lang, form: part.form, gloss: part.gloss))
                    previous = (part, steps.count - 1)
                }
            }
        }

        var nodes = Array(steps.reversed())
        // A compound spelled out beside the chain ("compare nesciō, from ne +
        // sciō") explains the oldest step, so it goes in front of it. Only
        // when the languages agree: a Latin compound does not explain a Greek
        // step.
        if sideParts.count >= 2, let oldest = nodes.first, sideParts.allSatisfy({ $0.lang == oldest.lang }),
           !sideParts.contains(where: { $0.form == oldest.form }) {
            let base = sideParts[sideParts.count - 1]
            nodes.insert(EtymNode(id: 0, lang: base.lang, form: base.form, gloss: base.gloss,
                                  addends: Array(sideParts.dropLast())), at: 0)
        }
        // An English step is the word itself under an older spelling; the
        // chain ends with its own "today" node instead.
        nodes.removeAll { $0.lang == "en" }
        for index in nodes.indices { nodes[index].id = index }
        return Chain(nodes: nodes, folk: folk, root: root)
    }

    private static func part(from t: WikiText.Template) -> Part? {
        let lang: String?, form: String?, alt: String?, gloss: String?
        if chainTemplates.contains(t.name) {
            lang = t.arg(2); form = t.arg(3); alt = t.arg(4); gloss = t.named("t", "gloss") ?? t.arg(5)
        } else if mentionTemplates.contains(t.name) {
            lang = t.arg(1); form = t.arg(2); alt = t.arg(3); gloss = t.named("t", "gloss") ?? t.arg(4)
        } else {
            return nil
        }
        guard let lang, var shown = alt ?? form else { return nil }
        // `sam#Adverb` names a section of the page, not a spelling.
        shown = shown.components(separatedBy: "#").first ?? shown
        shown = WikiText.plain(shown)
        guard !shown.isEmpty, shown != "-" else { return nil }
        return Part(lang: lang, form: shown, gloss: gloss.map(WikiText.plain).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A sentence as a reader would see it, for quoting a folk-etymology note.
    private static func visible(_ sentence: [WikiText.Token]) -> String {
        var out = ""
        for token in sentence {
            switch token {
            case .text(let t): out += t
            case .template(let t):
                if let part = part(from: t) { out += part.form }
                else if t.name == "glossary" { out += t.arg(1) ?? "" }
                else if t.name == "w" { out += t.arg(1) ?? "" }
            }
        }
        return WikiText.plain(out)
    }

    // MARK: - The root's own page

    /// Adds the root and whatever the root's page says lies between it and the
    /// oldest step: `*skey-` "to split" → Proto-Italic `*skijō` "to discern" →
    /// Latin `sciō`. The intermediate steps are the part a dictionary never
    /// prints and the reason this page is worth opening.
    static func applyRoot(_ root: Root, page: String, to entry: inout EtymologyEntry) {
        let gloss = page.components(separatedBy: "\n")
            .first { $0.hasPrefix("# ") }
            .map { WikiText.plain(String($0.dropFirst(2))) }

        var inserted: [EtymNode] = []
        if let oldest = entry.chain.first(where: { !$0.isToday }) {
            inserted = lineage(of: oldest, in: page)
        }
        let rootNode = EtymNode(id: 0, lang: root.lang, form: root.form, gloss: gloss)
        entry.chain.insert(contentsOf: [rootNode] + inserted, at: 0)
        for index in entry.chain.indices { entry.chain[index].id = index }
        if let title = root.pageTitle { entry.pages.append(title) }
    }

    /// Walks up the descendant tree on a root page from the line that names
    /// `node`, collecting the reconstructed forms on the way.
    private static func lineage(of node: EtymNode, in page: String) -> [EtymNode] {
        let lines = page.components(separatedBy: "\n")
        func matches(_ line: String) -> Bool {
            for token in WikiText.tokens(of: line) {
                guard case .template(let t) = token, ["desc", "desctree", "l", "desc-lite"].contains(t.name),
                      t.arg(1) == node.lang, let term = t.arg(2) else { continue }
                if term.compare(node.form, options: [.diacriticInsensitive, .caseInsensitive]) == .orderedSame {
                    return true
                }
            }
            return false
        }
        guard let hit = lines.firstIndex(where: matches) else { return [] }
        var depth = lines[hit].prefix { $0 == "*" }.count
        var found: [EtymNode] = []
        var i = hit - 1
        while i >= 0, depth > 1 {
            let line = lines[i]
            let d = line.prefix { $0 == "*" }.count
            if d > 0, d < depth {
                depth = d
                for token in WikiText.tokens(of: line) {
                    guard case .template(let t) = token, t.name == "desc" || t.name == "desctree",
                          let lang = t.arg(1), lang != "ine-pro", let form = t.arg(2) else { continue }
                    found.insert(EtymNode(id: 0, lang: lang, form: form,
                                          gloss: t.named("t", "gloss").map(WikiText.plain)), at: 0)
                    break
                }
            }
            i -= 1
        }
        return found
    }

    // MARK: - Senses and quotations (rendered HTML)

    /// The English section of the rendered page, first etymology only.
    ///
    /// Cut as a string before parsing because the rendered page has no
    /// section elements to select — headings and content are siblings.
    static func englishFragment(_ html: String) -> String? {
        guard let start = html.range(of: "id=\"English\"") else { return nil }
        var rest = html[start.upperBound...]
        for marker in ["mw-heading2", "id=\"Etymology_2\""] {
            if let next = rest.range(of: marker),
               let tagStart = rest[..<next.lowerBound].lastIndex(of: "<") {
                rest = rest[..<tagStart]
            }
        }
        // Tidy mangles text on the way in: handed raw UTF-8 it drops
        // characters it cannot map to Latin-1, and even as numeric entities it
        // throws away the whole General Punctuation block — en dashes, curly
        // quotes, the ellipsis — which turned "c. 1590–1592" into
        // "c. 15901592" and lost the date. So non-ASCII goes in as entities,
        // and that one block is first parked in the Private Use Area, which
        // tidy leaves alone, to be moved back by `restored(_:)`.
        var escaped = ""
        escaped.reserveCapacity(rest.utf8.count)
        for scalar in rest.unicodeScalars {
            if scalar.isASCII { escaped.unicodeScalars.append(scalar); continue }
            var value = scalar.value
            if punctuation.contains(value) { value = value - punctuation.lowerBound + parking }
            escaped += "&#\(value);"
        }
        return "<html><body><div>" + escaped + "</div></body></html>"
    }

    private static let punctuation: ClosedRange<UInt32> = 0x2010...0x206F
    private static let parking: UInt32 = 0xE000

    /// Undoes the parking done in `englishFragment`.
    static func restored(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let parked = parking...(parking + punctuation.upperBound - punctuation.lowerBound)
        for scalar in text.unicodeScalars {
            if parked.contains(scalar.value),
               let original = Unicode.Scalar(scalar.value - parking + punctuation.lowerBound) {
                out.append(original)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// A node's text, with parked punctuation put back.
    private static func nodeText(_ node: XMLNode?) -> String {
        restored(node?.stringValue ?? "")
    }

    struct RawQuote {
        var quote: Quote
        var senseIndex: Int
    }

    private static let partsOfSpeech: Set<String> = [
        "Adjective", "Noun", "Verb", "Adverb", "Pronoun", "Preposition", "Conjunction",
        "Interjection", "Determiner", "Numeral", "Particle", "Proper noun", "Prefix", "Suffix", "Phrase",
    ]

    static func readSenses(_ fragment: String) -> (partOfSpeech: String?, senses: [Sense], quotes: [RawQuote]) {
        guard let data = fragment.data(using: .utf8),
              let doc = try? XMLDocument(data: data, options: [.documentTidyHTML]) else {
            return (nil, [], [])
        }
        // The first list of senses belongs to the first part of speech. Later
        // lists are other parts of speech, or subsenses, and one timeline of
        // one part of speech is what the chart can honestly draw.
        let heads = (try? doc.nodes(forXPath: "//h3|//h4")) ?? []
        let pos = heads.map { nodeText($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { partsOfSpeech.contains($0) }
        guard let list = (try? doc.nodes(forXPath: "(//ol)[1]"))?.first as? XMLElement else {
            return (pos, [], [])
        }

        var senses: [Sense] = []
        var quotes: [RawQuote] = []
        for case let item as XMLElement in list.children ?? [] where item.name == "li" {
            let text = definitionText(item)
            guard !text.isEmpty else { continue }
            let dateText = nodeText((try? item.nodes(forXPath: "./span[@class='defdate']"))?.first)
            let tags = ((try? item.nodes(forXPath: "./span[contains(@class,'usage-label-sense')]")) ?? [])
                .map { nodeText($0) }.joined(separator: ", ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "() "))
            let (start, end, open) = dates(dateText)
            let lowerTags = tags.lowercased()
            let status: SenseStatus
            if lowerTags.contains("obsolete") || (end != nil && !open) { status = .dead }
            else if lowerTags.contains("dated") || lowerTags.contains("archaic") || lowerTags.contains("rare") {
                status = .fading
            } else { status = .alive }

            let index = senses.count
            senses.append(Sense(
                id: index, text: text, label: shortLabel(text),
                start: start, end: open ? nil : end, status: status,
                tags: tags.isEmpty ? [] : tags.components(separatedBy: ", ")
            ))
            let citations = (try? item.nodes(forXPath: "./ul/li/div[@class='citation-whole']")) ?? []
            for case let citation as XMLElement in citations {
                if let quote = readQuote(citation) {
                    quotes.append(RawQuote(quote: quote, senseIndex: index))
                }
            }
        }
        return (pos, senses, quotes)
    }

    /// The definition as printed: the item's own text, without its register
    /// label, its date, or the examples and quotations nested under it.
    private static func definitionText(_ item: XMLElement) -> String {
        var out = ""
        for child in item.children ?? [] {
            if let element = child as? XMLElement {
                let name = element.name ?? ""
                let cls = element.attribute(forName: "class")?.stringValue ?? ""
                if ["ul", "ol", "dl", "style", "link", "sup"].contains(name) { continue }
                if cls.contains("defdate") || cls.contains("usage-label") || cls.contains("maintenance") { continue }
            }
            out += nodeText(child)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".;:")))
    }

    /// First clause, sentence-cased: "Pleasant, satisfactory" → "Pleasant".
    static func shortLabel(_ text: String) -> String {
        let cut = text.split(whereSeparator: { ",;(".contains($0) }).first.map(String.init) ?? text
        return cut.trimmingCharacters(in: .whitespaces)
    }

    /// `[from 18th c.]`, `[14th–17th c.]`, `[from 1590s]` → years.
    ///
    /// Centuries become their first year when they open a range and their
    /// last when they close it: "14th–17th c." is 1300–1700, not 1300–1600.
    static func dates(_ text: String) -> (start: Int?, end: Int?, open: Bool) {
        let lower = text.lowercased()
        var values: [(Int, Bool)] = []   // (number, isCentury)
        if let regex = try? NSRegularExpression(pattern: #"(\d{1,4})(st|nd|rd|th)?"#) {
            for m in regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
                guard let r = Range(m.range(at: 1), in: lower), let n = Int(lower[r]) else { continue }
                let century = m.range(at: 2).location != NSNotFound
                if century, n >= 1, n <= 21 { values.append((n, true)) }
                else if !century, n >= 1000, n <= 2100 { values.append((n, false)) }
            }
        }
        guard let first = values.first else { return (nil, nil, false) }
        let open = lower.contains("from") || lower.contains("since")
        let start = first.1 ? (first.0 - 1) * 100 : first.0
        if values.count >= 2 {
            let last = values[values.count - 1]
            return (start, last.1 ? last.0 * 100 : last.0, false)
        }
        if open { return (start, nil, true) }
        // A single century with no "from" is attested in that century only.
        return (start, first.1 ? first.0 * 100 : nil, first.1 ? false : true)
    }

    private static func readQuote(_ citation: XMLElement) -> Quote? {
        let source = nodeText((try? citation.nodes(forXPath: "./span[contains(@class,'cited-source')]"))?.first)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // Song lyrics are quoted on Wiktionary under its own terms; they are
        // not something to reprint in an app.
        if source.contains("performed by") { return nil }
        guard let passageNode = (try? citation.nodes(forXPath: ".//span[contains(@class,'cited-passage')]"))?
            .first else { return nil }
        var passage = marked(passageNode).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !passage.isEmpty else { return nil }
        passage = trimmed(passage)

        var year: Int?
        var approximate = false
        if let regex = try? NSRegularExpression(pattern: #"\b(1[0-9]{3}|20[0-9]{2})\b"#),
           let m = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
           let r = Range(m.range, in: source) {
            year = Int(source[r])
            let before = source[..<r.lowerBound].lowercased()
            approximate = before.contains("c.") || before.contains("a.") || before.contains("circa")
        }

        // A title in quotation marks is the work itself ("The Taming of the
        // Shrew") when it names one — capitalised, more than a word — and a
        // dictionary headword or chapter otherwise, in which case the
        // italicised collection it sits in is the better name.
        var title: String?
        if let open = source.firstIndex(of: "“"), let close = source[open...].firstIndex(of: "”") {
            let quoted = String(source[source.index(after: open)..<close])
            if quoted.count > 3, quoted.first?.isUppercase == true { title = quoted }
        }
        if title == nil, let cite = (try? citation.nodes(forXPath: ".//cite"))?.first.map({ nodeText($0) }) {
            title = cite
        }
        title = title.map(tidyCitation).flatMap { $0.isEmpty ? nil : $0 }

        var author: String?
        for piece in source.components(separatedBy: ", ").dropFirst() {
            let p = piece.trimmingCharacters(in: .whitespaces)
            guard let first = p.first, first.isUppercase || first == "[",
                  !p.contains("“"), !p.contains(where: \.isNumber), !p.hasPrefix("in ") else { continue }
            author = tidyCitation(p)
            break
        }
        return Quote(id: 0, year: year, approximate: approximate, passage: passage,
                     author: author, title: title)
    }

    /// Editorial brackets out, as a reader would say the name: "L[ucy] M[aud]
    /// Montgomery" → "Lucy Maud Montgomery", "[Jane Austen]" → "Jane Austen".
    private static func tidyCitation(_ text: String) -> String {
        text.replacingOccurrences(of: "[…]", with: "")
            .replacingOccurrences(of: "[...]", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "→", with: "")
            .replacingOccurrences(of: #"[\s,:;]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ",")))
    }

    /// The passage text with the headword — which Wiktionary sets in bold —
    /// wrapped in `**` so the page can highlight it.
    private static func marked(_ node: XMLNode) -> String {
        guard let element = node as? XMLElement else { return nodeText(node) }
        // Verse keeps its line breaks as the conventional slash.
        if element.name == "br" { return " / " }
        if element.name == "b" {
            let inner = nodeText(element)
            return inner.isEmpty ? "" : "**\(inner)**"
        }
        return (element.children ?? []).map(marked).joined()
    }

    /// Long quotations cut down to the sentences around the headword.
    private static func trimmed(_ passage: String, limit: Int = 300) -> String {
        guard passage.count > limit else { return passage }
        var sentences: [String] = []
        var current = ""
        for c in passage {
            current.append(c)
            if ".!?;".contains(c) { sentences.append(current); current = "" }
        }
        if !current.isEmpty { sentences.append(current) }
        guard let hit = sentences.firstIndex(where: { $0.contains("**") }) else {
            return String(passage.prefix(limit)) + "…"
        }
        var lo = hit, hi = hit
        var text = sentences[hit]
        while text.count < limit {
            if hi + 1 < sentences.count, text.count + sentences[hi + 1].count <= limit {
                hi += 1; text += sentences[hi]
            } else if lo > 0, text.count + sentences[lo - 1].count <= limit {
                lo -= 1; text = sentences[lo] + text
            } else { break }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if lo > 0 { text = "…" + text }
        if hi < sentences.count - 1 { text += "…" }
        return text
    }

    /// Up to eight, in date order, spread across the senses.
    ///
    /// One per sense first — the earliest — because the point of the list is
    /// to show the word *meaning different things*, and eight quotations of
    /// the modern sense say nothing a dictionary does not. Older quotations
    /// are preferred throughout: this is a history page.
    static func chooseQuotes(_ raw: [RawQuote], limit: Int = 8) -> [Quote] {
        let dated = raw.filter { $0.quote.year != nil }
        let byAge = dated.sorted { ($0.quote.year ?? 0) < ($1.quote.year ?? 0) }
        var chosen: [RawQuote] = []
        var covered = Set<Int>()
        for candidate in byAge where !covered.contains(candidate.senseIndex) && chosen.count < limit {
            covered.insert(candidate.senseIndex)
            chosen.append(candidate)
        }
        for candidate in byAge where chosen.count < limit
            && !chosen.contains(where: { $0.quote.passage == candidate.quote.passage })
            && (candidate.quote.year ?? 9999) <= 1930 {
            chosen.append(candidate)
        }
        return chosen
            .sorted { ($0.quote.year ?? 0) < ($1.quote.year ?? 0) }
            .enumerated()
            .map { offset, raw in
                var q = raw.quote
                q.id = offset + 1
                q.senseID = raw.senseIndex
                return q
            }
    }

    // MARK: - Words from the same root

    /// Picks the recognisable members of a root's category.
    ///
    /// The category lists every English term Wiktionary derives from the
    /// root, which for a productive root is a hundred entries of compounds and
    /// jokes (`neuroscientifically`, `giraffiti`). Kept: single common words —
    /// "common" meaning present in the system's own English vocabulary — with
    /// derivatives of a kept word dropped in favour of the word itself.
    static func kin(from members: [String], excluding word: String, isCommon: (String) -> Bool,
                    limit: Int = 6) -> [String] {
        let plain = members.filter { m in
            m.count >= 3 && m.count <= 12 && m != word
                && m.allSatisfy { $0.isLowercase && $0.isLetter }
                && isCommon(m)
        }
        let shortest = plain.sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
        var kept: [String] = []
        for candidate in shortest {
            // `awesome` is `awe` with a suffix; `skid` is not `ski` with one.
            let derived = kept.contains { base in
                (base.count >= 4 && candidate.contains(base))
                    || (base.count >= 5 && candidate.hasPrefix(String(base.prefix(5))))
                    || (candidate.hasPrefix(base) && candidate.count - base.count >= 3)
            }
            if !derived { kept.append(candidate) }
            if kept.count == limit { break }
        }
        return kept
    }
}

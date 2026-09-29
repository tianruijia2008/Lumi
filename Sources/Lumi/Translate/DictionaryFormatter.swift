import Foundation

/// Turns Dictionary.app's output into something readable in a narrow card.
///
/// `DCSCopyTextDefinition` returns one dense line — headword, pronunciation,
/// part-of-speech blocks, senses and examples all run together:
///
///     hello | BrE həˈləʊ, AmE həˈloʊ | A. noun 问候 wènhòu
///     B. exclamation ① (greeting) 你好 nǐ hǎo ② British (in surprise) 嘿 hēi
///
/// The structure is all there, just unpunctuated: pipes separate the header,
/// `A.`/`B.` divide parts of speech, circled digits number senses, and ▸
/// introduces examples. This puts the boundaries back.
enum DictionaryFormatter {
    /// - Parameter term: the word that was looked up. A dictionary entry always
    ///   opens with its headword, so knowing what was asked for turns the
    ///   headword/body split from a guess into a fact for every entry that has
    ///   no pipes to split on.
    static func parse(_ raw: String, term: String = "") -> DictionaryEntry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let (headword, pronunciation, body) = splitHeader(text, term: term)
        let blocks = breakUp(body)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        var lead: String?
        var groups: [DictionaryEntry.Group] = []
        var current = DictionaryEntry.Group(id: 0, label: nil, body: nil, senses: [])
        var notes: [DictionaryEntry.Note] = []
        var currentNote: DictionaryEntry.Note?

        func closeGroup() {
            guard current.label != nil || !current.senses.isEmpty || current.body != nil else {
                return
            }
            groups.append(current)
            current = DictionaryEntry.Group(
                id: groups.count, label: nil, body: nil, senses: []
            )
        }

        for block in blocks {
            if let title = sectionTitle(of: block) {
                closeGroup()
                if let note = currentNote { notes.append(note) }
                currentNote = DictionaryEntry.Note(
                    id: notes.count,
                    title: title,
                    body: String(block.dropFirst(title.count)).trimmed
                )
            } else if currentNote == nil, let rest = groupHeading(block) {
                closeGroup()
                let (label, body) = splitPartOfSpeech(rest)
                current.label = label
                current.body = body.isEmpty ? nil : body
            } else if let first = block.first, isSenseMarker(first) {
                // Sub-notes (㊀㊁) trail a section heading; they belong to that
                // note, not to the numbered senses above it.
                if var note = currentNote {
                    note.body += note.body.isEmpty ? block : "\n" + block
                    currentNote = note
                } else {
                    current.senses.append(makeSense(block, id: current.senses.count))
                }
            } else if var note = currentNote {
                note.body += "\n" + block
                currentNote = note
            } else if lead == nil {
                lead = block
            } else {
                lead = (lead ?? "") + " " + block
            }
        }
        closeGroup()
        if let note = currentNote { notes.append(note) }

        return DictionaryEntry(
            headword: headword ?? text,
            pronunciation: pronunciation,
            lead: lead,
            groups: groups,
            notes: notes
        )
    }

    // MARK: Senses

    private static func makeSense(_ block: String, id: Int) -> DictionaryEntry.Sense {
        var rest = Substring(block)
        let marker = String(rest.removeFirst())
        rest = rest.drop(while: \.isWhitespace)

        // Chinese entries tag each sense with a one-character part of speech
        // right after the marker; English ones carry it in the group label.
        var partOfSpeech: String?
        if let first = rest.first, cjkPartsOfSpeech.contains(first) {
            partOfSpeech = String(first)
            rest = rest.dropFirst().drop(while: \.isWhitespace)
        }

        // Everything past the first ▸ is an example, not part of the gloss.
        var pieces = rest.components(separatedBy: exampleMarker)
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
        let definition = pieces.isEmpty ? "" : pieces.removeFirst()

        return DictionaryEntry.Sense(
            id: id, marker: marker, partOfSpeech: partOfSpeech,
            text: definition, examples: pieces
        )
    }

    private static let exampleMarker = "\u{25B8}"   // ▸

    private static let cjkPartsOfSpeech: Set<Character> =
        ["动", "名", "形", "副", "数", "量", "代", "介", "连", "助", "叹", "拟", "缀"]

    // MARK: Part-of-speech blocks

    /// `A. noun …` → `noun …`. Anything else is not a block heading.
    ///
    /// Deliberately narrow: only a single letter from the start of the alphabet
    /// followed by a full stop and a space. Dictionaries never reach past a
    /// handful of blocks, and a looser rule would cut ordinary prose in half at
    /// every initial.
    private static func groupHeading(_ block: String) -> String? {
        let characters = Array(block)
        guard characters.count > 3,
              let first = characters.first, groupLetters.contains(first),
              characters[1] == ".", characters[2] == " "
        else { return nil }
        return String(characters[3...]).trimmed
    }

    private static let groupLetters: Set<Character> = ["A", "B", "C", "D", "E", "F", "G", "H"]

    /// Splits `transitive verb past tense, past participle set` into the label
    /// and the remainder. Longest match wins, so "transitive verb" is not read
    /// as "verb".
    private static func splitPartOfSpeech(_ text: String) -> (String?, String) {
        for candidate in partsOfSpeech where text == candidate || text.hasPrefix(candidate + " ") {
            return (candidate, String(text.dropFirst(candidate.count)).trimmed)
        }
        return (text.isEmpty ? nil : text, "")
    }

    /// Ordered longest-first so prefix matching cannot stop early.
    private static let partsOfSpeech = [
        "intransitive verb", "transitive verb", "reflexive verb", "auxiliary verb",
        "modal verb", "phrasal verb", "proper noun", "definite article",
        "indefinite article", "exclamation", "conjunction", "preposition",
        "determiner", "abbreviation", "adjective", "adverb", "pronoun",
        "numeral", "prefix", "suffix", "noun", "verb",
    ]

    // MARK: Header

    static let sectionTitles = ["PHRASAL VERBS", "DERIVATIVES", "COMPOUNDS", "ORIGIN",
                                "PHRASES", "IDIOMS", "USAGE", "NOTE",
                                "用法说明", "辨析", "提示", "参见"]

    private static func sectionTitle(of block: String) -> String? {
        sectionTitles.first { block.hasPrefix($0) }
    }

    /// Only the three-field form is a header.
    ///
    /// A single pipe means something else entirely: Chinese entries use it to
    /// separate example phrases — `学习语言 | 学习电脑` — so treating it as a
    /// header separator bolds half the definition as the headword.
    private static func splitHeader(_ text: String, term: String) -> (String?, String?, String) {
        let parts = text.components(separatedBy: " | ")
        // Pipe *count* turns out to be no signal at all — a 汉语 entry with
        // three example phrases has as many pipes as `word | ipa | definition`.
        // Judge the candidate headword instead: a real one is short and holds
        // no sense markers.
        guard parts.count >= 3,
              parts[0].count <= 24,
              !parts[0].contains(where: isSenseMarker)
        else { return inlineHeader(text, term: term) }
        return (cleanHeadword(parts[0]), parts[1].trimmed,
                parts.dropFirst(2).joined(separator: " | "))
    }

    /// Recovers a header from entries that have no pipes at all.
    ///
    /// Two shapes turn up. `word reading ①… ②…` is the Chinese-dictionary
    /// standard, and everything before the first sense marker is the header.
    /// But a simple word gets a single unnumbered line —
    /// `查找 cházhǎo 动 寻找。查找丢失的文件` — and that shape used to fall
    /// through every branch here and come back with no headword at all, which
    /// `parse` then filled in with the entire text. The card printed the same
    /// sentence twice: once at 21pt as the headword, once underneath as the
    /// definition.
    ///
    /// The looked-up term settles it without any guessing. An entry opens with
    /// its headword, so when the text starts with the word we asked about,
    /// that word *is* the headword and everything after it is the entry.
    private static func inlineHeader(_ text: String, term: String) -> (String?, String?, String) {
        if !term.isEmpty, text.count > term.count,
           text.prefix(term.count).lowercased() == term.lowercased() {
            // Keep the dictionary's own spelling of the headword, not the
            // user's — it may differ in case.
            let head = String(text.prefix(term.count))
            let rest = String(text.dropFirst(term.count)).trimmed
            // Only a CJK headword is followed by a bare reading. After a Latin
            // one, `word word …` is ordinary prose, and `looksLikeReading`
            // cannot tell pinyin from "The" — every Latin entry that carries a
            // reading states it between pipes anyway.
            let (reading, body) = head.contains(where: isCJK)
                ? splitReading(rest)
                : (nil, rest)
            return (cleanHeadword(head), reading, body)
        }

        guard let markerIndex = text.firstIndex(where: isSenseMarker) else {
            return titledParagraph(text)
        }
        let prefix = text[..<markerIndex]
        guard prefix.count <= 24 else { return (nil, nil, text) }

        var tokens = prefix.split(whereSeparator: \.isWhitespace)
        guard let head = tokens.first else { return (nil, nil, text) }
        tokens.removeFirst()

        let (reading, leftover) = splitReading(tokens.joined(separator: " "))
        let rest = String(text[markerIndex...])
        return (
            cleanHeadword(String(head)),
            reading,
            leftover.isEmpty ? rest : leftover + " " + rest
        )
    }

    /// Peels the reading off the front of whatever follows the headword.
    ///
    /// Pinyin sits directly after the headword, sometimes behind a homograph
    /// index (一 1 yī). Grammatical labels — 〈文〉, 动, 名 — do not, and belong
    /// with the definition. Only the front of the string is consumed, so a
    /// multi-line body keeps its line breaks.
    private static func splitReading(_ text: String) -> (String?, String) {
        var rest = Substring(text)
        var reading: [String] = []
        while true {
            let trimmed = rest.drop(while: \.isWhitespace)
            let token = trimmed.prefix { !$0.isWhitespace }
            guard !token.isEmpty,
                  looksLikeReading(token) || isHomographIndex(token) else { break }
            if looksLikeReading(token) { reading.append(String(token)) }
            rest = trimmed.dropFirst(token.count)
        }
        return (reading.isEmpty ? nil : reading.joined(separator: " "),
                String(rest).trimmed)
    }

    /// Han characters. Used to decide whether a bare Latin token after the
    /// headword can be read as pinyin.
    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x3400...0x4DBF).contains(scalar.value)    // Ext A
            || (0x4E00...0x9FFF).contains(scalar.value)    // URO
            || (0xF900...0xFAFF).contains(scalar.value)    // Compatibility
    }

    /// Glossary-style entries — the ones Apple ships for its own terminology —
    /// have no pipes, no markers and no reading, just a title line and a
    /// paragraph. Without this the whole paragraph becomes the headword and is
    /// set at 21pt.
    private static func titledParagraph(_ text: String) -> (String?, String?, String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2, lines[0].count <= 60 else { return (nil, nil, text) }
        return (String(lines[0]).trimmed, nil, lines.dropFirst().joined(separator: "\n"))
    }

    /// `一 1 yī` — the bare number distinguishes homographs, it is not a sense.
    private static func isHomographIndex(_ token: Substring) -> Bool {
        token.count <= 2 && token.allSatisfy(\.isNumber)
    }

    /// Latin letters, including the diacritics pinyin uses. Deliberately
    /// excludes CJK and Bopomofo, which are definition text, not a reading.
    private static func looksLikeReading(_ token: Substring) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isAlphabetic && scalar.value < 0x0250
        }
    }

    /// Chinese dictionaries interleave Bopomofo into the headword and then
    /// repeat it — 你好 comes back as `你ㄋㄧˇ好ㄏㄠˇ ㄋㄧˇ ㄏㄠˇ`. The reading is
    /// already carried by the pronunciation field, so drop it and keep the
    /// characters.
    private static func cleanHeadword(_ raw: String) -> String {
        let stripped = String(raw.unicodeScalars.filter { !isPhoneticAnnotation($0) })
        let collapsed = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? raw.trimmed : collapsed
    }

    private static func isPhoneticAnnotation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3100...0x312F, 0x31A0...0x31BF:  // Bopomofo (+ Extended)
            true
        case 0x02C7, 0x02CA, 0x02CB, 0x02D9:    // ˇ ˊ ˋ ˙ tone marks
            true
        default:
            false
        }
    }

    // MARK: Splitting the body

    /// Puts a line break in front of every boundary the dictionary marks but
    /// does not punctuate: sense numbers, section headings and `A.`-style
    /// part-of-speech blocks.
    private static func breakUp(_ body: String) -> String {
        // Whatever pipes survive here separate example phrases.
        var result = ""
        for character in body.replacingOccurrences(of: " | ", with: "；") {
            if isSenseMarker(character), !result.isEmpty, !result.hasSuffix("\n") {
                result += "\n"
            }
            result.append(character)
        }

        for marker in sectionTitles {
            result = result.replacingOccurrences(of: " \(marker) ", with: "\n\(marker) ")
        }
        result = breakBeforeGroups(result)

        return result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Inserts a break before ` A. `, ` B. ` and so on.
    ///
    /// Requires the letter to follow whitespace or a line start: without that,
    /// the `A.` inside an abbreviation such as `U.S.A. troops` would split the
    /// word it belongs to.
    private static func breakBeforeGroups(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let atBoundary = result.isEmpty || result.last!.isWhitespace
            if atBoundary, groupLetters.contains(character),
               index + 2 < characters.count,
               characters[index + 1] == ".", characters[index + 2] == " " {
                if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
                result.append(character)
                result.append(".")
                result.append(" ")
                index += 3
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    /// ①–⑳ plus the parenthesised ⑴–⒇ some dictionaries prefer.
    static func isSenseMarker(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return false }
        return (0x2460...0x2473).contains(scalar.value)   // ① … ⑳
            || (0x2474...0x2487).contains(scalar.value)   // ⑴ … ⒇
            || (0x3280...0x3289).contains(scalar.value)   // ㊀ … ㊉ (sub-notes)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

import Foundation

/// A parsed Dictionary.app entry.
///
/// The provider used to hand the card a Markdown blob. Structure survives the
/// trip instead, so the card can give the headword, the reading, each sense and
/// each trailing note their own typography rather than rendering one grey wall
/// of text.
struct DictionaryEntry: Sendable, Equatable {
    struct Sense: Sendable, Equatable, Identifiable {
        let id: Int
        var marker: String          // ① ⑵ ㊀
        var partOfSpeech: String?   // 动 / 名 — the one-character CJK labels
        var text: String
        /// Usage examples, which the dictionary runs into the definition behind
        /// a ▸. A long entry is mostly examples, so leaving them inline turns
        /// one sense into a paragraph.
        var examples: [String] = []
    }

    /// A part-of-speech block — the `A. noun … B. transitive verb …` divisions
    /// that bilingual entries use before they start numbering senses.
    ///
    /// Entries without them still get exactly one group, with no label, so the
    /// view never needs two code paths.
    struct Group: Sendable, Equatable, Identifiable {
        let id: Int
        var label: String?          // noun / transitive verb / exclamation
        /// Text belonging to the block itself rather than to a numbered sense —
        /// either a short gloss (`A. noun 问候`) or an inflection note
        /// (`past tense, past participle set`).
        var body: String?
        var senses: [Sense]
    }

    struct Note: Sendable, Equatable, Identifiable {
        let id: Int
        var title: String           // 用法说明 / ORIGIN / PHRASAL VERBS
        var body: String
    }

    var headword: String
    var pronunciation: String?
    /// Whatever sits between the headword and the first sense — "noun formal"
    /// in English entries, 〈文〉-style register labels in Chinese ones.
    var lead: String?
    var groups: [Group]
    var notes: [Note]

    var senses: [Sense] { groups.flatMap(\.senses) }

    /// Entries with no numbered senses (短语、简单词条) still need a body.
    var isStructured: Bool {
        !senses.isEmpty || !notes.isEmpty || groups.contains { $0.label != nil }
    }

    /// Whether the entry is written in the language the reader asked for.
    ///
    /// Bilingual dictionaries gloss into the target language; monolingual ones
    /// do not, and the system decides which of the two answers.
    func answers(in target: Language) -> Bool {
        target == .auto || target.appears(in: bodyText)
    }

    /// Everything except the headword and the reading — the part that has to
    /// be in the reader's language for the entry to count as an answer.
    ///
    /// The headword is excluded because it is the *query*: a 汉语 entry for
    /// 查找 repeats 查找 throughout, which would make it look like a Chinese
    /// answer to any test that counted it.
    var bodyText: String {
        var parts: [String] = []
        if let lead { parts.append(lead) }
        for group in groups {
            if let label = group.label { parts.append(label) }
            if let body = group.body { parts.append(body) }
            for sense in group.senses {
                parts.append(sense.text)
                parts.append(contentsOf: sense.examples)
            }
        }
        parts.append(contentsOf: notes.map(\.body))
        return parts.joined(separator: " ")
    }

    /// What Copy puts on the pasteboard and what Speak reads aloud — the card
    /// renders structure, but those two want ordinary text.
    var plainText: String {
        var parts: [String] = []
        parts.append(pronunciation.map { "\(headword)  \($0)" } ?? headword)
        if let lead { parts.append(lead) }
        for group in groups {
            if let label = group.label { parts.append("[\(label)]") }
            if let body = group.body, !body.isEmpty { parts.append(body) }
            for sense in group.senses {
                let pos = sense.partOfSpeech.map { "[\($0)] " } ?? ""
                parts.append("\(sense.marker) \(pos)\(sense.text)")
                parts.append(contentsOf: sense.examples.map { "    \($0)" })
            }
        }
        for note in notes { parts.append("\(note.title)\n\(note.body)") }
        return parts.joined(separator: "\n")
    }
}

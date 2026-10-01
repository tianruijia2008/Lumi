import Foundation

/// Everything the 词源 page shows about one word, as read from Wiktionary.
///
/// Every field is something a source said. Nothing here is generated — the
/// narration, which is, lives beside the entry rather than inside it, so the
/// facts can be cached, shown and trusted without it.
struct EtymologyEntry: Codable, Sendable, Equatable {
    var word: String
    var ipa: String?
    /// Wiktionary's own heading, e.g. "Adjective".
    var partOfSpeech: String?
    /// Oldest first. The last node is the word as used today.
    var chain: [EtymNode] = []
    /// Origins people repeat that the source marks as wrong.
    var folk: [FolkClaim] = []
    var senses: [Sense] = []
    var quotes: [Quote] = []
    var kin: [KinGroup] = []
    /// Wiktionary pages this entry was read from, for the sources box.
    var pages: [String] = []
    var fetched = Date()
    /// Which language the `…Local` fields are in. A cached entry translated
    /// for a Chinese reader must not be served, untranslated, to anyone else.
    var localLanguage: String?
    /// Which engine produced `Quote.translation`, so switching engines knows
    /// whether the translations on screen are the ones asked for.
    var quoteTranslator: String?
    var kinLoaded = false
    /// The model's prose, kept so a revisit does not pay for it twice. Stored
    /// with the name of whoever wrote it, which the page prints under it.
    var narration: String?
    var narrator: String?
    /// Bumped whenever parsing or localising changes, so an entry cached by
    /// an older build is fetched again rather than shown half-upgraded.
    var schema: Int?
    static let currentSchema = 3
    /// The headword itself, translated — "肌肉", "鹿". What the word means
    /// *now* in one or two characters, which no definition's first clause
    /// manages for a noun ("动物用来影响运动的收…").
    var wordLocal: String?

    /// The present-day end of every one-line summary.
    var nowGloss: String? { wordLocal ?? senses.first?.shownLabel }

    var datedSenses: [Sense] { senses.filter { $0.start != nil } }

    /// The oldest ancestor someone actually wrote down, on the main line.
    ///
    /// A step that carries addends is a *part* of the next step — `sciō` in
    /// `ne + sciō → nescius` — so the story starts at the compound instead:
    /// "不知道的 → 令人愉快" is the history, "知道 → 令人愉快" is not.
    var oldestRecorded: EtymNode? {
        guard let index = chain.firstIndex(where: { !$0.isReconstructed && !$0.isToday }) else { return nil }
        if !chain[index].addends.isEmpty, index + 1 < chain.count, !chain[index + 1].isToday {
            return chain[index + 1]
        }
        return chain[index]
    }

    /// "不知道的 → 令人愉快" — the whole story in one line, for the sidebar,
    /// the cards and the panel.
    var hook: String? { arc.map { "\($0.from) → \($0.to)" } }

    /// The two ends of the story. The old end is the ancestor's meaning when
    /// that differs from today's, and its spelling otherwise — Latin
    /// `mūsculus` is glossed "a muscle", and "肌肉 → 肌肉" says nothing that
    /// "mūsculus → 肌肉" does not say better.
    var arc: (from: String, fromIsForm: Bool, to: String)? {
        guard let oldest = oldestRecorded, let now = nowGloss.map({ Self.clip($0) }) else { return nil }
        if let gloss = oldest.shownGloss.map({ Self.clip($0) }), gloss != now {
            return (gloss, false, now)
        }
        return (oldest.form, true, now)
    }

    /// When the word is first dated in English, as "14 世纪".
    @MainActor
    var firstCentury: String? {
        guard let start = senses.compactMap(\.start).min() else { return nil }
        let century = start / 100 + 1
        if Localization.shared.language == .en { return "\(century)\(Self.ordinalSuffix(century)) century" }
        return "\(century) 世纪"
    }

    /// English ordinal suffix (21st, not 21th). `String(format:)` cannot make
    /// ordinals, so this one label is handled here rather than in the table.
    private static func ordinalSuffix(_ n: Int) -> String {
        switch n % 100 { case 11, 12, 13: return "th"; default: break }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }

    @MainActor
    var partOfSpeechLocal: String? {
        guard let partOfSpeech else { return nil }
        // 词性名是"维基给的英文 token → 本地名称"的映射，不是句子文案，
        // 所以按界面语言选一张表（与 LanguageNames 同一个做法），
        // 而不是走 t() 的句子表——那样 key 是变量，守卫看不见、也查不出漏译。
        let table = Localization.shared.language == .en ? Self.partsOfSpeechEnglish
                                                        : Self.partsOfSpeechChinese
        return table[partOfSpeech] ?? partOfSpeech.lowercased()
    }

    /// Senses no longer in ordinary use, against the whole list.
    var goneCount: Int { senses.count { $0.status != .alive } }

    static func clip(_ text: String, to limit: Int = 8) -> String {
        let first = text.split(whereSeparator: { "，,；;、".contains($0) }).first.map(String.init) ?? text
        return first.count > limit ? String(first.prefix(limit)) + "…" : first
    }

    /// 维基词典用的英文词性 token → 中文名。**不要**把这张表并进 `t()` 的句子表。
    private static let partsOfSpeechChinese = [
        "Adjective": "形容词", "Noun": "名词", "Verb": "动词", "Adverb": "副词",
        "Pronoun": "代词", "Preposition": "介词", "Conjunction": "连词", "Interjection": "感叹词",
        "Determiner": "限定词", "Numeral": "数词", "Proper noun": "专有名词",
        "Prefix": "前缀", "Suffix": "后缀", "Phrase": "短语",
    ]

    /// 同一批 token 的英文名。小写，因为词源页里它跟在词头后面（"serendipity — noun"）。
    private static let partsOfSpeechEnglish = [
        "Adjective": "adjective", "Noun": "noun", "Verb": "verb", "Adverb": "adverb",
        "Pronoun": "pronoun", "Preposition": "preposition", "Conjunction": "conjunction",
        "Interjection": "interjection", "Determiner": "determiner", "Numeral": "numeral",
        "Proper noun": "proper noun", "Prefix": "prefix", "Suffix": "suffix", "Phrase": "phrase",
    ]

    /// 中文名表里用到的那批 key（供人对照；真正的查表在 `partOfSpeechLocal`）。
    static let partsOfSpeechKeys = partsOfSpeechChinese.values.sorted()
}

struct EtymNode: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var lang: String
    var form: String
    var gloss: String?
    var glossLocal: String?
    /// Parts joined onto this node on the way to the next one — the `ne` in
    /// `ne + sciō → nescius`. Drawn on the link, not as nodes of their own,
    /// because they are side branches rather than steps.
    var addends: [Part] = []
    /// The final node: the word itself, as used now.
    var isToday = false

    var isReconstructed: Bool { form.hasPrefix("*") || LanguageNames.isProto(lang) }
    @MainActor var language: String { LanguageNames.name(lang) }
    var shownGloss: String? { glossLocal ?? gloss }
}

struct Part: Codable, Sendable, Equatable {
    var lang: String
    var form: String
    var gloss: String?
    var glossLocal: String?
    var shownGloss: String? { glossLocal ?? gloss }
}

struct FolkClaim: Codable, Sendable, Equatable {
    var parts: [Part]
    /// The source's own sentence, kept so the claim is never paraphrased into
    /// something stronger than what was said.
    var sourceSentence: String
}

enum SenseStatus: String, Codable, Sendable {
    case alive, fading, dead

    @MainActor
    var label: String {
        switch self {
        case .alive:  t("还在用")
        case .fading: t("渐少")
        case .dead:   t("已不用")
        }
    }
}

struct Sense: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var text: String
    /// The definition's first clause — short enough to label a timeline lane.
    var label: String
    var labelLocal: String?
    var textLocal: String?
    /// Years, from Wiktionary's century-grained `defdate`. `end == nil` with a
    /// `start` means still attested.
    var start: Int?
    var end: Int?
    var status: SenseStatus
    /// The source's own register label ("obsolete", "now rare"), untranslated.
    var tags: [String] = []

    var shownLabel: String { labelLocal ?? label }
}

struct Quote: Codable, Sendable, Equatable, Identifiable {
    /// 1-based and in date order — the number printed in the circles.
    var id: Int
    var year: Int?
    var approximate = false
    /// The passage with the headword wrapped in `**`.
    var passage: String
    var author: String?
    var title: String?
    var senseID: Int?
    var translation: String?

    /// The passage with the markers removed, for translating and copying.
    var plainPassage: String { passage.replacingOccurrences(of: "**", with: "") }
}

struct KinGroup: Codable, Sendable, Equatable, Identifiable {
    var root: String
    var gloss: String?
    var glossLocal: String?
    var words: [KinWord]
    var id: String { root }
}

struct KinWord: Codable, Sendable, Equatable, Identifiable {
    var word: String
    var gloss: String?
    var id: String { word }
}

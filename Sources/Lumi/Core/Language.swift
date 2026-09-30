import Foundation
import NaturalLanguage

enum Language: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case auto
    case simplifiedChinese  = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english            = "en"
    case japanese           = "ja"
    case korean             = "ko"
    case french             = "fr"
    case german             = "de"
    case spanish            = "es"
    case italian            = "it"
    case portuguese         = "pt"
    case russian            = "ru"
    case arabic             = "ar"

    var id: String { rawValue }

    /// Bridges to Apple's Translation + Locale APIs. `nil` means "let the
    /// framework decide", which is exactly what `.auto` should do.
    var localeLanguage: Locale.Language? {
        self == .auto ? nil : Locale.Language(identifier: rawValue)
    }

    var displayName: String {
        switch self {
        case .auto:               "自动检测"
        case .simplifiedChinese:  "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english:            "English"
        case .japanese:           "日本語"
        case .korean:             "한국어"
        case .french:             "Français"
        case .german:             "Deutsch"
        case .spanish:            "Español"
        case .italian:            "Italiano"
        case .portuguese:         "Português"
        case .russian:            "Русский"
        case .arabic:             "العربية"
        }
    }

    /// Used in LLM prompts, where English names steer the model most reliably.
    var promptName: String {
        switch self {
        case .auto:               "the source language"
        case .simplifiedChinese:  "Simplified Chinese"
        case .traditionalChinese: "Traditional Chinese"
        case .english:            "English"
        case .japanese:           "Japanese"
        case .korean:             "Korean"
        case .french:             "French"
        case .german:             "German"
        case .spanish:            "Spanish"
        case .italian:            "Italian"
        case .portuguese:         "Portuguese"
        case .russian:            "Russian"
        case .arabic:             "Arabic"
        }
    }

    var isChinese: Bool { self == .simplifiedChinese || self == .traditionalChinese }

    static func detect(_ text: String) -> Language {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return .english }

        var detected = Language(rawValue: dominant.rawValue)
        if detected == nil {
            let base = dominant.rawValue.split(separator: "-").first.map(String.init) ?? ""
            detected = base == "zh" ? .simplifiedChinese : Language(rawValue: base)
        }
        guard let detected else { return .english }

        // NLLanguageRecognizer leans Traditional on short Chinese input — it
        // calls 你好 zh-Hant even though those characters are identical in both
        // scripts. Confirm with the text itself: if a Traditional→Simplified
        // conversion changes nothing, there are no Traditional-only characters.
        if detected == .traditionalChinese, !containsTraditionalOnlyCharacters(text) {
            return .simplifiedChinese
        }
        return detected
    }

    private static func containsTraditionalOnlyCharacters(_ text: String) -> Bool {
        guard let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false)
        else { return false }
        return simplified != text
    }

    /// Picks the direction from the user's language pair.
    ///
    /// Text in the first language goes to the second and vice versa, so one
    /// shortcut covers both directions without ever touching a picker. Chinese
    /// variants count as one language here: asking a translator for
    /// 简体 → 繁體 is not what pressing the hot-key on Chinese text meant.
    static func target(for source: Language, first: Language, second: Language) -> Language {
        sameLanguage(source, first) ? second : first
    }

    static func sameLanguage(_ a: Language, _ b: Language) -> Bool {
        a == b || (a.isChinese && b.isChinese)
    }

    /// Whether `text` contains any writing in this language's script.
    ///
    /// A script test, not a language test: it cannot tell French from Spanish,
    /// and is not meant to. What it answers is the one question a Latin/Han
    /// mismatch makes worth asking — did this text come back in the writing
    /// system the reader asked for, or in a different one entirely.
    /// Whether this language is normally written in Han characters.
    ///
    /// Japanese is deliberately excluded even though it uses them: its kana
    /// make its text expand and contract unlike Chinese, so the length ratios
    /// that depend on this would be wrong for it.
    var isHanScript: Bool {
        self == .simplifiedChinese || self == .traditionalChinese
    }

    func appears(in text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch self {
            case .auto:
                true
            case .simplifiedChinese, .traditionalChinese:
                Self.isHan(scalar)
            case .japanese:
                Self.isHan(scalar) || (0x3040...0x30FF).contains(scalar.value)
            case .korean:
                (0xAC00...0xD7AF).contains(scalar.value)
                    || (0x1100...0x11FF).contains(scalar.value)
            case .russian:
                (0x0400...0x04FF).contains(scalar.value)
            case .arabic:
                (0x0600...0x06FF).contains(scalar.value)
                    || (0x0750...0x077F).contains(scalar.value)
            case .english, .french, .german, .spanish, .italian, .portuguese:
                scalar.properties.isAlphabetic && scalar.value < 0x0250
            }
        }
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
    }
}

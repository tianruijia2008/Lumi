import Foundation

// Did anything go missing?
/// Catches segments the translator quietly shortened or skipped.
///
/// This exists because silent omission is measurably the normal failure of
/// machine translation on paper prose, not a rare one. Measured on this
/// machine: NLLB-200 3.3B asked to translate "train for 50 epochs with a
/// cosine schedule" returned "训练50个时代" — fluent, plausible, and missing
/// the schedule entirely. Nothing in the output says so. A reader comparing
/// columns would have to already know the source to notice.
///
/// The checks are ordered by how much they can be trusted.
enum DropCheck {
    /// Numbers and all-caps tokens survive translation unchanged, which makes
    /// them the only content that can be checked for by identity rather than by
    /// guesswork. If the source says 2.4 and the translation does not, a claim
    /// went missing — regardless of language pair.
    ///
    /// Deliberately not a general word check: ordinary words legitimately
    /// disappear in translation all the time.
    static func missingTokens(source: String, translation: String) -> [String] {
        let wanted = anchors(in: source).subtracting(rescaled(in: source))
        guard !wanted.isEmpty else { return [] }
        let have = anchors(in: translation)
        return wanted.filter { !have.contains($0) }
    }

    /// Numbers that a correct translation is *expected* to rewrite.
    ///
    /// Chinese counts in 万 and 亿, so "1.2 million sentence pairs" becomes
    /// "120万个句子对" — the claim survives intact while the digits do not.
    /// Measured: this was the only false positive in 25 correct translations of
    /// paper prose, and it would have recurred on every paper that reports a
    /// dataset size.
    static func rescaled(in text: String) -> Set<String> {
        let magnitudes: Set<String> = [
            "hundred", "thousand", "million", "billion", "trillion",
            "hundreds", "thousands", "millions", "billions", "trillions",
            "k", "m", "bn",
        ]
        var excluded: Set<String> = []
        // The suffixed spelling of the same thing — 120k, 1.2M, 3B — is
        // rewritten just the same: "120k sentence pairs" is 12 万个句子对.
        for anchor in anchors(in: text)
        where anchor.wholeMatch(of: /\d+(\.\d+)?(k|m|b|bn)/) != nil {
            excluded.insert(anchor)
        }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        for (offset, word) in words.enumerated() where offset > 0 {
            let bare = word.lowercased().trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted)
            guard magnitudes.contains(bare) else { continue }
            excluded.formUnion(anchors(in: String(words[offset - 1])))
        }
        return excluded
    }

    /// Digits-with-punctuation runs (3e-4, 2.4, 50) and acronyms (BLEU, A100,
    /// GPU). Both are reproduced verbatim by any translation worth reading.
    static func anchors(in text: String) -> Set<String> {
        var found: Set<String> = []
        var current = ""
        var sawDigit = false

        func flush() {
            defer { current = ""; sawDigit = false }
            let token = current.trimmingCharacters(in: CharacterSet(charactersIn: ".,-–—:;"))
            guard token.count >= 2 else { return }
            if sawDigit {
                found.insert(token.lowercased())
            } else if token.count >= 3, token.count <= 6, token == token.uppercased(),
                      token.contains(where: { $0.isLetter }) {
                // An acronym. Two letters is too short — "We" at the start of a
                // sentence would qualify. Seven is too long: papers that set
                // their headings in caps would have every INTRODUCTION flagged
                // as missing from a translation that correctly says 引言.
                found.insert(token.lowercased())
            }
        }

        for ch in text {
            if ch.isNumber {
                sawDigit = true
                current.append(ch)
            } else if ch.isLetter && ch.isASCII {
                current.append(ch)
            } else if ".,-–—:;".contains(ch), !current.isEmpty {
                // Kept inside the token so 3e-4 and 2.4 stay whole; trimmed off
                // the ends by `flush`.
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return found
    }

    /// How much shorter than expected the translation came out.
    ///
    /// Returns nil when the pair has no reliable expectation. Ratios are
    /// measured in characters, so they are a property of the *scripts*
    /// involved, not of the languages: Han script packs roughly two English
    /// words into two characters, and any ratio derived from that is only
    /// meaningful when one side is Han and the other is not.
    static func shortfall(source: String, translation: String,
                          from: Language, to: Language) -> Double? {
        let ws = CharacterSet.whitespacesAndNewlines
        let src = Double(source.trimmingCharacters(in: ws).count)
        let out = Double(translation.trimmingCharacters(in: ws).count)
        guard src > 40 else { return nil }   // too short to judge
        // Measured, not estimated. 25 sentences of paper prose through the
        // on-device translator, English → Chinese: min 0.235, median 0.295,
        // p90 0.364. 15 sentences Chinese → English: min 3.26, median 3.91,
        // p90 4.30. The first draft of this function guessed 0.42 and 2.1,
        // which would have flagged nearly every correct English → Chinese
        // translation as a dropped one and never flagged a Chinese → English
        // drop at all.
        let expected: Double
        switch (from.isHanScript, to.isHanScript) {
        case (false, true): expected = 0.295
        case (true, false): expected = 3.9
        default: return nil
        }
        let ratio = out / (src * expected)
        return ratio < 1 ? 1 - ratio : 0
    }
}

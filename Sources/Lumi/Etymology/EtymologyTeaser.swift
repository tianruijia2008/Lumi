import Foundation

/// The panel's one line of history: three steps at most.
///
/// The oldest ancestor someone wrote down, the word's first meaning in
/// English when that meaning has since died, and what it means now. Enough to
/// make the change visible — "不知道的 → 愚蠢 → 令人愉快" — and short enough
/// to sit under a dictionary entry without competing with it.
struct EtymologyTeaser: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        var language: String?
        var form: String
        var gloss: String?
    }

    let word: String
    let steps: [Step]

    init?(_ entry: EtymologyEntry) {
        guard let oldest = entry.oldestRecorded, oldest.lang != "en" else { return nil }
        var steps = [Step(language: oldest.language, form: oldest.form,
                          gloss: oldest.shownGloss.map { EtymologyEntry.clip($0) })]
        let firstEnglish = entry.datedSenses.min { ($0.start ?? 0, $0.id) < ($1.start ?? 0, $1.id) }
        if let firstEnglish, firstEnglish.status == .dead, firstEnglish.id != entry.senses.first?.id {
            steps.append(Step(form: entry.word, gloss: EtymologyEntry.clip(firstEnglish.shownLabel)))
        }
        guard let now = entry.nowGloss else { return nil }
        steps.append(Step(form: entry.word, gloss: EtymologyEntry.clip(now)))
        self.word = entry.word
        self.steps = steps
    }
}

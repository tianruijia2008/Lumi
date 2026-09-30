import Foundation

/// Cuts a pasted document into the units the workbench aligns.
///
/// Alignment is the whole point of the window — a segment that comes back
/// empty is a sentence the model dropped, and that is only visible if the
/// segments are stable and meaningful. Which makes the cut itself load-bearing.
///
/// The hard part is not the cutting, it is the *un*-cutting. Text copied out of
/// a PDF arrives hard-wrapped at the column the typesetter chose, so a single
/// sentence is spread over four lines. Segment on those and every "paragraph"
/// is a fragment. So lines are rejoined first, and only the breaks that survive
/// become segment boundaries.
enum Segmenter {
    /// Paragraphs longer than this are split further at sentence ends. A
    /// segment the reader has to scroll past defeats side-by-side alignment.
    static let maxSegmentLength = 1200

    static func segments(of raw: String) -> [String] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // A blank line is the one break a typesetter never inserts by accident,
        // so it is the only break taken at face value.
        var blocks: [[String]] = [[]]
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { blocks.append([]) } else { blocks[blocks.count - 1].append(trimmed) }
        }

        return blocks
            .filter { !$0.isEmpty }
            .flatMap { unwrap($0).components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap(split(long:))
    }

    // MARK: Rejoining hard-wrapped lines

    private static func unwrap(_ lines: [String]) -> String {
        guard var result = lines.first else { return "" }

        for line in lines.dropFirst() {
            guard let last = result.last else { result = line; continue }
            if last == "-" || last == "\u{00AD}" {
                // A word broken across lines by hyphenation: the hyphen is
                // typography, not spelling.
                result.removeLast()
                result += line
            } else if continues(after: last, with: line) {
                result += isCJK(last) || isCJK(line.first) ? line : " " + line
            } else {
                result += "\n" + line
            }
        }
        return result
    }

    /// Whether a line break is mid-sentence rather than a real one.
    ///
    /// Judged from both sides: a line that ends mid-clause is a wrap, and so is
    /// a line whose successor opens in lower case. A line that ends in a full
    /// stop *and* is followed by something that looks like a new sentence is
    /// left alone — that is the case where the typesetter's break and the
    /// author's agree.
    private static func continues(after last: Character, with next: String) -> Bool {
        guard let first = next.first else { return false }
        // A bullet, a number or a heading marker starts something new whatever
        // came before it.
        if "•–—*·".contains(first) || first.isNumber { return false }
        if sentenceEnders.contains(last) {
            return first.isLowercase
        }
        return true
    }

    private static let sentenceEnders: Set<Character> =
        [".", "!", "?", "。", "！", "？", "…", "”", "\"", "」", "』"]

    private static func isCJK(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        return Language.isHan(scalar)
            || (0x3040...0x30FF).contains(scalar.value)
            || (0x3000...0x303F).contains(scalar.value)   // CJK punctuation
    }

    // MARK: Splitting over-long paragraphs

    static func split(long paragraph: String) -> [String] {
        guard paragraph.count > maxSegmentLength else { return [paragraph] }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences(of: paragraph) {
            if !current.isEmpty, current.count + sentence.count > maxSegmentLength {
                chunks.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            current += sentence
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks.isEmpty ? [paragraph] : chunks
    }

    /// Keeps the terminator with the sentence it ends.
    ///
    /// Two cheap guards, not a real sentence tokeniser: a full stop inside a
    /// decimal is not followed by a space, and a new sentence does not open in
    /// lower case, which covers `62.5 %` and `et al. and then`. `Dr. Smith`
    /// still splits — and that is deliberately left alone, because this runs
    /// only inside paragraphs already over 1200 characters, where a boundary
    /// in an odd place costs a slightly short segment and nothing else.
    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard sentenceEnders.contains(character) else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            guard next.isWhitespace || isCJK(next) else { continue }
            if let opener = characters[(index + 1)...].first(where: { !$0.isWhitespace }),
               opener.isLowercase { continue }
            result.append(current)
            current = ""
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

import Foundation
import SwiftUI

/// What a segment is, structurally. Plain text is all `.paragraph`; Markdown
/// brings the rest.
///
/// The segment's text never carries its own block syntax — a heading is kept
/// as "Getting Started", not "## Getting Started". Engines then translate the
/// words and nothing else, alignment compares like with like, and the syntax
/// is put back once, on export, from this.
enum SegmentBlock: Codable, Hashable, Sendable {
    case paragraph
    case heading(level: Int)
    /// `marker` is what opened the item — "-", "*", "3.", "- [ ]".
    case listItem(marker: String, depth: Int)
    case quote
    /// Kept whole, pipes and all: a table translated cell by cell loses the
    /// row it belongs to.
    case table
    /// Fenced code, or a `$$` maths block. Never translated.
    case code(language: String)
    /// A paragraph that is only an image. Never translated.
    case image(alt: String, source: String)
    case rule
    /// Front matter, raw HTML, link reference definitions: kept as written.
    case verbatim

    /// Blocks that pass through untouched. They cost nothing, are never
    /// judged, and are shown once across both columns.
    var isVerbatim: Bool {
        switch self {
        case .code, .image, .rule, .verbatim: true
        default: false
        }
    }

    var isHeading: Bool { if case .heading = self { true } else { false } }
    var isListItem: Bool { if case .listItem = self { true } else { false } }

    /// A model told "this is a level-2 heading" sometimes answers
    /// "## 标题". Segment text never carries its block syntax — export adds
    /// it back — so an echoed marker would print twice. Only stripped when
    /// the source does not itself begin that way.
    func strippingEchoedSyntax(_ text: String, source: String) -> String {
        let pattern: String
        switch self {
        case .heading: pattern = #"^#{1,6}[ \t]+"#
        case .listItem: pattern = #"^(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"#
        case .quote: pattern = #"(?m)^>[ \t]?"#
        default: return text
        }
        guard source.range(of: pattern, options: .regularExpression) == nil else { return text }
        var out = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        if isHeading {
            out = out.replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
        }
        return out
    }

    /// How a prompt describes the segment, so a heading comes back as a
    /// heading rather than as a sentence with a full stop.
    var promptHint: String? {
        switch self {
        case .heading(let level): "a level-\(level) heading"
        case .listItem: "one item of a list"
        case .quote: "a block quotation"
        case .table: "a Markdown table — keep every | and the row structure, translate the cell text"
        default: nil
        }
    }
}

/// How a document was written. Decides how it is cut, drawn and exported.
enum TextFormat: String, Codable, Sendable {
    case plain
    case markdown
}

/// One block of a parsed document, before it becomes a segment.
struct TextBlock: Equatable, Sendable {
    var kind: SegmentBlock
    var text: String
}

/// Cuts a text into blocks, whichever way it was written.
enum DocumentParser {
    static func parse(_ text: String, format hint: TextFormat? = nil) -> (TextFormat, [TextBlock]) {
        let format = hint ?? (Markdown.looksLikeMarkdown(text) ? .markdown : .plain)
        switch format {
        case .plain:
            return (.plain, Segmenter.segments(of: text).map { TextBlock(kind: .paragraph, text: $0) })
        case .markdown:
            return (.markdown, Markdown.blocks(of: text))
        }
    }

    static func isMarkdownFile(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd", "mdx"].contains(url.pathExtension.lowercased())
    }

    /// The title a document gives itself: front matter's `title:`, else its
    /// first heading, else a short opening line.
    static func title(of blocks: [TextBlock], raw: String) -> String? {
        if let fromFrontMatter = Markdown.frontMatterTitle(raw) { return fromFrontMatter }
        for block in blocks.prefix(6) {
            if case .heading(let level) = block.kind, level <= 2 {
                return Markdown.plainText(block.text)
            }
        }
        guard let first = blocks.first(where: { !$0.kind.isVerbatim }) else { return nil }
        let plain = Markdown.plainText(first.text)
        return plain.count <= 90 ? plain : nil
    }
}

enum Markdown {
    // MARK: Detection

    /// Whether a pasted text was written in Markdown.
    ///
    /// Scored, not matched: one "1." at the start of a line is a numbered
    /// paragraph in a PDF, and one pair of asterisks is someone's emphasis.
    /// It takes structure — a heading, a fence, a link — or several weaker
    /// signs together before the text is cut as Markdown.
    static func looksLikeMarkdown(_ text: String) -> Bool {
        var score = 0
        var listLines = 0
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lines += 1
            if lines > 400 { break }
            let s = String(line)
            if s.wholeMatch(of: /\s{0,3}#{1,6}\s+\S.*/) != nil { score += 2 }
            else if s.wholeMatch(of: /\s{0,3}(```|~~~).*/) != nil { score += 2 }
            else if isTableDelimiter(s) { score += 3 }
            else if s.wholeMatch(of: /\s{0,3}>\s?.*/) != nil { score += 1 }
            else if s.wholeMatch(of: /\s*([-*+]|\d{1,3}[.)])\s+\S.*/) != nil { listLines += 1 }
            if s.contains(/!?\[[^\]\n]+\]\([^)\s]+\)/) { score += 2 }
            if s.contains(/\*\*[^*\n]+\*\*|__[^_\n]+__/) { score += 1 }
            if s.contains(/`[^`\n]+`/) { score += 1 }
        }
        score += min(listLines, 2)
        return score >= 3
    }

    // MARK: Blocks

    static func blocks(of raw: String) -> [TextBlock] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [TextBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = joinSoftWrapped(paragraph)
            paragraph = []
            if let image = text.wholeMatch(of: /!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/) {
                blocks.append(TextBlock(kind: .image(alt: String(image.1), source: String(image.2)), text: text))
            } else {
                for piece in Segmenter.split(long: text) {
                    blocks.append(TextBlock(kind: .paragraph, text: piece))
                }
            }
        }

        // Front matter: only at the very top, only when it closes.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().prefix(80).firstIndex(where: {
               ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces))
           }), close > 1 {
            blocks.append(TextBlock(kind: .verbatim, text: lines[0...close].joined(separator: "\n")))
            index = close + 1
        }

        // Indents of the list items open around the current line, so a
        // nested item knows how deep it is whatever its author's indent width.
        var listIndents: [Int] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Fenced code, and $$ maths, which is fenced in all but name.
            if let fence = line.wholeMatch(of: /\s{0,3}(`{3,}|~{3,}|\$\$)\s*([^`\s]*).*/) {
                flushParagraph()
                let opener = String(fence.1)
                let language = opener == "$$" ? "math" : String(fence.2)
                var end = index + 1
                while end < lines.count {
                    let candidate = lines[end].trimmingCharacters(in: .whitespaces)
                    if opener == "$$" ? candidate.hasSuffix("$$")
                                      : candidate.hasPrefix(opener) && candidate.allSatisfy({ $0 == opener.first }) {
                        break
                    }
                    end += 1
                }
                // A one-line $$…$$ closes on itself.
                if opener == "$$", trimmed.count > 2, trimmed.hasSuffix("$$") { end = index }
                let last = min(end, lines.count - 1)
                blocks.append(TextBlock(kind: .code(language: language),
                                        text: lines[index...last].joined(separator: "\n")))
                index = last + 1
                listIndents = []
                continue
            }

            if let heading = line.wholeMatch(of: /\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*/) {
                flushParagraph()
                blocks.append(TextBlock(kind: .heading(level: heading.1.count), text: String(heading.2)))
                index += 1
                listIndents = []
                continue
            }

            // A line of === or --- under a paragraph makes it a heading.
            if !paragraph.isEmpty, paragraph.count == 1,
               let underline = trimmed.wholeMatch(of: /(=+|-+)/) {
                let level = underline.1.first == "=" ? 1 : 2
                blocks.append(TextBlock(kind: .heading(level: level), text: paragraph[0]))
                paragraph = []
                index += 1
                continue
            }

            if trimmed.wholeMatch(of: /([-*_])(\s*\1){2,}/) != nil {
                flushParagraph()
                blocks.append(TextBlock(kind: .rule, text: trimmed))
                index += 1
                listIndents = []
                continue
            }

            if index + 1 < lines.count, line.contains("|"), isTableDelimiter(lines[index + 1]) {
                flushParagraph()
                var end = index + 2
                while end < lines.count,
                      lines[end].contains("|"),
                      !lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                    end += 1
                }
                blocks.append(TextBlock(kind: .table, text: lines[index..<end]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n")))
                index = end
                listIndents = []
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    var inner = current.dropFirst()
                    if inner.first == " " { inner = inner.dropFirst() }
                    let body = inner.trimmingCharacters(in: .whitespaces)
                    if body.isEmpty {
                        // A blank quoted line is a paragraph break inside
                        // the quotation.
                        if !quoted.isEmpty { blocks.append(TextBlock(kind: .quote, text: joinSoftWrapped(quoted))) }
                        quoted = []
                    } else {
                        quoted.append(body)
                    }
                    index += 1
                }
                if !quoted.isEmpty { blocks.append(TextBlock(kind: .quote, text: joinSoftWrapped(quoted))) }
                listIndents = []
                continue
            }

            if let item = line.wholeMatch(of: /(\s*)([-*+]|\d{1,3}[.)])\s+(\[[ xX]\]\s+)?(.*)/) {
                flushParagraph()
                let indent = item.1.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                while let last = listIndents.last, last > indent { listIndents.removeLast() }
                if listIndents.last != indent { listIndents.append(indent) }
                let depth = listIndents.count - 1
                var marker = String(item.2)
                if let task = item.3 { marker += " " + task.trimmingCharacters(in: .whitespaces) }
                var body = [String(item.4)]
                // Continuation lines: indented or lazy, until something that
                // opens a block of its own.
                var next = index + 1
                while next < lines.count {
                    let candidate = lines[next]
                    let bare = candidate.trimmingCharacters(in: .whitespaces)
                    if bare.isEmpty || startsBlock(candidate) { break }
                    body.append(bare)
                    next += 1
                }
                blocks.append(TextBlock(kind: .listItem(marker: marker, depth: depth),
                                        text: joinSoftWrapped(body)))
                index = next
                continue
            }

            if paragraph.isEmpty, trimmed.hasPrefix("<"), isHTMLBlockStart(trimmed) {
                var end = index + 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
                blocks.append(TextBlock(kind: .verbatim, text: lines[index..<end].joined(separator: "\n")))
                index = end
                continue
            }

            if trimmed.wholeMatch(of: /\[[^\]]+\]:\s+\S+.*/) != nil, paragraph.isEmpty {
                var end = index + 1
                while end < lines.count,
                      lines[end].trimmingCharacters(in: .whitespaces).wholeMatch(of: /\[[^\]]+\]:\s+\S+.*/) != nil {
                    end += 1
                }
                blocks.append(TextBlock(kind: .verbatim, text: lines[index..<end]
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")))
                index = end
                continue
            }

            listIndents = []
            // Two trailing spaces or a backslash is a hard break the author
            // asked for; everything else is a soft wrap.
            paragraph.append(line.hasSuffix("  ") || trimmed.hasSuffix("\\")
                             ? trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\\")) + "\u{2028}"
                             : trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return line.wholeMatch(of: /\s*([-*+]|\d{1,3}[.)])\s+.*/) != nil
            || line.wholeMatch(of: /\s{0,3}#{1,6}\s+.*/) != nil
            || line.wholeMatch(of: /\s{0,3}(```|~~~|\$\$).*/) != nil
            || trimmed.hasPrefix(">")
            || trimmed.hasPrefix("|")
    }

    private static let htmlBlockTags: Set<String> = [
        "div", "p", "table", "details", "summary", "section", "figure", "img", "pre",
        "ul", "ol", "center", "picture", "video", "iframe", "br", "hr", "!--", "a", "h1", "h2", "h3",
    ]

    private static func isHTMLBlockStart(_ line: String) -> Bool {
        if line.hasPrefix("<!--") { return true }
        guard let match = line.firstMatch(of: /<\/?([A-Za-z][A-Za-z0-9]*)/) else { return false }
        return htmlBlockTags.contains(match.1.lowercased())
    }

    static func isTableDelimiter(_ line: String) -> Bool {
        line.contains("|")
            && line.wholeMatch(of: /\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*/) != nil
    }

    /// Markdown paragraphs wrap at the author's whim; the words run on.
    /// Chinese and Japanese run on without a space.
    static func joinSoftWrapped(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            if result.isEmpty { result = line; continue }
            if result.hasSuffix("\u{2028}") {
                result.removeLast()
                result += "\n" + line
            } else if isCJK(result.last) || isCJK(line.first) {
                result += line
            } else {
                result += " " + line
            }
        }
        if result.hasSuffix("\u{2028}") { result.removeLast() }
        return result
    }

    private static func isCJK(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        return Language.isHan(scalar)
            || (0x3040...0x30FF).contains(scalar.value)
            || (0x3000...0x303F).contains(scalar.value)
            || (0xFF00...0xFFEF).contains(scalar.value)
    }

    static func frontMatterTitle(_ raw: String) -> String? {
        guard raw.hasPrefix("---") else { return nil }
        for line in raw.split(separator: "\n").dropFirst().prefix(40) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s == "---" || s == "..." { break }
            if let match = s.wholeMatch(of: /title:\s*["']?(.+?)["']?\s*/) {
                return String(match.1)
            }
        }
        return nil
    }

    // MARK: Inline

    /// The words a reader sees: link text without its address, emphasis
    /// without its asterisks, code spans and images gone. What the length
    /// checks should measure, since a URL copied across verbatim says
    /// nothing about whether a sentence was translated.
    static func visibleText(_ text: String) -> String {
        var s = text
        s = s.replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
        s = s.replacing(/`[^`]*`/, with: "")
        s = s.replacing(/\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
        s = s.replacing(/<[^>]+>/, with: "")
        s = s.replacing(/(\*\*|__|\*|_|~~)/, with: "")
        return s
    }

    /// Readable text for places that show no formatting: titles, the sidebar.
    static func plainText(_ text: String) -> String {
        var s = text
        s = s.replacing(/!\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
        s = s.replacing(/\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
        s = s.replacing(/`([^`]*)`/) { String($0.1) }
        s = s.replacing(/(\*\*|__|~~)/, with: "")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Spans that must come through translation character for character.
    static func codeSpans(_ text: String) -> [String] {
        text.matches(of: /`([^`\n]+)`/).map { String($0.1) }
    }

    static func linkTargets(_ text: String) -> [String] {
        text.matches(of: /\]\(([^)\s]+)(?:\s+"[^"]*")?\)/).map { String($0.1) }
    }

    /// Inline Markdown as styled text. Falls back to the raw string rather
    /// than showing nothing when the text does not parse.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var result = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        // Text leaves code spans in the body font; set them apart, since they
        // are the words that must not be translated.
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(size: 12, design: .monospaced)
            result[run.range].backgroundColor = Color.primary.opacity(0.06)
        }
        return result
    }

    // MARK: Protecting syntax from a translator that cannot be told

    /// Swaps code spans and link targets for placeholders the on-device
    /// translator leaves alone.
    ///
    /// Measured on the system translator: `code` came back as “代码” —
    /// translated, and its backticks turned into quotation marks — and a link
    /// came back as [发布页面]（https://…） with full-width parentheses, which
    /// is no longer a link. ⟦0⟧ passed through untouched in every test; `C0`,
    /// the obvious alternative, did not.
    static func mask(_ text: String) -> (String, [String]) {
        var kept: [String] = []
        var s = text.replacing(/`[^`\n]+`/) { match in
            kept.append(String(match.0))
            return "⟦\(kept.count - 1)⟧"
        }
        s = s.replacing(/\]\(([^)\s]+(?:\s+"[^"]*")?)\)/) { match in
            kept.append("(" + String(match.1) + ")")
            return "]⟦\(kept.count - 1)⟧"
        }
        return (s, kept)
    }

    static func unmask(_ text: String, _ kept: [String]) -> String {
        guard !kept.isEmpty else { return text }
        var s = text
        for (index, original) in kept.enumerated().reversed() {
            let token = "⟦\(index)⟧"
            if original.hasPrefix("(") {
                // A link target: close up any space the translator left
                // between the text and its address.
                s = s.replacing(try! Regex("\\]\\s*" + NSRegularExpression.escapedPattern(for: token)), with: "]" + original)
            }
            s = s.replacingOccurrences(of: token, with: original)
        }
        return repairLinks(s)
    }

    /// `]（url）` → `](url)`: the one mangling seen on links that survived
    /// unmasked.
    static func repairLinks(_ text: String) -> String {
        text.replacing(/\]\s*（([^）\s]+)）/) { "](" + String($0.1) + ")" }
    }

    // MARK: Tables

    struct Table {
        var header: [String]
        var rows: [[String]]
    }

    static func table(_ text: String) -> Table? {
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 2, isTableDelimiter(lines[1]) else { return nil }
        let header = cells(lines[0])
        let rows = lines.dropFirst(2).map(cells)
        guard !header.isEmpty else { return nil }
        return Table(header: header, rows: rows.map { row in
            Array((row + Array(repeating: "", count: max(0, header.count - row.count))).prefix(header.count))
        })
    }

    static func cells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var result: [String] = []
        var current = ""
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; current.append(ch); continue }
            if ch == "|" { result.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(ch) }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    // MARK: Writing back

    /// A block with its syntax put back.
    static func render(_ kind: SegmentBlock, _ text: String) -> String {
        switch kind {
        case .table, .code, .image, .rule, .verbatim:
            return text
        case .paragraph:
            // A line break inside a paragraph was a hard break; written back
            // bare it would be read as a soft wrap and run the lines together.
            return text.components(separatedBy: "\n").joined(separator: "  \n")
        case .heading(let level):
            return String(repeating: "#", count: max(1, min(level, 6))) + " " + text
        case .listItem(let marker, let depth):
            let indent = String(repeating: "  ", count: depth)
            let hang = String(repeating: " ", count: marker.count + 1)
            let lines = text.components(separatedBy: "\n")
            return lines.enumerated().map { offset, line in
                offset == 0 ? indent + marker + " " + line : indent + hang + line
            }.joined(separator: "\n")
        case .quote:
            return text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "  \n")
        }
    }

    /// Consecutive items belong to one list unless a top-level item switches
    /// between numbers and bullets — which in the source was two lists.
    private static func sameList(_ a: SegmentBlock, _ b: SegmentBlock) -> Bool {
        guard case .listItem(let first, _) = a, case .listItem(let second, let depth) = b else { return false }
        guard depth == 0 else { return true }
        return (first.first?.isNumber ?? false) == (second.first?.isNumber ?? false)
    }

    /// A whole document, blank line between blocks — except between the
    /// items of one list, which Markdown would otherwise render loose.
    static func join(_ blocks: [(SegmentBlock, String)]) -> String {
        var out = ""
        var previous: SegmentBlock?
        for (kind, text) in blocks {
            let piece = render(kind, text)
            if let previous {
                out += sameList(previous, kind) ? "\n" : "\n\n"
            }
            out += piece
            previous = kind
        }
        return out
    }
}

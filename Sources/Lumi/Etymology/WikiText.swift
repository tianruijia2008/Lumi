import Foundation

/// Just enough of MediaWiki's markup to read an etymology.
///
/// Not a wikitext parser — nothing here expands a template. It only has to
/// split a paragraph into prose and `{{…}}` calls, and read a call's arguments,
/// because an etymology on Wiktionary is written *as* template calls:
/// `From {{inh|en|enm|nyce}}, from {{der|en|la|nescius||ignorant}}` is a
/// machine-readable chain with some English glued between the links. Reading
/// the calls gets the chain; rendering the page and scraping the prose would
/// get a sentence.
enum WikiText {
    enum Token: Equatable {
        case text(String)
        case template(Template)
    }

    struct Template: Equatable {
        let name: String
        /// Unnamed arguments, in order, after the name.
        let positional: [String]
        let named: [String: String]

        /// 1-based, the way template documentation counts: `{{der|en|la|x}}`
        /// has `x` at 3.
        func arg(_ index: Int) -> String? {
            guard index >= 1, index <= positional.count else { return nil }
            let value = positional[index - 1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }

        func named(_ keys: String...) -> String? {
            for key in keys {
                if let value = named[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                    return value
                }
            }
            return nil
        }
    }

    /// Splits text into prose and top-level template calls. Nested calls stay
    /// inside their parent's arguments, where `tokens(of:)` can be run again.
    static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var prose = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "{", i + 1 < chars.count, chars[i + 1] == "{",
               let end = closingBraces(chars, from: i) {
                if !prose.isEmpty { tokens.append(.text(prose)); prose = "" }
                let inner = String(chars[(i + 2)..<(end - 1)])
                if let template = template(from: inner) { tokens.append(.template(template)) }
                i = end + 1
            } else {
                prose.append(chars[i])
                i += 1
            }
        }
        if !prose.isEmpty { tokens.append(.text(prose)) }
        return tokens
    }

    /// Index of the second `}` of the `}}` that closes the `{{` at `start`.
    private static func closingBraces(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "{", chars[i + 1] == "{" {
                depth += 1; i += 2; continue
            }
            if chars[i] == "}", chars[i + 1] == "}" {
                depth -= 1
                if depth == 0 { return i + 1 }
                i += 2; continue
            }
            i += 1
        }
        return nil
    }

    private static func template(from inner: String) -> Template? {
        let parts = splitArguments(inner)
        guard let first = parts.first else { return nil }
        let name = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }
        var positional: [String] = []
        var named: [String: String] = [:]
        for part in parts.dropFirst() {
            // `=` inside a nested call or link belongs to that call, which is
            // why the split is depth-aware and this check only looks at the
            // text before any nesting starts.
            if let eq = part.firstIndex(of: "="),
               !part[..<eq].contains("{"), !part[..<eq].contains("["),
               part[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                named[String(part[..<eq])] = String(part[part.index(after: eq)...])
            } else {
                positional.append(part)
            }
        }
        return Template(name: name, positional: positional, named: named)
    }

    /// Splits on `|` that are not inside a nested `{{…}}` or `[[…]]`.
    private static func splitArguments(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var braces = 0, brackets = 0
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "{", next == "{" { braces += 1; current += "{{"; i += 2; continue }
            if c == "}", next == "}" { braces -= 1; current += "}}"; i += 2; continue }
            if c == "[", next == "[" { brackets += 1; current += "[["; i += 2; continue }
            if c == "]", next == "]" { brackets -= 1; current += "]]"; i += 2; continue }
            if c == "|", braces == 0, brackets == 0 {
                parts.append(current); current = ""; i += 1; continue
            }
            current.append(c)
            i += 1
        }
        parts.append(current)
        return parts
    }

    /// Wiki markup reduced to what a reader would see, minus every template.
    /// Used for short glosses — a definition line, a root's meaning.
    static func plain(_ text: String) -> String {
        var result = ""
        for token in tokens(of: text) {
            switch token {
            case .text(let prose): result += prose
            case .template(let t):
                // The handful of templates that *are* their visible text.
                switch t.name {
                case "l", "m", "l-lite", "m-lite": result += t.arg(3) ?? t.arg(2) ?? ""
                case "gloss", "n-g", "non-gloss", "ng", "w": result += t.arg(1) ?? ""
                default: break
                }
            }
        }
        result = replaceLinks(in: result)
        result = result.replacingOccurrences(of: "'''", with: "")
            .replacingOccurrences(of: "''", with: "")
        result = result.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".;,")))
    }

    /// `[[target|shown]]` → `shown`, `[[target]]` → `target`, and an anchor
    /// such as `[[sam#Adverb|sam]]` never leaks its `#Adverb`.
    static func replaceLinks(in text: String) -> String {
        let pattern = #"\[\[([^\]\|]*)(?:\|([^\]]*))?\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result) else { continue }
            let shown: String
            if let r = Range(match.range(at: 2), in: text) {
                shown = String(text[r])
            } else if let r = Range(match.range(at: 1), in: text) {
                shown = String(text[r]).components(separatedBy: "#").first ?? ""
            } else { shown = "" }
            result.replaceSubrange(whole, with: shown)
        }
        return result
    }

    /// The body of a `==Heading==` section, up to the next heading of the same
    /// or a higher level.
    static func section(_ text: String, heading: String, level: Int) -> String? {
        let marks = String(repeating: "=", count: level)
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "\(marks)\(heading)\(marks)"
        }) else { return nil }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("="), headingLevel(trimmed) <= level { break }
            body.append(line)
        }
        return body.joined(separator: "\n")
    }

    static func headingLevel(_ line: String) -> Int {
        var n = 0
        for c in line { if c == "=" { n += 1 } else { break } }
        return n
    }
}

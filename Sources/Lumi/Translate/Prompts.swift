import Foundation

enum Prompts {
    /// Translation mode: the model is a pipe, not a chat partner. Every extra
    /// word it adds is noise in a 300pt-wide popup.
    static func system(for request: TranslationRequest) -> String {
        if let instructions = request.instructions { return instructions }
        // A segment of a document is a different job from a popup query, and
        // every provider that speaks a system prompt gets the document rules
        // for free by asking the same question it always asked.
        if let doc = request.document { return document(for: request, doc) }
        if request.isLookup {
            return """
            You are the dictionary engine inside a macOS lookup utility. The user \
            gives you a word or short phrase in \(request.source.promptName). \
            Respond in \(request.target.promptName) using exactly this compact layout, \
            and nothing else:

            **<the word>** /<IPA or romanisation, omit the line if not applicable>/

            1. <part of speech> — <sense>
            2. <part of speech> — <sense>

            _<one short example sentence in \(request.source.promptName)>_
            <its translation in \(request.target.promptName)>

            Give at most four senses, most common first. No preamble, no closing \
            remark, no extra headings.
            """
        }
        return """
        You are the translation engine inside a macOS utility. Translate the user's \
        text into \(request.target.promptName).

        Rules:
        - Output the translation and nothing else. No preamble, no quotes around \
          the result, no notes, no apologies.
        - Preserve line breaks, lists, and code blocks exactly as given.
        - Keep proper nouns, code identifiers, and URLs unchanged.
        - Match the register of the source: keep casual text casual and formal \
          text formal.
        """
    }

    /// Marker that opens each item of a page batch. Doubled angle brackets
    /// because nothing on a web page writes them, and a model copies them back
    /// without trying to translate or "fix" them.
    static func batchMarker(_ number: Int) -> String { "<<\(number)>>" }

    /// Page mode: several short pieces of one web page in one call.
    ///
    /// A news front page is sixty one-line headlines. One call each was 30
    /// seconds for a screenful; one call for eight is the time of one. Only
    /// short pieces are batched — a paragraph long enough to have a
    /// "the latter" in it still goes alone with its preceding context.
    static func pageBatch(target: Language, count: Int, title: String, notes: String) -> String {
        var prompt = """
        You are the translation engine inside a web page reader. The user message \
        holds \(count) numbered pieces of text from one web page. Translate each \
        piece into \(target.promptName).
        """
        if !title.isEmpty { prompt += "\n\nThe page is titled: \(title)" }
        if !notes.isEmpty {
            prompt += """

            The reader has given you this background — domain, terminology and \
            register. Follow it over any general convention:
            \(notes)
            """
        }
        prompt += """

        Rules:
        - Output exactly \(count) lines, in order, each starting with its marker \
          exactly as given, e.g. \(batchMarker(1)) followed by the translation. \
          Nothing else: no preamble, no notes, no blank lines.
        - Each translation stays on one line.
        - Translate every piece fully, even a single word or a fragment.
        - Keep proper nouns, product names, code identifiers, numbers and URLs \
          unchanged. Keep one rendering per term across all pieces.
        """
        return prompt
    }

    /// Document mode: one segment of a longer text, translated in the knowledge
    /// that it is one segment of a longer text.
    ///
    /// The rules here are not style preferences. Every one of them is a failure
    /// that was measured on real paper prose: content silently deleted rather
    /// than translated, a number quietly rounded, one term rendered three ways
    /// across three paragraphs, and the model answering the previous paragraph
    /// because it could not tell context from input.
    static func document(for request: TranslationRequest, _ doc: DocumentContext) -> String {
        var prompt = """
        You are the translation engine inside a document reader. You are given \
        segment \(doc.index) of \(doc.count) from one continuous document. \
        Translate it into \(request.target.promptName).
        """
        if !doc.title.isEmpty {
            prompt += "\n\nThe document is titled: \(doc.title)"
        }
        if let hint = doc.hint {
            prompt += "\n\nThis segment is \(hint)."
        }
        if !doc.notes.isEmpty {
            // The reader's notes outrank the generic rules below: they know
            // their field and this tool does not.
            prompt += """

            The reader has given you this background — domain, terminology and \
            register. Follow it over any general convention:
            \(doc.notes)
            """
        }
        if let previous = doc.previous, !previous.isEmpty {
            prompt += """

            For reference only, the source text immediately before this segment \
            ended with:
            \(previous)

            Use it to resolve references such as "this", "the latter" or a \
            dropped subject. Do not translate it and do not repeat any of it.
            """
        }
        prompt += """

        Rules:
        - Output the translation of this segment and nothing else. No preamble, \
          no segment number, no notes, no quotes around the result.
        - Translate every part of the segment. If a term has no good \
          equivalent, transliterate it or keep the original in parentheses — \
          never drop it, and never summarise instead of translating.
        - Reproduce numbers, units, equations, LaTeX, citation markers, table \
          and figure references, URLs and code identifiers exactly as written. \
          Do not round, re-format or localise them.
        - Keep one rendering per technical term for the whole document.
        - Preserve the segment's own line breaks, list markers and indentation.
        - Match the register of the source. Academic prose stays academic.
        """
        if doc.markdown {
            // Measured failure: asked plainly, models "helpfully" translate
            // link text inside the URL, and localise backticked identifiers.
            prompt += """

            - The text is Markdown. Keep every piece of syntax exactly — emphasis \
              markers, `inline code`, links and their URLs, images, HTML tags, \
              table pipes — and translate only the words a reader sees. Never \
              translate inside backticks or URLs. Do not add a heading marker, \
              list marker or quote marker that is not in the segment.
            """
        }
        return prompt
    }
}

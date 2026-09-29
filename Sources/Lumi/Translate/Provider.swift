import Foundation


/// What a segment needs to know about the document it came from.
///
/// Translating a paper one paragraph at a time loses exactly the things that
/// make it a paper: a term rendered two ways in two sections, and every
/// backward reference ("this assumption", "the latter") pointing at text the
/// model was never shown. Carrying the document's own framing into each
/// request is what separates a translated document from a pile of translated
/// paragraphs.
///
/// Engines that cannot use this — sentence-level MT models, which is all of
/// them that run on-device — simply ignore it, and say so in the UI rather
/// than letting the user type notes into a field that does nothing.
struct DocumentContext: Sendable, Hashable {
    var title: String = ""
    /// The reader's own instructions: domain, glossary, register.
    var notes: String = ""
    var index: Int = 1
    var count: Int = 1
    /// The tail of the preceding segment, supplied as context only — never to
    /// be translated. This is what resolves anaphora across a segment break.
    var previous: String?
    /// What kind of block the segment is — "a level-2 heading", "one item of
    /// a list" — so it comes back as one.
    var hint: String?
    /// The document is Markdown: its syntax has to survive translation.
    var markdown = false
}

struct TranslationRequest: Sendable, Hashable {
    let text: String
    let source: Language   // already resolved — never `.auto` by the time a provider sees it
    let target: Language
    /// Set only by the workbench. Its presence is what turns a provider from a
    /// popup translator into a document translator, without either of them
    /// needing to know the other exists.
    var document: DocumentContext?
    /// A job that is not translation at all — the 词源 page's narration.
    /// When set it *is* the system prompt, so every provider that can be told
    /// what to do can be told this, without a second code path per vendor.
    var instructions: String? = nil
    /// Single words get dictionary treatment (senses, part of speech, examples)
    /// instead of a flat translation.
    var isLookup: Bool {
        // A document segment is never a lookup. Papers have one-word headings
        // ("Abstract", "Discussion"), and a heading that came back as a
        // dictionary entry would be absurd in a reading column.
        if document != nil || instructions != nil { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 24 && !trimmed.contains(where: \.isNewline)
            && trimmed.split(whereSeparator: \.isWhitespace).count <= 2
    }
}

enum TranslationEvent: Sendable {
    case delta(String)                   // append (streaming providers)
    case replace(String)                 // set whole body (one-shot providers)
    case dictionary(DictionaryEntry)     // a parsed entry the card lays out itself
}

enum ProviderAvailability: Sendable, Equatable {
    case ready
    case needsSetup(String)     // user action required, e.g. missing API key
    case unavailable(String)    // configured but broken here — worth reporting
    /// Nothing is wrong; this service just has no opinion on this input (a
    /// dictionary handed a paragraph). Carries the phrasing the rail should
    /// show, because "no entry" and "not a lookup" read very differently to
    /// someone wondering why their query went elsewhere.
    case notApplicable(String)
}

protocol TranslationProvider: Sendable {
    var kind: ServiceKind { get }
    /// Whether this service is reachable only over the network. The two Apple
    /// providers run on-device, which is what makes them the last rung of the
    /// fallback ladder.
    var requiresNetwork: Bool { get }
    func availability(for request: TranslationRequest) async -> ProviderAvailability
    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error>
}

extension TranslationProvider {
    var requiresNetwork: Bool { true }
    var displayName: String { kind.displayName }
    var symbolName: String { kind.symbolName }

    /// Wraps a one-shot call as a single-event stream so callers only ever
    /// deal with one shape.
    func oneShot(
        timeout: Double = 20,
        _ body: @escaping @Sendable () async throws -> String
    ) -> AsyncThrowingStream<TranslationEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await withTimeout(timeout, operation: body)
                    continuation.yield(.replace(text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

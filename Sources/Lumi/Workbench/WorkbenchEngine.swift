import Foundation

/// Which kind of translator the workbench is driving.
///
/// Not a list of vendors — a choice between two genuinely different products.
/// The online engine reads the whole document's framing and can be told about
/// a field's terminology; the on-device one translates a sentence in isolation
/// and cannot be told anything. Presenting them as interchangeable would set
/// the reader up to trust an offline translation the way they trust an online
/// one, which is the one mistake this window must not encourage.
enum WorkbenchEngineID: String, Codable, CaseIterable, Sendable, Identifiable {
    case online, offline
    var id: String { rawValue }
}

/// One segment, handed to an engine with everything it needs to translate it.
struct WorkbenchJob: Sendable {
    let index: Int
    let text: String
    let context: DocumentContext
}

/// Engines report per segment, never per document.
///
/// A failure is scoped to one segment on purpose: a paper where paragraph 12
/// tripped a content filter should come back with 40 translated paragraphs and
/// one marked row, not with an error dialog and nothing to read.
enum WorkbenchEvent: Sendable {
    case finished(index: Int, text: String)
    case failed(index: Int, message: String)
}

protocol WorkbenchEngine: Sendable {
    var id: WorkbenchEngineID { get }
    var displayName: String { get }
    /// One line under the name in the picker, saying what the trade is.
    var detail: String { get }
    var requiresNetwork: Bool { get }
    /// Whether `DocumentContext` reaches the model at all. False for on-device
    /// MT, and the reason the context field greys out instead of lying.
    var usesDocumentContext: Bool { get }

    func availability(source: Language, target: Language) async -> ProviderAvailability
    func run(_ jobs: [WorkbenchJob], source: Language, target: Language)
        -> AsyncStream<WorkbenchEvent>
}

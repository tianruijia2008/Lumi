import CryptoKit
import Foundation
import Observation

/// What a document is for: read with a translation made here, or brought in
/// with someone else's translation to be checked.
enum DocumentPurpose: String, Codable, Sendable {
    case read
    case proof
}

/// A document as it is kept on disk: the source cut into segments, whatever
/// came back for each, and where the reader was.
///
/// Stored whole rather than as a diff against anything, because what makes it
/// worth keeping is exactly the part that cost money — the translations — and
/// reopening a paper should never mean paying for it twice.
struct SavedDocument: Codable, Identifiable {
    var id: UUID
    var title: String
    var context: String
    var engine: WorkbenchEngineID
    /// Who actually translated it: "本机" or the service's name.
    var engineLabel: String
    var source: Language
    var target: Language
    var segments: [SavedSegment]
    var readingPosition: Int
    var created: Date
    var modified: Date
    /// Identifies the text itself, so pasting the same paper again reopens it
    /// instead of starting a second, untranslated copy.
    var fingerprint: String
    // Optional so documents kept before these existed still open.
    var format: TextFormat?
    var purpose: DocumentPurpose?
    var reviewerLabel: String?

    var summary: DocumentSummary {
        let work = segments.filter { !($0.block?.isVerbatim ?? false) }
        return DocumentSummary(
            id: id, title: title, notes: context, engineLabel: engineLabel,
            source: source, target: target,
            segmentCount: work.count,
            doneCount: work.count { $0.kind != .pending },
            flaggedCount: work.count { $0.kind == .dropped },
            failedCount: work.count { $0.kind == .failed },
            readingPosition: readingPosition, modified: modified,
            fingerprint: fingerprint,
            purpose: purpose ?? .read,
            format: format ?? .plain,
            reviewedCount: work.count { $0.reviewed == true },
            issueCount: segments.reduce(0) { $0 + ($1.issues?.count { $0.state == .open } ?? 0) }
        )
    }
}

struct SavedSegment: Codable {
    enum Kind: String, Codable { case pending, done, dropped, failed }
    var source: String
    var translation: String
    var kind: Kind
    var note: String?
    var block: SegmentBlock?
    var issues: [ProofIssue]?
    var terms: [TermPair]?
    var reviewed: Bool?
    /// Why the review of this segment failed.
    var reviewNote: String?
    var edited: Bool?
}

/// What the start page and the sidebar list: enough to choose a document
/// without decoding every one of them.
struct DocumentSummary: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var notes: String
    var engineLabel: String
    var source: Language
    var target: Language
    var segmentCount: Int
    var doneCount: Int
    /// Segments that came back suspected of losing something.
    var flaggedCount: Int
    /// Segments the engine could not translate at all.
    var failedCount: Int
    var readingPosition: Int
    var modified: Date
    var fingerprint: String?
    var purpose: DocumentPurpose = .read
    var format: TextFormat = .plain
    var reviewedCount = 0
    /// Open review notes.
    var issueCount = 0

    /// Written out rather than synthesised: an index saved before the newer
    /// fields existed must still load, not blank the recents list.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        engineLabel = try c.decodeIfPresent(String.self, forKey: .engineLabel) ?? ""
        source = try c.decode(Language.self, forKey: .source)
        target = try c.decode(Language.self, forKey: .target)
        segmentCount = try c.decode(Int.self, forKey: .segmentCount)
        doneCount = try c.decode(Int.self, forKey: .doneCount)
        flaggedCount = try c.decodeIfPresent(Int.self, forKey: .flaggedCount) ?? 0
        failedCount = try c.decodeIfPresent(Int.self, forKey: .failedCount) ?? 0
        readingPosition = try c.decodeIfPresent(Int.self, forKey: .readingPosition) ?? 0
        modified = try c.decode(Date.self, forKey: .modified)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        purpose = try c.decodeIfPresent(DocumentPurpose.self, forKey: .purpose) ?? .read
        format = try c.decodeIfPresent(TextFormat.self, forKey: .format) ?? .plain
        reviewedCount = try c.decodeIfPresent(Int.self, forKey: .reviewedCount) ?? 0
        issueCount = try c.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
    }

    init(id: UUID, title: String, notes: String, engineLabel: String,
         source: Language, target: Language, segmentCount: Int, doneCount: Int,
         flaggedCount: Int, failedCount: Int, readingPosition: Int, modified: Date,
         fingerprint: String?, purpose: DocumentPurpose, format: TextFormat,
         reviewedCount: Int, issueCount: Int) {
        self.id = id; self.title = title; self.notes = notes; self.engineLabel = engineLabel
        self.source = source; self.target = target
        self.segmentCount = segmentCount; self.doneCount = doneCount
        self.flaggedCount = flaggedCount; self.failedCount = failedCount
        self.readingPosition = readingPosition; self.modified = modified
        self.fingerprint = fingerprint; self.purpose = purpose; self.format = format
        self.reviewedCount = reviewedCount; self.issueCount = issueCount
    }

    var isProof: Bool { purpose == .proof }
    var progress: Double {
        guard segmentCount > 0 else { return 0 }
        return Double(isProof ? reviewedCount : doneCount) / Double(segmentCount)
    }
    var isTranslated: Bool {
        segmentCount > 0 && (isProof ? reviewedCount : doneCount) == segmentCount
    }
    /// Somewhere past the opening and short of the end: a document to come
    /// back to rather than one that is finished or was never started.
    var isMidway: Bool { readingPosition > 0 && readingPosition < segmentCount - 1 }
}

/// The workbench's result cache: every document read in it, kept in
/// Application Support.
///
/// One file per document plus a small index, so the start page can list
/// fifty papers without reading fifty papers.
@MainActor @Observable
final class DocumentStore {
    static let shared = DocumentStore()

    private(set) var recents: [DocumentSummary] = []

    private let directory: URL
    private var indexURL: URL { directory.appending(path: "index.json") }
    private var pending: [UUID: Task<Void, Never>] = [:]
    /// The latest state of every document whose write is still waiting, so
    /// quitting inside the debounce writes it instead of losing it.
    private var unsaved: [UUID: SavedDocument] = [:]

    /// Past this many, the oldest are forgotten. A cache, not an archive.
    private let limit = 60

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appending(path: "Lumi/Documents", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? Self.decoder.decode([DocumentSummary].self, from: data) {
            recents = decoded.sorted { $0.modified > $1.modified }
        }
    }

    func document(_ id: UUID) -> SavedDocument? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? Self.decoder.decode(SavedDocument.self, from: data)
    }

    /// The saved copy of this exact text, if it was read before.
    func existing(fingerprint: String) -> SavedDocument? {
        summary(fingerprint: fingerprint).flatMap { document($0.id) }
    }

    func summary(fingerprint: String) -> DocumentSummary? {
        recents.first { $0.fingerprint == fingerprint }
    }

    /// Writes soon rather than now: a translation arrives a segment at a
    /// time, and forty segments should not mean forty rewrites of the file.
    /// The list updates at once, so the sidebar never lags what is on screen.
    func scheduleSave(_ saved: SavedDocument) {
        upsert(saved.summary)
        unsaved[saved.id] = saved
        pending[saved.id]?.cancel()
        pending[saved.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            self.write(saved)
        }
    }

    /// Writes everything still waiting, now. Called on quit and when the
    /// window closes — the two moments the debounce would otherwise lose the
    /// last edit.
    func flush() {
        for saved in unsaved.values {
            pending[saved.id]?.cancel()
            write(saved)
        }
    }

    func remove(_ id: UUID) {
        pending[id]?.cancel()
        unsaved[id] = nil
        recents.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: url(for: id))
        writeIndex()
    }

    private func write(_ saved: SavedDocument) {
        pending[saved.id] = nil
        unsaved[saved.id] = nil
        do {
            try Self.encoder.encode(saved).write(to: url(for: saved.id), options: .atomic)
        } catch {
            Log.window.error("document save failed: \(error.localizedDescription, privacy: .public)")
        }
        writeIndex()
    }

    private func upsert(_ summary: DocumentSummary) {
        recents.removeAll { $0.id == summary.id }
        recents.insert(summary, at: 0)
        while recents.count > limit, let dropped = recents.popLast() {
            try? FileManager.default.removeItem(at: url(for: dropped.id))
        }
    }

    private func writeIndex() {
        guard let data = try? Self.encoder.encode(recents) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    static func fingerprint(of text: String) -> String {
        let normalised = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalised.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

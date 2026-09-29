import AppKit
import Foundation
import Vision

/// Select a region of the screen, read the text in it, translate that.
///
/// Recognition uses Vision's async request API rather than the older
/// `VNImageRequestHandler.perform`, which is a synchronous, CPU-bound call —
/// exactly the kind of thing that stalls a UI when it runs on the wrong thread.
enum ScreenOCR {
    static func captureAndRecognize() async throws -> String? {
        guard let url = await selectRegion() else { return nil }   // user pressed Escape
        defer { try? FileManager.default.removeItem(at: url) }
        return try await recognize(url)
    }

    // MARK: Region selection

    /// Delegates to the system's own crosshair selection. It is the interaction
    /// every Mac user already knows, it handles multi-display and Escape
    /// correctly, and it keeps Lumi out of the business of drawing an overlay
    /// window over other apps.
    private static func selectRegion() async -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "lumi-ocr-\(UUID().uuidString).png")

        let finished: Bool = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i interactive, -x silent, -o no window shadow
            process.arguments = ["-i", "-x", "-o", url.path]
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }

        // Escape leaves no file behind; that is a cancel, not an error.
        guard finished, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: Recognition

    private static func recognize(_ url: URL) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [
            Locale.Language(identifier: "zh-Hans"),
            Locale.Language(identifier: "en-US"),
            Locale.Language(identifier: "ja-JP"),
            Locale.Language(identifier: "ko-KR"),
        ]

        let observations = try await request.perform(on: url)
        // Observations come back in reading order; one line each.
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation

struct TimeoutError: LocalizedError {
    let seconds: Double
    var errorDescription: String? { String(format: "超时（%.0f 秒无响应）", seconds) }
}

/// Races `operation` against a deadline.
///
/// This is the backbone of Lumi's no-freeze guarantee: every call that leaves
/// our process — network, Accessibility, OCR, on-device translation — goes
/// through here, so a wedged peer can never become a wedged UI. The loser task
/// is cancelled as soon as either side finishes.
func withTimeout<T: Sendable>(
    _ seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw CancellationError()
        }
        return first
    }
}

/// Runs a blocking C API on a detached thread so it can never stall the main
/// actor, and abandons it after `seconds`. Needed for Accessibility calls,
/// which block the calling thread with no async form.
func withBlockingTimeout<T: Sendable>(
    _ seconds: Double,
    _ work: @escaping @Sendable () -> T
) async -> T? {
    let task = Task.detached(priority: .userInitiated) { work() }
    do {
        return try await withTimeout(seconds) { await task.value }
    } catch {
        task.cancel()   // best effort; the thread is abandoned, not the app
        return nil
    }
}

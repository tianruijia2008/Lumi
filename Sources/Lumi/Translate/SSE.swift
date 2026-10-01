import Foundation

/// Shared streaming plumbing for the HTTP providers.
///
/// `URLSession.bytes` gives us back-pressure-free line reading, and
/// `timeoutIntervalForRequest` acts as a stall watchdog: it is the gap allowed
/// *between* packets, so a server that accepts the connection and then goes
/// quiet is dropped instead of hanging the result card forever.
enum SSE {
    static func session(stallTimeout: TimeInterval = 25, total: TimeInterval = 180) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = stallTimeout
        config.timeoutIntervalForResource = total
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "text/event-stream"]
        return URLSession(configuration: config)
    }

    /// Streams the response line by line, handing each non-empty payload to
    /// `decode`. Returning `nil` from `decode` skips the line; returning a
    /// string emits it as a delta. Throws on non-2xx with the body attached so
    /// the UI can show a real message instead of "something went wrong".
    static func stream(
        request: URLRequest,
        stripDataPrefix: Bool,
        decode: @escaping @Sendable (String) -> String?
    ) -> AsyncThrowingStream<TranslationEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let session = session()
                defer { session.invalidateAndCancel() }
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw TranslationFailure.badResponse(-1, tDetached("无效响应"))
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 1_000 { break }
                        }
                        throw TranslationFailure.badResponse(http.statusCode, body)
                    }

                    var produced = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        var payload = line
                        if stripDataPrefix {
                            guard line.hasPrefix("data:") else { continue }
                            payload = String(line.dropFirst(5))
                                .trimmingCharacters(in: .whitespaces)
                        }
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        if let text = decode(payload), !text.isEmpty {
                            produced = true
                            continuation.yield(.delta(text))
                        }
                    }
                    if !produced { throw TranslationFailure.emptyResult }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

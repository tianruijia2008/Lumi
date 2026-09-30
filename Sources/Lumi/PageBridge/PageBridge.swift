import Foundation
import Network
import Observation

/// The door the Safari extension knocks on: a loopback-only HTTP endpoint that
/// translates web-page paragraphs with Lumi's own engines.
///
/// Why a socket and not something more native. A Safari extension runs as a
/// sandboxed appex that cannot read Lumi's keychain or settings, so it cannot
/// translate with the reader's DeepSeek key by itself — whatever it sends has
/// to reach this process. XPC would need a launchd-registered service; a
/// loopback socket needs nothing, and can be exercised with `curl`, which is
/// how every path through it was checked.
///
/// A socket on 127.0.0.1 is still reachable by every web page the user opens,
/// so three checks stand between a page and the reader's API quota:
/// - `Host` must name loopback. A DNS-rebinding page arrives under its own
///   hostname, and that is where it gets turned away.
/// - A request carrying a web `Origin` is refused. Browsers attach `Origin` to
///   every cross-origin POST, and the extension's own origin is not http(s).
/// - POSTs must carry `X-Lumi-Client`, which a page cannot set without a CORS
///   preflight — and preflights are never answered.
@MainActor @Observable
final class PageBridge {
    static let shared = PageBridge()

    /// Fixed, because the extension has no way to be told a different one.
    /// Must match `LUMI_PORT` in the extension's background script.
    nonisolated static let port: UInt16 = 47_121

    enum State: Equatable {
        case stopped
        case listening
        case failed(String)
    }

    private(set) var state = State.stopped
    /// Pages translated since launch — shown in Settings so "is the extension
    /// actually reaching Lumi" has an answer that isn't a log query.
    private(set) var requestsServed = 0
    /// Paragraphs that came back translated, which is the number a reader
    /// recognises; a batch is an implementation detail.
    private(set) var paragraphsServed = 0
    /// The last time the extension got through — any accepted request, so a
    /// popup that only asked for status still counts as "connected".
    private(set) var lastContact: Date?

    private var listener: NWListener?

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!
        )
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                let verdict: State? = switch state {
                case .ready:               .listening
                case .failed(let error):   .failed(error.localizedDescription)
                case .cancelled:           .stopped
                default:                   nil
                }
                guard let verdict else { return }
                Task { @MainActor in PageBridge.shared.state = verdict }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .userInitiated))
                Task { await PageBridge.serve(connection) }
            }
            listener.start(queue: DispatchQueue(label: "com.tianruijia.Lumi.bridge"))
            self.listener = listener
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Connection

    /// One request per connection, then close. The extension never pipelines,
    /// and keep-alive would only be another way for a stalled peer to hold a
    /// socket open.
    nonisolated private static func serve(_ connection: NWConnection) async {
        defer { connection.cancel() }
        let response: HTTPResponse
        do {
            let request = try await withTimeout(10) { try await HTTPRequest.read(from: connection) }
            response = await route(request)
        } catch let error as HTTPError {
            response = .json(error.status, ["error": error.message])
        } catch {
            response = .json(408, ["error": error.localizedDescription])
        }
        await connection.sendAll(response.serialized)
    }

    nonisolated private static func route(_ request: HTTPRequest) async -> HTTPResponse {
        let host = request.headers["host"] ?? ""
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return .json(403, ["error": "host not allowed"])
        }
        if let origin = request.headers["origin"], isWebOrigin(origin) {
            return .json(403, ["error": "origin not allowed"])
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/status"):
            await MainActor.run { PageBridge.shared.lastContact = .now }
            return .json(200, await status(target: request.query["target"]))

        case ("POST", "/v1/translate"):
            guard request.headers["x-lumi-client"] != nil else {
                return .json(403, ["error": "missing X-Lumi-Client"])
            }
            guard let body = try? JSONDecoder().decode(PageTranslationRequest.self, from: request.body)
            else { return .json(400, ["error": "malformed request body"]) }
            let result = await PageTranslator.translate(body)
            let translated = result.results.count(where: { $0.text != nil })
            await MainActor.run {
                let bridge = PageBridge.shared
                bridge.requestsServed += 1
                bridge.paragraphsServed += translated
                bridge.lastContact = .now
            }
            return .json(200, result)

        default:
            return .json(404, ["error": "no such endpoint"])
        }
    }

    /// Extension origins (`safari-web-extension://…`) pass; anything a web
    /// page could be served from does not. There is deliberately no dev
    /// override: `Extensions/Safari/Harness/serve.py` drives the content
    /// script through a proxy that strips `Origin`, as the appex relay does.
    nonisolated private static func isWebOrigin(_ origin: String) -> Bool {
        let lowered = origin.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered == "null"
    }

    nonisolated static func status(target raw: String?) async -> PageBridgeStatus {
        let (online, firstLanguage) = await MainActor.run {
            (AppSettings.shared.workbenchOnlineProvider(), AppSettings.shared.firstLanguage)
        }
        let target = raw.flatMap(Language.init(rawValue:)) ?? firstLanguage
        // Availability for a typical page: an English one. The per-request
        // answer can still differ, and `translate` reports that per segment.
        let source: Language = Language.sameLanguage(target, .english) ? .simplifiedChinese : .english
        let engines: [any WorkbenchEngine] = [OnlineWorkbenchEngine(provider: online), OfflineWorkbenchEngine()]
        var reports: [PageBridgeStatus.Engine] = []
        for engine in engines {
            let availability = await engine.availability(source: source, target: target)
            reports.append(.init(
                id: engine.id.rawValue,
                name: engine.displayName,
                ready: availability == .ready,
                detail: availability.message ?? engine.detail
            ))
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return PageBridgeStatus(
            app: "Lumi", version: version ?? "dev",
            defaultTarget: firstLanguage.rawValue, engines: reports
        )
    }
}

struct PageBridgeStatus: Encodable {
    struct Engine: Encodable {
        let id: String
        let name: String
        let ready: Bool
        let detail: String
    }
    let app: String
    let version: String
    /// The reader's 第一语言, so the extension's first run already points the
    /// right way instead of defaulting to a language they never chose.
    let defaultTarget: String
    let engines: [Engine]
}

extension ProviderAvailability {
    /// The sentence to show a reader, or `nil` when there is nothing to say.
    var message: String? {
        switch self {
        case .ready:                    nil
        case .needsSetup(let why),
             .unavailable(let why),
             .notApplicable(let why):   why
        }
    }
}

// MARK: - Minimal HTTP/1.1

struct HTTPError: Error {
    let status: Int
    let message: String
}

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    /// Lower-cased names; HTTP header names are case-insensitive.
    let headers: [String: String]
    let body: Data

    /// Page batches are a few kilobytes. Anything near this is not the
    /// extension, and reading it to the end would only cost memory.
    static let maxBody = 1 << 20

    static func read(from connection: NWConnection) async throws -> HTTPRequest {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let (chunk, done) = try await connection.receiveChunk()
            if let chunk { buffer.append(chunk) }
            headerEnd = buffer.range(of: separator)
            if headerEnd == nil, done || buffer.count > 64 * 1024 {
                throw HTTPError(status: 400, message: "incomplete request head")
            }
        }
        guard let headerEnd,
              let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8)
        else { throw HTTPError(status: 400, message: "unreadable request head") }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw HTTPError(status: 400, message: "bad request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= maxBody else { throw HTTPError(status: 413, message: "body too large") }
        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < length {
            let (chunk, done) = try await connection.receiveChunk()
            if let chunk { body.append(chunk) }
            if done, body.count < length { throw HTTPError(status: 400, message: "truncated body") }
        }

        let components = URLComponents(string: String(requestLine[1]))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: components?.path ?? "/",
            query: query,
            headers: headers,
            body: body.prefix(length)
        )
    }
}

struct HTTPResponse: Sendable {
    let status: Int
    let body: Data

    static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }

    var serialized: Data {
        let reason = switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 413: "Payload Too Large"
        default:  "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

extension NWConnection {
    func receiveChunk() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data, done)) }
            }
        }
    }

    func sendAll(_ data: Data) async {
        await withCheckedContinuation { continuation in
            send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}

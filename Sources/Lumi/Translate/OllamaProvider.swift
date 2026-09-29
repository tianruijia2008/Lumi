import Foundation

/// Local models over Ollama's HTTP API. Fully offline, so it stays useful on a
/// plane or behind a firewall — and nothing typed into Lumi leaves the machine.
struct OllamaProvider: TranslationProvider {
    let kind = ServiceKind.ollama
    let model: String
    let host: String

    private var baseURL: URL { URL(string: host) ?? URL(string: "http://127.0.0.1:11434")! }

    func availability(for request: TranslationRequest) async -> ProviderAvailability {
        guard !model.isEmpty else { return .needsSetup("请在设置中选择本地模型") }
        do {
            let reachable = try await withTimeout(1.5) {
                let url = baseURL.appending(path: "api/tags")
                let (_, response) = try await URLSession.shared.data(from: url)
                return (response as? HTTPURLResponse)?.statusCode == 200
            }
            return reachable ? .ready : .unavailable("Ollama 无响应")
        } catch {
            return .needsSetup("未检测到运行中的 Ollama，请先启动 `ollama serve`")
        }
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        var urlRequest = URLRequest(url: baseURL.appending(path: "api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "options": ["temperature": 0.2],
            "messages": [
                ["role": "system", "content": Prompts.system(for: request)],
                ["role": "user", "content": request.text],
            ],
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Ollama streams NDJSON, not SSE — one bare JSON object per line.
        return SSE.stream(request: urlRequest, stripDataPrefix: false) { payload in
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OllamaChunk.self, from: data)
            else { return nil }
            return chunk.message?.content
        }
    }

    private struct OllamaChunk: Decodable {
        let message: Message?
        let done: Bool?
        struct Message: Decodable { let content: String? }
    }
}

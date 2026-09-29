import Foundation

struct GeminiProvider: TranslationProvider {
    let kind = ServiceKind.gemini
    let model: String

    func availability(for request: TranslationRequest) async -> ProviderAvailability {
        guard !model.isEmpty else { return .needsSetup("请填写模型名") }
        return Keychain.get(kind.keychainAccount)?.isEmpty == false
            ? .ready
            : .needsSetup("请在设置中填写 Gemini API Key")
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        guard let key = Keychain.get(kind.keychainAccount), !key.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: TranslationFailure.missingKey("Gemini")) }
        }
        // `alt=sse` is what turns the streaming endpoint from a JSON array into
        // proper server-sent events.
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/"
            + "\(model):streamGenerateContent?alt=sse"
        guard let url = URL(string: endpoint) else {
            return AsyncThrowingStream { $0.finish(throwing: TranslationFailure.badResponse(-1, "模型名无效")) }
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header rather than a query parameter: keys do not belong in URLs.
        urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Prompts.system(for: request)]]],
            "contents": [["role": "user", "parts": [["text": request.text]]]],
            "generationConfig": ["temperature": 0.2],
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return SSE.stream(request: urlRequest, stripDataPrefix: true) { payload in
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(Chunk.self, from: data)
            else { return nil }
            return chunk.candidates?.first?.content?.parts?.compactMap(\.text).joined()
        }
    }

    private struct Chunk: Decodable {
        let candidates: [Candidate]?
        struct Candidate: Decodable {
            let content: Content?
            struct Content: Decodable {
                let parts: [Part]?
                struct Part: Decodable { let text: String? }
            }
        }
    }
}

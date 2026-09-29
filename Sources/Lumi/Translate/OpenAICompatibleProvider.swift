import Foundation

/// One implementation for every vendor that speaks OpenAI's Chat Completions
/// protocol — OpenAI, DeepSeek, Groq, Moonshot, SiliconFlow, xAI, OpenRouter
/// and any self-hosted gateway. They differ only in base URL, key and model
/// name, so they are configured, not coded.
struct OpenAICompatibleProvider: TranslationProvider {
    let kind: ServiceKind
    let model: String
    let baseURL: String

    func availability(for request: TranslationRequest) async -> ProviderAvailability {
        guard !baseURL.isEmpty else { return .needsSetup("请填写 API 地址") }
        guard !model.isEmpty else { return .needsSetup("请填写模型名") }
        guard Keychain.get(kind.keychainAccount)?.isEmpty == false else {
            return .needsSetup("请在设置中填写 \(kind.displayName) API Key")
        }
        return .ready
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        guard let key = Keychain.get(kind.keychainAccount), !key.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: TranslationFailure.missingKey(displayName)) }
        }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?
            .appending(path: "chat/completions") else {
            return AsyncThrowingStream { $0.finish(throwing: TranslationFailure.badResponse(-1, "API 地址无效")) }
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": Prompts.system(for: request)],
                ["role": "user", "content": request.text],
            ],
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return SSE.stream(request: urlRequest, stripDataPrefix: true) { payload in
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(Chunk.self, from: data)
            else { return nil }
            let delta = chunk.choices.first?.delta
            // Reasoning models emit a separate thinking channel; the popup only
            // wants the answer.
            return delta?.content
        }
    }

    private struct Chunk: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let delta: Delta
            struct Delta: Decodable { let content: String? }
        }
    }
}

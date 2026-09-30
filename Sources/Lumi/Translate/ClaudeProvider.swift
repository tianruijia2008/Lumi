import Foundation

struct ClaudeProvider: TranslationProvider {
    let kind = ServiceKind.claude
    let model: String
    /// Translation is latency-critical in a popup, so a shallow reasoning
    /// budget beats disabling thinking outright — on Opus-class models a
    /// disabled-thinking request can leak reasoning into the visible answer.
    let effort: String

    func availability(for request: TranslationRequest) async -> ProviderAvailability {
        Keychain.get(kind.keychainAccount)?.isEmpty == false
            ? .ready
            : .needsSetup("请在设置中填写 Claude API Key")
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        guard let key = Keychain.get(kind.keychainAccount), !key.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: TranslationFailure.missingKey("Claude")) }
        }

        var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // If a safety classifier declines, the API routes to a comparable model
        // rather than handing back a refusal we would have to render as an error.
        urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4_096,
            "stream": true,
            "fallbacks": "default",
            "output_config": ["effort": effort],
            "system": Prompts.system(for: request),
            "messages": [["role": "user", "content": request.text]],
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return SSE.stream(request: urlRequest, stripDataPrefix: true) { payload in
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(Event.self, from: data),
                  event.type == "content_block_delta",
                  event.delta?.type == "text_delta"
            else { return nil }
            return event.delta?.text
        }
    }

    private struct Event: Decodable {
        let type: String
        let delta: Delta?
        struct Delta: Decodable {
            let type: String?
            let text: String?
        }
    }
}

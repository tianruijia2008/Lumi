import Foundation

struct DeepLProvider: TranslationProvider {
    let kind = ServiceKind.deepL

    func availability(for request: TranslationRequest) async -> ProviderAvailability {
        guard Keychain.get(kind.keychainAccount)?.isEmpty == false else {
            return .needsSetup(tDetached("请在设置中填写 DeepL API Key"))
        }
        guard Self.code(request.target, isTarget: true) != nil else {
            return .unavailable(tDetached("DeepL 不支持此目标语言"))
        }
        return .ready
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        oneShot(timeout: 12) {
            guard let key = Keychain.get(kind.keychainAccount), !key.isEmpty else {
                throw TranslationFailure.missingKey("DeepL")
            }
            guard let target = Self.code(request.target, isTarget: true) else {
                throw TranslationFailure.unsupportedPair
            }

            var urlRequest = URLRequest(url: Self.endpoint(for: key))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")

            var body: [String: Any] = ["text": [request.text], "target_lang": target]
            // Omitting source_lang lets DeepL detect, which it does well; only
            // pin it when we are confident.
            if let source = Self.code(request.source, isTarget: false) {
                body["source_lang"] = source
            }
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw TranslationFailure.badResponse(
                    code, String(data: data, encoding: .utf8) ?? ""
                )
            }
            let decoded = try JSONDecoder().decode(Payload.self, from: data)
            guard let text = decoded.translations.first?.text, !text.isEmpty else {
                throw TranslationFailure.emptyResult
            }
            return text
        }
    }

    /// DeepL issues free keys with a `:fx` suffix and serves them from a
    /// different host — deriving it from the key spares the user a toggle they
    /// would inevitably set wrong.
    private static func endpoint(for key: String) -> URL {
        let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        return URL(string: "https://\(host)/v2/translate")!
    }

    /// DeepL's codes are upper-case and asymmetric: some variants are valid as
    /// a target but not as a source.
    private static func code(_ language: Language, isTarget: Bool) -> String? {
        switch language {
        case .auto:               nil
        case .simplifiedChinese:  "ZH"
        case .traditionalChinese: isTarget ? "ZH-HANT" : "ZH"
        case .english:            isTarget ? "EN-US" : "EN"
        case .portuguese:         isTarget ? "PT-BR" : "PT"
        case .japanese:           "JA"
        case .korean:             "KO"
        case .french:             "FR"
        case .german:             "DE"
        case .spanish:            "ES"
        case .italian:            "IT"
        case .russian:            "RU"
        case .arabic:             "AR"
        }
    }

    private struct Payload: Decodable {
        let translations: [Translation]
        struct Translation: Decodable { let text: String }
    }
}

import Foundation

/// Google's public translate endpoint — no key, no account. It is an
/// undocumented interface, so it is treated as best-effort: it is never the
/// only provider running, and a failure here degrades one card rather than the
/// whole query.
struct WebProvider: TranslationProvider {
    let kind = ServiceKind.google

    func availability(for request: TranslationRequest) async -> ProviderAvailability { .ready }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        oneShot(timeout: 10) {
            var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
            components.queryItems = [
                .init(name: "client", value: "gtx"),
                .init(name: "sl", value: Self.code(request.source)),
                .init(name: "tl", value: Self.code(request.target)),
                .init(name: "dt", value: "t"),
                .init(name: "q", value: request.text),
            ]
            var urlRequest = URLRequest(url: components.url!)
            urlRequest.timeoutInterval = 8
            urlRequest.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                forHTTPHeaderField: "User-Agent"
            )

            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw TranslationFailure.badResponse(code, tDetached("在线翻译不可用"))
            }
            // Shape: [[["译文","原文",...], ...], ...] — segments must be joined.
            guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let segments = root.first as? [Any] else {
                throw TranslationFailure.emptyResult
            }
            let text = segments
                .compactMap { ($0 as? [Any])?.first as? String }
                .joined()
            guard !text.isEmpty else { throw TranslationFailure.emptyResult }
            return text
        }
    }

    /// Google uses its own codes for the Chinese variants.
    private static func code(_ language: Language) -> String {
        switch language {
        case .auto:               "auto"
        case .simplifiedChinese:  "zh-CN"
        case .traditionalChinese: "zh-TW"
        default:                  language.rawValue
        }
    }
}

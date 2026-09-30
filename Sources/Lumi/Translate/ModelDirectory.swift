import Foundation
import Observation

/// Pulls each vendor's live model list instead of trusting a table baked into
/// this app.
///
/// Hardcoded defaults go stale within months — every LLM default this project
/// shipped had been renamed or retired by the time it was checked. Every
/// vendor here exposes a list endpoint, so the authoritative answer is one GET
/// away and the user never has to guess a model name.
@MainActor @Observable
final class ModelDirectory {
    static let shared = ModelDirectory()

    private(set) var fetched: [String: [String]] = [:]
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]

    private init() {}

    /// Live list when we have one, otherwise the shipped suggestions.
    func models(for kind: ServiceKind) -> [String] {
        let live = fetched[kind.rawValue] ?? []
        return live.isEmpty ? kind.suggestedModels : live
    }

    func isLive(_ kind: ServiceKind) -> Bool {
        !(fetched[kind.rawValue] ?? []).isEmpty
    }

    func isLoading(_ kind: ServiceKind) -> Bool { loading.contains(kind.rawValue) }
    func error(for kind: ServiceKind) -> String? { errors[kind.rawValue] }

    func refresh(_ kind: ServiceKind) async {
        let key = kind.rawValue
        guard !loading.contains(key) else { return }
        loading.insert(key)
        errors[key] = nil
        defer { loading.remove(key) }

        do {
            // Same deadline discipline as every other outbound call: a vendor
            // that hangs must not hang the settings window.
            let names = try await withTimeout(10) { try await Self.list(kind) }
            if names.isEmpty {
                errors[key] = "没有返回模型"
            } else {
                fetched[key] = names.sorted()
            }
        } catch {
            errors[key] = error.localizedDescription
        }
    }

    // MARK: Per-vendor list endpoints

    @MainActor
    private static func list(_ kind: ServiceKind) async throws -> [String] {
        let settings = AppSettings.shared
        let apiKey = settings.apiKey(for: kind)

        switch kind.family {
        case .openAICompatible:
            let base = settings.baseURL(for: kind)
            guard let url = URL(string: base)?.appending(path: "models") else {
                throw TranslationFailure.badResponse(-1, "API 地址无效")
            }
            return try await ids(
                from: url, headers: ["Authorization": "Bearer \(apiKey)"], shape: .openAI
            )

        case .claude:
            return try await ids(
                from: URL(string: "https://api.anthropic.com/v1/models?limit=100")!,
                headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"],
                shape: .openAI
            )

        case .gemini:
            return try await ids(
                from: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!,
                headers: ["x-goog-api-key": apiKey],
                shape: .gemini
            )

        case .ollama:
            let host = settings.ollamaHost
            guard let url = URL(string: host)?.appending(path: "api/tags") else {
                throw TranslationFailure.badResponse(-1, "Ollama 地址无效")
            }
            return try await ids(from: url, headers: [:], shape: .ollama)

        case .appleTranslate, .appleDictionary, .googleWeb, .deepL:
            return []   // fixed capability, nothing to enumerate
        }
    }

    private enum Shape { case openAI, gemini, ollama }

    private static func ids(
        from url: URL, headers: [String: String], shape: Shape
    ) async throws -> [String] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TranslationFailure.badResponse(
                code, String(data: data, encoding: .utf8) ?? ""
            )
        }

        switch shape {
        case .openAI:
            return try JSONDecoder().decode(OpenAIList.self, from: data).data.map(\.id)
        case .gemini:
            // Gemini qualifies every name as "models/gemini-…"; the API wants
            // the bare id back.
            return try JSONDecoder().decode(GeminiList.self, from: data).models
                .map { $0.name.replacingOccurrences(of: "models/", with: "") }
        case .ollama:
            return try JSONDecoder().decode(OllamaList.self, from: data).models.map(\.name)
        }
    }

    private struct OpenAIList: Decodable {
        let data: [Item]
        struct Item: Decodable { let id: String }
    }
    private struct GeminiList: Decodable {
        let models: [Item]
        struct Item: Decodable { let name: String }
    }
    private struct OllamaList: Decodable {
        let models: [Item]
        struct Item: Decodable { let name: String }
    }
}

import Foundation
import Translation

/// On-device translation via Apple's Translation framework. No key, no network,
/// and it is the only provider guaranteed to work offline — so it doubles as
/// Lumi's always-available fallback.
struct AppleProvider: TranslationProvider {
    let kind = ServiceKind.appleTranslate
    let requiresNetwork = false

    func availability(for request: TranslationRequest) async -> ProviderAvailability {
        guard let source = request.source.localeLanguage,
              let target = request.target.localeLanguage else {
            return .unavailable("语言未指定")
        }
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:   return .ready
        case .supported:   return .needsSetup("需先在「系统设置 › 通用 › 语言与地区 › 翻译语言」下载语言包")
        case .unsupported: return .unavailable("系统翻译不支持此语言对")
        @unknown default:  return .unavailable("未知状态")
        }
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        oneShot(timeout: 15) {
            try await Self.run(request)
        }
    }

    // TranslationSession is a non-Sendable class, so it is created and consumed
    // entirely on the main actor. Its `translate` is genuinely async — the
    // inference runs out of process — so this never blocks the UI.
    @MainActor
    private static func run(_ request: TranslationRequest) async throws -> String {
        guard let source = request.source.localeLanguage else {
            throw TranslationFailure.unsupportedPair
        }
        let session = TranslationSession(
            installedSource: source,
            target: request.target.localeLanguage
        )
        return try await session.translate(request.text).targetText
    }
}

enum TranslationFailure: LocalizedError {
    case unsupportedPair
    case missingKey(String)
    case badResponse(Int, String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .unsupportedPair:           "不支持的语言对"
        case .missingKey(let provider):  "\(provider) 缺少 API Key，请在设置中填写"
        case .badResponse(let code, let body):
            "服务返回 \(code)：\(body.prefix(200))"
        case .emptyResult:               "服务返回了空结果"
        }
    }
}

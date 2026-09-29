import AVFoundation

@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synthesizer = AVSpeechSynthesizer()
    private init() {}

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String, language: Language) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: voiceCode(language))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    /// AVSpeechSynthesisVoice wants region-qualified tags, not bare ISO codes.
    private func voiceCode(_ language: Language) -> String {
        switch language {
        case .simplifiedChinese:  "zh-CN"
        case .traditionalChinese: "zh-TW"
        case .english:            "en-US"
        case .japanese:           "ja-JP"
        case .korean:             "ko-KR"
        case .french:             "fr-FR"
        case .german:             "de-DE"
        case .spanish:            "es-ES"
        case .italian:            "it-IT"
        case .portuguese:         "pt-BR"
        case .russian:            "ru-RU"
        case .arabic:             "ar-SA"
        case .auto:               "en-US"
        }
    }
}

import Foundation

/// Every service Lumi can query.
///
/// Most LLM vendors speak OpenAI's Chat Completions protocol, so they differ
/// only by base URL, key and model name — they share one implementation and are
/// separated here purely so each can carry its own credentials and appear as
/// its own card. Claude, Gemini and DeepL have their own wire formats.
enum ServiceKind: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    // Keyless
    case appleTranslate, appleDictionary, google
    // OpenAI-compatible wire protocol
    case openAI, deepseek, groq, moonshot, siliconflow, xai, openrouter, customOpenAI
    // Own protocols
    case claude, gemini, deepL
    // Local
    case ollama

    var id: String { rawValue }

    enum Family: Sendable {
        case appleTranslate, appleDictionary, googleWeb
        case openAICompatible, claude, gemini, deepL, ollama
    }

    var family: Family {
        switch self {
        case .appleTranslate:  .appleTranslate
        case .appleDictionary: .appleDictionary
        case .google:          .googleWeb
        case .claude:          .claude
        case .gemini:          .gemini
        case .deepL:           .deepL
        case .ollama:          .ollama
        case .openAI, .deepseek, .groq, .moonshot,
             .siliconflow, .xai, .openrouter, .customOpenAI:
            .openAICompatible
        }
    }

    /// Whether this service is a general language model rather than a
    /// fixed-function translation API.
    ///
    /// The distinction matters exactly once: only an LLM can be handed a
    /// document's title, glossary and preceding paragraph and do something with
    /// them. DeepL and the system translator are better than an LLM at plain
    /// sentences and cannot be instructed at all.
    var isLLM: Bool {
        switch family {
        case .openAICompatible, .claude, .gemini, .ollama: true
        case .appleTranslate, .appleDictionary, .googleWeb, .deepL: false
        }
    }

    var displayName: String {
        switch self {
        case .appleTranslate:  "系统翻译"
        case .appleDictionary: "系统词典"
        case .google:          "Google 网页"
        case .openAI:          "OpenAI"
        case .deepseek:        "DeepSeek"
        case .groq:            "Groq"
        case .moonshot:        "Moonshot"
        case .siliconflow:     "SiliconFlow"
        case .xai:             "xAI"
        case .openrouter:      "OpenRouter"
        case .customOpenAI:    "自定义（OpenAI 兼容）"
        case .claude:          "Claude"
        case .gemini:          "Gemini"
        case .deepL:           "DeepL"
        case .ollama:          "本地模型"
        }
    }

    var symbolName: String {
        switch self {
        case .appleTranslate:  "apple.logo"
        case .appleDictionary: "character.book.closed"
        case .google, .deepL:  "globe"
        case .ollama:          "desktopcomputer"
        case .customOpenAI:    "slider.horizontal.3"
        default:               "sparkles"
        }
    }

    var needsKey: Bool {
        switch family {
        case .appleTranslate, .appleDictionary, .googleWeb, .ollama: false
        case .openAICompatible, .claude, .gemini, .deepL:            true
        }
    }

    var keychainAccount: String { "service.\(rawValue).key" }

    /// Shipped defaults, verified against each vendor's docs at the date in
    /// `modelsVerified`. They go stale fast — every one of these had already
    /// changed within months — so they are only a starting point: the field is
    /// free text, and `ModelDirectory` can pull the live list from the vendor.
    static let modelsVerified = "2026-09-19"

    var defaultModel: String {
        switch self {
        case .openAI:       "gpt-5.6-sol"
        case .deepseek:     "deepseek-flash"
        case .groq:         "openai/gpt-oss-120b"
        case .moonshot:     "kimi-k2.6"
        case .siliconflow:  "Pro/deepseek-ai/DeepSeek-R1"
        case .xai:          "grok-4.6"
        case .openrouter:   "openai/gpt-5.6-sol"
        case .customOpenAI: ""
        case .claude:       "claude-opus-5"
        case .gemini:       "gemini-3.8-flash"
        default:            ""
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .openAI:      ["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-6-astra"]
        case .deepseek:    ["deepseek-flash", "deepseek-v4-pro"]
        case .groq:        ["openai/gpt-oss-120b", "openai/gpt-oss-20b",
                            "llama-3.1-8b-instant", "llama-3.3-70b-versatile"]
        // k3 always reasons, which is the wrong trade for a translation popup.
        case .moonshot:    ["kimi-k2.6", "kimi-k3"]
        case .siliconflow: ["Pro/deepseek-ai/DeepSeek-R1"]
        case .xai:         ["grok-4.6", "grok-4.5", "grok-4.3"]
        case .openrouter:  ["openai/gpt-5.6-sol", "anthropic/claude-opus-5",
                            "deepseek/deepseek-flash"]
        case .claude:      ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
        case .gemini:      ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.1-pro-preview"]
        default:           []
        }
    }

    /// Model names this app once shipped as a default and the vendor has since
    /// retired. A stored value matching one of these is cleared on launch so it
    /// falls back to the current default instead of failing with an opaque 400.
    static let retiredModels: Set<String> = [
        "deepseek-chat", "deepseek-reasoner", "deepseek-v4-flash",
        "gpt-4.1", "gpt-4.1-mini",
        "gemini-2.5-flash", "gemini-2.5-pro",
        "grok-3", "grok-3-mini",
        "moonshot-v1-8k", "moonshot-v1-32k",
        "Qwen/Qwen2.5-7B-Instruct",
        "openai/gpt-4.1", "anthropic/claude-opus-5-20250101",
    ]

    var defaultBaseURL: String {
        switch self {
        case .openAI:       "https://api.openai.com/v1"
        case .deepseek:     "https://api.deepseek.com/v1"
        case .groq:         "https://api.groq.com/openai/v1"
        case .moonshot:     "https://api.moonshot.cn/v1"
        case .siliconflow:  "https://api.siliconflow.cn/v1"
        case .xai:          "https://api.x.ai/v1"
        case .openrouter:   "https://openrouter.ai/api/v1"
        case .customOpenAI: ""
        default:            ""
        }
    }

    /// Where to get a key, linked from Settings so the user isn't left guessing.
    var keyPageURL: URL? {
        switch self {
        case .openAI:      URL(string: "https://platform.openai.com/api-keys")
        case .deepseek:    URL(string: "https://platform.deepseek.com/api_keys")
        case .groq:        URL(string: "https://console.groq.com/keys")
        case .moonshot:    URL(string: "https://platform.kimi.com/console/api-keys")
        case .siliconflow: URL(string: "https://cloud.siliconflow.cn/account/ak")
        case .xai:         URL(string: "https://console.x.ai")
        case .openrouter:  URL(string: "https://openrouter.ai/keys")
        case .claude:      URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini:      URL(string: "https://aistudio.google.com/apikey")
        case .deepL:       URL(string: "https://www.deepl.com/pro-api")
        default:           nil
        }
    }

    /// Display order in settings and in the result stack.
    /// Also the default fallback ladder, because the panel shows the
    /// highest-priority service that actually produced something.
    ///
    /// The dictionary leads: for a single word it is both the richest answer
    /// and the fastest, and it bows out on its own for anything that is not a
    /// word. Apple Translate trails everything, not because it is worst but
    /// because it is the only rung that survives with the Wi-Fi off — a last
    /// resort is only a last resort if nothing is below it.
    static let catalogOrder: [ServiceKind] = [
        .appleDictionary, .claude, .openAI, .deepseek, .gemini, .groq,
        .moonshot, .siliconflow, .xai, .openrouter, .customOpenAI, .ollama,
        .deepL, .google, .appleTranslate,
    ]

    /// Whether a model name applies at all — the fixed-capability services
    /// (system translate, dictionary, DeepL, the free web endpoint) have none.
    var canEnumerateModels: Bool {
        switch family {
        case .openAICompatible, .claude, .gemini, .ollama: true
        case .appleTranslate, .appleDictionary, .googleWeb, .deepL: false
        }
    }

    var section: String {
        switch family {
        case .appleTranslate, .appleDictionary: "系统内置（离线、免密钥）"
        case .googleWeb, .deepL:                "翻译服务"
        case .ollama:                           "本地模型"
        default:                                "大模型"
        }
    }
}

/// 英文文案表：翻译服务与桥。
///
/// key 是中文原文（`Translate/*.swift`、`PageBridge/*.swift`、`Speech/*.swift`
/// 里 `t(...)` / `tDetached(...)` 的实参），value 是对应英文。
/// 加条目就是加一行：`"暂不可用": "Not available",`
/// 查表与回落规则见 `Core/Localization.swift`。
enum ServiceStrings {
    static let english: [String: String] = [
        // ServiceKind.displayName / section
        "系统翻译": "System Translate",
        "系统词典": "System Dictionary",
        "Google 网页": "Google Web",
        "自定义（OpenAI 兼容）": "Custom (OpenAI-compatible)",
        "本地模型": "Local Model",
        "系统内置（离线、免密钥）": "System built-in (offline, no key)",
        "翻译服务": "Translation services",
        "大模型": "Large language models",

        // AppleProvider
        "语言未指定": "Language not specified",
        "需先在「系统设置 › 通用 › 语言与地区 › 翻译语言」下载语言包":
            "First download the language pack in System Settings › General › Language & Region › Translation Languages",
        "系统翻译不支持此语言对": "System Translate doesn't support this language pair",
        "未知状态": "Unknown state",
        "不支持的语言对": "Unsupported language pair",
        "%@ 缺少 API Key，请在设置中填写": "%@ API key missing — add it in Settings",
        "服务返回 %d：%@": "Service returned %d: %@",
        "服务返回了空结果": "The service returned an empty result",
        "无效响应": "Invalid response",

        // AppleDictionaryProvider
        "查不到": "No entry",

        // WebProvider
        "在线翻译不可用": "Online translation unavailable",

        // DeepLProvider
        "请在设置中填写 DeepL API Key": "Enter your DeepL API key in Settings",
        "DeepL 不支持此目标语言": "DeepL doesn't support this target language",

        // ClaudeProvider
        "请在设置中填写 Claude API Key": "Enter your Claude API key in Settings",

        // GeminiProvider
        "请填写模型名": "Enter a model name",
        "请在设置中填写 Gemini API Key": "Enter your Gemini API key in Settings",
        "模型名无效": "Invalid model name",

        // OllamaProvider
        "请在设置中选择本地模型": "Choose a local model in Settings",
        "Ollama 无响应": "Ollama is not responding",
        "未检测到运行中的 Ollama，请先启动 `ollama serve`":
            "No running Ollama detected — start it with `ollama serve` first",

        // OpenAICompatibleProvider
        "请填写 API 地址": "Enter the API base URL",
        "请在设置中填写 %@ API Key": "Enter your %@ API key in Settings",
        "API 地址无效": "Invalid API base URL",

        // ModelDirectory
        "没有返回模型": "No models returned",
        "Ollama 地址无效": "Invalid Ollama address",

        // PageTranslator
        "不支持的目标语言 %@": "Unsupported target language: %@",
        "%@ 不可用": "%@ unavailable",
        "超时未返回": "Timed out with no response",
    ]
}

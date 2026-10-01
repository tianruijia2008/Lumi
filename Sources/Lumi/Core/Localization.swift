import Foundation
import Observation
import Synchronization

/// 界面语言。
///
/// 只做界面文案，**不影响**被翻译的内容：发给模型的服务/提示词、维基词典的解析、
/// 词典格式判断都跟这个设置无关（见 STRUCTURE.md「界面语言」一节）。
enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case zhHans = "zh-Hans"
    case en = "en"

    var id: String { rawValue }

    /// 语言选择器里显示的名字用**该语言自己的写法**：英文界面里也要能认出
    /// 「简体中文」，否则一个只看得懂中文的人会找不到回中文的路。
    var displayName: String {
        switch self {
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }

    /// 首次启动跟随系统：中文系统给中文，其余给英文。用户改过之后以他的选择为准。
    static var systemDefault: AppLanguage {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return code == "zh" ? .zhHans : .en
    }
}

/// 当前语言的线程安全快照。
///
/// 写只发生在 main actor（设置界面），但读可能发生在任何线程——provider 的
/// `availability` 消息就是在非隔离上下文里拼出来的，所以不能只靠 main actor。
private let languageSnapshot = Mutex<AppLanguage>(AppLanguage.systemDefault)

/// 界面语言的**单一真相源**（持久化在本类里，不经过 `AppSettings`）。
///
/// 为什么不放 AppSettings：只要 `AppSettings.swift` 里出现对 `Localization` 的引用，
/// 那个文件的类型检查就会在 `activeProviders()` 的 `compactMap` 上报
/// “ElementOfResult 无法推断”（实测两次），而 AppSettings 是 Core 的类型推断重灾区。
/// 语言本来也是一件独立的事（密钥就存在 Keychain 而不在 AppSettings），单独存放更干净。
@MainActor @Observable
final class Localization {
    static let shared = Localization()

    /// 视图读它就会在切换语言时重绘（@Observable 的依赖追踪）。
    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            languageSnapshot.withLock { $0 = language }
        }
    }

    private static let defaultsKey = "appLanguage"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        language = AppLanguage(rawValue: stored) ?? .systemDefault
        languageSnapshot.withLock { $0 = language }
    }
}

/// 取界面文案。`zh` 是中文原文，同时充当查表的 key；英文表里没有就回落中文
/// （安全失败：宁可显示中文，也不要显示 key 或空白）。
///
/// 只在 main actor 上调用（视图、`AppState`、`AppSettings` 这类 MainActor 类型）。
@MainActor
func t(_ zh: String) -> String {
    let _ = Localization.shared.language      // 建立依赖：切语言时视图会重绘
    guard Localization.shared.language == .en else { return zh }
    return englishStrings[zh] ?? zh
}

/// 带参数的版本。占位符用 `String(format:)` 的规则（`%@` / `%d`），
/// 中英两边**顺序可以不同**——这正是英文要单独写一条的原因。
///
///     t("已翻译 %d / %d 段", done, total)
@MainActor
func t(_ zh: String, _ arguments: CVarArg...) -> String {
    String(format: t(zh), locale: nil, arguments: arguments)
}

/// 非 main actor 上下文（`TranslationProvider`、`WorkbenchEngine`、给扩展的响应……）
/// 用这个：查同一张表，读的是 Mutex 快照。它不会触发视图重绘——那些地方也不画界面，
/// 拼出来的字符串最终都会交给 MainActor 的界面去显示。
func tDetached(_ zh: String) -> String {
    guard languageSnapshot.withLock({ $0 }) == .en else { return zh }
    return englishStrings[zh] ?? zh
}

func tDetached(_ zh: String, _ arguments: CVarArg...) -> String {
    String(format: tDetached(zh), locale: nil, arguments: arguments)
}

/// 所有区域的英文表。一个区域一个文件，改动互不冲突。
let englishStrings: [String: String] = [
    CoreStrings.english,
    PanelStrings.english,
    SettingsStrings.english,
    WorkbenchStrings.english,
    EtymologyStrings.english,
    ServiceStrings.english,
].reduce(into: [:]) { merged, table in
    merged.merge(table) { _, new in new }
}

// MARK: - 加文案时怎么做

// 1. 把中文字面量包进 t(...)：`Text("设置")` -> `Text(t("设置"))`
//    —— 中文**原样保留**，它是 key，改写它等于丢翻译（`scripts/security-scan.py`
//    的 i18n 检查会报出来）。
// 2. 到对应区域的表里加一条：`"设置": "Settings",`
// 3. 插值改成占位符：`t("已翻译 \(n) 段")` -> `t("已翻译 %d 段", n)`
// 4. 非 main actor 上下文用 `tDetached(...)`。
// 5. 不要翻译：注释、日志、LLM 提示词（`Translate/Prompts.swift`）、
//    维基/HTTP 参数、词典解析规则、以及用户自己的数据。

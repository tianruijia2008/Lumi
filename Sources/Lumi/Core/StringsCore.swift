/// 英文文案表：Core 区域。
///
/// key 是中文原文（Core/*.swift 里 `t(...)` 的实参），value 是对应英文。
/// 加条目就是加一行：`"设置": "Settings",`
/// 查表与回落规则见 `Core/Localization.swift`。
enum CoreStrings {
    static let english: [String: String] = [
        "等待中": "Waiting",
        "正在输出": "Streaming",
        "已完成": "Done",
        "离线不可用": "Offline",
        "离线，已回退到「%@」": "Offline — fell back to %@",
        "%@%@，改用「%@」": "%@ %@ — using %@ instead",
        "没有启用任何翻译服务，请在设置中开启至少一个。": "No translation services are enabled. Enable at least one in Settings.",
        "已取消": "Canceled",
        "无结果": "No results",
        "查不到": "No entry",
        "自动检测": "Auto Detect",
        "超时（%.0f 秒无响应）": "Timed out (no response in %.0f seconds)",
        "空格": "Space",
        "翻译选中文本": "Translate Selection",
        "打开输入框": "Open Input",
        "截图翻译": "Translate Screenshot",
        "打开工作台": "Open Workbench",
        "翻译选中文本  %@": "Translate Selection  %@",
        "打开输入框  %@": "Open Input  %@",
        "截图翻译  %@": "Translate Screenshot  %@",
        "工作台  %@": "Workbench  %@",
        "设置…": "Settings…",
        "退出 Lumi": "Quit Lumi",
        "没有取到选中的文本。试试先选中再按快捷键，或直接在上面输入。": "No selected text was found. Select some text and try the shortcut again, or type in the field above.",
        "这块区域里没有识别到文字。": "No text was recognized in that area.",
        "截图识别失败：%@": "Screenshot recognition failed: %@",
    ]
}

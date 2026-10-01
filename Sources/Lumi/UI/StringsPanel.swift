/// 英文文案表：面板区域。
///
/// key 是中文原文（UI/ 下面板相关的文件 里 `t(...)` 的实参），value 是对应英文。
/// 加条目就是加一行：`"设置": "Settings",`
/// 查表与回落规则见 `Core/Localization.swift`。
enum PanelStrings {
    static let english: [String: String] = [
        "已固定，点击别处不会收起": "Pinned; clicking elsewhere won't dismiss it",
        "固定窗口": "Pin Window",
        "设置": "Settings",
        "对调方向": "Swap Direction",
        "自动": "Auto",
        "输入或粘贴要翻译的文本": "Type or paste text to translate",
        "停止": "Stop",
        "清空": "Clear",
        "收起": "Collapse",
        "展开全文": "Show Full Text",
        "朗读": "Speak",
        "重新查询": "Query Again",
        "复制": "Copy",
        "来历": "Origin",
        "深究": "Explore",
        "在工作台里看 %@ 的完整词源": "View %@'s full etymology in Workbench",
        "联网": "Online",
        "本机": "On-device",
        "新文稿": "New Document",
        "输入或粘贴原文，逐段对照着读。漏掉的句子会被标出来。":
            "Type or paste the source text to read it against the translation, paragraph by paragraph. Missing sentences are flagged.",
        "在这里粘贴原文，或把选中的文字拖进来": "Paste the source text here, or drag in a selection",
        "这是一篇什么文章？术语、语体上有什么要求？（可留空）":
            "What kind of text is this? Any terminology or style requirements? (Optional)",
        "本机翻译逐句工作，读不到这些说明——换成联网才会用上。":
            "On-device translation works sentence by sentence and can't read these notes — switch to Online to use them.",
        "按标题、列表、表格分段；代码块和公式原样保留，不翻译":
            "Split by headings, lists, and tables; code blocks and formulas are kept verbatim, not translated",
        "开始": "Start",
        "校对译文": "Proofread Translation",
        "放进原文和译文，逐段标出漏译、错译和前后不一的术语。":
            "Add the source and translation to flag omissions, mistranslations, and inconsistent terminology paragraph by paragraph.",
        "原文": "Source",
        "译文": "Translation",
        "打开文件…": "Open File…",
        "粘贴原文，或把 .txt、.md 文件拖进来": "Paste the source, or drag in a .txt or .md file",
        "粘贴要校对的译文": "Paste the translation to proofread",
        "字": "characters",
        "词": "words",
        "术语表和要求（可留空）。术语每行一条，如：attention = 注意力":
            "Glossary and requirements (optional). One term per line, e.g. attention = focus",
        "识别到 %d 条术语，每段都会核对译法。":
            "Found %d terms; each paragraph is checked against the glossary.",
        "按标题、列表、表格对齐，代码块不参与校对":
            "Align by headings, lists, and tables; code blocks are excluded from proofreading",
        "正在按意思对齐段落…": "Aligning paragraphs by meaning…",
        "对齐中": "Aligning",
        "开始校对": "Start Proofreading",
        "本机只做机检：数字、术语表、格式、篇幅":
            "On-device only runs mechanical checks: numbers, glossary, formatting, and length.",
        "没有启用语言模型，只能做机检":
            "No language model is enabled, so only mechanical checks are available.",
        "%@ 逐段审读意思，外加机检": "%@ reviews meaning paragraph by paragraph, plus mechanical checks.",
        // 「离线不可用」由 Core 表持有（ResultCard.reason 的状态词 Offline）：
        // 同一句中文只能有一张表定义它，合并后查表照样命中。
    ]
}

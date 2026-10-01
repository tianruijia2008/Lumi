/// 英文文案表：词源区域。
///
/// key 是中文原文（Etymology/*.swift 与 UI/Etymology*.swift 里 `t(...)` 的实参），value 是对应英文。
/// 加条目就是加一行：`"设置": "Settings",`
/// 查表与回落规则见 `Core/Localization.swift`。
enum EtymologyStrings {
    static let english: [String: String] = [
        // SenseStatus
        "还在用": "in use",
        "渐少": "fading",
        "已不用": "obsolete",

        // （词性名不在这张表里：见 EtymologyEntry.partsOfSpeechEnglish）

        // EtymologyStore
        "需要联网才能查 Wiktionary。": "A network connection is needed to look up Wiktionary.",
        "还没有启用语言模型。在设置里开启一个并填好 API Key，或改用本机。": "No language model is enabled yet. Turn one on in Settings and fill in its API key, or use on-device instead.",
        "当前离线，讲解需要联网。下面的资料不受影响。": "You're offline, and the narrative needs a connection. The material below is unaffected.",
        "模型没有返回内容": "The model returned no content.",

        // Wiktionary
        "Wiktionary 没有这个词条": "Wiktionary has no entry for this word.",
        "Wiktionary 返回异常：%@": "Wiktionary returned an error: %@",
        "缺少正文": "missing content",
        "无法解析": "couldn't parse",
        "未知错误": "unknown error",

        // EtymologyView
        "所有资料都来自 Wiktionary，点击打开原词条": "Everything comes from Wiktionary. Click to open the original entry.",
        "讲解": "Narrative",
        "%@ 在整理讲解": "%@ is writing the narrative",
        "只整理 Wiktionary 的资料，引文用系统翻译。不联网调用模型。": "Only organizes Wiktionary material; quotations use the system translator. No online model calls.",
        "由语言模型把资料串成一段讲解，每句标出处；引文也交给它翻译。": "A language model weaves the material into a narrative, citing each claim; quotations are also translated by it.",
        "拷贝本页文字": "Copy this page's text",
        "在 Wiktionary 中打开": "Open in Wiktionary",
        "重写讲解": "Rewrite narrative",
        "重新获取": "Fetch again",
        "%d 个义项": "%d senses",
        "%d 条引文": "%d quotations",
        "资料来源：Wiktionary（CC BY-SA 4.0）": "Source: Wiktionary (CC BY-SA 4.0)",
        "重试": "Retry",
        "从最早能追到的地方，到今天": "From the earliest it can be traced, to today",
        "进入英语": "entered English",
        "%d 步": "%d steps",
        "从最早到今天": "earliest to today",
        "个意思已不用或少用": "senses now obsolete or rare",
        "本机模式只整理资料，不写讲解。切到 AI，会把下面几部分串成一段话，每句标出处。": "On-device mode only organizes the material; it doesn't write a narrative. Switch to AI to weave the sections below into a paragraph, each claim cited.",
        "切到 AI": "Switch to AI",
        "讲解没写成：%@": "Couldn't write the narrative: %@",
        "%@ 按本页资料整理 · 圈号是下面的引文 · 资料里没有的不写": "%@ organized from this page's material · circled numbers are the quotations below · nothing is written that isn't in the material",
        "民间词源": "Folk etymology",
        "流传很广，但 Wiktionary 明确标注这不是它的来历。放在这里，是因为你多半听过这个说法。": "Widely told, but Wiktionary explicitly marks this as not its origin. It's here because you've probably heard it.",
        "虚线：构拟形式，没有文字记录，是语言学家倒推出来的": "Dashed: reconstructed forms with no written record, inferred by linguists",
        "实线：有文献": "Solid: attested in writing",
        "构拟形式：没有文字记录，由语言学家根据后代语言倒推": "Reconstructed form: no written record, inferred by linguists from descendant languages",
        "英语 · 今天": "English · today",
        "%@ · 构拟": "%@ · reconstructed",
        "词义变迁": "Meaning shifts",
        "每条横线是一个意思活着的年代": "Each bar is the years a meaning was in use",
        "另有 %d 个义项没有年代标注：": "Another %d senses have no dates: ",
        "义项": "Senses",
        "这一条没有年代标注，画不出时间线，只列义项。不拿 AI 去猜年代。": "This entry has no dates, so there's no timeline to draw — just the senses. We don't ask AI to guess dates.",
        "圆圈是下面的引文 · 年代只精确到世纪": "Circles are the quotations below · dates are only to the century",
        "少见": "rare",
        "引文": "Quotations",
        "按年代": "by date",
        "Wiktionary 这一条没有带年份的引文。资料少就显示少，不让 AI 补例句。": "Wiktionary has no dated quotations for this entry. We show the little there is rather than have AI invent examples.",
        "这一条的引文就这么多。资料少就显示少，不让 AI 补例句。": "These are all the quotations this entry has. We show the little there is rather than have AI invent examples.",
        "同根词": "Cognates",
        "同一词根": "Same root",
        "资料": "Sources",
        "CC BY-SA 4.0 · %@ 取得": "CC BY-SA 4.0 · retrieved %@",
        "引文年代是词条自带的标注，不是推算的": "Quotation dates are the entry's own labels, not estimates",
        "前后": "c.",
        "查 %@ 的词源": "Look up the etymology of %@",

        // EtymologyHome
        "只查单个英文单词。句子和其他语言，交给面板。": "Single English words only. Sentences and other languages go to the panel.",
        "只查英文单词。句子和其他语言，交给面板。": "English words only. Sentences and other languages go to the panel.",
        "今日一词": "Word of the day",
        "每天换一个": "a new one every day",
        "有故事的词": "Words with a story",
        "意思变得最远的几个": "the ones whose meanings wandered furthest",
        "面板": "Panel",
        "在面板里查一个英文单词，词典下面那行「来历」点「深究」，也会来到这里。": "Look up an English word in the panel and click “Dig deeper” on its “Origin” line to get here.",
        "词源": "Etymology",
        "英文单词从哪来、意思怎么变过来、历代怎么用": "Where English words come from, how their meanings shifted, and how they've been used",
        "输入一个英文单词": "Enter an English word",
        "有民间词源": "Has a folk etymology",
        "%@进入英语": "entered English in the %@",
        "意思怎么一步步变过来": "How the meaning changed, step by step",
        "打开 %@": "Open %@",
    ]
}

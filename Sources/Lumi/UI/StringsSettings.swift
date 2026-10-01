/// 英文文案表：设置区域。
///
/// key 是中文原文（UI/SettingsView.swift 等设置界面 里 `t(...)` 的实参），value 是对应英文。
/// 加条目就是加一行：`"设置": "Settings",`
/// 查表与回落规则见 `Core/Localization.swift`。
enum SettingsStrings {
    static let english: [String: String] = [
        // 语言选择器
        "界面语言": "Interface Language",
        "只影响界面文字。翻译结果、提示词和词源解析始终按原文处理。":
            "Affects the interface only — translations, prompts and etymology parsing always follow the source text.",
        // 设置窗口 · 标签页
        "通用": "General",
        "网页翻译": "Web Translation",
        "权限": "Permissions",

        // 通用 › 查询语言
        "查询语言": "Lookup Languages",
        "第一语言（通常是母语）": "First Language (usually your native language)",
        "第二语言": "Second Language",
        "方向会自动对调：第一语言的文本译到第二语言，反之亦然。所以同一个快捷键中英文都能用，不必每次去改目标语言。":
            "The direction flips automatically: text in the first language is translated into the second, and vice versa. So the same shortcut works in both directions — no need to change the target language each time.",

        // 通用 › 外观
        "外观": "Appearance",
        "主题": "Theme",
        "跟随系统": "Follow System",
        "浅色": "Light",
        "深色": "Dark",
        "字号": "Font Size",
        "小": "Small",
        "大": "Large",
        "结果区最高": "Maximum Result Height",
        "窗口宽度": "Window Width",

        // 通用 › 查询行为
        "查询行为": "Lookup Behavior",
        "输入框折叠行数": "Collapse Input After",
        "%d 行": "%d lines",
        "超过这个行数时输入框会收起，右侧出现展开按钮 —— 长句的译文才不会被挤出窗口。":
            "When the input exceeds this many lines, it collapses and an expand button appears on the right — so long translations don't get squeezed out of the window.",
        "翻译后自动复制结果": "Auto-copy result after translation",
        "查单词后自动朗读": "Auto-read after looking up a word",
        "翻译后清空输入框": "Clear input after translation",
        "取词为空时保留上次结果": "Keep previous result when selection is empty",
        "出结果时播放提示音": "Play a sound when a result arrives",
        "自动复制和自动朗读只作用于最先返回的那个服务 —— 多个服务并发出结果，让最后到的去覆盖剪贴板或盖着前一个念，都不是「自动」该有的行为。":
            "Auto-copy and auto-read only apply to the service that returns first — when several services answer at once, letting the last one overwrite the clipboard or speak over the previous one isn't what \"auto\" should do.",

        // 通用 › 窗口
        "窗口": "Window",
        "固定窗口（点击别处不自动收起）": "Pin window (don't dismiss when clicking elsewhere)",
        "跟随鼠标位置": "Follow the mouse",
        "使用你上次摆放的位置": "Use your last position",
        "重置为跟随鼠标": "Reset to Follow Mouse",

        // 通用 › 快捷键
        "快捷键": "Keyboard Shortcuts",
        "点击快捷键按钮后直接按下新组合，Esc 取消。":
            "Click a shortcut button, then press the new combination. Press Esc to cancel.",
        "按下新快捷键…": "Press new shortcut…",
        "恢复默认": "Restore Default",
        "至少要带一个修饰键": "Must include at least one modifier key",
        "与「%@」冲突": "Conflicts with %@",

        // 通用 › 启动
        "启动": "Launch at Login",
        "登录时自动启动": "Launch at login",
        "已登记，请到「系统设置 › 通用 › 登录项」中允许。":
            "Registered. Allow it in System Settings › General › Login Items.",
        "需要先把 Lumi 移动到「应用程序」文件夹。登录项绑定 App 的路径，从构建目录登记会在你挪动它之后失效。":
            "First move Lumi into the Applications folder. Login items are bound to the app's path — registering from the build directory breaks when you move it.",
        "打开登录项": "Open Login Items",

        // 翻译服务
        "查询顺序": "Query Order",
        "这些服务会被同时查询，但面板显示的是其中排最前、且真的给出了结果的那一个。                词典查不到词条、或者离线时联网服务用不了，就自动落到下一个。把最信任的放在最上面。":
            "These services are all queried at once, but the panel shows the topmost one that actually returned a result. When the dictionary finds no entry, or an online service is unusable offline, it falls through to the next one. Put the one you trust most at the top.",
        "大模型通用": "General (Large Language Models)",
        "推理强度": "Reasoning Effort",
        "低（最快，翻译够用）": "Low (fastest, good enough)",
        "中": "Medium",
        "高（长句更准，较慢）": "High (more accurate on long text, slower)",
        "密钥一律保存在系统钥匙串，不写入配置文件。内置的模型名核对于 %@，厂商改名很频繁 —— 用模型框旁边的 ↻ 按钮直接向服务商拉取当前列表。":
            "Keys are stored in the system keychain, never in the config file. Built-in model names were verified as of %@ — vendors rename models often, so use the ↻ button next to the model field to pull the current list from the provider.",
        "语言包已下载，离线可用": "Language pack downloaded, available offline",
        "语言包未下载 —— 离线时回退到这里会落空": "Language pack not downloaded — offline fallback to this will fail",
        "系统翻译不支持当前语言对": "System translation doesn't support this language pair",
        "正在检查语言包…": "Checking language pack…",
        "打开语言设置": "Open Language Settings",
        "模型": "Model",
        "拉取模型失败：%@": "Failed to fetch models: %@",
        "模型列表已从服务商更新。": "The model list has been updated from the provider.",
        "从服务商拉取当前可用模型": "Fetch the currently available models from the provider",
        "API 地址": "API URL",
        "Ollama 地址": "Ollama URL",
        "需先运行 `ollama serve`，并用 `ollama pull` 下载一个本地模型。":
            "Run `ollama serve` first, then download a local model with `ollama pull`.",
        "获取": "Get",
        "免费版和专业版共用此处：密钥以 `:fx` 结尾会自动走免费接口。":
            "Free and Pro share this field: a key ending in `:fx` automatically uses the free endpoint.",

        // 权限
        "辅助功能": "Accessibility",
        "用于读取其他 App 里选中的文本。未授权时快捷键取词无法工作。":
            "Used to read selected text in other apps. Without it, hotkey lookup can't work.",
        "屏幕录制": "Screen Recording",
        "截图翻译需要此权限。": "Screenshot translation needs this permission.",
        "已授权": "Authorized",
        "未授权": "Not Authorized",
        "打开设置": "Open Settings",
        "如果系统设置里开关已经打开、这里却仍显示未授权，通常是 App 不是由 访达或 `open` 启动的 —— 直接运行 bundle 里的可执行文件时，系统会把 权限算到启动它的终端头上。":
            "If the switch is already on in System Settings but this still shows as not authorized, the app usually wasn't launched by the Finder or `open` — running the executable inside the bundle directly makes the system attribute the permission to the terminal that launched it.",

        // 网页翻译
        "开启步骤": "Setup Steps",
        "扩展已经连上 Lumi。Safari 重新启动后如果扩展不见了，重做第 1 步。":
            "The extension is connected to Lumi. If it disappears after Safari restarts, redo step 1.",
        "Lumi 用免费开发者证书签名，所以 Safari 每次重新启动后都要再勾一次第 1 步。":
            "Lumi is signed with a free developer certificate, so after every Safari restart you have to check step 1 again.",
        "自动（%@）": "Auto (%@)",
        "选「自动」时依次尝试": "Tried in order when Auto is selected",
        "翻译引擎": "Translation Engine",
        "还没有启用语言模型，扩展会用本机翻译。在「翻译服务」里开启一个 （如 DeepSeek）并填好 API Key，网页就能按上下文翻译。":
            "No language model is enabled yet, so the extension uses on-device translation. Enable one in Translation Services (e.g. DeepSeek) and fill in its API key, and pages will be translated with context.",
        "与工作台共用。大模型会读到网页标题、上一段和你在扩展里写的说明，术语前后一致；本机翻译离线、免费，但只能逐句翻。「自动」挑第一个能用的，Lumi 没开时直接用 Google。":
            "Shared with the workbench. The language model reads the page title, the previous paragraph, and the notes you write in the extension, keeping terminology consistent; on-device translation is offline and free but only translates sentence by sentence. Auto picks the first one that works, and falls back to Google when Lumi isn't running.",
        "翻译整页 / 显示原文": "Translate page / show original",
        "只翻译指针下的那一段": "Translate only the paragraph under the pointer",
        "轻点": "Tap",
        "译文样式、语言、每个网站的说明": "Translation style, language, per-site notes",
        "Safari 工具栏里的 Lumi 按钮": "The Lumi button in Safari's toolbar",
        "在网页上": "On Web Pages",
        "Lumi 网页翻译": "Lumi Page Translate",
        "在 Safari 中设置": "Set Up in Safari",
        "端口 %d 不可用：%@": "Port %d unavailable: %@",
        "Lumi 的网页接口没有启动": "Lumi's web interface isn't running",
        "已连接，按 ⌥T 翻译当前网页": "Connected — press ⌥T to translate the current page",
        "已连接 · 本次启动翻译了 %d 段": "Connected · translated %d segments this session",
        "扩展已开启，打开或刷新一个网页": "Extension is enabled — open or refresh a page",
        "等待 Safari 扩展连接": "Waiting for the Safari extension to connect",
        "Safari 设置 › 开发者 › 勾选「允许未签名的扩展」":
            "Safari Settings › Developer › check \"Allow unsigned extensions\"",
        "Safari 设置 › 扩展 › 勾选「Lumi 网页翻译」":
            "Safari Settings › Extensions › check \"Lumi Page Translate\"",
        "允许它访问网站，然后刷新网页": "Allow it to access websites, then refresh the page",
        "看不到「开发者」：先在「高级」里勾选「显示网页开发者功能」":
            "If you don't see \"Developer\", first check \"Show features for web developers\" in Advanced.",
        "网页右侧出现 Lumi 的玻璃按钮，就是连上了":
            "When Lumi's glass button appears on the right side of the page, it's connected.",
        "不需要 Lumi；逐句翻译，读不到上下文": "Doesn't need Lumi; translates sentence by sentence, no context",
        "Safari 还没发现这个扩展。先完成第 1 步，再点一次。":
            "Safari hasn't found this extension yet. Complete step 1 first, then click again.",
    ]
}

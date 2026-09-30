# Lumi

一个原生的 macOS 取词翻译 / 词典工具，受 [Easydict](https://github.com/tisfeng/Easydict) 启发，代码从零写起。

Swift 6 + SwiftUI，macOS 26+，使用系统原生 Liquid Glass。**不需要 Xcode，也不需要付费开发者账号。**

> **现状**：个人项目，作者自己每天在用，但仍在早期。只支持 macOS 26 及以上；目前没有编译好的安装包，
> 需要按下面的步骤自己编译。业余维护，issue 不保证及时回复。

## 能做什么

- **取词翻译**：选中任意应用里的文字按 ⌥D，或 ⌥A 打开输入框，⌥S 截图识字翻译。
- **多个引擎同时查**：系统词典、系统翻译（断网可用）、Google（非官方网页接口，可能随时失效）、DeepL，以及各家大模型
  （OpenAI、Claude、Gemini、DeepSeek、Ollama、任意 OpenAI 兼容接口）。API Key 只存在系统钥匙串里。
- **网页翻译**：自带 Safari 扩展，在每段原文下面放译文。
- **工作台**（⌥W）：
  - 长文通读：逐段对照阅读，自动标出疑似漏译。
  - 校对别人的译文：按意思对齐段落，机检加模型审读，逐条采纳或忽略。
  - 词源：词源事实来自维基词典，模型只负责讲解。
  - 支持 Markdown 文件，也支持直接粘贴 Markdown 文本，导出时保持原有结构。

## 构建

```bash
./build.sh debug     # 或 release
open build/Lumi.app
```

`build.sh` 做三件事：SwiftPM 编译 → 组装 `.app` bundle → 用本机的免费个人团队证书签名。

签名身份**不在源码里**（个人邮箱和团队 ID 不该进仓库，仓库守卫会拦）。它按顺序找：

```bash
echo "Apple Development: 你的名字 (TEAMID)" > .lumi-identity   # 已被 .gitignore 忽略
LUMI_IDENTITY="Apple Development: 你的名字 (TEAMID)" ./build.sh   # 或一次性给环境变量
security find-identity -v -p codesigning                          # 查自己有哪些身份
```

都没有就会停下来告诉你怎么办（`LUMI_IDENTITY="-"` 可做 ad-hoc 签名，只够验证能编译，
TCC 授权会失效）。身份要保持稳定：换了身份，TCC 会当成另一个 App，「辅助功能」和
「屏幕录制」都要重新授权。

## 运行

```bash
./build.sh debug && ./run.sh
```

**务必用 `run.sh` 或访达启动，不要直接跑 `build/Lumi.app/Contents/MacOS/Lumi`。**
TCC 把「辅助功能」和「屏幕录制」授权归属到 LaunchServices 启动的那个 App；
直接执行 bundle 里的二进制，权限会被算到启动它的终端头上，于是系统设置里开关明明
是开的，App 里 `AXIsProcessTrusted()` 却返回 false。实测确认过。

## 窗口定位

面板存的是**左上角锚点**，不是 AppKit 的左下角原点。原点随高度变化，把它持久化会让
窗口每查询一次就往下挪一点，几轮之后掉出屏幕底部。

结果卡出现时保持顶边不动，用的是**赋值**而不是高度增量。实测下来 hosting view 驱动
resize 时 AppKit 本来就锚定左上角，所以这个赋值通常是空操作；但增量版本会漂移
（AppKit 放大缩小时的锚定行为不一致，补偿会过头），赋值则不可能漂。

边界钳制可能合法地移动锚点（窗口长高到超出屏幕底部），所以钳制后的位置会被采纳为新
锚点，否则下一次 resize 会把它推回去，来回震荡。

## 自测截图

改 UI 时不必找人看屏幕。有两条路，用途不同：

```bash
# 真实窗口：玻璃、输入框、一切所见即所得
./run.sh LUMI_SHOW_ON_LAUNCH=1 LUMI_DEMO_QUERY=学习 \
         LUMI_WINDOW_SHOT=/tmp/shot.png LUMI_SNAPSHOT_DELAY=5 LUMI_SNAPSHOT_QUIT=0

# 离屏渲染：只看版面
./run.sh LUMI_SHOW_ON_LAUNCH=1 LUMI_DEMO_QUERY=学习 \
         LUMI_SNAPSHOT=/tmp/shot.png LUMI_SNAPSHOT_DELAY=4
```

`LUMI_WINDOW_SHOT` 把面板的窗口号交给 `screencapture -l`，拍的是窗口服务器真正
合成出来的那一张 —— 这是唯一能看到玻璃材质的办法。

`LUMI_SNAPSHOT` 走 SwiftUI 的 `ImageRenderer` 离屏渲染。先试过 `cacheDisplay`，
只抓到几何位置 —— 玻璃和结果文本走独立图层合成，画出来是空的。离屏没有背景可
采样，玻璃会渲染成平面，`NSViewRepresentable`（拖拽区、输入框）渲染成黄色占位块；
文字、换行、间距、裁切是准的，迭代排版够用。

其余测试开关：

| 变量 | 作用 |
|---|---|
| `LUMI_DEMO_FOCUS=<服务>` | 3 秒后模拟点击某个服务胶囊 |
| `LUMI_FORCE_OFFLINE=1` | 假装断网，用来跑离线回退这条路径 |
| `LUMI_PANEL_CONTENT=settings` | 把设置界面塞进面板窗口 —— 设置是独立 scene，
脚本打不开也拍不到（agent app 里 `showSettingsWindow:` 不起作用） |
| `LUMI_SETTINGS_TAB=services` | 指定打开哪个标签页 |
| `LUMI_DRAG_MAP=1` | 把可拖动区域打成一张 ASCII 覆盖图 —— 拖动区是透明的，不画出来只能靠猜 |

## 快捷键

| 功能 | 快捷键 |
|---|---|
| 翻译选中文本 | ⌥D |
| 打开输入框 | ⌥A |
| 截图翻译 | ⌥S |
| 打开工作台 | ⌥W |

## 翻译服务与回退链

15 个，启用的会被**同时查询**，互不阻塞。但面板同一时间只显示一个 —— 服务栏
（`ServiceRail`）里排最前、且真的给出了结果的那一个。其余收成胶囊，点一下即切。

这样做的原因是高度：旧版每个服务一张卡，开四个就是四个标题栏、四组图标，
而且每次慢服务返回都会把正在读的文字往下推。现在面板高度与启用了几个服务无关，
迟到的结果只是把一个圆点点亮。

### 回退顺序就是服务顺序

链条里**没有写死任何厂商名**。`AppSettings.orderedServices` 的顺序即回退顺序，
`AppState.promoteFocus()` 取「第一个有内容的」。默认顺序
（`ServiceKind.catalogOrder`）是 系统词典 → 各家大模型 → DeepL/Google → 系统翻译：
词典对单词最快也最全，且不是词条时会自己让位；系统翻译垫底不是因为它最差，
而是因为它是唯一断网还能用的一级 —— 最后一根梯子底下不能还有东西。

焦点有 1.5 秒的宽限期（`AppState.focusGrace`），之后锁死，或者用户点了胶囊就
立刻锁死。没有这个，词典毫秒级返回、大模型几百毫秒返回，正文会在读者眼皮底下
被抽走。

### 断网

断网不靠超时发现。`NetworkMonitor` 常驻 `NWPathMonitor`，需要联网的服务在
**派发之前**就被标成不可用，请求根本不出进程。等 TCP 超时意味着盯着转圈十几秒
才掉到系统翻译，那会让离线变成 App 里最慢的状态 —— 而它本该是最快的。
实测断网时 1.2 秒内结果已经落定。

系统翻译要真的能离线，前提是语言包已下载。设置里的服务列表会显示真实状态
（`LanguageAvailability.status`），没下载就直接说明，而不是留一个空承诺。

| 分组 | 服务 | 密钥 |
|---|---|---|
| 系统内置 | 系统翻译、系统词典 | 不需要，离线可用 |
| 翻译服务 | Google 网页、DeepL | Google 不需要；DeepL 需要 |
| 大模型 | Claude、OpenAI、DeepSeek、Gemini、Groq、Moonshot、SiliconFlow、xAI、OpenRouter、自定义 | 需要 |
| 本地模型 | Ollama | 不需要 |

其中 OpenAI / DeepSeek / Groq / Moonshot / SiliconFlow / xAI / OpenRouter / 自定义
共用一份实现 —— 它们都讲 OpenAI 的 Chat Completions 协议，差别只有 base URL、
密钥和模型名，所以是**配置出来的，不是各写一遍**。Claude、Gemini、DeepL 协议不同，
各自实现。

### 模型名

内置默认值核对于 `ServiceKind.modelsVerified`，但**它们过期得很快** —— 这个项目
最初写的 LLM 默认模型，到第一次核对时已经全部被改名或下线（`deepseek-chat` →
`deepseek-flash`、`gpt-4.1` → `gpt-5.6-*`、`gemini-2.5-flash` → `gemini-3.8-flash`、
`grok-3` → `grok-4.6`、`moonshot-v1-8k` → `kimi-k2.6`）。

所以不靠表：模型框旁边的 ↻ 会直接向服务商拉取当前可用列表
（OpenAI 兼容的 `/v1/models`、Claude 的 `/v1/models`、Gemini 的 `v1beta/models`、
Ollama 的 `/api/tags`）。已退役的名字如果之前存过，启动时会被清掉并回退到当前默认值，
免得报一个看不懂的 400。

密钥全部存系统钥匙串。

## 词典排版

系统词典返回的是**一整行**密排文本，所有义项挤在一起。解析器（`DictionaryFormatter`）
把它还原成结构 —— 词头、读音、语体标签、编号义项、末尾的用法说明 —— 再由
`DictionaryEntryView` 按语义排版，而不是打印成一段 Markdown。

解析规则全部是拿真实词条验证出来的，不是照着文档猜的：

- **竖线数量不是信号。** `你好` 的 2 个竖线是 `词头 | 音标 | 释义`；`学习` 的 1 个和
  `一` 的 3 个都是**例词分隔符**。判据改成内容：词头必须短且不含义项标记。
- **中文词条常常没有竖线**，词头和拼音混在正文开头（`学习 xuéxí ①动 …`），要从第一个
  义项标记之前的片段里提取，还要跳过 `一 1 yī` 里的同形字编号。
- **注音符号要剥掉** —— `你好` 的词头字段实际是 `你ㄋㄧˇ好ㄏㄠˇ ㄋㄧˇ ㄏㄠˇ`。
- 义项标记不止 ①–⑳，还有 ⑴–⒇ 和用于子注的 ㊀–㊉。
- **`A.` `B.` 是词性块，不是义项。** `hello` 的原文是 `A. noun 问候 wènhòu
  B. exclamation ① … ② …` —— 两个词性各自成块，义项编号从属于块。所以模型里是
  `Group`（可带标签、可带块内文本、下辖若干 Sense），没有 A./B. 的词条就是一个无标签的块，
  视图不需要两套分支。识别规则刻意收窄到「行首 + A–H + `.` + 空格」，放宽会把散文里
  每一个缩写都劈成两半。
- **`▸` 后面是例句。** `set` 的一条义项后面能跟四个例句，全部内联就变成一段话。
  拆出来放在一条竖线后面，眼睛可以直接跳过。
- **有些词条根本不是词条。** 查 `light` 命中的是 Apple 自家术语表：没有竖线、没有标记，
  只有一行标题加一段说明。原来整段都会被当成词头用 21pt 排出来。

一个已知的、不打算修的问题：`DCSCopyTextDefinition` 用系统的词典优先级，查 `run`
会命中汉语词典里读音相同的 `瞤`。要指定词典得用私有 API，不碰。

## 网页翻译（Safari 扩展）

在网页每一段原文下面放译文，沉浸式翻译那种双语对照，但由 Lumi 里已经配好的引擎来译。
`build.sh` 会把扩展一起打进 `Lumi.app/Contents/PlugIns/LumiSafari.appex`，没有 Xcode 工程。

第一次用：Safari 设置 › 开发者 › 勾选「允许未签名的扩展」→ 扩展 › 勾选「Lumi 网页翻译」→
允许它访问网站。免费开发者证书签的扩展 Safari 不认作已签名，所以**每次重启 Safari 都要再勾
一次**「允许未签名的扩展」。这是 Apple 的限制，付费开发者账号 + 公证才能去掉。

| 操作 | 方式 |
|---|---|
| 翻译 / 还原整页 | ⌥T，或页面右侧的玻璃圆钮，或工具栏弹窗 |
| 只翻一段 | 鼠标指着那一段，轻点一下 ⌥（按住不算，⌥ 加别的键也不算） |
| 换译文样式 | 指着圆钮展开后点样式按钮，或在弹窗里选 |
| 移开圆钮 | 上下拖动 |

### 引擎

| 弹窗里的选项 | 实际是谁 | 需要 |
|---|---|---|
| 大模型 | Lumi 设置里「网页翻译」选的模型（与工作台共用） | Lumi 在运行 + 该服务的密钥 |
| 本机 | 系统翻译 | Lumi 在运行 + 语言包 |
| Google | 公共接口，扩展直接调用 | 什么都不要 |
| 自动 | 大模型可用就用它，否则本机，Lumi 没开就 Google | — |

网页翻译**复用工作台的引擎**（`OnlineWorkbenchEngine` / `OfflineWorkbenchEngine`），
不是另写一套：网页就是一篇文档。大模型拿到的是网页标题、上一段的结尾、以及你在弹窗里
为这个网站写的说明（术语表），和工作台翻论文是同一个提示词。实测同一个标题，Google 译成
「变形金刚如何学习参与」，DeepSeek 译成「Transformer 如何学会关注」。

大模型的批次按**长短**分：超过 200 字的真段落单独一次调用，带上一段做上下文；标题、图注、
列表项这类短句最多八条合成一次调用（`Prompts.pageBatch`，逐行 `<<n>>` 标号，对不上号的
那几条自动退回单独调用）。一条一次时 Hacker News 一屏要 30 秒，合批后 6 秒全部译完；而把
两个长段落和六个标题混在一批里要 7.6 秒，只放短句约 2 秒 —— 一批的速度取决于最慢的那条。
Google 和系统翻译一次调用能答一整批，所以它们直接攒大批。排队时屏幕上正看着的段落优先。

### 扩展怎么找到 Lumi

扩展是沙盒里的 appex，读不到 Lumi 的钥匙串，所以翻译必须回到 Lumi 进程里做。
`PageBridge` 在 **127.0.0.1:47121** 上开了一个只收本机连接的 HTTP 端点：

```
GET  /v1/status?target=zh-Hans      引擎是否可用、用户的第一语言
POST /v1/translate                  一批段落 → 每段的译文 / 错误 / 已是目标语言
```

扩展先直接 fetch；不行就经 appex 转发（`SafariWebExtensionHandler.swift`，只做转发）。
本机任何网页也能访问 127.0.0.1，所以有三道门：`Host` 必须是回环地址（挡 DNS rebinding）、
带 http(s) `Origin` 的一律拒绝、POST 必须带 `X-Lumi-Client` 头（网页设不了，除非先过
CORS 预检，而预检永远不会被放行）。

```bash
curl -s 127.0.0.1:47121/v1/status
```

### 界面：和面板是同一套零件

页面边缘的圆钮是 Lumi 面板的标题栏缩小版：一颗液态玻璃圆片，指上去（或者开始翻译、出错时）
向左展开成玻璃胶囊，里面是服务栏同款的状态点（译着时强调色呼吸、完成变绿、出错橙色）、
引擎名和胶囊按钮。弹窗照面板排：36pt 标题行里的「自动 ⇆ 简体中文」语言胶囊、唯一一块玻璃
是主操作（就像面板里唯一的玻璃是输入框）、下面是服务栏式的引擎胶囊、`EngineToggle` 那种
滑块切样式。

数值全部取自 `Chrome.swift` / `Motion.swift`：11pt 圆体中号字、22% 描边的胶囊、选中态
强调色 18% 填充 + 55% 描边、系统强调色（CSS 的 `AccentColor`）、`Motion.pop` 和
`Motion.tap` 两条弹簧 —— 用弹簧方程采样成 CSS `linear()` 曲线，所以网页上的东西和面板
回弹得一样。译文到达时从轻微模糊里「透过玻璃」浮现，对应面板的 `bodySwap`。

玻璃的明暗跟着**背后的网页**走，不跟系统外观：深色玻璃压在白色维基百科上是一块灰斑。
圆钮会取自己左侧那一点网页的背景色，滚动时重取。

整页性的失败（Lumi 没开、语言包没下、被限流）只在圆钮里说**一次**，带「重试」；Lumi 重新
可用后，下一批成功时会自动把失败的段落补译。只有「这一段失败、邻居都成功」才在段落下放一个
面板风格的小胶囊。第一版把「Lumi 没有运行」按标题字号印在了每一个标题下面。

### 不经 Safari 调试

```bash
python3 Extensions/Safari/Harness/serve.py
open 'http://127.0.0.1:8765/?engine=online&style=pane'
open 'http://127.0.0.1:8765/popup.html?active=1'
open 'http://127.0.0.1:8765/site?url=https://en.wikipedia.org/wiki/Transformer_(deep_learning)'
```

测试页用一个很小的 WebExtension 垫片（`Harness/shim.js`），让**原样的** `content.js` 和
`background.js` 在任何浏览器里跑，并把对 Lumi 的请求经代理转发（代理去掉 `Origin`，和
appex 转发时一样）。本地测试页覆盖导航栏、代码块、嵌套列表、表格、中文和法文段落、3 秒后才
插入的段落；`/site?url=` 把真实网页取回来、去掉它的 CSP 再注入扩展 —— 维基百科、GitHub
的 CSP 既不让加载脚本也不让连 127.0.0.1，而 Safari 里真正的内容脚本不受网页 CSP 约束，
所以去掉它不改变扩展看到的东西。`__lumiTest` 暴露了内部状态，网页本身看不到。

在真实网站上测出来并修掉的：

- **公式泄漏 TeX 源码。** 维基百科把 MathML 藏起来显示图片，`<annotation>` 里是 TeX，
  于是发给模型的是 `x W {\displaystyle xW}`。现在隐藏的子树不读，公式读它看得见的符号。
- **给屏幕阅读器的字被翻译。** 「Jump to content」「[edit]」、arXiv 移到屏幕外的跳转链接。
  按通用类名过滤，外加「1px 大小或在屏幕左右以外」的判断。
- **收起的菜单变成一段。** 36 种语言名藏在 `display:none` 里，外层 div 被当成一个段落。
- **标题的译文跟在 [edit] 后面。** 维基百科的 `<h2>` 在一个 flex 容器里是行内的；现在只有
  一个标题子元素的容器，译文放进标题里，用标题的字。
- **名字原样返回。** 模型把「Hacker News new | past」原样还回来，和原文一样的译文不显示。
- **中途变了字的段落。** 每个请求带票号，旧回复不会落到新文字上。
- **9000 段的页面冻住 1 秒。** 遍历改成生成器，8ms 一片，最长阻塞降到 134ms。

两个在测试页里踩到、但在 Safari 里同样会发生的坑：

- **「仅译文」要先量再藏。** 原文是靠把宿主字号设成 0 藏起来的，于是一切以 em 为单位的
  边距、行高也跟着变 0，段落挤成一团。所以字号、行高、上下边距先按像素记下来，再加 class
  —— 顺序反了读到的全是 0，译文也跟着变成 0px 不见了。
- **批次调度不能用定时器。** 不在前台的标签页里 `setTimeout` 会被节流到一秒一次甚至更慢，
  整页卡在「4/25」。现在用微任务：同一次 IntersectionObserver 回调里入队的段落自然成一批。

### 段落识别

不移动、不包裹网页自己的节点 —— React 这类框架管着自己的 DOM，节点换了父元素就会出错；
多出一个它没创建的子元素它能容忍。所以译文是追加进段落里的 `<lumi-tr>`，而
`<li>文字 <ul>…</ul></li>` 这种文字和块级子元素混排的，译文插在那串文字后面，不去包它。
译文一律以纯文本写入，不当 HTML —— 翻译它的是读了任意网页的大模型。

已知限制：译文不保留链接和加粗；「仅译文」对上面那种混排文字不生效（藏不掉又不能包）；
不处理 iframe 里的内容。

## 图标

图标是**代码**，不是一张 PNG：`Tools/IconForge/main.swift` 用 CoreGraphics 画，
`Tools/IconForge/make-icon.sh` 渲染成 iconset 再 `iconutil` 打包进
`Resources/Lumi.icns`。几何写成代码就能任意尺寸重渲、改色、像别的代码一样 diff；
一张 1024 的 PNG 只能整张替换。

内容是「A 经过一块玻璃，出来是文」—— 这块玻璃就是面板本身的形状，所以图标和产品
共用一个形。不是「两种语言并排」那种通用徽章。

两个踩过的坑：

- **macOS 26 会自己套一层瓷砖。** 自己再画一个圆角矩形，结果是系统圆角里浮着一个
  深色小方块 —— 像一张白卡片上贴了个徽章。所以画面必须出血到画布边缘，圆角、描边、
  投影全部交给系统。`--tile` 参数保留了自绘瓷砖的老行为。
- **别信 plist，问系统。** `NSWorkspace.icon(forFile:)` 返回的才是 Finder 真正会
  显示的那一张（含系统瓷砖）—— 上面那个坑就是这么发现的。

小尺寸靠 `*.preview.png` 输出模式验证：用最近邻把 16/32/64/128 放大排成一行，
哪一笔在重采样里糊掉一眼就看见。

## 为什么不会卡死

Easydict 卡死的根因是同步阻塞调用跑在主线程上。这里每一条会离开进程的路径都有硬性超时：

- **`Core/Timeout.swift`** — `withTimeout` 把任意异步操作和一个 deadline 放进 task group 赛跑；
  `withBlockingTimeout` 把阻塞式 C API 丢到 detached 线程，到点直接放弃。
- **`Input/TextGrabber.swift`** — Accessibility 取词是同步调用，目标 App 无响应就会连带冻住调用方。
  这里每个 AX 调用都设了 `AXUIElementSetMessagingTimeout`，并跑在可被放弃的线程上；
  失败则回退到模拟 ⌘C，且会还原剪贴板。
- **`Translate/SSE.swift`** — `timeoutIntervalForRequest` 是**包与包之间**的间隔上限，
  所以「连上了但不发数据」的服务器会被掐掉，而不是让结果卡片永远转圈。
- **`Core/AppState.swift`** — 所有服务并发扇出，一个服务一张卡片，互不阻塞。
  新查询会取消旧任务。

## 关于 `@Stored`

当前 SDK 里 `@State` 是宏，实现 `SwiftUIMacros` 只随 Xcode 分发，Command Line Tools 装不到。
底层的 `@propertyWrapper struct State` 仍然存在，而宏在**类型位置**不参与解析，
所以 `Sources/Lumi/UI/StateShim.swift` 里的 `typealias Stored<Value> = SwiftUI.State<Value>`
可以绕过去，行为与 `@State` 完全一致（含 `$binding` 与 `nonmutating set`）。
以后若装了完整 Xcode，全局替换回 `@State` 即可。

## 结构

**完整的模块地图、两张可交互图（结构图 + 数据流图）、以及仓库守卫的说明，都在
[`STRUCTURE.md`](STRUCTURE.md)**（图在 `docs/*.html`，双击就能打开）。给 AI 代理的
约定在 [`AGENTS.md`](AGENTS.md)。下面只是源码分区的简表。

```
App/       应用入口、菜单栏、面板窗口控制器
Core/       超时原语、语言检测、设置、钥匙串、网络状态、查询协调与回退
Input/      全局快捷键（Carbon）、AX 取词、截图 OCR、权限
Translate/  服务协议 + Apple / Claude / OpenAI / Ollama / 在线
UI/         Liquid Glass 面板、服务栏、结果正文、动效常量、设置界面
Speech/     TTS 朗读
PageBridge/ 给 Safari 扩展的本机 HTTP 端点，把网页段落交给工作台引擎
Workbench/  工作台：分段、翻译引擎、漏译检查、校对、Markdown、文稿存档
Etymology/  词源：维基词典取数 + 模型讲解

Extensions/Safari/
  SafariWebExtensionHandler.swift   appex 的原生部分，只做转发
  WebExtension/                     manifest、内容脚本、后台脚本、弹窗
  Harness/                          不经 Safari 调试扩展的测试页

scripts/     仓库守卫（密钥 / 卫生 / 文档 / 设计契约四阶段）与它的自测
.githooks/   提交前钩子（core.hooksPath 指到这里，./scripts/install-hooks.sh 启用）
.github/     CI：push 与 PR 时跑同一套守卫
docs/        两张图 + 浏览器证据 + 图规格
```

提交前想自己过一遍完整检查（钩子只查这次提交的内容）：

```bash
python3 scripts/security-scan.py        # 四个阶段；CI 跑的是同一条命令
python3 scripts/test-security-scan.py   # 验证守卫自己还有效（38 项断言）
```

界面只有**两层玻璃**：面板本身，因为它是浮在桌面上的一个物体；输入框，因为它是
唯一被直接操作的控件。玻璃标记「可交互」而不是「好看」—— 服务栏、结果区、设置
窗口一律用普通材质。每一行都糊一层的话，窗口就不再像一个物体，而像一摞药片。

输入框对长文本会收起到 `inputCollapsedLines` 行（默认 3），右侧出现展开按钮。
是否溢出是**量出来的**：把同一段文字用同样的字号、同样的宽度再排一次，比高度。
按字数估算不行 —— 一行中文和一行英文装的字数差得远。展开按钮只在真的有东西被
挡住时才出现，因为一个按了没反应的控件比没有按钮更糟。

顶栏没有专门的拖动条。可见的把手等于承认拖动不好发现，而且它占掉窗口最顶上
12pt —— 视线最先落下的地方。现在拖的是顶栏和底部操作栏的空隙，跟任何一个 Mac
窗口一样。两条都贴着窗口边缘，因为那是手真正会去够的地方；高度给在行上而不是
给成 padding，否则最顶上那一条是不属于任何视图的死区。

## 许可证

[GPL-3.0](LICENSE)。欢迎提 issue 和 PR，提交前请读 [CONTRIBUTING.md](CONTRIBUTING.md)。

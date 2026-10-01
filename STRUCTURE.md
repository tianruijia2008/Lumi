# Lumi — 项目结构

一页看懂 Lumi 的代码结构。两张可交互图（可直接双击打开，支持明暗主题、缩放、搜索、按路径高亮）：

| 图 | 文件 | 说明 |
|---|---|---|
| 结构图（模块 / 边界 / 依赖） | [`docs/lumi-architecture.html`](docs/lumi-architecture.html) | 12 个节点、12 条关系，含 3 条引导视图 |
| 数据流图（取词 → 呈现） | [`docs/lumi-dataflow.html`](docs/lumi-dataflow.html) | 5 个阶段、13 个节点、13 条流，含图例与 3 条引导视图 |

生成规格（JSON）在 [`docs/archify/`](docs/archify/) 下，重新生成：

```bash
ARCHIFY=~/.pi/agent/skills/archify
node $ARCHIFY/bin/archify.mjs deliver architecture docs/archify/lumi-architecture.json docs/lumi-architecture.html --quality showcase
node $ARCHIFY/bin/archify.mjs deliver dataflow     docs/archify/lumi-dataflow.json     docs/lumi-dataflow.html     --quality showcase
node $ARCHIFY/bin/archify.mjs visual-check docs/lumi-architecture.html --json
node $ARCHIFY/bin/archify.mjs deliver <type> docs/archify/lumi-<type>.json \
     docs/lumi-<type>.html --quality showcase --json > docs/archify/lumi-<type>.deliver.json
python3 scripts/sanitize-receipts.py   # 两类回执都会写绝对路径，提交前改成相对路径
```

> 图是**静态 HTML**（内嵌 SVG + 运行时），不需要服务器、不需要联网。
> 修改结构后请先改 JSON 再重新 `deliver`，不要在 HTML 上手改。

**证据标签**：**[已验证]** 直接读文件或 grep 得到；**[README]** / **[TECHSHEET]** 只在 `README.md`（功能）或 `TECHSHEET.md`（技术细节）中说明、本次未独立复现；**[未验证]** 结构上合理但没查。

---

## 1. 项目概况

| 项 | 值 |
|---|---|
| 形态 | macOS 取词翻译 / 词典面板，受 Easydict 启发、代码从零写起 **[README]**；许可证 GPL-3.0 **[已验证 `LICENSE`]** |
| 语言 / UI | Swift 6（`swiftLanguageMode(.v6)`）+ SwiftUI，`platforms: [.macOS("26.0")]` **[已验证 `Package.swift`]** |
| 构建 | SwiftPM **单个 executable target `Lumi`**（`path: Sources/Lumi`），**零第三方依赖** **[已验证]** |
| 规模 | 69 个 Swift 文件 / 16,272 行 **[已验证：文件统计]** |
| 打包 | `build.sh`：SwiftPM 编译 → 手工组装 `.app` → 本机免费个人团队证书签名（身份**不写进源码**，见第 8 节）；Safari appex 用 `swiftc` 单独编译后 `lsregister` 注册 **[已验证]** |
| 启动 | 必须 `./run.sh`（内部走 `open`）或访达启动；直接执行 bundle 内二进制会把 TCC 权限记到终端头上 **[TECHSHEET + `run.sh` 注释]** |
| 版本控制 | git 仓库，分支 `main`；密钥 / 卫生 / 文档 / 设计契约四道闸门 + CI，见第 8 节 **[已验证]** |
| 额外产物 | Safari Web Extension（JS）、`Tools/IconForge`（CoreGraphics 画图标 → `.icns`） |

---

## 2. 目录结构

```
Lumi/
├── Package.swift                  # 单 target "Lumi"，无 dependencies
├── build.sh / run.sh              # 编译 + 组装 .app + 签名 / 用 open 启动
├── Lumi.entitlements              # app-sandbox=false（要 AX + 屏幕录制）
├── .gitignore                     # 构建产物、本机私有配置不入库
├── .lumi-identity                 # 签名身份（本地、不入库；build.sh 读它）
├── .githooks/pre-commit           # 提交前守卫（core.hooksPath 指向这里）
├── .githooks/pre-push             # 只允许把 main / tag 推到发布仓库，拒绝直接推存档
├── .github/workflows/security.yml # CI：密钥 / 卫生 / 文档 / 契约四道闸门
├── README.md                      # 给使用者：功能、截图、安装、隐私
├── README.en.md                   # README 的英文版（只在存档里）
├── TECHSHEET.md                   # 技术说明：设计取向、实现细节、自测入口
├── CONTRIBUTING.md                # 提 issue / PR 的约定与贡献授权
├── LICENSE                        # GPL-3.0
├── STRUCTURE.md                   # 本文
├── scripts/
│   ├── security-scan.py           # 守卫本体（secrets / hygiene / docs / invariants 四阶段）
│   ├── test-security-scan.py      # 守卫自测（CI 里跑，防止守卫本身失效）
│   ├── install-hooks.sh           # 新克隆后一键启用钩子
│   └── sync-vault.sh              # 同步公开存档（过滤掉 AGENTS.md / CLAUDE.md 后推送）
├── docs/
│   ├── lumi-architecture.html     # 结构图（可交互）
│   ├── lumi-dataflow.html         # 数据流图（可交互）
│   ├── *.visual-check.*           # 浏览器证据：截图 + receipt（可再生成）
│   ├── archify/*.json             # 两张图的生成规格
│   └── screenshots/*.png          # README 用的截图
├── Resources/                     # Info.plist、Lumi.icns（由 IconForge 生成）
├── Tools/IconForge/               # main.swift + make-icon.sh
├── Extensions/Safari/
│   ├── SafariWebExtensionHandler.swift   # appex 原生侧，纯转发
│   ├── Extension.entitlements            # sandbox=true + network.client（只够回环）
│   ├── WebExtension/                     # manifest.json / background.js / content.js / popup.*
│   └── Harness/                          # serve.py + shim.js：不开 Safari 也能调扩展
└── Sources/Lumi/
    ├── App/          (2)   入口、菜单栏、面板窗口控制器
    ├── Core/         (9)   AppState 扇出、设置、Keychain、超时、网络、日志
    ├── Input/        (4)   Carbon 热键、AX 取词、Vision 截图取词、权限
    ├── Translate/   (15)   Provider 协议 + 8 个实现、SSE、提示词、模型目录
    ├── Etymology/    (7)   Wiktionary 抓取 + wikitext 解析 + 词源缓存
    ├── Workbench/   (10)   文档工作台：分段、引擎、落盘、校对
    ├── PageBridge/   (2)   回环 HTTP :47121 + 网页批次 → 分段任务
    ├── Speech/       (1)   AVSpeechSynthesizer 朗读
    └── UI/          (19)   玻璃面板、服务滑轨、设置、工作台/词源视图
```

---

## 3. 模块清单 **[已验证]**

| 模块 | 文件 | 行数 | 职责 | 关键类型 |
|---|---:|---:|---|---|
| `App` | 2 | 546 | 应用入口、菜单栏、面板窗口 | `LumiApp`、`AppDelegate`、`PanelController` |
| `Core` | 11 | 1,165 | 查询扇出、设置、凭据、超时、网络、**界面语言与文案表** | `AppState`、`AppSettings`、`Keychain`、`Timeout`、**`Localization`** |
| `Input` | 4 | 410 | 拿到"用户选了什么" | `HotKeyCenter`、`TextGrabber`、`ScreenOCR`、`Permissions` |
| `Translate` | 16 | 1,733 | 调服务并产出流式事件 | `TranslationProvider`、`ServiceKind`、`SSE`、`Prompts`、`ModelDirectory` |
| `Etymology` | 8 | 1,979 | 词源页的数据（含维基语言名的中英对照表） | `EtymologyStore`、`Wiktionary`、`WikiText`、`EtymologyParser`、`LanguageNames` |
| `Workbench` | 11 | 3,883 | 长文分段翻译与校对 | `WorkbenchEngine`、`WorkbenchDocument`、`Segmenter`、`DocumentStore` |
| `PageBridge` | 2 | 517 | 让 Safari 扩展借用本机引擎 | `PageBridge`、`PageTranslator` |
| `Speech` | 1 | 41 | 朗读 | `Speaker` |
| `UI` | 21 | 6,909 | 全部视图与窗口修饰 | `GlassPanel`、`RootView`、`ServiceRail`、`SettingsView` |
| **合计** | **76** | **17,183** | | |

**界面文案表的位置**：`Core/Localization.swift`（API 与语言）+ 每个区域一个表文件
（`Core/StringsCore.swift`、`UI/StringsPanel.swift`、`UI/StringsSettings.swift`、
`Workbench/StringsWorkbench.swift`、`Etymology/StringsEtymology.swift`、
`Translate/StringsServices.swift`）。这 7 个文件也是本表里 Core/UI/Workbench/Etymology/Translate
计数增加的原因。设计见 TECHSHEET 的「界面语言」一节。

---

## 4. 依赖与接缝

结构图里的骨架（箭头 = 调用 / 数据方向）：

```
面板取词（主路径）
  用户 ─按键触发─▶ HotKeyCenter ─派发─▶ PanelController ─提交查询─▶ AppState ─并发扇出─▶ TranslationProvider ─流式增量─▶ 结果卡 UI
                  (⌥D ⌥A ⌥S ⌥W)          ├─取词 / OCR─▶ TextGrabber（AX / ⌘C · 区域 OCR）
                                          ├─英文单词查词─▶ EtymologyStore ─词源一行─▶ 结果卡 UI
                                          └─读取设置─▶ Core 基础服务（设置 · 密钥 · 超时）

本条文档（⌥W）
  文档导入 ─原始文本─▶ Segmenter ─分段任务─▶ WorkbenchEngine ─按段调用─▶ TranslationProvider
                                                    │
                                                    └─译文落盘─▶ DocumentStore（按指纹复用）

网页（扩展）
  Safari 扩展 ─批量段落─▶ PageBridge（127.0.0.1:47121）──解析请求─▶ PageTranslator ─段落作业─▶ WorkbenchEngine
```

### 两个接缝（这是本项目最重要的两个抽象边界）**[已验证]**

1. **`TranslationProvider`**（`Translate/Provider.swift`）
   协议只要求 `kind`、`requiresNetwork`、`availability(for:)`、`translate(_:) -> AsyncThrowingStream<TranslationEvent, any Error>`。
   **8 个 struct 实现**：`AppleProvider`、`AppleDictionaryProvider`、`WebProvider`(Google)、`DeepLProvider`、`ClaudeProvider`、`GeminiProvider`、`OllamaProvider`、`OpenAICompatibleProvider`。
   `ServiceKind` 共 **15 个服务**，其中 8 个（OpenAI / DeepSeek / Groq / Moonshot / SiliconFlow / xAI / OpenRouter / 自定义）**只有配置差异，共用一个实现**——因此"加一个 OpenAI 兼容厂商"通常等于改配置，不是加文件。
   `Presentation` 侧只有一个事件枚举：`delta`（追加）/ `replace`（整体替换）/ `dictionary`（结构化词条）。

2. **`WorkbenchEngine`**（`Workbench/WorkbenchEngine.swift`）
   只有两个实现：`OnlineWorkbenchEngine`（吃 `DocumentContext`，走某个 Provider）与 `OfflineWorkbenchEngine`（系统翻译，`usesDocumentContext == false`，界面上把语境输入框置灰而不是假装能用）。
   逐段上报 `WorkbenchEvent`，单段失败只标记该行，不放弃整篇。

`PageBridge` 复用同一套引擎（`PageTranslator` 构造 `Online/OfflineWorkbenchEngine`），所以"文档提示词"改进会同时改善面板、工作台和网页翻译——这是刻意设计的复用点。

### 共享底座 **[已验证]**

| 类型 | 谁在用 | 备注 |
|---|---|---|
| `AppSettings.shared` | **19 个文件**依赖（不含定义它的那个文件） | 全项目耦合最广的类型：语言对、各服务开关/模型、面板宽度、外观 |
| `Keychain` | 仅 `GeminiProvider`、`OpenAICompatibleProvider`、`ClaudeProvider`、`DeepLProvider` | 账号名 `service.<ServiceKind.rawValue>.key` |
| `Timeout` | 取词（`withBlockingTimeout`）、HTTP 分段（`withTimeout`）、SSE | AX 调用不可无超时 |
| `NetworkMonitor` | `AppState`（离线直接判 `offline`）、`EtymologyStore` | 避免无谓请求与假失败 |

---

## 5. 关键机制（读代码时先看这些）

**取词入口**：`HotKeyCenter` 注册 Carbon 全局热键，默认 `⌥D` 翻译选中、`⌥A` 唤起输入、`⌥S` 截图取词、`⌥W` 打开工作台（`Input/HotKey.swift`）。动作全部派发给 `PanelController`：`translateSelection()` → `TextGrabber.selectedText()`；`translateScreenRegion()` → `ScreenOCR.captureAndRecognize()`。
`TextGrabber` 先走 AX（`AXUIElementSetMessagingTimeout` 0.25s，整体 `withBlockingTimeout(0.7)` 兜底），失败再退到模拟 `⌘C` 读剪贴板——**每次 AX 调用都在超时保护内**，卡死的目标 App 不会拖垮 Lumi。`ScreenOCR` 用 `screencapture -i` 选区域 + Vision 异步识别。

**扇出与回退**：`AppState.submit()` 用 `withTaskGroup` **并行**跑所有启用服务；焦点立刻落在队列最上面的服务（"等待中"不能表现为空白），`promotionDeadline` 之后锁定，不再自动跳；用户点 chip 也是永久锁定。回退只是"显示哪一条"的规则，不是串行顺序（`Core/AppState.swift`）。`ResultCard.Status` 把 `empty`（词典对这种输入没有意见）与 `failed` 分开，空结果不算错误。

**面板几何**：持久化的是**窗口左上角锚点**，不是 AppKit 的原点；结果卡出现时保持顶边不动，用**赋值**而不是高度增量；边界钳制后如果确实移动了锚点，就采纳新锚点，否则下次 resize 会来回震荡（`TECHSHEET.md` 有实测结论，`PanelController` 里是这套做法）。

**文档工作台**：`Segmenter` 切成对齐单元（Markdown 保留结构），`WorkbenchDocument` 持有"一篇文章"的状态，`DocumentStore` 按**内容指纹**落盘以复用已付费的译文，`DropCheck` 抓"悄悄漏译/缩写"的段落，`Proofreading` 定位校对问题。

**网页桥**：`PageBridge` 用 `NWListener` 只监听 `127.0.0.1:47121`（必须与扩展里的 `LUMI_PORT` 一致），受理前过三道校验——`Host` 必须是回环、带 web `Origin` 的一律拒绝、POST 必须带 `X-Lumi-Client`（页面无法在不触发预检的情况下设置它，而预检不回应）。扩展本体是 sandbox 的，读不到 Lumi 的 Keychain，所以只能把段落发过来让本机引擎翻。

**词源**：`EtymologyStore`（单例）→ `Wiktionary` 抓取 → `WikiText` 做"够用就好"的 wikitext 解析（不展开模板）→ `EtymologyParser`/`EtymologyEntry` → 面板上的一行 teaser 或完整词源页；结果进内存缓存并记 recents。

**界面语言**：中文 / 英文两套界面，在设置里切换、立即生效。文案走查表：`t("中文原文")`
（MainActor，视图读它就会在切换时重绘）与 `tDetached(...)`（非 main actor 上下文，
读 `Mutex` 快照）；key 就是中文原文，查不到英文回落中文。表按区域分文件、运行时合并。
只影响界面文字——**提示词、维基解析、词典格式判断与用户内容都与此无关**。
完整设计（为什么不放 `Localizable.strings`、为什么不放在 `AppSettings`、AppKit 菜单
为什么要手动重建）见 TECHSHEET 的「界面语言」一节；守卫的 `invariants` 阶段会核对
文案表的完整性（缺翻译 / 无用条目 / key 不含中文）。

**自测入口**（不依赖人手点屏幕）**[TECHSHEET + `App/LumiApp.swift`]**：
`LUMI_SHOW_ON_LAUNCH=1` 直接开面板，`LUMI_DEMO_QUERY=<词>` 灌查询，`LUMI_WINDOW_SHOT=<path>` 用 `screencapture -l` 拍真实窗口（唯一能看到玻璃材质的路径），`LUMI_SNAPSHOT=<path>` 走 `ImageRenderer` 离屏渲染（只适合看排版），`LUMI_SHOW_WORKBENCH=1` / `LUMI_WORKBENCH_ENGINE=online|offline` 开工作台。

---

## 6. 改动时需要留意的地方

- **`AppSettings` 是宽耦合点**（19 个文件依赖它）。往里加字段最省事，但每加一个"全局开关"都会同时影响面板、工作台、网页桥和设置界面；能让引擎自己决定的，别放进去。
- **新增服务**优先走 `ServiceKind` + `OpenAICompatibleProvider` 配置（base URL / key / model），只有协议不兼容（如 Claude、Gemini、DeepL）才新增 Provider 文件。新服务记得 `family`、`defaultModel`、`needsKey` 三处一起补，`ModelDirectory` 才拉得到在线模型列表。
- **新增 Swift 文件不需要改任何工程文件**：SwiftPM 自动发现 `Sources/Lumi` 下的所有 `.swift`。但新增**资源**要在 `build.sh` 的拷贝逻辑里考虑（目前 `Resources/*` 整目录复制，`Info.plist` 除外）。
- **回环端口是攻击面**：任何本机页面都能发请求到 `127.0.0.1:47121`，安全性完全靠 `PageBridge` 里那三道校验。改 `route(_:)` 之前先读该文件的注释与 `PageTranslator` 的请求校验。
- **取词路径上的一切都要有超时**：AX 是同步阻塞 API，任何新的阻塞调用都要包进 `withBlockingTimeout`，否则一个卡住的目标 App 就能冻住整个面板。
- **TCC 归属**：改 `build.sh` 的签名身份会让"辅助功能/屏幕录制"授权失效（identity 变 → TCC 视为新 App）。身份现在**不在源码里**：优先读 `$LUMI_IDENTITY`，其次本地未跟踪的 `.lumi-identity`；保持这个文件不变即可避免反复授权。新克隆的人自己建一份（`echo "Apple Development: 名字 (TEAMID)" > .lumi-identity`，查身份用 `security find-identity -v -p codesigning`）。
- **改完 UI 后用上面那两条截图路径自测**，不要靠"看起来应该没问题"。

---

## 7. 图是怎么来的

两张图由 [Archify](https://github.com/tt-a1i/archify) 从 JSON 规格生成，验收标准是 `--quality showcase`（9 项 artifact 检查 + 0 composition error / 0 warning）：

| 图 | 规格文件 | 验收结果 |
|---|---|---|
| `docs/lumi-architecture.html` | `docs/archify/lumi-architecture.json` | 9/9 通过，0 error / 0 warning |
| `docs/lumi-dataflow.html` | `docs/archify/lumi-dataflow.json` | 9/9 通过，0 error / 0 warning |

浏览器证据（`visual-check`）在 1440×900、1600×1000、1920×1080、2048×1320、明/暗两套主题下均无溢出（`scrollWidth/Height` ≤ 视口），文字投影 ≥ 6px；截图与 receipt 落在 `docs/*.visual-check.*`，可随时用上面的命令重跑。

⚠️ `visual-check` 会把 `artifact.path` 写成**绝对路径**（里面含你的家目录 / 用户名），所以提交前要跑一次 `python3 scripts/sanitize-receipts.py` 把它改成仓库相对路径——守卫的 `personal/home-path` 规则和 CI 的 `--check` 会拦住忘记的那次。这个改写只动路径字段，receipt 与 HTML 的 sha256 校验依然成立。

**图上标了什么，不标什么**：架构图只画“谁调用谁”（不画数据内容），数据流图只画“什么东西从哪到哪”（五个阶段 = 触发 / 取词·导入 / 分段·调度 / 引擎·传输 / 呈现·落盘）。两张图都不含部署、进程或第三方基础设施——Lumi 没有这些。节点是**模块级**的（`Workbench` 10 个文件合成 1 个节点），文件级细节见第 3 节。

---

## 8. 仓库守卫与 CI

密钥这种事只能靠“两道闸门 + 一个可验证的扫描器”：**提交前**拦住，**CI** 再拦一次。两边调的是同一个脚本，所以本地过了 CI 不会翻脸。

```bash
python3 scripts/security-scan.py          # 全部（= CI 跑的三个阶段）
python3 scripts/security-scan.py --staged # 只看 staged 内容（钩子跑的就是这条）
python3 scripts/security-scan.py --phase secrets   # 单独跑某一阶段
python3 scripts/test-security-scan.py     # 验证守卫自己还有效
```

| 阶段 | 拦什么 | 例子 |
|---|---|---|
| `secrets` | 15 类厂商密钥形状、私钥块、JWT、`key = "…"` 形式的高熵串；以及邮箱、团队 ID、`/Users/<name>` 绝对路径（**生成物也查**） | `sk-…`、`AIza…`、`gsk_…`、`…:fx`、`AKIA…` |
| `hygiene` | `.build/`、`build/`、`*.app`、`_CodeSignature`、`.DS_Store`、编译中间产物、证书/描述文件/`.env`、>5MB 文件、Mach-O | — |
| `docs` | `STRUCTURE.md` 相对链接、模块清单（文件数/行数）与代码是否一致、图规格与**交付回执**、入库 receipt 的 sha256 指纹 | 改了代码没改文档 / 改了规格没重新 deliver |
| `invariants` | **只写在注释里的契约**：扩展端口 == `PageBridge.port`、扩展对外主机白名单、appex 必须 sandbox 且签名必须分别指定 entitlements、`build.sh` 不得用 `--deep`、`Package.swift` 不得出现外部依赖 | 见下表 |

`invariants` 这一栏值得单独说：这些约定原本只存在于代码注释里（"必须与扩展里的 `LUMI_PORT` 一致"、"never `--deep`"、"Safari 拒绝未沙箱的扩展"），注释不会在 CI 里失败。现在它们会被逐条检查：

| 契约 | 破了会怎样 | 检查方式 |
|---|---|---|
| 扩展端口 == `PageBridge.port` | 网页翻译静默失效（连不上又没人报错） | 分别解析 `PageBridge.swift` 与 `background.js` 再比对 |
| 扩展出口主机白名单 | 浏览器扩展悄悄把页面内容发给新主机 | 扫描扩展 JS/manifest 里所有 `http(s)://` 主机，只允许 `127.0.0.1`、`translate.googleapis.com`、`www.w3.org`（各带原因），并禁止 `host_permissions` 里的通配符 |
| appex sandbox + 分别签名 | Safari 拒绝加载扩展 / TCC 授权失效，且症状离原因很远 | 解析两份 entitlements 的 `app-sandbox`，并从 `build.sh` 里抽出**签名**命令（`--verify --deep` 是校验，不算）逐条检查 |
| 零第三方依赖 | `STRUCTURE.md` 的"零第三方依赖"从已验证事实变成假话 | 扫 `Package.swift` 有没有 `.package(` |

**图的完整性链条**：`规格 JSON → 交付回执 → HTML → 浏览器证据` 四者用 sha256 串起来。`deliver --json` 的输出存在 `docs/archify/*.deliver.json`（含规格 sha256 与产物 sha256），`visual-check` 的输出存在 `docs/*.visual-check.json`（含产物 sha256 与视口测量）。守卫逐个验算，所以"改了规格忘了重新 deliver"和"手改了生成的 HTML"都会在 CI 里断——这两件事第 7 节明令禁止，现在有东西在管了。

**本地钩子**：`.githooks/pre-commit` 调 `--staged`，只拦这次要提交的内容（文档漂移留给 CI，不打断本地迭代）。钩子用 `core.hooksPath` 指过来，所以要每个克隆各启用一次：

```bash
./scripts/install-hooks.sh        # = git config core.hooksPath .githooks
git commit --no-verify            # 确实需要时才绕过（CI 仍会拦）
```

**CI**（`.github/workflows/security.yml`）在 push / PR / 手动触发时跑四个平行 job，任一失败即红。它跑在 **GitHub 云端的 Linux 临时虚拟机**（`ubuntu-latest`）上——不是你的 Mac，你不需要装 Linux，也不需要装任何东西；那台机器把你的代码 clone 过去跑一遍 Python 脚本就销毁。选 Linux 是因为计费系数最低（Linux 1×，macOS 10×），而编译本来也做不了（见下）。刻意**不装第三方 action、不联网下载扫描器**，只用 Python 标准库，所以你本地能 100% 复现同一条命令。也刻意**不编译 App**：项目要求 macOS 26，而 GitHub 的 `macos` runner 还没到那个版本，`swift build` 只会红得没信息量——构建请在本地 `./build.sh`。

**守卫自己也要被验证**：`scripts/test-security-scan.py` 在临时仓库里塞 17 种真形状的假密钥，断言全部命中；再塞 14 类正常内容（文档例句、`com.tianruijia.` bundle id、sha256 常量、noreply 邮箱…），断言零误报；
最后把 7 条设计契约各改坏一次，断言都会被抓住——**一共 38 项**。CI 里跑它，所以“永远绿”的假扫描器活不过下一次提交。

### 两个远端：发布线 vs 存档

仓库里有两条**没有共同祖先**的历史，所以推送的地方必须分开：

| 远端 | 地址 | 收什么 | 用途 |
|---|---|---|---|
| `origin` | `github.com/…/Lumi` | 只收 `main` 与 tag | 发布线（已压平：`main` 是一个初始提交 + 后续修改） |
| `vault` | `github.com/…/Lumi-history`（公开） | 只收 `sync-vault.sh` 推的 | 存档：`main` + `backup/pre-public`（未压平的开发历史）+ tag，整段历史去掉了 `AGENTS.md` / `CLAUDE.md`，另有英文 README |

```bash
git push origin main                 # 发布
git push origin v0.1.0               # 发布标签
scripts/sync-vault.sh                # 存档（--dry-run 只生成不推）
```

存档里的历史是**过滤后重新生成的**：`git filter-repo` 从每个提交里删掉给 AI 代理的两份约定，
所以存档的提交哈希和本地不同，不能直接 `git push vault`。`sync-vault.sh` 的做法：

1. 把本地的 `main`、`backup/pre-public` 与 tag 克隆到临时目录——**其它本地分支一律不带**，
   临时分支不会因为一次同步被公开；
2. 过滤。过滤是确定的（同样的输入得到同样的哈希），所以推过的提交不会变，推送都是快进，不用 `--force`；
3. 存档的两条分支顶上各有一个存档专用提交（`main` 上是 `README.en.md`，两边都去掉了指向被删文件的链接），
   所以是把过滤后的分支**合并**进存档里的同名分支，而不是覆盖。合并冲突时脚本停下并保留临时目录；
4. 在合并结果上跑完整守卫与自测，都通过才推。

脚本从临时克隆推送，不经过本仓库的钩子；直接 `git push vault` 会被 `pre-push` 拒绝。
英文 README 只存在于存档里，中文 README 有大改动时要在存档里手动同步一次。

`.githooks/pre-push` 把这件事从"记得别推错"变成机制。对发布仓库（URL 含
`tianruijia2008/Lumi`）：只允许 `main` 与 `refs/tags/*`，删除 `main` 也拒绝；对存档仓库
（URL 含 `Lumi-history`）：一律拒绝。其它远端（fork、自建）放行——贡献者在自己的
fork 上推特性分支必须照常可用。两条无关的历史一旦混进发布仓库就很难清干净（删分支
容易，别人已经 fetch 走的收不回来），所以这里对发布仓库宁可拦错。

发布标记：tag 打在 `main` 的当前提交上，版本号同时在 `manifest.json`、`Resources/Info.plist`、
`Extensions/Safari/Info.plist` 三处，必须一致。

**几个刻意没做的事**（免得以后反复讨论）：

- **不钉 `ubuntu-latest` 到 `ubuntu-24.04`**：守卫只用 Python 标准库 + bash，跟发行版版本无关；钉死换来一个需要人工维护的版本号，还得再写一条升级提醒。那条"将迁到 Ubuntu 26"的公告是信息，不是问题。
- **不加 dependabot**：整个仓库只有 2 个 action（`checkout` / `setup-python`）。dependabot 每次升级开一个 PR + 一次 CI，换来的是一条本来一分钟能改完的一行改动——对 2 个 action 的仓库是净负担。升级手法记在这里就够：`gh api repos/actions/checkout/releases/latest --jq .tag_name`，然后改 YAML 里的 major tag（major tag 会自动跟随 patch）。
- **不自研之外的东西、也不引入 gitleaks**：gitleaks 规则更多，但要多一个二进制下载与版本跟踪，而且它对**这个项目**特有的东西（端口一致性、扩展出口、entitlements）一无所知。自研部分只用标准库，好处是本地、CI、任何机器上跑的完全一致，并且可以被自测覆盖。
- **不上 macOS runner**：贵 10×，而且编不了（平台要求 macOS 26）。编译留在本机 `./build.sh`。

**命中之后怎么办**：不要只删文件——已经 commit 过的东西还留在 reflog 和远端对象里。正确顺序是①撤销那笔改动 ②去厂商后台**轮换/作废**那把 key ③才考虑清理历史。文档里的示例请写成 `sk-YOUR_KEY` 这类明确占位形式，扫描器会放过它们（占位词、重复字符、`xxxx` 都认）。个别文件天生必须包含假密钥（比如守卫自测），可以在文件前几行写 `security-scan:allow-file` 声明跳过内容扫描；这是个显眼、可评审的单行标记，而且跳过时 CI 日志会点名。

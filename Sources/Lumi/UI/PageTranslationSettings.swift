import SafariServices
import SwiftUI

/// The 网页翻译 tab: is the Safari extension reaching Lumi, what is left to do
/// if it is not, and which engine answers when it is.
///
/// Built from the same grouped `Form` as the other tabs, with the chrome
/// vocabulary from `Chrome.swift` inside it — the capsule chips and status
/// dots the extension's popup and the service rail already use — so the
/// settings for the extension look like the extension.
struct PageTranslationSettings: View {
    @Stored private var settings = AppSettings.shared
    @Stored private var bridge = PageBridge.shared
    /// nil until Safari has answered; Safari may never answer if it has not
    /// been launched since the extension was installed.
    @Stored private var extensionEnabled: Bool?
    @Stored private var engines: [PageBridgeStatus.Engine] = []
    @Stored private var openError: String?

    var body: some View {
        Form {
            Section { header }

            Section {
                ForEach(Step.allCases) { step in
                    stepRow(step)
                }
            } header: {
                Text("开启步骤")
            } footer: {
                Text(connected
                     ? "扩展已经连上 Lumi。Safari 重新启动后如果扩展不见了，重做第 1 步。"
                     : "Lumi 用免费开发者证书签名，所以 Safari 每次重新启动后都要再勾一次第 1 步。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("大模型", selection: $settings.workbenchOnlineService) {
                    Text(autoLabel).tag(ServiceKind?.none)
                    ForEach(llms) { kind in
                        Text(kind.displayName).tag(ServiceKind?.some(kind))
                    }
                }
                .disabled(llms.isEmpty)

                LabeledContent("选「自动」时依次尝试") { chain }
            } header: {
                Text("翻译引擎")
            } footer: {
                Text(llms.isEmpty ? """
                还没有启用语言模型，扩展会用本机翻译。在「翻译服务」里开启一个 \
                （如 DeepSeek）并填好 API Key，网页就能按上下文翻译。
                """ : """
                与工作台共用。大模型会读到网页标题、上一段和你在扩展里写的说明，\
                术语前后一致；本机翻译离线、免费，但只能逐句翻。\
                「自动」挑第一个能用的，Lumi 没开时直接用 Google。
                """)
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("翻译整页 / 显示原文") { Keycap("⌥T") }
                LabeledContent("只翻译指针下的那一段") {
                    HStack(spacing: 5) {
                        Text("轻点").font(.caption).foregroundStyle(.secondary)
                        Keycap("⌥")
                    }
                }
                LabeledContent("译文样式、语言、每个网站的说明") {
                    Text("Safari 工具栏里的 Lumi 按钮")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("在网页上")
            }
        }
        .formStyle(.grouped)
        .animation(Motion.settle, value: connected)
        .animation(Motion.settle, value: extensionEnabled)
        .task(id: settings.workbenchOnlineService) { await watch() }
    }

    // MARK: Header

    /// What the extension is doing right now, in one line, next to the thing
    /// that fixes it when it is not doing anything.
    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "safari.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white, Color.accentColor)
                        .background(Circle().fill(.background).padding(-1.5))
                        .offset(x: 2, y: 2)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("Lumi 网页翻译")
                    .font(.headline)
                HStack(spacing: 6) {
                    BridgeDot(tone: headline.tone)
                    Text(headline.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .lineLimit(2)
                }
                if let openError {
                    Text(openError)
                        .font(.caption).foregroundStyle(.orange)
                        .lineLimit(2)
                        .transition(.opacity)
                }
            }

            Spacer(minLength: 8)

            Button("在 Safari 中设置") { openInSafari() }
                .controlSize(.regular)
        }
        .padding(.vertical, 4)
        .animation(Motion.settle, value: bridge.paragraphsServed)
        .animation(Motion.settle, value: openError)
    }

    private var headline: (text: String, tone: BridgeDot.Tone) {
        if case .failed(let why) = bridge.state {
            return ("端口 \(PageBridge.port) 不可用：\(why)", .bad)
        }
        if bridge.state == .stopped { return ("Lumi 的网页接口没有启动", .bad) }
        if connected {
            return bridge.paragraphsServed == 0
                ? ("已连接，按 ⌥T 翻译当前网页", .ok)
                : ("已连接 · 本次启动翻译了 \(bridge.paragraphsServed) 段", .ok)
        }
        if extensionEnabled == true { return ("扩展已开启，打开或刷新一个网页", .waiting) }
        return ("等待 Safari 扩展连接", .idle)
    }

    // MARK: Steps

    /// Enabling an unsigned extension is a sequence the reader has to walk in
    /// order, in another app — so it is numbered, and each step ticks itself
    /// off from what Lumi can observe rather than asking to be told.
    enum Step: Int, CaseIterable, Identifiable {
        case allowUnsigned, enable, openPage
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .allowUnsigned: "Safari 设置 › 开发者 › 勾选「允许未签名的扩展」"
            case .enable:        "Safari 设置 › 扩展 › 勾选「Lumi 网页翻译」"
            case .openPage:      "允许它访问网站，然后刷新网页"
            }
        }

        var detail: String? {
            switch self {
            case .allowUnsigned: "看不到「开发者」：先在「高级」里勾选「显示网页开发者功能」"
            case .enable:        nil
            case .openPage:      "网页右侧出现 Lumi 的玻璃按钮，就是连上了"
            }
        }
    }

    private func isDone(_ step: Step) -> Bool {
        switch step {
        // An enabled extension is only listed once unsigned ones are allowed.
        case .allowUnsigned, .enable: connected || extensionEnabled == true
        case .openPage:               connected
        }
    }

    private func stepRow(_ step: Step) -> some View {
        let done = isDone(step)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.16) : .clear)
                Circle().strokeBorder(done ? Color.green.opacity(0.5) : Chrome.chipStroke, lineWidth: 1)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(Chrome.chipFont.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(width: 18, height: 18)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .foregroundStyle(done ? .secondary : .primary)
                if let detail = step.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(Motion.pop, value: done)
    }

    // MARK: Engines

    /// The order 自动 walks, drawn as the service rail draws services: a chip
    /// per engine, each with the dot that says whether it can answer now.
    private var chain: some View {
        HStack(spacing: 4) {
            ForEach(Array(chainLinks.enumerated()), id: \.offset) { index, link in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 5) {
                    Image(systemName: link.symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(link.name).font(Chrome.chipFont)
                    BridgeDot(tone: link.tone, size: 5)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .chipShell()
                .help(link.help)
            }
        }
    }

    private struct ChainLink {
        let name: String
        let symbol: String
        let tone: BridgeDot.Tone
        let help: String
    }

    private var chainLinks: [ChainLink] {
        func tone(_ id: String) -> BridgeDot.Tone {
            guard let engine = engines.first(where: { $0.id == id }) else { return .idle }
            return engine.ready ? .ok : .warn
        }
        func help(_ id: String) -> String {
            engines.first(where: { $0.id == id })?.detail ?? ""
        }
        let online = engines.first { $0.id == WorkbenchEngineID.online.rawValue }
        return [
            ChainLink(name: online?.name ?? llms.first?.displayName ?? "大模型", symbol: "sparkle",
                 tone: tone(WorkbenchEngineID.online.rawValue), help: help(WorkbenchEngineID.online.rawValue)),
            ChainLink(name: "本机", symbol: "desktopcomputer",
                 tone: tone(WorkbenchEngineID.offline.rawValue), help: help(WorkbenchEngineID.offline.rawValue)),
            ChainLink(name: "Google", symbol: "globe", tone: .ok,
                 help: "不需要 Lumi；逐句翻译，读不到上下文"),
        ]
    }

    private var llms: [ServiceKind] {
        settings.orderedServices.filter { settings.enabledServices.contains($0) && $0.isLLM }
    }

    private var autoLabel: String {
        llms.first.map { "自动（\($0.displayName)）" } ?? "自动"
    }

    // MARK: Observation

    /// Recent enough that the extension is plausibly still there. Safari
    /// quitting is not something Lumi hears about, so this is a window, not
    /// a flag.
    private var connected: Bool {
        guard let last = bridge.lastContact else { return false }
        return Date.now.timeIntervalSince(last) < 30 * 60
    }

    /// Safari and the engines both change in other windows, so the tab asks
    /// again every few seconds while it is on screen.
    private func watch() async {
        while !Task.isCancelled {
            async let state = SafariExtension.isEnabled()
            async let report = PageBridge.status(target: nil)
            let (enabled, status) = await (state, report)
            extensionEnabled = enabled
            engines = status.engines
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func openInSafari() {
        Task {
            let shown = await SafariExtension.showSettings()
            openError = shown ? nil : "Safari 还没发现这个扩展。先完成第 1 步，再点一次。"
        }
    }
}

/// The two questions Lumi can ask Safari about its extension.
///
/// Through the async forms only. The SDK marks the state callback
/// `NS_SWIFT_UI_ACTOR` but Safari delivers it on an XPC queue, so a Swift 6
/// closure handed to it traps on the runtime isolation check. The async
/// import resumes a continuation instead and never makes that check.
enum SafariExtension {
    static let identifier = "com.tianruijia.Lumi.Safari"

    /// nil when Safari cannot say — it has not seen the extension yet.
    static func isEnabled() async -> Bool? {
        try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: identifier).isEnabled
    }

    static func showSettings() async -> Bool {
        do {
            try await SFSafariApplication.showPreferencesForExtension(withIdentifier: identifier)
            return true
        } catch {
            return false
        }
    }
}

/// `StatusDot` from the service rail, keyed by bridge state: green can answer, orange needs setting up,
/// accent means waiting on the reader, grey means nothing to say yet.
private struct BridgeDot: View {
    enum Tone { case ok, warn, bad, waiting, idle }
    let tone: Tone
    var size: CGFloat = 7
    @Stored private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.35 : 1)
            .animation(Motion.settle, value: tone)
            // The rail's "working" rhythm: 0.65s each way, only while waiting.
            .animation(tone == .waiting
                       ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true)
                       : Motion.settle, value: dim)
            .onChange(of: tone, initial: true) { _, tone in dim = tone == .waiting }
    }

    private var color: Color {
        switch tone {
        case .ok:      .green
        case .warn:    .orange.opacity(0.7)
        case .bad:     .orange
        case .waiting: .accentColor
        case .idle:    .secondary.opacity(0.5)
        }
    }
}

/// A key as the 11pt chrome draws it — the capsule's hairline, squared off.
private struct Keycap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(Chrome.hover))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Chrome.chipStroke, lineWidth: 1))
    }
}

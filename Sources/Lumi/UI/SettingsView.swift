import SwiftUI
import Translation

struct SettingsView: View {
    @Stored private var settings = AppSettings.shared
    /// 界面语言的真相源；用 @Stored（= @State）拿投影，`$localization.language` 可绑定。
    @Stored private var localization = Localization.shared
    @Stored private var launchAtLogin = LaunchAtLogin.isEnabled
    @Stored private var launchError: String?
    @Stored private var permissions = PermissionStatus()
    @Stored private var directory = ModelDirectory.shared
    @Stored private var offlinePack: LanguageAvailability.Status?
    /// Which tab is open. Seeded from the environment so a build script can
    /// photograph a tab other than the first one.
    @Stored private var tab =
        ProcessInfo.processInfo.environment["LUMI_SETTINGS_TAB"] ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label(t("通用"), systemImage: "gearshape") }.tag("general")
            services.tabItem { Label(t("翻译服务"), systemImage: "sparkles") }.tag("services")
            PageTranslationSettings().tabItem { Label(t("网页翻译"), systemImage: "safari") }.tag("web")
            permissionsTab.tabItem { Label(t("权限"), systemImage: "lock.shield") }.tag("permissions")
        }
        .frame(width: 480, height: 380)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Picker(t("界面语言"), selection: $localization.language) {
                    // 语言名用各自的写法（endonym）：只看得懂中文的人，
                    // 在英文界面里也要认得出「简体中文」才能改回来。
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Text(t("只影响界面文字。翻译结果、提示词和词源解析始终按原文处理。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(t("查询语言")) {
                Picker(t("第一语言（通常是母语）"), selection: $settings.firstLanguage) {
                    ForEach(Language.allCases.filter { $0 != .auto }) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker(t("第二语言"), selection: $settings.secondLanguage) {
                    ForEach(Language.allCases.filter { $0 != .auto }) {
                        Text($0.displayName).tag($0)
                    }
                }
                Text(t("方向会自动对调：第一语言的文本译到第二语言，反之亦然。所以同一个快捷键中英文都能用，不必每次去改目标语言。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(t("外观")) {
                Picker(t("主题"), selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: settings.appearance) { _, mode in mode.apply() }

                LabeledContent(t("字号")) {
                    HStack(spacing: 8) {
                        Text(t("小")).font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.fontScale, in: 0.85...1.5, step: 0.05)
                            .frame(width: 160)
                        Text(t("大")).font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", settings.fontScale * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                LabeledContent(t("结果区最高")) {
                    HStack(spacing: 8) {
                        Slider(value: $settings.resultsMaxHeight, in: 240...900, step: 20)
                            .frame(width: 180)
                        Text("\(Int(settings.resultsMaxHeight))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                LabeledContent(t("窗口宽度")) {
                    HStack(spacing: 8) {
                        Slider(value: $settings.panelWidth, in: 360...680, step: 10)
                            .frame(width: 180)
                        Text("\(Int(settings.panelWidth))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section(t("查询行为")) {
                Picker(t("输入框折叠行数"), selection: $settings.inputCollapsedLines) {
                    ForEach(2...8, id: \.self) { Text(t("%d 行", $0)).tag($0) }
                }
                Text(t("超过这个行数时输入框会收起，右侧出现展开按钮 —— 长句的译文才不会被挤出窗口。"))
                    .font(.caption).foregroundStyle(.secondary)

                Toggle(t("翻译后自动复制结果"), isOn: $settings.autoCopyResult)
                Toggle(t("查单词后自动朗读"), isOn: $settings.autoSpeakWords)
                Toggle(t("翻译后清空输入框"), isOn: $settings.clearInputAfterQuery)
                Toggle(t("取词为空时保留上次结果"), isOn: $settings.keepPreviousOnEmptySelection)
                Toggle(t("出结果时播放提示音"), isOn: $settings.playSoundOnResult)
                Text(t("自动复制和自动朗读只作用于最先返回的那个服务 —— 多个服务并发出结果，让最后到的去覆盖剪贴板或盖着前一个念，都不是「自动」该有的行为。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(t("窗口")) {
                Toggle(t("固定窗口（点击别处不自动收起）"), isOn: $settings.pinPanel)
                LabeledContent(
                    settings.panelTopLeft == nil ? t("跟随鼠标位置") : t("使用你上次摆放的位置")
                ) {
                    Button(t("重置为跟随鼠标")) { settings.panelTopLeft = nil }
                        .disabled(settings.panelTopLeft == nil)
                }
            }

            Section(t("快捷键")) {
                ForEach(HotKeyAction.allCases) { HotKeyRecorder(action: $0) }
                Text(t("点击快捷键按钮后直接按下新组合，Esc 取消。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(t("启动")) {
                Toggle(t("登录时自动启动"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { wanted in
                        switch LaunchAtLogin.set(wanted) {
                        case .success:
                            launchAtLogin = LaunchAtLogin.isEnabled
                            launchError = LaunchAtLogin.needsApproval
                                ? t("已登记，请到「系统设置 › 通用 › 登录项」中允许。")
                                : nil
                        case .failure(let error):
                            launchError = error.localizedDescription
                        }
                    }
                ))
                .disabled(!LaunchAtLogin.isSupported)

                if !LaunchAtLogin.isSupported {
                    Text(t("需要先把 Lumi 移动到「应用程序」文件夹。登录项绑定 App 的路径，从构建目录登记会在你挪动它之后失效。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if let launchError {
                    HStack(spacing: 6) {
                        Text(launchError).font(.caption).foregroundStyle(.secondary)
                        Button(t("打开登录项")) { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Services

    /// Catalog order, grouped by section, without reordering within a group.
    private var sections: [(String, [ServiceKind])] {
        var order: [String] = []
        var grouped: [String: [ServiceKind]] = [:]
        for kind in settings.orderedServices {
            if grouped[kind.section] == nil { order.append(kind.section) }
            grouped[kind.section, default: []].append(kind)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private var services: some View {
        Form {
            Section {
                ForEach(settings.orderedServices.filter(settings.enabledServices.contains)) {
                    ladderRow($0)
                }
            } header: {
                Text(t("查询顺序"))
            } footer: {
                Text(t("这些服务会被同时查询，但面板显示的是其中排最前、且真的给出了结果的那一个。                词典查不到词条、或者离线时联网服务用不了，就自动落到下一个。把最信任的放在最上面。"))
                .font(.caption).foregroundStyle(.secondary)
            }

            // The catalog is grouped by kind, which is how someone *finds* a
            // service. The ladder above is ordered by preference, which is how
            // they use it — showing one list grouped and calling it an order
            // was a contradiction: 系统翻译 sat next to 系统词典 while actually
            // being last.
            ForEach(sections, id: \.0) { section, kinds in
                Section(section) {
                    ForEach(kinds) { kind in
                        Toggle(isOn: enabledBinding(kind)) {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                }
            }

            Section(t("大模型通用")) {
                Picker(t("推理强度"), selection: $settings.llmEffort) {
                    Text(t("低（最快，翻译够用）")).tag("low")
                    Text(t("中")).tag("medium")
                    Text(t("高（长句更准，较慢）")).tag("high")
                }
                Text(t("密钥一律保存在系统钥匙串，不写入配置文件。内置的模型名核对于 %@，厂商改名很频繁 —— 用模型框旁边的 ↻ 按钮直接向服务商拉取当前列表。", ServiceKind.modelsVerified))
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: "\(settings.firstLanguage.rawValue)-\(settings.secondLanguage.rawValue)") {
            await refreshOfflinePack()
        }
    }

    /// One rung: its position, its name, and whatever it needs configured.
    @ViewBuilder
    private func ladderRow(_ kind: ServiceKind) -> some View {
        let enabled = settings.orderedServices.filter(settings.enabledServices.contains)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\((enabled.firstIndex(of: kind) ?? 0) + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .trailing)
                Label(kind.displayName, systemImage: kind.symbolName)
                Spacer()
                Button { settings.moveService(kind, by: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(enabled.first == kind)
                Button { settings.moveService(kind, by: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(enabled.last == kind)
            }
            configuration(for: kind).padding(.leading, 22)
        }
    }

    /// Apple Translate is the bottom rung of the fallback ladder, but only if
    /// its language pack is actually on disk — otherwise "offline fallback" is
    /// a promise the app cannot keep, and the user finds out at 30,000 feet.
    private func offlinePackRow() -> some View {
        HStack(spacing: 6) {
            Image(systemName: offlinePack == .installed ? "checkmark.circle" : "arrow.down.circle")
                .font(.system(size: 11))
            Text(offlinePackLabel)
                .font(.caption)
            if offlinePack == .supported {
                Button(t("打开语言设置")) {
                    guard let url = URL(
                        string: "x-apple.systempreferences:com.apple.Localization-Settings.extension"
                    ) else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .foregroundStyle(offlinePack == .installed ? Color.green : Color.secondary)
    }

    private var offlinePackLabel: String {
        switch offlinePack {
        case .installed:   t("语言包已下载，离线可用")
        case .supported:   t("语言包未下载 —— 离线时回退到这里会落空")
        case .unsupported: t("系统翻译不支持当前语言对")
        default:           t("正在检查语言包…")
        }
    }

    private func refreshOfflinePack() async {
        guard let source = settings.firstLanguage.localeLanguage,
              let target = settings.secondLanguage.localeLanguage else { return }
        offlinePack = await LanguageAvailability().status(from: source, to: target)
    }

    @ViewBuilder
    private func configuration(for kind: ServiceKind) -> some View {
        if kind == .appleTranslate {
            offlinePackRow()
        } else if kind.canEnumerateModels {
            HStack(spacing: 4) {
                TextField(t("模型"), text: modelBinding(kind), prompt: Text(kind.defaultModel))
                    .textFieldStyle(.roundedBorder)

                Menu {
                    ForEach(directory.models(for: kind), id: \.self) { suggestion in
                        Button(suggestion) { settings.setModel(suggestion, for: kind) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(directory.models(for: kind).isEmpty)

                // The shipped list is a starting point; this asks the vendor.
                Button {
                    Task { await directory.refresh(kind) }
                } label: {
                    if directory.isLoading(kind) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help(t("从服务商拉取当前可用模型"))
                .disabled(directory.isLoading(kind))
            }

            if let error = directory.error(for: kind) {
                Text(t("拉取模型失败：%@", error))
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(2)
            } else if directory.isLive(kind) {
                Text(t("模型列表已从服务商更新。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        if kind == .customOpenAI {
            TextField(t("API 地址"), text: baseURLBinding(kind),
                      prompt: Text("https://example.com/v1"))
                .textFieldStyle(.roundedBorder)
        }

        if kind.family == .ollama {
            TextField(t("Ollama 地址"), text: $settings.ollamaHost)
                .textFieldStyle(.roundedBorder)
            Text(t("需先运行 `ollama serve`，并用 `ollama pull` 下载一个本地模型。"))
                .font(.caption).foregroundStyle(.secondary)
        }

        if kind.needsKey {
            HStack(spacing: 6) {
                SecureField("API Key", text: keyBinding(kind))
                    .textFieldStyle(.roundedBorder)
                if let url = kind.keyPageURL {
                    Link(t("获取"), destination: url).font(.caption)
                }
            }
            if kind == .deepL {
                Text(t("免费版和专业版共用此处：密钥以 `:fx` 结尾会自动走免费接口。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Bindings into the settings dictionaries

    private func enabledBinding(_ kind: ServiceKind) -> Binding<Bool> {
        Binding(
            get: { settings.enabledServices.contains(kind) },
            set: { isOn in
                if isOn { settings.enabledServices.insert(kind) }
                else { settings.enabledServices.remove(kind) }
            }
        )
    }

    private func modelBinding(_ kind: ServiceKind) -> Binding<String> {
        Binding(get: { settings.model(for: kind) },
                set: { settings.setModel($0, for: kind) })
    }

    private func baseURLBinding(_ kind: ServiceKind) -> Binding<String> {
        Binding(get: { settings.baseURL(for: kind) },
                set: { settings.setBaseURL($0, for: kind) })
    }

    private func keyBinding(_ kind: ServiceKind) -> Binding<String> {
        Binding(get: { settings.apiKey(for: kind) },
                set: { settings.setAPIKey($0, for: kind) })
    }

    // MARK: Permissions

    private var permissionsTab: some View {
        Form {
            Section {
                permissionRow(
                    title: t("辅助功能"),
                    granted: permissions.accessibility,
                    note: t("用于读取其他 App 里选中的文本。未授权时快捷键取词无法工作。"),
                    open: Permissions.openAccessibilitySettings
                )
            }

            Section {
                permissionRow(
                    title: t("屏幕录制"),
                    granted: permissions.screenRecording,
                    note: t("截图翻译需要此权限。"),
                    open: Permissions.openScreenRecordingSettings
                )
            }

            Section {
                Text(t("如果系统设置里开关已经打开、这里却仍显示未授权，通常是 App 不是由 访达或 `open` 启动的 —— 直接运行 bundle 里的可执行文件时，系统会把 权限算到启动它的终端头上。"))
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Granting happens in another process; poll while this tab is visible.
        .task { await permissions.poll() }
    }

    private func permissionRow(
        title: String, granted: Bool, note: String, open: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    Label(
                        granted ? t("已授权") : t("未授权"),
                        systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(granted ? .green : .orange)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .contentTransition(.symbolEffect(.replace))

                    Button(t("打开设置"), action: open)
                }
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .animation(Motion.settle, value: granted)
    }
}

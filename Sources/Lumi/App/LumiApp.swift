import AppKit
import SwiftUI

@main
struct LumiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(systemName: "character.bubble.fill")
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.shared.appearance.apply()
        WindowDragMonitor.install()
        flushOnSIGTERM()

        Log.hotKey.info("launch: accessibility=\(Permissions.hasAccessibility, privacy: .public)")
        HotKeyCenter.shared.reloadBindings()
        // The Safari extension translates through this. Started
        // unconditionally: it costs one idle socket, and an extension that
        // silently falls back to Google because a toggle was off would be
        // worse than no toggle.
        PageBridge.shared.start()

        // Dev affordance: bring the panel up without a hot-key, so the UI can be
        // exercised from a script or a fresh checkout.
        let env = ProcessInfo.processInfo.environment
        if env["LUMI_SHOW_ON_LAUNCH"] == "1" {
            PanelController.shared.showInput()
            if let demo = env["LUMI_DEMO_QUERY"], !demo.isEmpty {
                PanelController.shared.state.deliverCapture(demo)
            }
            // Picking a chip is a user gesture, so it needs a way to be driven
            // from a script if the switch is ever going to be regression-tested.
            if let pick = env["LUMI_DEMO_FOCUS"], let kind = ServiceKind(rawValue: pick) {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    PanelController.shared.state.focus(kind)
                }
            }
        }

        // Same dev affordance as the panel's: the workbench can be opened,
        // and optionally pre-loaded, without a key press — otherwise every
        // check of it needs a human at the keyboard.
        if env["LUMI_SHOW_WORKBENCH"] == "1" {
            var loaded = false
            if let engine = env["LUMI_WORKBENCH_ENGINE"], let id = WorkbenchEngineID(rawValue: engine) {
                WorkbenchController.shared.document.engineID = id
            }
            if let path = env["LUMI_WORKBENCH_FILE"],
               let file = try? WorkbenchController.readFile(URL(fileURLWithPath: path)) {
                WorkbenchController.shared.start(file.text, fallbackTitle: file.title, format: file.format)
                loaded = true
            }
            // A source and someone else's translation, reviewed at once; the
            // report lists every note, which a screenshot cannot.
            if let sourcePath = env["LUMI_PROOF_SOURCE"], let targetPath = env["LUMI_PROOF_TRANSLATION"],
               let source = try? WorkbenchController.readFile(URL(fileURLWithPath: sourcePath)),
               let target = try? WorkbenchController.readFile(URL(fileURLWithPath: targetPath)) {
                loaded = true
                let reportPath = env["LUMI_PROOF_REPORT"]
                Task { @MainActor in
                    let started = Date()
                    await WorkbenchController.shared.startProof(
                        source: source.text, translation: target.text,
                        fallbackTitle: source.title, format: source.format ?? target.format
                    )
                    // Pairing repairs, as the segment menu makes them:
                    // "pull:2;gap:4" (1-based rows).
                    for op in (env["LUMI_PROOF_OPS"] ?? "").split(separator: ";") {
                        let parts = op.split(separator: ":")
                        guard parts.count == 2, let row = Int(parts[1]) else { continue }
                        let document = WorkbenchController.shared.document
                        if parts[0] == "pull" { document.pullNext(into: row - 1) }
                        if parts[0] == "gap" { document.insertGap(at: row - 1) }
                    }
                    if let path = reportPath {
                        let document = WorkbenchController.shared.document
                        try? await Task.sleep(for: .milliseconds(300))
                        while document.isRunning || document.checkingTerms, Date().timeIntervalSince(started) < 600 {
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                        var report = "format=\(document.format.rawValue) \(document.resolvedSource.rawValue)->\(document.resolvedTarget.rawValue) segments=\(document.segments.count) reviewed=\(document.reviewedCount) issues=\(document.openIssueCount) reviewer=\(document.reviewerLabel) elapsed=\(String(format: "%.1f", Date().timeIntervalSince(started)))s problem=\(document.engineProblem ?? "none")\n"
                        for segment in document.segments {
                            report += "[\(segment.id)] \(segment.block) review=\(segment.review)\n"
                            report += "    SRC \(segment.source.prefix(160))\n"
                            report += "    OUT \(segment.translation.prefix(160))\n"
                            if !segment.terms.isEmpty {
                                report += "    terms: " + segment.terms.map { "\($0.source)=\($0.target)" }.joined(separator: "; ") + "\n"
                            }
                            for issue in segment.issues {
                                report += "    - \(issue.origin.rawValue)/\(issue.kind.rawValue) q=「\(issue.quote)」 s=「\(issue.suggestion ?? "")」 \(issue.note)\n"
                            }
                        }
                        try? report.write(toFile: path, atomically: true, encoding: .utf8)
                        if env["LUMI_WORKBENCH_QUIT"] == "1" { NSApp.terminate(nil) }
                    }
                }
            }
            if env["LUMI_WORKBENCH_MODE"] == "compose" {
                WorkbenchController.shared.navigation.mode = .compose
                loaded = true
            }
            if env["LUMI_WORKBENCH_MODE"] == "proof" {
                WorkbenchController.shared.navigation.mode = .proofCompose
                loaded = true
            }
            WorkbenchController.shared.show(keepingPlace: loaded)
            Log.window.info("pasteboard access: \(NSPasteboard.general.accessBehavior.rawValue, privacy: .public)")

            // Open, close, open again. The policy flips are the one part of
            // this window that can leave the app wedged — a Dock icon with no
            // window, or a regular app with no menu bar the second time — and
            // they cannot be reached without a click, which a build loop does
            // not have.
            // Translate the loaded document and write a per-segment report.
            // Translation is the one part of this window a screenshot cannot
            // check: what matters is which segments came back flagged, and that
            // is a list, not a picture.
            if env["LUMI_WORKBENCH_TRANSLATE"] == "1" {
                let document = WorkbenchController.shared.document
                Task { @MainActor in
                    let started = Date()
                    document.translateAll()
                    while document.isRunning, Date().timeIntervalSince(started) < 900 {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    var report = """
                    engine=\(document.engineID.rawValue) \
                    \(document.resolvedSource.rawValue)->\(document.resolvedTarget.rawValue) \
                    segments=\(document.segments.count) \
                    done=\(document.doneCount) dropped=\(document.droppedCount) \
                    failed=\(document.failedCount) \
                    elapsed=\(String(format: "%.1f", Date().timeIntervalSince(started)))s
                    problem=\(document.engineProblem ?? "none")

                    """
                    for segment in document.segments {
                        let mark: String
                        switch segment.status {
                        case .done:              mark = "ok      "
                        case .dropped(let why):  mark = "DROPPED(\(why)) "
                        case .failed(let why):   mark = "FAILED(\(why)) "
                        case .pending:           mark = "pending "
                        case .running:           mark = "running "
                        }
                        report += "[\(segment.id)] \(mark)\n"
                        report += "    SRC \(segment.source.prefix(150))\n"
                        report += "    OUT \(segment.translation.prefix(150))\n"
                    }
                    if let path = env["LUMI_WORKBENCH_REPORT"] {
                        try? report.write(toFile: path, atomically: true, encoding: .utf8)
                    }
                    Log.window.info("workbench translate done: \(report, privacy: .public)")
                    if env["LUMI_WORKBENCH_QUIT"] == "1" { NSApp.terminate(nil) }
                }
            }

            if let step = Double(env["LUMI_WORKBENCH_CYCLE"] ?? "") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(step))
                    WorkbenchController.shared.closeForTesting()
                    try? await Task.sleep(for: .seconds(step))
                    WorkbenchController.shared.show()
                }
            }
        }

        // The 词源 page, opened on a word (or on its search page with "1"),
        // so every state of it can be reached from a script.
        if let word = env["LUMI_SHOW_ETYMOLOGY"] {
            WorkbenchController.shared.showEtymology(word == "1" ? nil : word)
            if let raw = env["LUMI_ETYMOLOGY_SCROLL"], let section = EtymologySection(rawValue: raw) {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Double(env["LUMI_ETYMOLOGY_SCROLL_AFTER"] ?? "") ?? 8))
                    EtymologyStore.shared.scrollTarget = section
                }
            }
        }

        // Headless visual check: render the panel and quit. Lets the build loop
        // look at its own output instead of asking a human to describe it.
        if env["LUMI_OPEN_SETTINGS"] == "1" {
            Task { @MainActor in
                // The Settings scene is not registered yet at launch time, and
                // the selector was renamed between releases — try both.
                //
                // 已知限制（macOS 27 实测）：`sendAction` 返回 true，但 Lumi 是 LSUIElement，
                // 后台启动时 `activate()` 不会真的把它激活（实测 active=false、windows=0），
                // 于是设置窗口不出现——`LUMI_WINDOW_SHOT` 也就拍不到它。下面重试并写日志，
                // 让这件事有据可查，而不是"截图没生成，不知道为什么"。
                // 要拍设置界面，目前只能由人打开设置后自己截屏。
                try? await Task.sleep(for: .seconds(1))
                for attempt in 1...4 {
                    // LSUIElement（后台 agent）默认是 .accessory：activate() 不会真的把它激活，
                    // 于是设置窗口永远不出现（实测 selector 返回 true，但 active=false、windows=0）。
                    // 工作台能弹出来，正是因为它先把 policy 提到 .regular —— 这里照做。
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                    var handled = ""
                    for name in ["showSettingsWindow:", "showPreferencesWindow:"]
                    where NSApp.sendAction(Selector((name)), to: nil, from: nil) {
                        handled = name
                        break
                    }
                    try? await Task.sleep(for: .seconds(1))
                    let visible = NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 }
                    Log.window.info("""
                        open settings: attempt=\(attempt, privacy: .public) \
                        selector=\(handled.isEmpty ? "none" : handled, privacy: .public) \
                        active=\(NSApp.isActive, privacy: .public) \
                        windows=\(visible.count, privacy: .public)
                        """)
                    if !visible.isEmpty { break }
                }
            }
        }

        if let path = env["LUMI_WINDOW_SHOT"] {
            let delay = Double(env["LUMI_SNAPSHOT_DELAY"] ?? "") ?? 2.5
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                // Settings is a separate scene, so the capture has to look it
                // up rather than assume the panel is the interesting window.
                PanelController.shared.windowShot(
                    to: path, settingsWindow: env["LUMI_OPEN_SETTINGS"] == "1")
                if env["LUMI_SNAPSHOT_QUIT"] != "0" { NSApp.terminate(nil) }
            }
        }

        if let path = env["LUMI_SNAPSHOT"] {
            let delay = Double(env["LUMI_SNAPSHOT_DELAY"] ?? "") ?? 2.5
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                PanelController.shared.snapshot(to: path)
                if env["LUMI_SNAPSHOT_QUIT"] != "0" { NSApp.terminate(nil) }
            }
        }

        // Ask on first launch only — AXIsProcessTrustedWithOptions is a no-op
        // prompt once the user has already granted or explicitly denied.
        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
        DocumentStore.shared.flush()
    }

    /// A plain `kill` never reaches `applicationWillTerminate`; the last
    /// second of edits would go with the process.
    private var terminationSource: DispatchSourceSignal?

    private func flushOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { DocumentStore.shared.flush() }
            exit(0)
        }
        source.resume()
        terminationSource = source
    }
}

private struct MenuContent: View {
    var body: some View {
        Button(t("翻译选中文本  %@", AppSettings.shared.hotKey(for: .translateSelection).displayString)) {
            PanelController.shared.translateSelection()
        }
        Button(t("打开输入框  %@", AppSettings.shared.hotKey(for: .showInput).displayString)) {
            PanelController.shared.showInput()
        }
        Button(t("截图翻译  %@", AppSettings.shared.hotKey(for: .captureScreen).displayString)) {
            PanelController.shared.translateScreenRegion()
        }
        Divider()
        Button(t("工作台  %@", AppSettings.shared.hotKey(for: .showWorkbench).displayString)) {
            WorkbenchController.shared.show()
        }
        Divider()
        SettingsLink { Text(t("设置…")) }
        Divider()
        Button(t("退出 Lumi")) { NSApp.terminate(nil) }
    }
}

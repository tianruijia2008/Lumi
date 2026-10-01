import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The 工作台 window.
///
/// Lumi is an `LSUIElement` app: no Dock icon and — the part that actually
/// bites — no main menu. That is right for the panel, which is a transient
/// overlay nobody expects to find in ⌘Tab, and wrong for a window the user
/// keeps open for an hour, resizes, switches away from and closes with ⌘W.
///
/// So the activation policy is not a constant. It rises to `.regular` while
/// this window is open and drops back to `.accessory` when it closes, and the
/// main menu is built by hand because an agent app is never given one.
@MainActor
final class WorkbenchController: NSObject, NSWindowDelegate {
    static let shared = WorkbenchController()

    private var window: NSWindow?
    let document = WorkbenchDocument()
    let navigation = WorkbenchNavigation()
    private var menuInstalled = false

    // MARK: Opening and closing

    /// Opens the window. A window that was closed opens on the start page —
    /// the document being read is not lost, it is the first thing listed
    /// there — unless the caller has put it somewhere on purpose.
    func show(keepingPlace: Bool = false) {
        if !keepingPlace, window?.isVisible != true {
            navigation.mode = .home
        }
        let window = ensureWindow()
        raiseToRegular()
        window.makeKeyAndOrderFront(nil)
        // Ordering front is not enough from a background agent app: without an
        // explicit activate the window appears behind whatever the user was
        // using, which reads as the shortcut having done nothing.
        NSApp.activate()
        Log.window.info("""
            workbench shown: policy=\(NSApp.activationPolicy() == .regular ? "regular" : "other", privacy: .public) \
            active=\(NSApp.isActive, privacy: .public) key=\(window.isKeyWindow, privacy: .public) \
            menu=\(NSApp.mainMenu?.items.count ?? 0, privacy: .public) \
            segments=\(self.document.segments.count, privacy: .public)
            """)
    }

    /// Opens on the 词源 page — on `word` when given, on the search page
    /// otherwise. What the panel's 深究 calls.
    func showEtymology(_ word: String? = nil) {
        navigation.mode = .etymology
        if let word { EtymologyStore.shared.open(word) } else { EtymologyStore.shared.closeWord() }
        show(keepingPlace: true)
    }

    /// Loads a document straight into the reader.
    func load(_ text: String) {
        _ = start(text)
    }

    // MARK: Starting and reopening documents

    /// Cuts a text into segments and shows it side by side, untranslated: the
    /// engine and the notes are set on that page, before anything is spent.
    /// A text read before comes back with its translations.
    @discardableResult
    func start(_ text: String, fallbackTitle: String? = nil, format: TextFormat? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // A file's name is a better title than a first paragraph, but not
        // than a heading or a first line that is already a title.
        document.load(trimmed, fallbackTitle: fallbackTitle, format: format)
        navigation.go(.read)
        return true
    }

    /// Pairs a source with a translation made elsewhere and starts reviewing
    /// it at once: that is the only thing a proofreading document is for.
    @discardableResult
    func startProof(source: String, translation: String, fallbackTitle: String? = nil,
                    format: TextFormat? = nil, notes: String = "") async -> Bool {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !translation.isEmpty, !document.aligning else { return false }
        var draft = WorkbenchDocument.prepareProof(source: source, translation: translation, format: format)
        // Paired by meaning when a model is at hand; by length otherwise.
        if DocumentStore.shared.existing(fingerprint: draft.fingerprint) == nil,
           document.engineID == .online,
           let provider = AppSettings.shared.workbenchOnlineProvider(),
           NetworkMonitor.shared.isOnline || !provider.requiresNetwork {
            document.aligning = true
            draft.pairs = await ModelAligner.align(source: draft.source, target: draft.target,
                                                   from: draft.from, to: draft.to, provider: provider)
            document.aligning = false
        }
        document.loadProof(draft, fallbackTitle: fallbackTitle)
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty, !document.hasReview { document.context = notes }
        // Not `go`: this runs seconds later, as the continuation of a network
        // call, often while the reader has switched to another Space. Measured
        // there: the animated cross-fade cannot finish on a window that is not
        // drawing, and the compose page stayed up beside a sidebar that had
        // already moved to the document. Nobody is watching for a fade anyway.
        navigation.mode = .read
        if !document.hasReview { document.review() }
        return true
    }

    /// Reads a file the reader picked or dropped, knowing Markdown by its
    /// extension rather than by guessing.
    static func readFile(_ url: URL) throws -> (text: String, title: String, format: TextFormat?) {
        let text = try DroppedText.read(url)
        return (text, url.deletingPathExtension().lastPathComponent,
                DocumentParser.isMarkdownFile(url) ? .markdown : nil)
    }

    static let readableTypes: [UTType] = [.plainText, UTType("net.daringfireball.markdown")].compactMap(\.self)

    func openDocument(_ id: UUID) {
        guard let saved = DocumentStore.shared.document(id) else {
            // The index outlived its file; drop the dead row.
            DocumentStore.shared.remove(id)
            return
        }
        if document.id != id { document.restore(saved) } else { document.resumeReading() }
        navigation.go(.read)
    }

    @objc func openFile(_ sender: Any? = nil) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.readableTypes
        panel.allowsMultipleSelection = false
        panel.message = t("选一个文本文件（.txt、.md）")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    let file = try Self.readFile(url)
                    self.start(file.text, fallbackTitle: file.title, format: file.format)
                } catch {
                    Log.window.error("open failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Picks a file for one side of a proofreading pair.
    func chooseFile(_ completion: @escaping @MainActor (String, String, TextFormat?) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.readableTypes
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let file = try? Self.readFile(url) else { return }
                completion(file.text, file.title, file.format)
            }
        }
    }

    /// Saves the translation where the reader says, as Markdown when that is
    /// what came in.
    func exportTranslation() {
        guard let window, document.isLoaded else { return }
        let panel = NSSavePanel()
        let markdown = document.format == .markdown
        panel.allowedContentTypes = markdown ? Self.readableTypes.reversed() : [.plainText]
        let base = document.title.replacingOccurrences(of: "/", with: "-").prefix(60)
        panel.nameFieldStringValue = t("%@（译文）", String(base)) + ".\(markdown ? "md" : "txt")"
        let text = document.exportedTranslation
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Log.window.error("export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// ⌘V on the start page. Reached through the responder chain — the
    /// window's delegate is its last stop — so a focused text field still
    /// gets its own paste first, and because it is a real paste command the
    /// system lets it read the pasteboard without asking.
    @objc func paste(_ sender: Any?) {
        guard navigation.mode == .home else { return }
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let file = try? Self.readFile(url) {
            start(file.text, fallbackTitle: file.title, format: file.format)
        } else if let text = pasteboard.string(forType: .string) {
            start(text)
        }
    }

    /// Closes exactly the way the red button does, so the dev hook exercises
    /// the real path rather than a shortcut around it.
    func closeForTesting() {
        window?.performClose(nil)
    }

    func toggle() {
        if let window, window.isVisible { window.performClose(nil) } else { show() }
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        created.title = t("工作台")
        // Glass, like the panel: the window is not opaque and draws nothing of
        // its own, so the material the shell lays down is what shows — out to
        // the edges and under the title bar.
        //
        // The content still starts below the title bar. `.fullSizeContentView`
        // only lets the *background* run up there; SwiftUI keeps every control
        // inside the safe area, so nothing drawn in the top 28pt competes with
        // the traffic lights or the title-bar drag.
        created.titlebarAppearsTransparent = true
        created.isOpaque = false
        created.backgroundColor = .clear
        created.minSize = NSSize(width: 900, height: 480)
        created.isReleasedWhenClosed = false
        created.contentView = NSHostingView(rootView: WorkbenchShell(
            navigation: navigation,
            document: document,
            onTitleChange: { [weak created] title in
                // The title *is* the document's first line, so it can be a
                // whole sentence. A window title that runs off the screen edge
                // is worse than one that stops.
                created?.title = title.count > 48 ? String(title.prefix(47)) + "…" : title
            }
        ))
        created.delegate = self
        // Remembers its own size and position across launches, which is the
        // baseline expectation for any ordinary window.
        let autosaved = created.setFrameAutosaveName("LumiWorkbench")
        Log.window.info("""
            created: autosave=\(autosaved, privacy: .public) \
            frame=\(NSStringFromRect(created.frame), privacy: .public) \
            content=\(NSStringFromRect(created.contentLayoutRect), privacy: .public)
            """)
        created.center()
        window = created
        return created
    }

    /// Becomes a normal app: Dock icon, ⌘Tab, a menu bar.
    private func raiseToRegular() {
        installMainMenuIfNeeded()
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    func windowWillClose(_ notification: Notification) {
        DocumentStore.shared.flush()
        // Dropping the policy inside the close notification leaves AppKit
        // tearing down a window belonging to an app that is no longer regular.
        // One turn of the run loop later, the close is finished.
        Task { @MainActor in
            guard self.window?.isVisible != true else { return }
            NSApp.setActivationPolicy(.accessory)
            Log.window.info("workbench closed, back to accessory")
        }
    }

    // MARK: Main menu

    /// Builds the menu bar an agent app never gets.
    ///
    /// Without this the menu bar is empty while the window is up and ⌘W, ⌘C
    /// and ⌘Z all do nothing — the editing shortcuts are not free, AppKit
    /// routes them through menu items and there are none.
    private func installMainMenuIfNeeded() {
        guard !menuInstalled else { return }
        menuInstalled = true

        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: t("关于 Lumi"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: t("设置…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: t("隐藏 Lumi"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: t("退出 Lumi"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: t("文件"))
        let open = fileMenu.addItem(withTitle: t("打开…"), action: #selector(openFile(_:)), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: t("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: t("编辑"))
        editMenu.addItem(withTitle: t("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: t("重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: t("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: t("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: t("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: t("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: t("窗口"))
        windowMenu.addItem(withTitle: t("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: t("缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        observeLanguage()
    }

    /// 界面语言变了就重建菜单栏。
    ///
    /// NSMenu 是 AppKit 对象，不会跟着 SwiftUI 的 @Observable 重绘；不重建的话菜单
    /// 会停在旧语言上（窗口里已经变了、菜单没变，看起来像 bug）。
    ///
    /// 由本类**观察** `Localization`，而不是让 `AppSettings` 反过来调用这里——
    /// Core 不该知道工作台，而且那条反向调用会让类型检查在这两个文件之间打转
    /// （实测：`activeProviders()` 会报 ElementOfResult 无法推断）。
    private func observeLanguage() {
        withObservationTracking {
            _ = Localization.shared.language
        } onChange: { [weak self] in
            // onChange 在值改变**之前**触发，跳到下一个 tick 再读才是新值。
            Task { @MainActor in
                self?.rebuildMenus()
                self?.observeLanguage()      // 观察是一次性的，重新注册
            }
        }
    }

    private func rebuildMenus() {
        guard menuInstalled else { return }
        menuInstalled = false
        installMainMenuIfNeeded()
    }

    @objc private func openSettings() {
        for name in ["showSettingsWindow:", "showPreferencesWindow:"] where
            NSApp.sendAction(Selector((name)), to: nil, from: nil) { return }
        Log.window.error("no settings selector responded")
    }
}

extension WorkbenchController: NSMenuItemValidation {
    /// Paste means "start a document" only on the start page; anywhere else
    /// the menu item belongs to whatever text field has focus, or to nobody.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)) { return navigation.mode == .home }
        return true
    }
}

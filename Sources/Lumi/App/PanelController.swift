import AppKit
import SwiftUI

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    let state = AppState()
    private var panel: GlassPanel?

    /// Set while *we* move the window, so our own repositioning is not mistaken
    /// for the user choosing a spot.
    private var isRepositioning = false

    /// Where the panel's top-left corner belongs right now — from the pointer,
    /// from the remembered position, or from the user's last drag.
    private var desiredTopLeft: CGPoint?

    private func ensurePanel() -> GlassPanel {
        if let panel { return panel }
        // Settings lives in its own scene, which cannot be opened or captured
        // from a script — showSettingsWindow: does nothing in an agent app.
        // Hosting it in the panel is the only way this build loop gets to look
        // at the settings window it just changed.
        if ProcessInfo.processInfo.environment["LUMI_PANEL_CONTENT"] == "settings" {
            let created = GlassPanel(content: AnyView(SettingsView()))
            created.delegate = self
            panel = created
            return created
        }
        let created = GlassPanel(content: AnyView(RootView(state: state)))
        created.delegate = self
        panel = created
        return created
    }

    /// Opens the panel empty, focused, ready to type.
    func showInput() {
        let panel = ensurePanel()
        if !panel.isVisible { place(panel) }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Moves the panel without that move being recorded as a user choice.
    private func place(_ panel: GlassPanel) {
        isRepositioning = true
        panel.restorePlacement()
        isRepositioning = false
        desiredTopLeft = panel.topLeft
    }

    func toggle() {
        if let panel, panel.isVisible { panel.orderOut(nil) } else { showInput() }
    }

    /// Grabs whatever is selected in the frontmost app and translates it.
    ///
    /// The panel is shown *before* the text arrives, so the window appears
    /// instantly and fills in — rather than the user pressing a key and
    /// watching nothing happen while Accessibility is queried. It is shown
    /// without being made key, which is the whole trick: the selection about
    /// to be read belongs to whatever window holds focus *now*, and taking
    /// focus first destroys the thing being read.
    ///
    /// Measured with `makeKeyAndOrderFront` here instead: the Accessibility
    /// fast path reported Lumi's own window as the system-wide focused
    /// element on every single press, so every grab fell through to a
    /// synthesised ⌘C — which lands only while the other app happens to still
    /// be *frontmost*, and comes back empty the moment it does not. A grab
    /// that comes back empty leaves the previous query on screen, which is
    /// what "按了没反应，还是上一句" actually was.
    func translateSelection() {
        guard Permissions.hasAccessibility else {
            Log.grab.error("translateSelection: Accessibility not granted")
            Permissions.requestAccessibility()
            return
        }
        let panel = ensurePanel()
        state.beginCapture()
        place(panel)
        panel.orderFront(nil)

        Task {
            let text = await TextGrabber.selectedText()
            // Focus comes to the panel only once there is nothing left to read
            // from the other app.
            panel.makeKeyAndOrderFront(nil)
            if let text, !text.isEmpty {
                Log.grab.info("grabbed \(text.count) chars")
                state.deliverCapture(text)
            } else {
                Log.grab.error("no selection grabbed")
                state.lastError = "没有取到选中的文本。试试先选中再按快捷键，或直接在上面输入。"
            }
        }
    }

    /// Screenshot → OCR → translate.
    ///
    /// The panel stays hidden during region selection so it can never end up
    /// inside the captured rectangle, then opens once there is text to show.
    func translateScreenRegion() {
        panel?.orderOut(nil)
        Task {
            do {
                guard let text = try await ScreenOCR.captureAndRecognize() else { return }
                let panel = ensurePanel()
                place(panel)
                panel.makeKeyAndOrderFront(nil)
                if text.isEmpty {
                    state.lastError = "这块区域里没有识别到文字。"
                } else {
                    state.deliverCapture(text)
                }
            } catch {
                let panel = ensurePanel()
                place(panel)
                panel.makeKeyAndOrderFront(nil)
                state.lastError = "截图识别失败：\(error.localizedDescription)"
            }
        }
    }

    /// Renders the panel to a PNG from inside the process.
    ///
    /// Screen-capture APIs need a TCC grant a build loop cannot obtain, so this
    /// goes through SwiftUI's own offscreen renderer instead. `cacheDisplay`
    /// was tried first and captured only geometry: the glass and the result
    /// text composite in separate layers and came out blank.
    ///
    /// Backdrop effects have nothing to sample offscreen, so the glass renders
    /// flat — but every piece of text, wrapping, spacing and clipping is exact,
    /// which is what iterating on layout and formatting needs.
    /// Only the result panel can be captured this way: Settings is built from
    /// `TabView` and a grouped `Form`, both AppKit-backed, which the offscreen
    /// renderer draws as an "unsupported" placeholder.
    @discardableResult
    func snapshot(to path: String) -> Bool {
        let renderer = ImageRenderer(
            content: RootView(state: state)
                .frame(width: AppSettings.shared.panelWidth)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Captures the panel as the window server actually composited it.
    ///
    /// `ImageRenderer` re-renders the view tree offscreen, which is enough to
    /// check layout but says nothing about the two things that only exist on
    /// screen: the glass material, and AppKit-backed subviews such as the text
    /// field, which come back as placeholder blocks. Asking screencapture for
    /// this one window number is the only way to see what the user sees.
    func windowShot(to path: String, settingsWindow: Bool = false) {
        let target = settingsWindow
            ? NSApp.windows.first { $0 !== panel && $0.isVisible && $0.frame.width > 300 }
            : panel
        if let w = target, ProcessInfo.processInfo.environment["LUMI_DRAG_MAP"] == "1" {
            var out = "window=\(w.frame.size)\n"
            for r in WindowDragZones.rects(in: w) { out += "zone=\(r)\n" }
            let cols = 44, rows = 22
            for row in 0..<rows {
                for col in 0..<cols {
                    let p = NSPoint(x: (Double(col) + 0.5) / Double(cols) * w.frame.width,
                                    y: w.frame.height - (Double(row) + 0.5) / Double(rows) * w.frame.height)
                    out += WindowDragZones.hitsZone(p, in: w) ? "#" : "."
                }
                out += "\n"
            }
            try? out.write(toFile: path + ".map.txt", atomically: true, encoding: .utf8)
        }
        guard let number = target?.windowNumber, number > 0 else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l\(number)", path]
        try? task.run()
        task.waitUntilExit()
    }

    /// Remembers a position the user chose by hand.
    func windowDidMove(_ notification: Notification) {
        guard !isRepositioning, let panel, panel.isVisible else { return }
        desiredTopLeft = panel.topLeft
        AppSettings.shared.panelTopLeft = panel.topLeft
    }

    /// Holds the panel's top-left corner steady as results change its height,
    /// and keeps it on screen as it grows.
    ///
    /// Measured behaviour: when the SwiftUI hosting view drives the resize,
    /// AppKit already keeps the top-left fixed, so this assignment is usually a
    /// no-op. It is kept because an earlier version computed a *height delta*
    /// instead and drifted a couple of points per resize — assigning the corner
    /// cannot drift, whatever AppKit does.
    ///
    /// Clamping can legitimately move the corner (a panel growing past the
    /// bottom of the screen), so the clamped position is adopted as the new
    /// anchor; otherwise the next resize would fight it back and oscillate.
    func windowDidResize(_ notification: Notification) {
        guard let panel, let anchor = desiredTopLeft else { return }
        isRepositioning = true
        panel.setTopLeft(anchor)
        desiredTopLeft = panel.topLeft
        isRepositioning = false
        // A borderless, non-opaque window derives its shadow from the alpha it
        // draws, and only recomputes that on request. This one changes height
        // on every result, so without this the shadow keeps the shape of a
        // previous answer.
        panel.invalidateShadow()
    }

    // Click away to dismiss — unless the user pinned it.
    //
    // Focus bounces for a moment when a non-activating panel is clicked, and
    // AppKit's drag loop resigns key outright. Acting on the first notification
    // makes the window disappear from under the pointer, so settle first and
    // re-check what is actually true.
    func windowDidResignKey(_ notification: Notification) {
        guard !AppSettings.shared.pinPanel, let panel, !panel.isUserDragging else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard let panel = self.panel,
                  !panel.isUserDragging,
                  !panel.isKeyWindow,
                  !AppSettings.shared.pinPanel
            else { return }
            panel.orderOut(nil)
        }
    }
}

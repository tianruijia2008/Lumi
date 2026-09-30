import AppKit
import SwiftUI

/// The floating translation window.
///
/// It is a `.nonactivatingPanel`, so invoking Lumi never deactivates the app
/// the user is reading — the selection stays selected, the caret stays put, and
/// there is no app-switch flash. `canBecomeKey` is still true so the text field
/// accepts typing.
final class GlassPanel: NSPanel {
    /// True while AppKit's drag loop owns the mouse. Auto-hide must stand down
    /// during that window, or the panel vanishes mid-drag.
    var isUserDragging = false

    init(content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            // Borderless on purpose. `.titled` reserves a 32pt titlebar inside
            // the frame while `preferredContentSize` sizes only the content
            // area, so the window ended up permanently 32pt taller than
            // anything drawn in it — a band of empty desktop above the glass.
            // Hiding the title and making the bar transparent does not reclaim
            // that space; nothing but dropping the style does.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        // Not `.clear`: the window server routes clicks by drawn alpha, so a
        // fully transparent pixel lets the click reach the app behind, which
        // then takes key status and auto-hides this panel. An alpha this low is
        // invisible but keeps every pixel of the frame ours.
        backgroundColor = NSColor.black.withAlphaComponent(0.001)
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: content)
        // Only drives the window's height while the hosting view *is* the
        // contentView — wrapping it in a container silently breaks auto-sizing
        // and clips the content.
        hosting.sizingOptions = [.preferredContentSize]
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape dismisses, matching every other macOS popover.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    /// Restores the remembered position if there is one and it is still
    /// reachable, otherwise falls back to the pointer.
    func restorePlacement() {
        guard let anchor = AppSettings.shared.panelTopLeft, isReachable(anchor) else {
            positionNearPointer()
            return
        }
        setTopLeft(anchor)
    }

    /// The panel's top-left corner in screen coordinates — the stable handle
    /// for a window whose height changes as results stream in.
    var topLeft: CGPoint { CGPoint(x: frame.minX, y: frame.maxY) }

    func setTopLeft(_ point: CGPoint) {
        setFrameOrigin(CGPoint(x: point.x, y: point.y - frame.height))
        clampOnScreen()
    }

    /// Keeps the whole panel inside the screen it is on, preferring to keep the
    /// top edge where it is and giving up height room at the bottom.
    func clampOnScreen() {
        guard let screen = screen(containing: topLeft) else { return }
        let visible = screen.visibleFrame
        var origin = frame.origin

        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        // Prefer showing the top: a translation popup is read downward, so a
        // clipped bottom costs less than a clipped heading.
        if origin.y + frame.height > visible.maxY - 8 {
            origin.y = visible.maxY - 8 - frame.height
        }
        if origin.y < visible.minY + 8 {
            origin.y = visible.minY + 8
        }
        setFrameOrigin(origin)
    }

    /// An anchor counts as reachable only if it sits on a screen that is
    /// actually attached — displays come and go, and a window restored onto a
    /// monitor that is gone is invisible with no way to get it back.
    private func isReachable(_ anchor: CGPoint) -> Bool {
        screen(containing: anchor) != nil
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.insetBy(dx: -4, dy: -4).contains(point) }
            ?? NSScreen.main
    }

    /// Places the panel under the pointer, nudged fully on-screen.
    func positionNearPointer() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main else { return }

        let size = frame.size
        let visible = screen.visibleFrame
        var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 18)

        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        if origin.y < visible.minY + 12 {
            origin.y = mouse.y + 18                    // flip above the pointer
        }
        origin.y = min(origin.y, visible.maxY - size.height - 12)

        setFrameOrigin(origin)
    }
}

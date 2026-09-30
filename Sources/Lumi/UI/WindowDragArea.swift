import AppKit
import SwiftUI

/// Marks a region that drags the window, the way a title bar does.
///
/// Two AppKit facts shape this design:
///
/// 1. `NSHostingView` consumes `mouseDown` and turns it into SwiftUI gestures.
///    A plain `NSView` embedded via `NSViewRepresentable` gets hit-tested but
///    never receives the click, so it cannot start a drag by itself.
/// 2. `WindowDragGesture` does get the event, but it rides SwiftUI's render
///    loop and visibly trails the pointer.
///
/// So the click is intercepted *before* the window dispatches it, with a local
/// event monitor, and handed to `NSWindow.performDrag(with:)` — AppKit's own
/// modal drag loop, the one the title bar uses. Each `WindowDragArea` simply
/// registers its rectangle; the monitor consults those rectangles and leaves
/// every other click alone, so buttons and text selection still work.
struct WindowDragArea: View {
    var body: some View {
        DragZoneRepresentable()
            // An NSView has no intrinsic size; without this it can be laid out
            // at zero and register an empty rectangle.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DragZoneRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragZoneView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        MainActor.assumeIsolated { WindowDragZones.unregister(nsView) }
    }
}

private final class DragZoneView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated {
            if window == nil { WindowDragZones.unregister(self) }
            else { WindowDragZones.register(self) }
        }
    }
}

/// The live set of draggable rectangles, kept as weak references so a zone
/// disappears with the view that declared it.
@MainActor
enum WindowDragZones {
    private struct Box { weak var view: NSView? }
    private static var boxes: [Box] = []

    static func register(_ view: NSView) {
        boxes.removeAll { $0.view == nil || $0.view === view }
        boxes.append(Box(view: view))
    }

    static func unregister(_ view: NSView) {
        boxes.removeAll { $0.view == nil || $0.view === view }
    }

    /// Every live zone rectangle in window coordinates. Only used to verify
    /// coverage from a script — the drag areas are invisible, so the alternative
    /// is guessing at where they ended up.
    static func rects(in window: NSWindow) -> [NSRect] {
        boxes.compactMap { box in
            guard let view = box.view, view.window === window, !view.isHidden else { return nil }
            return view.convert(view.bounds, to: nil)
        }
    }

    /// `point` is in window coordinates, as `NSEvent.locationInWindow` gives it.
    static func hitsZone(_ point: NSPoint, in window: NSWindow) -> Bool {
        boxes.contains { box in
            guard let view = box.view, view.window === window, !view.isHidden else { return false }
            return view.convert(view.bounds, to: nil).contains(point)
        }
    }
}

/// Intercepts left mouse-downs before `NSHostingView` can swallow them.
@MainActor
enum WindowDragMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            // AppKit delivers this on the main thread, but NSEvent is not
            // Sendable, so the crossing into the isolated region is spelled out
            // and only a Bool comes back.
            let transfer = Transfer(event)
            let consumed = MainActor.assumeIsolated { beginDragIfInZone(transfer.value) }
            return consumed ? nil : event
        }
    }

    private static func beginDragIfInZone(_ event: NSEvent) -> Bool {
        guard let panel = event.window as? GlassPanel,
              WindowDragZones.hitsZone(event.locationInWindow, in: panel)
        else { return false }

        // performDrag runs its own event loop and returns on mouse-up, so the
        // flag brackets exactly the drag.
        panel.isUserDragging = true
        panel.performDrag(with: event)
        panel.isUserDragging = false
        return true
    }

    private struct Transfer<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}

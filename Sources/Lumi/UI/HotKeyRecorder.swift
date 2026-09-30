import AppKit
import SwiftUI

/// A button that captures the next key combination the user presses.
///
/// Recording goes through a local event monitor rather than a first-responder
/// `NSView`: the monitor sees the event before `NSHostingView` routes it, which
/// is the same reason the window drag had to be intercepted there. It also lets
/// us swallow the keystroke so recording ⌘W doesn't close anything.
struct HotKeyRecorder: View {
    let action: HotKeyAction
    @Stored private var settings = AppSettings.shared
    @Stored private var isRecording = false
    @Stored private var monitor: Any?
    @Stored private var warning: String?

    var body: some View {
        LabeledContent(action.title) {
            HStack(spacing: 6) {
                if let warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button(isRecording ? "按下新快捷键…" : settings.hotKey(for: action).displayString) {
                    isRecording ? stop() : start()
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : nil)
                .monospaced()

                Button {
                    settings.setHotKey(action.defaultCombo, for: action)
                    HotKeyCenter.shared.reloadBindings()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("恢复默认")
                .disabled(settings.hotKey(for: action) == action.defaultCombo)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        stop()
        isRecording = true
        warning = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let transfer = Transfer(event)
            MainActor.assumeIsolated { capture(transfer.value) }
            return nil   // swallow: never let the combo being recorded also fire
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == UInt16(53) {   // Escape cancels
            stop()
            return
        }
        let modifiers = HotKeyCombo.carbonModifiers(from: event.modifierFlags)
        let combo = HotKeyCombo(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            label: HotKeyCombo.label(for: event)
        )
        guard combo.hasModifier else {
            warning = "至少要带一个修饰键"
            return   // stay in recording mode so the user can try again
        }
        if let clash = HotKeyAction.allCases.first(where: {
            $0 != action && settings.hotKey(for: $0) == combo
        }) {
            warning = "与「\(clash.title)」冲突"
            return
        }

        warning = nil
        settings.setHotKey(combo, for: action)
        HotKeyCenter.shared.reloadBindings()
        stop()
    }

    private struct Transfer<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}

import AppKit
import ApplicationServices

/// Reads the text the user has selected in whatever app is frontmost.
///
/// The Accessibility API is synchronous and blocks the calling thread until the
/// target process answers — an unresponsive app (Electron editors and remote
/// desktops are the usual offenders) will otherwise take the whole UI down with
/// it. Every AX call here therefore runs on a detached thread, carries an
/// explicit `AXUIElementSetMessagingTimeout`, and is abandoned on deadline.
enum TextGrabber {
    static func selectedText() async -> String? {
        if let text = await accessibilitySelection(), !text.isEmpty {
            Log.grab.info("selection via AX")
            return text
        }
        let text = await pasteboardSelection()
        Log.grab.info("selection via ⌘C: \(text == nil ? "nothing" : "ok", privacy: .public)")
        return text
    }

    // MARK: Fast path — ask the focused element directly.

    private static func accessibilitySelection() async -> String? {
        let result: String?? = await withBlockingTimeout(0.7) {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.25)

            var focusedValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                    system, kAXFocusedUIElementAttribute as CFString, &focusedValue
                  ) == .success,
                  let focusedValue else { return nil }

            let element = focusedValue as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.25)

            // Which process are we actually asking? A selection grab that
            // lands on Lumi's own input field looks exactly like a source app
            // with nothing selected, and the two need telling apart.
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
            let role = roleValue as? String ?? "?"
            Log.grab.info("AX focus pid=\(pid, privacy: .public) role=\(role, privacy: .public) (self=\(ProcessInfo.processInfo.processIdentifier, privacy: .public))")

            var selected: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                    element, kAXSelectedTextAttribute as CFString, &selected
                  ) == .success else { return nil }
            return selected as? String
        }
        return result ?? nil
    }

    // MARK: Fallback — synthesise ⌘C, then put the pasteboard back.

    private static func pasteboardSelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let saved = pasteboard.string(forType: .string)

        postCommandC()

        // Poll rather than sleep a fixed interval: fast apps answer in ~20ms,
        // and we give up well before the user notices.
        var copied: String?
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(20))
            if pasteboard.changeCount != before {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        if let saved, copied != nil {
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
        return copied?.isEmpty == false ? copied : nil
    }

    private static func postCommandC() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let cKey: CGKeyCode = 0x08   // kVK_ANSI_C
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

import AppKit
import Carbon.HIToolbox

struct HotKeyCombo: Codable, Sendable, Hashable, Identifiable {
    var keyCode: UInt32
    var modifiers: UInt32     // Carbon: cmdKey / optionKey / controlKey / shiftKey
    /// The key's printed name, captured from the keyboard at record time.
    /// Deriving it from the key code would mean shipping a layout table and
    /// getting it wrong on non-US keyboards.
    var label: String

    var id: String { "\(modifiers)-\(keyCode)" }

    static let translateSelection = HotKeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey), label: "D")
    static let showInput         = HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey), label: "A")
    static let captureScreen     = HotKeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey), label: "S")
    static let showWorkbench     = HotKeyCombo(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(optionKey), label: "W")

    var displayString: String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { parts += "⌘" }
        return parts + label
    }

    /// A bare key would swallow normal typing system-wide.
    var hasModifier: Bool { modifiers != 0 }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option)  { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift)   { result |= UInt32(shiftKey) }
        return result
    }

    /// Printable keys come back from the event; the rest get a symbol.
    static func label(for event: NSEvent) -> String {
        if let named = namedKeys[Int(event.keyCode)] { return named }
        let characters = event.charactersIgnoringModifiers ?? ""
        return characters.uppercased().isEmpty ? "?" : characters.uppercased()
    }

    private static var namedKeys: [Int: String] {
        [
            kVK_Space: tDetached("空格"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12",
        ]
    }
}

/// Which shortcut a recorder is editing.
enum HotKeyAction: String, CaseIterable, Identifiable, Sendable {
    case translateSelection, showInput, captureScreen, showWorkbench
    var id: String { rawValue }

    var title: String {
        switch self {
        case .translateSelection: tDetached("翻译选中文本")
        case .showInput:          tDetached("打开输入框")
        case .captureScreen:      tDetached("截图翻译")
        case .showWorkbench:      tDetached("打开工作台")
        }
    }

    var defaultCombo: HotKeyCombo {
        switch self {
        case .translateSelection: .translateSelection
        case .showInput:          .showInput
        case .captureScreen:      .captureScreen
        case .showWorkbench:      .showWorkbench
        }
    }
}

/// Thin wrapper over Carbon's hot-key registration — still the only API that
/// gives a background app a true global shortcut without an event tap (event
/// taps are what make these apps feel laggy system-wide).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    @discardableResult
    func register(_ combo: HotKeyCombo, action: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C554D49) /* 'LUMI' */, id: id)
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Log.hotKey.error("register \(combo.displayString, privacy: .public) failed: OSStatus \(status)")
            return nil
        }
        Log.hotKey.info("registered \(combo.displayString, privacy: .public) as #\(id)")

        refs[id] = ref
        actions[id] = action
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    func unregisterAll() {
        for id in refs.keys { unregister(id) }
    }

    /// Drops every binding and re-registers from the current settings. Called
    /// at launch and after any shortcut is re-recorded.
    func reloadBindings() {
        unregisterAll()
        let settings = AppSettings.shared
        for action in HotKeyAction.allCases {
            let combo = settings.hotKey(for: action)
            guard combo.hasModifier else { continue }
            register(combo) { [action] in
                let controller = PanelController.shared
                switch action {
                case .translateSelection: controller.translateSelection()
                case .showInput:          controller.showInput()
                case .captureScreen:      controller.translateScreenRegion()
                case .showWorkbench:      WorkbenchController.shared.toggle()
                }
            }
        }
    }

    fileprivate func fire(_ id: UInt32) {
        Log.hotKey.info("fired #\(id)\(self.actions[id] == nil ? " (no action bound)" : "", privacy: .public)")
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(GetEventDispatcherTarget(), lumiHotKeyHandler, 1, &spec, nil, nil)
        if status != noErr { Log.hotKey.error("InstallEventHandler failed: OSStatus \(status)") }
    }
}

/// Carbon requires a bare C function pointer, so this lives at file scope and
/// hops straight back to the main actor.
private func lumiHotKeyHandler(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
    }
    return noErr
}

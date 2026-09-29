import AppKit
import ApplicationServices
import CoreGraphics
import Observation

enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccessibility() -> Bool {
        // The SDK exposes this key as a mutable global, which Swift 6 rejects as
        // non-Sendable. The literal is the documented, stable value.
        let promptKey = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Preflight reports the current state without showing a prompt, so the
    /// settings window can display status without nagging.
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}


/// Polls the two TCC states while a view is on screen.
///
/// Granting happens in System Settings, in another process — there is no
/// notification to observe, and a status read once at render time would sit
/// there stale showing a red cross after the user has already said yes.
@MainActor @Observable
final class PermissionStatus {
    var accessibility = Permissions.hasAccessibility
    var screenRecording = Permissions.hasScreenRecording

    func refresh() {
        accessibility = Permissions.hasAccessibility
        screenRecording = Permissions.hasScreenRecording
    }

    /// Drives `refresh` until the surrounding view goes away.
    func poll() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

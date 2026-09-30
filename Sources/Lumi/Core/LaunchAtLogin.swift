import Foundation
import ServiceManagement

/// Register/unregister Lumi as a login item via `SMAppService`.
///
/// The registration is keyed to the app bundle's *path*, so a build sitting in
/// a developer folder registers that path. Moving the app afterwards leaves a
/// stale entry — hence `isSupported`, which keeps the toggle out of the way
/// until the app lives somewhere stable.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Login items launched from a throwaway build directory are a footgun:
    /// the path changes and macOS silently keeps pointing at the old one.
    static var isSupported: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications")
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Result<Void, any Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

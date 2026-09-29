import AppKit

enum AppearanceMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light:  "浅色"
        case .dark:   "深色"
        }
    }

    /// `nil` hands the choice back to the system, which is what "follow" means.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        }
    }

    /// Touches `NSApp`, so it is main-actor work by definition.
    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }
}

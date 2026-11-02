import AppKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` follows the system; web content follows too, via the web view's effective appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum AppSettings {
    static let autosaveOnFocusLossKey = "autosaveOnFocusLoss"
    static let appearanceKey = "appearance"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autosaveOnFocusLossKey: true,
            appearanceKey: AppearanceMode.system.rawValue,
        ])
    }

    static var autosaveOnFocusLoss: Bool {
        UserDefaults.standard.bool(forKey: autosaveOnFocusLossKey)
    }

    static var appearance: AppearanceMode {
        UserDefaults.standard.string(forKey: appearanceKey).flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    static func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }
}

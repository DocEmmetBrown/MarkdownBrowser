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

    /// `nil` follows the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum PageMargins: String, CaseIterable, Identifiable {
    case none
    case narrow
    case normal
    case wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .narrow: "Narrow"
        case .normal: "Normal"
        case .wide: "Wide"
        }
    }

    /// Space beside rendered Markdown, in points; "None" keeps a small gutter so text doesn't touch the edge.
    var points: Int {
        switch self {
        case .none: 12
        case .narrow: 24
        case .normal: 45
        case .wide: 96
        }
    }
}

struct PageLayout: Equatable {
    var margins: PageMargins
    /// Caps lines at GitHub's 980-point page width.
    var limitsWidth: Bool
}

enum AppSettings {
    static let autosaveOnFocusLossKey = "autosaveOnFocusLoss"
    static let appearanceKey = "appearance"
    static let commandLineToolOfferedKey = "commandLineToolOffered"
    static let wrapLongLinesKey = "wrapLongLines"
    static let pageMarginsKey = "pageMargins"
    static let limitPageWidthKey = "limitPageWidth"
    static let loadRemoteMediaKey = "loadRemoteMedia"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autosaveOnFocusLossKey: true,
            appearanceKey: AppearanceMode.system.rawValue,
            wrapLongLinesKey: true,
            pageMarginsKey: PageMargins.none.rawValue,
            limitPageWidthKey: false,
            loadRemoteMediaKey: false,
        ])
    }

    static var pageLayout: PageLayout {
        let defaults = UserDefaults.standard
        return PageLayout(
            margins: defaults.string(forKey: pageMarginsKey).flatMap(PageMargins.init(rawValue:)) ?? .none,
            limitsWidth: defaults.bool(forKey: limitPageWidthKey))
    }

    static var wrapLongLines: Bool {
        UserDefaults.standard.bool(forKey: wrapLongLinesKey)
    }

    static var autosaveOnFocusLoss: Bool {
        UserDefaults.standard.bool(forKey: autosaveOnFocusLossKey)
    }

    /// Whether previews fetch images and video over the network. Off by default: the request tells the host
    /// who opened the document, and when.
    static var loadRemoteMedia: Bool {
        UserDefaults.standard.bool(forKey: loadRemoteMediaKey)
    }

    static var appearance: AppearanceMode {
        UserDefaults.standard.string(forKey: appearanceKey).flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    static func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }
}

import Foundation

public enum LauncherShortcut: String, CaseIterable, Codable, Sendable {
    case optionSpace
    case optionShiftSpace
    case controlShiftSpace

    public var title: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .optionShiftSpace: "⌥ ⇧ Space"
        case .controlShiftSpace: "⌃ ⇧ Space"
        }
    }
}

/// Screen corner that toggles the launcher. `.off` disables monitoring.
/// Distinct from macOS Mission Control hot corners (System Settings → Desktop
/// & Dock → Hot Corners): if both use the same corner, both may fire — pick an
/// unused system corner or set that system corner to “-”.
public enum LauncherHotCorner: String, CaseIterable, Codable, Sendable {
    case off
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var title: String {
        switch self {
        case .off: "关闭"
        case .topLeft: "左上角"
        case .topRight: "右上角"
        case .bottomLeft: "左下角"
        case .bottomRight: "右下角"
        }
    }

    public var isEnabled: Bool { self != .off }
}

public struct LauncherPreferences: Equatable, Sendable {
    public var shortcut: LauncherShortcut
    public var showsStatusItem: Bool
    public var hidesAfterLaunch: Bool
    public var reducesMotion: Bool
    public var hotCorner: LauncherHotCorner

    public init(
        shortcut: LauncherShortcut = .optionSpace,
        showsStatusItem: Bool = true,
        hidesAfterLaunch: Bool = true,
        reducesMotion: Bool = false,
        hotCorner: LauncherHotCorner = .off
    ) {
        self.shortcut = shortcut
        self.showsStatusItem = showsStatusItem
        self.hidesAfterLaunch = hidesAfterLaunch
        self.reducesMotion = reducesMotion
        self.hotCorner = hotCorner
    }
}

public actor LauncherPreferencesStore {
    private let defaults: UserDefaults
    private let prefix = "LaunchIcon.Preferences."

    public init(suiteName: String? = nil) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func load() -> LauncherPreferences {
        LauncherPreferences(
            shortcut: defaults.string(forKey: prefix + "shortcut")
                .flatMap(LauncherShortcut.init(rawValue:)) ?? .optionSpace,
            showsStatusItem: defaults.object(forKey: prefix + "showsStatusItem") as? Bool ?? true,
            hidesAfterLaunch: defaults.object(forKey: prefix + "hidesAfterLaunch") as? Bool ?? true,
            reducesMotion: defaults.bool(forKey: prefix + "reducesMotion"),
            hotCorner: defaults.string(forKey: prefix + "hotCorner")
                .flatMap(LauncherHotCorner.init(rawValue:)) ?? .off
        )
    }

    public func save(_ preferences: LauncherPreferences) {
        defaults.set(preferences.shortcut.rawValue, forKey: prefix + "shortcut")
        defaults.set(preferences.showsStatusItem, forKey: prefix + "showsStatusItem")
        defaults.set(preferences.hidesAfterLaunch, forKey: prefix + "hidesAfterLaunch")
        defaults.set(preferences.reducesMotion, forKey: prefix + "reducesMotion")
        defaults.set(preferences.hotCorner.rawValue, forKey: prefix + "hotCorner")
    }
}

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

public struct LauncherPreferences: Equatable, Sendable {
    public var shortcut: LauncherShortcut
    public var showsStatusItem: Bool
    public var hidesAfterLaunch: Bool
    public var reducesMotion: Bool

    public init(
        shortcut: LauncherShortcut = .optionSpace,
        showsStatusItem: Bool = true,
        hidesAfterLaunch: Bool = true,
        reducesMotion: Bool = false
    ) {
        self.shortcut = shortcut
        self.showsStatusItem = showsStatusItem
        self.hidesAfterLaunch = hidesAfterLaunch
        self.reducesMotion = reducesMotion
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
            reducesMotion: defaults.bool(forKey: prefix + "reducesMotion")
        )
    }

    public func save(_ preferences: LauncherPreferences) {
        defaults.set(preferences.shortcut.rawValue, forKey: prefix + "shortcut")
        defaults.set(preferences.showsStatusItem, forKey: prefix + "showsStatusItem")
        defaults.set(preferences.hidesAfterLaunch, forKey: prefix + "hidesAfterLaunch")
        defaults.set(preferences.reducesMotion, forKey: prefix + "reducesMotion")
    }
}

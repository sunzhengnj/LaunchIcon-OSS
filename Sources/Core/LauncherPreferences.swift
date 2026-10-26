import Foundation

public enum LauncherShortcut: String, CaseIterable, Codable, Sendable {
    case optionSpace
    case optionShiftSpace
    case controlShiftSpace
    /// Optional summon key. Stored by raw value, so it stays last and does not
    /// move the three Space chords. Default remains `.optionSpace`.
    case f4

    public var title: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .optionShiftSpace: "⌥ ⇧ Space"
        case .controlShiftSpace: "⌃ ⇧ Space"
        case .f4: "F4"
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

/// Detects a clash with the macOS hot corner on the same corner (LaunchOS
/// "warns about conflicts during setup"). Reads only the Dock's
/// `wvous-*-corner` values handed in by the caller, so it stays pure.
public extension LauncherHotCorner {
    /// `com.apple.dock` key holding the macOS action for this corner.
    var systemDockDefaultsKey: String? {
        switch self {
        case .off: nil
        case .topLeft: "wvous-tl-corner"
        case .topRight: "wvous-tr-corner"
        case .bottomLeft: "wvous-bl-corner"
        case .bottomRight: "wvous-br-corner"
        }
    }

    /// Localization key of a macOS hot-corner action code; nil for "-" (0/1).
    static func systemHotCornerActionTitleKey(_ code: Int) -> String? {
        switch code {
        case ..<2: nil
        case 2: "调度中心"
        case 3: "应用程序窗口"
        case 4: "桌面"
        case 5: "启动屏幕保护程序"
        case 6: "停用屏幕保护程序"
        case 7: "仪表盘"
        case 10: "让显示器进入睡眠"
        case 11: "启动台"
        case 12: "通知中心"
        case 13: "锁定屏幕"
        case 14: "快速备忘录"
        default: "其他系统操作"
        }
    }

    /// Action title key when macOS already uses this corner, else nil.
    /// `dockValue` returns the raw Dock preference (Int / NSNumber / String).
    func systemConflictActionTitleKey(dockValue: (String) -> Any?) -> String? {
        guard let key = systemDockDefaultsKey, let raw = dockValue(key) else { return nil }
        let code: Int?
        switch raw {
        case let value as Int: code = value
        case let value as NSNumber: code = value.intValue
        case let value as String: code = Int(value.trimmingCharacters(in: .whitespaces))
        default: code = nil
        }
        guard let code else { return nil }
        return Self.systemHotCornerActionTitleKey(code)
    }

    /// Format: corner title, then system action title (both localized).
    static let systemConflictMessageFormatKey =
        "系统触发角已把%@用于「%@」，两者会同时触发。可换一个角，或在系统设置 → 桌面与程序坞 → 触发角里把该角设为「-」。"

    // HOT-CORNER-CONFLICT-HELP-01
    public static func conflictMessage(
        cornerTitle: String,
        actionTitle: String,
        localize: (String) -> String = { $0 }
    ) -> String {
        String(format: localize(systemConflictMessageFormatKey), cornerTitle, actionTitle)
    }

    /// Localized warning when Dock already assigns an action to this corner.
    public func conflictMessage(
        dockValue: (String) -> Any?,
        localize: (String) -> String = { $0 }
    ) -> String? {
        guard isEnabled, let actionKey = systemConflictActionTitleKey(dockValue: dockValue) else {
            return nil
        }
        return Self.conflictMessage(
            cornerTitle: localize(title),
            actionTitle: localize(actionKey),
            localize: localize
        )
    }
}

// MARK: - Hot-corner conflict help (HOT-CORNER-CONFLICT-HELP-01)

/// Settings chrome explaining LaunchIcon vs macOS hot-corner clashes.
public enum HotCornerConflictCopy {
    public static let accessibilityHelpKey =
        "将指针移入所选屏幕角可显示或隐藏启动器。若与系统设置「桌面与程序坞 → 触发角」选同一角，系统动作会一并触发；请选未占用的角，或在系统里将该角设为「-」。不需要辅助功能权限。"
    public static let conflictToolTipKey = "与系统触发角冲突时请换角或关闭系统该角"

    public static func accessibilityHelp(localize: (String) -> String = { $0 }) -> String {
        localize(accessibilityHelpKey)
    }

    public static func conflictToolTip(localize: (String) -> String = { $0 }) -> String {
        localize(conflictToolTipKey)
    }
}

// MARK: - Settings display / feedback copy (SETTINGS-DISPLAY-FEEDBACK-01)

/// Multi-display target label + help shown in Settings.
public enum DisplayTargetCopy {
    public static let labelKey = "显示于"
    public static let accessibilityHelpKey =
        "连接多台显示器时，选择启动器出现在哪台显示器上；下次打开启动器时生效"

    public static func label(localize: (String) -> String = { $0 }) -> String {
        localize(labelKey)
    }

    public static func accessibilityHelp(localize: (String) -> String = { $0 }) -> String {
        localize(accessibilityHelpKey)
    }
}

/// Short Settings status-line feedback unrelated to layout I/O outcomes.
public enum SettingsFeedbackCopy {
    public static let appliedKey = "设置已应用"
    public static let rescanningKey = "正在重新扫描"

    public static func applied(localize: (String) -> String = { $0 }) -> String {
        localize(appliedKey)
    }

    public static func rescanning(localize: (String) -> String = { $0 }) -> String {
        localize(rescanningKey)
    }
}

// MARK: - App directory Settings chrome (APP-DIRECTORY-FEEDBACK-01)

/// Labels and toasts for additional Applications folders in Settings.
public enum AppDirectoryCopy {
    public static let menuTitleKey = "应用目录…"
    public static let menuTitleCountedFormatKey = "应用目录（%ld）…"
    public static let addFolderTitleKey = "添加文件夹…"
    public static let removeHeaderKey = "选择以移除："
    public static let panelPromptKey = "添加"
    public static let accessibilityLabelKey = "应用目录"
    public static let accessibilityHelpKey =
        "在默认的 Applications 文件夹之外，再扫描你添加的文件夹（例如外置磁盘）"
    public static let alreadyCoveredKey = "该文件夹已在扫描范围内，或不能作为应用目录"
    public static let limitReachedKey = "应用目录最多添加 12 个，请先移除一个再添加"
    public static let addedFormatKey = "已添加应用目录：%@"
    public static let removedFormatKey = "已移除应用目录：%@"

    public static func menuTitle(count: Int, localize: (String) -> String = { $0 }) -> String {
        if count == 0 { return localize(menuTitleKey) }
        return String(format: localize(menuTitleCountedFormatKey), count)
    }

    public static func addFolderTitle(localize: (String) -> String = { $0 }) -> String {
        localize(addFolderTitleKey)
    }

    public static func removeHeader(localize: (String) -> String = { $0 }) -> String {
        localize(removeHeaderKey)
    }

    public static func panelPrompt(localize: (String) -> String = { $0 }) -> String {
        localize(panelPromptKey)
    }

    public static func accessibilityLabel(localize: (String) -> String = { $0 }) -> String {
        localize(accessibilityLabelKey)
    }

    public static func accessibilityHelp(localize: (String) -> String = { $0 }) -> String {
        localize(accessibilityHelpKey)
    }

    public static func alreadyCovered(localize: (String) -> String = { $0 }) -> String {
        localize(alreadyCoveredKey)
    }

    public static func limitReached(localize: (String) -> String = { $0 }) -> String {
        localize(limitReachedKey)
    }

    public static func addedMessage(abbreviatedPath: String, localize: (String) -> String = { $0 }) -> String {
        String(format: localize(addedFormatKey), abbreviatedPath)
    }

    public static func removedMessage(abbreviatedPath: String, localize: (String) -> String = { $0 }) -> String {
        String(format: localize(removedFormatKey), abbreviatedPath)
    }
}

// MARK: - Settings section chrome (SETTINGS-SECTION-CHROME-01)

/// Window title, page header, section titles, and version line in Settings.
public enum SettingsSectionChromeCopy {
    public static let windowTitleKey = "LaunchIcon 设置"
    public static let pageTitleKey = "通用"
    public static let appearanceSectionKey = "外观与呼出"
    public static let behaviorSectionKey = "行为"
    public static let appsSectionKey = "应用管理"
    public static let maintenanceSectionKey = "维护"
    public static let unknownVersionKey = "未知"
    public static let sourceFormatKey = "源码 %@"
    public static let developmentBuildKey = "开发构建"
    public static let versionFormatKey = "版本 %@ (%@) · %@"
    public static let fullCommitFormatKey = "完整源码提交：%@"

    // SETTINGS-FORM-DENSITY-01: compact form-row labels (popup / scan cluster)
    public static let rearrangeRowTitleKey = "重新排列"
    public static let rearrangeMenuTitleKey = "选取排序…"
    public static let layoutRowTitleKey = "布局"
    public static let layoutMenuTitleKey = "导出与导入…"
    public static let scanRowTitleKey = "扫描与清理"

    public static func windowTitle(localize: (String) -> String = { $0 }) -> String {
        localize(windowTitleKey)
    }

    public static func pageTitle(localize: (String) -> String = { $0 }) -> String {
        localize(pageTitleKey)
    }

    public static func appearanceSectionTitle(localize: (String) -> String = { $0 }) -> String {
        localize(appearanceSectionKey)
    }

    public static func behaviorSectionTitle(localize: (String) -> String = { $0 }) -> String {
        localize(behaviorSectionKey)
    }

    public static func appsSectionTitle(localize: (String) -> String = { $0 }) -> String {
        localize(appsSectionKey)
    }

    public static func maintenanceSectionTitle(localize: (String) -> String = { $0 }) -> String {
        localize(maintenanceSectionKey)
    }


    public static func rearrangeRowTitle(localize: (String) -> String = { $0 }) -> String {
        localize(rearrangeRowTitleKey)
    }

    public static func rearrangeMenuTitle(localize: (String) -> String = { $0 }) -> String {
        localize(rearrangeMenuTitleKey)
    }

    public static func layoutRowTitle(localize: (String) -> String = { $0 }) -> String {
        localize(layoutRowTitleKey)
    }

    public static func layoutMenuTitle(localize: (String) -> String = { $0 }) -> String {
        localize(layoutMenuTitleKey)
    }

    public static func scanRowTitle(localize: (String) -> String = { $0 }) -> String {
        localize(scanRowTitleKey)
    }

    public static func unknownVersion(localize: (String) -> String = { $0 }) -> String {
        localize(unknownVersionKey)
    }

    public static func sourceLabel(shortCommit: String, localize: (String) -> String = { $0 }) -> String {
        String(format: localize(sourceFormatKey), shortCommit)
    }

    public static func developmentBuild(localize: (String) -> String = { $0 }) -> String {
        localize(developmentBuildKey)
    }

    public static func versionLine(
        version: String,
        build: String,
        source: String,
        localize: (String) -> String = { $0 }
    ) -> String {
        String(format: localize(versionFormatKey), version, build, source)
    }

    public static func fullCommitHelp(commit: String, localize: (String) -> String = { $0 }) -> String {
        String(format: localize(fullCommitFormatKey), commit)
    }
}


/// Which display the launcher appears on (LaunchOS multi-display parity).
/// `.active` keeps the historical `NSScreen.main` choice.
public enum LauncherDisplayTarget: String, CaseIterable, Codable, Sendable {
    /// Display with the key window / menu focus (`NSScreen.main`).
    case active
    /// Display under the mouse pointer.
    case pointer
    /// Display with the menu bar (`NSScreen.screens[0]`).
    case primary

    public var title: String {
        switch self {
        case .active: "当前活跃的显示器"
        case .pointer: "鼠标所在的显示器"
        case .primary: "主显示器"
        }
    }

    /// Index into the screen list, or nil when there are no screens.
    /// `screenFrames[0]` is the primary display; `activeIndex` is the
    /// `NSScreen.main` index. A pointer on no display (gap between
    /// screens) falls back to the active one.
    public static func screenIndex(
        for target: LauncherDisplayTarget,
        screenFrames: [CGRect],
        activeIndex: Int?,
        pointer: CGPoint
    ) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        let active = activeIndex.flatMap { screenFrames.indices.contains($0) ? $0 : nil } ?? 0
        switch target {
        case .active:
            return active
        case .primary:
            return 0
        case .pointer:
            return screenFrames.firstIndex { frame in
                pointer.x >= frame.minX && pointer.x < frame.maxX
                    && pointer.y >= frame.minY && pointer.y < frame.maxY
            } ?? screenFrames.firstIndex { frame in
                // Top / right edge pixel (maxX / maxY are exclusive above).
                pointer.x >= frame.minX && pointer.x <= frame.maxX
                    && pointer.y >= frame.minY && pointer.y <= frame.maxY
            } ?? active
        }
    }
}

/// BACKGROUND-DIM-01: how much the launcher darkens the blurred wallpaper
/// (LaunchOS-style background dimming). `.standard` is the historical 0.24.
public enum LauncherBackgroundDim: String, CaseIterable, Codable, Sendable {
    case light
    case standard
    case dark

    public var title: String {
        switch self {
        case .light: "浅"
        case .standard: "标准"
        case .dark: "深"
        }
    }

    /// Alpha of the black contrast overlay above the blurred wallpaper.
    public var overlayAlpha: Double {
        switch self {
        case .light: 0.12
        case .standard: 0.24
        case .dark: 0.42
        }
    }
}

/// Settings label + help for the background dim popup (BACKGROUND-DIM-01).
public enum BackgroundDimCopy {
    public static let labelKey = "背景暗度"
    public static let accessibilityHelpKey =
        "调整启动器背后壁纸的变暗程度；越深图标名称越清楚，立即生效"

    public static func label(localize: (String) -> String = { $0 }) -> String {
        localize(labelKey)
    }

    public static func accessibilityHelp(localize: (String) -> String = { $0 }) -> String {
        localize(accessibilityHelpKey)
    }

    /// BACKGROUND-BLUR-01: row title once the blur toggle shares the row.
    public static let rowTitleKey = "背景"
    public static let blurTitleKey = "模糊"
    public static let blurAccessibilityLabelKey = "模糊壁纸"
    public static let blurAccessibilityHelpKey =
        "关闭后直接显示清晰的桌面壁纸，只保留变暗；立即生效"

    public static func rowTitle(localize: (String) -> String = { $0 }) -> String {
        localize(rowTitleKey)
    }

    public static func blurTitle(localize: (String) -> String = { $0 }) -> String {
        localize(blurTitleKey)
    }

    public static func blurAccessibilityLabel(localize: (String) -> String = { $0 }) -> String {
        localize(blurAccessibilityLabelKey)
    }

    public static func blurAccessibilityHelp(localize: (String) -> String = { $0 }) -> String {
        localize(blurAccessibilityHelpKey)
    }
}

/// REOPEN-PAGE-BEHAVIOR-01: where the grid opens after dismiss (LaunchOS parity).
/// Default `.rememberLast` keeps today's in-session page memory. Delay cases
/// reset to page 0 only when enough time has passed since the last dismiss.
public enum LauncherReopenPageBehavior: String, CaseIterable, Codable, Sendable {
    case rememberLast
    case alwaysHome
    case homeAfter30Seconds
    case homeAfter1Minute
    case homeAfter5Minutes

    public var title: String {
        switch self {
        case .rememberLast: "记住上次位置"
        case .alwaysHome: "始终回到首页"
        case .homeAfter30Seconds: "30 秒后回首页"
        case .homeAfter1Minute: "1 分钟后回首页"
        case .homeAfter5Minutes: "5 分钟后回首页"
        }
    }

    /// Seconds after dismiss before the next appear resets to page 0.
    /// `nil` = never auto-reset; `0` = always reset on appear.
    public var homeResetDelaySeconds: TimeInterval? {
        switch self {
        case .rememberLast: return nil
        case .alwaysHome: return 0
        case .homeAfter30Seconds: return 30
        case .homeAfter1Minute: return 60
        case .homeAfter5Minutes: return 300
        }
    }
}

/// Settings label + help for the reopen-page popup (REOPEN-PAGE-BEHAVIOR-01).
public enum ReopenPageCopy {
    public static let labelKey = "打开时页面"
    public static let accessibilityHelpKey =
        "再次打开启动器时停留在上次所在页，或回到第一页；不影响翻页动画"

    public static func label(localize: (String) -> String = { $0 }) -> String {
        localize(labelKey)
    }

    public static func accessibilityHelp(localize: (String) -> String = { $0 }) -> String {
        localize(accessibilityHelpKey)
    }

    /// Pure policy: reset to page 0 on a fresh appear (not settings handoff).
    public static func shouldResetToHomePageOnAppear(
        behavior: LauncherReopenPageBehavior,
        secondsSinceLastDismiss: TimeInterval?,
        isSettingsHandoffRestore: Bool
    ) -> Bool {
        if isSettingsHandoffRestore { return false }
        guard let delay = behavior.homeResetDelaySeconds else { return false }
        if delay == 0 { return true }
        guard let elapsed = secondsSinceLastDismiss else { return false }
        return elapsed >= delay
    }
}

/// PINCH-TO-DISMISS-01: LaunchOS-parity pinch-in to hide while the launcher is open.
/// Show-via-pinch while hidden needs a global monitor (Accessibility); not in this slice.
/// SETTINGS-BEHAVIOR-TOGGLES-COPY-01: behavior-section checkbox chrome.
/// SETTINGS-APPEARANCE-CHROME-COPY-01: appearance-section row/toggle chrome.
public enum SettingsAppearanceChromeCopy {
    public static let shortcutLabelKey = "呼出快捷键"
    public static let hotCornerLabelKey = "呼出触发角"
    public static let statusItemTitleKey = "显示菜单栏图标"
    // STATUS-ITEM-CLICK-HELP-01 — document left / right / Option-click.
    public static let statusItemHelpKey =
        "左键切换启动器，右键打开菜单，按住 Option 再左键打开设置。关闭后仍可用快捷键呼出；从启动器顶部设置按钮或按 Command-逗号可再次打开设置"
    public static let hideNamesRowTitleKey = "隐藏名称"
    public static let hideAppNamesCheckboxTitleKey = "应用"
    public static let hideFolderNamesCheckboxTitleKey = "文件夹"
    public static let hideAppNamesLabelKey = "隐藏应用名称"
    public static let hideFolderNamesLabelKey = "隐藏文件夹名称"
    public static let hideAppNamesHelpKey =
        "只显示图标，不在应用图标下方显示名称；搜索结果仍显示名称，悬停可看全名"
    public static let hideFolderNamesHelpKey =
        "不在文件夹图标下方显示名称；打开文件夹后仍显示标题"

    public static func shortcutLabel(localize: (String) -> String = { $0 }) -> String {
        localize(shortcutLabelKey)
    }
    public static func hotCornerLabel(localize: (String) -> String = { $0 }) -> String {
        localize(hotCornerLabelKey)
    }
    public static func statusItemTitle(localize: (String) -> String = { $0 }) -> String {
        localize(statusItemTitleKey)
    }
    public static func statusItemHelp(localize: (String) -> String = { $0 }) -> String {
        localize(statusItemHelpKey)
    }
    public static func hideNamesRowTitle(localize: (String) -> String = { $0 }) -> String {
        localize(hideNamesRowTitleKey)
    }
    public static func hideAppNamesCheckboxTitle(localize: (String) -> String = { $0 }) -> String {
        localize(hideAppNamesCheckboxTitleKey)
    }
    public static func hideFolderNamesCheckboxTitle(localize: (String) -> String = { $0 }) -> String {
        localize(hideFolderNamesCheckboxTitleKey)
    }
    public static func hideAppNamesLabel(localize: (String) -> String = { $0 }) -> String {
        localize(hideAppNamesLabelKey)
    }
    public static func hideFolderNamesLabel(localize: (String) -> String = { $0 }) -> String {
        localize(hideFolderNamesLabelKey)
    }
    public static func hideAppNamesHelp(localize: (String) -> String = { $0 }) -> String {
        localize(hideAppNamesHelpKey)
    }
    public static func hideFolderNamesHelp(localize: (String) -> String = { $0 }) -> String {
        localize(hideFolderNamesHelpKey)
    }
}

public enum SettingsBehaviorTogglesCopy {
    public static let hideAfterLaunchTitleKey = "启动应用后自动收起"
    public static let hideAfterLaunchHelpKey = "打开应用后自动收起启动器"
    public static let reducesMotionTitleKey = "减少动态效果"
    public static let reducesMotionHelpKey =
        "开启后不播放合并图标飞入与文件夹弹跳，只保留短淡入；关闭可恢复完整过渡。macOS 系统的减少动态效果设置仍会优先生效"
    public static let reducesMotionToolTipKey =
        "关闭此项可显示完整合并过渡动画；系统减少动态效果开启时仍会简化动画"
    public static let loginTitleKey = "开机登录"
    public static let loginHelpKey = "登录 macOS 时自动启动 LaunchIcon"
    public static let openLoginSettingsTitleKey = "打开系统登录项设置…"
    public static let openLoginSettingsLabelKey = "打开系统登录项设置"
    public static let loginUpdatedKey = "开机登录设置已更新"
    public static let loginNeedsApprovalKey = "请在系统设置的登录项中允许 LaunchIcon。"

    public static func hideAfterLaunchTitle(localize: (String) -> String = { $0 }) -> String {
        localize(hideAfterLaunchTitleKey)
    }
    public static func hideAfterLaunchHelp(localize: (String) -> String = { $0 }) -> String {
        localize(hideAfterLaunchHelpKey)
    }
    public static func reducesMotionTitle(localize: (String) -> String = { $0 }) -> String {
        localize(reducesMotionTitleKey)
    }
    public static func reducesMotionHelp(localize: (String) -> String = { $0 }) -> String {
        localize(reducesMotionHelpKey)
    }
    public static func reducesMotionToolTip(localize: (String) -> String = { $0 }) -> String {
        localize(reducesMotionToolTipKey)
    }
    public static func loginTitle(localize: (String) -> String = { $0 }) -> String {
        localize(loginTitleKey)
    }
    public static func loginHelp(localize: (String) -> String = { $0 }) -> String {
        localize(loginHelpKey)
    }
    public static func openLoginSettingsTitle(localize: (String) -> String = { $0 }) -> String {
        localize(openLoginSettingsTitleKey)
    }
    public static func openLoginSettingsLabel(localize: (String) -> String = { $0 }) -> String {
        localize(openLoginSettingsLabelKey)
    }
    public static func loginUpdated(localize: (String) -> String = { $0 }) -> String {
        localize(loginUpdatedKey)
    }
    public static func loginNeedsApproval(localize: (String) -> String = { $0 }) -> String {
        localize(loginNeedsApprovalKey)
    }
}

public enum PinchDismissCopy {
    public static let titleKey = "双指捏合收起"
    public static let accessibilityLabelKey = "双指捏合收起"
    public static let accessibilityHelpKey =
        "启动器打开时双指捏合可收起；不影响翻页手势。关闭后捏合无效"

    public static func title(localize: (String) -> String = { $0 }) -> String {
        localize(titleKey)
    }

    public static func accessibilityLabel(localize: (String) -> String = { $0 }) -> String {
        localize(accessibilityLabelKey)
    }

    public static func accessibilityHelp(localize: (String) -> String = { $0 }) -> String {
        localize(accessibilityHelpKey)
    }
}

/// Pure policy for pinch-in dismiss (PINCH-TO-DISMISS-01). AppKit phases stay in Direct.
public enum PinchDismissPolicy {
    /// Accumulated `NSEvent.magnification` (negative = pinch in) that triggers dismiss.
    public static let pinchInThreshold: Double = -0.22

    public static func shouldDismiss(
        enabled: Bool,
        accumulatedMagnification: Double,
        isPaging: Bool,
        isDragging: Bool,
        isDismissing: Bool,
        threshold: Double = pinchInThreshold
    ) -> Bool {
        guard enabled, !isPaging, !isDragging, !isDismissing else { return false }
        return accumulatedMagnification <= threshold
    }
}

/// Preferred main-grid columns and rows (GRID-GEOMETRY-CONFIG-01).
///
/// Clamped math, persisted on `LauncherPreferences` (GRID-GEOMETRY-PREFS-01).
/// Direct still lays the grid out with `LauncherLayout.pageColumns` /
/// `pageRows` / `pageCapacity`. `preservedPageIndex` must not drive a page
/// turn until that apply slice has its own guard.
/// Folder grids stay on `LauncherLayout.folderColumns` and are not this preference.
public struct GridGeometryPreference: Equatable, Sendable, Codable {
    public static let defaultColumns = 7
    public static let defaultRows = 5
    /// Inclusive. Below 5 the titles collide; above 10 the icons drop under 60 pt
    /// on a typical launcher width. Rows stop at 3 so a page still looks like a
    /// grid, and at 8 so a compact display can still fit the fifth-row minimum.
    public static let columnBounds = 5...10
    public static let rowBounds = 3...8

    public var columns: Int
    public var rows: Int

    public var capacity: Int { columns * rows }

    public static var standard: GridGeometryPreference {
        GridGeometryPreference(columns: defaultColumns, rows: defaultRows)
    }

    public init(columns: Int, rows: Int) {
        self.columns = Self.clamp(columns, to: Self.columnBounds)
        self.rows = Self.clamp(rows, to: Self.rowBounds)
    }

    /// Same integer division as `LauncherLayout.pageIndex(containingEntryAt:)`.
    /// Negative indexes stay on page 0. This does not animate.
    public func pageIndex(containingEntryAt index: Int) -> Int {
        guard index >= 0, capacity > 0 else { return 0 }
        return index / capacity
    }

    public func pageCount(forEntryCount count: Int) -> Int {
        guard count > 0, capacity > 0 else { return 0 }
        return (count + capacity - 1) / capacity
    }

    /// Page that still contains the first slot of `previousPage` after a
    /// geometry change. Keeps that slot in view; does not pick an animation.
    public static func preservedPageIndex(
        previous: GridGeometryPreference,
        next: GridGeometryPreference,
        previousPage: Int
    ) -> Int {
        let slot = max(0, previousPage) * previous.capacity
        return next.pageIndex(containingEntryAt: slot)
    }

    private static func clamp(_ value: Int, to bounds: ClosedRange<Int>) -> Int {
        min(max(value, bounds.lowerBound), bounds.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case columns
        case rows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let columns = try container.decode(Int.self, forKey: .columns)
        let rows = try container.decode(Int.self, forKey: .rows)
        self.init(columns: columns, rows: rows)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(columns, forKey: .columns)
        try container.encode(rows, forKey: .rows)
    }
}

public struct LauncherPreferences: Equatable, Sendable {
    public var shortcut: LauncherShortcut
    public var showsStatusItem: Bool
    public var hidesAfterLaunch: Bool
    public var reducesMotion: Bool
    public var hotCorner: LauncherHotCorner
    /// Hide app / folder names under grid and folder tiles (search results keep them).
    public var hidesAppNames: Bool
    /// Hide folder names under folder tiles on the grid (open-folder title stays).
    public var hidesFolderNames: Bool
    /// Display the launcher opens on; default keeps `NSScreen.main`.
    public var displayTarget: LauncherDisplayTarget
    /// Extra folders scanned after the standard Applications roots
    /// (external drives, VM app folders). Stored as absolute paths.
    public var additionalAppDirectories: [String]
    /// Darkness of the overlay over the blurred wallpaper (BACKGROUND-DIM-01).
    public var backgroundDim: LauncherBackgroundDim
    /// Blur the wallpaper behind the grid (BACKGROUND-BLUR-01); default on.
    public var blursBackground: Bool
    /// Where the grid opens after dismiss (REOPEN-PAGE-BEHAVIOR-01).
    public var reopenPageBehavior: LauncherReopenPageBehavior
    /// Pinch-in while visible hides the launcher (PINCH-TO-DISMISS-01); default on.
    public var pinchToDismiss: Bool
    /// Preferred main-grid size. Direct does not read this for layout yet.
    public var gridGeometry: GridGeometryPreference

    public init(
        shortcut: LauncherShortcut = .optionSpace,
        showsStatusItem: Bool = true,
        hidesAfterLaunch: Bool = true,
        reducesMotion: Bool = false,
        hotCorner: LauncherHotCorner = .off,
        hidesAppNames: Bool = false,
        hidesFolderNames: Bool = false,
        displayTarget: LauncherDisplayTarget = .active,
        additionalAppDirectories: [String] = [],
        backgroundDim: LauncherBackgroundDim = .standard,
        blursBackground: Bool = true,
        reopenPageBehavior: LauncherReopenPageBehavior = .rememberLast,
        pinchToDismiss: Bool = true,
        gridGeometry: GridGeometryPreference = .standard
    ) {
        self.shortcut = shortcut
        self.showsStatusItem = showsStatusItem
        self.hidesAfterLaunch = hidesAfterLaunch
        self.reducesMotion = reducesMotion
        self.hotCorner = hotCorner
        self.hidesAppNames = hidesAppNames
        self.hidesFolderNames = hidesFolderNames
        self.displayTarget = displayTarget
        self.additionalAppDirectories = additionalAppDirectories
        self.backgroundDim = backgroundDim
        self.blursBackground = blursBackground
        self.reopenPageBehavior = reopenPageBehavior
        self.pinchToDismiss = pinchToDismiss
        self.gridGeometry = gridGeometry
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
                .flatMap(LauncherHotCorner.init(rawValue:)) ?? .off,
            hidesAppNames: defaults.bool(forKey: prefix + "hidesAppNames"),
            hidesFolderNames: defaults.bool(forKey: prefix + "hidesFolderNames"),
            displayTarget: defaults.string(forKey: prefix + "displayTarget")
                .flatMap(LauncherDisplayTarget.init(rawValue:)) ?? .active,
            additionalAppDirectories: AppCatalogScanner.sanitizedAdditionalAppDirectories(
                defaults.stringArray(forKey: prefix + "additionalAppDirectories") ?? []
            ),
            backgroundDim: defaults.string(forKey: prefix + "backgroundDim")
                .flatMap(LauncherBackgroundDim.init(rawValue:)) ?? .standard,
            blursBackground: defaults.object(forKey: prefix + "blursBackground") as? Bool ?? true,
            reopenPageBehavior: defaults.string(forKey: prefix + "reopenPageBehavior")
                .flatMap(LauncherReopenPageBehavior.init(rawValue:)) ?? .rememberLast,
            pinchToDismiss: defaults.object(forKey: prefix + "pinchToDismiss") as? Bool ?? true,
            gridGeometry: Self.storedGridGeometry(
                columns: defaults.object(forKey: prefix + "gridColumns") as? Int,
                rows: defaults.object(forKey: prefix + "gridRows") as? Int
            )
        )
    }

    /// GRID-GEOMETRY-PREFS-01. Missing either key stays 7×5 so a half write
    /// cannot change page capacity. Both keys are clamped by the preference type.
    private static func storedGridGeometry(columns: Int?, rows: Int?) -> GridGeometryPreference {
        guard let columns, let rows else { return .standard }
        return GridGeometryPreference(columns: columns, rows: rows)
    }

    public func save(_ preferences: LauncherPreferences) {
        defaults.set(preferences.shortcut.rawValue, forKey: prefix + "shortcut")
        defaults.set(preferences.showsStatusItem, forKey: prefix + "showsStatusItem")
        defaults.set(preferences.hidesAfterLaunch, forKey: prefix + "hidesAfterLaunch")
        defaults.set(preferences.reducesMotion, forKey: prefix + "reducesMotion")
        defaults.set(preferences.hotCorner.rawValue, forKey: prefix + "hotCorner")
        defaults.set(preferences.hidesAppNames, forKey: prefix + "hidesAppNames")
        defaults.set(preferences.hidesFolderNames, forKey: prefix + "hidesFolderNames")
        defaults.set(preferences.displayTarget.rawValue, forKey: prefix + "displayTarget")
        defaults.set(
            AppCatalogScanner.sanitizedAdditionalAppDirectories(preferences.additionalAppDirectories),
            forKey: prefix + "additionalAppDirectories"
        )
        defaults.set(preferences.backgroundDim.rawValue, forKey: prefix + "backgroundDim")
        defaults.set(preferences.blursBackground, forKey: prefix + "blursBackground")
        defaults.set(preferences.reopenPageBehavior.rawValue, forKey: prefix + "reopenPageBehavior")
        defaults.set(preferences.pinchToDismiss, forKey: prefix + "pinchToDismiss")
        defaults.set(preferences.gridGeometry.columns, forKey: prefix + "gridColumns")
        defaults.set(preferences.gridGeometry.rows, forKey: prefix + "gridRows")
    }
}


// MARK: - Shortcut registration copy (SHORTCUT-REGISTRATION-COPY-01)

/// User-visible outcomes when a global hotkey cannot be registered or when
/// hiding the status item would leave the app unreachable.
public enum ShortcutRegistrationCopy {
    public static let bootConflictFormatKey =
        "无法使用呼出快捷键 %@。可能与系统或其他应用冲突，请选择其他组合；菜单栏图标仍可使用。"
    public static let changeConflictFormatKey =
        "无法使用快捷键 %@，可能与系统或其他应用冲突。原组合保持不变。"
    public static let cannotHideStatusItemKey = "快捷键不可用时不能隐藏菜单栏图标。"

    public static func bootConflictMessage(
        shortcutTitle: String,
        localize: (String) -> String = { $0 }
    ) -> String {
        String(format: localize(bootConflictFormatKey), shortcutTitle)
    }

    public static func changeConflictMessage(
        shortcutTitle: String,
        localize: (String) -> String = { $0 }
    ) -> String {
        String(format: localize(changeConflictFormatKey), shortcutTitle)
    }

    public static func cannotHideStatusItem(localize: (String) -> String = { $0 }) -> String {
        localize(cannotHideStatusItemKey)
    }
}

import AppKit
import LaunchIconCore
import ObjectiveC
import OSLog

/// STATUS-ITEM-AX-SHOW-MENU-01: `NSStatusItem` owns the button, and Show Menu
/// is delivered only to that instance. This subclass stores nothing, so
/// `object_setClass` keeps the same size. Left click still uses the action.
final class LaunchIconStatusButton: NSStatusBarButton {
    override func accessibilityPerformShowMenu() -> Bool {
        guard let owner = target as? DirectAppDelegate else { return false }
        return owner.presentStatusItemMenuForAccessibility()
    }
}

func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
}

/// Shared application. `main` creates this before `NSApplication.shared`, and
/// the principal class is the same type, so the process does not lock in a
/// plain `NSApplication` whose frame is null.
@objc(LauncherApplication)
final class LauncherApplication: NSApplication {
    /// Grid typing is delivered to the application element. A missing
    /// position or size attribute is what XCTest reads as a null frame.
    private func launcherScreenFrame() -> NSRect {
        let others = windows.filter { $0 !== keyWindow && $0.isVisible }.map(\.frame)
        return LauncherLayout.applicationAccessibilityFrame(
            keyWindowFrame: keyWindow?.frame,
            otherVisibleWindowFrames: others,
            reportedFrame: .null
        )
    }

    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        var names = super.accessibilityAttributeNames()
        if !names.contains(.position) { names.append(.position) }
        if !names.contains(.size) { names.append(.size) }
        return names
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        let screen = launcherScreenFrame()
        switch attribute {
        case .position:
            return NSValue(point: screen.origin)
        case .size:
            return NSValue(size: screen.size)
        default:
            return super.accessibilityAttributeValue(attribute)
        }
    }

    override func accessibilityFrame() -> NSRect {
        launcherScreenFrame()
    }
}

@main
final class DirectAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    nonisolated(unsafe) private static var retained: DirectAppDelegate?
    private let hotKeyService = CarbonGlobalHotKeyService()
    private let hotCornerMonitor = HotCornerMonitor()
    private let preferencesStore = LauncherPreferencesStore(
        suiteName: ProcessInfo.processInfo.environment["LAUNCHICON_TEST_PREFERENCES_SUITE"]
    )
    private let diagnosticsQueue = DispatchQueue(label: "LaunchIcon.Direct.Diagnostics", qos: .utility)
    private let folderLifecycleLogger = Logger(subsystem: "com.sunzheng.LaunchIcon", category: "FolderLifecycle")
    /// Process-local origin for bootstrap / first-catalog diagnostic timings.
    private let processTimingOrigin = CFAbsoluteTimeGetCurrent()
    private var hasRecordedFirstCatalogReady = false
    private var preferences = LauncherPreferences()
    private var preferencesSaveTask: Task<Void, Never>?
    private var hotKeyRegistered = false
    private var launcherController: LauncherWindowController?
    private var settingsController: SettingsWindowController?
    /// True when `showSettings` hid a visible launcher; restore on settings close.
    private var didHideLauncherToShowSettings = false
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var toggleMenuItem: NSMenuItem?

    static func main() {
        let application = LauncherApplication.shared
        let delegate = DirectAppDelegate()
        retained = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await self.bootstrap()
        }
    }

    @MainActor
    private func bootstrap() async {
        preferences = await preferencesStore.load()
        let testRoot = ProcessInfo.processInfo.environment["LAUNCHICON_TEST_SCAN_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let testLayoutURL = ProcessInfo.processInfo.environment["LAUNCHICON_TEST_LAYOUT_PATH"].map {
            URL(fileURLWithPath: $0)
        }
        let testWindowSize: NSSize? = {
            guard testLayoutURL != nil,
                  let value = ProcessInfo.processInfo.environment["LAUNCHICON_TEST_WINDOW_SIZE"] else { return nil }
            let dimensions = value.split(separator: "x")
            guard dimensions.count == 2,
                  let width = Double(dimensions[0]), let height = Double(dimensions[1]),
                  width > 0, height > 0 else { return nil }
            return NSSize(width: width, height: height)
        }()
        let layoutStore: JSONLayoutStore
        let backupFailureLogURL = Self.layoutBackupFailureLogURL()
        if let testLayoutURL {
            layoutStore = JSONLayoutStore(fileURL: testLayoutURL, backupFailureLogURL: backupFailureLogURL)
        } else if testRoot != nil {
            let automaticTestLayoutURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LaunchIcon-empty-state-\(ProcessInfo.processInfo.processIdentifier)")
                .appendingPathComponent("layout-v1.json")
            layoutStore = JSONLayoutStore(fileURL: automaticTestLayoutURL, backupFailureLogURL: backupFailureLogURL)
        } else {
            layoutStore = JSONLayoutStore(fileURL: JSONLayoutStore.defaultFileURL, backupFailureLogURL: backupFailureLogURL)
        }
        launcherController = LauncherWindowController(
            catalogRoots: testRoot.map { [$0] } ?? AppCatalogScanner.standardRoots,
            additionalAppDirectories: testRoot == nil ? preferences.additionalAppDirectories : [],
            layoutStore: layoutStore,
            testWindowSize: testWindowSize
        )
        launcherController?.hidesAfterLaunch = preferences.hidesAfterLaunch
        launcherController?.setReducesMotion(preferences.reducesMotion)
        launcherController?.setHidesAppNames(preferences.hidesAppNames)
        launcherController?.setHidesFolderNames(preferences.hidesFolderNames)
        launcherController?.setDisplayTarget(preferences.displayTarget)
        launcherController?.setBackgroundDim(preferences.backgroundDim)
        launcherController?.setBlursBackground(preferences.blursBackground)
        // UI tests cannot push a suite UserDefaults value into this process
        // reliably. The same setter the Settings popup uses applies the override.
        if ProcessInfo.processInfo.environment["LAUNCHICON_TEST_LAYOUT_PATH"] != nil,
           let raw = ProcessInfo.processInfo.environment["LAUNCHICON_TEST_REOPEN_PAGE_BEHAVIOR"],
           let override = LauncherReopenPageBehavior(rawValue: raw) {
            preferences.reopenPageBehavior = override
        }
        // UI tests cannot push a suite UserDefaults value into this process
        // reliably. Honor a test-only pair so a fixture can boot at 5×3 / 10×8.
        if ProcessInfo.processInfo.environment["LAUNCHICON_TEST_LAYOUT_PATH"] != nil,
           let columns = Int(ProcessInfo.processInfo.environment["LAUNCHICON_TEST_GRID_COLUMNS"] ?? ""),
           let rows = Int(ProcessInfo.processInfo.environment["LAUNCHICON_TEST_GRID_ROWS"] ?? "") {
            preferences.gridGeometry = GridGeometryPreference(columns: columns, rows: rows)
        }
        launcherController?.setReopenPageBehavior(preferences.reopenPageBehavior)
        launcherController?.setPageFlipDirection(preferences.pageFlipDirection)
        launcherController?.setGridGeometry(preferences.gridGeometry)
        launcherController?.setPinchToDismissEnabled(preferences.pinchToDismiss)
        launcherController?.onSettingsRequested = { [weak self] in self?.showSettings() }
        launcherController?.onPageFlipDirectionChangeRequested = { [weak self] direction in
            guard let self else { return }
            var next = self.preferences
            next.pageFlipDirection = direction
            _ = self.applyPreferences(next)
        }
        launcherController?.onVisibilityChanged = { [weak self] in
            self?.refreshStatusItemToggleTitle()
            self?.clearSettingsLauncherRestoreIfLauncherVisible()
        }
        launcherController?.onCatalogLoaded = { [weak self] report in
            self?.record("Discovery: \(report.candidates.count) candidates; skipped: \(report.skippedPaths.count)")
            for url in report.skippedPaths.prefix(20) {
                self?.record("Discovery skipped: \(url.path)")
            }
            for url in report.unreadableMetadataPaths.prefix(20) {
                self?.record("Discovery degraded: \(url.path); bundle Info.plist missing or unreadable")
            }
            for url in report.unlaunchablePaths.prefix(20) {
                self?.record("Discovery degraded: \(url.path); bundle executable missing or not executable")
            }
        }
        launcherController?.onCatalogReloadFinished = { [weak self] canEditLayout in
            guard let self else { return }
            self.settingsController?.completeRescan(canEditLayout: canEditLayout)
            // SETTINGS-HIDDEN-REFRESH-ON-SCAN-01: mid-scan Settings open must
            // see hidden apps once the catalog exists (not only on becomeKey).
            self.settingsController?.refreshHiddenApplicationsFromLauncher()
            if !self.hasRecordedFirstCatalogReady {
                self.hasRecordedFirstCatalogReady = true
                self.record(
                    "Bootstrap: first catalog ready after \(self.elapsedSinceProcessTimingOriginMs()) ms; persistable=\(canEditLayout)"
                )
            }
        }
        // SETTINGS-HIDDEN-REFRESH-ON-LAYOUT-01: hide/restore while Settings stays
        // open (launcher brought back) refreshes without waiting for becomeKey.
        launcherController?.onHiddenApplicationsChanged = { [weak self] in
            guard let self else { return }
            let visible = self.settingsController?.window?.isVisible == true
            guard LauncherLayout.shouldRefreshSettingsHiddenAppsOnLayoutChange(
                settingsWindowVisible: visible
            ) else { return }
            self.settingsController?.refreshHiddenApplicationsFromLauncher()
        }
        launcherController?.onCatalogSnapshotSaveFailed = { [weak self] error in
            let nsError = error as NSError
            self?.record("Catalog snapshot save failed: domain=\(nsError.domain); code=\(nsError.code)")
        }
        launcherController?.onDiagnosticEvent = { [weak self] event in
            self?.recordFolderLifecycle(event)
        }
        launcherController?.onLaunchFailed = { [weak self] candidate, error in
            let nsError = error as NSError
            self?.record(
                "Launch failed: \(candidate.canonicalURL.path); domain=\(nsError.domain); code=\(nsError.code)"
            )
        }
        launcherController?.onLayoutSaveFailed = { [weak self] error in
            let nsError = error as NSError
            self?.record("Layout save failed: domain=\(nsError.domain); code=\(nsError.code)")
        }
        Task { @MainActor [weak self] in
            guard let self, let launcherController = self.launcherController else { return }
            if !(await launcherController.startWatchingCatalog()) {
                self.record("Directory watcher unavailable; manual rescan remains available")
            }
        }
        configureApplicationMenu()
        var shortcutError: HotKeyRegistrationError?
        switch registerShortcut(preferences.shortcut) {
        case .success:
            hotKeyRegistered = true
            record("Hot key \(preferences.shortcut.title): registered")
        case let .failure(error):
            shortcutError = error
            record("Hot key \(preferences.shortcut.title): failed: \(error)")
        }
        if !hotKeyRegistered && !preferences.showsStatusItem {
            preferences.showsStatusItem = true
            await preferencesStore.save(preferences)
        }
        if preferences.showsStatusItem { configureStatusItem() }
        configureHotCornerMonitor(preferences.hotCorner)
        if let shortcutError {
            showSettings()
            // SHORTCUT-REGISTRATION-COPY-01
            settingsController?.presentShortcutRegistrationError(
                ShortcutRegistrationCopy.bootConflictMessage(
                    shortcutTitle: preferences.shortcut.title,
                    localize: { L($0) }
                )
            )
            record("Shortcut recovery shown: \(shortcutError)")
        }
        launcherController?.reloadCatalogIfIdle()
        #if DEBUG
        if testRoot != nil,
           ProcessInfo.processInfo.environment["LAUNCHICON_TEST_CANCEL_SCAN_ON_BOOT"] == "1" {
            await launcherController?.flushLayout()
            precondition(launcherController?.reloadCatalogIfIdle() == true, "Cancelled catalog scan remained busy")
        }
        #endif
        if shortcutError == nil {
            record("Bootstrap: initial show requested after \(elapsedSinceProcessTimingOriginMs()) ms")
            launcherController?.show()
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LAUNCHICON_TEST_LAYOUT_PATH"] != nil,
           ProcessInfo.processInfo.environment["LAUNCHICON_TEST_OPEN_SETTINGS"] == "1" {
            showSettings()
        }
        #endif
        #if DEBUG
        if testRoot != nil,
           ProcessInfo.processInfo.environment["LAUNCHICON_TEST_CANCEL_SCAN_WITHOUT_RETRY"] == "1" {
            await launcherController?.flushLayout()
        }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        hotKeyService.unregister()
        Task { @MainActor [weak self] in
            self?.hotCornerMonitor.stop()
            await self?.launcherController?.flushLayout()
            await self?.preferencesSaveTask?.value
            if let queue = self?.diagnosticsQueue {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    queue.async { continuation.resume() }
                }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let hasVisibleWindows = flag
        Task { @MainActor in
            guard let controller = self.launcherController else { return }
            // DOCK-REOPEN-SUPPRESS-WHEN-SETTINGS-OR-MODAL-01
            let settingsIsKey = self.settingsController?.window?.isKeyWindow == true
            controller.respondToDockReopen(
                hasVisibleWindows: hasVisibleWindows,
                settingsIsKey: settingsIsKey
            )
        }
        return true
    }

    @MainActor
    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "LaunchIcon")
        // MENU-CHROME-TITLES-01
        let settingsItem = appMenu.addItem(
            withTitle: LauncherLayout.MenuChromeCopy.settingsTitle(localize: { L($0) }),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(
            withTitle: LauncherLayout.MenuChromeCopy.quitAppTitle(localize: { L($0) }),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: LauncherLayout.MenuChromeCopy.editMenuTitle(localize: { L($0) }))
        editMenu.addItem(
            withTitle: LauncherLayout.MenuChromeCopy.selectAllTitle(localize: { L($0) }),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenu.addItem(
            withTitle: LauncherLayout.MenuChromeCopy.pasteTitle(localize: { L($0) }),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    @MainActor
    private func configureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(
            systemSymbolName: "square.grid.2x2.fill",
            accessibilityDescription: "LaunchIcon"
        ) {
            image.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
        } else {
            item.button?.title = "LI"
        }
        item.button?.toolTip = L(LauncherLayout.statusItemToggleTitle(isVisible: false, isDismissing: false))
        // STATUS-ITEM-BUTTON-AX-01: label tracks show/hide via refreshStatusItemToggleTitle.
        item.button?.setAccessibilityLabel(
            L(LauncherLayout.statusItemToggleTitle(isVisible: false, isDismissing: false))
        )
        // STATUS-ITEM-CLICK-01 — left click toggles the launcher; right /
        // Control-click opens the same menu. Do not assign `item.menu` or
        // primary click would only open the menu.
        item.button?.target = self
        item.button?.action = #selector(statusItemButtonActivated(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // STATUS-ITEM-AX-SHOW-MENU-01: do not assign item.menu (that steals
        // the left click). Install the Show Menu override on the existing button.
        if let button = item.button {
            object_setClass(button, LaunchIconStatusButton.self)
        }

        let menu = NSMenu()
        menu.delegate = self
        // MENU-CHROME-TITLES-01 — initial toggle title matches Core show-state.
        let toggleItem = menu.addItem(
            withTitle: L(LauncherLayout.statusItemToggleTitle(isVisible: false, isDismissing: false)),
            action: #selector(toggleLauncher),
            keyEquivalent: menuKeyEquivalent(for: preferences.shortcut)
        )
        toggleItem.target = self
        toggleItem.keyEquivalentModifierMask = menuModifiers(for: preferences.shortcut)
        let reloadItem = menu.addItem(
            withTitle: LauncherLayout.MenuChromeCopy.reloadCatalogTitle(localize: { L($0) }),
            action: #selector(reloadCatalog),
            keyEquivalent: "r"
        )
        reloadItem.target = self
        let settingsItem = menu.addItem(
            withTitle: LauncherLayout.MenuChromeCopy.settingsTitle(localize: { L($0) }),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(
            withTitle: LauncherLayout.MenuChromeCopy.quitTitle(localize: { L($0) }),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        statusMenu = menu
        toggleMenuItem = toggleItem
        statusItem = item
        refreshStatusItemToggleTitle()
    }

    @MainActor
    @objc private func statusItemButtonActivated(_ sender: Any?) {
        let event = NSApp.currentEvent
        let pointer = Self.statusItemPointerKind(for: event)
        let optionDown = event?.modifierFlags.contains(.option) == true
        switch LauncherLayout.statusItemButtonAction(for: pointer, optionDown: optionDown) {
        case .toggle:
            toggleLauncher()
        case .showMenu:
            presentStatusMenu(from: sender as? NSStatusBarButton)
        case .openSettings:
            openSettings()
        }
    }

    private static func statusItemPointerKind(
        for event: NSEvent?
    ) -> LauncherLayout.StatusItemPointerKind {
        // STATUS-ITEM-NONPOINTER-MENU-01: a missing event or a non-mouse event
        // (VoiceOver AXPress, keyboard) opens the menu. Real clicks stay as before.
        guard let event else { return .nonPointer }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            if event.type == .rightMouseDown || event.type == .rightMouseUp || event.type == .rightMouseDragged
                || event.modifierFlags.contains(.control) {
                return .secondary
            }
            return .primary
        default:
            return .nonPointer
        }
    }

    @MainActor
    private func presentStatusMenu(from button: NSStatusBarButton?) {
        guard let menu = statusMenu, let button else { return }
        // STATUS-ITEM-MENU-SUPPRESS-WHEN-MODAL-01
        guard launcherController?.shouldPresentStatusItemMenu() != false else { return }
        refreshStatusItemToggleTitle()
        let point = NSPoint(x: 0, y: button.bounds.height)
        menu.popUp(positioning: nil, at: point, in: button)
    }

    /// STATUS-ITEM-AX-SHOW-MENU-01: VoiceOver Show Menu. Not the left-click toggle.
    @MainActor
    func presentStatusItemMenuForAccessibility() -> Bool {
        guard LauncherLayout.statusItemActionForAccessibilityShowMenu() == .showMenu else {
            return false
        }
        // STATUS-ITEM-AX-SHOW-MENU-SUPPRESSED-01: alias / uninstall sheets
        // keep the menu down. Report that to VoiceOver instead of success.
        let presentationAllowed = launcherController?.shouldPresentStatusItemMenu() != false
        guard LauncherLayout.statusItemAccessibilityShowMenuPerformed(
            hasButton: statusItem?.button != nil,
            hasMenu: statusMenu != nil,
            presentationAllowed: presentationAllowed
        ) else { return false }
        presentStatusMenu(from: statusItem?.button)
        return true
    }

    @MainActor
    private func menuKeyEquivalent(for shortcut: LauncherShortcut) -> String {
        switch shortcut {
        case .optionSpace, .optionShiftSpace, .controlShiftSpace:
            return " "
        case .f4:
            return String(UnicodeScalar(UInt32(NSF4FunctionKey))!)
        }
    }

    @MainActor
    private func menuModifiers(for shortcut: LauncherShortcut) -> NSEvent.ModifierFlags {
        switch shortcut {
        case .optionSpace: [.option]
        case .optionShiftSpace: [.option, .shift]
        case .controlShiftSpace: [.control, .shift]
        case .f4: []
        }
    }

    @MainActor
    private func configureHotCornerMonitor(_ corner: LauncherHotCorner) {
        hotCornerMonitor.update(corner: corner) { [weak self] in
            // Presence fade via show/hide(animated:) — not settings snappy hide,
            // and not page indicator/arrow snaps.
            // HOT-CORNER-SUPPRESS-WHEN-SETTINGS-OR-MODAL-01
            guard let self else { return }
            let settingsIsKey = self.settingsController?.window?.isKeyWindow == true
            self.launcherController?.respondToHotCornerTrigger(settingsIsKey: settingsIsKey)
        }
        if corner.isEnabled {
            record("Hot corner \(corner.title): enabled")
        }
    }

    @MainActor
    private func registerShortcut(_ shortcut: LauncherShortcut) -> Result<Void, HotKeyRegistrationError> {
        let environment = ProcessInfo.processInfo.environment
        if environment["LAUNCHICON_TEST_SCAN_ROOT"] != nil,
           environment["LAUNCHICON_TEST_FORCE_HOTKEY_FAILURE"] == shortcut.rawValue {
            return .failure(.registrationFailed(-1))
        }
        let pressed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // HOTKEY-STATUS-SUPPRESS-WHEN-SETTINGS-OR-MODAL-01
                let settingsIsKey = self.settingsController?.window?.isKeyWindow == true
                self.launcherController?.toggleVisibility(settingsIsKey: settingsIsKey)
            }
        }
        return hotKeyService.register(shortcut, onPressed: pressed)
    }

    @MainActor
    private func applyPreferences(_ proposed: LauncherPreferences) -> String? {
        if proposed.shortcut != preferences.shortcut || !hotKeyRegistered {
            switch registerShortcut(proposed.shortcut) {
            case .success:
                hotKeyRegistered = true
            case let .failure(error):
                record("Hot key \(proposed.shortcut.title): failed: \(error)")
                // SHORTCUT-REGISTRATION-COPY-01
                return ShortcutRegistrationCopy.changeConflictMessage(
                    shortcutTitle: proposed.shortcut.title,
                    localize: { L($0) }
                )
            }
        }
        guard proposed.showsStatusItem || hotKeyRegistered else {
            return ShortcutRegistrationCopy.cannotHideStatusItem(localize: { L($0) })
        }
        preferences = proposed
        launcherController?.hidesAfterLaunch = proposed.hidesAfterLaunch
        launcherController?.setReducesMotion(proposed.reducesMotion)
        launcherController?.setHidesAppNames(proposed.hidesAppNames)
        launcherController?.setHidesFolderNames(proposed.hidesFolderNames)
        launcherController?.setDisplayTarget(proposed.displayTarget)
        launcherController?.setBackgroundDim(proposed.backgroundDim)
        launcherController?.setBlursBackground(proposed.blursBackground)
        launcherController?.setReopenPageBehavior(proposed.reopenPageBehavior)
        launcherController?.setPageFlipDirection(proposed.pageFlipDirection)
        launcherController?.setGridGeometry(proposed.gridGeometry)
        launcherController?.setPinchToDismissEnabled(proposed.pinchToDismiss)
        launcherController?.setAdditionalAppDirectories(proposed.additionalAppDirectories)
        configureHotCornerMonitor(proposed.hotCorner)
        if proposed.showsStatusItem {
            configureStatusItem()
            toggleMenuItem?.keyEquivalent = menuKeyEquivalent(for: proposed.shortcut)
            toggleMenuItem?.keyEquivalentModifierMask = menuModifiers(for: proposed.shortcut)
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            self.statusMenu = nil
            toggleMenuItem = nil
        }
        let previous = preferencesSaveTask
        preferencesSaveTask = Task { [preferencesStore] in
            await previous?.value
            await preferencesStore.save(proposed)
        }
        return nil
    }

    @MainActor
    private func showSettings() {
        // SETTINGS-CLEAR-SELECTION-01: also covers app-menu / dock paths.
        launcherController?.clearSelectionBeforeOpeningSettings()
        let launcherVisible = launcherController?.window?.isVisible == true
        if LauncherLayout.shouldHideLauncherToShowSettings(launcherVisible: launcherVisible) {
            launcherController?.hide(
                animated: LauncherLayout.shouldAnimateLauncherHideForSettingsHandoff()
            )
            didHideLauncherToShowSettings = true
        } else {
            // SETTINGS-OPEN-DEDUPE-CALLS-01: hide() cancels icon loads when the
            // launcher is visible. A hidden launcher skips hide(), but a catalog
            // refresh may still be prefetching. Cancel once on that path only.
            launcherController?.cancelIconLoadsForSettingsWhileLauncherHidden()
        }
        let hiddenApplications = launcherController?.hiddenApplications() ?? []
        if settingsController == nil {
            let controller = SettingsWindowController(
                preferences: preferences,
                hiddenApplications: hiddenApplications
            )
            controller.onPreferencesChanged = { [weak self] proposed in
                self?.applyPreferences(proposed)
            }
            controller.onRestoreHiddenApplication = { [weak self] key in
                self?.launcherController?.restoreHiddenApplication(withKey: key) ?? false
            }
            controller.hiddenApplicationsProvider = { [weak self] in
                self?.launcherController?.hiddenApplications()
            }
            controller.onRestoreAllHiddenApplications = { [weak self] in
                self?.launcherController?.restoreAllHiddenApplications()
            }
            controller.onCleanUpLeftovers = { [weak self] progress in
                await self?.launcherController?.cleanUpOrphanLeftovers(progress: progress)
                    ?? L(AppOrphanLeftoverScanner.incompleteScanMessageKey)
            }
            controller.onRescan = { [weak self] in
                self?.launcherController?.reloadCatalog()
            }
            controller.onRearrangeTopLevel = { [weak self] sort in
                self?.launcherController?.rearrangeTopLevelGrid(sort: sort) ?? false
            }
            controller.onRearrangeByCategory = { [weak self] in
                self?.launcherController?.rearrangeTopLevelGridByCategory() ?? false
            }
            controller.onRearrangeByColor = { [weak self] in
                await self?.launcherController?.rearrangeTopLevelGridByColorAwaitingCompletion() ?? false
            }
            controller.onRearrangeByDate = { [weak self] kind in
                await self?.launcherController?.rearrangeTopLevelGridByDateAwaitingCompletion(kind) ?? false
            }
            controller.layoutBackupAvailable = { [weak self] in
                self?.launcherController?.layoutBackupAvailable() ?? false
            }
            controller.onAwaitLayoutPersist = { [weak self] in
                await self?.launcherController?.awaitPendingLayoutPersist()
            }
            controller.onExportLayout = { [weak self] url in
                // LAYOUT-IO-OUTCOME-COPY-01
                await self?.launcherController?.exportLayout(to: url)
                    ?? LauncherLayout.LayoutIOOutcomeCopy.exportUnavailable(localize: { L($0) })
            }
            controller.onImportLayout = { [weak self] url in
                await self?.launcherController?.importLayout(from: url)
                    ?? LauncherLayout.LayoutIOOutcomeCopy.importUnavailable(localize: { L($0) })
            }
            controller.onImportLaunchpadLayout = { [weak self] url in
                await self?.launcherController?.importLaunchpadLayout(from: url)
                    ?? LauncherLayout.LayoutIOOutcomeCopy.importUnavailable(localize: { L($0) })
            }
            controller.onRestoreLayoutBackup = { [weak self] in
                await self?.launcherController?.restoreLastLayoutBackup()
                    ?? LauncherLayout.LayoutIOOutcomeCopy.restoreUnavailable(localize: { L($0) })
            }
            controller.onWindowWillClose = { [weak self] in
                self?.settingsWindowWillClose()
            }
            settingsController = controller
        }
        settingsController?.show(preferences: preferences, hiddenApplications: hiddenApplications)
    }

    @MainActor
    private func clearSettingsLauncherRestoreIfLauncherVisible() {
        let visible = launcherController?.window?.isVisible == true
        guard LauncherLayout.shouldClearSettingsLauncherRestoreFlag(
            didHideLauncherToShowSettings: didHideLauncherToShowSettings,
            launcherVisible: visible
        ) else { return }
        didHideLauncherToShowSettings = false
    }

    @MainActor
    private func settingsWindowWillClose() {
        let shouldRestore = LauncherLayout.shouldRestoreLauncherWhenSettingsCloses(
            didHideLauncherToShowSettings: didHideLauncherToShowSettings
        )
        didHideLauncherToShowSettings = false
        guard shouldRestore else { return }
        launcherController?.show(
            animated: LauncherLayout.shouldAnimateLauncherShowForSettingsHandoff()
        )
    }

    @objc private func openSettings() {
        Task { @MainActor in self.showSettings() }
    }

    @objc private func toggleLauncher() {
        Task { @MainActor in
            // HOTKEY-STATUS-SUPPRESS-WHEN-SETTINGS-OR-MODAL-01
            let settingsIsKey = self.settingsController?.window?.isKeyWindow == true
            self.launcherController?.toggleVisibility(settingsIsKey: settingsIsKey)
        }
    }

    @objc private func reloadCatalog() {
        Task { @MainActor in
            self.launcherController?.reloadCatalog()
        }
    }

    /// User diagnostics only. A test layout or preferences suite must not append there.
    private static func layoutBackupFailureLogURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard !LocalDiagnostics.keepsUserEvidenceUntouched(environment) else { return nil }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.sunzheng.LaunchIcon"
        return LocalDiagnostics.fileURL(for: bundleIdentifier)
    }

    private func elapsedSinceProcessTimingOriginMs() -> Int {
        Int((CFAbsoluteTimeGetCurrent() - processTimingOrigin) * 1000)
    }

    private func record(_ line: String) {
        let environment = ProcessInfo.processInfo.environment
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.sunzheng.LaunchIcon"
        diagnosticsQueue.async {
            LocalDiagnostics.appendEvidence(
                line,
                environment: environment,
                defaults: .standard,
                bundleIdentifier: bundleIdentifier
            )
        }
    }

    private func recordFolderLifecycle(_ event: String) {
        folderLifecycleLogger.notice("\(event, privacy: .public)")
        record(event)
    }
}

extension DirectAppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusItemToggleTitle()
    }

    /// The toggle item keeps whatever title it had when the menu opened.
    /// Show/hide (and dismiss-arm / dismiss-cancel) publish the current choice
    /// so a fade does not leave「隐藏」on an item that would now show the launcher.
    @MainActor
    private func refreshStatusItemToggleTitle() {
        let title = LauncherLayout.statusItemToggleTitle(
            isVisible: launcherController?.window?.isVisible == true,
            isDismissing: launcherController?.isDismissing == true
        )
        toggleMenuItem?.title = L(title)
        // Keep VoiceOver / help in sync with the same visibilityToggle choice.
        toggleMenuItem?.setAccessibilityTitle(L(title))
        statusItem?.button?.toolTip = L(title)
        // STATUS-ITEM-BUTTON-AX-01: button label was stuck on「LaunchIcon」.
        statusItem?.button?.setAccessibilityLabel(L(title))
        statusItem?.button?.setAccessibilityHelp(L(title))
    }
}

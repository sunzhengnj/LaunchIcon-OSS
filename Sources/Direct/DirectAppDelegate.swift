import AppKit
import LaunchIconCore
import OSLog

@main
final class DirectAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    nonisolated(unsafe) private static var retained: DirectAppDelegate?
    private let hotKeyService = CarbonGlobalHotKeyService()
    private let preferencesStore = LauncherPreferencesStore(
        suiteName: ProcessInfo.processInfo.environment["LAUNCHICON_TEST_PREFERENCES_SUITE"]
    )
    private let diagnosticsQueue = DispatchQueue(label: "LaunchIcon.Direct.Diagnostics", qos: .utility)
    private let folderLifecycleLogger = Logger(subsystem: "com.sunzheng.LaunchIcon", category: "FolderLifecycle")
    private var preferences = LauncherPreferences()
    private var preferencesSaveTask: Task<Void, Never>?
    private var hotKeyRegistered = false
    private var launcherController: LauncherWindowController?
    private var settingsController: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?

    static func main() {
        let application = NSApplication.shared
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
        if let testLayoutURL {
            layoutStore = JSONLayoutStore(fileURL: testLayoutURL)
        } else if testRoot != nil {
            let automaticTestLayoutURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LaunchIcon-empty-state-\(ProcessInfo.processInfo.processIdentifier)")
                .appendingPathComponent("layout-v1.json")
            layoutStore = JSONLayoutStore(fileURL: automaticTestLayoutURL)
        } else {
            layoutStore = JSONLayoutStore(fileURL: JSONLayoutStore.defaultFileURL)
        }
        launcherController = LauncherWindowController(
            catalogRoots: testRoot.map { [$0] } ?? AppCatalogScanner.standardRoots,
            layoutStore: layoutStore,
            testWindowSize: testWindowSize
        )
        launcherController?.hidesAfterLaunch = preferences.hidesAfterLaunch
        launcherController?.setReducesMotion(preferences.reducesMotion)
        launcherController?.onSettingsRequested = { [weak self] in self?.showSettings() }
        launcherController?.onVisibilityChanged = { [weak self] in
            self?.refreshStatusItemToggleTitle()
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
            self?.settingsController?.completeRescan(canEditLayout: canEditLayout)
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
        if let shortcutError {
            showSettings()
            settingsController?.presentShortcutRegistrationError(
                "无法使用呼出快捷键 \(preferences.shortcut.title)。可能与系统或其他应用冲突，请选择其他组合；菜单栏图标仍可使用。"
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
        if ProcessInfo.processInfo.environment["LAUNCHICON_SHOW_ON_LAUNCH"] == "1" {
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
            // A Dock click never hides. During the dismiss animation the
            // window is still visible, and the same choice as the hotkey
            // brings it back.
            if LauncherLayout.visibilityToggle(
                isVisible: hasVisibleWindows,
                isDismissing: controller.isDismissing
            ) == .show {
                controller.show()
            }
        }
        return true
    }

    @MainActor
    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "LaunchIcon")
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(
            withTitle: "退出 LaunchIcon",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
        item.button?.toolTip = "LaunchIcon"
        item.button?.setAccessibilityLabel("LaunchIcon")

        let menu = NSMenu()
        menu.delegate = self
        let toggleItem = menu.addItem(
            withTitle: "显示 LaunchIcon",
            action: #selector(toggleLauncher),
            keyEquivalent: " "
        )
        toggleItem.target = self
        toggleItem.keyEquivalentModifierMask = menuModifiers(for: preferences.shortcut)
        let reloadItem = menu.addItem(withTitle: "重新扫描", action: #selector(reloadCatalog), keyEquivalent: "r")
        reloadItem.target = self
        let settingsItem = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApplication.shared
        item.menu = menu
        toggleMenuItem = toggleItem
        statusItem = item
    }

    @MainActor
    private func menuModifiers(for shortcut: LauncherShortcut) -> NSEvent.ModifierFlags {
        switch shortcut {
        case .optionSpace: [.option]
        case .optionShiftSpace: [.option, .shift]
        case .controlShiftSpace: [.control, .shift]
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
            Task { @MainActor in self?.launcherController?.toggleVisibility() }
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
                return "无法使用快捷键 \(proposed.shortcut.title)，可能与系统或其他应用冲突。原组合保持不变。"
            }
        }
        guard proposed.showsStatusItem || hotKeyRegistered else {
            return "快捷键不可用时不能隐藏菜单栏图标。"
        }
        preferences = proposed
        launcherController?.hidesAfterLaunch = proposed.hidesAfterLaunch
        launcherController?.setReducesMotion(proposed.reducesMotion)
        if proposed.showsStatusItem {
            configureStatusItem()
            toggleMenuItem?.keyEquivalentModifierMask = menuModifiers(for: proposed.shortcut)
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
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
        launcherController?.hide()
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
            controller.onRescan = { [weak self] in
                self?.launcherController?.reloadCatalog()
            }
            settingsController = controller
        }
        settingsController?.show(preferences: preferences, hiddenApplications: hiddenApplications)
    }

    @objc private func openSettings() {
        Task { @MainActor in self.showSettings() }
    }

    @objc private func toggleLauncher() {
        Task { @MainActor in
            self.launcherController?.toggleVisibility()
        }
    }

    @objc private func reloadCatalog() {
        Task { @MainActor in
            self.launcherController?.reloadCatalog()
        }
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
    /// Show and hide publish the current choice so a fade does not leave「隐藏」
    /// on an item that would now show the launcher.
    @MainActor
    private func refreshStatusItemToggleTitle() {
        toggleMenuItem?.title = LauncherLayout.statusItemToggleTitle(
            isVisible: launcherController?.window?.isVisible == true,
            isDismissing: launcherController?.isDismissing == true
        )
    }
}

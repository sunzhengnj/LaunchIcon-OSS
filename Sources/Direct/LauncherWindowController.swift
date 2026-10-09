import AppKit
import CoreImage
import ImageIO
import LaunchIconCore
import OSLog

/// Stop the animations named in `keys` and leave the layer on the frame
/// already on screen. The model value is often already the destination.
private func pinLayerToPresentedFrame(_ layer: CALayer?, removing keys: [String]) {
    guard let layer else { return }
    let presented = layer.presentation()
    let opacity = presented?.opacity ?? layer.opacity
    let transform = presented?.transform ?? layer.transform
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for key in keys {
        layer.removeAnimation(forKey: key)
    }
    layer.opacity = opacity
    layer.transform = transform
    CATransaction.commit()
}

@MainActor
final class LauncherWindowController: NSWindowController {
    var onCatalogLoaded: ((CatalogScanReport) -> Void)?
    var onCatalogReloadFinished: ((Bool) -> Void)?
    var onCatalogSnapshotSaveFailed: ((Error) -> Void)?
    var onLaunchFailed: ((AppCandidate, Error) -> Void)?
    var onLayoutSaveFailed: ((Error) -> Void)?
    var onDiagnosticEvent: ((String) -> Void)?
    var onSettingsRequested: (() -> Void)?
    /// Status-item title is chosen when its menu opens. Publish again after
    /// show and hide so an already-open menu does not keep the previous verb.
    var onVisibilityChanged: (() -> Void)?
    var hidesAfterLaunch = true

    private let rootView: LauncherRootView
    private let layoutStore: JSONLayoutStore
    private let catalogSnapshotStore: CatalogSnapshotStore
    private let catalogRoots: [URL]
    private let testWindowSize: NSSize?
    private var directoryWatcher: ApplicationDirectoryWatcher?
    private var catalogLoadingTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var persistGeneration = 0
    private var launchesInFlight: [String: AppCandidate] = [:]
    private var persistableLayout = false
    private var isScanning = false
    private var catalogReloadGeneration = 0
    private var cachedCandidates: [AppCandidate] = []
    private var cachedLayout = LayoutState()
    private let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.sunzheng.LaunchIcon",
        category: "Performance"
    )
    private var windowUpdateInterval: OSSignpostIntervalState?
    private var dismissTask: Task<Void, Never>?
    private var dismissGeneration = 0
    /// Set for the whole fade, including the moment before `dismissTask`
    /// exists. Page restore has to see the fade before that task is stored.
    private var dismissArmed = false
    /// True while the dismiss animation is waiting to order the window out.
    /// The window is still visible; the next toggle shows the launcher again.
    var isDismissing: Bool { dismissTask != nil || dismissArmed }
    #if DEBUG
    private var buttonScriptTimer: Timer?
    #endif
    private let launcherPresentationOptions: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar]

    init(
        catalogRoots: [URL] = AppCatalogScanner.standardRoots,
        layoutStore: JSONLayoutStore = JSONLayoutStore(fileURL: JSONLayoutStore.defaultFileURL),
        testWindowSize: NSSize? = nil
    ) {
        rootView = LauncherRootView()
        self.catalogRoots = catalogRoots
        self.layoutStore = layoutStore
        catalogSnapshotStore = CatalogSnapshotStore(
            fileURL: layoutStore.fileURL.deletingLastPathComponent().appendingPathComponent("catalog-v1.json")
        )
        self.testWindowSize = testWindowSize
        let panel = LauncherPanel(
            contentRect: Self.frame(for: NSScreen.main?.frame ?? .zero, testSize: testWindowSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        // NSPanel would otherwise order itself out on deactivate and skip hide(), leaving the menu bar hidden.
        panel.hidesOnDeactivate = false
        // A panel that becomes key only for text fields swallows the click that should start a drag.
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = rootView
        super.init(window: panel)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidUpdate),
            name: NSWindow.didUpdateNotification,
            object: panel
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared
        )
        panel.dismissHandler = { [weak self] in self?.hide() }
        panel.keyboardSuspended = { [weak self] in
            LauncherLayout.shouldConsumeLauncherKeyEquivalent(isDismissing: self?.isDismissing == true)
        }
        panel.acceptsPointerActivation = { [weak self] in
            guard let self else { return false }
            return LauncherLayout.shouldAcceptPointerActivation(
                isDismissing: self.isDismissing,
                isVisible: self.window?.isVisible == true
            )
        }
        panel.resignKeyHandler = { [weak self] in
            self?.rootView.abandonFolderRenameBecauseWindowResignedKey()
            self?.rootView.discardSearchCompositionBecauseWindowResignedKey()
        }
        rootView.launcherIsDismissing = { [weak self] in
            self?.isDismissing == true
        }
        panel.searchHandler = { [weak self] in self?.rootView.focusSearch() }
        panel.pageHandler = { [weak rootView] direction in rootView?.movePage(by: direction) }
        panel.verticalPageHandler = { [weak rootView] direction in
            rootView?.scrollSearchResults(byPage: direction) ?? false
        }
        panel.escapeHandler = { [weak rootView] in rootView?.handleEscape() ?? false }
        panel.settingsHandler = { [weak self] in self?.onSettingsRequested?() }
        rootView.onCandidateSelected = { [weak self] candidate in self?.launch(candidate) }
        rootView.onLayoutChanged = { [weak self] state in self?.schedulePersist(state) }
        rootView.onReloadRequested = { [weak self] in self?.reloadCatalog() }
        rootView.onUseCachedCatalogRequested = { [weak self] in self?.cancelScanAndUseCachedCatalog() }
        rootView.onDiagnosticEvent = { [weak self] event in self?.onDiagnosticEvent?(event) }
        rootView.onSettingsRequested = { [weak self] in self?.onSettingsRequested?() }
        startTestButtonScriptIfNeeded()
    }

    private func startTestButtonScriptIfNeeded() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["LAUNCHICON_TEST_LAYOUT_PATH"] != nil,
              let path = environment["LAUNCHICON_TEST_BUTTON_SCRIPT"],
              !path.isEmpty else { return }
        buttonScriptTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.consumeTestButtonScript(at: path)
            }
        }
        #endif
    }

    #if DEBUG
    private func consumeTestButtonScript(at path: String) {
        guard let title = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              rootView.pressVisibleButton(titled: title) else { return }
        try? Data().write(to: URL(fileURLWithPath: path), options: .atomic)
        fputs("TEST_UI pressed \(title)\n", stderr)
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc nonisolated private func displayOptionsDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.rootView.refreshReducedMotionForSystemChange()
        }
    }

    private static func frame(for screenFrame: NSRect, testSize: NSSize?) -> NSRect {
        guard let testSize else { return screenFrame }
        return NSRect(
            x: screenFrame.midX - testSize.width / 2,
            y: screenFrame.midY - testSize.height / 2,
            width: testSize.width,
            height: testSize.height
        )
    }

    func show() {
        dismissGeneration += 1
        dismissTask?.cancel()
        dismissTask = nil
        dismissArmed = false
        rootView.releaseFrozenSearchField()
        guard let window else { return }
        let appearing = !window.isVisible
        // Activating the app makes this window key again. Read the old state
        // first, or a launcher that already gave up the keyboard looks like
        // it never did and keeps a stale field editor.
        let wasKey = window.isKeyWindow
        if appearing {
            windowUpdateInterval = signposter.beginInterval("WindowUpdate")
        }
        let screen = NSScreen.main ?? window.screen
        window.setFrame(Self.frame(for: screen?.frame ?? window.frame, testSize: testWindowSize), display: true)
        if let testWindowSize {
            assert(window.frame.size == testWindowSize, "Test window size was constrained by its content")
        }
        rootView.updateDesktopBackground(for: screen)
        if appearing {
            rootView.prepareForPresentation()
        } else {
            // A page slide was left where it was when the fade started. Land
            // it now that the launcher is up. A fresh appearance does this
            // before the first frame, from prepareForPresentation.
            // The merge ring and reorder gap were left in place for the same
            // reason. Clear them now unless the drag is still down.
            rootView.rememberGridPageForDismissal()
            rootView.applyDeferredVisualState()
            // A click may have ended the field editor just before this fade.
            // The refilter waits a turn and bails out while dismissing, so
            // the list is still the old query. Run it now that the launcher
            // is up again. Appearing clears the query instead.
            // A scan can finish during the fade. The model is already new.
            // Reload now that the launcher is up, before search focus moves.
            rootView.applyDeferredCatalogPresentation()
            // A launch can finish during the fade. The highlight id is already
            // new. Reload the tiles now that the launcher is up.
            rootView.applyDeferredLaunchHighlight()
            // Icon decode can finish during the fade. The image is already
            // decoded. Show it now that the launcher is up.
            rootView.applyDeferredLoadedIcons()
            // The wallpaper thumbnail can finish during the fade. Show it
            // now that the launcher is up.
            rootView.applyDeferredDesktopBackground()
            // A visible toast may have reached its timer during the fade.
            // Hide it only now that the launcher is up, unless a newer toast
            // is waiting to replace it.
            rootView.applyDeferredToastHide()
            // A failure toast can be requested during the fade. Show it now
            // that the launcher is up.
            rootView.applyDeferredToast()
            rootView.refilterSearchIfFieldEditorDroppedComposition()
            // The catalog index can finish during the fade without changing
            // the query, so the refilter above does not see it.
            rootView.applyDeferredSearchIndexRefresh()
            // Shift-Tab waits a turn. That turn may have been skipped while
            // the launcher was fading. Run it now that the window is up.
            // Appearing clears the query instead.
            rootView.applyDeferredSearchBacktab()
        }
        NSApp.activate(ignoringOtherApps: true)
        if testWindowSize == nil { NSApp.presentationOptions.formUnion(launcherPresentationOptions) }
        window.ignoresMouseEvents = false
        // Cancelling the fade must not move the first responder: that ends
        // the folder title and saves the draft. A fresh appearance, or a
        // window that already resigned key, starts on the grid.
        let keepFocus = LauncherLayout.shouldKeepLauncherFocusWhenShown(
            isAppearing: appearing,
            isKey: wasKey
        )
        window.makeKeyAndOrderFront(nil)
        if !keepFocus {
            window.makeFirstResponder(rootView)
        }
        rootView.animateLauncherPresence(visible: true, appearing: appearing)
        if directoryWatcher?.watchesAllRoots != true {
            reloadCatalogIfIdle()
        }
        onVisibilityChanged?()
    }

    func hide() {
        // Snapshot the query before a click that is already down can clear it.
        rootView.freezeSearchFieldForDismiss()
        // The icon menu tracks in its own window. Close it before the alias
        // alert: a choice of "设置别名" has already left the menu and entered
        // that modal, and cancelling the menu must not open a new one.
        rootView.cancelIconContextMenuBecauseLauncherIsDismissing()
        // The alias alert runs a modal loop, so this hide cannot order the
        // window out until the alert returns. Cancel it first. Save has
        // already left the loop and is not abandoned.
        rootView.abandonAliasPromptBecauseLauncherIsDismissing()
        // Arm before the page restore. `dismissTask` does not exist yet, and
        // committing now would reload the sliding grid before the fade.
        dismissArmed = true
        rootView.rememberGridPageForDismissal()
        // A wheel step can already be waiting out its quiet period. That wait
        // does not mark the grid as interrupted, so the restore above leaves
        // it armed. Cancel it here, before the fade, and again if a scroll
        // event arrives while the window is still dismissing.
        rootView.cancelPendingPageInput()
        rootView.endDropHighlightForDismissal()
        // Leaving the gap in place still lets the 0.18s ease finish under
        // the fade. Pin that slide on the frame it has already reached.
        rootView.settleReorderSlideForDismissal()
        // A folder landing can still be waiting out the merge flight. Letting
        // that reveal start now pops the new tile under the fade. Pin every
        // landing still in flight; a later tile must not leave an earlier one running.
        rootView.settleFolderLandingForDismissal()
        // The merge image is still flying, or the drag session has not ended
        // yet. Leave the image where it is; do not start the flight under
        // the fade.
        rootView.settleMergeFlightForDismissal()
        // An opening or closing folder keeps scaling under the fade, and the
        // close completion can hide the panel before the window leaves.
        rootView.settleFolderChromeForDismissal()
        // The grid and the search list crossfade for 0.12s. That fade keeps
        // running under the launcher fade unless it is pinned first.
        rootView.settleSearchChromeForDismissal()
        // The grid fades back in after a folder dissolves. That fade keeps
        // running under the launcher fade unless it is pinned first.
        rootView.settleDissolvedGridFadeForDismissal()
        // A launch press scales the icon for about 0.09s. That scale keeps
        // running under the launcher fade unless it is pinned first.
        rootView.settleLaunchFeedbackForDismissal()
        // A page arrow fades in over about a quarter of a second. That fade
        // keeps running under the launcher fade unless it is pinned first.
        rootView.settlePageButtonHoverForDismissal()
        // A toast can already be fading in or out. Leave it on the opacity
        // already drawn, and do not let the hide completion remove it.
        rootView.settleToastFadeForDismissal()
        finishWindowUpdate(cancelled: true)
        guard let window, window.isVisible, dismissTask == nil else {
            if dismissTask == nil {
                dismissArmed = false
                // orderOut ends the field editor and would save a half-typed
                // folder name. Abandon that draft only as the window leaves.
                rootView.abandonFolderRenameForDismissal()
                window?.orderOut(nil)
                rootView.applyDeferredVisualState()
                NSApp.presentationOptions.subtract(launcherPresentationOptions)
                onVisibilityChanged?()
            }
            return
        }
        window.ignoresMouseEvents = true
        let animationDelay = rootView.animateLauncherPresence(visible: false, appearing: false)
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let delay: TimeInterval
        if environment["LAUNCHICON_TEST_LAYOUT_PATH"] != nil,
           let milliseconds = TimeInterval(environment["LAUNCHICON_TEST_DISMISS_DELAY_MS"] ?? ""),
           milliseconds > 0 {
            delay = max(animationDelay, min(milliseconds / 1_000, 2))
        } else {
            delay = animationDelay
        }
        #else
        let delay = animationDelay
        #endif
        let generation = dismissGeneration
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.dismissGeneration == generation else { return }
            self.rootView.abandonFolderRenameForDismissal()
            self.window?.orderOut(nil)
            self.rootView.applyDeferredVisualState()
            self.window?.ignoresMouseEvents = false
            NSApp.presentationOptions.subtract(self.launcherPresentationOptions)
            self.dismissTask = nil
            self.dismissArmed = false
            self.onVisibilityChanged?()
        }
        onVisibilityChanged?()
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
        finishWindowUpdate()
    }

    private func finishWindowUpdate(cancelled: Bool = false) {
        guard let windowUpdateInterval else { return }
        if cancelled {
            signposter.endInterval("WindowUpdate", windowUpdateInterval, "cancelled")
        } else {
            signposter.endInterval("WindowUpdate", windowUpdateInterval)
        }
        self.windowUpdateInterval = nil
    }

    func toggleVisibility() {
        guard let window else { return }
        switch LauncherLayout.visibilityToggle(isVisible: window.isVisible, isDismissing: isDismissing) {
        case .show:
            show()
        case .hide:
            hide()
        }
    }

    func setReducesMotion(_ enabled: Bool) {
        rootView.setReducesMotion(enabled)
    }

    func hiddenApplications() -> [HiddenApplication] {
        rootView.hiddenApplications()
    }

    @discardableResult
    func restoreHiddenApplication(withKey key: String) -> Bool {
        rootView.restoreHiddenApplication(withKey: key)
    }

    func flushLayout() async {
        directoryWatcher?.stop()
        directoryWatcher = nil
        let scan = catalogLoadingTask
        scan?.cancel()
        await scan?.value
        catalogLoadingTask = nil
        let pendingSave = persistTask
        pendingSave?.cancel()
        await pendingSave?.value
        persistTask = nil
        guard persistableLayout else { return }
        do {
            try await layoutStore.save(rootView.layoutState)
            rootView.clearLayoutSaveError()
        } catch {
            reportLayoutSaveFailure(error)
        }
    }

    @discardableResult
    func reloadCatalogIfIdle() -> Bool {
        guard !isScanning else { return false }
        reloadCatalog()
        return true
    }

    @discardableResult
    func startWatchingCatalog() async -> Bool {
        let watcher = ApplicationDirectoryWatcher(
            onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.reloadCatalog() }
            },
            onRootChanged: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.startWatchingCatalog()
                }
            }
        )
        let roots = catalogRoots
        let started = await Task.detached(priority: .utility) {
            watcher.start(roots: roots)
        }.value
        guard started else { return false }
        directoryWatcher = watcher
        return true
    }

    func reloadCatalog() {
        catalogLoadingTask?.cancel()
        catalogReloadGeneration &+= 1
        let generation = catalogReloadGeneration
        isScanning = true
        cachedCandidates = []
        rootView.setCachedCatalogAvailable(false)
        rootView.setRescanVisible(false)
        rootView.setLayoutEditingEnabled(false, explanation: "正在扫描应用，暂时无法整理")
        rootView.setLoading(true)
        catalogLoadingTask = Task { [weak self] in
            guard let self else { return }
            let scanInterval = signposter.beginInterval("CatalogReload", id: signposter.makeSignpostID())
            defer {
                if Task.isCancelled {
                    signposter.endInterval("CatalogReload", scanInterval, "cancelled")
                } else {
                    signposter.endInterval("CatalogReload", scanInterval)
                }
                if catalogReloadGeneration == generation {
                    isScanning = false
                    catalogLoadingTask = nil
                    if Task.isCancelled {
                        if rootView.isCatalogEmpty {
                            rootView.noteScanCancelledWhileEmpty()
                        }
                        rootView.setLoading(false)
                        rootView.setLayoutEditingEnabled(false, explanation: "应用扫描已取消，请重新扫描")
                        rootView.setRescanVisible(true)
                    }
                }
            }
            if let cached = try? await catalogSnapshotStore.load(),
               !Task.isCancelled {
                let stored = (try? await layoutStore.load()) ?? LayoutState()
                guard !Task.isCancelled else { return }
                cachedCandidates = cached
                cachedLayout = stored
                rootView.setCachedCatalogAvailable(true)
            }
            #if DEBUG
            await waitForTestScanHoldRelease()
            guard !Task.isCancelled else { return }
            #endif
            let report = await AppCatalogScanner().scan(roots: self.catalogRoots)
            guard !Task.isCancelled else { return }
            await finishPendingLayoutSaves()
            guard !Task.isCancelled else { return }
            var persistable = true
            let stored: LayoutState
            do {
                stored = try await layoutStore.load() ?? LayoutState()
            } catch LayoutStoreIssue.unsupportedSchema {
                persistable = false
                stored = LayoutState()
            } catch {
                persistable = false
                stored = LayoutState()
            }
            guard !Task.isCancelled else { return }
            persistableLayout = persistable && report.canPersistReconciledLayout
            let base = LauncherLayout.layoutBaseForCatalogReload(memory: rootView.layoutState, stored: stored)
            let layout = LauncherLayout.reconcile(candidates: report.candidates, into: base)
            rootView.setCatalog(report.candidates, layout: layout)
            rootView.setLoading(false)
            let editingExplanation: String? = if !persistable {
                "布局文件无法读取，暂时无法整理；原文件已保留"
            } else if !report.canPersistReconciledLayout {
                "应用扫描不完整，暂时无法整理；请重新扫描"
            } else {
                nil
            }
            rootView.setLayoutEditingEnabled(persistableLayout, explanation: editingExplanation)
            rootView.setRescanVisible(persistable && !report.canPersistReconciledLayout)
            onCatalogLoaded?(report)
            onCatalogReloadFinished?(persistableLayout)
            if persistableLayout {
                schedulePersist(layout)
                do {
                    try await catalogSnapshotStore.save(report)
                } catch {
                    onCatalogSnapshotSaveFailed?(error)
                }
            }
        }
    }

    #if DEBUG
    // Debug-only. A test layout path is required so Release and normal launches ignore the hold file.
    private func waitForTestScanHoldRelease() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LAUNCHICON_TEST_LAYOUT_PATH"] != nil,
              let path = environment["LAUNCHICON_TEST_SCAN_HOLD_FILE"],
              !path.isEmpty else { return }
        let deadline = Date().addingTimeInterval(120)
        while FileManager.default.fileExists(atPath: path), Date() < deadline {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    #endif

    private func cancelScanAndUseCachedCatalog() {
        guard !cachedCandidates.isEmpty,
              isScanning || rootView.isCatalogEmpty || !persistableLayout else { return }
        catalogReloadGeneration &+= 1
        catalogLoadingTask?.cancel()
        catalogLoadingTask = nil
        isScanning = false
        persistableLayout = false
        rootView.setCachedCatalogAvailable(false)
        rootView.setCatalog(cachedCandidates, layout: LauncherLayout.reconcile(candidates: cachedCandidates, into: cachedLayout))
        rootView.setLoading(false)
        rootView.setLayoutEditingEnabled(false, explanation: "正在显示上次应用列表；重新扫描后可整理")
        rootView.setRescanVisible(true)
        onCatalogReloadFinished?(false)
    }

    /// Wait out a save that was still debouncing when the scan finished, including
    /// one scheduled while the previous save was in flight. A finished task is
    /// not awaited twice.
    private func finishPendingLayoutSaves() async {
        var waited: Int?
        while let pending = persistTask {
            let generation = persistGeneration
            if waited == generation { break }
            waited = generation
            await pending.value
        }
    }

    private func schedulePersist(_ state: LayoutState) {
        guard persistableLayout else { return }
        persistTask?.cancel()
        persistGeneration &+= 1
        persistTask = Task { [weak self, layoutStore] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                try await layoutStore.save(state)
                self?.rootView.clearLayoutSaveError()
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { self?.reportLayoutSaveFailure(error) }
            }
        }
    }

    private func reportLayoutSaveFailure(_ error: Error) {
        onLayoutSaveFailed?(error)
        rootView.showLayoutSaveError(error)
    }

    private func launch(_ candidate: AppCandidate) {
        // mouseUp can arrive after the fade starts, or after orderOut. The
        // press must not open the app once the launcher is no longer active.
        guard LauncherLayout.shouldAcceptPointerActivation(
            isDismissing: isDismissing,
            isVisible: window?.isVisible == true
        ) else { return }
        let key = candidate.deduplicationKey
        // A second click on the same app is ignored while it is opening.
        // A different app must still launch; the old single task dropped it.
        guard launchesInFlight[key] == nil else { return }
        launchesInFlight[key] = candidate
        rootView.hideToast(animated: false)
        rootView.setLaunchPending(candidate)
        // show() bumps this. A hotkey that cancels the dismiss animation and
        // brings the launcher back must not be undone when this wait ends.
        let launchGeneration = dismissGeneration
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.launchesInFlight[key] = nil
                let nextKey = LauncherLayout.launchHighlightChange(
                    finishedKey: key,
                    highlightedKey: self.rootView.highlightedLaunchKey,
                    remainingKeys: Set(self.launchesInFlight.keys)
                )
                if case .show(let highlighted) = nextKey {
                    let next = highlighted.flatMap { self.launchesInFlight[$0] }
                    self.rootView.setLaunchPending(next)
                }
            }
            do {
                try await WorkspaceAppLauncher().launch(candidate.canonicalURL)
                try await Task.sleep(nanoseconds: 120_000_000)
                if LauncherLayout.shouldDismissAfterSuccessfulLaunch(
                    hidesAfterLaunch: self.hidesAfterLaunch,
                    launchGeneration: launchGeneration,
                    currentGeneration: self.dismissGeneration
                ) {
                    self.hide()
                }
            } catch is CancellationError {
                return
            } catch {
                onLaunchFailed?(candidate, error)
                rootView.showLaunchError(for: candidate, error: error)
            }
        }
    }
}
private final class LauncherPanel: NSPanel {
    var dismissHandler: (() -> Void)?
    /// True while the window is still visible but interaction is already off.
    var keyboardSuspended: () -> Bool = { false }
    /// False while the launcher is fading or already ordered out. A mouseUp
    /// from a press that started earlier must not open an icon or Settings.
    var acceptsPointerActivation: () -> Bool = { true }
    var searchHandler: (() -> Void)?
    var pageHandler: ((Int) -> Void)?
    /// Page Up/Down while search is showing. Return true to consume the key
    /// instead of turning a grid page.
    var verticalPageHandler: ((Int) -> Bool)?
    var escapeHandler: (() -> Bool)?
    var settingsHandler: (() -> Void)?
    /// Runs before `super` so a half-typed folder name is abandoned before
    /// AppKit commits the field editor.
    var resignKeyHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if escapeHandler?() == true { return }
        dismissHandler?()
    }

    override func resignKey() {
        resignKeyHandler?()
        super.resignKey()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Consume the shortcut. Returning false would let the main menu open
        // Settings or quit during the fade.
        if keyboardSuspended() { return true }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "," {
            settingsHandler?()
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            searchHandler?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !keyboardSuspended() else { return }
        guard !(firstResponder is NSTextView) else {
            super.keyDown(with: event)
            return
        }

        if let button = firstResponder as? NSButton,
           (event.keyCode == 36 || event.characters == " ") {
            button.performClick(nil)
            return
        }

        switch event.keyCode {
        case 123: // Left arrow pages. It does not walk icons.
            pageHandler?(-1)
        case 124:
            pageHandler?(1)
        case 116: // Page Up. Search scrolls; the grid still pages.
            if verticalPageHandler?(-1) != true {
                pageHandler?(-1)
            }
        case 121:
            if verticalPageHandler?(1) != true {
                pageHandler?(1)
            }
        default:
            if let deletion = launcherSearchDeletion(for: event),
               (contentView as? LauncherRootView)?.deleteSearch(deletion) == true {
                return
            }
            if (contentView as? LauncherRootView)?.beginSearch(with: event) != true {
                super.keyDown(with: event)
            }
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if keyboardSuspended(), event.type == .keyDown || event.type == .keyUp {
            return
        }
        // `ignoresMouseEvents` does not stop a click that already went down.
        // Drop a new press so it cannot start. Left-drag and left-up still
        // go through: a drag session ends on mouseUp, and launch / open /
        // Settings refuse that release. Scroll wheels are not button events.
        if !acceptsPointerActivation(), Self.shouldDropInactivePointerEvent(event) {
            return
        }
        if event.type == .keyDown,
           event.keyCode == 53,
           let rootView = contentView as? LauncherRootView {
            // Marked pinyin has to reach the field editor. Swallowing Escape
            // here used to clear the query or dismiss instead of unmarking.
            if rootView.inputMethodHasMarkedText() {
                let searchWasComposing = rootView.searchFieldHasMarkedText()
                rootView.escapeDeliveredToInputMethod = true
                super.sendEvent(event)
                rootView.escapeDeliveredToInputMethod = false
                // Unmarking does not go through the field's text-change
                // callback, so the old pinyin would keep filtering.
                if searchWasComposing {
                    rootView.noteSearchCompositionEnded()
                }
                return
            }
            if rootView.handleEscape() {
                return
            }
        }
        if event.type == .leftMouseDown {
            (contentView as? LauncherRootView)?.beginClick()
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp,
           let rootView = contentView as? LauncherRootView,
           !rootView.didConsumeClick,
           rootView.shouldDismiss(at: event.locationInWindow) {
            dismissHandler?()
        }
    }

    private static func shouldDropInactivePointerEvent(_ event: NSEvent) -> Bool {
        let kind: LauncherLayout.LauncherInactivePointerEvent
        switch event.type {
        case .leftMouseDown:
            kind = .press
        case .leftMouseDragged:
            kind = .leftDrag
        case .leftMouseUp:
            kind = .leftRelease
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            kind = .otherButton
        default:
            return false
        }
        return !LauncherLayout.shouldDeliverPointerEventWhileInactive(kind)
    }
}

private let layoutItemPasteboardType = NSPasteboard.PasteboardType("com.sunzheng.LaunchIcon.layout-item")

private struct DraggedLayoutItem: Codable {
    var itemID: UUID
    var folderID: UUID?
}

struct HiddenApplication: Equatable {
    let key: String
    let displayName: String
}

private struct ReorderSlideSignature: Equatable {
    var collectionID: ObjectIdentifier
    var slots: [Int?]
}

private enum PresentedItem: Hashable {
    case app(UUID, AppCandidate)
    case folder(LauncherFolder, [AppCandidate])

    var id: UUID {
        switch self {
        case .app(let id, _): return id
        case .folder(let folder, _): return folder.id
        }
    }
}

@MainActor
private final class LauncherRootView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate {
    var onCandidateSelected: ((AppCandidate) -> Void)?
    var onLayoutChanged: ((LayoutState) -> Void)?
    var onReloadRequested: (() -> Void)?
    var onUseCachedCatalogRequested: (() -> Void)?
    var onDiagnosticEvent: ((String) -> Void)?
    var onSettingsRequested: (() -> Void)?
    /// Set while Escape is being delivered so a marked range can unmark
    /// without also clearing search or closing the launcher.
    var escapeDeliveredToInputMethod = false
    private(set) var layoutState = LayoutState()

    private let searchField = NSSearchField()
    private let settingsButton = LauncherChromeButton()
    private let clearButton = NSButton(title: "×", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let readOnlyStatusLabel = NSTextField(labelWithString: "")
    private let readOnlyStatusRow = NSStackView()
    private let rescanButton = LauncherChromeButton(title: "重新扫描", target: nil, action: nil)
    private let readOnlyCachedButton = LauncherChromeButton(title: "使用上次应用列表", target: nil, action: nil)
    private let messageLabel = NSTextField(wrappingLabelWithString: "正在准备应用…")
    private let scanSkeleton = ScanSkeletonView()
    private let cachedCatalogButton = LauncherChromeButton(title: "使用上次应用列表", target: nil, action: nil)
    private let emptyStateView = NSStackView()
    private let emptyStateIcon = NSImageView()
    private let emptyStateTitle = NSTextField(labelWithString: "未找到可用的应用")
    private let emptyStateDetail = NSTextField(wrappingLabelWithString: "请确认应用位于 Applications 文件夹，然后重新扫描。")
    private let emptyStateReloadButton = LauncherChromeButton(title: "重新扫描", target: nil, action: nil)
    private let emptyStateCachedButton = LauncherChromeButton(title: "使用上次应用列表", target: nil, action: nil)
    private let toastView = NSVisualEffectView()
    private let toastLabel = NSTextField(labelWithString: "")
    private let toastCloseButton = NSButton(title: "", target: nil, action: nil)
    private let contentCard = NSView()
    private let gridViewport = NSView()
    private var activeHost: PagingPageHost
    private var stagingHost: PagingPageHost
    /// True while the window is fading out. Grid paging must not keep turning.
    var launcherIsDismissing: () -> Bool = { false }

    /// The launcher is on screen and not fading. A mouseUp, VoiceOver press,
    /// or button action uses this before opening an app, folder, or Settings.
    func acceptsPointerActivation() -> Bool {
        LauncherLayout.shouldAcceptPointerActivation(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        )
    }

    private var activeCollectionView: PagingCollectionView { activeHost.collectionView }
    private var stagingCollectionView: PagingCollectionView { stagingHost.collectionView }
    private let searchScrollView = LauncherScrollView()
    private let searchCollectionView = PagingCollectionView()
    private let pageIndicator = PageIndicatorView()
    private let footerControls = NSStackView()
    private let dragHintLabel = NSTextField(labelWithString: "拖拽整理")
    private let navigationHintLabel = NSTextField(labelWithString: "")
    private let previousPageButton = PagingArrowButton(symbolName: "chevron.left", accessibilityLabel: "上一页")
    private let nextPageButton = PagingArrowButton(symbolName: "chevron.right", accessibilityLabel: "下一页")
    private let folderOverlay = FolderOverlayView()
    private let desktopBackgroundView = NSView()
    private var backgroundLoadTask: Task<Void, Never>?
    private var desktopBackgroundURL: URL?
    /// Thumbnail decoded while the launcher was fading. Applied once the fade
    /// is over. Nil is a real result: the decode can fail and clear the image.
    private var deferredDesktopBackground: CGImage?
    private var desktopBackgroundWaitsForLauncher = false
    private var allCandidates: [AppCandidate] = []
    private var catalogByKey: [String: AppCandidate] = [:]
    private var searchableApps: [AppCandidate] = []
    private var searchableAppIDsByKey: [String: UUID] = [:]
    private var appSearchIndex = AppSearchIndex(candidates: [])
    private var appSearchIndexBuildTask: Task<AppSearchIndex, Never>?
    private var appSearchIndexGeneration = 0
    private var searchPresentedItems: [PresentedItem] = []
    private var searchScrollQuery: String?
    /// Query the result list was last built from, including marked pinyin.
    /// `stringValue` omits that mark, so the two diverge when composing.
    private var searchQueryAppliedToResults = ""
    /// The replacement search index arrived while the launcher was fading or
    /// already gone. The query is unchanged, so the field-editor refilter
    /// will not reload. Apply it once the launcher is up again.
    private var searchIndexRefreshWaitsForLauncher = false
    /// Shift-Tab from the search field was deferred a turn, and that turn
    /// landed while the launcher was fading or already gone. Resigning then
    /// would reload the list. Move focus once the launcher is up again.
    private var searchBacktabWaitsForLauncher = false
    /// The catalog model changed while the launcher was fading or already
    /// gone. The grid and search list still show the previous presentation.
    private var catalogPresentationWaitsForLauncher = false
    private var deferredCatalogPresentation: DeferredCatalogPresentation?

    /// What was on screen when the first deferred catalog change arrived.
    /// Later scans keep this snapshot so focus is restored from the tiles
    /// the user still sees, while `layoutState` is already the newest model.
    private struct DeferredCatalogPresentation {
        var previousEntries: [LauncherEntry]
        var previouslyOpenedFolder: LauncherFolder?
        var closingFolder: UUID?
        var preservedGridFocus: UUID?
        var preservedFolderMember: (id: UUID, index: Int)?
        var catalogChanged: Bool
    }
    /// Query captured when dismiss starts. A clear click that finishes during
    /// the fade is written back to this instead of emptying the field.
    private var frozenSearchFieldText: (committed: String, editing: String?)?
    private var isRestoringSearchField = false
    /// Resign-key removes marked pinyin itself. That edit must not be treated
    /// as a clear click and written back.
    private var isDiscardingSearchComposition = false
    private var launchingID: AppCandidate.ID?
    /// The highlight id changed while the launcher was fading or already gone.
    /// Reloading then jumps the tiles under the fade.
    private var launchHighlightWaitsForLauncher = false
    private var pageSize = LauncherLayout.pageCapacity
    private var currentPage = 0
    private var isPageTransitioning = false
    private var pageTransitionGeneration = 0
    private var transitionTargetPage: Int?
    private var queuedPage: Int?
    private var pageTurnGridSlot: Int?
    /// The icon that had the keyboard when this turn started. Completion must
    /// not pull focus back if the user has since moved to the field or a button.
    private weak var pageTurnFocusedTile: AppGridTileView?
    private var stagingPage: Int?
    private var openedFolderID: UUID?
    /// True only while the alias alert's modal loop is running. Dismiss
    /// aborts that loop; Save has already cleared this and must be kept.
    private var isPromptingForAlias = false
    /// The icon menu passed to `popUpContextMenu`, if that call has not
    /// returned. Nil for the status-item menu.
    private var trackedIconContextMenu: NSMenu?
    /// True while dismiss is closing that menu. The tracking loop must not
    /// treat the cancel as a chosen row.
    private var isCancellingIconContextMenu = false
    private var lastViewportSize: CGSize = .zero
    private var isPagingGesture = false
    /// Reduced motion changed while the launcher fade was holding a finger
    /// drag that had already pulled the pages. Rest them once that hold ends,
    /// if the drag is still in hand and motion is still reduced.
    private var pageDragRestWaitsForLauncher = false
    private(set) var didConsumeClick = false
    private var dragPreview: (ref: LayoutItemRef, frame: CGRect, image: NSImage)?
    /// The drag image is a still picture. `showsLift` is the scale and shadow
    /// drawn when the drag started. Reduced motion drops that picture without
    /// moving the drag frame. Turning motion back on does not add a lift.
    private struct ActiveDragLift {
        weak var session: NSDraggingSession?
        var sourceImage: NSImage
        var sourceSize: CGSize
        var showsLift: Bool
    }
    private var activeDragLift: ActiveDragLift?
    /// Reduced motion changed while the launcher fade was holding the drag
    /// image. The lift is dropped once that hold ends, if the drag is still up.
    private var dragLiftDropWaitsForLauncher = false
    private weak var dropTargetTile: AppGridTileView?
    private weak var dragSourceTile: AppGridTileView?
    private var reorderSlideSignature: ReorderSlideSignature?
    private var pendingMergeAnimation: (source: CGRect?, target: CGRect?, image: NSImage, folderID: UUID?, createdFolder: Bool)?
    private weak var mergeAnimationView: NSImageView?
    /// Bumped when a flight is frozen or removed, so its completion does not
    /// take the image away after the fade asked to keep the current frame.
    private var mergeFlightGeneration = 0
    /// The fade asked to stop the flight. A flight that has not started stays
    /// in `pendingMergeAnimation` until the launcher is up, or is dropped once
    /// the window is hidden. A flight that already started stays on screen
    /// until that same moment, then the image is removed.
    private var mergeFlightWaitsForLauncher = false
    /// The fade pinned an opening or closing folder panel, or the grid
    /// behind it. Applied once the launcher is up, or once the window is hidden.
    private var folderChromeWaitsForLauncher = false
    /// Reduced motion changed while the fade was holding the backdrop.
    /// Applied with the folder chrome, once that hold ends.
    private var folderBackdropStyleWaitsForLauncher = false
    private let mergeFlightDuration: TimeInterval = 0.34
    private var folderLandingGeneration = 0
    /// Every landing that has not committed yet. A later tile must not drop
    /// an earlier one: that spring would keep playing under the fade. Weak:
    /// the grid owns the layer. Cleared once the final opacity and scale
    /// are applied.
    private struct HeldFolderLanding {
        weak var layer: CALayer?
        var generation: Int
    }
    private var heldFolderLandings: [HeldFolderLanding] = []
    /// A reveal's timer asked to finish during the fade. Applied once the
    /// launcher is up, or once the window is hidden.
    private var folderLandingWaitsForLauncher = false
    private var iconPrefetchTask: Task<Void, Never>?
    private let iconSignposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.sunzheng.LaunchIcon",
        category: "Performance"
    )
    private var toastDismissTask: Task<Void, Never>?
    private var toastGeneration = 0
    /// Toast requested while the launcher was fading or hidden. The newest
    /// request wins. Nil help is a real value.
    private var deferredToast: DeferredToast?
    private var toastWaitsForLauncher = false
    /// The visible toast was asked to leave during the fade. Applied once
    /// the launcher is up, unless a newer toast replaces it.
    private var toastHideWaitsForLauncher = false
    /// A fade-in or fade-out was pinned for the launcher fade. `.shown` snaps
    /// back to opaque. `.hidden` removes the bubble without replaying.
    private var heldToastFade: HeldToastFade?
    private var isCatalogLoading = true
    private var hasCachedCatalog = false
    private var showsRescanButton = false
    private var presentsCancelledEmptyCatalog = false
    private var isLayoutEditingEnabled = false
    private var layoutEditingExplanation: String?
    private var layoutSaveFailed = false
    private var reducesMotionOverride = false
    private var appliedReducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var searchChromeVisible = false
    private var searchChromeGeneration = 0
    /// The fade pinned a search/grid crossfade that had already started.
    /// Applied once the launcher is up, or once the window is hidden.
    private var searchChromeWaitsForLauncher = false
    /// The fade pinned a grid fade-in that follows a dissolved folder.
    /// Applied once the launcher is up, or once the window is hidden.
    private var dissolvedGridFadeWaitsForLauncher = false
    /// Layers whose launch pulse was pinned mid-scale. Reset once the
    /// launcher is up, or once the window is hidden, so the icon is not
    /// left small. The pulse is not replayed.
    private var heldLaunchFeedbackLayers: [CALayer] = []

    private var prefersReducedMotion: Bool {
        reducesMotionOverride || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var isCatalogEmpty: Bool { allCandidates.isEmpty }
    private var isSearching: Bool {
        !currentSearchQuery().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Prefer the field editor while it exists so unfinished pinyin counts.
    private func currentSearchQuery() -> String {
        LauncherLayout.searchQuery(
            committed: searchField.stringValue,
            editing: searchField.currentEditor()?.string
        )
    }
    override var acceptsFirstResponder: Bool { true }

    private func displayName(for candidate: AppCandidate) -> String {
        layoutState.appAliases[candidate.deduplicationKey] ?? candidate.displayName
    }

    override func accessibilityChildren() -> [Any]? {
        if openedFolderID != nil { return [folderOverlay] }
        return super.accessibilityChildren()
    }

    override init(frame frameRect: NSRect) {
        activeHost = PagingPageHost()
        stagingHost = PagingPageHost()
        activeHost.collectionView.collectionViewLayout = Self.makeGridLayout()
        stagingHost.collectionView.collectionViewLayout = Self.makeGridLayout()
        searchCollectionView.collectionViewLayout = Self.makeGridLayout()
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.12, alpha: 1).cgColor

        desktopBackgroundView.wantsLayer = true
        desktopBackgroundView.layer?.contentsGravity = .resizeAspectFill
        desktopBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(desktopBackgroundView)

        let effect = NSVisualEffectView(frame: .zero)
        effect.material = .fullScreenUI
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let contrastOverlay = NSView()
        contrastOverlay.wantsLayer = true
        contrastOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        contrastOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contrastOverlay)

        let card = contentCard
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        searchField.placeholderString = "搜索应用"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.focusRingType = .none
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 14, weight: .regular)
        searchField.alignment = .center
        searchField.setAccessibilityLabel("搜索应用")
        searchField.setAccessibilityHelp("按应用名称或 Bundle ID 搜索")
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let searchChrome = NSVisualEffectView(frame: .zero)
        searchChrome.material = .popover
        searchChrome.blendingMode = .withinWindow
        searchChrome.state = .active
        searchChrome.wantsLayer = true
        searchChrome.layer?.cornerRadius = LauncherLayout.searchFieldCornerRadius
        searchChrome.layer?.cornerCurve = .continuous
        searchChrome.layer?.masksToBounds = true
        searchChrome.layer?.borderWidth = 0.5
        searchChrome.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        searchChrome.setAccessibilityElement(false)
        searchChrome.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(searchChrome)
        searchChrome.addSubview(searchField)

        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        settingsButton.imagePosition = .imageOnly
        settingsButton.bezelStyle = .circular
        settingsButton.toolTip = "设置"
        settingsButton.setAccessibilityLabel("设置")
        settingsButton.setAccessibilityHelp("打开 LaunchIcon 设置")
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.onInsertTab = { [weak self] in
            self?.focusFirstVisibleSearchResult() ?? false
        }
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(settingsButton)

        readOnlyStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        readOnlyStatusLabel.textColor = .labelColor
        readOnlyStatusLabel.alignment = .center
        readOnlyStatusLabel.lineBreakMode = .byTruncatingTail
        readOnlyStatusLabel.isHidden = true
        readOnlyStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        readOnlyStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rescanButton.bezelStyle = .rounded
        rescanButton.controlSize = .small
        rescanButton.isHidden = true
        rescanButton.target = self
        rescanButton.action = #selector(reloadCatalog)
        rescanButton.setAccessibilityHelp("重新扫描应用并恢复可整理的列表")
        rescanButton.translatesAutoresizingMaskIntoConstraints = false
        readOnlyCachedButton.bezelStyle = .rounded
        readOnlyCachedButton.controlSize = .small
        readOnlyCachedButton.isHidden = true
        readOnlyCachedButton.target = self
        readOnlyCachedButton.action = #selector(useCachedCatalog)
        readOnlyCachedButton.setAccessibilityHelp("使用本机上次完整扫描的应用列表；整理功能暂不可用")
        readOnlyCachedButton.translatesAutoresizingMaskIntoConstraints = false
        readOnlyStatusRow.orientation = .horizontal
        readOnlyStatusRow.alignment = .centerY
        readOnlyStatusRow.spacing = 8
        readOnlyStatusRow.translatesAutoresizingMaskIntoConstraints = false
        readOnlyStatusRow.addArrangedSubview(readOnlyStatusLabel)
        readOnlyStatusRow.addArrangedSubview(rescanButton)
        readOnlyStatusRow.addArrangedSubview(readOnlyCachedButton)
        card.addSubview(readOnlyStatusRow)

        clearButton.isHidden = true
        countLabel.isHidden = true
        countLabel.setAccessibilityElement(false)

        gridViewport.wantsLayer = true
        gridViewport.layer?.masksToBounds = true
        gridViewport.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(gridViewport)

        for collectionView in [activeCollectionView, stagingCollectionView, searchCollectionView] {
            collectionView.dataSource = self
            collectionView.delegate = self
            collectionView.dragSessionEndedHandler = { [weak self] in self?.finishItemDragSession() }
            collectionView.dragExitedHandler = { [weak self] in self?.clearDropHighlightIfAllowed() }
            collectionView.isSelectable = false
            collectionView.setAccessibilityEnabled(true)
            collectionView.backgroundColors = [.clear]
            collectionView.wantsLayer = true
            collectionView.registerForDraggedTypes([layoutItemPasteboardType])
            collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
            collectionView.register(AppGridItem.self, forItemWithIdentifier: AppGridItem.identifier)
        }
        let launcherIsDismissing = { [weak self] in self?.launcherIsDismissing() ?? false }
        for collectionView in [activeCollectionView, stagingCollectionView] {
            collectionView.dragChangedHandler = { [weak self] distance in self?.updatePageDrag(distance) }
            collectionView.dragEndedHandler = { [weak self] direction in self?.finishPageDrag(direction) }
            collectionView.isDismissing = launcherIsDismissing
        }
        // Search is not a paging grid. A scroll gesture that started before
        // the fade still arrives here and would move the result list.
        searchCollectionView.isDismissing = launcherIsDismissing
        searchScrollView.isDismissing = launcherIsDismissing
        searchScrollView.reducesMotion = { [weak self] in self?.prefersReducedMotion ?? false }
        searchScrollView.isWindowVisible = { [weak self] in self?.window?.isVisible == true }
        gridViewport.addSubview(activeHost)
        gridViewport.addSubview(stagingHost)
        scanSkeleton.translatesAutoresizingMaskIntoConstraints = false
        scanSkeleton.isHidden = true
        gridViewport.addSubview(scanSkeleton)
        activeHost.registerForDraggedTypes([layoutItemPasteboardType])
        stagingHost.registerForDraggedTypes([layoutItemPasteboardType])
        // Closures stay on the host object while active/staging roles swap.
        // Each host must drop onto its own grid; resolving the role at drop
        // time sends the event to whichever page is parked after the swap.
        let restingHost = activeHost
        let incomingHost = stagingHost
        restingHost.performDrop = { [weak self, weak restingHost] info in
            guard let self, let restingHost else { return false }
            return self.handleHostDrop(info, on: restingHost.collectionView)
        }
        incomingHost.performDrop = { [weak self, weak incomingHost] info in
            guard let self, let incomingHost else { return false }
            return self.handleHostDrop(info, on: incomingHost.collectionView)
        }
        for host in [restingHost, incomingHost] {
            host.acceptsLayoutDrop = { [weak self] in
                LauncherLayout.shouldAcceptLayoutDrop(isDismissing: self?.launcherIsDismissing() ?? false)
            }
        }
        stagingHost.isHidden = true
        stagingHost.alphaValue = 0

        searchScrollView.wantsLayer = true
        searchScrollView.drawsBackground = false
        searchScrollView.hasVerticalScroller = true
        searchScrollView.autohidesScrollers = true
        searchScrollView.scrollerStyle = .overlay
        searchScrollView.borderType = .noBorder
        searchScrollView.documentView = searchCollectionView
        searchScrollView.translatesAutoresizingMaskIntoConstraints = false
        searchScrollView.isHidden = true
        card.addSubview(searchScrollView)

        pageIndicator.onPageSelected = { [weak self] page in
            guard let self, self.acceptsPointerActivation() else { return }
            self.showPage(page)
        }
        pageIndicator.onPageMove = { [weak self] direction in self?.movePage(by: direction) }
        let pageByKey: (Int) -> Void = { [weak self] direction in
            self?.movePage(by: direction)
        }
        let searchPageByKey = { [weak self] (direction: Int) in
            self?.scrollSearchResults(byPage: direction) ?? false
        }
        previousPageButton.onPage = pageByKey
        nextPageButton.onPage = pageByKey
        for (button, direction) in [(previousPageButton, -1), (nextPageButton, 1)] {
            button.acceptsDraggedItem = { [weak self] info in
                guard let self, self.isLayoutEditingEnabled,
                      !self.isSearching, self.openedFolderID == nil,
                      LauncherLayout.shouldAcceptLayoutDrop(isDismissing: self.launcherIsDismissing()),
                      case .topLevel = self.draggedItem(from: info) else { return false }
                return true
            }
            button.onDragHover = { [weak self] in self?.movePage(by: direction) }
        }
        previousPageButton.launcherIsDismissing = launcherIsDismissing
        nextPageButton.launcherIsDismissing = launcherIsDismissing
        let motionIsReduced = { [weak self] in self?.prefersReducedMotion ?? false }
        previousPageButton.reducesMotion = motionIsReduced
        nextPageButton.reducesMotion = motionIsReduced
        settingsButton.onPage = pageByKey
        previousPageButton.onVerticalPage = searchPageByKey
        nextPageButton.onVerticalPage = searchPageByKey
        settingsButton.onVerticalPage = searchPageByKey
        pageIndicator.onVerticalPage = searchPageByKey
        let typeToSearch = { [weak self] (event: NSEvent) in self?.beginSearch(with: event) ?? false }
        settingsButton.onType = typeToSearch
        previousPageButton.onType = typeToSearch
        nextPageButton.onType = typeToSearch
        pageIndicator.onType = typeToSearch
        // Empty catalog and incomplete scans show these instead of icons.
        // Same page and typing keys as Settings; Space and Return still click.
        for button in [cachedCatalogButton, emptyStateReloadButton, emptyStateCachedButton, rescanButton, readOnlyCachedButton] {
            button.onPage = pageByKey
            button.onVerticalPage = searchPageByKey
            button.onType = typeToSearch
        }
        let deleteSearchCharacter = { [weak self] (deletion: LauncherSearchDeletion) in
            self?.deleteSearch(deletion) ?? false
        }
        settingsButton.onDelete = deleteSearchCharacter
        previousPageButton.onDelete = deleteSearchCharacter
        nextPageButton.onDelete = deleteSearchCharacter
        pageIndicator.onDelete = deleteSearchCharacter
        for button in [cachedCatalogButton, emptyStateReloadButton, emptyStateCachedButton, rescanButton, readOnlyCachedButton] {
            button.onDelete = deleteSearchCharacter
        }
        pageIndicator.translatesAutoresizingMaskIntoConstraints = false
        for label in [dragHintLabel, navigationHintLabel] {
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        footerControls.orientation = .horizontal
        footerControls.alignment = .centerY
        footerControls.distribution = .fill
        footerControls.spacing = 14
        footerControls.translatesAutoresizingMaskIntoConstraints = false
        footerControls.setAccessibilityElement(false)
        footerControls.addArrangedSubview(dragHintLabel)
        footerControls.addArrangedSubview(pageIndicator)
        footerControls.addArrangedSubview(navigationHintLabel)
        card.addSubview(footerControls)

        previousPageButton.target = self
        previousPageButton.action = #selector(showPreviousPage)
        previousPageButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(previousPageButton)

        nextPageButton.target = self
        nextPageButton.action = #selector(showNextPage)
        nextPageButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(nextPageButton)

        folderOverlay.isHidden = true
        folderOverlay.translatesAutoresizingMaskIntoConstraints = false
        folderOverlay.onClose = { [weak self] in self?.closeFolder() }
        folderOverlay.acceptsPointerActivation = { [weak self] in
            self?.acceptsPointerActivation() ?? false
        }
        folderOverlay.onActivateApp = { [weak self] candidate in self?.onCandidateSelected?(candidate) }
        folderOverlay.onDrop = { [weak self] drop in
            guard let self else { return false }
            return self.applyDrop(self.placingUnspecifiedFolderExtraction(drop))
        }
        folderOverlay.acceptsDrop = { [weak self] in
            LauncherLayout.shouldAcceptLayoutDrop(isDismissing: self?.launcherIsDismissing() ?? false)
        }
        folderOverlay.followLauncherDismissing { [weak self] in
            self?.launcherIsDismissing() ?? false
        }
        folderOverlay.followContentScrollMotion(
            reducesMotion: { [weak self] in self?.prefersReducedMotion ?? false },
            isWindowVisible: { [weak self] in self?.window?.isVisible == true }
        )
        folderOverlay.onRename = { [weak self] name in
            self?.renameOpenFolder(name) ?? name
        }
        folderOverlay.onTabToMembers = { [weak self] in
            guard let self,
                  let first = self.presentedItems(for: self.folderOverlay.collectionView).first else { return false }
            return self.focusPresentedItem(id: first.id, in: self.folderOverlay.collectionView)
        }
        folderOverlay.onBacktabFromTitle = { [weak self] in
            guard let self,
                  self.presentedItems(for: self.folderOverlay.collectionView).last != nil else { return false }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.openedFolderID != nil else { return }
                // A renamed title reloads the folder before focus returns.
                // The tile that was on screen is gone after that reload.
                if self.folderOverlay.isEditingTitle {
                    _ = self.window?.makeFirstResponder(self)
                }
                guard let last = self.presentedItems(for: self.folderOverlay.collectionView).last else { return }
                _ = self.focusPresentedItem(id: last.id, in: self.folderOverlay.collectionView)
            }
            return true
        }
        folderOverlay.collectionView.dataSource = self
        folderOverlay.collectionView.delegate = self
        folderOverlay.collectionView.dragSessionEndedHandler = { [weak self] in self?.finishItemDragSession() }
        folderOverlay.collectionView.dragExitedHandler = { [weak self] in self?.clearDropHighlightIfAllowed() }
        folderOverlay.collectionView.isSelectable = false
        folderOverlay.collectionView.setAccessibilityEnabled(true)
        folderOverlay.collectionView.backgroundColors = [.clear]
        folderOverlay.collectionView.registerForDraggedTypes([layoutItemPasteboardType])
        folderOverlay.collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        folderOverlay.collectionView.register(AppGridItem.self, forItemWithIdentifier: AppGridItem.identifier)
        folderOverlay.collectionView.collectionViewLayout = Self.makeFolderLayout()
        card.addSubview(folderOverlay)

        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 15, weight: .medium)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(messageLabel)

        cachedCatalogButton.bezelStyle = .rounded
        cachedCatalogButton.controlSize = .large
        cachedCatalogButton.isHidden = true
        cachedCatalogButton.target = self
        cachedCatalogButton.action = #selector(useCachedCatalog)
        cachedCatalogButton.setAccessibilityHelp("取消当前扫描，使用本机上次完整扫描的应用列表；整理功能暂不可用")
        cachedCatalogButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cachedCatalogButton)
        scanSkeleton.actionView = cachedCatalogButton

        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 10
        emptyStateView.setAccessibilityElement(false)
        emptyStateView.isHidden = true
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        emptyStateIcon.image = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 34, weight: .regular))
        emptyStateIcon.contentTintColor = .secondaryLabelColor
        emptyStateIcon.setAccessibilityHidden(true)

        emptyStateTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        emptyStateTitle.alignment = .center

        emptyStateDetail.font = .systemFont(ofSize: 13, weight: .regular)
        emptyStateDetail.textColor = .secondaryLabelColor
        emptyStateDetail.alignment = .center
        emptyStateDetail.maximumNumberOfLines = 2

        emptyStateReloadButton.bezelStyle = .rounded
        emptyStateReloadButton.controlSize = .large
        emptyStateReloadButton.target = self
        emptyStateReloadButton.action = #selector(reloadCatalog)
        emptyStateReloadButton.setAccessibilityHelp("重新扫描标准 Applications 文件夹")

        emptyStateCachedButton.bezelStyle = .rounded
        emptyStateCachedButton.controlSize = .large
        emptyStateCachedButton.isHidden = true
        emptyStateCachedButton.target = self
        emptyStateCachedButton.action = #selector(useCachedCatalog)
        emptyStateCachedButton.setAccessibilityHelp("使用本机上次完整扫描的应用列表；整理功能暂不可用")

        for view in [emptyStateIcon, emptyStateTitle, emptyStateDetail, emptyStateReloadButton, emptyStateCachedButton] {
            emptyStateView.addArrangedSubview(view)
        }
        card.addSubview(emptyStateView)

        toastView.material = .popover
        toastView.blendingMode = .withinWindow
        toastView.state = .active
        toastView.wantsLayer = true
        toastView.layer?.cornerRadius = 15
        toastView.layer?.borderWidth = 0.5
        toastView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        toastView.setAccessibilityElement(true)
        toastView.setAccessibilityRole(.group)
        toastView.isHidden = true
        toastView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(toastView)

        toastLabel.font = .systemFont(ofSize: 13, weight: .medium)
        toastLabel.textColor = .labelColor
        toastLabel.lineBreakMode = .byTruncatingTail
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastView.addSubview(toastLabel)

        toastCloseButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "关闭提示"
        )
        toastCloseButton.imagePosition = .imageOnly
        toastCloseButton.isBordered = false
        toastCloseButton.contentTintColor = .secondaryLabelColor
        toastCloseButton.setAccessibilityLabel("关闭提示")
        toastCloseButton.target = self
        toastCloseButton.action = #selector(closeToast)
        toastCloseButton.translatesAutoresizingMaskIntoConstraints = false
        toastView.addSubview(toastCloseButton)

        NSLayoutConstraint.activate([
            desktopBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            desktopBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            desktopBackgroundView.topAnchor.constraint(equalTo: topAnchor),
            desktopBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            contrastOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            contrastOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            contrastOverlay.topAnchor.constraint(equalTo: topAnchor),
            contrastOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchChrome.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            searchChrome.topAnchor.constraint(equalTo: card.topAnchor, constant: 34),
            searchChrome.widthAnchor.constraint(equalToConstant: LauncherLayout.searchFieldWidth),
            searchChrome.heightAnchor.constraint(equalToConstant: LauncherLayout.searchFieldHeight),
            searchField.leadingAnchor.constraint(equalTo: searchChrome.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchChrome.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchChrome.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            settingsButton.leadingAnchor.constraint(equalTo: searchChrome.trailingAnchor, constant: 10),
            settingsButton.centerYAnchor.constraint(equalTo: searchChrome.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 38),
            settingsButton.heightAnchor.constraint(equalToConstant: 38),
            readOnlyStatusRow.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            readOnlyStatusRow.topAnchor.constraint(equalTo: searchChrome.bottomAnchor, constant: 8),
            readOnlyStatusRow.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 40),
            readOnlyStatusRow.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -40),
            gridViewport.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 96),
            gridViewport.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -96),
            gridViewport.topAnchor.constraint(equalTo: searchChrome.bottomAnchor, constant: 28),
            gridViewport.bottomAnchor.constraint(equalTo: footerControls.topAnchor, constant: -18),
            scanSkeleton.leadingAnchor.constraint(equalTo: gridViewport.leadingAnchor),
            scanSkeleton.trailingAnchor.constraint(equalTo: gridViewport.trailingAnchor),
            scanSkeleton.topAnchor.constraint(equalTo: gridViewport.topAnchor),
            scanSkeleton.bottomAnchor.constraint(equalTo: gridViewport.bottomAnchor),
            searchScrollView.leadingAnchor.constraint(equalTo: gridViewport.leadingAnchor),
            searchScrollView.trailingAnchor.constraint(equalTo: gridViewport.trailingAnchor),
            searchScrollView.topAnchor.constraint(equalTo: gridViewport.topAnchor),
            searchScrollView.bottomAnchor.constraint(equalTo: gridViewport.bottomAnchor),
            folderOverlay.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            folderOverlay.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            folderOverlay.topAnchor.constraint(equalTo: searchChrome.bottomAnchor),
            folderOverlay.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            footerControls.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            footerControls.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -56),
            footerControls.heightAnchor.constraint(equalToConstant: 24),
            pageIndicator.heightAnchor.constraint(equalToConstant: 24),
            previousPageButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            previousPageButton.centerYAnchor.constraint(equalTo: gridViewport.centerYAnchor),
            previousPageButton.widthAnchor.constraint(equalToConstant: 44),
            previousPageButton.heightAnchor.constraint(equalToConstant: 72),
            nextPageButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            nextPageButton.centerYAnchor.constraint(equalTo: gridViewport.centerYAnchor),
            nextPageButton.widthAnchor.constraint(equalToConstant: 44),
            nextPageButton.heightAnchor.constraint(equalToConstant: 72),
            messageLabel.centerXAnchor.constraint(equalTo: gridViewport.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: gridViewport.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 40),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -40),
            cachedCatalogButton.centerXAnchor.constraint(equalTo: messageLabel.centerXAnchor),
            cachedCatalogButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 12),
            emptyStateView.centerXAnchor.constraint(equalTo: gridViewport.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: gridViewport.centerYAnchor),
            emptyStateView.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            toastView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            toastView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -82),
            toastView.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 40),
            toastView.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -40),
            toastView.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            toastLabel.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 16),
            toastLabel.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 10),
            toastLabel.bottomAnchor.constraint(equalTo: toastView.bottomAnchor, constant: -10),
            toastLabel.trailingAnchor.constraint(equalTo: toastCloseButton.leadingAnchor, constant: -8),
            toastCloseButton.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -10),
            toastCloseButton.centerYAnchor.constraint(equalTo: toastView.centerYAnchor),
            toastCloseButton.widthAnchor.constraint(equalToConstant: 24),
            toastCloseButton.heightAnchor.constraint(equalToConstant: 24)
        ])
        // System reduced motion can already be on before the checkbox is read.
        // A list that has not moved yet only picks up the elasticity.
        syncContentScrollMotionForPreference()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @discardableResult
    func animateLauncherPresence(visible: Bool, appearing: Bool) -> TimeInterval {
        wantsLayer = true
        contentCard.wantsLayer = true
        let reduced = prefersReducedMotion
        let duration = reduced ? 0.12 : (visible ? 0.22 : 0.15)
        let timing = reduced
            ? CAMediaTimingFunction(name: .easeOut)
            : CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
        guard let layer, let cardLayer = contentCard.layer else { return duration }
        layer.removeAnimation(forKey: "launcherFade")
        cardLayer.removeAnimation(forKey: "launcherRise")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = (visible && appearing) ? 0 : (layer.presentation()?.opacity ?? (visible ? 0 : 1))
        fade.toValue = visible ? 1 : 0
        fade.duration = duration
        fade.timingFunction = timing
        layer.opacity = visible ? 1 : 0
        layer.add(fade, forKey: "launcherFade")

        if reduced {
            cardLayer.transform = CATransform3DIdentity
            return duration
        }
        let targetY: CGFloat = visible ? 0 : -4
        let startY: CGFloat
        if visible && appearing {
            startY = -8
        } else if let presented = cardLayer.presentation()?.value(forKeyPath: "transform.translation.y") as? NSNumber {
            startY = CGFloat(presented.doubleValue)
        } else {
            startY = 0
        }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = startY
        rise.toValue = targetY
        rise.duration = duration
        rise.timingFunction = timing
        cardLayer.transform = CATransform3DMakeTranslation(0, targetY, 0)
        cardLayer.add(rise, forKey: "launcherRise")
        return duration
    }

    /// The preference changed. A fade or card rise that is still running
    /// jumps to the opacity and position already stored on the layer.
    /// Reduced motion has no card travel, and turning motion back on does
    /// not finish the old fade or rise. A dismiss that is still on screen
    /// keeps the frame already drawn. A settled launcher is left alone.
    private func snapInFlightLauncherPresenceForMotionChange() {
        wantsLayer = true
        contentCard.wantsLayer = true
        guard let layer, let cardLayer = contentCard.layer else { return }
        let fading = layer.animation(forKey: "launcherFade") != nil
        let rising = cardLayer.animation(forKey: "launcherRise") != nil
        guard fading || rising else { return }
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldInFlightLauncherPresence(
            isDismissing: dismissing,
            isVisible: visible
        ) {
            let opacity = layer.presentation()?.opacity ?? layer.opacity
            let frozenTransform = cardLayer.presentation()?.transform
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "launcherFade")
            cardLayer.removeAnimation(forKey: "launcherRise")
            layer.opacity = opacity
            if let frozenTransform {
                cardLayer.transform = frozenTransform
            }
            CATransaction.commit()
            return
        }
        guard LauncherLayout.shouldSnapInFlightLauncherPresence(
            isDismissing: dismissing,
            isVisible: visible
        ) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "launcherFade")
        cardLayer.removeAnimation(forKey: "launcherRise")
        // The model already holds the destination written when the animation
        // started. Reduced motion never travels the card, so a hide offset
        // stored by the old rise is dropped. Turning motion back on does not
        // start a new rise.
        if prefersReducedMotion {
            cardLayer.transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    func updateDesktopBackground(for screen: NSScreen?) {
        guard let screen,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              url != desktopBackgroundURL else { return }
        desktopBackgroundURL = url
        backgroundLoadTask?.cancel()
        // A new URL replaces the held thumbnail. The cancelled task must not
        // paint the previous wallpaper after this one is requested.
        deferredDesktopBackground = nil
        desktopBackgroundWaitsForLauncher = false
        let maximumPixelSize = Int(ceil(max(screen.frame.width, screen.frame.height)))
        backgroundLoadTask = Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard !Task.isCancelled,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: false
                ] as CFDictionary)
            }.value
            guard let self, !Task.isCancelled, self.desktopBackgroundURL == url else { return }
            guard LauncherLayout.shouldApplyDesktopBackground(isDismissing: self.launcherIsDismissing()) else {
                self.deferredDesktopBackground = image
                self.desktopBackgroundWaitsForLauncher = true
                return
            }
            self.installDesktopBackground(image)
        }
    }

    /// Shows a wallpaper thumbnail that was decoded during the fade.
    func applyDeferredDesktopBackground() {
        guard desktopBackgroundWaitsForLauncher else { return }
        guard LauncherLayout.shouldApplyDesktopBackground(isDismissing: launcherIsDismissing()) else { return }
        desktopBackgroundWaitsForLauncher = false
        let image = deferredDesktopBackground
        deferredDesktopBackground = nil
        installDesktopBackground(image)
    }

    private func installDesktopBackground(_ image: CGImage?) {
        desktopBackgroundView.layer?.contentsScale = 1
        desktopBackgroundView.layer?.contents = image
    }

    override func layout() {
        super.layout()
        let viewport = gridViewport.bounds.size
        if viewport != lastViewportSize, viewport.width > 0, viewport.height > 0 {
            lastViewportSize = viewport
            updateGridMetrics()
            if !isPaging {
                layoutCollectionViews()
            }
            layoutSearchCollection()
        }
    }

    func setLoading(_ isLoading: Bool) {
        if isLoading { presentsCancelledEmptyCatalog = false }
        isCatalogLoading = isLoading
        guard shouldPresentCatalogChromeNow() else {
            catalogPresentationWaitsForLauncher = true
            return
        }
        if catalogPresentationWaitsForLauncher {
            applyDeferredCatalogPresentation()
        }
        updateReadOnlyStatus()
        refreshPresentation(resetPage: false)
    }

    func noteScanCancelledWhileEmpty() {
        presentsCancelledEmptyCatalog = true
    }

    func setCachedCatalogAvailable(_ available: Bool) {
        hasCachedCatalog = available
        guard shouldPresentCatalogChromeNow() else {
            catalogPresentationWaitsForLauncher = true
            return
        }
        if catalogPresentationWaitsForLauncher {
            applyDeferredCatalogPresentation()
        }
        updateRecoveryButtons()
    }

    func setRescanVisible(_ visible: Bool) {
        showsRescanButton = visible
        guard shouldPresentCatalogChromeNow() else {
            catalogPresentationWaitsForLauncher = true
            return
        }
        if catalogPresentationWaitsForLauncher {
            applyDeferredCatalogPresentation()
        }
        updateRecoveryButtons()
    }

    private func updateRecoveryButtons() {
        cachedCatalogButton.isHidden = !isCatalogLoading || !allCandidates.isEmpty || !hasCachedCatalog
        emptyStateCachedButton.isHidden = isCatalogLoading || !allCandidates.isEmpty || !hasCachedCatalog
        rescanButton.isHidden = isCatalogLoading || allCandidates.isEmpty || !showsRescanButton
        readOnlyCachedButton.isHidden = isCatalogLoading || allCandidates.isEmpty || !showsRescanButton || !hasCachedCatalog
        scanSkeleton.needsDisplay = true
        // Visibility changes after the last key-loop rebuild. Hidden parents
        // (the empty state) must not stay in the loop either.
        rebuildKeyViewLoop()
    }

    func setLayoutEditingEnabled(_ enabled: Bool, explanation: String? = nil) {
        let changed = isLayoutEditingEnabled != enabled
        isLayoutEditingEnabled = enabled
        if !enabled { dragPreview = nil }
        layoutEditingExplanation = enabled ? nil : explanation ?? "应用列表正在加载或不完整，暂时无法整理"
        // The label, drag hint, and title field follow the grid. Touching the
        // field while the launcher is fading can end a rename that should stay
        // a draft until the window is back.
        guard shouldPresentCatalogChromeNow() else {
            catalogPresentationWaitsForLauncher = true
            return
        }
        let hadDeferredPresentation = catalogPresentationWaitsForLauncher
        if hadDeferredPresentation {
            applyDeferredCatalogPresentation()
        }
        applyLayoutEditingChrome()
        if changed, !isCatalogLoading, !hadDeferredPresentation {
            // Item configuration captures the editing callbacks used by the context menu.
            // Rebuild existing tiles after a successful scan enables editing.
            reloadVisibleCollections()
        }
    }

    /// Tooltips, the read-only label, and the drag hint. Safe to repeat.
    /// The folder title's editable flag is included so a scan does not touch
    /// that field until the launcher is up.
    private func applyLayoutEditingChrome() {
        let reason = isLayoutEditingEnabled ? nil : layoutEditingExplanation
        activeCollectionView.toolTip = reason
        activeCollectionView.setAccessibilityHelp(reason ?? "拖动应用以整理布局")
        stagingCollectionView.toolTip = reason
        folderOverlay.setEditingEnabled(isLayoutEditingEnabled, explanation: reason)
        updateReadOnlyStatus()
        updateFooterHint()
    }

    private func updateReadOnlyStatus() {
        if layoutSaveFailed {
            readOnlyStatusLabel.stringValue = "布局未保存，请检查磁盘空间或文件权限"
            readOnlyStatusLabel.isHidden = false
        } else {
            readOnlyStatusLabel.stringValue = layoutEditingExplanation ?? ""
            readOnlyStatusLabel.isHidden = isCatalogLoading || isLayoutEditingEnabled || allCandidates.isEmpty
        }
    }

    func setReducesMotion(_ enabled: Bool) {
        reducesMotionOverride = enabled
        applyCurrentReducedMotion()
    }

    func refreshReducedMotionForSystemChange() {
        applyCurrentReducedMotion()
    }

    private func applyCurrentReducedMotion() {
        let effective = prefersReducedMotion
        let changed = LauncherLayout.shouldApplyReducedMotionChange(
            previousEffective: appliedReducedMotion,
            currentEffective: effective
        )
        appliedReducedMotion = effective
        guard changed else { return }
        // A hover fade already running is about a quarter of a second. Snap
        // it when the preference changes, instead of finishing that fade.
        previousPageButton.snapHoverVisibility()
        nextPageButton.snapHoverVisibility()
        // An open folder's backdrop follows the new preference at once.
        // Reduced motion is opacity only. A close that is still scaling
        // drops that scale the same way.
        applyFolderBackdropStyleForMotionChange()
        // Toast, search/grid, a dissolved-folder fade, a page slide, a press
        // pulse, a folder open or close, a merge flight, a folder landing,
        // and the launcher's own fade and card rise would keep running after
        // this preference changes. Snap them only when the effective value
        // changes, so saving another setting does not cut them short.
        // A reorder ease is the same, but the reload below puts every tile
        // back in its cell, so that gap is put back after the reload.
        // A search or folder coast is not a tile animation. Pin it only when
        // this preference actually changes.
        snapInFlightToastFadeForMotionChange()
        snapInFlightSearchChromeFadeForMotionChange()
        snapInFlightDissolvedGridFadeForMotionChange()
        snapInFlightPageSlideForMotionChange()
        snapInFlightLaunchFeedbackForMotionChange()
        snapInFlightFolderChromeForMotionChange()
        snapInFlightMergeFlightForMotionChange()
        snapInFlightFolderLandingForMotionChange()
        snapInFlightLauncherPresenceForMotionChange()
        dropInFlightDragLiftForMotionChange()
        restInFlightPageDragForMotionChange()
        restInFlightContentScrollForMotionChange()
        reloadVisibleCollections()
        landInFlightReorderSlideForMotionChange()
    }

    func hiddenApplications() -> [HiddenApplication] {
        allCandidates
            .filter { layoutState.hiddenAppKeys.contains($0.deduplicationKey) }
            .map { HiddenApplication(key: $0.deduplicationKey, displayName: displayName(for: $0)) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    @discardableResult
    func restoreHiddenApplication(withKey key: String) -> Bool {
        guard isLayoutEditingEnabled,
              layoutState.hiddenAppKeys.contains(key) else { return false }
        let restored = LauncherLayout.restoreApplication(withKey: key, in: layoutState)
        commitLayout(LauncherLayout.reconcile(candidates: allCandidates, into: restored))
        return true
    }

    func setCatalog(_ candidates: [AppCandidate], layout: LayoutState) {
        // A deferred presentation still describes the tiles on screen.
        // Apply it before reading focus, or the captured id belongs to a
        // grid this model update is about to replace.
        if catalogPresentationWaitsForLauncher && shouldPresentCatalogNow() {
            applyDeferredCatalogPresentation()
        }
        presentsCancelledEmptyCatalog = false
        let catalogChanged = allCandidates != candidates
        let previouslyOpenedFolder = openedFolderID.flatMap { layoutState.folders[$0] }
        let previousEntries = layoutState.orderedEntries
        let closingFolder = openedFolderID
        // The tile index still names an entry in the layout about to be replaced.
        let preservedGridFocus = focusedGridEntryID()
        let preservedFolderMember = focusedOpenFolderMember()
        allCandidates = candidates
        catalogByKey = AppCandidate.firstByDeduplicationKey(candidates)
        if layoutState.appAliases != layout.appAliases {
            appSearchIndex.setAliases(layout.appAliases)
        }
        if catalogChanged {
            appSearchIndexGeneration &+= 1
            appSearchIndexBuildTask?.cancel()
            let generation = appSearchIndexGeneration
            let buildTask = Task.detached(priority: .utility) {
                AppSearchIndex(candidates: candidates, aliases: layout.appAliases)
            }
            appSearchIndexBuildTask = buildTask
            Task { @MainActor [weak self] in
                let index = await buildTask.value
                guard let self,
                      self.appSearchIndexGeneration == generation,
                      !buildTask.isCancelled else { return }
                var currentIndex = index
                currentIndex.setAliases(self.layoutState.appAliases)
                self.appSearchIndex = currentIndex
                self.appSearchIndexBuildTask = nil
                self.refreshSearchResultsForInstalledIndex()
            }
        }
        layoutState = layout
        rebuildSearchableAppsCache()
        let snapshot = DeferredCatalogPresentation(
            previousEntries: previousEntries,
            previouslyOpenedFolder: previouslyOpenedFolder,
            closingFolder: closingFolder,
            preservedGridFocus: preservedGridFocus,
            preservedFolderMember: preservedFolderMember,
            catalogChanged: catalogChanged
        )
        prefetchIcons(for: LauncherLayout.searchableApps(in: layoutState, catalog: candidates))
        guard shouldPresentCatalogNow() else {
            // Keep the first on-screen snapshot. A second scan while the
            // launcher is still away only marks that the catalog changed.
            if deferredCatalogPresentation == nil {
                deferredCatalogPresentation = snapshot
            } else if catalogChanged {
                deferredCatalogPresentation?.catalogChanged = true
            }
            catalogPresentationWaitsForLauncher = true
            return
        }
        presentCatalogChange(snapshot)
    }

    /// Reload the grid and search list for a catalog change that already
    /// updated `layoutState`. Safe while the launcher is up, and before a
    /// fresh appearance orders the window in.
    private func presentCatalogChange(_ snapshot: DeferredCatalogPresentation) {
        let dissolvedOpenFolder = snapshot.closingFolder.map { layoutState.folders[$0] == nil } ?? false
        if dissolvedOpenFolder {
            // The reloads below throw away a focus set here.
            closeFolder(restoreFocus: false)
        }
        applySearch(
            preservedGridFocus: snapshot.preservedGridFocus,
            gridFocusCaptured: true,
            preservedFolderMember: snapshot.preservedFolderMember,
            folderFocusCaptured: true
        )
        if let openedFolderID,
           let folder = layoutState.folders[openedFolderID],
           folder != snapshot.previouslyOpenedFolder {
            folderOverlay.updateTitle(for: folder)
            folderOverlay.layoutFolderGrid(itemCount: presentedItems(for: folderOverlay.collectionView).count)
        }
        if snapshot.catalogChanged || lastViewportSize == .zero {
            lastViewportSize = .zero
            needsLayout = true
            layoutSubtreeIfNeeded()
            layoutCollectionViews()
            reloadVisibleCollections()
        }
        if dissolvedOpenFolder, let closingFolder = snapshot.closingFolder,
           let focusID = LauncherLayout.entryReplacingDissolvedFolder(
               folderID: closingFolder,
               previousEntries: snapshot.previousEntries,
               currentEntries: layoutState.orderedEntries
           ) {
            focusGridEntry(focusID)
        }
    }

    private func shouldPresentCatalogNow() -> Bool {
        LauncherLayout.shouldPresentCatalogWhileLauncherIsUp(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        )
    }

    private func shouldPresentCatalogChromeNow() -> Bool {
        LauncherLayout.shouldPresentCatalogChromeWhileLauncherIsUp(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        )
    }

    /// `force` is for a fresh appearance: the window is not visible yet, but
    /// the first frame should already show the catalog that landed while it
    /// was away. Cancelling a fade uses the normal visibility check.
    func applyDeferredCatalogPresentation(force: Bool = false) {
        guard catalogPresentationWaitsForLauncher else { return }
        guard force || shouldPresentCatalogNow() else { return }
        catalogPresentationWaitsForLauncher = false
        if let pending = deferredCatalogPresentation {
            deferredCatalogPresentation = nil
            presentCatalogChange(pending)
        } else {
            refreshPresentation(resetPage: false)
        }
        applyLayoutEditingChrome()
        updateRecoveryButtons()
    }

    func beginClick() {
        didConsumeClick = false
    }

    /// The window is still hidden. Drop a leftover search or open folder so the
    /// next presentation starts on the grid instead of the last session.
    func prepareForPresentation() {
        // Hide may already have landed. Do it again so a transition that
        // finished after hide cannot leave the hosts mid-slide. Clearing a
        // search or folder below does not send the grid back to page 0.
        // A fresh appearance drops the query, so a search-index refresh or a
        // Shift-Tab that waited out the fade must not rebuild the old list
        // or move focus onto it.
        searchIndexRefreshWaitsForLauncher = false
        searchBacktabWaitsForLauncher = false
        rememberGridPageForDismissal()
        applyDeferredVisualState()
        // The window is still hidden. Present a scan that finished while it
        // was away before the first frame, then drop any leftover search.
        applyDeferredCatalogPresentation(force: true)
        applyDeferredLaunchHighlight(force: true)
        // The window is still hidden. Icons that finished during the fade
        // should already be on the tiles before the first frame.
        applyDeferredLoadedIcons()
        // The window is still hidden. A wallpaper that finished during the
        // fade should already be in place before the first frame.
        applyDeferredDesktopBackground()
        // The window is still hidden. A toast whose timer fired during the
        // fade must be gone before the first frame, unless a newer one is
        // waiting. That newer one is drawn before the fade-in finishes, and
        // its auto-dismiss timer starts here.
        applyDeferredToastHide(force: true)
        applyDeferredToast(force: true)
        if openedFolderID != nil {
            _ = folderOverlay.cancelTitleEditingIfActive()
            closeFolder(immediately: true)
        }
        // stringValue can already be empty while the field editor still holds
        // the query and writes it back when the window returns.
        let hadEditor = searchField.currentEditor() != nil
        if hadEditor {
            searchField.abortEditing()
        }
        guard hadEditor || !searchField.stringValue.isEmpty else { return }
        searchField.stringValue = ""
        applySearch()
    }

    /// Finish visual work held by a launcher fade. Both a cancelled fade and
    /// an ordered-out window use this order before deferred model updates.
    func applyDeferredVisualState() {
        applyDeferredDropHighlightClear()
        applyDeferredFolderLanding()
        applyDeferredMergeFlight()
        applyDeferredFolderChrome()
        applyDeferredSearchChrome()
        applyDeferredDissolvedGridFade()
        applyDeferredLaunchFeedback()
        applyDeferredDragLiftDrop()
        applyDeferredPageDragRest()
        applyDeferredContentScrollRest()
        applyDeferredPageButtonHover()
        applyDeferredToastFade()
    }

    /// The page the grid should show the next time the launcher appears.
    /// Search text and an open folder are cleared separately and must not
    /// discard this page. A page past the end clamps. While the fade is still
    /// on screen this pins the hosts to the frame already drawn and stops the
    /// completion from swapping them. A hidden window, or a fade that was
    /// cancelled, lands the page before the next frame.
    func rememberGridPageForDismissal() {
        let count = LauncherLayout.pageCount(forEntryCount: layoutState.orderedEntries.count)
        let page = LauncherLayout.pageToRestore(
            currentPage: currentPage,
            inFlightPage: transitionTargetPage,
            queuedPage: queuedPage,
            pageCount: count
        )
        let interrupted = isPageTransitioning || isPagingGesture || queuedPage != nil || stagingPage != nil
        guard interrupted || currentPage != page else { return }
        guard LauncherLayout.shouldCommitRestoredGridPage(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else {
            // The in-flight completion would swap hosts and might start the
            // queued turn. Ignore it. `animator().frame` has already written
            // the destination, so removing the animation without the
            // presentation frame would finish the slide under the fade.
            holdInFlightPageSlide()
            return
        }
        pageTransitionGeneration += 1
        activeHost.layer?.removeAllAnimations()
        stagingHost.layer?.removeAllAnimations()
        queuedPage = nil
        transitionTargetPage = nil
        isPageTransitioning = false
        isPagingGesture = false
        stagingPage = nil
        currentPage = page
        discardInProgressPageGestures()
        activeCollectionView.cancelHeldDiscretePageTurn()
        stagingCollectionView.cancelHeldDiscretePageTurn()
        activeHost.alphaValue = 1
        activeCollectionView.reloadData()
        layoutCollectionViews()
        pageIndicator.configure(pageCount: isSearching ? 0 : count, selectedPage: currentPage)
        updatePagingControls()
    }

    func inputMethodHasMarkedText() -> Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }

    func searchFieldHasMarkedText() -> Bool {
        guard let editor = searchField.currentEditor() as? NSTextView else { return false }
        return editor.hasMarkedText()
    }

    func noteSearchCompositionEnded() {
        applySearch()
    }

    /// Install already happened. Reload the visible results only while the
    /// launcher can show them. A fade, or a window that has ordered out,
    /// keeps the old list and retries from `show()` when the fade is cancelled.
    private func refreshSearchResultsForInstalledIndex() {
        guard isSearching else {
            searchIndexRefreshWaitsForLauncher = false
            return
        }
        guard LauncherLayout.shouldRefreshInstalledSearchIndex(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else {
            searchIndexRefreshWaitsForLauncher = true
            return
        }
        searchIndexRefreshWaitsForLauncher = false
        applySearch()
    }

    func applyDeferredSearchIndexRefresh() {
        guard searchIndexRefreshWaitsForLauncher else { return }
        refreshSearchResultsForInstalledIndex()
    }

    /// Shift-Tab already asked to leave the search field. Resigning reloads
    /// the list, so skip that while the launcher is fading or gone and retry
    /// from `show()` when the fade is cancelled.
    func applyDeferredSearchBacktab() {
        guard searchBacktabWaitsForLauncher else { return }
        performSearchBacktabFocus()
    }

    private func performSearchBacktabFocus() {
        guard openedFolderID == nil else {
            searchBacktabWaitsForLauncher = false
            return
        }
        guard LauncherLayout.shouldApplyDeferredSearchBacktab(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else {
            searchBacktabWaitsForLauncher = true
            return
        }
        searchBacktabWaitsForLauncher = false
        // Resigning drops unfinished pinyin without the text-change
        // callback, so the list would still be the marked query.
        // Refilter before choosing the last hit. Resign-key during the
        // fade may already have cleared the mark and skipped the reload.
        // An empty query puts the caret back; there is no last hit to focus.
        if searchField.currentEditor() != nil {
            _ = window?.makeFirstResponder(self)
        }
        if LauncherLayout.shouldRefilterSearchAfterFieldEditorEnds(
            appliedQuery: searchQueryAppliedToResults,
            committedQuery: searchField.stringValue
        ) {
            noteSearchCompositionEnded()
        }
        guard isSearching else {
            focusSearchFieldAtEnd()
            return
        }
        guard let last = currentPresentedItems().last else {
            focusSearchFieldAtEnd()
            return
        }
        if !focusPresentedItem(id: last.id, in: searchCollectionView) {
            focusSearchFieldAtEnd()
        }
    }

    /// The field editor is ending while this window is still key. Marked
    /// pinyin disappears without `controlTextDidChange`, and the list would
    /// keep that spelling. Wait until the next turn so this click's mouse-up
    /// still reaches the tile that was pressed. A query that did not change
    /// is left alone.
    func refilterSearchIfFieldEditorDroppedComposition() {
        let committed = searchField.stringValue
        guard LauncherLayout.shouldRefilterSearchAfterFieldEditorEnds(
            appliedQuery: searchQueryAppliedToResults,
            committedQuery: committed
        ) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Hide can start before this turn. Reloading now jumps the list
            // under the fade. `show()` asks again if the fade is cancelled.
            // Ordering out clears the query on the next appearance.
            guard LauncherLayout.shouldApplyDeferredSearchRefilter(
                isDismissing: self.launcherIsDismissing(),
                isVisible: self.window?.isVisible == true
            ) else { return }
            // A new editing session owns the list again. Resign-key and
            // Shift-Tab may also have refiltered before this turn.
            guard self.searchField.currentEditor() == nil else { return }
            guard LauncherLayout.shouldRefilterSearchAfterFieldEditorEnds(
                appliedQuery: self.searchQueryAppliedToResults,
                committedQuery: self.searchField.stringValue
            ) else { return }
            self.noteSearchCompositionEnded()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === searchField else { return }
        refilterSearchIfFieldEditorDroppedComposition()
    }

    /// The window can resign key while pinyin is still marked in the search
    /// field. AppKit then drops that mark without telling the field, and the
    /// results stay on the old spelling. Remove the mark first so the
    /// committed letters are what gets saved, then filter again. A fade or
    /// `orderOut` also resigns key; reloading then waits until the launcher
    /// is up. A fresh appearance clears the query instead.
    func discardSearchCompositionBecauseWindowResignedKey() {
        guard let editor = searchField.currentEditor() as? NSTextView else { return }
        guard LauncherLayout.shouldDiscardSearchCompositionOnResignKey(
            hasMarkedText: editor.hasMarkedText()
        ) else { return }
        let marked = editor.markedRange()
        let cleaned = LauncherLayout.textByRemovingMarkedRange(
            editor.string,
            utf16Location: marked.location,
            utf16Length: marked.length
        )
        guard cleaned != editor.string else { return }
        let full = NSRange(location: 0, length: (editor.string as NSString).length)
        isDiscardingSearchComposition = true
        editor.replaceCharacters(in: full, with: cleaned)
        searchField.validateEditing()
        isDiscardingSearchComposition = false
        // A clear click during the fade may still restore the snapshot.
        // Keep that snapshot on the text that remains after the mark is gone.
        if frozenSearchFieldText != nil {
            frozenSearchFieldText = (
                committed: searchField.stringValue,
                editing: searchField.currentEditor()?.string
            )
        }
        // orderOut and a fade both resign key. Reloading here jumps the list
        // under the fade. The mark is already gone, so show() can refilter
        // when the fade is cancelled. A fresh appearance clears the query.
        guard LauncherLayout.shouldApplyDeferredSearchRefilter(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return }
        noteSearchCompositionEnded()
    }

    func handleEscape() -> Bool {
        // The field editor is clearing a marked range for this same Escape.
        // Do not also drop the query, close the folder, or dismiss.
        if escapeDeliveredToInputMethod || inputMethodHasMarkedText() {
            return true
        }
        // Escape is swallowed before the field editor sees it. Cancel an
        // in-progress folder rename instead of closing and saving the draft.
        if folderOverlay.cancelTitleEditingIfActive() {
            return true
        }
        if openedFolderID != nil {
            closeFolder()
            return true
        }
        guard clearSearchIfNeeded() else { return false }
        _ = window?.makeFirstResponder(self)
        return true
    }

    var highlightedLaunchKey: String? { launchingID }

    func setLaunchPending(_ candidate: AppCandidate?) {
        launchingID = candidate?.id
        guard shouldPresentLaunchHighlightNow() else {
            launchHighlightWaitsForLauncher = true
            return
        }
        reloadVisibleLaunchHighlight()
    }

    /// `force` reloads every grid. The window is still hidden, so the items
    /// that were on screen may no longer count as visible. Cancelling a fade
    /// reloads only the visible tiles.
    func applyDeferredLaunchHighlight(force: Bool = false) {
        guard launchHighlightWaitsForLauncher else { return }
        guard force || shouldPresentLaunchHighlightNow() else { return }
        launchHighlightWaitsForLauncher = false
        if force {
            for collectionView in launchHighlightCollections {
                collectionView.reloadData()
            }
        } else {
            reloadVisibleLaunchHighlight()
        }
    }

    private var launchHighlightCollections: [NSCollectionView] {
        [activeCollectionView, stagingCollectionView, searchCollectionView, folderOverlay.collectionView]
    }

    private func shouldPresentLaunchHighlightNow() -> Bool {
        LauncherLayout.shouldPresentLaunchHighlightWhileLauncherIsUp(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        )
    }

    private func reloadVisibleLaunchHighlight() {
        for collectionView in launchHighlightCollections {
            let paths = collectionView.indexPathsForVisibleItems()
            guard !paths.isEmpty else { continue }
            collectionView.reloadItems(at: paths)
        }
    }

    /// Tiles keep a decoded icon when it arrives during the fade. Walk every
    /// tile, including ones the collection view has not marked visible, and
    /// show that image once the launcher is up.
    func applyDeferredLoadedIcons() {
        var pending: [NSView] = [self]
        while let view = pending.popLast() {
            if let tile = view as? AppGridTileView {
                tile.applyDeferredLoadedIcon()
            }
            pending.append(contentsOf: view.subviews)
        }
    }

    func showLaunchError(for candidate: AppCandidate, error: Error) {
        showToast("无法打开“\(displayName(for: candidate))”", help: error.localizedDescription)
    }

    func showLayoutSaveError(_ error: Error) {
        layoutSaveFailed = true
        if shouldPresentCatalogChromeNow() {
            updateReadOnlyStatus()
        } else {
            catalogPresentationWaitsForLauncher = true
        }
        showToast("布局未保存，请检查磁盘空间或文件权限", help: error.localizedDescription, autoDismiss: false)
    }

    func clearLayoutSaveError() {
        layoutSaveFailed = false
        if shouldPresentCatalogChromeNow() {
            updateReadOnlyStatus()
        } else {
            catalogPresentationWaitsForLauncher = true
        }
        // The save failure may still be waiting out the fade. Drop that
        // request so the next appearance does not show a cleared error.
        // A different toast that replaced it stays.
        if deferredToast?.message == "布局未保存，请检查磁盘空间或文件权限" {
            deferredToast = nil
            toastWaitsForLauncher = false
        }
        guard toastLabel.stringValue == "布局未保存，请检查磁盘空间或文件权限" else { return }
        hideToast(animated: true)
    }

    private struct DeferredToast {
        var message: String
        var help: String?
        var autoDismiss: Bool
    }

    private enum HeldToastFade {
        case shown
        case hidden
    }

    /// The bubble is already fading when the launcher fade starts. Pin the
    /// opacity on screen. A hidden window, or a cancelled fade, snaps to the
    /// end. A hide that has not started yet still waits on its own flag.
    func settleToastFadeForDismissal() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldInFlightToastFade(isDismissing: dismissing, isVisible: visible) {
            pinInFlightToastFade()
            return
        }
        applyDeferredToastFade()
    }

    /// Snaps a pinned toast fade. A newer toast, or a hide that was only
    /// remembered, keeps ownership when the launcher is up again.
    func applyDeferredToastFade() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldInFlightToastFade(isDismissing: dismissing, isVisible: visible) {
            return
        }
        guard let end = heldToastFade else { return }
        heldToastFade = nil
        if end == .shown, toastWaitsForLauncher {
            return
        }
        if end == .shown, toastHideWaitsForLauncher, visible {
            return
        }
        switch end {
        case .shown:
            revealToastWithoutAnimation()
        case .hidden:
            performToastHide(animated: false)
        }
    }

    private func shouldPresentToastNow() -> Bool {
        LauncherLayout.shouldPresentToastWhileLauncherIsUp(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        )
    }

    /// Shows a toast that was requested during the fade or while hidden.
    /// `force` is for a fresh appearance: the window is not visible yet, but
    /// the first frame should already include the bubble.
    func applyDeferredToast(force: Bool = false) {
        guard toastWaitsForLauncher, let pending = deferredToast else { return }
        guard force || shouldPresentToastNow() else { return }
        toastWaitsForLauncher = false
        deferredToast = nil
        toastHideWaitsForLauncher = false
        presentToast(pending.message, help: pending.help, autoDismiss: pending.autoDismiss)
    }

    /// Hides a toast that reached its timer during the fade. A newer held
    /// toast wins. `force` removes it before a fresh appearance's first frame.
    func applyDeferredToastHide(force: Bool = false) {
        guard toastHideWaitsForLauncher else { return }
        if toastWaitsForLauncher {
            toastHideWaitsForLauncher = false
            return
        }
        guard force || shouldPresentToastNow() else { return }
        toastHideWaitsForLauncher = false
        if force {
            performToastHide(animated: false)
        } else {
            hideToast(animated: true)
        }
    }

    private func showToast(_ message: String, help: String? = nil, autoDismiss: Bool = true) {
        guard shouldPresentToastNow() else {
            deferredToast = DeferredToast(message: message, help: help, autoDismiss: autoDismiss)
            toastWaitsForLauncher = true
            return
        }
        toastWaitsForLauncher = false
        deferredToast = nil
        toastHideWaitsForLauncher = false
        presentToast(message, help: help, autoDismiss: autoDismiss)
    }

    private func presentToast(_ message: String, help: String? = nil, autoDismiss: Bool = true) {
        toastGeneration += 1
        toastDismissTask?.cancel()
        toastLabel.stringValue = message
        toastView.setAccessibilityLabel(message)
        toastView.toolTip = help
        toastView.alphaValue = 0
        toastView.isHidden = false
        if prefersReducedMotion {
            toastView.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                toastView.animator().alphaValue = 1
            }
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: message,
                NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
        guard autoDismiss else { return }
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.hideToast(animated: true)
        }
    }

    func hideToast(animated: Bool) {
        // The bubble is still on screen while the launcher fades. A second
        // fade here fights that animation. Remember the hide and let the
        // window carry the bubble out. A hidden window removes it at once.
        if !toastView.isHidden,
           LauncherLayout.shouldHoldToastDismissal(
               isDismissing: launcherIsDismissing(),
               isVisible: window?.isVisible == true
           ) {
            toastDismissTask?.cancel()
            toastDismissTask = nil
            toastGeneration += 1
            toastHideWaitsForLauncher = true
            return
        }
        toastHideWaitsForLauncher = false
        let animate = animated && LauncherLayout.shouldAnimateToastDismissal(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        )
        performToastHide(animated: animate)
    }

    private func performToastHide(animated: Bool) {
        toastGeneration += 1
        let generation = toastGeneration
        toastDismissTask?.cancel()
        toastDismissTask = nil
        guard !toastView.isHidden else { return }
        guard animated, !prefersReducedMotion else {
            toastView.alphaValue = 0
            toastView.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toastView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard self?.toastGeneration == generation else { return }
                self?.toastView.isHidden = true
            }
        })
    }

    /// The preference changed. A fade that is still running jumps to the
    /// end. Reduced motion has no fade, and turning it off does not finish
    /// the old one. A launcher fade that is holding the frame is left alone.
    private func snapInFlightToastFadeForMotionChange() {
        guard LauncherLayout.shouldSnapInFlightToastFade(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return }
        guard !toastView.isHidden else { return }
        toastView.wantsLayer = true
        guard let layer = toastView.layer else { return }
        guard !toastFadeKeys(on: layer).isEmpty else { return }
        if toastView.alphaValue > 0.01 {
            revealToastWithoutAnimation()
        } else {
            performToastHide(animated: false)
        }
    }

    /// `animator().alphaValue` writes the destination immediately. The
    /// presentation opacity is the frame on screen. A fade-out completion
    /// would still hide the bubble, so drop that generation.
    private func pinInFlightToastFade() {
        guard !toastView.isHidden else { return }
        toastView.wantsLayer = true
        guard let layer = toastView.layer else { return }
        let keys = toastFadeKeys(on: layer)
        guard !keys.isEmpty else { return }
        let end: HeldToastFade = toastView.alphaValue > 0.01 ? .shown : .hidden
        let opacity = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in keys {
            layer.removeAnimation(forKey: key)
        }
        toastView.alphaValue = CGFloat(opacity)
        layer.opacity = opacity
        CATransaction.commit()
        if end == .hidden {
            toastGeneration += 1
        }
        heldToastFade = end
    }

    private func revealToastWithoutAnimation() {
        toastView.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer = toastView.layer {
            for key in toastFadeKeys(on: layer) {
                layer.removeAnimation(forKey: key)
            }
            layer.opacity = 1
        }
        toastView.alphaValue = 1
        toastView.isHidden = false
        CATransaction.commit()
    }

    private func toastFadeKeys(on layer: CALayer) -> [String] {
        guard let keys = layer.animationKeys() else { return [] }
        return keys.filter { key in
            if key == "opacity" || key == "alphaValue" { return true }
            let path = (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath
            return path == "opacity" || path == "alphaValue"
        }
    }

    @objc private func closeToast() {
        didConsumeClick = true
        hideToast(animated: true)
    }

    @objc private func reloadCatalog() {
        guard acceptsPointerActivation() else { return }
        didConsumeClick = true
        onReloadRequested?()
    }

    @objc private func useCachedCatalog() {
        guard acceptsPointerActivation() else { return }
        didConsumeClick = true
        onUseCachedCatalogRequested?()
    }

    func pressVisibleButton(titled title: String) -> Bool {
        let candidates = [cachedCatalogButton, emptyStateCachedButton, readOnlyCachedButton, rescanButton, emptyStateReloadButton]
        guard let button = candidates.first(where: { $0.title == title && !isEffectivelyHidden($0) }) else {
            return false
        }
        button.performClick(nil)
        return true
    }

    private func isEffectivelyHidden(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let view = current {
            if view.isHidden { return true }
            current = view.superview
        }
        return false
    }

    @objc private func openSettings() {
        guard acceptsPointerActivation() else { return }
        onSettingsRequested?()
    }

    func focusSearch() {
        // The open folder is modal. Command-F must not uncover search or
        // close the folder; typing is already ignored, and Escape still closes.
        guard openedFolderID == nil else { return }
        // ⌘F does not change the query, so nothing else settles a page turn.
        // The animation completion would otherwise take the keyboard back.
        settleInterruptedPaging()
        window?.makeFirstResponder(searchField)
        // Already inside the field: becoming first responder does not run again,
        // so the query stays unselected and the next letter is inserted mid-word.
        // ⌘F still means "type this over". Typing from an icon puts the caret
        // back at the end after this returns.
        searchField.currentEditor()?.selectAll(nil)
    }

    /// The search field selects its whole string on focus. Put the caret at
    /// the end so another letter appends. ⌘F still uses `focusSearch`, which
    /// leaves the query selected.
    @discardableResult
    private func focusSearchFieldAtEnd() -> Bool {
        guard window?.makeFirstResponder(searchField) == true else { return false }
        let length = (currentSearchQuery() as NSString).length
        searchField.currentEditor()?.selectedRange = NSRange(location: length, length: 0)
        return true
    }

    func beginSearch(with event: NSEvent) -> Bool {
        guard openedFolderID == nil else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection([.command, .control]).isEmpty,
              let characters = event.characters,
              characters.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) else { return false }
        focusSearch()
        if let editor = searchField.currentEditor() {
            // Becoming first responder selects the whole query. insertText would
            // replace it, and it also skips the input method. Put the caret at
            // the end and let the field editor handle this key.
            let length = (editor.string as NSString).length
            editor.selectedRange = NSRange(location: length, length: 0)
            editor.keyDown(with: event)
        } else {
            searchField.stringValue = LauncherLayout.searchQueryAppending(searchField.stringValue, characters)
            applySearch()
        }
        return true
    }

    /// Backspace on a search result, or on chrome while a query is showing.
    /// Option-backspace removes the last word. Command-backspace clears the
    /// line. The field editor already deletes when it has focus. A folder stays put.
    func deleteSearch(_ deletion: LauncherSearchDeletion) -> Bool {
        guard isSearching, openedFolderID == nil else { return false }
        let current = searchField.stringValue
        let next: String
        switch deletion {
        case .character:
            next = LauncherLayout.searchQueryDeletingLastCharacter(current)
        case .word:
            next = LauncherLayout.searchQueryDeletingLastWord(current)
        case .toLineStart:
            next = ""
        }
        guard next != current else { return false }
        let focusedID = focusedSearchResultID()
        if searchField.currentEditor() != nil {
            searchField.abortEditing()
        }
        searchField.stringValue = next
        applySearch()
        // The last letter left search. The result tile was reloaded away, so
        // the keyboard would otherwise sit on nothing. The caret belongs in
        // the now-empty field. A chrome button that was deleting keeps focus.
        if !isSearching {
            if focusedID != nil {
                focusSearchFieldAtEnd()
            }
            return true
        }
        guard let focusedID else { return true }
        if presentedItems(for: searchCollectionView).contains(where: { $0.id == focusedID }) {
            focusSearchResult(focusedID)
        } else {
            // The old hit is gone. Put the caret at the end so the next
            // backspace does not select the whole query and erase it.
            focusSearchFieldAtEnd()
        }
        return true
    }

    /// The grid icon that has the keyboard, read from the list still on screen.
    /// Call this before `layoutState` is replaced: the tile's index is not an id.
    private func focusedGridEntryID() -> UUID? {
        guard openedFolderID == nil, !isSearching,
              let slot = focusedGridSlot(in: activeCollectionView) else { return nil }
        let items = presentedItems(for: activeCollectionView)
        guard items.indices.contains(slot) else { return nil }
        return items[slot].id
    }

    private func focusedSearchResultID() -> UUID? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        for item in searchCollectionView.visibleItems() {
            guard item.view === responder || responder.isDescendant(of: item.view),
                  let index = searchCollectionView.indexPath(for: item)?.item else { continue }
            let items = presentedItems(for: searchCollectionView)
            guard items.indices.contains(index) else { return nil }
            return items[index].id
        }
        return nil
    }

    @discardableResult
    func clearSearchIfNeeded() -> Bool {
        let raw = searchField.stringValue
        let hadEditor = searchField.currentEditor() != nil
        guard !raw.isEmpty || hadEditor else { return false }
        // Spaces alone are not a search: the grid is already showing. Clear them
        // but let Esc close a folder or dismiss the launcher.
        let hadQuery = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hadEditor {
            // Esc never reaches the field, so abort before assigning or the
            // editor restores the query when it resigns.
            searchField.abortEditing()
        }
        searchField.stringValue = ""
        if hadQuery || hadEditor {
            applySearch()
        }
        return hadQuery
    }

    @objc private func clearSearch() {
        _ = clearSearchIfNeeded()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === searchField else { return }
        if isRestoringSearchField || isDiscardingSearchComposition { return }
        guard LauncherLayout.shouldApplySearchFieldEdit(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else {
            restoreFrozenSearchFieldText()
            // The search cell can write the cleared string after this returns.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isRestoringSearchField else { return }
                guard !LauncherLayout.shouldApplySearchFieldEdit(
                    isDismissing: self.launcherIsDismissing(),
                    isVisible: self.window?.isVisible == true
                ) else { return }
                self.restoreFrozenSearchFieldText()
            }
            return
        }
        frozenSearchFieldText = nil
        applySearch()
    }

    /// Keep the first snapshot. A second `hide()` during the fade must not
    /// replace it with text the clear button has already emptied.
    func freezeSearchFieldForDismiss() {
        guard frozenSearchFieldText == nil else { return }
        frozenSearchFieldText = (
            committed: searchField.stringValue,
            editing: searchField.currentEditor()?.string
        )
    }

    func releaseFrozenSearchField() {
        frozenSearchFieldText = nil
    }

    private func restoreFrozenSearchFieldText() {
        guard let frozen = frozenSearchFieldText else { return }
        let editor = searchField.currentEditor() as? NSTextView
        let editingTarget = frozen.editing ?? frozen.committed
        let editorMatches = editor == nil || editor?.string == editingTarget
        guard searchField.stringValue != frozen.committed || !editorMatches else { return }
        isRestoringSearchField = true
        defer { isRestoringSearchField = false }
        searchField.stringValue = frozen.committed
        guard let editor, editor.string != editingTarget else { return }
        let full = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.replaceCharacters(in: full, with: editingTarget)
        let caret = (editingTarget as NSString).length
        editor.selectedRange = NSRange(location: caret, length: 0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            guard isSearching else { return false }
            // Return confirms the IME candidate first. Launching here would open
            // whatever the unfinished pinyin currently matches.
            if textView.hasMarkedText() { return false }
            switch currentPresentedItems().first {
            case .app(_, let candidate):
                onCandidateSelected?(candidate)
            case .folder(let folder, _):
                openFolder(folder.id)
            case nil:
                break
            }
            return true
        }
        // The key loop only contains icons already on screen. Shift-Tab would
        // stop on the last visible hit and never reach one below the fold.
        if selector == #selector(NSResponder.insertBacktab(_:)), isSearching, openedFolderID == nil,
           !currentPresentedItems().isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.performSearchBacktabFocus()
            }
            return true
        }
        // An empty field still has the keyboard. Left/Right and Page Up/Down
        // would otherwise move a caret that has nowhere to go, and the page
        // stays put. A real query keeps Left and Right inside the text.
        if !isSearching, openedFolderID == nil, launcherSearchFieldPages(selector) {
            let backward = selector == #selector(NSResponder.moveLeft(_:))
                || selector == #selector(NSResponder.pageUp(_:))
            movePage(by: backward ? -1 : 1)
            return true
        }
        // A real query used to swallow Page Up/Down: the grid refuses to page,
        // and a single-line field has nowhere to move. Scroll the results.
        // Left/Right stay in the text. Marked pinyin still goes to the IME.
        if isSearching, openedFolderID == nil, !textView.hasMarkedText(),
           selector == #selector(NSResponder.pageUp(_:)) || selector == #selector(NSResponder.pageDown(_:)) {
            let forward = selector == #selector(NSResponder.pageDown(_:))
            _ = scrollSearchResults(byPage: forward ? 1 : -1)
            return true
        }
        return false
    }

    /// Page Up/Down while results are showing. One viewport at a time.
    /// Left/Right do not come here. The key is consumed even at the end.
    @discardableResult
    func scrollSearchResults(byPage direction: Int) -> Bool {
        guard isSearching, openedFolderID == nil, direction != 0 else { return false }
        layoutSearchCollection()
        let clipView = searchScrollView.contentView
        let next = LauncherLayout.scrolledPageOffset(
            current: clipView.bounds.origin.y,
            documentLength: searchCollectionView.frame.height,
            viewportLength: clipView.bounds.height,
            forward: direction > 0
        )
        if next != clipView.bounds.origin.y {
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: next))
            searchScrollView.reflectScrolledClipView(clipView)
        }
        // The result that had the keyboard may now be off screen. A recycled
        // tile would open a different app. The caret goes back to the field
        // without jumping the list to the top. Left/Right are not involved.
        if let tile = window?.firstResponder as? AppGridTileView,
           tile.isDescendant(of: searchCollectionView) {
            let frame = tile.convert(tile.bounds, to: searchCollectionView)
            let barelyVisible = frame.insetBy(dx: 0, dy: frame.height * 0.5)
            if !searchCollectionView.visibleRect.intersects(barelyVisible) {
                focusSearchFieldAtEnd()
            }
        }
        rebuildKeyViewLoop()
        return true
    }

    func movePage(by direction: Int) {
        showPage(LauncherLayout.pageIndex(
            movingBy: direction,
            from: currentPage,
            inFlightPage: transitionTargetPage,
            queuedPage: queuedPage,
            pageCount: pageCount
        ))
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        presentedItems(for: collectionView).count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let presentedItems = presentedItems(for: collectionView)
        guard presentedItems.indices.contains(indexPath.item) else { return AppGridItem() }

        let item: AppGridItem
        if collectionView === folderOverlay.collectionView {
            // On macOS 27 AppKit can raise an Objective-C exception while dequeuing
            // the first item after this collection view changes from hidden to visible.
            // Folder grids contain at most 25 items, so creating their lightweight item
            // controllers directly avoids that unstable reuse path at negligible cost.
            item = AppGridItem()
        } else {
            guard let reusedItem = collectionView.makeItem(
                withIdentifier: AppGridItem.identifier,
                for: indexPath
            ) as? AppGridItem else {
                return AppGridItem()
            }
            item = reusedItem
        }

        let presented = presentedItems[indexPath.item]
        let representedID = presented.id
        // Set this before configure starts an icon load. A cached decode can
        // resume on this turn, and the tile has to know the fade is underway.
        if let tile = item.view as? AppGridTileView {
            tile.launcherIsDismissing = launcherIsDismissing
        }
        let activate = { [weak self, weak collectionView] in
            guard let collectionView else { return }
            self?.activateItem(withID: representedID, in: collectionView)
        }
        let beginDrag = { [weak self, weak collectionView] (event: NSEvent) -> Bool in
            guard let collectionView = collectionView as? PagingCollectionView else { return false }
            return self?.beginItemDrag(withID: representedID, in: collectionView, event: event) ?? false
        }
        let renameAlias = { [weak self, weak collectionView] in
            guard let self, let collectionView,
                  let candidate = self.currentAppCandidate(withID: representedID, in: collectionView) else { return }
            self.promptForAlias(of: candidate, focusID: representedID, in: collectionView)
        }
        let hideApplication = { [weak self, weak collectionView] in
            guard let self, let collectionView,
                  let candidate = self.currentAppCandidate(withID: representedID, in: collectionView) else { return }
            self.hideApplication(candidate)
        }
        switch presented {
        case .app(_, let candidate):
            item.configure(
                candidate: candidate,
                displayName: displayName(for: candidate),
                isLaunching: candidate.id == launchingID,
                isFolder: false,
                preview: [],
                reducesMotion: prefersReducedMotion,
                onActivate: activate,
                onDragStart: beginDrag,
                onRenameAlias: isLayoutEditingEnabled ? renameAlias : nil,
                onHideApplication: isLayoutEditingEnabled ? hideApplication : nil
            )
        case .folder(let folder, let preview):
            item.configure(candidate: AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/\(folder.id.uuidString)"),
                bundleIdentifier: nil,
                displayName: folder.name,
                sourcePriority: 0,
                discoveredAt: folder.createdAt
            ), displayName: folder.name, isLaunching: false, isFolder: true, preview: preview,
                reducesMotion: prefersReducedMotion, onActivate: activate, onDragStart: beginDrag,
                onRenameAlias: nil, onHideApplication: nil)
        }
        if let tile = item.view as? AppGridTileView {
            tile.onContextMenuTracking = { [weak self] menu in
                self?.noteIconContextMenuTracking(menu)
            }
            // Same keys as the window. A folder or search still refuses to page.
            tile.onPage = { [weak self] direction in self?.movePage(by: direction) }
            tile.onVerticalPage = { [weak self] direction in
                self?.scrollSearchResults(byPage: direction) ?? false
            }
            tile.onType = { [weak self] event in self?.beginSearch(with: event) ?? false }
            tile.onDelete = { [weak self] deletion in self?.deleteSearch(deletion) ?? false }
            // Search and folders scroll. Tab must reach icons that are not
            // materialized yet. The grid page does not: those keys stay on the
            // existing loop, and Left/Right still page.
            if collectionView === searchCollectionView || collectionView === folderOverlay.collectionView {
                tile.onTab = { [weak self, weak collectionView] direction in
                    guard let self, let collectionView else { return false }
                    let items = self.presentedItems(for: collectionView)
                    guard let index = items.firstIndex(where: { $0.id == representedID }) else { return false }
                    if items.indices.contains(index + direction) {
                        return self.focusAdjacentPresentedItem(from: representedID, in: collectionView, by: direction)
                    }
                    // The icon may have been created by scrolling and is not in
                    // the key loop. Leaving the list still has to land somewhere.
                    return self.focusOutsidePresentedList(in: collectionView, by: direction)
                }
            } else {
                tile.onTab = nil
            }
        }
        (item.view as? AppGridTileView)?.onFocus = (collectionView === searchCollectionView || collectionView === folderOverlay.collectionView)
            ? { [weak self, weak collectionView] in
                guard let self, let collectionView,
                      let currentIndex = self.presentedItems(for: collectionView).firstIndex(where: { $0.id == representedID }),
                      let frame = collectionView.collectionViewLayout?.layoutAttributesForItem(
                        at: IndexPath(item: currentIndex, section: 0)
                      )?.frame else { return }
                collectionView.scrollToVisible(frame)
            }
            : nil
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        nil
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        let reorderingOpenFolder = collectionView === folderOverlay.collectionView && openedFolderID != nil
        guard LauncherLayout.shouldAcceptLayoutDrop(isDismissing: launcherIsDismissing()),
              (reorderingOpenFolder || !isSearching),
              isLayoutEditingEnabled,
              !(collectionView === folderOverlay.collectionView && folderOverlay.isAnimatingClose) else {
            // Rejecting the drop during the fade used to snap the gap back
            // under the animation. Leave the ring and the slide until the
            // window is hidden or the launcher is up again.
            clearDropHighlightIfAllowed()
            return []
        }
        let point = collectionView.convert(draggingInfo.draggingLocation, from: nil)
        var hoveredTarget: AppGridTileView?
        if let hover = collectionView.indexPathForItem(at: point),
           let item = collectionView.item(at: hover) {
            let local = item.view.convert(point, from: collectionView)
            let center = item.view.bounds.insetBy(dx: item.view.bounds.width * 0.22, dy: item.view.bounds.height * 0.22)
            // Members are already in a folder. Highlighting a merge here is a
            // lie: the drop only reorders, and nesting is rejected.
            // The center merges. Either edge reorders: the trailing half inserts
            // after this icon, not in front of it.
            let merges = collectionView !== folderOverlay.collectionView && center.contains(local)
            let visibleItems = presentedItems(for: collectionView)
            if merges {
                dropOperation.pointee = .on
                proposedIndexPath.pointee = hover as NSIndexPath
                if visibleItems.indices.contains(hover.item) {
                    let folderID = collectionView === folderOverlay.collectionView ? openedFolderID : nil
                    if !isDragSource(visibleItems[hover.item].id, folderID: folderID, info: draggingInfo) {
                        hoveredTarget = item.view as? AppGridTileView
                    }
                }
            } else {
                dropOperation.pointee = .before
                let gap = LauncherLayout.reorderGapIndex(
                    hoveredItem: hover.item,
                    pointerX: local.x,
                    itemMinX: item.view.bounds.minX,
                    itemWidth: item.view.bounds.width,
                    itemCount: visibleItems.count
                )
                proposedIndexPath.pointee = IndexPath(item: gap, section: hover.section) as NSIndexPath
            }
        } else {
            dropOperation.pointee = .before
        }
        setDropTarget(hoveredTarget)
        updateReorderSlide(
            in: collectionView,
            info: draggingInfo,
            proposedIndex: proposedIndexPath.pointee.item,
            showsGap: dropOperation.pointee == .before
        )
        return .move
    }

    private func finishItemDragSession() {
        previousPageButton.cancelDragHover()
        nextPageButton.cancelDragHover()
        // The drag image is gone. Put the source icon back now, even during
        // the fade: a blank cell is the jump. The neighbors stay where the
        // gap left them until the window is hidden or the launcher is up.
        activeDragLift = nil
        dragLiftDropWaitsForLauncher = false
        restoreDragSourceTile()
        clearDropHighlightIfAllowed()
        guard pendingMergeAnimation != nil else { return }
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldMergeFlight(isDismissing: dismissing, isVisible: visible) {
            // The session can end during the fade. Starting the flight now
            // would move the icon under it. Keep the request until the
            // launcher is up. A hidden window drops it below.
            mergeFlightWaitsForLauncher = true
            return
        }
        if !LauncherLayout.shouldAdvanceMergeFlight(isDismissing: dismissing, isVisible: visible) {
            pendingMergeAnimation = nil
            mergeFlightWaitsForLauncher = false
            removeMergeFlyer()
            return
        }
        beginPendingMergeFlight()
    }

    private func beginPendingMergeFlight() {
        guard let pending = pendingMergeAnimation else { return }
        pendingMergeAnimation = nil
        mergeFlightWaitsForLauncher = false
        let startsFlight = pending.target != nil
        if let target = pending.target {
            playMergeAnimation(
                from: pending.source ?? target.offsetBy(dx: -48, dy: -48),
                to: target,
                image: pending.image
            )
        }
        if let folderID = pending.folderID {
            playFolderLandingAnimation(
                folderID,
                after: startsFlight && pending.createdFolder && !prefersReducedMotion ? mergeFlightDuration : 0
            )
        }
    }

    /// The flyer is an image view whose model frame is already the destination.
    /// While the fade is up, pin it to the frame on screen and ignore the
    /// completion that would remove it. A hidden window removes it instead,
    /// so the next appearance does not flash the icon. Cancelling the fade
    /// removes a flight that already started: the folder tile commits to its
    /// final size. A flight that has not started plays once the launcher is up.
    func settleMergeFlightForDismissal() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldMergeFlight(isDismissing: dismissing, isVisible: visible) {
            if let flyer = mergeAnimationView {
                freezeMergeFlyer(flyer)
            }
            if mergeAnimationView != nil || pendingMergeAnimation != nil {
                mergeFlightWaitsForLauncher = true
            }
            return
        }
        guard LauncherLayout.shouldAdvanceMergeFlight(isDismissing: dismissing, isVisible: visible) else {
            pendingMergeAnimation = nil
            mergeFlightWaitsForLauncher = false
            removeMergeFlyer()
            return
        }
    }

    func applyDeferredMergeFlight() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldMergeFlight(isDismissing: dismissing, isVisible: visible) {
            return
        }
        // A flight that is already playing, and was not held, keeps going.
        // `show()` on an already-open launcher must not cancel it.
        guard mergeFlightWaitsForLauncher || !visible else { return }
        if LauncherLayout.shouldAdvanceMergeFlight(isDismissing: dismissing, isVisible: visible),
           pendingMergeAnimation != nil {
            beginPendingMergeFlight()
            return
        }
        pendingMergeAnimation = nil
        mergeFlightWaitsForLauncher = false
        removeMergeFlyer()
    }

    private func freezeMergeFlyer(_ flyer: NSView) {
        mergeFlightGeneration &+= 1
        flyer.wantsLayer = true
        guard let layer = flyer.layer else { return }
        let presented = layer.presentation()
        let opacity = presented?.opacity ?? layer.opacity
        // `animator().frame` writes the destination into the model immediately.
        // The presentation frame is the one on screen. It is already in the
        // superview's coordinates for this layer-backed image view.
        let frame = presented?.frame ?? flyer.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.removeAllAnimations()
        flyer.alphaValue = CGFloat(opacity)
        flyer.frame = frame
        CATransaction.commit()
    }

    private func removeMergeFlyer() {
        mergeFlightGeneration &+= 1
        let flyer = mergeAnimationView
        mergeAnimationView = nil
        flyer?.layer?.removeAllAnimations()
        flyer?.removeFromSuperview()
    }

    /// The preference changed. A flight that is still running is removed.
    /// Reduced motion is only a shorter fade, and turning motion back on does
    /// not finish the old path. A launcher fade that is holding the frame is
    /// left alone. A flight that has not started stays pending. A new folder
    /// still waiting on this flight is drawn at its final size, so the icon
    /// does not vanish and leave an empty cell. A spring that has already
    /// started keeps going.
    private func snapInFlightMergeFlightForMotionChange() {
        guard LauncherLayout.shouldSnapInFlightMergeFlight(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return }
        guard mergeAnimationView != nil else { return }
        removeMergeFlyer()
        mergeFlightWaitsForLauncher = false
        commitLandingsStillWaitingOnMergeFlight()
    }

    /// The reveal is queued until the flight duration elapses, with model
    /// opacity still 0. Once that image is gone, waiting would leave a blank
    /// cell. A landing whose fade has already started is above this threshold
    /// and is not this flight.
    private func commitLandingsStillWaitingOnMergeFlight() {
        let snapshots = heldFolderLandings
        for held in snapshots {
            guard let layer = held.layer else { continue }
            guard layer.value(forKey: "folderLandingToken") as? Int == held.generation else { continue }
            guard layer.animation(forKey: "folder-created-opacity") != nil else { continue }
            let opacity = layer.presentation()?.opacity ?? layer.opacity
            guard opacity < 0.01 else { continue }
            commitFolderLanding(on: layer, generation: held.generation)
            forgetTrackedFolderLanding(layer: layer, generation: held.generation)
        }
    }

    /// The preference changed. A spring or a short fade that is still running
    /// jumps to full opacity and scale. Reduced motion has no spring, and
    /// turning motion back on does not finish the old one. A launcher fade
    /// that is holding the frame is left alone. A tile that is not landing
    /// stays as it is.
    private func snapInFlightFolderLandingForMotionChange() {
        guard LauncherLayout.shouldSnapInFlightFolderLanding(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return }
        let snapshots = heldFolderLandings
        for held in snapshots {
            guard let layer = held.layer else { continue }
            guard layer.value(forKey: "folderLandingToken") as? Int == held.generation else { continue }
            let animating = layer.animation(forKey: "folder-created") != nil
                || layer.animation(forKey: "folder-created-opacity") != nil
            guard animating else { continue }
            commitFolderLanding(on: layer, generation: held.generation)
            forgetTrackedFolderLanding(layer: layer, generation: held.generation)
        }
    }

    /// The panel and the dimmed grid keep their own animations after the
    /// launcher starts fading. While the fade is up, pin both to the frame
    /// already on screen and ignore the close completion that would hide the
    /// panel. A hidden window, or a cancelled fade, jumps to the end: an
    /// opening panel is fully open, a closing panel is gone.
    func settleFolderChromeForDismissal() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldFolderChromeAnimation(isDismissing: dismissing, isVisible: visible) {
            if folderOverlay.freezeChromeForDismissal() || freezeFolderBackdropIfAnimating() {
                folderChromeWaitsForLauncher = true
            }
            return
        }
        if folderChromeWaitsForLauncher || folderOverlay.isAnimatingClose {
            applyDeferredFolderChrome()
        }
    }

    func applyDeferredFolderChrome() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldFolderChromeAnimation(isDismissing: dismissing, isVisible: visible) {
            return
        }
        if folderBackdropStyleWaitsForLauncher {
            folderBackdropStyleWaitsForLauncher = false
            restyleOpenFolderBackdrop()
        }
        // An open or close that was not held keeps going. `show()` on an
        // already-open launcher must not finish it early. A hidden window
        // still jumps a close to the end, so the next appearance does not
        // flash the panel.
        guard folderChromeWaitsForLauncher || !visible else { return }
        guard folderChromeWaitsForLauncher || folderOverlay.isAnimatingClose else { return }
        folderChromeWaitsForLauncher = false
        folderOverlay.commitHeldChrome()
        commitFolderBackdrop()
    }

    /// The preference changed. An open folder's backdrop follows it at once,
    /// unless the launcher fade is still holding that frame. A close has
    /// already cleared the folder id, but its panel can still be scaling.
    /// Reduced motion drops that scale now. The panel fade is snapped
    /// separately, so it does not keep playing. The launcher fade keeps the
    /// frame it already drew; the close commit resets the panel.
    private func applyFolderBackdropStyleForMotionChange() {
        let applyNow = LauncherLayout.shouldApplyFolderBackdropStyle(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        )
        guard openedFolderID != nil else {
            folderBackdropStyleWaitsForLauncher = false
            if prefersReducedMotion, applyNow {
                folderOverlay.dropScaleForReducedMotion()
            }
            return
        }
        guard applyNow else {
            folderBackdropStyleWaitsForLauncher = true
            return
        }
        folderBackdropStyleWaitsForLauncher = false
        restyleOpenFolderBackdrop()
    }

    /// Scale and blur match the current reduced-motion preference. Opacity
    /// stays at the open-folder value. A folder that is not open is left
    /// alone; closing already reset the grid.
    private func restyleOpenFolderBackdrop() {
        guard openedFolderID != nil else { return }
        let backdrop = isSearching ? searchScrollView : gridViewport
        resetFolderBackdrop(backdrop === gridViewport ? searchScrollView : gridViewport)
        finishFolderBackdropOpen(backdrop)
        if prefersReducedMotion {
            folderOverlay.dropScaleForReducedMotion()
        }
    }

    private func freezeFolderBackdropIfAnimating() -> Bool {
        let views = [gridViewport, searchScrollView].filter(backdropIsAnimating)
        guard !views.isEmpty else { return false }
        for view in views {
            pinLayerToPresentedFrame(
                view.layer,
                removing: ["folderBackdropOpacity", "folderBackdropScale"]
            )
        }
        return true
    }

    private func backdropIsAnimating(_ view: NSView) -> Bool {
        guard let keys = view.layer?.animationKeys() else { return false }
        return keys.contains("folderBackdropOpacity") || keys.contains("folderBackdropScale")
    }

    /// The open animation's model values are already the end state until a
    /// freeze overwrites them. Put that end state back without replaying it.
    /// A closed folder resets the grid instead.
    private func commitFolderBackdrop() {
        if openedFolderID != nil {
            let backdrop = isSearching ? searchScrollView : gridViewport
            resetFolderBackdrop(backdrop === gridViewport ? searchScrollView : gridViewport)
            finishFolderBackdropOpen(backdrop)
        } else {
            resetFolderBackdrop(gridViewport)
            resetFolderBackdrop(searchScrollView)
        }
    }

    private func finishFolderBackdropOpen(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let style = LauncherLayout.folderBackdropStyle(open: true, reducesMotion: prefersReducedMotion)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "folderBackdropOpacity")
        layer.removeAnimation(forKey: "folderBackdropScale")
        layer.opacity = Float(style.opacity)
        if style.scale == 1 {
            layer.transform = CATransform3DIdentity
        } else {
            layer.transform = CATransform3DMakeScale(style.scale, style.scale, 1)
        }
        if style.blurs {
            view.layerUsesCoreImageFilters = true
            if layer.filters == nil,
               let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 6]) {
                layer.filters = [blur]
            }
        } else {
            layer.filters = nil
        }
        CATransaction.commit()
    }

    private func clearDragHighlight() {
        setDropTarget(nil)
        clearReorderSlides()
    }

    /// True once a fade asked to drop the ring and the gap, and that clear
    /// has not run yet. A drag that is still down keeps owning the highlight.
    private var dropHighlightClearWaitsForLauncher = false

    /// Snapping the merge ring and the reorder gap back to the grid jumps
    /// those tiles. Do it when the launcher is up, or when the window is
    /// already hidden. While the fade is on screen, remember the request.
    private func clearDropHighlightIfAllowed() {
        guard LauncherLayout.shouldClearDropHighlight(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else {
            dropHighlightClearWaitsForLauncher = true
            return
        }
        dropHighlightClearWaitsForLauncher = false
        clearDragHighlight()
    }

    /// `hide()` asked to clear the highlight and then left it on screen.
    /// Run that clear once the fade is over. A session that has not restored
    /// its source tile is still dragging, so the ring and the gap stay.
    func applyDeferredDropHighlightClear() {
        guard dropHighlightClearWaitsForLauncher else {
            // A slide pinned for the fade still has to leave that mid-frame
            // once the launcher is up, even if nothing asked to clear it.
            settleReorderSlideForDismissal()
            return
        }
        guard dragSourceTile == nil else {
            // The drag is still down, so the gap stays. Jump to it instead
            // of easing the rest of the way after the fade.
            settleReorderSlideForDismissal()
            return
        }
        clearDropHighlightIfAllowed()
        settleReorderSlideForDismissal()
    }

    /// The reorder ease keeps moving icons after the gap has been left on
    /// screen. While the fade is up, stop each timer on the frame already
    /// drawn. A hidden window, or a cancelled fade, jumps a drag that is
    /// still down to its gap. A drag that already ended is cleared by the
    /// highlight path and is not replayed.
    func settleReorderSlideForDismissal() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldReorderSlide(isDismissing: dismissing, isVisible: visible) {
            pinInFlightReorderSlides()
            return
        }
        releaseHeldReorderSlides(jumpToTarget: dragSourceTile != nil)
    }

    private func pinInFlightReorderSlides() {
        for collectionView in reorderSlideCollections {
            for item in collectionView.visibleItems() {
                (item.view as? AppGridTileView)?.pinReorderSlideForDismissal()
            }
        }
    }

    private func releaseHeldReorderSlides(jumpToTarget: Bool) {
        for collectionView in reorderSlideCollections {
            for item in collectionView.visibleItems() {
                (item.view as? AppGridTileView)?.releaseHeldReorderSlide(jumpToTarget: jumpToTarget)
            }
        }
    }

    private func setDropTarget(_ tile: AppGridTileView?) {
        guard dropTargetTile !== tile else { return }
        dropTargetTile?.isDropTarget = false
        tile?.isDropTarget = true
        dropTargetTile = tile
    }

    private var reorderSlideCollections: [NSCollectionView] {
        [activeCollectionView, stagingCollectionView, folderOverlay.collectionView]
    }

    private func dragSourceIndex(in collectionView: NSCollectionView, info: NSDraggingInfo) -> Int? {
        guard let source = draggedItem(from: info) else { return nil }
        let items = presentedItems(for: collectionView)
        switch source {
        case .topLevel(let id):
            guard collectionView === activeCollectionView || collectionView === stagingCollectionView else { return nil }
            return items.firstIndex { $0.id == id }
        case .folderMember(let folderID, let itemID):
            guard collectionView === folderOverlay.collectionView, openedFolderID == folderID else { return nil }
            return items.firstIndex { $0.id == itemID }
        }
    }

    private func updateReorderSlide(
        in collectionView: NSCollectionView,
        info: NSDraggingInfo,
        proposedIndex: Int,
        showsGap: Bool
    ) {
        let preview = showsGap
            ? LauncherLayout.dragReorderPreview(
                sourceIndex: dragSourceIndex(in: collectionView, info: info),
                proposedIndex: proposedIndex,
                count: presentedItems(for: collectionView).count
            )
            : nil
        let signature = preview.map {
            ReorderSlideSignature(collectionID: ObjectIdentifier(collectionView), slots: $0.slotByItem)
        }
        guard signature != reorderSlideSignature else {
            for item in collectionView.visibleItems() {
                (item.view as? AppGridTileView)?.reassertReorderSlide()
            }
            return
        }
        for other in reorderSlideCollections where other !== collectionView {
            clearReorderSlide(in: other)
        }
        if applyReorderSlide(preview, in: collectionView) {
            reorderSlideSignature = signature
        } else {
            reorderSlideSignature = nil
        }
    }

    private func clearReorderSlides() {
        reorderSlideSignature = nil
        for collectionView in reorderSlideCollections {
            clearReorderSlide(in: collectionView)
        }
    }

    private func clearReorderSlide(in collectionView: NSCollectionView) {
        for item in collectionView.visibleItems() {
            (item.view as? AppGridTileView)?.setReorderTranslation(.zero, animated: false)
        }
    }

    /// The preference changed. Neighbors were easing toward a gap. Reduced
    /// motion is already on that gap, and turning motion back on does not
    /// finish the old ease. Reloading the grid has just put every tile back
    /// in its cell, so put them on the gap again without starting another
    /// 0.18s ease. A launcher fade that is holding the frame is left alone.
    private func landInFlightReorderSlideForMotionChange() {
        guard LauncherLayout.shouldSnapInFlightReorderSlide(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return }
        guard let signature = reorderSlideSignature,
              let collectionView = reorderSlideCollections.first(where: {
                  ObjectIdentifier($0) == signature.collectionID
              }) else { return }
        _ = applyReorderSlots(signature.slots, in: collectionView, animated: false)
    }

    /// Returns false when the layout frames are not ready, so the next drag update can retry.
    private func applyReorderSlide(
        _ preview: LauncherLayout.DragReorderPreview?,
        in collectionView: NSCollectionView
    ) -> Bool {
        guard let preview else {
            clearReorderSlide(in: collectionView)
            return true
        }
        return applyReorderSlots(preview.slotByItem, in: collectionView, animated: nil)
    }

    /// `animated == nil` follows reduced motion and the launcher fade.
    /// `false` lands on the gap immediately. The caller that records the
    /// signature must not treat a forced landing as a new drag update.
    private func applyReorderSlots(
        _ slots: [Int?],
        in collectionView: NSCollectionView,
        animated forcedAnimated: Bool?
    ) -> Bool {
        collectionView.layoutSubtreeIfNeeded()
        let animated = forcedAnimated ?? LauncherLayout.shouldAnimateReorderSlide(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true,
            reducesMotion: prefersReducedMotion
        )
        var ready = true
        var tiles: [Int: AppGridTileView] = [:]
        for item in collectionView.visibleItems() {
            guard let path = collectionView.indexPath(for: item)?.item,
                  let tile = item.view as? AppGridTileView else { continue }
            tiles[path] = tile
        }
        for itemIndex in slots.indices {
            let indexPath = IndexPath(item: itemIndex, section: 0)
            guard let tile = tiles[itemIndex] ?? (collectionView.item(at: indexPath)?.view as? AppGridTileView) else {
                if let slot = slots[itemIndex], slot != itemIndex {
                    ready = false
                }
                continue
            }
            guard let slot = slots[itemIndex],
                  let fromFrame = collectionView.collectionViewLayout?.layoutAttributesForItem(at: indexPath)?.frame,
                  let toFrame = collectionView.collectionViewLayout?.layoutAttributesForItem(
                    at: IndexPath(item: slot, section: 0)
                  )?.frame else {
                tile.setReorderTranslation(.zero, animated: false)
                continue
            }
            if slot != itemIndex, fromFrame.size == .zero || toFrame.size == .zero || fromFrame == toFrame {
                ready = false
            }
            // Layout frames are in the flipped collection view. The tile converts this delta.
            let translation = CGSize(
                width: toFrame.origin.x - fromFrame.origin.x,
                height: toFrame.origin.y - fromFrame.origin.y
            )
            tile.setReorderTranslation(translation, animated: animated && ready)
        }
        return ready
    }

    private func restoreDragSourceTile() {
        dragSourceTile?.layer?.opacity = 1
        dragSourceTile = nil
    }

    private func dragLiftImage(from source: NSImage, presentation: LauncherLayout.DragLiftPresentation) -> NSImage {
        guard presentation.shadowOpacity > 0,
              presentation.canvasSize.width > 0,
              presentation.canvasSize.height > 0 else { return source }
        let image = NSImage(size: presentation.canvasSize)
        image.lockFocus()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(presentation.shadowOpacity)
        shadow.shadowBlurRadius = presentation.shadowRadius
        shadow.shadowOffset = presentation.shadowOffset
        shadow.set()
        source.draw(
            in: NSRect(origin: presentation.contentOrigin, size: presentation.contentSize),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        return image
    }

    /// The preference changed. A drag that is still showing its lift drops
    /// the scale and shadow. Turning motion back on does not add a lift.
    /// A launcher fade that is holding the picture leaves it, and remembers
    /// the drop for when that hold ends. No drag is left alone.
    private func dropInFlightDragLiftForMotionChange() {
        guard activeDragLift?.session != nil else {
            activeDragLift = nil
            dragLiftDropWaitsForLauncher = false
            return
        }
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        guard LauncherLayout.shouldDropInFlightDragLift(
            isDismissing: dismissing,
            isVisible: visible,
            reducesMotion: prefersReducedMotion
        ) else {
            if prefersReducedMotion,
               activeDragLift?.showsLift == true,
               LauncherLayout.shouldHoldInFlightLauncherPresence(
                   isDismissing: dismissing,
                   isVisible: visible
               ) {
                dragLiftDropWaitsForLauncher = true
            } else if !prefersReducedMotion {
                dragLiftDropWaitsForLauncher = false
            }
            return
        }
        dragLiftDropWaitsForLauncher = false
        dropActiveDragLift()
    }

    /// Drops a lift that was remembered during the fade. Does nothing while
    /// the fade is still holding the picture, or when motion is no longer reduced.
    func applyDeferredDragLiftDrop() {
        guard dragLiftDropWaitsForLauncher else { return }
        guard LauncherLayout.shouldDropInFlightDragLift(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true,
            reducesMotion: prefersReducedMotion
        ) else { return }
        dragLiftDropWaitsForLauncher = false
        dropActiveDragLift()
    }

    /// Replaces the lifted drag image with the original cell picture, centered
    /// in the frame the drag already has, so the image does not jump.
    private func dropActiveDragLift() {
        guard var lift = activeDragLift, let session = lift.session, lift.showsLift else { return }
        let source = lift.sourceImage
        let cellSize = lift.sourceSize
        var replaced = false
        session.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { item, _, stop in
            let frame = item.draggingFrame
            let image = self.plainDragImage(source, cellSize: cellSize, fitting: frame.size)
            item.setDraggingFrame(frame, contents: image)
            replaced = true
            stop.pointee = true
        }
        guard replaced else { return }
        lift.showsLift = false
        activeDragLift = lift
    }

    /// The original cell picture, centered in the drag frame. The frame stays
    /// where the lift already was. Empty padding is clear.
    private func plainDragImage(_ source: NSImage, cellSize: CGSize, fitting canvas: CGSize) -> NSImage {
        guard canvas.width > 0, canvas.height > 0, cellSize.width > 0, cellSize.height > 0 else {
            return source
        }
        let image = NSImage(size: canvas)
        image.lockFocus()
        source.draw(
            in: NSRect(
                x: (canvas.width - cellSize.width) / 2,
                y: (canvas.height - cellSize.height) / 2,
                width: cellSize.width,
                height: cellSize.height
            ),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        return image
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard LauncherLayout.shouldAcceptLayoutDrop(isDismissing: launcherIsDismissing()),
              !(collectionView === folderOverlay.collectionView && folderOverlay.isAnimatingClose) else { return false }
        guard let source = draggedItem(from: draggingInfo) else { return false }
        let items = presentedItems(for: collectionView)
        let destination: LayoutDestination
        if collectionView === folderOverlay.collectionView, let folderID = openedFolderID {
            destination = .folderIndex(folderID: folderID, index: min(indexPath.item, items.count))
        } else if dropOperation == .on, items.indices.contains(indexPath.item) {
            destination = .merge(.topLevel(items[indexPath.item].id))
        } else {
            destination = .topLevelIndex(
                LauncherLayout.topLevelDropIndex(
                    page: topLevelPageIndex(for: collectionView),
                    localIndex: min(indexPath.item, items.count),
                    sourceIndex: topLevelSourceIndex(source),
                    countBeforeRemoval: layoutState.orderedEntries.count
                )
            )
        }
        return applyDrop(LayoutDrop(source: source, destination: destination))
    }

    private func applySearch(
        preservedGridFocus: UUID? = nil,
        gridFocusCaptured: Bool = false,
        preservedFolderMember: (id: UUID, index: Int)? = nil,
        folderFocusCaptured: Bool = false
    ) {
        refreshPresentation(
            resetPage: false,
            preservedGridFocus: preservedGridFocus,
            gridFocusCaptured: gridFocusCaptured,
            preservedFolderMember: preservedFolderMember,
            folderFocusCaptured: folderFocusCaptured
        )
    }

    /// Search or an open folder covers the grid. A page animation still in
    /// flight would finish underneath, or steal focus back when it ends.
    /// Land on the page already requested, and drop any gesture still in hand.
    private func settleInterruptedPaging() {
        guard isPageTransitioning || isPagingGesture || queuedPage != nil || stagingPage != nil else { return }
        let gridPageCount = LauncherLayout.pageCount(forEntryCount: layoutState.orderedEntries.count)
        let landed = queuedPage ?? transitionTargetPage ?? currentPage
        pageTransitionGeneration += 1
        queuedPage = nil
        transitionTargetPage = nil
        isPageTransitioning = false
        isPagingGesture = false
        if gridPageCount > 0 {
            currentPage = min(max(landed, 0), gridPageCount - 1)
        }
        stagingPage = nil
        discardInProgressPageGestures()
        activeCollectionView.cancelHeldDiscretePageTurn()
        stagingCollectionView.cancelHeldDiscretePageTurn()
        layoutCollectionViews()
    }

    private func refreshPresentation(
        resetPage: Bool,
        preservedGridFocus preCapturedGridFocus: UUID? = nil,
        gridFocusCaptured: Bool = false,
        preservedFolderMember preCapturedFolderMember: (id: UUID, index: Int)? = nil,
        folderFocusCaptured: Bool = false
    ) {
        // The focused tile's index is into the list still on screen. The
        // replacement below can put a different hit at that index.
        let capturedSearchFocus = (openedFolderID == nil) ? focusedSearchResultID() : nil
        // A layout swap has already moved a different icon into the old slot.
        // Callers that swap first pass the id they read before the swap.
        let capturedGridFocus = gridFocusCaptured ? preCapturedGridFocus : focusedGridEntryID()
        let query = currentSearchQuery()
        searchQueryAppliedToResults = query
        if isSearching {
            settleInterruptedPaging()
            // A folder opened from a search hit stays up while results refresh
            // underneath it. Closing here used to cancel a rename or a rescan.
            // Starting a new search still closes the folder before the field edits.
        }
        if isSearching {
            searchPresentedItems = appSearchIndex.filter(
                LauncherLayout.searchHits(in: layoutState, catalog: allCandidates),
                query: query
            ).compactMap { hit in
                switch hit {
                case .app(let candidate):
                    return searchableAppIDsByKey[candidate.deduplicationKey].map { .app($0, candidate) }
                case .folder(let id, _):
                    guard let folder = layoutState.folders[id] else { return nil }
                    let preview = folder.itemIDs.prefix(4).compactMap { itemID in
                        layoutState.appKeys[itemID].flatMap { catalogByKey[$0] }
                    }
                    return .folder(folder, Array(preview))
                }
            }
        } else {
            searchPresentedItems.removeAll(keepingCapacity: true)
        }
        if resetPage { currentPage = 0 }
        clearButton.isHidden = true
        let presented = currentPresentedItems()
        countLabel.stringValue = isSearching ? "\(presented.count) 个结果" : "\(layoutState.orderedEntries.count) 个项目"
        updateSearchChrome(searching: isSearching)
        updatePagination(resetToFirstPage: resetPage)
        reloadVisibleCollections(
            preservedSearchResult: capturedSearchFocus,
            searchFocusCaptured: true,
            preservedGridFocus: capturedGridFocus,
            gridFocusCaptured: true,
            preservedFolderMember: preCapturedFolderMember,
            folderFocusCaptured: folderFocusCaptured
        )
        emptyStateView.isHidden = true
        let showScanSkeleton = isCatalogLoading && allCandidates.isEmpty && !isSearching
        scanSkeleton.isHidden = !showScanSkeleton
        if isCatalogLoading, allCandidates.isEmpty {
            messageLabel.stringValue = "正在准备应用…"
            messageLabel.isHidden = false
        } else if allCandidates.isEmpty {
            messageLabel.isHidden = true
            emptyStateView.isHidden = false
            if presentsCancelledEmptyCatalog {
                emptyStateTitle.stringValue = "扫描已取消"
                emptyStateDetail.stringValue = "应用扫描已取消，请重新扫描。"
                emptyStateReloadButton.setAccessibilityHelp("重新扫描应用")
            } else {
                emptyStateTitle.stringValue = "未找到可用的应用"
                emptyStateDetail.stringValue = "请确认应用位于 Applications 文件夹，然后重新扫描。"
                emptyStateReloadButton.setAccessibilityHelp("重新扫描标准 Applications 文件夹")
            }
        } else if presented.isEmpty {
            messageLabel.stringValue = isSearching ? "未找到匹配的应用，按 Esc 清除搜索" : "正在准备应用…"
            messageLabel.isHidden = false
        } else {
            messageLabel.isHidden = true
        }
        updateRecoveryButtons()
        updateReadOnlyStatus()
    }

    private func rebuildSearchableAppsCache() {
        searchableApps = LauncherLayout.searchableApps(in: layoutState, catalog: allCandidates)
        searchableAppIDsByKey.removeAll(keepingCapacity: true)
        for (id, key) in layoutState.appKeys where searchableAppIDsByKey[key] == nil {
            searchableAppIDsByKey[key] = id
        }
    }

    /// The crossfade keeps running after the launcher starts fading. While
    /// the fade is up, pin the incoming surface to the opacity already on
    /// screen and ignore the completion that would finish it. A hidden
    /// window, or a cancelled fade, shows that surface at full opacity.
    func settleSearchChromeForDismissal() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldSearchChromeAnimation(isDismissing: dismissing, isVisible: visible) {
            if pinInFlightSearchChrome() {
                searchChromeWaitsForLauncher = true
            }
            return
        }
        if searchChromeWaitsForLauncher {
            applyDeferredSearchChrome()
        }
    }

    func applyDeferredSearchChrome() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldSearchChromeAnimation(isDismissing: dismissing, isVisible: visible) {
            return
        }
        guard searchChromeWaitsForLauncher else { return }
        searchChromeWaitsForLauncher = false
        searchChromeGeneration &+= 1
        finishSearchChromeFade(on: searchChromeVisible ? searchScrollView : gridViewport)
    }

    /// The preference changed. A crossfade that is still running jumps to
    /// full opacity. Reduced motion has no fade, and turning it off does not
    /// finish the old one. A launcher fade that is holding the frame is left
    /// alone. An open folder's backdrop keeps its dimmed opacity.
    private func snapInFlightSearchChromeFadeForMotionChange() {
        guard LauncherLayout.shouldSnapInFlightSearchChromeFade(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return }
        let fading = [searchScrollView, gridViewport].filter { view in
            view.wantsLayer = true
            guard let layer = view.layer else { return false }
            return !searchChromeFadeKeys(on: layer).isEmpty
        }
        guard !fading.isEmpty else { return }
        // Drop the completion that would still force full opacity. An open
        // folder's backdrop must keep the dim it already has.
        searchChromeGeneration &+= 1
        for view in fading {
            finishSearchChromeFade(on: view)
        }
    }

    /// The incoming surface is the one fading in. Its model opacity is already
    /// 1; the presentation opacity is the frame on screen.
    private func pinInFlightSearchChrome() -> Bool {
        let incoming: NSView = searchChromeVisible ? searchScrollView : gridViewport
        incoming.wantsLayer = true
        guard let layer = incoming.layer else { return false }
        let keys = searchChromeFadeKeys(on: layer)
        guard !keys.isEmpty else { return false }
        let opacity = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in keys {
            layer.removeAnimation(forKey: key)
        }
        incoming.alphaValue = CGFloat(opacity)
        layer.opacity = opacity
        CATransaction.commit()
        searchChromeGeneration &+= 1
        return true
    }

    /// Drop a crossfade and show the surface at full opacity. A folder
    /// backdrop owns that same opacity, so leave it alone while the folder
    /// is open or its dim animation is still on the layer.
    private func finishSearchChromeFade(on view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else {
            view.alphaValue = 1
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in searchChromeFadeKeys(on: layer) {
            layer.removeAnimation(forKey: key)
        }
        if !backdropIsAnimating(view), !isOpenFolderBackdrop(view) {
            view.alphaValue = 1
            layer.opacity = 1
        }
        CATransaction.commit()
    }

    private func isOpenFolderBackdrop(_ view: NSView) -> Bool {
        guard openedFolderID != nil else { return false }
        let backdrop = isSearching ? searchScrollView : gridViewport
        return view === backdrop
    }

    private func searchChromeFadeKeys(on layer: CALayer) -> [String] {
        guard let keys = layer.animationKeys() else { return [] }
        return keys.filter { key in
            if key == "folderBackdropOpacity" || key == "folderBackdropScale" { return false }
            if key == "opacity" || key == "alphaValue" { return true }
            let path = (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath
            return path == "opacity" || path == "alphaValue"
        }
    }

    /// The surface that is leaving search or the grid is removed at once, so clicks
    /// and accessibility match the mode. The surface that is appearing fades in.
    private func updateSearchChrome(searching: Bool) {
        let incoming: NSView = searching ? searchScrollView : gridViewport
        let outgoing: NSView = searching ? gridViewport : searchScrollView
        guard searching != searchChromeVisible else {
            outgoing.isHidden = true
            incoming.isHidden = false
            return
        }
        searchChromeGeneration &+= 1
        let generation = searchChromeGeneration
        searchChromeVisible = searching
        outgoing.isHidden = true
        outgoing.alphaValue = 1
        incoming.isHidden = false
        let holdCrossfade = LauncherLayout.shouldHoldSearchChromeAnimation(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        )
        guard !holdCrossfade, !prefersReducedMotion, window?.isVisible == true else {
            // A mode change during the fade must not start another crossfade.
            // The results were already swapped above this call.
            finishSearchChromeFade(on: incoming)
            finishSearchChromeFade(on: outgoing)
            return
        }
        incoming.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = LauncherLayout.searchTransitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            incoming.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.searchChromeGeneration == generation else { return }
                incoming.alphaValue = 1
            }
        })
    }

    private func currentPresentedItems() -> [PresentedItem] {
        if isSearching { return searchPresentedItems }
        return presentedItems(from: layoutState.orderedEntries)
    }

    private func presentedItems(from entries: [LauncherEntry]) -> [PresentedItem] {
        entries.compactMap { entry in
            switch entry {
            case .app(let id):
                guard let key = layoutState.appKeys[id], let candidate = catalogByKey[key] else { return nil }
                return .app(id, candidate)
            case .folder(let id):
                guard let folder = layoutState.folders[id] else { return nil }
                let preview = folder.itemIDs.prefix(4).compactMap { itemID in
                    layoutState.appKeys[itemID].flatMap { catalogByKey[$0] }
                }
                return .folder(folder, Array(preview))
            }
        }
    }

    private func presentedItems(for page: Int) -> [PresentedItem] {
        if isSearching { return currentPresentedItems() }
        return presentedItems(from: LauncherLayout.entries(onPage: page, from: layoutState.orderedEntries))
    }

    private func presentedItems(for collectionView: NSCollectionView) -> [PresentedItem] {
        if collectionView === searchCollectionView { return currentPresentedItems() }
        if collectionView === folderOverlay.collectionView {
            guard let folderID = openedFolderID, let folder = layoutState.folders[folderID] else { return [] }
            return folder.itemIDs.compactMap { id in
                layoutState.appKeys[id].flatMap { catalogByKey[$0] }.map { .app(id, $0) }
            }
        }
        if collectionView === activeCollectionView {
            return presentedItems(for: currentPage)
        }
        return presentedItems(for: stagingPage ?? currentPage)
    }

    private var pageCount: Int {
        if isSearching { return currentPresentedItems().isEmpty ? 0 : 1 }
        return LauncherLayout.pageCount(forEntryCount: layoutState.orderedEntries.count)
    }

    private func updatePagination(resetToFirstPage: Bool) {
        pageSize = LauncherLayout.pageCapacity
        updateGridMetrics()
        if resetToFirstPage {
            currentPage = 0
        } else if !isSearching, pageCount > 0 {
            currentPage = min(currentPage, pageCount - 1)
        }
        pageIndicator.configure(pageCount: isSearching ? 0 : pageCount, selectedPage: currentPage)
        updatePagingControls()
        if isSearching {
            layoutSearchCollection()
        }
    }

    private func updateGridMetrics() {
        let viewport = isSearching ? searchScrollView.bounds.size : gridViewport.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let itemSize = LauncherLayout.itemSize(in: viewport)
        let inset = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        for collectionView in [activeCollectionView, stagingCollectionView, searchCollectionView] {
            guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { continue }
            guard layout.itemSize != itemSize else { continue }
            layout.itemSize = itemSize
            layout.minimumInteritemSpacing = 12
            layout.minimumLineSpacing = 10
            layout.sectionInset = inset
            layout.invalidateLayout()
        }
    }

    private func layoutSearchCollection() {
        let width = max(searchScrollView.bounds.width, 1)
        let items = currentPresentedItems().count
        let columns = LauncherLayout.pageColumns
        let rows = max(1, (items + columns - 1) / columns)
        guard let layout = searchCollectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        var inset = layout.sectionInset
        let horizontalInset: CGFloat = 8
        if items > 0, items < columns {
            let rowWidth = CGFloat(items) * layout.itemSize.width
                + CGFloat(items - 1) * layout.minimumInteritemSpacing
            let centeredInset = max(horizontalInset, floor((width - rowWidth) / 2))
            inset.left = centeredInset
            inset.right = centeredInset
        } else {
            inset.left = horizontalInset
            inset.right = horizontalInset
        }
        if layout.sectionInset.left != inset.left || layout.sectionInset.right != inset.right {
            layout.sectionInset = inset
        }
        let height = layout.sectionInset.top + layout.sectionInset.bottom
            + CGFloat(rows) * layout.itemSize.height
            + CGFloat(max(rows - 1, 0)) * layout.minimumLineSpacing
        searchCollectionView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, searchScrollView.bounds.height))
        // Spaces, case, and accents do not change which results the filter
        // returns, including a space typed between letters. Only a real query
        // change should jump back to the top.
        let query = LauncherLayout.searchScrollQueryKey(currentSearchQuery())
        let clipView = searchScrollView.contentView
        if query != searchScrollQuery {
            searchScrollQuery = query
            clipView.scroll(to: .zero)
            searchScrollView.reflectScrolledClipView(clipView)
        } else {
            let clamped = LauncherLayout.clampedScrollOffset(
                clipView.bounds.origin.y,
                documentLength: searchCollectionView.frame.height,
                viewportLength: clipView.bounds.height
            )
            if clamped != clipView.bounds.origin.y {
                clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: clamped))
                searchScrollView.reflectScrolledClipView(clipView)
            }
        }
    }

    private func reloadVisibleCollections(
        preservedSearchResult capturedSearchFocus: UUID? = nil,
        searchFocusCaptured: Bool = false,
        preservedGridFocus capturedGridFocus: UUID? = nil,
        gridFocusCaptured: Bool = false,
        preservedFolderMember capturedFolderMember: (id: UUID, index: Int)? = nil,
        folderFocusCaptured: Bool = false
    ) {
        // After a catalog swap the tile's index belongs to the previous folder.
        let preservedFolderMember = folderFocusCaptured ? capturedFolderMember : focusedOpenFolderMember()
        // A scan or a new query reloads the search grid and drops the key
        // focus. Remember the result only when it actually has the keyboard;
        // the search field must keep the caret. After the result list has been
        // replaced, the index on screen belongs to the old list.
        let preservedSearchResult = searchFocusCaptured
            ? capturedSearchFocus
            : ((openedFolderID == nil) ? focusedSearchResultID() : nil)
        let preservedGridFocus = gridFocusCaptured ? capturedGridFocus : focusedGridEntryID()
        activeCollectionView.reloadData()
        stagingCollectionView.reloadData()
        searchCollectionView.reloadData()
        folderOverlay.reload()
        if openedFolderID != nil {
            folderOverlay.layoutFolderGrid(itemCount: presentedItems(for: folderOverlay.collectionView).count)
        }
        layoutSearchCollection()
        updateGridAccessibilityChildren(for: activeCollectionView)
        updateGridAccessibilityChildren(for: stagingCollectionView)
        updateGridAccessibilityChildren(for: searchCollectionView)
        updateGridAccessibilityChildren(for: folderOverlay.collectionView)
        rebuildKeyViewLoop()
        if let preservedFolderMember, openedFolderID != nil {
            restoreOpenFolderMemberFocus(preservedFolderMember)
        } else if let preservedSearchResult, openedFolderID == nil, isSearching {
            focusSearchResult(preservedSearchResult)
        } else if let preservedGridFocus, openedFolderID == nil, !isSearching {
            // Typing moves the caret into the field before this reload, so the
            // id is nil and the grid does not take the keyboard back.
            focusGridEntry(preservedGridFocus)
        }
    }

    private func updateGridAccessibilityChildren(for collectionView: NSCollectionView) {
        collectionView.layoutSubtreeIfNeeded()
        let tiles = collectionView.visibleItems()
            .sorted { lhs, rhs in
                guard let left = collectionView.indexPath(for: lhs),
                      let right = collectionView.indexPath(for: rhs) else { return false }
                return left.item < right.item
            }
            .map(\.view)
        collectionView.setAccessibilityChildren(tiles)
        tiles.forEach { $0.setAccessibilityParent(collectionView) }
        NSAccessibility.post(element: collectionView, notification: .layoutChanged)
    }

    private func rebuildKeyViewLoop() {
        let keyViews: [NSView]
        if openedFolderID != nil {
            keyViews = folderOverlay.keyViews
        } else {
            let collectionView = isSearching ? searchCollectionView : activeCollectionView
            collectionView.layoutSubtreeIfNeeded()
            let tiles = collectionView.visibleItems()
                .sorted { lhs, rhs in
                    guard let left = collectionView.indexPath(for: lhs),
                          let right = collectionView.indexPath(for: rhs) else { return false }
                    return left.item < right.item
                }
                .compactMap { $0.view as? AppGridTileView }
            keyViews = [searchField, settingsButton]
                + [cachedCatalogButton, emptyStateReloadButton, emptyStateCachedButton, rescanButton, readOnlyCachedButton]
                + tiles
                + pageIndicator.keyViews
                + [previousPageButton, nextPageButton]
        }
        let visibleKeyViews = keyViews.filter { view in
            !isEffectivelyHidden(view) && (view as? NSControl)?.isEnabled != false
        }
        guard let first = visibleKeyViews.first else {
            nextKeyView = nil
            return
        }
        nextKeyView = first
        for (current, next) in zip(visibleKeyViews, visibleKeyViews.dropFirst()) {
            current.nextKeyView = next
        }
        visibleKeyViews.last?.nextKeyView = first
    }

    /// Tab/Shift-Tab inside a scrolling list. False at either end so the key
    /// loop can still leave the list. Does not move between grid-page icons.
    private func focusAdjacentPresentedItem(
        from itemID: UUID,
        in collectionView: NSCollectionView,
        by delta: Int
    ) -> Bool {
        guard collectionView === searchCollectionView || collectionView === folderOverlay.collectionView else {
            return false
        }
        let items = presentedItems(for: collectionView)
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return false }
        let next = index + delta
        guard items.indices.contains(next) else { return false }
        let indexPath = IndexPath(item: next, section: 0)
        collectionView.layoutSubtreeIfNeeded()
        if let frame = collectionView.collectionViewLayout?.layoutAttributesForItem(at: indexPath)?.frame {
            // Clip-view bounds are not the collection's coordinates once it has
            // scrolled, so the old test never asked for the offscreen item.
            // scrollToItems is what makes that item exist for the key focus.
            let barelyVisible = frame.insetBy(dx: 0, dy: frame.height * 0.5)
            if !collectionView.visibleRect.intersects(barelyVisible) {
                collectionView.scrollToItems(
                    at: Set([indexPath]),
                    scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge]
                )
                collectionView.layoutSubtreeIfNeeded()
            }
        }
        guard let tile = collectionView.item(at: indexPath)?.view else { return false }
        return window?.makeFirstResponder(tile) == true
    }

    /// Tab just before the first scrolling icon, or just after the last one.
    /// Search returns to the settings button or the search field. A folder
    /// returns to the close button or the title. Grid icons are not involved.
    private func focusOutsidePresentedList(in collectionView: NSCollectionView, by direction: Int) -> Bool {
        if collectionView === searchCollectionView {
            if direction < 0 {
                return window?.makeFirstResponder(settingsButton) == true
            }
            // The field selects everything when it becomes first responder.
            // The next letter would replace the query the user just tabbed back to.
            return focusSearchFieldAtEnd()
        }
        if collectionView === folderOverlay.collectionView {
            return direction < 0 ? folderOverlay.focusCloseButton() : folderOverlay.focusTitleField()
        }
        return false
    }

    /// The folder chrome uses Int.max when the drop is not on a grid cell.
    /// Put that member beside the folder instead of on the last page.
    private func placingUnspecifiedFolderExtraction(_ drop: LayoutDrop) -> LayoutDrop {
        guard case .folderMember(let folderID, _) = drop.source,
              case .topLevelIndex(let index) = drop.destination,
              index == Int.max else { return drop }
        return LayoutDrop(
            source: drop.source,
            destination: .topLevelIndex(LauncherLayout.topLevelIndexAfterFolder(folderID, in: layoutState))
        )
    }

    @discardableResult
    private func applyDrop(_ drop: LayoutDrop) -> Bool {
        guard isLayoutEditingEnabled,
              LauncherLayout.shouldAcceptLayoutDrop(isDismissing: launcherIsDismissing()) else { return false }
        let preview = dragPreview
        dragPreview = nil
        pendingMergeAnimation = nil
        let existingFolderIDs = Set(layoutState.folders.keys)
        let sourceFrame = preview?.frame ?? frameInRoot(for: drop.source)
        let targetFrame: CGRect?
        if case .merge(let target) = drop.destination {
            targetFrame = frameInRoot(for: target)
        } else {
            targetFrame = nil
        }
        let flyingIcon = preview?.image ?? iconImage(for: drop.source)

        switch LauncherLayout.applyDrop(drop, to: layoutState) {
        case .success(let next):
            guard next != layoutState else { return true }
            // NSCollectionView expects its data source to reflect an accepted drop
            // before the drag session finishes. Animation must not own layout state.
            let landingPage = LauncherLayout.pageContainingDrop(drop, in: next)
            commitLayout(next)
            // A full page has no empty cell after the last icon. The item is on
            // the next page; staying here makes it look lost. Not an edge-drag page turn.
            if let landingPage,
               openedFolderID == nil,
               !isSearching,
               !isPageTransitioning,
               !isPagingGesture,
               landingPage != currentPage {
                showPage(landingPage)
            }
            if case .merge(let target) = drop.destination {
                let folderID: UUID?
                if case .topLevel(let id) = target, next.folders[id] != nil {
                    folderID = id
                } else {
                    folderID = next.folders.keys.first { !existingFolderIDs.contains($0) }
                }
                pendingMergeAnimation = (
                    sourceFrame, targetFrame, flyingIcon, folderID,
                    folderID.map { !existingFolderIDs.contains($0) } ?? false
                )
            }
            return true
        case .failure(let error):
            if error == .folderFull {
                showToast("文件夹已满，最多容纳 25 个应用")
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            } else if error == .nestedFolder {
                showToast("不能将文件夹放入另一个文件夹")
            }
            return false
        }
    }

    private func promptForAlias(of candidate: AppCandidate, focusID: UUID, in collectionView: NSCollectionView) {
        guard isLayoutEditingEnabled, acceptsIconContextMenuAction() else { return }
        let field = AliasNameField(string: layoutState.appAliases[candidate.deduplicationKey] ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        field.placeholderString = candidate.displayName
        field.setAccessibilityLabel("\(candidate.displayName) 的别名")

        let alert = NSAlert()
        alert.messageText = "设置应用别名"
        alert.informativeText = "别名会用于显示和搜索；留空可恢复原名称。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        field.adoptAlertButtons(alert.buttons)
        // The accessory field is not in the window until the alert lays out.
        // Setting the first responder before that is ignored, so typing never
        // reaches the name until the user clicks it.
        alert.layout()
        alert.window.initialFirstResponder = field
        // The alert takes the keyboard. Remember the icon before the modal
        // returns, including when the user cancels and the layout is unchanged.
        // Hide aborts this loop. Save has already returned and is kept.
        isPromptingForAlias = true
        defer { isPromptingForAlias = false }
        let saved = alert.runModal() == .alertFirstButtonReturn
        if saved {
            let aliased = LauncherLayout.setAlias(
                field.stringValue,
                forApplicationKey: candidate.deduplicationKey,
                in: layoutState
            )
            if aliased != layoutState {
                commitLayout(aliased)
            }
        }
        restoreFocusAfterAlias(focusID, in: collectionView)
    }

    private func restoreFocusAfterAlias(_ id: UUID, in collectionView: NSCollectionView) {
        if collectionView === folderOverlay.collectionView, openedFolderID != nil {
            _ = focusPresentedItem(id: id, in: collectionView)
        } else if collectionView === searchCollectionView, isSearching {
            focusSearchResult(id)
        } else if openedFolderID == nil, !isSearching {
            focusGridEntry(id)
        }
    }

    private func hideApplication(_ candidate: AppCandidate) {
        // A click on the still-open menu would otherwise write the layout
        // after the launcher has started to leave.
        guard isLayoutEditingEnabled, acceptsIconContextMenuAction() else { return }
        commitLayout(LauncherLayout.hideApplication(withKey: candidate.deduplicationKey, in: layoutState))
    }

    @discardableResult
    private func renameOpenFolder(_ name: String) -> String {
        guard let openedFolderID else { return name }
        let current = layoutState.folders[openedFolderID]?.name ?? name
        guard isLayoutEditingEnabled else { return current }
        let renamed = LauncherLayout.renameFolder(openedFolderID, to: name, in: layoutState)
        guard renamed != layoutState else { return current }
        commitLayout(renamed)
        if let folder = layoutState.folders[openedFolderID] {
            folderOverlay.updateTitle(for: folder)
        }
        return layoutState.folders[openedFolderID]?.name ?? current
    }

    /// The dissolve fade keeps running after the launcher starts fading.
    /// While the fade is up, pin the grid to the opacity already on screen.
    /// A hidden window, or a cancelled fade, shows the grid at full opacity.
    func settleDissolvedGridFadeForDismissal() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldDissolvedGridFade(isDismissing: dismissing, isVisible: visible) {
            if pinInFlightDissolvedGridFade() {
                dissolvedGridFadeWaitsForLauncher = true
            }
            return
        }
        if dissolvedGridFadeWaitsForLauncher {
            applyDeferredDissolvedGridFade()
        }
    }

    /// The launch pulse keeps scaling after the launcher starts fading.
    /// While the fade is up, pin each icon to the scale already on screen.
    /// A hidden window, or a cancelled fade, returns those icons to normal
    /// size. The pulse is not replayed. A new press during the fade does
    /// not start one.
    func settleLaunchFeedbackForDismissal() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldLaunchFeedback(isDismissing: dismissing, isVisible: visible) {
            pinInFlightLaunchFeedback()
            return
        }
        if !heldLaunchFeedbackLayers.isEmpty {
            applyDeferredLaunchFeedback()
        }
    }

    func applyDeferredLaunchFeedback() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldLaunchFeedback(isDismissing: dismissing, isVisible: visible) {
            return
        }
        guard !heldLaunchFeedbackLayers.isEmpty else { return }
        let layers = heldLaunchFeedbackLayers
        heldLaunchFeedbackLayers.removeAll()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.removeAnimation(forKey: "launch-feedback")
            layer.transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    /// The page arrows fade in on hover. While the launcher fade is up, pin
    /// each arrow to the opacity already on screen. A hidden window hides
    /// them. A cancelled fade snaps to hover or focus, and does not replay.
    func settlePageButtonHoverForDismissal() {
        previousPageButton.settleHoverFadeForDismissal()
        nextPageButton.settleHoverFadeForDismissal()
    }

    func applyDeferredPageButtonHover() {
        previousPageButton.applyDeferredHoverFade()
        nextPageButton.applyDeferredHoverFade()
    }

    /// The preference changed. A pulse that is still running returns to the
    /// normal scale. Reduced motion has none, and turning it off does not
    /// finish the old one. A launcher fade that is holding the scale is left
    /// alone.
    private func snapInFlightLaunchFeedbackForMotionChange() {
        guard LauncherLayout.shouldSnapInFlightLaunchFeedback(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return }
        for tile in visibleGridTiles() {
            tile.snapLaunchFeedbackForMotionChange()
        }
    }

    /// The model scale stays at 1. The presentation scale is the frame on
    /// screen. Remember each layer so a later pass can restore it even if
    /// the tile has been reused.
    private func pinInFlightLaunchFeedback() {
        for tile in visibleGridTiles() {
            guard let layer = tile.layer,
                  layer.animation(forKey: "launch-feedback") != nil else { continue }
            let transform = layer.presentation()?.transform ?? layer.transform
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "launch-feedback")
            layer.transform = transform
            CATransaction.commit()
            if !heldLaunchFeedbackLayers.contains(where: { $0 === layer }) {
                heldLaunchFeedbackLayers.append(layer)
            }
        }
    }

    private func visibleGridTiles() -> [AppGridTileView] {
        let views = [
            activeCollectionView,
            stagingCollectionView,
            searchCollectionView,
            folderOverlay.collectionView
        ]
        var tiles: [AppGridTileView] = []
        for view in views {
            for item in view.visibleItems() {
                if let tile = item.view as? AppGridTileView {
                    tiles.append(tile)
                }
            }
        }
        return tiles
    }

    /// The preference changed. An open or close that is still running jumps
    /// to its end: an opening panel is fully open, a closing panel is gone.
    /// Reduced motion is only a shorter fade, and turning motion back on does
    /// not finish the old one. A launcher fade that is holding the frame is
    /// left alone. A settled panel is not animating, so it stays.
    private func snapInFlightFolderChromeForMotionChange() {
        guard LauncherLayout.shouldSnapInFlightFolderChromeAnimation(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return }
        guard folderOverlay.snapInFlightChromeForMotionChange() else { return }
        folderChromeWaitsForLauncher = false
    }

    /// The preference changed. A fade that is still running jumps to full
    /// opacity. Reduced motion is only shorter, and turning motion back on
    /// does not finish the old fade. A launcher fade that is holding the
    /// frame is left alone. Views that are not fading stay as they are.
    private func snapInFlightDissolvedGridFadeForMotionChange() {
        guard LauncherLayout.shouldSnapInFlightDissolvedGridFade(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return }
        var snapped = false
        for view in [activeCollectionView, stagingCollectionView] {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let keys = dissolvedGridFadeKeys(on: layer)
            guard !keys.isEmpty else { continue }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for key in keys {
                layer.removeAnimation(forKey: key)
            }
            view.alphaValue = 1
            layer.opacity = 1
            CATransaction.commit()
            snapped = true
        }
        if snapped {
            dissolvedGridFadeWaitsForLauncher = false
        }
    }

    func applyDeferredDissolvedGridFade() {
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        if LauncherLayout.shouldHoldDissolvedGridFade(isDismissing: dismissing, isVisible: visible) {
            return
        }
        guard dissolvedGridFadeWaitsForLauncher else { return }
        dissolvedGridFadeWaitsForLauncher = false
        finishDissolvedGridFade()
    }

    /// The grid fade uses `animator().alphaValue`, so the model opacity is
    /// already 1 and the presentation opacity is the frame on screen.
    private func pinInFlightDissolvedGridFade() -> Bool {
        var pinned = false
        for view in [activeCollectionView, stagingCollectionView] {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let keys = dissolvedGridFadeKeys(on: layer)
            guard !keys.isEmpty else { continue }
            let opacity = layer.presentation()?.opacity ?? layer.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for key in keys {
                layer.removeAnimation(forKey: key)
            }
            view.alphaValue = CGFloat(opacity)
            layer.opacity = opacity
            CATransaction.commit()
            pinned = true
        }
        return pinned
    }

    private func finishDissolvedGridFade() {
        dissolvedGridFadeWaitsForLauncher = false
        for view in [activeCollectionView, stagingCollectionView] {
            view.wantsLayer = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let layer = view.layer {
                for key in dissolvedGridFadeKeys(on: layer) {
                    layer.removeAnimation(forKey: key)
                }
                layer.opacity = 1
            }
            view.alphaValue = 1
            CATransaction.commit()
        }
    }

    private func dissolvedGridFadeKeys(on layer: CALayer) -> [String] {
        guard let keys = layer.animationKeys() else { return [] }
        return keys.filter { key in
            if key == "opacity" || key == "alphaValue" { return true }
            let path = (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath
            return path == "opacity" || path == "alphaValue"
        }
    }

    private func commitLayout(_ next: LayoutState) {
        let previousEntries = layoutState.orderedEntries
        let closingFolder = openedFolderID
        let dissolvesOpenFolder = closingFolder.map { next.folders[$0] == nil } ?? false
        // Reload drops whatever icon was focused. Remember it while the old
        // folder contents are still the ones on screen.
        let preservedFolderMember = dissolvesOpenFolder ? nil : focusedOpenFolderMember()
        let preservedGridFocus = focusedGridEntryID()
        let holdDissolvedGridFade = LauncherLayout.shouldHoldDissolvedGridFade(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        )
        // Blank the grid only when the fade-in is about to play. During the
        // launcher fade, leave the opacity already on screen.
        let playDissolvedGridFade = dissolvesOpenFolder
            && !holdDissolvedGridFade
            && window?.isVisible == true
            && !launcherIsDismissing()
        if playDissolvedGridFade {
            activeCollectionView.alphaValue = 0
        }
        if next.appAliases != layoutState.appAliases {
            appSearchIndex.setAliases(next.appAliases)
        }
        layoutState = next
        rebuildSearchableAppsCache()
        if let closingFolder, layoutState.folders[closingFolder] == nil {
            // The reload below throws away a focus set here. Restore it after.
            closeFolder(restoreFocus: false)
        }
        refreshPresentation(
            resetPage: false,
            preservedGridFocus: preservedGridFocus,
            gridFocusCaptured: true,
            preservedFolderMember: preservedFolderMember,
            folderFocusCaptured: true
        )
        if dissolvesOpenFolder, let closingFolder,
           let focusID = LauncherLayout.entryReplacingDissolvedFolder(
               folderID: closingFolder,
               previousEntries: previousEntries,
               currentEntries: layoutState.orderedEntries
           ) {
            focusGridEntry(focusID)
        } else if let preservedFolderMember, openedFolderID != nil {
            restoreOpenFolderMemberFocus(preservedFolderMember)
        }
        if dissolvesOpenFolder {
            if playDissolvedGridFade {
                dissolvedGridFadeWaitsForLauncher = false
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = prefersReducedMotion ? 0.12 : 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    activeCollectionView.animator().alphaValue = 1
                }
            } else if holdDissolvedGridFade {
                // Do not start a fade under the launcher fade. An in-flight
                // one stays on the frame it has reached.
                if pinInFlightDissolvedGridFade() {
                    dissolvedGridFadeWaitsForLauncher = true
                }
            } else {
                finishDissolvedGridFade()
            }
        }
        onLayoutChanged?(next)
    }

    private func frameInRoot(for ref: LayoutItemRef) -> CGRect? {
        let id: UUID
        switch ref {
        case .topLevel(let value):
            id = value
        case .folderMember(_, let itemID):
            id = itemID
        }
        let items = presentedItems(for: activeCollectionView)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let indexPath = IndexPath(item: index, section: 0)
        if let item = activeCollectionView.item(at: indexPath) {
            return item.view.convert(item.view.bounds, to: self)
        }
        guard let attributes = activeCollectionView.collectionViewLayout?.layoutAttributesForItem(at: indexPath) else {
            return nil
        }
        return activeCollectionView.convert(attributes.frame, to: self)
    }

    private func iconImage(for ref: LayoutItemRef) -> NSImage {
        let id: UUID
        switch ref {
        case .topLevel(let value):
            id = value
        case .folderMember(_, let itemID):
            id = itemID
        }
        if let key = layoutState.appKeys[id],
           let app = catalogByKey[key] {
            return WorkspaceIconCache.shared.cachedIcon(for: app)
                ?? WorkspaceIconCache.placeholder
        }
        return WorkspaceIconCache.placeholder
    }

    private func playMergeAnimation(from source: CGRect, to target: CGRect, image: NSImage) {
        removeMergeFlyer()
        let generation = mergeFlightGeneration

        let flyer = NSImageView(frame: source)
        flyer.image = image
        flyer.imageScaling = .scaleProportionallyUpOrDown
        flyer.wantsLayer = true
        addSubview(flyer, positioned: .above, relativeTo: nil)
        mergeAnimationView = flyer
        onDiagnosticEvent?("Merge flyer started: reducedMotion=\(prefersReducedMotion)")
        if prefersReducedMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                flyer.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak flyer] in
                Task { @MainActor [weak self, weak flyer] in
                    guard let self, self.mergeFlightGeneration == generation else { return }
                    flyer?.removeFromSuperview()
                    if self.mergeAnimationView === flyer {
                        self.mergeAnimationView = nil
                    }
                }
            })
            return
        }

        let dest = target.insetBy(dx: target.width * 0.28, dy: target.height * 0.28)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = mergeFlightDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            flyer.animator().frame = dest
            flyer.animator().alphaValue = 0.15
        }, completionHandler: { [weak self, weak flyer] in
            Task { @MainActor [weak self, weak flyer] in
                guard let self, self.mergeFlightGeneration == generation else { return }
                flyer?.removeFromSuperview()
                if self.mergeAnimationView === flyer {
                    self.mergeAnimationView = nil
                }
            }
        })
    }

    private func materializedFolderItem(_ folderID: UUID) -> NSCollectionViewItem? {
        // The folder may have landed on the page that is coming in, not the one
        // still recorded as current. Searching only the active grid skips the
        // landing animation for that drop.
        var collections: [(NSCollectionView, Int)] = [(activeCollectionView, currentPage)]
        if let stagingPage {
            collections.append((stagingCollectionView, stagingPage))
        }
        func item(in collectionView: NSCollectionView) -> NSCollectionViewItem? {
            collectionView.layoutSubtreeIfNeeded()
            let items = presentedItems(for: collectionView)
            guard let index = items.firstIndex(where: { $0.id == folderID }) else { return nil }
            return collectionView.item(at: IndexPath(item: index, section: 0))
        }
        for (collectionView, _) in collections {
            if let existing = item(in: collectionView) { return existing }
        }
        for (collectionView, page) in collections {
            let entries = LauncherLayout.entries(onPage: page, from: layoutState.orderedEntries)
            guard entries.contains(where: { $0.id == folderID }) else { continue }
            collectionView.reloadData()
            if let created = item(in: collectionView) { return created }
        }
        return nil
    }

    private func playFolderLandingAnimation(_ folderID: UUID, after delay: TimeInterval) {
        guard let item = materializedFolderItem(folderID) else { return }

        onDiagnosticEvent?("Folder landing started: reducedMotion=\(prefersReducedMotion)")
        item.view.wantsLayer = true
        guard let layer = item.view.layer else { return }
        if prefersReducedMotion {
            // The short fade used to return without a landing token, so a
            // dismiss could not pin it. Track it the same way as the spring.
            let dismissing = launcherIsDismissing()
            let visible = window?.isVisible == true
            guard LauncherLayout.shouldAnimateReducedMotionFolderLanding(
                isDismissing: dismissing,
                isVisible: visible
            ) else {
                // Hidden: draw the final tile. Still on screen: do not start
                // the fade, and do not jump a frame the hold already pinned.
                if LauncherLayout.shouldCommitFolderLanding(
                    isDismissing: dismissing,
                    isVisible: visible
                ) {
                    commitFolderLandingVisual(on: layer)
                    layer.setValue(nil, forKey: "folderLandingToken")
                    forgetTrackedFolderLanding(layer: layer, generation: nil)
                }
                return
            }
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = 0.12
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let generation = beginTrackedFolderLanding(on: layer)
            layer.add(animation, forKey: "folder-created")
            finishFolderLandingLater(on: layer, generation: generation, after: 0.12)
            return
        }

        var immediateSpringGeneration: Int?
        if delay > 0 {
            // Model opacity stays 0 until the flight ends. fillMode alone does not
            // hide a tile whose layer was just created for this drop.
            folderLandingGeneration &+= 1
            let generation = folderLandingGeneration
            layer.opacity = 0
            let reveal = CABasicAnimation(keyPath: "opacity")
            reveal.fromValue = 0
            reveal.toValue = 1
            reveal.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            reveal.duration = 0.22
            reveal.fillMode = .both
            reveal.isRemovedOnCompletion = false
            reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
            beginTrackedFolderLanding(on: layer, generation: generation)
            layer.add(reveal, forKey: "folder-created-opacity")
            finishFolderLandingLater(on: layer, generation: generation, after: delay + reveal.duration)
        }
        let animation = CASpringAnimation(keyPath: "transform.scale")
        animation.fromValue = 0.68
        animation.toValue = 1.0
        animation.damping = 13
        animation.initialVelocity = 1.0
        animation.mass = 0.8
        animation.stiffness = 180
        animation.duration = animation.settlingDuration
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.fillMode = .backwards
        } else {
            // A drop into an existing folder does not wait for the flight.
            // That spring used to keep scaling under the launcher fade.
            immediateSpringGeneration = beginTrackedFolderLanding(on: layer)
        }
        layer.add(animation, forKey: "folder-created")
        if let generation = immediateSpringGeneration {
            finishFolderLandingLater(on: layer, generation: generation, after: animation.duration)
        }
    }

    /// Remember this tile so a dismiss can pin the frame already on screen.
    private func beginTrackedFolderLanding(on layer: CALayer) -> Int {
        folderLandingGeneration &+= 1
        beginTrackedFolderLanding(on: layer, generation: folderLandingGeneration)
        return folderLandingGeneration
    }

    private func beginTrackedFolderLanding(on layer: CALayer, generation: Int) {
        layer.setValue(generation, forKey: "folderLandingToken")
        heldFolderLandings.removeAll { $0.layer == nil || $0.layer === layer }
        heldFolderLandings.append(HeldFolderLanding(layer: layer, generation: generation))
        // A new landing only starts while the launcher is up. Leave a hold
        // that is still waiting: clearing it would abandon the other tiles.
        if LauncherLayout.shouldCommitFolderLanding(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) {
            folderLandingWaitsForLauncher = false
        }
    }

    /// Drop one landing, or every generation on this layer when `generation`
    /// is nil. The wait flag stays while another landing is still held.
    private func forgetTrackedFolderLanding(layer: CALayer, generation: Int?) {
        heldFolderLandings.removeAll { entry in
            guard let tracked = entry.layer else { return true }
            guard tracked === layer else { return false }
            guard let generation else { return true }
            return entry.generation == generation
        }
        if heldFolderLandings.isEmpty {
            folderLandingWaitsForLauncher = false
        }
    }

    private func finishFolderLandingLater(on layer: CALayer, generation: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak layer] in
            guard let layer, layer.value(forKey: "folderLandingToken") as? Int == generation else { return }
            guard let self else {
                layer.removeAnimation(forKey: "folder-created-opacity")
                layer.removeAnimation(forKey: "folder-created")
                layer.opacity = 1
                layer.transform = CATransform3DIdentity
                layer.setValue(nil, forKey: "folderLandingToken")
                return
            }
            self.finishFolderLandingIfAllowed(on: layer, generation: generation)
        }
    }

    /// Final opacity and scale, without playing the fade or the spring.
    private func commitFolderLandingVisual(on layer: CALayer) {
        layer.removeAnimation(forKey: "folder-created-opacity")
        layer.removeAnimation(forKey: "folder-created")
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
    }

    /// The reveal and the spring are already on the layer, sometimes with a
    /// begin time still in the future. Reduced motion's 0.12s fade and a
    /// spring that did not wait for the flight are tracked the same way.
    /// Every landing still in flight is pinned, not only the latest: a later
    /// tile used to take the only slot and leave the earlier spring running.
    /// While the fade is up, pin each tile to the frame it has reached so
    /// that reveal does not start underneath. A hidden window, or a fade
    /// that was cancelled, commits the final opacity and scale.
    func settleFolderLandingForDismissal() {
        heldFolderLandings.removeAll { $0.layer == nil }
        let snapshots = heldFolderLandings
        guard !snapshots.isEmpty else {
            folderLandingWaitsForLauncher = false
            return
        }
        for held in snapshots {
            guard let layer = held.layer else { continue }
            finishFolderLandingIfAllowed(on: layer, generation: held.generation)
        }
    }

    func applyDeferredFolderLanding() {
        guard folderLandingWaitsForLauncher else { return }
        settleFolderLandingForDismissal()
    }

    private func finishFolderLandingIfAllowed(on layer: CALayer, generation: Int) {
        let tokenMatches = layer.value(forKey: "folderLandingToken") as? Int == generation
        guard tokenMatches else {
            forgetTrackedFolderLanding(layer: layer, generation: generation)
            return
        }
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        let tracked = heldFolderLandings.contains { $0.layer === layer && $0.generation == generation }
        if LauncherLayout.shouldPinTrackedFolderLanding(
            isTracked: tracked,
            tokenMatches: true,
            isDismissing: dismissing,
            isVisible: visible
        ) {
            freezeFolderLanding(layer)
            folderLandingWaitsForLauncher = true
            return
        }
        guard LauncherLayout.shouldCommitFolderLanding(
            isDismissing: dismissing,
            isVisible: visible
        ) else { return }
        forgetTrackedFolderLanding(layer: layer, generation: generation)
        commitFolderLanding(on: layer, generation: generation)
    }

    private func freezeFolderLanding(_ layer: CALayer) {
        let presented = layer.presentation()
        let opacity = presented?.opacity ?? layer.opacity
        let transform = presented?.transform ?? layer.transform
        layer.removeAnimation(forKey: "folder-created-opacity")
        layer.removeAnimation(forKey: "folder-created")
        layer.opacity = opacity
        layer.transform = transform
    }

    private func commitFolderLanding(on layer: CALayer, generation: Int) {
        guard layer.value(forKey: "folderLandingToken") as? Int == generation else { return }
        layer.removeAnimation(forKey: "folder-created-opacity")
        layer.removeAnimation(forKey: "folder-created")
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        layer.setValue(nil, forKey: "folderLandingToken")
    }

    private func topLevelSourceIndex(_ source: LayoutItemRef) -> Int? {
        guard case .topLevel(let id) = source else { return nil }
        return layoutState.orderedEntries.firstIndex(where: { $0.id == id })
    }

    private func topLevelPageIndex(for collectionView: NSCollectionView) -> Int {
        if collectionView === stagingCollectionView {
            return stagingPage ?? currentPage
        }
        return currentPage
    }

    private func topLevelDropIndex(page: Int, localIndex: Int, source: LayoutItemRef) -> Int {
        LauncherLayout.topLevelDropIndex(
            page: page,
            localIndex: localIndex,
            sourceIndex: topLevelSourceIndex(source),
            countBeforeRemoval: layoutState.orderedEntries.count
        )
    }

    private func handleHostDrop(_ info: NSDraggingInfo, on collectionView: NSCollectionView?) -> Bool {
        guard LauncherLayout.shouldAcceptLayoutDrop(isDismissing: launcherIsDismissing()),
              let collectionView,
              let source = draggedItem(from: info) else { return false }
        let point = collectionView.convert(info.draggingLocation, from: nil)
        let items = presentedItems(for: collectionView)
        let destination: LayoutDestination
        if let indexPath = collectionView.indexPathForItem(at: point),
           items.indices.contains(indexPath.item),
           let item = collectionView.item(at: indexPath) {
            let local = item.view.convert(point, from: collectionView)
            let center = item.view.bounds.insetBy(dx: item.view.bounds.width * 0.22, dy: item.view.bounds.height * 0.22)
            if center.contains(local) {
                destination = .merge(.topLevel(items[indexPath.item].id))
            } else {
                let gap = LauncherLayout.reorderGapIndex(
                    hoveredItem: indexPath.item,
                    pointerX: local.x,
                    itemMinX: item.view.bounds.minX,
                    itemWidth: item.view.bounds.width,
                    itemCount: items.count
                )
                destination = .topLevelIndex(
                    topLevelDropIndex(
                        page: topLevelPageIndex(for: collectionView),
                        localIndex: gap,
                        source: source
                    )
                )
            }
        } else {
            destination = .topLevelIndex(
                topLevelDropIndex(
                    page: topLevelPageIndex(for: collectionView),
                    localIndex: items.count,
                    source: source
                )
            )
        }
        return applyDrop(LayoutDrop(source: source, destination: destination))
    }

    private func draggedItem(from info: NSDraggingInfo) -> LayoutItemRef? {
        guard let data = info.draggingPasteboard.data(forType: layoutItemPasteboardType),
              let payload = try? JSONDecoder().decode(DraggedLayoutItem.self, from: data) else { return nil }
        if let folderID = payload.folderID {
            return .folderMember(folderID: folderID, itemID: payload.itemID)
        }
        return .topLevel(payload.itemID)
    }

    private func isDragSource(_ itemID: UUID, folderID: UUID?, info: NSDraggingInfo) -> Bool {
        switch draggedItem(from: info) {
        case .topLevel(let id):
            return folderID == nil && id == itemID
        case .folderMember(let sourceFolderID, let id):
            return folderID == sourceFolderID && id == itemID
        case nil:
            return false
        }
    }

    private func activateItem(withID itemID: UUID, in collectionView: NSCollectionView) {
        guard let item = presentedItems(for: collectionView).first(where: { $0.id == itemID }) else { return }
        didConsumeClick = true
        switch item {
        case .app(_, let candidate):
            onCandidateSelected?(candidate)
        case .folder(let folder, _):
            openFolder(folder.id)
        }
    }

    private func currentAppCandidate(withID itemID: UUID, in collectionView: NSCollectionView) -> AppCandidate? {
        guard let item = presentedItems(for: collectionView).first(where: { $0.id == itemID }),
              case .app(_, let candidate) = item else { return nil }
        return candidate
    }

    private func beginItemDrag(withID itemID: UUID, in collectionView: PagingCollectionView, event: NSEvent) -> Bool {
        // Only the move that crosses the drag threshold calls this. A session
        // already tracking does not. Starting one during the fade, or after
        // the window has ordered out, blanks the icon until that session ends.
        guard LauncherLayout.shouldBeginLayoutDrag(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return false }
        let reorderingOpenFolder = collectionView === folderOverlay.collectionView && openedFolderID != nil
        // Search results themselves do not reorder. A folder opened on top of
        // them still does: the search grid underneath is not the drag source.
        guard isLayoutEditingEnabled, reorderingOpenFolder || !isSearching else { return false }
        let items = presentedItems(for: collectionView)
        guard let itemIndex = items.firstIndex(where: { $0.id == itemID }) else { return false }
        pendingMergeAnimation = nil
        mergeFlightWaitsForLauncher = false
        removeMergeFlyer()
        let indexPath = IndexPath(item: itemIndex, section: 0)
        let presented = items[itemIndex]
        restoreDragSourceTile()
        clearReorderSlides()
        let payload: DraggedLayoutItem
        if collectionView === folderOverlay.collectionView, let folderID = openedFolderID {
            payload = DraggedLayoutItem(itemID: presented.id, folderID: folderID)
        } else {
            payload = DraggedLayoutItem(itemID: presented.id, folderID: nil)
        }
        let pasteboardItem = NSPasteboardItem()
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        pasteboardItem.setData(data, forType: layoutItemPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let sourceRef: LayoutItemRef
        if collectionView === folderOverlay.collectionView, let folderID = openedFolderID {
            sourceRef = .folderMember(folderID: folderID, itemID: presented.id)
        } else {
            sourceRef = .topLevel(presented.id)
        }
        if let itemView = collectionView.item(at: indexPath)?.view {
            let frame = itemView.convert(itemView.bounds, to: self)
            let sourceImage = itemView.draggingImage()
            dragPreview = (sourceRef, frame, sourceImage)
            let sourceInCollection = itemView.convert(itemView.bounds, to: collectionView)
            let presentation = LauncherLayout.dragLiftPresentation(
                for: sourceInCollection.size,
                reducesMotion: prefersReducedMotion
            )
            draggingItem.setDraggingFrame(
                presentation.canvasFrame(centering: sourceInCollection),
                contents: dragLiftImage(from: sourceImage, presentation: presentation)
            )
            itemView.layer?.opacity = 0
            dragSourceTile = itemView as? AppGridTileView
            let session = collectionView.beginDraggingSession(
                with: [draggingItem], event: event, source: collectionView
            )
            activeDragLift = ActiveDragLift(
                session: session,
                sourceImage: sourceImage,
                sourceSize: sourceInCollection.size,
                showsLift: presentation.shadowOpacity > 0
            )
            dragLiftDropWaitsForLauncher = false
            didConsumeClick = true
            return true
        }
        collectionView.beginDraggingSession(with: [draggingItem], event: event, source: collectionView)
        didConsumeClick = true
        return true
    }

    private func prefetchIcons(for candidates: [AppCandidate]) {
        iconPrefetchTask?.cancel()
        let visibleCandidates = Array(candidates.prefix(LauncherLayout.pageCapacity * 2))
        let firstBatchCount = min(LauncherLayout.pageCapacity, visibleCandidates.count)
        let signposter = iconSignposter
        iconPrefetchTask = Task {
            guard firstBatchCount > 0 else { return }
            let interval = signposter.beginInterval("First35IconPrefetch")
            var firstBatchFinished = false
            defer {
                if !firstBatchFinished {
                    signposter.endInterval("First35IconPrefetch", interval, "cancelled")
                }
            }
            do {
                let firstPage = Array(visibleCandidates.prefix(firstBatchCount))
                try await WorkspaceIconCache.shared.prefetchIcons(for: firstPage)
                guard !Task.isCancelled else { return }
                signposter.endInterval("First35IconPrefetch", interval)
                firstBatchFinished = true

                let remaining = Array(visibleCandidates.dropFirst(firstBatchCount))
                try await WorkspaceIconCache.shared.prefetchIcons(for: remaining)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func setFolderBackdrop(open: Bool) {
        if !open {
            resetFolderBackdrop(gridViewport)
            resetFolderBackdrop(searchScrollView)
            return
        }
        let backdrop = isSearching ? searchScrollView : gridViewport
        resetFolderBackdrop(backdrop === gridViewport ? searchScrollView : gridViewport)
        presentFolderBackdrop(backdrop)
    }

    private func resetFolderBackdrop(_ view: NSView) {
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "folderBackdropScale")
        layer.removeAnimation(forKey: "folderBackdropOpacity")
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        layer.filters = nil
    }

    private func presentFolderBackdrop(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "folderBackdropScale")
        layer.removeAnimation(forKey: "folderBackdropOpacity")
        let reduced = prefersReducedMotion
        let style = LauncherLayout.folderBackdropStyle(open: true, reducesMotion: reduced)
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = style.opacity
        fade.duration = reduced ? 0.12 : 0.22
        fade.timingFunction = timing
        layer.opacity = Float(style.opacity)
        layer.add(fade, forKey: "folderBackdropOpacity")
        guard style.scale != 1 || style.blurs else {
            layer.transform = CATransform3DIdentity
            layer.filters = nil
            return
        }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = style.scale
        scale.duration = 0.22
        scale.timingFunction = timing
        layer.transform = CATransform3DMakeScale(style.scale, style.scale, 1)
        layer.add(scale, forKey: "folderBackdropScale")
        view.layerUsesCoreImageFilters = true
        if style.blurs, let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 6]) {
            layer.filters = [blur]
        } else {
            layer.filters = nil
        }
    }

    private func openFolder(_ id: UUID) {
        guard acceptsPointerActivation() else { return }
        onDiagnosticEvent?("Folder open requested: id=\(id.uuidString)")
        guard let folder = layoutState.folders[id] else { return }
        settleInterruptedPaging()
        // Record the entry before AppKit and accessibility mutations can fail synchronously.
        onDiagnosticEvent?("Folder open started: id=\(id.uuidString); storedMembers=\(folder.itemIDs.count)")
        openedFolderID = id
        updatePagingControls()
        setLauncherContentAccessibilityHidden(true)
        let items = presentedItems(for: folderOverlay.collectionView)
        folderOverlay.show(folder: folder, items: items)
        NSAccessibility.post(element: self, notification: .layoutChanged)
        folderOverlay.layoutSubtreeIfNeeded()
        folderOverlay.layoutFolderGrid(itemCount: items.count)
        folderOverlay.scrollContentsToTop()
        folderOverlay.animateOpen(reducesMotion: prefersReducedMotion)
        setFolderBackdrop(open: true)
        rebuildKeyViewLoop()
        onDiagnosticEvent?("Folder open prepared: id=\(id.uuidString); members=\(items.count)")
        Task { @MainActor in
            guard self.openedFolderID == id else { return }
            folderOverlay.layoutFolderGrid(itemCount: self.presentedItems(for: folderOverlay.collectionView).count)
            self.rebuildKeyViewLoop()
            // The title can already be editing by the time this hop runs.
            // Moving focus back to the first icon would cancel that edit.
            if let responder = self.window?.firstResponder as? NSView,
               responder === self.folderOverlay || responder.isDescendant(of: self.folderOverlay) {
                return
            }
            let keyViews = folderOverlay.keyViews
            if let target = keyViews.first(where: { $0 is AppGridTileView }) ?? keyViews.first,
               self.window?.makeFirstResponder(target) == true {
                NSAccessibility.post(element: target, notification: .focusedUIElementChanged)
            }
        }
    }

    private func closeFolder(immediately: Bool = false, restoreFocus: Bool = true) {
        let closingFolderID = openedFolderID
        guard closingFolderID != nil else { return }
        // Moving focus ends title editing and would save whatever is marked.
        folderOverlay.discardMarkedTitleComposition()
        let dissolved = closingFolderID.map { layoutState.folders[$0] == nil } ?? false
        if let closingFolderID {
            onDiagnosticEvent?("Folder close requested: id=\(closingFolderID.uuidString)")
        }
        openedFolderID = nil
        setFolderBackdrop(open: false)
        folderOverlay.animateClose(reducesMotion: prefersReducedMotion, immediately: immediately || dissolved)
        updatePagingControls()
        setLauncherContentAccessibilityHidden(false)
        NSAccessibility.post(element: self, notification: .layoutChanged)
        rebuildKeyViewLoop()
        if restoreFocus, let closingFolderID {
            focusGridEntry(closingFolderID)
        }
    }

    /// Focus a grid entry, turning to its page when a dissolve or a layout
    /// shift left it off the page that was open. No page animation: the folder
    /// overlay is already closing.
    private func focusedOpenFolderMember() -> (id: UUID, index: Int)? {
        guard openedFolderID != nil,
              let tile = window?.firstResponder as? AppGridTileView,
              tile.isDescendant(of: folderOverlay) else { return nil }
        let collectionView = folderOverlay.collectionView
        let index: Int?
        if let item = tile.nextResponder as? NSCollectionViewItem {
            index = collectionView.indexPath(for: item)?.item
        } else {
            index = collectionView.visibleItems().first { $0.view === tile }
                .flatMap { collectionView.indexPath(for: $0)?.item }
        }
        guard let index else { return nil }
        let items = presentedItems(for: collectionView)
        guard items.indices.contains(index) else { return nil }
        return (items[index].id, index)
    }

    /// The open folder is still here after a rename, scan, or reorder. Put the
    /// keyboard back on the same member, or the slot it left when that member is gone.
    private func restoreOpenFolderMemberFocus(_ preserved: (id: UUID, index: Int)) {
        guard openedFolderID != nil, !folderOverlay.isEditingTitle else { return }
        let items = presentedItems(for: folderOverlay.collectionView)
        if items.contains(where: { $0.id == preserved.id }) {
            _ = focusPresentedItem(id: preserved.id, in: folderOverlay.collectionView)
            return
        }
        guard let slot = LauncherLayout.focusSlot(previousSlot: preserved.index, itemCount: items.count) else {
            _ = folderOverlay.focusCloseButton()
            return
        }
        _ = focusPresentedItem(id: items[slot].id, in: folderOverlay.collectionView)
    }

    @discardableResult
    private func focusPresentedItem(id: UUID, in collectionView: NSCollectionView) -> Bool {
        collectionView.layoutSubtreeIfNeeded()
        let items = presentedItems(for: collectionView)
        guard let itemIndex = items.firstIndex(where: { $0.id == id }) else { return false }
        let indexPath = IndexPath(item: itemIndex, section: 0)
        if let frame = collectionView.collectionViewLayout?.layoutAttributesForItem(at: indexPath)?.frame {
            let barelyVisible = frame.insetBy(dx: 0, dy: frame.height * 0.5)
            if !collectionView.visibleRect.intersects(barelyVisible) {
                collectionView.scrollToItems(
                    at: Set([indexPath]),
                    scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge]
                )
                collectionView.layoutSubtreeIfNeeded()
            }
        } else {
            collectionView.scrollToItems(
                at: Set([indexPath]),
                scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge]
            )
            collectionView.layoutSubtreeIfNeeded()
        }
        guard let tile = collectionView.item(at: indexPath)?.view,
              window?.makeFirstResponder(tile) == true else { return false }
        NSAccessibility.post(element: tile, notification: .focusedUIElementChanged)
        return true
    }

    private func focusGridEntry(_ id: UUID) {
        if isSearching {
            focusSearchResult(id)
            return
        }
        guard let index = layoutState.orderedEntries.firstIndex(where: { $0.id == id }) else {
            window?.makeFirstResponder(self)
            return
        }
        let page = LauncherLayout.pageIndex(containingEntryAt: index)
        let count = LauncherLayout.pageCount(forEntryCount: layoutState.orderedEntries.count)
        if count > 0 {
            let bounded = min(max(page, 0), count - 1)
            if bounded != currentPage {
                currentPage = bounded
                stagingPage = nil
                isPagingGesture = false
                layoutCollectionViews()
                activeCollectionView.reloadData()
                updatePagingControls()
                rebuildKeyViewLoop()
            }
        }
        activeCollectionView.layoutSubtreeIfNeeded()
        let items = presentedItems(for: activeCollectionView)
        guard let itemIndex = items.firstIndex(where: { $0.id == id }) else {
            window?.makeFirstResponder(self)
            return
        }
        let indexPath = IndexPath(item: itemIndex, section: 0)
        if activeCollectionView.item(at: indexPath) == nil {
            activeCollectionView.reloadData()
            activeCollectionView.layoutSubtreeIfNeeded()
        }
        guard let tile = activeCollectionView.item(at: indexPath)?.view as? AppGridTileView,
              window?.makeFirstResponder(tile) == true else {
            window?.makeFirstResponder(self)
            return
        }
        NSAccessibility.post(element: tile, notification: .focusedUIElementChanged)
    }

    /// Tab from Settings enters the results already on screen. The first hit
    /// would scroll a paged list back to the top. An empty list returns false
    /// so Tab continues around the key loop.
    private func focusFirstVisibleSearchResult() -> Bool {
        guard isSearching else { return false }
        searchCollectionView.layoutSubtreeIfNeeded()
        let items = currentPresentedItems()
        let visibleIndexes = searchCollectionView.visibleItems().compactMap { item in
            searchCollectionView.indexPath(for: item)?.item
        }.sorted()
        if let index = visibleIndexes.first(where: { items.indices.contains($0) }) {
            return focusPresentedItem(id: items[index].id, in: searchCollectionView)
        }
        guard let first = items.first else { return false }
        return focusPresentedItem(id: first.id, in: searchCollectionView)
    }

    /// Search stays up under an opened folder. Closing it should return to that
    /// folder's result, not the window. A missing hit leaves the query editable.
    private func focusSearchResult(_ id: UUID) {
        searchCollectionView.layoutSubtreeIfNeeded()
        let items = presentedItems(for: searchCollectionView)
        guard let itemIndex = items.firstIndex(where: { $0.id == id }) else {
            focusSearchFieldAtEnd()
            return
        }
        let indexPath = IndexPath(item: itemIndex, section: 0)
        if let frame = searchCollectionView.collectionViewLayout?.layoutAttributesForItem(at: indexPath)?.frame {
            let barelyVisible = frame.insetBy(dx: 0, dy: frame.height * 0.5)
            if !searchCollectionView.visibleRect.intersects(barelyVisible) {
                searchCollectionView.scrollToItems(
                    at: Set([indexPath]),
                    scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge]
                )
                searchCollectionView.layoutSubtreeIfNeeded()
            }
        }
        guard let tile = searchCollectionView.item(at: indexPath)?.view as? AppGridTileView,
              window?.makeFirstResponder(tile) == true else {
            focusSearchFieldAtEnd()
            return
        }
        NSAccessibility.post(element: tile, notification: .focusedUIElementChanged)
    }

    private func setLauncherContentAccessibilityHidden(_ hidden: Bool) {
        searchField.setAccessibilityHidden(hidden)
        searchField.isEnabled = !hidden
        settingsButton.setAccessibilityHidden(hidden)
        settingsButton.isEnabled = !hidden
        gridViewport.setAccessibilityHidden(hidden)
        searchScrollView.setAccessibilityHidden(hidden)
        footerControls.setAccessibilityHidden(hidden)
        pageIndicator.setAccessibilityHidden(hidden)
        previousPageButton.setAccessibilityHidden(hidden)
        nextPageButton.setAccessibilityHidden(hidden)
        messageLabel.setAccessibilityHidden(hidden)
        emptyStateView.setAccessibilityHidden(hidden)
        for collectionView in [activeCollectionView, stagingCollectionView, searchCollectionView] {
            collectionView.setAccessibilityHidden(hidden)
            for item in collectionView.visibleItems() {
                (item.view as? AppGridTileView)?.setAccessibilitySuppressed(hidden)
            }
        }
        for dot in pageIndicator.arrangedSubviews {
            dot.setAccessibilityHidden(hidden)
        }
    }

    private func showPage(_ page: Int) {
        guard openedFolderID == nil, !isSearching, pageCount > 0 else { return }
        let boundedPage = min(max(page, 0), pageCount - 1)
        if isPageTransitioning {
            queuedPage = boundedPage
            updatePagingControls()
            pageIndicator.configure(pageCount: pageCount, selectedPage: boundedPage)
            return
        }
        guard boundedPage != currentPage else { return }
        transitionToPage(boundedPage, direction: boundedPage > currentPage ? 1 : -1)
    }

    @objc private func showPreviousPage() {
        guard acceptsPointerActivation() else { return }
        didConsumeClick = true
        movePage(by: -1)
    }

    @objc private func showNextPage() {
        guard acceptsPointerActivation() else { return }
        didConsumeClick = true
        movePage(by: 1)
    }

    private func updatePagingControls() {
        let hasMultiplePages = openedFolderID == nil && !isSearching && pageCount > 1
        let anchor = LauncherLayout.pagingControlPage(
            currentPage: currentPage,
            inFlightPage: transitionTargetPage,
            queuedPage: queuedPage
        )
        previousPageButton.isHidden = !hasMultiplePages || anchor <= 0
        nextPageButton.isHidden = !hasMultiplePages || anchor >= pageCount - 1
        updateFooterHint()
        recoverFocusFromHiddenPagingControl()
    }

    /// Previous/next disappear on the first and last page. Leaving focus on the
    /// hidden button swallows later arrow keys.
    private func recoverFocusFromHiddenPagingControl() {
        let responder = window?.firstResponder
        let previousFocused = responder === previousPageButton
        let nextFocused = responder === nextPageButton
        guard previousFocused || nextFocused else { return }
        if previousFocused, !previousPageButton.isHidden { return }
        if nextFocused, !nextPageButton.isHidden { return }
        if !previousPageButton.isHidden {
            window?.makeFirstResponder(previousPageButton)
            return
        }
        if !nextPageButton.isHidden {
            window?.makeFirstResponder(nextPageButton)
            return
        }
        window?.makeFirstResponder(self)
    }

    private func updateFooterHint() {
        footerControls.isHidden = openedFolderID != nil
        if isSearching {
            dragHintLabel.isHidden = true
            navigationHintLabel.stringValue = "Esc 清除搜索"
            return
        }

        dragHintLabel.isHidden = !isLayoutEditingEnabled || layoutState.orderedEntries.isEmpty
        dragHintLabel.stringValue = pageCount > 1 ? "拖拽整理 · 悬停箭头跨页" : "拖拽整理"
        navigationHintLabel.stringValue = pageCount > 1 ? "← → 翻页 · Esc 返回" : "Esc 返回"
    }

    private var isPaging: Bool { isPagingGesture || isPageTransitioning }

    private func updatePageDrag(_ distance: CGFloat) {
        guard !isPageTransitioning else { return }
        guard distance != 0 else { return }
        isPagingGesture = true
        // Reduced motion keeps the current page still. The gesture stays so
        // the release can still turn. A launcher fade that is holding the
        // frame also stops further travel.
        guard LauncherLayout.shouldFollowPageDrag(
            reducesMotion: prefersReducedMotion,
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return }
        let direction = distance < 0 ? 1 : -1
        let targetPage = currentPage + direction
        let pageWidth = max(gridViewport.bounds.width, 1)
        let clampedDistance = min(max(distance, -pageWidth), pageWidth)
        let progress = min(abs(clampedDistance) / pageWidth, 1)
        guard (0..<pageCount).contains(targetPage) else {
            pageIndicator.configure(pageCount: pageCount, selectedPage: currentPage)
            positionPages(activeX: clampedDistance * 0.04, stagingX: nil)
            stagingHost.park(in: gridViewport.bounds)
            return
        }

        prepareStagingPage(targetPage)
        pageIndicator.setTransition(from: currentPage, to: targetPage, progress: progress)
        let travel = pageTravelDistance(for: pageWidth)
        positionPages(
            activeX: clampedDistance * 0.18,
            stagingX: CGFloat(direction) * travel + clampedDistance * 0.18,
            activeAlpha: 1 - progress,
            stagingAlpha: progress
        )
    }

    private func finishPageDrag(_ direction: Int?) {
        // A flick that ends during a transition used to be dropped. Queue it
        // the same way as a key or page button. A gesture that does not meet
        // the turn threshold must not interrupt the animation already running.
        if isPageTransitioning {
            if let direction {
                movePage(by: direction)
            }
            return
        }
        switch LauncherLayout.pageDragFinish(
            direction: direction,
            isVisuallyDragging: isPagingGesture,
            currentPage: currentPage,
            pageCount: pageCount
        ) {
        case .ignore:
            return
        case .settle:
            settleCurrentPage()
        case .turn(let targetPage):
            transitionToPage(targetPage, direction: targetPage > currentPage ? 1 : -1)
        }
    }

    private func transitionToPage(_ targetPage: Int, direction: Int) {
        transitionTargetPage = targetPage
        pageTurnGridSlot = focusedGridSlot(in: activeCollectionView)
        pageTurnFocusedTile = window?.firstResponder as? AppGridTileView
        prepareStagingPage(targetPage)
        let pageWidth = max(gridViewport.bounds.width, 1)
        let travel = pageTravelDistance(for: pageWidth)
        isPagingGesture = true
        isPageTransitioning = true
        updatePagingControls()
        pageIndicator.setTransition(from: currentPage, to: targetPage, progress: 1)
        positionPages(
            activeX: -CGFloat(direction) * travel,
            stagingX: 0,
            activeAlpha: 0,
            stagingAlpha: 1,
            animated: true,
            finishPage: targetPage
        )
    }

    private func completePageTransition(to targetPage: Int) {
        let previousGridSlot = pageTurnGridSlot
        pageTurnGridSlot = nil
        currentPage = targetPage
        pageIndicator.configure(
            pageCount: pageCount,
            selectedPage: LauncherLayout.pagingControlPage(
                currentPage: currentPage,
                inFlightPage: transitionTargetPage,
                queuedPage: queuedPage
            )
        )
        updatePagingControls()
        swap(&activeHost, &stagingHost)
        stagingPage = nil
        isPageTransitioning = false
        isPagingGesture = false
        transitionTargetPage = nil
        // Motion ignored while the animation ran must not rubber-band the new page.
        discardInProgressPageGestures()
        layoutCollectionViews()
        updateGridAccessibilityChildren(for: activeCollectionView)
        rebuildKeyViewLoop()
        // Search is covering the grid. Restoring a grid slot would take ⌘F
        // or a result away when a turn that started earlier finally ends.
        // A turn that is still the keyboard's owner should land on the new
        // page. Settings, the search field, or another control reached during
        // the animation keeps what the user just focused.
        if openedFolderID == nil, !isSearching, let previousGridSlot, pageTurnStillOwnsFocus() {
            applyGridFocusAfterPageTurn(from: previousGridSlot)
        } else if focusLeftOnDepartingPage() {
            // Tab can land on another icon of the page that is now parked.
            // That tile is still first responder, so Return would open it off screen.
            moveFocusOffDepartedGridTile()
        }
        pageTurnFocusedTile = nil
        runQueuedPage()
    }

    /// True when the page turn is still what the keyboard is doing. A tile that
    /// stayed focused, or focus that fell back to the window with that tile,
    /// moves to the arriving page. Anything the user focused in between stays.
    private func pageTurnStillOwnsFocus() -> Bool {
        guard let responder = window?.firstResponder else { return true }
        if let tile = pageTurnFocusedTile, responder === tile { return true }
        if responder === self || responder === window { return true }
        return false
    }

    /// After the swap, the page that just left is the staging host. An icon
    /// there is not the one this turn started with, and it is no longer on screen.
    private func focusLeftOnDepartingPage() -> Bool {
        guard let tile = window?.firstResponder as? AppGridTileView else { return false }
        if let original = pageTurnFocusedTile, tile === original { return false }
        return tile.isDescendant(of: stagingHost)
    }

    private func focusedGridSlot(in collectionView: NSCollectionView) -> Int? {
        guard let tile = window?.firstResponder as? AppGridTileView,
              tile.isDescendant(of: collectionView) else { return nil }
        if let item = tile.nextResponder as? NSCollectionViewItem,
           let index = collectionView.indexPath(for: item)?.item {
            return index
        }
        for candidate in collectionView.visibleItems() where candidate.view === tile {
            return collectionView.indexPath(for: candidate)?.item
        }
        return nil
    }

    private func applyGridFocusAfterPageTurn(from previousSlot: Int) {
        let itemCount = presentedItems(for: currentPage).count
        guard let slot = LauncherLayout.focusSlot(previousSlot: previousSlot, itemCount: itemCount) else {
            moveFocusOffDepartedGridTile()
            return
        }
        let indexPath = IndexPath(item: slot, section: 0)
        activeCollectionView.layoutSubtreeIfNeeded()
        if activeCollectionView.item(at: indexPath) == nil {
            activeCollectionView.reloadData()
            activeCollectionView.layoutSubtreeIfNeeded()
            rebuildKeyViewLoop()
        }
        guard let tile = activeCollectionView.item(at: indexPath)?.view as? AppGridTileView,
              window?.makeFirstResponder(tile) == true else {
            moveFocusOffDepartedGridTile()
            return
        }
        NSAccessibility.post(element: tile, notification: .focusedUIElementChanged)
    }

    private func moveFocusOffDepartedGridTile() {
        guard window?.firstResponder is AppGridTileView else { return }
        window?.makeFirstResponder(self)
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }

    private func settleCurrentPage() {
        let pageWidth = max(gridViewport.bounds.width, 1)
        let travel = pageTravelDistance(for: pageWidth)
        let stagingX = stagingPage.map { $0 > currentPage ? travel : -travel }
        isPageTransitioning = true
        pageIndicator.configure(pageCount: pageCount, selectedPage: currentPage)
        positionPages(
            activeX: 0,
            stagingX: stagingX,
            activeAlpha: 1,
            stagingAlpha: stagingX == nil ? nil : 0,
            animated: true,
            settle: true
        )
    }

    private func finishSettle() {
        isPageTransitioning = false
        isPagingGesture = false
        discardInProgressPageGestures()
        layoutCollectionViews()
        runQueuedPage()
    }

    private func discardInProgressPageGestures() {
        activeCollectionView.discardInProgressPageGesture()
        stagingCollectionView.discardInProgressPageGesture()
    }

    /// Drop every paging gesture the grid is still holding. Called when the
    /// launcher starts to dismiss, including when the visible page does not
    /// need to be rewritten.
    func cancelPendingPageInput() {
        activeCollectionView.cancelPagingInput()
        stagingCollectionView.cancelPagingInput()
    }

    /// The merge ring and reorder gap stay on screen until the pointer moves.
    /// Dismiss still has to clear them when no further drag event arrives.
    /// While the fade is on screen that clear snaps the tiles, so it waits
    /// until the window is hidden or `show()` cancels the fade.
    func endDropHighlightForDismissal() {
        clearDropHighlightIfAllowed()
    }

    private func noteIconContextMenuTracking(_ menu: NSMenu?) {
        trackedIconContextMenu = menu
    }

    /// The icon menu is tracking in its own window. `orderOut` does not close
    /// it. Cancel without choosing a row. The flag stays set across that call
    /// so a synchronous action does not hide an app or open the alias alert.
    func cancelIconContextMenuBecauseLauncherIsDismissing() {
        guard let menu = trackedIconContextMenu,
              LauncherLayout.shouldCancelIconContextMenuOnDismiss(isTracking: true) else { return }
        isCancellingIconContextMenu = true
        defer { isCancellingIconContextMenu = false }
        menu.cancelTrackingWithoutAnimation()
    }

    private func acceptsIconContextMenuAction() -> Bool {
        LauncherLayout.shouldApplyIconContextMenuAction(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true,
            isCancellingMenu: isCancellingIconContextMenu
        )
    }

    /// The alias alert is application-modal. `orderOut` cannot run until the
    /// alert returns, so dismiss cancels it instead of leaving it up. The
    /// flag is clear once Save has already returned.
    func abandonAliasPromptBecauseLauncherIsDismissing() {
        guard LauncherLayout.shouldAbandonAliasPromptOnDismiss(isPrompting: isPromptingForAlias) else { return }
        NSApp.abortModal()
    }

    /// A folder title still in the field editor is a draft. `orderOut` would
    /// commit it. Escape already abandons that draft; do the same, and only
    /// when the window is actually leaving.
    func abandonFolderRenameForDismissal() {
        guard LauncherLayout.shouldAbandonFolderRenameOnOrderOut(
            isEditingTitle: folderOverlay.isEditingTitle
        ) else { return }
        _ = folderOverlay.cancelTitleEditingIfActive()
    }

    /// Another window can become key before `orderOut`. AppKit would commit
    /// the field editor inside `resignKey`. Drop the draft first, and do not
    /// move focus: this window is already giving up the keyboard.
    func abandonFolderRenameBecauseWindowResignedKey() {
        guard LauncherLayout.shouldAbandonFolderRenameOnResignKey(
            isEditingTitle: folderOverlay.isEditingTitle
        ) else { return }
        _ = folderOverlay.abandonTitleEditingForResignKey()
    }

    private func runQueuedPage() {
        guard let queuedPage else { return }
        self.queuedPage = nil
        showPage(queuedPage)
    }

    private func prepareStagingPage(_ page: Int) {
        let pageChanged = stagingPage != page
        stagingPage = page
        stagingHost.unpark()
        stagingHost.syncDocumentFrame()
        if pageChanged || stagingHost.collectionView.visibleItems().isEmpty {
            stagingHost.collectionView.collectionViewLayout?.invalidateLayout()
            stagingHost.collectionView.reloadData()
            stagingHost.collectionView.layoutSubtreeIfNeeded()
        }
    }

    private func pageTravelDistance(for pageWidth: CGFloat) -> CGFloat {
        pageWidth * 0.18
    }

    /// The preference changed. A finger drag writes its offset directly, so
    /// the page-slide snap does not see it. Reduced motion puts the pages
    /// back on the current page and leaves the gesture in hand. Turning
    /// motion back on does not play a catch-up slide. A launcher fade that
    /// is holding the frame is left alone, and remembered.
    private func restInFlightPageDragForMotionChange() {
        guard isPagingGesture, !isPageTransitioning else {
            pageDragRestWaitsForLauncher = false
            return
        }
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        guard LauncherLayout.shouldRestInFlightPageDrag(
            reducesMotion: prefersReducedMotion,
            isDismissing: dismissing,
            isVisible: visible
        ) else {
            if prefersReducedMotion,
               LauncherLayout.shouldHoldPageSlide(isDismissing: dismissing, isVisible: visible) {
                pageDragRestWaitsForLauncher = true
            } else if !prefersReducedMotion {
                pageDragRestWaitsForLauncher = false
            }
            return
        }
        pageDragRestWaitsForLauncher = false
        restInFlightPageDrag()
    }

    /// The preference changed. A search list or an open folder may still be
    /// coasting or stretched past its end. Reduced motion pins that. Turning
    /// motion back on does not finish the old coast. A launcher fade that is
    /// holding the frame is left alone, and remembered. A list that is already
    /// still only picks up the elasticity.
    private func restInFlightContentScrollForMotionChange() {
        searchScrollView.restForMotionChange()
        folderOverlay.restContentScrollForMotionChange()
    }

    /// Pins a coast or a stretch that was remembered during the fade. Also
    /// publishes the current elasticity once the fade is no longer holding
    /// the frame, including for a list that never moved.
    func applyDeferredContentScrollRest() {
        searchScrollView.applyDeferredRest()
        folderOverlay.applyDeferredContentScrollRest()
        let dismissing = launcherIsDismissing()
        let visible = window?.isVisible == true
        guard !LauncherLayout.shouldHoldPageSlide(isDismissing: dismissing, isVisible: visible) else { return }
        syncContentScrollMotionForPreference()
    }

    /// Reduced motion does not stretch past the ends. Motion does. A fade
    /// that is still on screen does not change the elasticity yet.
    private func syncContentScrollMotionForPreference() {
        searchScrollView.syncElasticityForMotionPreference()
        folderOverlay.syncContentScrollElasticity()
    }

    /// Rests a finger drag that was remembered during the fade. Does nothing
    /// while the fade is still holding the frame, when motion is no longer
    /// reduced, or when the drag has already ended.
    func applyDeferredPageDragRest() {
        guard pageDragRestWaitsForLauncher else { return }
        guard LauncherLayout.shouldRestInFlightPageDrag(
            reducesMotion: prefersReducedMotion,
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return }
        pageDragRestWaitsForLauncher = false
        restInFlightPageDrag()
    }

    /// Current page, full opacity, staging parked. The gesture flag stays, so
    /// a later release can still turn or settle without replaying the pull.
    private func restInFlightPageDrag() {
        guard isPagingGesture, !isPageTransitioning else { return }
        let frame = gridViewport.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        activeHost.layer?.removeAllAnimations()
        stagingHost.layer?.removeAllAnimations()
        activeHost.unpark()
        activeHost.frame = frame
        activeHost.alphaValue = 1
        activeHost.syncDocumentFrame()
        stagingPage = nil
        stagingHost.park(in: frame)
        CATransaction.commit()
        pageIndicator.configure(
            pageCount: isSearching ? 0 : pageCount,
            selectedPage: currentPage
        )
    }

    /// The preference changed. A slide that is still running jumps to the
    /// destination already stored on the hosts, then the turn or the settle
    /// finishes. Reduced motion has no slide, and turning it off does not
    /// finish the old one. A launcher fade that is holding the frame is left
    /// alone.
    private func snapInFlightPageSlideForMotionChange() {
        guard LauncherLayout.shouldSnapInFlightPageSlide(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return }
        let sliding = [activeHost, stagingHost].filter { host in
            host.wantsLayer = true
            guard let layer = host.layer else { return false }
            return !(layer.animationKeys() ?? []).isEmpty
        }
        guard !sliding.isEmpty else { return }
        pageTransitionGeneration &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for host in sliding {
            host.layer?.removeAllAnimations()
        }
        CATransaction.commit()
        if let targetPage = transitionTargetPage, isPageTransitioning {
            completePageTransition(to: targetPage)
        } else if isPageTransitioning {
            finishSettle()
        }
    }

    /// `animator().frame` writes the destination into the model immediately.
    /// The presentation frame is the one on screen. Pin any host that is
    /// still sliding, and ignore the completion that would swap the pages.
    private func holdInFlightPageSlide() {
        pageTransitionGeneration &+= 1
        for host in [activeHost, stagingHost] {
            freezePageHostIfSliding(host)
        }
    }

    private func freezePageHostIfSliding(_ host: NSView) {
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        let keys = layer.animationKeys() ?? []
        guard !keys.isEmpty else { return }
        let presented = layer.presentation()
        let opacity = presented?.opacity ?? layer.opacity
        let frame = presented?.frame ?? host.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.removeAllAnimations()
        host.alphaValue = CGFloat(opacity)
        layer.opacity = opacity
        host.frame = frame
        CATransaction.commit()
    }

    private func positionPages(
        activeX: CGFloat,
        stagingX: CGFloat?,
        activeAlpha: CGFloat = 1,
        stagingAlpha: CGFloat? = nil,
        animated: Bool = false,
        finishPage: Int? = nil,
        settle: Bool = false
    ) {
        if LauncherLayout.shouldHoldPageSlide(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) {
            // A turn requested during the fade must not start another slide
            // or write the destination into the model. The in-flight hosts
            // stay on the frame `holdInFlightPageSlide` already pinned.
            pageTransitionGeneration &+= 1
            return
        }
        let bounds = gridViewport.bounds
        let apply = {
            self.activeHost.unpark()
            self.activeHost.frame = bounds.offsetBy(dx: activeX, dy: 0)
            self.activeHost.alphaValue = activeAlpha
            self.activeHost.syncDocumentFrame()
            if let stagingX {
                self.stagingHost.unpark()
                self.stagingHost.frame = bounds.offsetBy(dx: stagingX, dy: 0)
                self.stagingHost.alphaValue = stagingAlpha ?? 1
                self.stagingHost.syncDocumentFrame()
            }
        }
        let reduceMotion = prefersReducedMotion
        guard animated, !reduceMotion else {
            pageTransitionGeneration += 1
            apply()
            if let finishPage {
                completePageTransition(to: finishPage)
            } else if settle {
                finishSettle()
            }
            return
        }
        pageTransitionGeneration += 1
        let generation = pageTransitionGeneration
        let travel = max(pageTravelDistance(for: bounds.width), 1)
        let remainingFraction = min(abs(activeX - activeHost.frame.minX) / travel, 1)
        let duration = max(0.12, LauncherLayout.pageAnimationDuration * pow(remainingFraction, 0.55))
        gridViewport.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            self.activeHost.animator().frame = bounds.offsetBy(dx: activeX, dy: 0)
            self.activeHost.animator().alphaValue = activeAlpha
            if let stagingX {
                self.stagingHost.animator().frame = bounds.offsetBy(dx: stagingX, dy: 0)
                self.stagingHost.animator().alphaValue = stagingAlpha ?? 1
            }
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pageTransitionGeneration == generation else { return }
                if let finishPage {
                    self.completePageTransition(to: finishPage)
                } else if settle {
                    self.finishSettle()
                }
            }
        })
    }

    private func layoutCollectionViews() {
        guard !isPaging else { return }
        let frame = gridViewport.bounds
        activeHost.unpark()
        activeHost.frame = frame
        activeHost.syncDocumentFrame()
        stagingHost.park(in: frame)
        stagingPage = nil
        if frame.width > 0, presentedItems(for: currentPage).isEmpty == false {
            activeHost.collectionView.collectionViewLayout?.invalidateLayout()
            activeHost.collectionView.layoutSubtreeIfNeeded()
            if activeHost.collectionView.visibleItems().isEmpty {
                activeHost.collectionView.reloadData()
                activeHost.collectionView.layoutSubtreeIfNeeded()
            }
        }
    }

    func shouldDismiss(at point: NSPoint) -> Bool {
        // Left mouse-up still arrives during the fade so a drag can end.
        // This click also closes an open folder. That would end title editing
        // and save a half-typed name. Refuse it until the launcher is up.
        guard LauncherLayout.shouldApplyBackgroundRelease(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) else { return false }
        let hitView = hitTest(point)
        var currentView = hitView
        while let view = currentView {
            if view is AppGridTileView || view is NSSearchField || view is NSButton {
                return false
            }
            if view === folderOverlay {
                if folderOverlay.shouldClose(for: hitView) {
                    closeFolder()
                }
                return false
            }
            if view === pageIndicator { return false }
            if view === self { break }
            currentView = view.superview
        }
        let gridPoint = activeCollectionView.convert(point, from: self)
        if activeCollectionView.indexPathForItem(at: gridPoint) != nil {
            return false
        }
        if openedFolderID != nil {
            closeFolder()
            return false
        }
        return true
    }

    private static func makeGridLayout() -> NSCollectionViewFlowLayout {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 112, height: 124)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        return layout
    }

    private static func makeFolderLayout() -> NSCollectionViewFlowLayout {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 104, height: 120)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 8, left: 16, bottom: 16, right: 16)
        layout.scrollDirection = .vertical
        return layout
    }
}

private final class PagingPageHost: NSScrollView {
    let collectionView = PagingCollectionView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        scrollerStyle = .overlay
        wantsLayer = true
        collectionView.backgroundColors = [.clear]
        collectionView.wantsLayer = true
        collectionView.layer?.masksToBounds = true
        documentView = collectionView
        registerForDraggedTypes([layoutItemPasteboardType])
    }

    var performDrop: ((NSDraggingInfo) -> Bool)?
    /// False while the launcher is fading out. A release must not land here.
    var acceptsLayoutDrop: () -> Bool = { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsLayoutDrop() ? .move : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { acceptsLayoutDrop() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performDrop?(sender) ?? false
    }

    func park(in bounds: CGRect) {
        isHidden = true
        alphaValue = 0
        frame = bounds.offsetBy(dx: max(bounds.width, 1), dy: 0)
    }

    func unpark() {
        isHidden = false
        alphaValue = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func tile() {
        super.tile()
        syncDocumentFrame()
    }

    override func scrollWheel(with event: NSEvent) {
        collectionView.handlePagingScroll(event)
    }

    func syncDocumentFrame() {
        let bounds = contentView.bounds.size.width > 0 ? contentView.bounds : self.bounds
        let frame = CGRect(origin: .zero, size: bounds.size)
        guard collectionView.frame.size != frame.size else { return }
        collectionView.frame = frame
        collectionView.collectionViewLayout?.invalidateLayout()
    }

}

/// Search results and an open folder scroll in one of these. The grid does
/// not: paging hosts handle that wheel themselves. A gesture that started
/// before the fade still arrives, and `ignoresMouseEvents` does not stop it.
/// Reduced motion keeps system-controlled scrolling inertia but removes the
/// stretch past the ends. A coast pinned by a preference change or dismissal
/// is not resumed when motion comes back.
private final class LauncherScrollView: NSScrollView {
    var isDismissing: () -> Bool = { false }
    var reducesMotion: () -> Bool = { false }
    var isWindowVisible: () -> Bool = { true }

    /// Momentum events after the finger lifts. Cleared when that phase ends.
    private var isCoasting = false
    /// This flick was stopped. Later momentum events of the same flick stay
    /// dropped, even if motion comes back before the phase ends.
    private var coastHeldUntilPhaseEnds = false
    /// Reduced motion asked to pin while the launcher fade was still holding
    /// the frame.
    private var restWaitsForLauncher = false

    override func scrollWheel(with event: NSEvent) {
        guard LauncherLayout.shouldAcceptContentScroll(isDismissing: isDismissing()) else {
            noteBlockedContentScroll(event)
            return
        }
        if !event.momentumPhase.isEmpty {
            handleMomentum(event)
            return
        }
        // A new finger-down is not the flick that was stopped.
        if event.phase == .began {
            coastHeldUntilPhaseEnds = false
            isCoasting = false
        }
        super.scrollWheel(with: event)
    }

    /// The collection view eats the wheel while the launcher is fading, so
    /// this scroll view never sees that event. Record the flick anyway.
    func noteBlockedContentScroll(_ event: NSEvent) {
        if !event.momentumPhase.isEmpty {
            let ended = event.momentumPhase == .ended || event.momentumPhase == .cancelled
            isCoasting = !ended
            coastHeldUntilPhaseEnds = !ended
        }
        guard reducesMotion(), isCoasting || coastHeldUntilPhaseEnds || isStretchedPastEnds() else { return }
        if LauncherLayout.shouldRestInFlightContentScroll(
            reducesMotion: true,
            isDismissing: isDismissing(),
            isVisible: isWindowVisible()
        ) {
            restWaitsForLauncher = false
            pinStretchedContent()
            syncElasticityForMotionPreference()
            return
        }
        guard LauncherLayout.shouldHoldPageSlide(
            isDismissing: isDismissing(),
            isVisible: isWindowVisible()
        ) else { return }
        freezePresentedScrollFrame()
        guard !restWaitsForLauncher else { return }
        restWaitsForLauncher = true
    }

    /// Publishes elasticity for the next drag. A fade that is still on screen
    /// keeps the current value so a stretch is not snapped early.
    func syncElasticityForMotionPreference() {
        if LauncherLayout.shouldHoldPageSlide(
            isDismissing: isDismissing(),
            isVisible: isWindowVisible()
        ) {
            return
        }
        let allowStretch = LauncherLayout.shouldAllowContentElasticity(
            reducesMotion: reducesMotion(),
            isDismissing: isDismissing(),
            isVisible: isWindowVisible()
        )
        let elasticity: NSScrollView.Elasticity = allowStretch ? .automatic : .none
        verticalScrollElasticity = elasticity
        horizontalScrollElasticity = elasticity
    }

    /// Pins a moving list, or remembers it while the fade is up.
    func restForMotionChange() {
        let dismissing = isDismissing()
        let visible = isWindowVisible()
        let reduced = reducesMotion()
        let moving = isCoasting || coastHeldUntilPhaseEnds || isStretchedPastEnds()
        let hold = LauncherLayout.shouldHoldPageSlide(isDismissing: dismissing, isVisible: visible)
        if moving && LauncherLayout.shouldRestInFlightContentScroll(
            reducesMotion: reduced,
            isDismissing: dismissing,
            isVisible: visible
        ) {
            restWaitsForLauncher = false
            coastHeldUntilPhaseEnds = isCoasting || coastHeldUntilPhaseEnds
            pinStretchedContent()
            syncElasticityForMotionPreference()
            return
        }
        if moving && reduced && hold {
            coastHeldUntilPhaseEnds = true
            freezePresentedScrollFrame()
            guard !restWaitsForLauncher else { return }
            restWaitsForLauncher = true
            return
        }
        if !reduced {
            restWaitsForLauncher = false
            if moving {
                coastHeldUntilPhaseEnds = isCoasting || coastHeldUntilPhaseEnds
            }
        }
        if !hold {
            syncElasticityForMotionPreference()
        }
    }

    /// Pins a coast or stretch remembered during the fade. Does nothing while
    /// that fade is still holding the frame, or when motion is no longer reduced.
    func applyDeferredRest() {
        guard restWaitsForLauncher else { return }
        guard LauncherLayout.shouldRestInFlightContentScroll(
            reducesMotion: reducesMotion(),
            isDismissing: isDismissing(),
            isVisible: isWindowVisible()
        ) else { return }
        restWaitsForLauncher = false
        coastHeldUntilPhaseEnds = isCoasting || coastHeldUntilPhaseEnds
        pinStretchedContent()
    }

    private func handleMomentum(_ event: NSEvent) {
        let ended = event.momentumPhase == .ended || event.momentumPhase == .cancelled
        if coastHeldUntilPhaseEnds {
            if ended {
                isCoasting = false
                coastHeldUntilPhaseEnds = false
            } else {
                isCoasting = true
            }
            return
        }
        isCoasting = !ended
        super.scrollWheel(with: event)
    }

    private func isStretchedPastEnds() -> Bool {
        let clip = contentView
        var rects = [clip.bounds]
        if let presented = clip.layer?.presentation()?.bounds {
            rects.append(presented)
        }
        return rects.contains { rect in
            let constrained = clip.constrainBoundsRect(rect)
            return abs(constrained.origin.x - rect.origin.x) > 0.5
                || abs(constrained.origin.y - rect.origin.y) > 0.5
        }
    }

    /// Stop a bounce where it is drawn, including a stretch past the end.
    private func freezePresentedScrollFrame() {
        let clip = contentView
        clip.wantsLayer = true
        let origin = clip.layer?.presentation()?.bounds.origin ?? clip.bounds.origin
        scrollWithoutAnimation(to: origin)
    }

    /// Pull a stretch back inside the document. A coast inside the bounds
    /// stays where it is; later momentum events are not forwarded.
    private func pinStretchedContent() {
        let clip = contentView
        clip.wantsLayer = true
        let drawn = clip.layer?.presentation()?.bounds ?? clip.bounds
        let origin = clip.constrainBoundsRect(drawn).origin
        scrollWithoutAnimation(to: origin)
        isCoasting = false
    }

    private func scrollWithoutAnimation(to origin: NSPoint) {
        let clip = contentView
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.layer?.removeAllAnimations()
        clip.scroll(to: origin)
        reflectScrolledClipView(clip)
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }
}

private final class PagingCollectionView: NSCollectionView {
    var dragChangedHandler: ((CGFloat) -> Void)?
    var dragEndedHandler: ((Int?) -> Void)?
    /// True while the launcher is fading out. Scroll events already in flight
    /// still arrive; they must not turn a page.
    var isDismissing: () -> Bool = { false }
    var dragSessionEndedHandler: (() -> Void)?
    var dragExitedHandler: (() -> Void)?
    private var accumulatedDelta: CGFloat = 0
    private var lastTimestamp: TimeInterval?
    private var lastVelocity: CGFloat = 0
    private var accumulatedDiscreteDelta: CGFloat = 0
    private var lastDiscreteScrollTimestamp: TimeInterval?
    private var lastDiscretePageTurnTimestamp: TimeInterval = -.infinity
    private var heldDiscreteToken = 0

    override func scrollWheel(with event: NSEvent) {
        // Search results and folder members scroll through this path. The
        // grid handles paging in `handlePagingScroll`, which has the same
        // dismiss check. A gesture already in flight must not move either.
        guard LauncherLayout.shouldAcceptContentScroll(isDismissing: isDismissing()) else {
            cancelPagingInput()
            // Search and folder lists live in `LauncherScrollView`. The grid
            // handles paging itself and must not record a content-scroll coast.
            if dragChangedHandler == nil {
                (enclosingScrollView as? LauncherScrollView)?.noteBlockedContentScroll(event)
            }
            return
        }
        if dragChangedHandler != nil {
            handlePagingScroll(event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        false
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        dragSessionEndedHandler?()
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        dragExitedHandler?()
    }

    func handlePagingScroll(_ event: NSEvent) {
        guard LauncherLayout.shouldAcceptPagingGesture(isDismissing: isDismissing()) else {
            cancelPagingInput()
            return
        }
        if !event.momentumPhase.isEmpty {
            if lastTimestamp != nil {
                finishGesture()
            }
            return
        }

        let delta = Self.dominantScrollDelta(from: event)
        guard delta != 0 else { return }

        if event.hasPreciseScrollingDeltas {
            if event.phase == .began || lastTimestamp == nil {
                beginGesture(at: event.timestamp)
            }
            updateGesture(with: delta, timestamp: event.timestamp)
            if event.phase == .ended || event.phase == .cancelled {
                finishGesture()
            }
            return
        }

        let quietPeriod = LauncherLayout.pageAnimationDuration + 0.05
        let decision = LauncherLayout.discreteScrollTurn(
            accumulatedDelta: accumulatedDiscreteDelta,
            incomingDelta: delta,
            now: event.timestamp,
            lastScroll: lastDiscreteScrollTimestamp,
            lastTurn: lastDiscretePageTurnTimestamp,
            quietPeriod: quietPeriod
        )
        lastDiscreteScrollTimestamp = event.timestamp
        accumulatedDiscreteDelta = decision.accumulatedDelta
        guard let direction = decision.direction else { return }
        if let holdDelay = decision.holdDelay {
            heldDiscreteToken &+= 1
            let token = heldDiscreteToken
            let deliverAt = event.timestamp + holdDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay) { [weak self] in
                guard let self, self.heldDiscreteToken == token else { return }
                self.heldDiscreteToken &+= 1
                self.deliverDiscretePageTurn(direction, at: deliverAt)
            }
            return
        }
        heldDiscreteToken &+= 1
        deliverDiscretePageTurn(direction, at: event.timestamp)
    }

    private func deliverDiscretePageTurn(_ direction: Int, at timestamp: TimeInterval) {
        // Hide bumps the wait token. A callback that still gets here while
        // the fade is up must not turn the page.
        guard LauncherLayout.shouldAcceptPagingGesture(isDismissing: isDismissing()) else {
            cancelPagingInput()
            return
        }
        accumulatedDiscreteDelta = 0
        lastDiscretePageTurnTimestamp = timestamp
        resetGesture()
        dragEndedHandler?(direction)
    }

    static func dominantScrollDelta(from event: NSEvent) -> CGFloat {
        let dx: CGFloat
        let dy: CGFloat
        if event.hasPreciseScrollingDeltas {
            dx = event.scrollingDeltaX
            dy = event.scrollingDeltaY
        } else {
            dx = CGFloat(event.deltaX)
            dy = CGFloat(event.deltaY)
        }
        return abs(dx) >= abs(dy) ? dx : dy
    }

    private func beginGesture(at timestamp: TimeInterval) {
        accumulatedDelta = 0
        lastVelocity = 0
        lastTimestamp = timestamp
    }

    private func updateGesture(with delta: CGFloat, timestamp: TimeInterval) {
        if let lastTimestamp {
            let interval = timestamp - lastTimestamp
            if interval > 0.002 {
                let instantaneousVelocity = delta / interval
                lastVelocity = lastVelocity == 0
                    ? instantaneousVelocity
                    : lastVelocity * 0.72 + instantaneousVelocity * 0.28
            }
        }
        lastTimestamp = timestamp
        accumulatedDelta += delta
        dragChangedHandler?(accumulatedDelta)
    }

    private func finishGesture() {
        let shouldAdvance = LauncherLayout.shouldTurnPage(
            distance: accumulatedDelta,
            velocity: lastVelocity,
            pageWidth: max(bounds.width, 1)
        )
        let direction = shouldAdvance ? (accumulatedDelta < 0 ? 1 : -1) : nil
        dragEndedHandler?(direction)
        resetGesture()
    }

    private func resetGesture() {
        accumulatedDelta = 0
        lastVelocity = 0
        lastTimestamp = nil
    }

    /// Drop distance accumulated while a page animation was ignoring updates.
    /// Does not emit a turn; a flick that already ended was handled separately.
    func discardInProgressPageGesture() {
        accumulatedDelta = 0
        lastVelocity = 0
    }

    /// A wheel step waiting out the quiet period must not turn the page after
    /// search has taken over the grid.
    func cancelHeldDiscretePageTurn() {
        heldDiscreteToken &+= 1
    }

    /// Dismiss, or a scroll event that arrives during the fade. Clears the
    /// trackpad gesture and any wheel step already waiting to turn the page.
    func cancelPagingInput() {
        discardInProgressPageGesture()
        lastTimestamp = nil
        accumulatedDiscreteDelta = 0
        lastDiscreteScrollTimestamp = nil
        cancelHeldDiscretePageTurn()
    }
}

@MainActor
private final class PageIndicatorView: NSStackView {
    var onPageSelected: ((Int) -> Void)?
    var onPageMove: ((Int) -> Void)?
    var onVerticalPage: ((Int) -> Bool)?
    var onType: ((NSEvent) -> Bool)?
    var onDelete: ((LauncherSearchDeletion) -> Bool)?
    private var configuredPageCount = -1
    private var configuredSelectedPage = -1

    var keyViews: [NSView] {
        arrangedSubviews
            .compactMap { $0 as? PageDotButton }
            .filter { !$0.isHidden && $0.isEnabled }
            .map { $0 as NSView }
    }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(pageCount: Int, selectedPage: Int) {
        let slots = LauncherLayout.pageIndicatorSlots(pageCount: pageCount, selectedPage: selectedPage)
        if configuredPageCount == pageCount, configuredSelectedPage == selectedPage, arrangedSubviews.count == slots.count {
            for case let dot as PageDotButton in arrangedSubviews {
                dot.isCurrent = dot.tag == selectedPage
            }
            isHidden = pageCount < 2
            return
        }
        configuredPageCount = pageCount
        configuredSelectedPage = selectedPage
        let focusedTag: Int? = {
            guard let dot = window?.firstResponder as? PageDotButton, dot.isDescendant(of: self) else { return nil }
            return dot.tag
        }()
        arrangedSubviews.forEach {
            removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for slot in slots {
            switch slot {
            case let .page(page):
                let dot = PageDotButton()
                dot.tag = page
                dot.isCurrent = page == selectedPage
                dot.onPage = { [weak self] direction in self?.onPageMove?(direction) }
                dot.onVerticalPage = { [weak self] direction in self?.onVerticalPage?(direction) ?? false }
                dot.onType = { [weak self] event in self?.onType?(event) ?? false }
                dot.onDelete = { [weak self] deletion in self?.onDelete?(deletion) ?? false }
                dot.target = self
                dot.action = #selector(selectPage)
                dot.setAccessibilityLabel("第 \(page + 1) 页")
                dot.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    dot.widthAnchor.constraint(equalToConstant: 24),
                    dot.heightAnchor.constraint(equalToConstant: 24)
                ])
                addArrangedSubview(dot)
            case .ellipsis:
                let ellipsis = PageEllipsisView()
                ellipsis.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    ellipsis.widthAnchor.constraint(equalToConstant: 12),
                    ellipsis.heightAnchor.constraint(equalToConstant: 12)
                ])
                addArrangedSubview(ellipsis)
            }
        }
        isHidden = pageCount < 2
        guard let focusedTag else { return }
        let dots = arrangedSubviews.compactMap { $0 as? PageDotButton }
        if !isHidden, let restored = dots.first(where: { $0.tag == focusedTag }) ?? dots.first(where: { $0.tag == selectedPage }) {
            window?.makeFirstResponder(restored)
        } else if let content = window?.contentView {
            window?.makeFirstResponder(content)
        }
    }

    func setTransition(from currentPage: Int, to targetPage: Int, progress: CGFloat) {
        let boundedProgress = min(max(progress, 0), 1)
        for case let dot as PageDotButton in arrangedSubviews {
            switch dot.tag {
            case currentPage:
                dot.visualWeight = 1 - boundedProgress
            case targetPage:
                dot.visualWeight = boundedProgress
            default:
                dot.visualWeight = 0
            }
        }
    }

    @objc private func selectPage(_ sender: PageDotButton) {
        onPageSelected?(sender.tag)
    }
}

private final class PageEllipsisView: NSView {
    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.65).setFill()
        for x in [2.5, 5, 7.5] {
            NSBezierPath(ovalIn: NSRect(x: x, y: 5, width: 2, height: 2)).fill()
        }
    }
}

private final class PageDotButton: NSButton {
    var onPage: ((Int) -> Void)?
    var onVerticalPage: ((Int) -> Bool)?
    var onType: ((NSEvent) -> Bool)?
    var onDelete: ((LauncherSearchDeletion) -> Bool)?
    var isCurrent = false {
        didSet { visualWeight = isCurrent ? 1 : 0 }
    }

    var visualWeight: CGFloat = 0 {
        didSet {
            visualWeight = min(max(visualWeight, 0), 1)
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = 5 + visualWeight * 2
        let rect = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        NSColor.labelColor.withAlphaComponent(0.42 + visualWeight * 0.58).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    override func keyDown(with event: NSEvent) {
        // Same keys as the grid tiles. Focus can sit on a dot after Tab;
        // Left/Right still turn the page and do not walk icons or dots.
        // Page Up/Down scroll search results instead of turning a page.
        if launcherConsumesVerticalSearchPage(event, using: onVerticalPage) { return }
        if let direction = launcherPagingDirection(for: event) {
            onPage?(direction)
            return
        }
        if let onDelete, let deletion = launcherSearchDeletion(for: event), onDelete(deletion) { return }
        if let onType, launcherTypingStartsSearch(event), onType(event) { return }
        super.keyDown(with: event)
    }
}

private final class AppGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("AppGridItem")

    override func loadView() {
        view = AppGridTileView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        (view as? AppGridTileView)?.resetForReuse()
    }

    func configure(
        candidate: AppCandidate,
        displayName: String,
        isLaunching: Bool,
        isFolder: Bool,
        preview: [AppCandidate],
        reducesMotion: Bool,
        onActivate: @escaping () -> Void,
        onDragStart: @escaping (NSEvent) -> Bool,
        onRenameAlias: (() -> Void)?,
        onHideApplication: (() -> Void)?
    ) {
        guard let tile = view as? AppGridTileView else { return }
        tile.configure(
            candidate: candidate,
            displayName: displayName,
            isLaunching: isLaunching,
            isFolder: isFolder,
            preview: preview,
            reducesMotion: reducesMotion,
            onActivate: onActivate,
            onDragStart: onDragStart,
            onRenameAlias: onRenameAlias,
            onHideApplication: onHideApplication
        )
    }
}

private final class AppGridTileView: NSView {
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    /// Owns the icon and title so a reorder can move them without fighting the cell frame.
    private let reorderSlideHost = NSView()
    var isFolder = false
    var previewCandidates: [AppCandidate] = []
    var previewImages: [NSImage] = []
    var reducesMotion = false
    var iconGeneration = 0
    var onActivate: (() -> Void)?
    var onFocus: (() -> Void)?
    var onPage: ((Int) -> Void)?
    var onVerticalPage: ((Int) -> Bool)?
    var onType: ((NSEvent) -> Bool)?
    var onTab: ((Int) -> Bool)?
    var onDelete: ((LauncherSearchDeletion) -> Bool)?
    var onContextMenuTracking: ((NSMenu?) -> Void)?
    /// True while the launcher is fading. A decoded icon waits instead of
    /// swapping the placeholder under that fade. A hidden window is not fading.
    var launcherIsDismissing: () -> Bool = { false }
    private var onDragStart: ((NSEvent) -> Bool)?
    private var onRenameAlias: (() -> Void)?
    private var onHideApplication: (() -> Void)?
    private var iconLoadTask: Task<Void, Never>?
    /// Decoded while the launcher was fading. Applied once the fade is over.
    private var deferredIconImage: NSImage?
    private var deferredPreviewImages: [NSImage]?
    private var loadedIconWaitsForLauncher = false
    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var mouseDownPoint: NSPoint?
    private var didStartItemDrag = false
    /// Captured at hit-test time, before a search field resigning reloads the
    /// tile and clears `onActivate`. The click still has to open that app.
    private var armedActivate: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override var focusRingMaskBounds: NSRect { focusRingRect }

    private var focusRingRect: NSRect {
        guard !iconView.frame.isEmpty, !titleLabel.frame.isEmpty else {
            return bounds.insetBy(dx: 3, dy: 3)
        }
        let titleWidth = min(
            max(titleLabel.intrinsicContentSize.width, iconView.frame.width),
            max(iconView.frame.width, bounds.width - 24)
        )
        let width = min(bounds.width - 8, titleWidth + 16)
        let minY = max(2, min(iconView.frame.minY, titleLabel.frame.minY) - 7)
        let maxY = min(bounds.height - 2, max(iconView.frame.maxY, titleLabel.frame.maxY) + 6)
        return NSRect(
            x: (bounds.width - width) / 2,
            y: minY,
            width: width,
            height: max(maxY - minY, 44)
        )
    }

    var isLaunching = false {
        didSet {
            updateAppearance()
            if isLaunching, !oldValue { playLaunchFeedback() }
        }
    }

    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            updateDropTargetAppearance()
        }
    }

    private var baseAccessibilityHelp = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        clipsToBounds = true
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityEnabled(true)
        setAccessibilityChildren([])

        reorderSlideHost.autoresizingMask = []
        addSubview(reorderSlideHost)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityHidden(true)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        reorderSlideHost.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.setAccessibilityHidden(true)
        let labelShadow = NSShadow()
        labelShadow.shadowColor = NSColor.black.withAlphaComponent(0.62)
        labelShadow.shadowBlurRadius = 2
        labelShadow.shadowOffset = NSSize(width: 0, height: -1)
        titleLabel.shadow = labelShadow
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.drawsBackground = false
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        reorderSlideHost.addSubview(titleLabel)

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 64)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 64)
        iconHeightConstraint.priority = .init(999)
        let titleTrailingConstraint = titleLabel.trailingAnchor.constraint(equalTo: reorderSlideHost.trailingAnchor, constant: -6)
        titleTrailingConstraint.priority = .init(999)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: reorderSlideHost.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: reorderSlideHost.centerYAnchor, constant: -14),
            iconWidthConstraint,
            iconHeightConstraint,
            titleLabel.leadingAnchor.constraint(equalTo: reorderSlideHost.leadingAnchor, constant: 6),
            titleTrailingConstraint,
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 5),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: reorderSlideHost.bottomAnchor, constant: -2)
        ])
    }

    func configure(
        candidate: AppCandidate,
        displayName: String,
        isLaunching: Bool,
        isFolder: Bool,
        preview: [AppCandidate],
        reducesMotion: Bool,
        onActivate: @escaping () -> Void,
        onDragStart: @escaping (NSEvent) -> Bool,
        onRenameAlias: (() -> Void)?,
        onHideApplication: (() -> Void)?
    ) {
        self.reducesMotion = reducesMotion
        self.isFolder = isFolder
        self.onActivate = onActivate
        self.onDragStart = onDragStart
        self.onRenameAlias = onRenameAlias
        self.onHideApplication = onHideApplication
        previewCandidates = preview
        iconGeneration += 1
        let generation = iconGeneration
        iconLoadTask?.cancel()
        deferredIconImage = nil
        deferredPreviewImages = nil
        loadedIconWaitsForLauncher = false
        titleLabel.stringValue = isLaunching ? "正在启动…" : displayName
        toolTip = displayName
        setAccessibilityLabel(isFolder ? "文件夹 \(displayName)" : displayName)
        baseAccessibilityHelp = isFolder ? "按下以打开文件夹" : "按下以打开应用"
        setAccessibilityHelp(baseAccessibilityHelp)
        updateDropTargetAppearance()
        configureContextMenu()
        if isFolder {
            iconView.image = nil
            previewImages = preview.map {
                WorkspaceIconCache.shared.cachedIcon(for: $0) ?? WorkspaceIconCache.placeholder
            }
            iconLoadTask = Task { @MainActor [weak self] in
                let images: [NSImage]
                do {
                    images = try await WorkspaceIconCache.shared.loadIcons(for: preview)
                } catch {
                    return
                }
                guard let self, self.iconGeneration == generation else { return }
                guard self.shouldApplyLoadedIconNow() else {
                    self.deferredPreviewImages = images
                    self.deferredIconImage = nil
                    self.loadedIconWaitsForLauncher = true
                    return
                }
                self.previewImages = images
                self.needsDisplay = true
            }
        } else if let cached = WorkspaceIconCache.shared.cachedIcon(for: candidate) {
            previewImages = []
            iconView.image = cached
        } else {
            previewImages = []
            iconView.image = WorkspaceIconCache.placeholder
            iconLoadTask = Task { @MainActor [weak self] in
                let image: NSImage
                do {
                    image = try await WorkspaceIconCache.shared.loadIcon(for: candidate)
                } catch {
                    return
                }
                guard let self, self.iconGeneration == generation else { return }
                guard self.shouldApplyLoadedIconNow() else {
                    self.deferredIconImage = image
                    self.deferredPreviewImages = nil
                    self.loadedIconWaitsForLauncher = true
                    return
                }
                self.iconView.image = image
            }
        }
        self.isLaunching = isLaunching
        needsDisplay = true
    }

    private func shouldApplyLoadedIconNow() -> Bool {
        LauncherLayout.shouldApplyLoadedIcon(isDismissing: launcherIsDismissing())
    }

    /// Shows an icon that was decoded during the fade. A newer configure
    /// already cleared the wait.
    func applyDeferredLoadedIcon() {
        guard loadedIconWaitsForLauncher else { return }
        guard shouldApplyLoadedIconNow() else { return }
        loadedIconWaitsForLauncher = false
        if let images = deferredPreviewImages {
            deferredPreviewImages = nil
            previewImages = images
            needsDisplay = true
        }
        if let image = deferredIconImage {
            deferredIconImage = nil
            iconView.image = image
        }
    }

    func resetForReuse() {
        iconLoadTask?.cancel()
        iconLoadTask = nil
        iconGeneration += 1
        deferredIconImage = nil
        deferredPreviewImages = nil
        loadedIconWaitsForLauncher = false
        launcherIsDismissing = { false }
        titleLabel.stringValue = ""
        iconView.image = nil
        previewCandidates = []
        previewImages = []
        isFolder = false
        onActivate = nil
        onFocus = nil
        onPage = nil
        onVerticalPage = nil
        onType = nil
        onTab = nil
        onDelete = nil
        onContextMenuTracking = nil
        onDragStart = nil
        onRenameAlias = nil
        onHideApplication = nil
        menu = nil
        toolTip = nil
        baseAccessibilityHelp = ""
        isDropTarget = false
        alphaValue = 1
        layer?.opacity = 1
        reorderTicker?.invalidate()
        reorderTicker = nil
        reorderGeneration += 1
        reorderSlideHeld = false
        reorderTarget = .zero
        reorderPresented = .zero
        layer?.transform = CATransform3DIdentity
        reorderSlideHost.frame = bounds
        clipsToBounds = true
        layer?.masksToBounds = true
    }

    private var reorderTarget: CGSize = .zero
    private var reorderPresented: CGSize = .zero
    private var reorderTicker: Timer?
    private var reorderGeneration = 0
    /// The fade stopped an ease before it reached the gap. Release jumps to
    /// that gap only while the drag is still down. Clearing the highlight
    /// sends the icon home instead.
    private var reorderSlideHeld = false

    /// Slides the icon and title inside the cell. AppKit resets the item
    /// layer's transform while it keeps that cell's frame fixed during a drag.
    /// A fade that is still on screen does not start this ease and does not
    /// snap the icon to the new gap. The picture stays on the frame it has.
    func setReorderTranslation(_ translation: CGSize, animated: Bool) {
        if LauncherLayout.shouldHoldReorderSlide(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        ) {
            if reorderTarget != translation {
                reorderTarget = translation
            }
            pinReorderSlideForDismissal()
            return
        }
        guard translation != reorderTarget else { return }
        let from = reorderPresented
        reorderTarget = translation
        reorderTicker?.invalidate()
        reorderTicker = nil
        reorderGeneration += 1
        reorderSlideHeld = false
        layer?.transform = CATransform3DIdentity
        guard animated, !reducesMotion, translation != from else {
            reorderPresented = translation
            applyReorderSlidePresentation()
            return
        }
        let started = CACurrentMediaTime()
        let duration = LauncherLayout.reorderSlideDuration
        let generation = reorderGeneration
        let ticker = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let finished = MainActor.assumeIsolated {
                self.advanceReorderSlide(
                    from: from, to: translation, started: started,
                    duration: duration, generation: generation
                )
            }
            if finished { timer.invalidate() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        reorderTicker = ticker
        applyReorderSlidePresentation()
    }

    private func advanceReorderSlide(
        from: CGSize, to: CGSize, started: CFTimeInterval,
        duration: CFTimeInterval, generation: Int
    ) -> Bool {
        guard reorderGeneration == generation else { return true }
        let raw = duration > 0 ? (CACurrentMediaTime() - started) / duration : 1
        let progress = min(1, max(0, raw))
        let eased = Self.reorderEase(progress)
        reorderPresented = CGSize(
            width: from.width + (to.width - from.width) * eased,
            height: from.height + (to.height - from.height) * eased
        )
        applyReorderSlidePresentation()
        if progress >= 1 {
            reorderTicker = nil
            reorderSlideHeld = false
        }
        return progress >= 1
    }

    /// Stop the ease on the frame already drawn. The target gap stays put
    /// so a later release can jump there without replaying the timer.
    func pinReorderSlideForDismissal() {
        let inFlight = reorderTicker != nil || reorderPresented != reorderTarget
        reorderTicker?.invalidate()
        reorderTicker = nil
        reorderGeneration += 1
        if inFlight {
            reorderSlideHeld = true
        }
    }

    /// The fade is over. A drag that is still down lands on the gap. A drag
    /// that already ended keeps whatever clear already wrote.
    func releaseHeldReorderSlide(jumpToTarget: Bool) {
        guard reorderSlideHeld else { return }
        reorderSlideHeld = false
        reorderTicker?.invalidate()
        reorderTicker = nil
        reorderGeneration += 1
        guard jumpToTarget, reorderPresented != reorderTarget else { return }
        reorderPresented = reorderTarget
        applyReorderSlidePresentation()
    }

    func reassertReorderSlide() {
        guard reorderTarget != .zero || reorderPresented != .zero else { return }
        applyReorderSlidePresentation()
    }

    private func applyReorderSlidePresentation() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        if isFolder { needsDisplay = true }
    }

    private func tileDelta(for translation: CGSize) -> CGSize {
        guard translation != .zero else { return .zero }
        var ancestor = superview
        while let current = ancestor {
            if let collection = current as? NSCollectionView {
                let origin = convert(CGPoint.zero, to: collection)
                let shifted = CGPoint(x: origin.x + translation.width, y: origin.y + translation.height)
                let local = convert(shifted, from: collection)
                return CGSize(width: local.x, height: local.y)
            }
            ancestor = current.superview
        }
        return CGSize(width: translation.width, height: -translation.height)
    }

    private func unclipReorderSlide() {
        if clipsToBounds { clipsToBounds = false }
        if layer?.masksToBounds != false { layer?.masksToBounds = false }
        var ancestor = superview
        while let current = ancestor, !(current is NSCollectionView), !(current is NSScrollView) {
            if current.clipsToBounds { current.clipsToBounds = false }
            if current.layer?.masksToBounds != false { current.layer?.masksToBounds = false }
            ancestor = current.superview
        }
    }

    /// Samples `cubic-bezier(0.23, 1, 0.32, 1)`, the reorder ease-out.
    private static func reorderEase(_ time: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, time))
        var parameter = clamped
        for _ in 0..<6 {
            let x = reorderBezier(parameter, 0.23, 0.32)
            let slope = reorderBezierSlope(parameter, 0.23, 0.32)
            guard abs(slope) > 0.0001 else { break }
            parameter = min(1, max(0, parameter - (x - clamped) / slope))
        }
        return reorderBezier(parameter, 1, 1)
    }

    private static func reorderBezier(_ t: CGFloat, _ c1: CGFloat, _ c2: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * c1 + 3 * inverse * t * t * c2 + t * t * t
    }

    private static func reorderBezierSlope(_ t: CGFloat, _ c1: CGFloat, _ c2: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * c1 + 6 * inverse * t * (c2 - c1) + 3 * t * t * (1 - c2)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu else {
            super.rightMouseDown(with: event)
            return
        }
        // Keep this closure. A reload while the menu is up clears the property,
        // and the matching nil must still reach the launcher when tracking ends.
        let tracking = onContextMenuTracking
        tracking?(menu)
        defer { tracking?(nil) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The icon and title would otherwise swallow the click, so a press on the glyph never drags or opens.
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let onActivate {
            armedActivate = onActivate
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }
        mouseDownPoint = event.locationInWindow
        didStartItemDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseDragged(with: event)
            return
        }
        guard !didStartItemDrag, let mouseDownPoint else { return }
        let distance = hypot(
            event.locationInWindow.x - mouseDownPoint.x,
            event.locationInWindow.y - mouseDownPoint.y
        )
        guard distance >= 8 else { return }
        // A read-only grid cannot drag. Leaving the flag set used to eat the
        // click, so the app neither moved nor opened.
        guard onDragStart?(event) == true else { return }
        didStartItemDrag = true
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseUp(with: event)
            return
        }
        let activate = armedActivate ?? onActivate
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let stayedPut: Bool = {
            guard let mouseDownPoint else { return false }
            return hypot(
                event.locationInWindow.x - mouseDownPoint.x,
                event.locationInWindow.y - mouseDownPoint.y
            ) < 8
        }()
        // Resigning the search field reloads this tile before mouse up. The
        // reloaded view can fail the bounds test even though the press never
        // became a drag, which used to focus the result without opening it.
        if !didStartItemDrag, mouseDownPoint != nil, inside || stayedPut {
            activate?()
        }
        mouseDownPoint = nil
        didStartItemDrag = false
        armedActivate = nil
    }

    private func configureContextMenu() {
        guard !isFolder, onRenameAlias != nil, onHideApplication != nil else {
            menu = nil
            return
        }
        let contextMenu = NSMenu()
        let aliasItem = contextMenu.addItem(
            withTitle: "设置别名…",
            action: #selector(renameAlias),
            keyEquivalent: ""
        )
        aliasItem.target = self
        let hideItem = contextMenu.addItem(
            withTitle: "隐藏应用",
            action: #selector(hideApplication),
            keyEquivalent: ""
        )
        hideItem.target = self
        menu = contextMenu
    }

    @objc private func renameAlias() {
        onRenameAlias?()
    }

    @objc private func hideApplication() {
        onHideApplication?()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?()
            needsDisplay = true
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { needsDisplay = true }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 || event.characters == " " {
            onActivate?()
            return
        }
        // Left/Right and Page Up/Down page the grid, including after a folder
        // close leaves this tile focused. They do not walk icon to icon.
        // Page Up/Down scroll an open search instead of doing nothing.
        if launcherConsumesVerticalSearchPage(event, using: onVerticalPage) { return }
        switch event.keyCode {
        case 123, 116:
            onPage?(-1)
            return
        case 124, 121:
            onPage?(1)
            return
        default:
            if let onDelete, let deletion = launcherSearchDeletion(for: event), onDelete(deletion) { return }
            if onType?(event) == true { return }
            super.keyDown(with: event)
        }
    }

    override func insertTab(_ sender: Any?) {
        if onTab?(1) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if onTab?(-1) == true { return }
        super.insertBacktab(sender)
    }

    override func drawFocusRingMask() {
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: focusRingRect,
            xRadius: 12,
            yRadius: 12
        ).fill()
    }

    func setAccessibilitySuppressed(_ suppressed: Bool) {
        setAccessibilityHidden(suppressed)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isFolder else { return }
        let iconSize = LauncherLayout.iconPointSize(in: bounds.size)
        let iconFrame = iconView.convert(iconView.bounds, to: self)
        let well = NSRect(
            x: iconFrame.midX - iconSize / 2,
            y: iconFrame.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
        NSColor.controlBackgroundColor.withAlphaComponent(0.7).setFill()
        let cornerRadius = iconSize * 0.24
        NSBezierPath(roundedRect: well, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        let inset: CGFloat = 6
        let gap: CGFloat = 4
        let tile = floor((iconSize - inset * 2 - gap) / 2)
        let positions: [NSPoint] = [
            NSPoint(x: well.minX + inset, y: well.maxY - inset - tile),
            NSPoint(x: well.minX + inset + tile + gap, y: well.maxY - inset - tile),
            NSPoint(x: well.minX + inset, y: well.minY + inset),
            NSPoint(x: well.minX + inset + tile + gap, y: well.minY + inset)
        ]
        for (index, icon) in previewImages.prefix(4).enumerated() {
            icon.draw(in: NSRect(origin: positions[index], size: NSSize(width: tile, height: tile)))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        super.updateLayer()
        updateAppearance()
    }

    override func layout() {
        let iconSize = LauncherLayout.iconPointSize(in: bounds.size)
        if iconWidthConstraint.constant != iconSize {
            iconWidthConstraint.constant = iconSize
            iconHeightConstraint.constant = iconSize
        }
        let delta = tileDelta(for: reorderPresented)
        let target = bounds.offsetBy(dx: delta.width, dy: delta.height)
        if reorderSlideHost.frame != target {
            reorderSlideHost.frame = target
        }
        super.layout()
        if reorderSlideHost.frame != target {
            reorderSlideHost.frame = target
            reorderSlideHost.layoutSubtreeIfNeeded()
        }
        if delta == .zero {
            if !clipsToBounds || layer?.masksToBounds == false {
                clipsToBounds = true
                layer?.masksToBounds = true
            }
        } else {
            unclipReorderSlide()
        }
    }

    private func updateAppearance() {
        layer?.backgroundColor = isLaunching ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : .clear
        iconView.isHidden = isFolder
        updateDropTargetAppearance()
    }

    private func updateDropTargetAppearance() {
        if isDropTarget {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            setAccessibilitySelected(true)
            setAccessibilityHelp(isFolder ? "拖放到此文件夹" : "拖放到此以合并")
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = nil
            setAccessibilitySelected(false)
            if !baseAccessibilityHelp.isEmpty {
                setAccessibilityHelp(baseAccessibilityHelp)
            }
        }
    }

    private func playLaunchFeedback() {
        guard LauncherLayout.shouldPlayLaunchFeedback(
            isDismissing: launcherIsDismissing(),
            reducesMotion: reducesMotion
        ) else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.0
        animation.toValue = 0.93
        animation.duration = 0.045
        animation.autoreverses = true
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(animation, forKey: "launch-feedback")
    }

    /// The preference changed. The pulse returns to the normal scale instead
    /// of finishing. The model scale is already 1.
    func snapLaunchFeedbackForMotionChange() {
        guard let layer, layer.animation(forKey: "launch-feedback") != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "launch-feedback")
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}

/// Placeholder grid shown only while the first scan has no candidates yet.
private final class ScanSkeletonView: NSView {
    /// A control that must stay on the wallpaper, such as the cached-catalog button.
    weak var actionView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let item = LauncherLayout.itemSize(in: bounds.size)
        guard item.width > 1, item.height > 1 else { return }
        let columns = LauncherLayout.pageColumns
        let rows = LauncherLayout.pageRows
        let horizontalSpacing: CGFloat = 12
        let verticalSpacing: CGFloat = 10
        let inset = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        let contentWidth = CGFloat(columns) * item.width + CGFloat(columns - 1) * horizontalSpacing
        let originX = inset.left + max(0, bounds.width - inset.left - inset.right - contentWidth) / 2
        let iconSize = LauncherLayout.iconPointSize(in: item)
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        let captionRow = rows / 2
        let captionColumn = columns / 2
        let actionHole = actionHoleRect()
        for row in 0..<rows {
            for column in 0..<columns {
                // The loading sentence sits on the middle of this row.
                if row == captionRow, abs(column - captionColumn) <= 1 { continue }
                let cell = NSRect(
                    x: originX + CGFloat(column) * (item.width + horizontalSpacing),
                    y: inset.top + CGFloat(row) * (item.height + verticalSpacing),
                    width: item.width,
                    height: item.height
                )
                if let actionHole, cell.intersects(actionHole) { continue }
                let iconRect = NSRect(
                    x: cell.midX - iconSize / 2,
                    y: cell.minY + max(8, (cell.height - iconSize) * 0.22),
                    width: iconSize,
                    height: iconSize
                )
                NSBezierPath(roundedRect: iconRect, xRadius: iconSize * 0.22, yRadius: iconSize * 0.22).fill()
                let title = NSRect(x: cell.midX - 26, y: iconRect.maxY + 8, width: 52, height: 8)
                NSBezierPath(roundedRect: title, xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    private func actionHoleRect() -> NSRect? {
        guard let actionView, !actionView.isHidden, actionView.superview != nil else { return nil }
        let rect = actionView.convert(actionView.bounds, to: self)
        guard rect.width > 1, rect.height > 1, rect.intersects(bounds) else { return nil }
        return rect.insetBy(dx: -18, dy: -12)
    }
}

private final class LauncherChromeButton: NSButton {
    var onInsertTab: (() -> Bool)?
    var onPage: ((Int) -> Void)?
    var onVerticalPage: ((Int) -> Bool)?
    var onType: ((NSEvent) -> Bool)?
    var onDelete: ((LauncherSearchDeletion) -> Bool)?

    override func insertTab(_ sender: Any?) {
        if onInsertTab?() == true { return }
        super.insertTab(sender)
    }

    override func keyDown(with event: NSEvent) {
        // Focus can sit on Settings after Tab. Left/Right still turn the page
        // and do not walk icons. A button without onPage keeps the system key.
        if launcherConsumesVerticalSearchPage(event, using: onVerticalPage) { return }
        if let onPage, let direction = launcherPagingDirection(for: event) {
            onPage(direction)
            return
        }
        if let onDelete, let deletion = launcherSearchDeletion(for: event), onDelete(deletion) { return }
        if let onType, launcherTypingStartsSearch(event), onType(event) { return }
        super.keyDown(with: event)
    }
}

private func launcherPagingDirection(for event: NSEvent) -> Int? {
    switch event.keyCode {
    case 123, 116: return -1
    case 124, 121: return 1
    default: return nil
    }
}

/// Page Up and Page Down only. Left/Right stay on `launcherPagingDirection`.
private func launcherVerticalPagingDirection(for event: NSEvent) -> Int? {
    switch event.keyCode {
    case 116: return -1
    case 121: return 1
    default: return nil
    }
}

private func launcherConsumesVerticalSearchPage(_ event: NSEvent, using handler: ((Int) -> Bool)?) -> Bool {
    guard let handler, let direction = launcherVerticalPagingDirection(for: event) else { return false }
    return handler(direction)
}

/// Printable keys start a search from a focused button. Space and Return still
/// click that button. Arrows are handled before this.
private func launcherSearchFieldPages(_ selector: Selector) -> Bool {
    selector == #selector(NSResponder.moveLeft(_:))
        || selector == #selector(NSResponder.moveRight(_:))
        || selector == #selector(NSResponder.pageUp(_:))
        || selector == #selector(NSResponder.pageDown(_:))
}

private enum LauncherSearchDeletion {
    case character
    case word
    case toLineStart
}

/// Deletions the field editor would apply with the caret at the end of the query.
/// Plain backspace removes one grapheme. Option-backspace removes one word.
/// Command-backspace clears the line. Other modifiers are left alone.
private func launcherSearchDeletion(for event: NSEvent) -> LauncherSearchDeletion? {
    guard event.keyCode == 51 else { return nil }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.isEmpty { return .character }
    if modifiers == .option { return .word }
    if modifiers == .command { return .toLineStart }
    return nil
}

private func launcherTypingStartsSearch(_ event: NSEvent) -> Bool {
    if event.keyCode == 36 || event.keyCode == 76 || event.characters == " " { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard modifiers.intersection([.command, .control]).isEmpty,
          let characters = event.characters,
          characters.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) else { return false }
    return true
}

private final class PagingArrowButton: NSButton {
    var onPage: ((Int) -> Void)?
    var acceptsDraggedItem: ((NSDraggingInfo) -> Bool)?
    var onDragHover: (() -> Void)?
    var onVerticalPage: ((Int) -> Bool)?
    var onType: ((NSEvent) -> Bool)?
    var onDelete: ((LauncherSearchDeletion) -> Bool)?
    var launcherIsDismissing: () -> Bool = { false }
    var reducesMotion: () -> Bool = { false }
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false
    private var dragHoverWorkItem: DispatchWorkItem?
    private var isDragHovering = false

    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        title = ""
        image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(.init(pointSize: 20, weight: .semibold))
        imagePosition = .imageOnly
        isBordered = false
        focusRingType = .none
        contentTintColor = .labelColor
        setAccessibilityLabel(accessibilityLabel)
        toolTip = accessibilityLabel
        wantsLayer = true
        layer?.cornerRadius = 22
        alphaValue = 0
        registerForDraggedTypes([layoutItemPasteboardType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateVisibility(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateVisibility(animated: true)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isHidden, acceptsDraggedItem?(sender) == true else {
            cancelDragHover()
            return []
        }
        if !isDragHovering {
            isDragHovering = true
            scheduleDragHover(after: 0.5)
        }
        return .move
    }

    private func scheduleDragHover(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isDragHovering, !self.isHidden else { return }
            self.onDragHover?()
            self.scheduleDragHover(after: 0.5 + LauncherLayout.pageAnimationDuration)
        }
        dragHoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        cancelDragHover()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        cancelDragHover()
        return false
    }

    func cancelDragHover() {
        dragHoverWorkItem?.cancel()
        dragHoverWorkItem = nil
        isDragHovering = false
    }

    override func keyDown(with event: NSEvent) {
        if launcherConsumesVerticalSearchPage(event, using: onVerticalPage) { return }
        if let direction = launcherPagingDirection(for: event) {
            onPage?(direction)
            return
        }
        if let onDelete, let deletion = launcherSearchDeletion(for: event), onDelete(deletion) { return }
        if let onType, launcherTypingStartsSearch(event), onType(event) { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateVisibility(animated: false)
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        updateVisibility(animated: false)
        return resigned
    }

    /// While the launcher fade is up, keep the opacity already on screen.
    /// A later pass snaps to hover or focus. The fade is not replayed.
    func settleHoverFadeForDismissal() {
        if holdingHoverFade {
            pinHoverFade()
            return
        }
        applyDeferredHoverFade()
    }

    /// Preference changes and reduced motion land on hover or focus at once.
    func snapHoverVisibility() {
        updateVisibility(animated: false)
    }

    /// A hidden window drops the arrow so the next appearance does not flash
    /// a half-faded control. A cancelled fade snaps to the current hover.
    func applyDeferredHoverFade() {
        guard !holdingHoverFade else { return }
        if window?.isVisible != true {
            isHovering = false
            layer?.backgroundColor = .clear
            setAlphaWithoutAnimation(0)
            return
        }
        updateVisibility(animated: false)
    }

    private var holdingHoverFade: Bool {
        LauncherLayout.shouldHoldPageButtonHover(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true
        )
    }

    private func updateVisibility(animated: Bool) {
        if holdingHoverFade {
            pinHoverFade()
            return
        }
        let shown = isHovering || window?.firstResponder === self
        layer?.backgroundColor = shown ? NSColor.black.withAlphaComponent(0.22).cgColor : .clear
        let alpha: CGFloat = shown ? 0.9 : 0
        if animated, LauncherLayout.shouldAnimatePageButtonHover(
            isDismissing: launcherIsDismissing(),
            isVisible: window?.isVisible == true,
            reducesMotion: reducesMotion()
        ) {
            animator().alphaValue = alpha
        } else {
            setAlphaWithoutAnimation(alpha)
        }
    }

    /// `animator().alphaValue` writes the destination immediately. The
    /// presentation opacity is the one on screen.
    private func pinHoverFade() {
        wantsLayer = true
        let presented = layer?.presentation()?.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.removeAllAnimations()
        if let presented {
            alphaValue = CGFloat(presented)
            layer?.opacity = presented
        }
        CATransaction.commit()
    }

    private func setAlphaWithoutAnimation(_ alpha: CGFloat) {
        wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.removeAllAnimations()
        alphaValue = alpha
        CATransaction.commit()
    }
}

@MainActor
private final class AliasNameField: NSTextField, NSTextFieldDelegate {
    private weak var saveButton: NSButton?
    private weak var cancelButton: NSButton?
    private var saveKeyEquivalent = "\r"
    private var cancelKeyEquivalent = "\u{1b}"
    private var isStrippingMarkedAlias = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func adoptAlertButtons(_ buttons: [NSButton]) {
        saveButton = buttons.first
        cancelButton = buttons.dropFirst().first
        if let key = saveButton?.keyEquivalent, !key.isEmpty {
            saveKeyEquivalent = key
        }
        if let key = cancelButton?.keyEquivalent, !key.isEmpty {
            cancelKeyEquivalent = key
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let marked = (currentEditor() as? NSTextView)?.hasMarkedText() == true
        // Return is the alert's Save key, and Escape is Cancel. Both would
        // skip the input method and store or discard the unfinished pinyin.
        saveButton?.keyEquivalent = marked ? "" : saveKeyEquivalent
        cancelButton?.keyEquivalent = marked ? "" : cancelKeyEquivalent
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard !isStrippingMarkedAlias,
              let editor = fieldEditor as? NSTextView,
              editor.hasMarkedText() else { return true }
        let marked = editor.markedRange()
        let cleaned = LauncherLayout.textByRemovingMarkedRange(
            editor.string,
            utf16Location: marked.location,
            utf16Length: marked.length
        )
        guard cleaned != editor.string else { return true }
        isStrippingMarkedAlias = true
        let full = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.replaceCharacters(in: full, with: cleaned)
        validateEditing()
        isStrippingMarkedAlias = false
        return true
    }
}

@MainActor
private final class FolderTitleField: NSTextField {
    var onBacktab: (() -> Bool)?

    override func insertBacktab(_ sender: Any?) {
        if onBacktab?() == true { return }
        super.insertBacktab(sender)
    }
}

@MainActor
private final class FolderOverlayView: NSView, NSTextFieldDelegate {
    let collectionView = PagingCollectionView()
    var onClose: (() -> Void)?
    var onActivateApp: ((AppCandidate) -> Void)?
    /// False while the launcher is fading or already ordered out. Releasing
    /// the close button or the dimmer must not close the folder or save the
    /// title.
    var acceptsPointerActivation: () -> Bool = { true }
    var onDrop: ((LayoutDrop) -> Bool)?
    /// False while the launcher is fading out. Dragging out of a folder then
    /// must not extract the icon.
    var acceptsDrop: () -> Bool = { true }
    var onRename: ((String) -> String)?
    var onTabToMembers: (() -> Bool)?
    var onBacktabFromTitle: (() -> Bool)?

    private let dimmer = NSView()
    private let panel = NSVisualEffectView()
    private let titleField = FolderTitleField()
    private var titleBeforeEdit = ""
    private var isDiscardingTitleEdit = false
    /// Applied once the field editor is gone. Changing `isEditable` while a
    /// rename is in progress ends that editor and would save or drop the draft.
    private var titleEditingEnabled = true
    private var isStrippingMarkedTitle = false
    private let closeButton = LauncherChromeButton(title: "关闭", target: nil, action: nil)
    private let folderScrollView = LauncherScrollView()
    private var preferredPanelWidth: NSLayoutConstraint!
    private var preferredPanelHeight: NSLayoutConstraint!
    private var animationGeneration: UInt64 = 0
    private(set) var isAnimatingClose = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityEnabled(true)
        setAccessibilityLabel("打开的文件夹")
        dimmer.wantsLayer = true
        dimmer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        dimmer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dimmer)

        panel.material = .popover
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 22
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.group)
        panel.setAccessibilityEnabled(true)
        panel.setAccessibilityLabel("文件夹")
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        titleField.font = .systemFont(ofSize: 17, weight: .semibold)
        titleField.alignment = .center
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.placeholderString = "文件夹名称"
        titleField.setAccessibilityLabel("文件夹名称")
        titleField.delegate = self
        titleField.onBacktab = { [weak self] in self?.onBacktabFromTitle?() ?? false }
        titleField.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(titleField)

        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭文件夹")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setAccessibilityLabel("关闭文件夹")
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.onInsertTab = { [weak self] in self?.onTabToMembers?() ?? false }
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(closeButton)

        folderScrollView.drawsBackground = false
        folderScrollView.hasVerticalScroller = true
        folderScrollView.autohidesScrollers = true
        folderScrollView.borderType = .noBorder
        folderScrollView.setAccessibilityEnabled(true)
        folderScrollView.documentView = collectionView
        folderScrollView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(folderScrollView)

        collectionView.backgroundColors = [.clear]
        collectionView.setAccessibilityElement(true)
        collectionView.setAccessibilityRole(.list)
        collectionView.setAccessibilityLabel("文件夹中的应用")

        preferredPanelWidth = panel.widthAnchor.constraint(equalToConstant: 820)
        preferredPanelWidth.priority = .defaultHigh
        preferredPanelHeight = panel.heightAnchor.constraint(equalToConstant: 620)
        preferredPanelHeight.priority = .defaultLow

        NSLayoutConstraint.activate([
            dimmer.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmer.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimmer.topAnchor.constraint(equalTo: topAnchor),
            dimmer.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.90),
            preferredPanelWidth,
            panel.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.70),
            preferredPanelHeight,
            titleField.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            titleField.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            titleField.widthAnchor.constraint(equalToConstant: 280),
            titleField.heightAnchor.constraint(equalToConstant: 28),
            closeButton.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            folderScrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            folderScrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            folderScrollView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 12),
            folderScrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16)
        ])
        registerForDraggedTypes([layoutItemPasteboardType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isAnimatingClose else { return super.hitTest(point) }
        return self
    }

    private var isSizingGrid = false

    /// Search-style scrolling lives on this overlay's scroll view, which is
    /// not one of the paging hosts. A fade must freeze both that view and the
    /// collection view, because either one can receive the wheel event.
    func followLauncherDismissing(_ isDismissing: @escaping () -> Bool) {
        collectionView.isDismissing = isDismissing
        folderScrollView.isDismissing = isDismissing
    }

    /// The folder list coasts and stretches on its own scroll view. Reduced
    /// motion uses the same rule as search results.
    func followContentScrollMotion(
        reducesMotion: @escaping () -> Bool,
        isWindowVisible: @escaping () -> Bool
    ) {
        folderScrollView.reducesMotion = reducesMotion
        folderScrollView.isWindowVisible = isWindowVisible
    }

    func syncContentScrollElasticity() {
        folderScrollView.syncElasticityForMotionPreference()
    }

    func restContentScrollForMotionChange() {
        folderScrollView.restForMotionChange()
    }

    func applyDeferredContentScrollRest() {
        folderScrollView.applyDeferredRest()
    }

    func setEditingEnabled(_ enabled: Bool, explanation: String?) {
        titleEditingEnabled = enabled
        titleField.toolTip = explanation
        titleField.setAccessibilityHelp(explanation ?? "编辑文件夹名称")
        collectionView.toolTip = explanation
        collectionView.setAccessibilityHelp(explanation ?? "拖动应用以整理文件夹")
        guard titleField.currentEditor() == nil else { return }
        titleField.isEditable = enabled
    }

    func show(folder: LauncherFolder, items: [PresentedItem]) {
        updateTitle(for: folder)
        setAccessibilityHidden(false)
        isHidden = false
        collectionView.reloadData()
        scrollContentsToTop()
        NSAccessibility.post(element: panel, notification: .layoutChanged)
    }

    /// A previously scrolled folder must not open with its icons above the panel.
    func scrollContentsToTop() {
        let clipView = folderScrollView.contentView
        guard clipView.bounds.origin != .zero else { return }
        clipView.scroll(to: .zero)
        folderScrollView.reflectScrolledClipView(clipView)
    }

    var isEditingTitle: Bool { titleField.currentEditor() != nil }

    @discardableResult
    func focusCloseButton() -> Bool {
        window?.makeFirstResponder(closeButton) == true
    }

    @discardableResult
    func focusTitleField() -> Bool {
        window?.makeFirstResponder(titleField) == true
    }

    func updateTitle(for folder: LauncherFolder) {
        // A catalog refresh must not replace a name the user is still typing.
        if titleField.currentEditor() == nil {
            titleBeforeEdit = folder.name
            titleField.stringValue = folder.name
        }
        setAccessibilityLabel("打开的文件夹 \(folder.name)")
        panel.setAccessibilityLabel("文件夹 \(folder.name)")
        if !isHidden { NSAccessibility.post(element: panel, notification: .layoutChanged) }
    }

    /// True when an open or close animation is still on the panel. The close
    /// flag counts too: its completion is what hides the panel, and that can
    /// land during the launcher fade.
    func freezeChromeForDismissal() -> Bool {
        let panelKeys = panel.layer?.animationKeys() ?? []
        let dimmerKeys = dimmer.layer?.animationKeys() ?? []
        let panelAnimating = panelKeys.contains("folderOpenFade")
            || panelKeys.contains("folderOpenScale")
            || panelKeys.contains("folderCloseFade")
            || panelKeys.contains("folderCloseScale")
        let dimmerAnimating = dimmerKeys.contains("folderOpenFade")
            || dimmerKeys.contains("folderCloseFade")
        guard panelAnimating || dimmerAnimating || isAnimatingClose else { return false }
        // Drop the close completion before it can hide the panel under the fade.
        animationGeneration &+= 1
        pinLayerToPresentedFrame(panel.layer, removing: [
            "folderOpenFade", "folderOpenScale", "folderCloseFade", "folderCloseScale"
        ])
        pinLayerToPresentedFrame(dimmer.layer, removing: ["folderOpenFade", "folderCloseFade"])
        return true
    }

    /// Reduced motion does not scale the panel. Drop a scale that is already
    /// running. A preference change snaps the opacity fade on its own; this
    /// only clears scale. The model scale of an opening panel is already
    /// identity; a closing panel had written 0.92.
    func dropScaleForReducedMotion() {
        guard let panelLayer = panel.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panelLayer.removeAnimation(forKey: "folderOpenScale")
        panelLayer.removeAnimation(forKey: "folderCloseScale")
        panelLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// The preference changed while this panel was still opening or closing.
    /// An opening panel lands fully open. A closing panel is removed. Neither
    /// one keeps playing. A settled panel has no animation and is left alone.
    @discardableResult
    func snapInFlightChromeForMotionChange() -> Bool {
        let panelKeys = panel.layer?.animationKeys() ?? []
        let dimmerKeys = dimmer.layer?.animationKeys() ?? []
        let closing = isAnimatingClose
            || panelKeys.contains("folderCloseFade")
            || panelKeys.contains("folderCloseScale")
            || dimmerKeys.contains("folderCloseFade")
        let opening = panelKeys.contains("folderOpenFade")
            || panelKeys.contains("folderOpenScale")
            || dimmerKeys.contains("folderOpenFade")
        guard closing || opening else { return false }
        if closing {
            animateClose(reducesMotion: false, immediately: true)
            return true
        }
        animationGeneration &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.layer?.removeAllAnimations()
        panel.layer?.opacity = 1
        panel.layer?.transform = CATransform3DIdentity
        dimmer.layer?.removeAllAnimations()
        dimmer.layer?.opacity = 1
        CATransaction.commit()
        return true
    }

    /// An opening panel becomes fully visible. A closing panel is removed.
    /// Neither one replays the scale.
    func commitHeldChrome() {
        if isAnimatingClose {
            animateClose(reducesMotion: false, immediately: true)
            return
        }
        animationGeneration &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.layer?.removeAllAnimations()
        panel.layer?.opacity = 1
        panel.layer?.transform = CATransform3DIdentity
        dimmer.layer?.removeAllAnimations()
        dimmer.layer?.opacity = 1
        CATransaction.commit()
    }

    func animateOpen(reducesMotion: Bool) {
        let wasClosing = isAnimatingClose
        let panelLayer = panel.layer
        let dimmerLayer = dimmer.layer
        let currentPanelOpacity = wasClosing ? panelLayer?.presentation()?.opacity ?? 0 : 0
        let currentDimmerOpacity = wasClosing ? dimmerLayer?.presentation()?.opacity ?? 0 : 0
        let currentPanelScale = wasClosing ? panelLayer?.presentation()?.transform.m11 ?? 0.92 : 0.92
        animationGeneration &+= 1
        isAnimatingClose = false
        panelLayer?.removeAnimation(forKey: "folderOpenScale")
        panelLayer?.removeAnimation(forKey: "folderOpenFade")
        panelLayer?.removeAnimation(forKey: "folderCloseScale")
        panelLayer?.removeAnimation(forKey: "folderCloseFade")
        dimmerLayer?.removeAnimation(forKey: "folderOpenFade")
        dimmerLayer?.removeAnimation(forKey: "folderCloseFade")
        panel.layer?.opacity = 1
        panel.layer?.transform = CATransform3DIdentity
        dimmer.layer?.opacity = 1

        let duration = reducesMotion ? 0.12 : 0.22
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = currentPanelOpacity
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = timing
        panelLayer?.add(fade, forKey: "folderOpenFade")
        let dimmerFade = CABasicAnimation(keyPath: "opacity")
        dimmerFade.fromValue = currentDimmerOpacity
        dimmerFade.toValue = 1
        dimmerFade.duration = duration
        dimmerFade.timingFunction = timing
        dimmerLayer?.add(dimmerFade, forKey: "folderOpenFade")

        guard !reducesMotion else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = currentPanelScale
        scale.toValue = 1
        scale.duration = duration
        scale.timingFunction = timing
        panelLayer?.add(scale, forKey: "folderOpenScale")
    }

    func animateClose(reducesMotion: Bool, immediately: Bool = false) {
        if immediately {
            animationGeneration &+= 1
            isAnimatingClose = false
            setAccessibilityHidden(true)
            panel.layer?.removeAllAnimations()
            panel.layer?.opacity = 1
            panel.layer?.transform = CATransform3DIdentity
            dimmer.layer?.removeAllAnimations()
            dimmer.layer?.opacity = 1
            isHidden = true
            return
        }
        let panelLayer = panel.layer
        let dimmerLayer = dimmer.layer
        let currentPanelOpacity = panelLayer?.presentation()?.opacity ?? panelLayer?.opacity ?? 1
        let currentDimmerOpacity = dimmerLayer?.presentation()?.opacity ?? dimmerLayer?.opacity ?? 1
        let currentPanelScale = panelLayer?.presentation()?.transform.m11 ?? panelLayer?.transform.m11 ?? 1
        animationGeneration &+= 1
        let generation = animationGeneration
        isAnimatingClose = true
        setAccessibilityHidden(true)

        let duration = reducesMotion ? 0.12 : 0.22
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
        panelLayer?.removeAnimation(forKey: "folderOpenScale")
        panelLayer?.removeAnimation(forKey: "folderOpenFade")
        dimmerLayer?.removeAnimation(forKey: "folderOpenFade")

        guard let panelLayer, let dimmerLayer else {
            isAnimatingClose = false
            isHidden = true
            return
        }

        let panelFade = CABasicAnimation(keyPath: "opacity")
        panelFade.fromValue = currentPanelOpacity
        panelFade.toValue = 0
        panelFade.duration = duration
        panelFade.timingFunction = timing
        panelLayer.opacity = 0

        let dimmerFade = CABasicAnimation(keyPath: "opacity")
        dimmerFade.fromValue = currentDimmerOpacity
        dimmerFade.toValue = 0
        dimmerFade.duration = duration
        dimmerFade.timingFunction = timing
        dimmerLayer.opacity = 0

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.animationGeneration == generation else { return }
                self.isHidden = true
                self.isAnimatingClose = false
                panelLayer.removeAllAnimations()
                panelLayer.opacity = 1
                panelLayer.transform = CATransform3DIdentity
                dimmerLayer.removeAllAnimations()
                dimmerLayer.opacity = 1
            }
        }
        panelLayer.add(panelFade, forKey: "folderCloseFade")
        dimmerLayer.add(dimmerFade, forKey: "folderCloseFade")
        if !reducesMotion {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = currentPanelScale
            scale.toValue = 0.92
            scale.duration = duration
            scale.timingFunction = timing
            panelLayer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
            panelLayer.add(scale, forKey: "folderCloseScale")
        } else {
            panelLayer.transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    var keyViews: [NSView] {
        collectionView.layoutSubtreeIfNeeded()
        return [titleField, closeButton] + orderedAppTiles
    }

    private var orderedAppTiles: [AppGridTileView] {
        collectionView.visibleItems()
            .sorted { lhs, rhs in
                guard let left = collectionView.indexPath(for: lhs),
                      let right = collectionView.indexPath(for: rhs) else { return false }
                return left.item < right.item
            }
            .compactMap { $0.view as? AppGridTileView }
    }

    func reload() {
        collectionView.reloadData()
    }

    func layoutFolderGrid(itemCount: Int) {
        guard !isSizingGrid else { return }
        isSizingGrid = true
        defer { isSizingGrid = false }
        let contentRows = max(1, (max(itemCount, 1) + LauncherLayout.folderColumns - 1) / LauncherLayout.folderColumns)
        let desiredWidth = LauncherLayout.preferredFolderPanelWidth(forItemCount: itemCount)
        let desiredHeight = min(620, max(260, 112 + CGFloat(contentRows) * 104))
        if preferredPanelWidth.constant != desiredWidth || preferredPanelHeight.constant != desiredHeight {
            preferredPanelWidth.constant = desiredWidth
            preferredPanelHeight.constant = desiredHeight
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        let viewport = folderScrollView.contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0,
              let flow = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let columns = CGFloat(LauncherLayout.folderDisplayColumns(forItemCount: itemCount))
        let rows = CGFloat(contentRows)
        let hSpacing = flow.minimumInteritemSpacing
        let vSpacing = flow.minimumLineSpacing
        var inset = flow.sectionInset
        let horizontalInset: CGFloat = 16
        let itemWidth = max(72, floor((viewport.width - horizontalInset * 2 - hSpacing * (columns - 1)) / columns))
        if flow.sectionInset.left != horizontalInset || flow.sectionInset.right != horizontalInset {
            inset.left = horizontalInset
            inset.right = horizontalInset
            flow.sectionInset = inset
        }
        let itemHeight = min(112, max(88, floor((viewport.height - inset.top - inset.bottom - vSpacing * (rows - 1)) / rows)))
        let itemSize = NSSize(width: itemWidth, height: itemHeight)
        if flow.itemSize != itemSize {
            flow.itemSize = itemSize
        }
        let height = inset.top + inset.bottom
            + CGFloat(contentRows) * itemHeight
            + CGFloat(max(contentRows - 1, 0)) * vSpacing
        let frame = NSRect(x: 0, y: 0, width: max(viewport.width, 1), height: max(height, viewport.height))
        if collectionView.frame.size != frame.size {
            collectionView.frame = frame
        }
        // Opening a folder still scrolls to the top. Losing members must not
        // leave the panel looking at empty space, and must not jump back up
        // when the icons still fit under the current offset.
        let clipView = folderScrollView.contentView
        let clamped = LauncherLayout.clampedScrollOffset(
            clipView.bounds.origin.y,
            documentLength: collectionView.frame.height,
            viewportLength: clipView.bounds.height
        )
        if clamped != clipView.bounds.origin.y {
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: clamped))
            folderScrollView.reflectScrolledClipView(clipView)
        }
        collectionView.layoutSubtreeIfNeeded()
        collectionView.setAccessibilityChildren(orderedAppTiles)
        orderedAppTiles.forEach { $0.setAccessibilityParent(collectionView) }
        NSAccessibility.post(element: collectionView, notification: .layoutChanged)
    }

    func shouldClose(for hitView: NSView?) -> Bool {
        var current = hitView
        while let view = current {
            if view === panel || view is AppGridTileView || view is NSButton || view is NSTextField {
                return false
            }
            current = view.superview
        }
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop() else { return [] }
        return shouldClose(for: hitTest(convert(sender.draggingLocation, from: nil))) ? .move : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsDrop()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsDrop(),
              shouldClose(for: hitTest(convert(sender.draggingLocation, from: nil))),
              let data = sender.draggingPasteboard.data(forType: layoutItemPasteboardType),
              let payload = try? JSONDecoder().decode(DraggedLayoutItem.self, from: data),
              let folderID = payload.folderID else { return false }
        return onDrop?(LayoutDrop(
            source: .folderMember(folderID: folderID, itemID: payload.itemID),
            destination: .topLevelIndex(Int.max)
        )) ?? false
    }

    override func mouseUp(with event: NSEvent) {
        guard acceptsPointerActivation() else { return }
        let point = convert(event.locationInWindow, from: nil)
        if shouldClose(for: hitTest(point)) {
            onClose?()
        }
    }

    /// Unfinished pinyin is not part of the name. Closing or otherwise leaving
    /// the field commits `stringValue` only after this mark is gone.
    func discardMarkedTitleComposition(in editor: NSText? = nil) {
        guard !isDiscardingTitleEdit, !isStrippingMarkedTitle else { return }
        let editor = (editor as? NSTextView) ?? (titleField.currentEditor() as? NSTextView)
        guard let editor, editor.hasMarkedText() else { return }
        let marked = editor.markedRange()
        let cleaned = LauncherLayout.textByRemovingMarkedRange(
            editor.string,
            utf16Location: marked.location,
            utf16Length: marked.length
        )
        guard cleaned != editor.string else { return }
        isStrippingMarkedTitle = true
        let full = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.replaceCharacters(in: full, with: cleaned)
        titleField.validateEditing()
        isStrippingMarkedTitle = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === titleField else { return false }
        // Return must leave the field. Leaving it to the field editor kept the
        // session up, so the next Escape cancelled the draft and the folder
        // stayed open instead of showing the renamed icon.
        if selector == #selector(NSResponder.insertNewline(_:)) {
            discardMarkedTitleComposition(in: textView)
            if window?.makeFirstResponder(collectionView) != true {
                _ = window?.makeFirstResponder(closeButton)
            }
            return true
        }
        // The field editor, not the text field, receives Shift-Tab while the
        // name is being edited. The key loop only knows visible icons, so the
        // last member below the fold was skipped.
        guard selector == #selector(NSResponder.insertBacktab(_:)) else { return false }
        return titleField.onBacktab?() ?? false
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        // Tab, click, or Return that actually ends editing. The input method
        // confirms a candidate before this, so a finished character stays.
        discardMarkedTitleComposition(in: fieldEditor)
        return true
    }

    /// Escape cancels the draft and leaves the folder open. A second Escape
    /// still closes it, because the field editor is no longer first responder.
    func cancelTitleEditingIfActive() -> Bool {
        guard restoreTitleAndAbortEditing() else { return false }
        if window?.makeFirstResponder(collectionView) != true {
            _ = window?.makeFirstResponder(closeButton)
        }
        return true
    }

    /// Losing key is about to end the editor. Restoring the name here is
    /// enough. Moving the first responder would fight the window that is
    /// taking key.
    func abandonTitleEditingForResignKey() -> Bool {
        restoreTitleAndAbortEditing()
    }

    /// Puts the field back to the name from before this edit and ends the
    /// editor without `controlTextDidEndEditing` saving the draft.
    private func restoreTitleAndAbortEditing() -> Bool {
        guard titleField.currentEditor() != nil else { return false }
        let restored = titleBeforeEdit
        isDiscardingTitleEdit = true
        titleField.stringValue = restored
        titleField.abortEditing()
        isDiscardingTitleEdit = false
        return true
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        titleBeforeEdit = titleField.stringValue
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isDiscardingTitleEdit else {
            titleField.isEditable = titleEditingEnabled
            return
        }
        let committed = onRename?(titleField.stringValue) ?? titleBeforeEdit
        titleBeforeEdit = committed
        if titleField.stringValue != committed {
            titleField.stringValue = committed
        }
        titleField.isEditable = titleEditingEnabled
        // The rename reloads the folder and can put the field editor back.
        // A following Escape would cancel that empty session and leave the
        // folder open, so the grid never shows the new name.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.titleField.currentEditor() != nil else { return }
            if self.window?.makeFirstResponder(self.collectionView) != true {
                _ = self.window?.makeFirstResponder(self.closeButton)
            }
        }
    }

    @objc private func close() {
        guard acceptsPointerActivation() else { return }
        discardMarkedTitleComposition()
        _ = onRename?(titleField.stringValue)
        onClose?()
    }
}

private extension NSView {
    func draggingImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        bitmapImageRepForCachingDisplay(in: bounds).map { representation in
            cacheDisplay(in: bounds, to: representation)
            representation.draw(in: bounds)
        }
        image.unlockFocus()
        return image
    }
}

import AppKit
import LaunchIconCore
import OSLog
import QuartzCore

extension LauncherWindowController {
    func show(animated: Bool = true) {
        let wasDismissing = isDismissing
        dismissGeneration += 1
        dismissTask?.cancel()
        dismissTask = nil
        dismissArmed = false
        // Mid-fade cancel: open status menu still said「显示」; flip to「隐藏」now.
        if LauncherLayout.shouldRefreshStatusItemToggleTitleOnDismissCancel(
            wasDismissing: wasDismissing
        ) {
            onVisibilityChanged?()
        }
        rootView.releaseFrozenSearchField()
        guard let window else { return }
        let appearing = !window.isVisible
        let appearStartedAt = appearing ? CACurrentMediaTime() : 0
        // Activating the app makes this window key again. Read the old state
        // first, or a launcher that already gave up the keyboard looks like
        // it never did and keeps a stale field editor.
        let wasKey = window.isKeyWindow
        if appearing {
            windowUpdateInterval = signposter.beginInterval("WindowUpdate")
        }
        let screen = launcherScreen(for: window, appearing: appearing)
        let previousFrame = window.frame
        let targetFrame = Self.frame(for: screen?.frame ?? window.frame, testSize: testWindowSize)
        window.setFrame(targetFrame, display: true)
        if let testWindowSize {
            assert(window.frame.size == testWindowSize, "Test window size was constrained by its content")
        }
        // Borderless panel: ensure contentView matches the target screen size
        // even when AppKit leaves a stale primary-sized contentView after a
        // cross-display setFrame (secondary black gutter / sticky primary).
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        if let contentView = window.contentView, contentView.frame.size != contentSize {
            contentView.setFrameSize(contentSize)
        }
        rootView.updateDesktopBackground(for: screen)
        // Always refresh metrics on show when the frame moved, the backing
        // scale changed, or on appear. Same-size sticky corruption still
        // needs lastViewportSize cleared.
        let presentedScale = screen?.backingScaleFactor
        if appearing
            || LauncherLayout.shouldInvalidateGridViewportCacheOnScreenChange(
                previousScreenFrame: previousFrame,
                newScreenFrame: window.frame,
                previousBackingScale: lastPresentedBackingScale,
                newBackingScale: presentedScale
            )
        {
            rootView.applyScreenGeometryForPresentation()
        }
        if let presentedScale {
            lastPresentedBackingScale = presentedScale
        }
        if appearing {
            // WALLPAPER-DEFERRED-ON-APPEAR-01: the decode that finished during
            // the fade already stored this screen's URL, size, and scale, so
            // the reload above skipped. Install that thumbnail or the old one
            // stays up. A new request clears the held image before this runs.
            if LauncherLayout.shouldInstallHeldDesktopBackgroundOnAppearance(
                holdsDecodedImage: rootView.holdsDeferredDesktopBackground,
                isDismissing: isDismissing
            ) {
                rootView.applyDeferredDesktopBackground()
            }
            // Settings snappy restore uses animated: false — keep the query.
            let clearsQuery = LauncherLayout.shouldClearSearchQueryWhenPreparingPresentation(
                preservesQueryAcrossHandoff: !animated
            )
            rootView.prepareForPresentation(clearsSearchQuery: clearsQuery)
            // REOPEN-PAGE-BEHAVIOR-01: snap to page 0 when policy says so (no animation;
            // window still hidden). Settings handoff never resets.
            let elapsed = lastDismissDate.map { Date().timeIntervalSince($0) }
            if ReopenPageCopy.shouldResetToHomePageOnAppear(
                behavior: reopenPageBehavior,
                secondsSinceLastDismiss: elapsed,
                isSettingsHandoffRestore: !animated
            ) {
                rootView.snapGridToHomePageForReopen()
            }
            if LauncherLayout.shouldRestoreSearchResultsChromeAfterSettingsHandoff(
                isSettingsHandoffRestore: !animated,
                hadNonEmptyQueryBeforeHandoff: pendingSettingsHandoffSearchResultsChrome
            ) {
                rootView.snapSearchResultsChromeForSettingsHandoffRestore()
            }
            if LauncherLayout.shouldSuppressPageIndicatorAfterSettingsHandoff(
                isSettingsHandoffRestore: !animated,
                hadNonEmptyQueryBeforeHandoff: pendingSettingsHandoffSearchResultsChrome
            ) {
                rootView.snapPageIndicatorSuppressedForSettingsHandoffRestore()
            }
            if LauncherLayout.shouldSuppressPageArrowsAfterSettingsHandoff(
                isSettingsHandoffRestore: !animated,
                hadNonEmptyQueryBeforeHandoff: pendingSettingsHandoffSearchResultsChrome
            ) {
                rootView.snapPageArrowsSuppressedForSettingsHandoffRestore()
            }
            if LauncherLayout.shouldSnapSearchFooterChromeAfterSettingsHandoff(
                isSettingsHandoffRestore: !animated,
                hadNonEmptyQueryBeforeHandoff: pendingSettingsHandoffSearchResultsChrome
            ) {
                rootView.snapSearchFooterChromeForSettingsHandoffRestore()
            }
            if LauncherLayout.shouldSnapSearchAdjacentChromeAfterSettingsHandoff(
                isSettingsHandoffRestore: !animated,
                hadNonEmptyQueryBeforeHandoff: pendingSettingsHandoffSearchResultsChrome
            ) {
                rootView.snapSearchAdjacentChromeForSettingsHandoffRestore()
            }
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
            // TILE-ICON-RESTART-AFTER-CANCEL-ON-SHOW-01 /
            // ICON-PREFETCH-RESTART-ON-SHOW-01: hide cancelled in-flight
            // tile loads and prefetch; mid-fade reopen must restart them.
            rootView.restartCancelledTileIconLoadsAfterAppearance()
            rootView.restartIconPrefetchIfNeededAfterAppearance()
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
        let restoreSearchFocus = LauncherLayout.shouldRestoreSearchFocusAfterSettingsHandoff(
            isSettingsHandoffRestore: !animated,
            searchHeldFocusBeforeHandoff: pendingSettingsHandoffSearchFocus
        )
        pendingSettingsHandoffSearchFocus = false
        pendingSettingsHandoffSearchResultsChrome = false
        // Opacity-before-unhide: park transparent before orderFront so a model
        // left at 1 (or mid-fade) cannot flash solid for a frame.
        if animated && appearing {
            rootView.parkLauncherPresenceHiddenForAppear()
        }
        window.makeKeyAndOrderFront(nil)
        if restoreSearchFocus {
            // Caret at end so the next character appends (not select-all).
            _ = rootView.focusSearchFieldForSettingsHandoffRestore()
        } else if !keepFocus {
            window.makeFirstResponder(rootView)
        }
        if animated {
            rootView.animateLauncherPresence(visible: true, appearing: appearing)
        } else {
            // Instant-hid for settings left opacity at 1; a normal appear would
            // still fade up from 0. Snap so restore matches the snappy hide.
            rootView.snapLauncherPresenceVisible()
        }
        if directoryWatcher?.watchesAllRoots != true {
            reloadCatalogIfIdle()
        }
        onVisibilityChanged?()
        scheduleAutomatedLaunchVerificationIfNeeded()
        if appearing {
            let elapsedMs = Int((CACurrentMediaTime() - appearStartedAt) * 1000)
            onDiagnosticEvent?("Show appear completed in \(elapsedMs) ms")
        }
    }

    /// DOCK-REVEAL-EDGE-01: lift only Dock hiding while the pointer is in the
    /// screen-edge zone. The menu bar stays hidden. An in-grid reorder never
    /// calls this with `true`. Tests never took these options (see show()).
    func setExternalAppDragActive(_ active: Bool) {
        if active {
            guard !dockHideSuspendedForExternalDrag, testWindowSize == nil,
                  window?.isVisible == true, !isDismissing else { return }
            NSApp.presentationOptions.subtract(.hideDock)
            dockHideSuspendedForExternalDrag = true
            return
        }
        guard dockHideSuspendedForExternalDrag else { return }
        dockHideSuspendedForExternalDrag = false
        guard LauncherLayout.shouldRestoreDockHideAfterExternalDrag(
            launcherVisible: window?.isVisible == true,
            launcherDismissing: isDismissing
        ), testWindowSize == nil else { return }
        NSApp.presentationOptions.formUnion(.hideDock)
    }

    func hide(animated: Bool = true) {
        // REOPEN-PAGE-BEHAVIOR-01: stamp only the visible → dismissing edge.
        // A second hide during the fade must not push the home-reset clock.
        if ReopenPageCopy.shouldStampDismissInstant(
            windowVisible: window?.isVisible == true,
            alreadyDismissing: isDismissing
        ) {
            lastDismissDate = Date()
        }
        // DATE-REARRANGE-HIDE-01
        rootView.invalidateDeferredGridRearrange()
        // SAMPLING-FLAG-CLEAR-ON-HIDE-01 /
        // REARRANGE-PROGRESS-TOAST-CLEAR-ON-HIDE-01: abandoned samples must not
        // block the next sort or leave「正在读取…」under the fade.
        rootView.clearIconSamplingBecauseLauncherIsDismissing()
        // DISMISS-CLEAR-SELECTION-01: drop multi-select before fade so next show is clean.
        rootView.clearItemSelectionForDismiss()
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
        // Status-menu toggle: rewrite「隐藏」→「显示」as soon as dismiss arms so
        // an already-open menu bar item matches visibilityToggle mid-fade.
        if LauncherLayout.shouldRefreshStatusItemToggleTitleOnDismissArm() {
            onVisibilityChanged?()
        }
        rootView.rememberGridPageForDismissal()
        // A wheel step can already be waiting out its quiet period. That wait
        // does not mark the grid as interrupted, so the restore above leaves
        // it armed. Cancel it here, before the fade, and again if a scroll
        // event arrives while the window is still dismissing.
        rootView.cancelPendingPageInput()
        // DRAG-CANCEL-ON-HIDE-01: mid-drag hide left multi-drag companions at
        // opacity 0 and an airborne session under the fade. Same synthetic
        // mouse-up path as Esc cancel.
        rootView.cancelItemDragBecauseLauncherIsDismissing()
        // MARQUEE-CANCEL-ON-HIDE-01: hotkey/status hide mid-band left the
        // marquee overlay under the fade until the next show.
        rootView.cancelMarqueeBecauseLauncherIsDismissing()
        // PINCH-DISMISS-RESET-ON-HIDE-01: mid-pinch hide left accumulated
        // magnification / triggered so the next show could dismiss on the
        // first continued magnify without a fresh .began.
        rootView.resetPinchDismissBecauseLauncherIsDismissing()
        // LAUNCH-HIGHLIGHT-CLEAR-ON-HIDE-01: no open in flight → drop stale
        // 「正在启动…」so the next show is clean.
        if launchesInFlight.isEmpty {
            rootView.setLaunchPending(nil, forceReload: true)
        }
        // SEARCH-KEYBOARD-HIGHLIGHT-CLEAR-ON-HIDE-01: drop search keyboard-open
        // chrome under the fade so the next show does not flash a stale ring.
        rootView.clearSearchKeyboardHighlightBecauseLauncherIsDismissing()
        // ICON-PREFETCH-CANCEL-ON-HIDE-01
        rootView.cancelIconPrefetchBecauseLauncherIsDismissing()
        rootView.cancelTileIconLoadsBecauseLauncherIsDismissing()
        // LAYOUT-FLUSH-ON-HIDE-01: fire the debounced layout save now so a
        // quit during the fade does not drop the last rearrange.
        flushPendingLayoutSave()
        // DOCK-REVEAL-RESET-ON-HIDE-01: mid-drag dismiss left
        // dockHideSuspendedForExternalDrag stuck true so the next show never
        // re-revealed the Dock at the screen edge.
        rootView.cancelExternalDragDockRevealBecauseLauncherIsDismissing()
        rootView.endDropHighlightForDismissal()
        // SETTINGS-HANDOFF-SETTLE-VIA-HIDE-01: dismiss is already armed, so
        // this pass holds or commits in-flight visuals. Settings open used to
        // repeat eight of these first; that earlier pass no-op'd the holds.
        rootView.settleInFlightVisualsForDismissal()
        finishWindowUpdate(cancelled: true)
        // Settings handoff (and any other immediate dismiss) skips the fade so
        // the next window can appear on this turn. Cancel an in-flight fade.
        if !animated {
            pendingSettingsHandoffSearchFocus = LauncherLayout.shouldParkSearchFocusForSettingsHandoff(
                searchHoldsKeyboardFocus: rootView.searchFieldHoldsKeyboardFocus()
            )
            pendingSettingsHandoffSearchResultsChrome = LauncherLayout.shouldParkSearchResultsChromeForSettingsHandoff(
                queryIsNonEmpty: rootView.searchQueryIsNonEmpty()
            )
            if pendingSettingsHandoffSearchResultsChrome {
                rootView.snapPageIndicatorSuppressedForSettingsHandoffRestore()
                rootView.snapPageArrowsSuppressedForSettingsHandoffRestore()
                rootView.snapSearchFooterChromeForSettingsHandoffRestore()
                rootView.snapSearchAdjacentChromeForSettingsHandoffRestore()
            }
            dismissGeneration += 1
            dismissTask?.cancel()
            dismissTask = nil
            dismissArmed = false
            rootView.abandonFolderRenameForDismissal()
            if let window {
                window.ignoresMouseEvents = false
                window.orderOut(nil)
            }
            rootView.applyDeferredVisualState()
            NSApp.presentationOptions.subtract(launcherPresentationOptions)
            onVisibilityChanged?()
            return
        }
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

    func toggleVisibility(settingsIsKey: Bool = false) {
        // HOTKEY-STATUS-SUPPRESS-WHEN-SETTINGS-OR-MODAL-01
        // PRESENCE-TOGGLE-SUPPRESS-WHEN-EDITING-TEXT-01
        guard LauncherLayout.shouldAcceptHotkeyPresenceToggle(
            isPromptingForAlias: rootView.isPromptingForAlias,
            isPromptingForUninstall: rootView.isPromptingForUninstall,
            settingsIsKey: settingsIsKey,
            folderTitleEditing: rootView.isFolderTitleEditing,
            searchFieldEditing: rootView.isSearchFieldEditing
        ) else { return }
        guard let window else { return }
        switch LauncherLayout.visibilityToggle(isVisible: window.isVisible, isDismissing: isDismissing) {
        case .show:
            show()
        case .hide:
            hide()
        }
    }

    /// Dock reopen: show only (never hide). Suppress under Settings / modals.
    func respondToDockReopen(hasVisibleWindows: Bool, settingsIsKey: Bool = false) {
        // DOCK-REOPEN-SUPPRESS-WHEN-SETTINGS-OR-MODAL-01
        // PRESENCE-TOGGLE-SUPPRESS-WHEN-EDITING-TEXT-01
        guard LauncherLayout.shouldAcceptDockReopenShow(
            isPromptingForAlias: rootView.isPromptingForAlias,
            isPromptingForUninstall: rootView.isPromptingForUninstall,
            settingsIsKey: settingsIsKey,
            folderTitleEditing: rootView.isFolderTitleEditing,
            searchFieldEditing: rootView.isSearchFieldEditing
        ) else { return }
        // A Dock click never hides. During the dismiss animation the
        // window is still visible, and the same choice as the hotkey
        // brings it back.
        if LauncherLayout.visibilityToggle(
            isVisible: hasVisibleWindows,
            isDismissing: isDismissing
        ) == .show {
            show()
        }
    }

    /// Hot-corner edge trigger: same animated presence fade as the hotkey
    /// (`show`/`hide` with `shouldAnimateLauncherPresenceForHotCorner`). Does
    /// not snap page indicator/arrows (settings-handoff only).
    func respondToHotCornerTrigger(settingsIsKey: Bool = false) {
        // HOT-CORNER-SUPPRESS-WHEN-SETTINGS-OR-MODAL-01
        // PRESENCE-TOGGLE-SUPPRESS-WHEN-EDITING-TEXT-01
        guard LauncherLayout.shouldAcceptHotCornerPresenceToggle(
            isPromptingForAlias: rootView.isPromptingForAlias,
            isPromptingForUninstall: rootView.isPromptingForUninstall,
            settingsIsKey: settingsIsKey,
            folderTitleEditing: rootView.isFolderTitleEditing,
            searchFieldEditing: rootView.isSearchFieldEditing
        ) else { return }
        // Settings handoff snaps page indicator/arrows; hot corner must not
        // (shouldSnapPagingChromeForHotCornerTrigger == false — guarded in Core tests).
        let animated = LauncherLayout.shouldAnimateLauncherPresenceForHotCorner()
        guard let window else { return }
        switch LauncherLayout.visibilityToggle(
            isVisible: window.isVisible,
            isDismissing: isDismissing
        ) {
        case .show:
            show(animated: animated)
        case .hide:
            hide(animated: animated)
        }
    }
}

/// HIDDEN-FINISH-REGISTRY-01 stage 1: weak add-time table for opacity fades.
/// The explicit `hiddenChromeFinishOrder` landers stay the primary finish
/// path. This table records `layer.add` so a leftover still-attached fade
/// can be drained afterwards. It does not retain views or layers.
final class HiddenFinishTable {
    struct Record {
        weak var view: NSView?
        weak var layer: CALayer?
        var key: String
        var policy: LauncherLayout.HiddenFinishPolicy
    }

    private var records: [Record] = []

    func register(view: NSView, key: String, policy: LauncherLayout.HiddenFinishPolicy) {
        unregister(view: view, key: key)
        records.append(Record(view: view, layer: view.layer, key: key, policy: policy))
    }

    func unregister(view: NSView, key: String) {
        unregister(view: view, layer: view.layer, key: key)
    }

    /// Drop a finished leftover even when the view is already gone and only
    /// a weak layer pointer remains. Matching is by key plus the live view
    /// or the live layer, never by key alone.
    func unregister(view: NSView?, layer: CALayer?, key: String) {
        records.removeAll { record in
            guard record.key == key else { return false }
            if let view, record.view === view { return true }
            if let layer, record.layer === layer { return true }
            return false
        }
    }

    func prune() {
        records.removeAll { $0.view == nil && $0.layer == nil }
    }

    /// Records whose view or layer is still alive. Detached animations are
    /// left for the drain to inspect.
    func liveRecords() -> [Record] {
        prune()
        return records.filter { $0.view != nil || $0.layer != nil }
    }
}

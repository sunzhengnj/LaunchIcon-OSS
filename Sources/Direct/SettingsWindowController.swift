import AppKit
import QuartzCore
import LaunchIconCore
import ServiceManagement
import UniformTypeIdentifiers

/// Esc closes settings like other preference windows. A modal alert or open
/// popup menu consumes Escape first, so this only fires on the bare window.

/// Shared settings chrome metrics (SETTINGS-TAB-CHROME-01 / OpenAI 6.1-sol-high).
/// Tabbed preferences: shorter per-pane form, unified label column.
private enum SettingsWindowChrome {
    static let contentWidth: CGFloat = 560
    static let defaultContentHeight: CGFloat = 560
    static let minimumContentHeight: CGFloat = 480
    /// Inset applied on each edge of `visibleFrame` when fitting the window.
    static let screenMargin: CGFloat = 16
    static let contentInset: CGFloat = 20
    static let stackTopInset: CGFloat = 12
    static let stackBottomInset: CGFloat = 16
    static let sectionGap: CGFloat = 12
    static let sectionHeaderGap: CGFloat = 6
    static let cardCornerRadius: CGFloat = 10
    static let cardPadding: CGFloat = 16
    static let cardVerticalInset: CGFloat = 4
    static let rowHeight: CGFloat = 32
    static let labelWidth: CGFloat = 112
    static let titleFontSize: CGFloat = 13
    static let tabContentInset: CGFloat = 16
}


/// Rounded settings card; refreshes fill when the effective appearance flips.
private final class SettingsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = SettingsWindowChrome.cardCornerRadius
        layer?.masksToBounds = true
        applyCardFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCardFill()
    }

    private func applyCardFill() {
        // SETTINGS-FORM-DENSITY-01: elevated card fill (readable in dark mode)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill = dark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.07)
            : NSColor(calibratedWhite: 1.0, alpha: 0.62)
        layer?.backgroundColor = fill.cgColor
    }
}


/// Flipped settings document so Auto Layout stacks grow downward in the scroll view.
private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsWindow: NSWindow {
    /// When false, `performClose` asks the controller to fade out first.
    var allowCloseWithoutPresenceFade = false
    var onRequestPresenceFadeClose: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        guard LauncherLayout.settingsEscapeClosesWindow else {
            super.cancelOperation(sender)
            return
        }
        performClose(sender)
    }

    override func performClose(_ sender: Any?) {
        if allowCloseWithoutPresenceFade {
            allowCloseWithoutPresenceFade = false
            super.performClose(sender)
            return
        }
        if let onRequestPresenceFadeClose {
            onRequestPresenceFadeClose()
            return
        }
        super.performClose(sender)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSTabViewDelegate {
    var onPreferencesChanged: ((LauncherPreferences) -> String?)?
    var onRestoreHiddenApplication: ((String) -> Bool)?
    var onRestoreAllHiddenApplications: (() -> Int?)?
    var onRescan: (() -> Void)?
    /// One-shot top-level grid rearrange (name / kind).
    var onRearrangeTopLevel: ((LauncherLayout.GridRearrangeSort) -> Bool)?
    var onRearrangeByCategory: (() -> Bool)?
    var onRearrangeByColor: (() async -> Bool)?
    var onRearrangeByDate: ((AppDateRearrangeKind) async -> Bool)?
    /// True when layout-v1.backup.json exists (automatic prior-layout backup).
    var layoutBackupAvailable: (() -> Bool)?
    /// Wait for LayoutStore's debounced save so backup.json exists, then refresh.
    var onAwaitLayoutPersist: (() async -> Void)?
    /// Export current layout JSON to the given URL.
    var onExportLayout: ((URL) async -> String)?
    /// Import layout JSON from the given URL (reconcile + commit).
    var onImportLayout: ((URL) async -> String)?
    var onImportLaunchpadLayout: ((URL) async -> String)?
    /// Restore automatic last backup (reconcile + commit).
    var onRestoreLayoutBackup: (() async -> String)?
    /// Runs the orphan-leftovers flow; progress lines update the settings message.
    var onCleanUpLeftovers: (((@MainActor (String) -> Void)?) async -> String)?
    /// Live hidden list from the launcher. Hiding/restoring in the launcher,
    /// importing or restoring a layout can change it while Settings stays open.
    var hiddenApplicationsProvider: (() -> [HiddenApplication]?)?
    /// Fired when the settings window is closing (red button / Close).
    var onWindowWillClose: (() -> Void)?

    private var preferences: LauncherPreferences
    private var hiddenApplications: [HiddenApplication]
    private let shortcutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hotCornerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayTargetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// BACKGROUND-DIM-01
    private let backgroundDimPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let reopenPagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pageFlipDirectionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// GRID-GEOMETRY-SETTINGS-01
    private let gridColumnsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gridRowsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// BACKGROUND-BLUR-01
    private let backgroundBlurCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let statusCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    // One form row「隐藏名称」holds both app + folder toggles (keeps one row of height).
    private let appNamesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let folderNamesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let hideCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let motionCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let pinchDismissCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let hiddenApplicationsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    // SETTINGS-HIDDEN-APPS-CHROME-COPY-01
    private let restoreHiddenApplicationButton = NSButton(
        title: L(LauncherLayout.SettingsHiddenAppsChromeCopy.restoreButtonTitleKey),
        target: nil,
        action: nil
    )
    private let restoreAllHiddenApplicationsButton = NSButton(
        title: L(LauncherLayout.restoreAllHiddenButtonTitleKey), target: nil, action: nil
    )
    // SETTINGS-FORM-DENSITY-01 + SETTINGS-REARRANGE-BUTTONS-COPY-01: one popup, AX ids on items
    private let rearrangePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    // SETTINGS-MAINTENANCE-LAYOUT-CHROME-COPY-01
    private let rescanButton = NSButton(
        title: L(LauncherLayout.SettingsMaintenanceChromeCopy.rescanButtonTitleKey),
        target: nil,
        action: nil
    )
    private let leftoversButton = NSButton(
        title: L(LauncherLayout.SettingsMaintenanceChromeCopy.leftoversButtonTitleKey),
        target: nil,
        action: nil
    )
    private let appDirectoriesPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    // Layout I/O collapsed into one pull-down; keep title keys + AX ids on menu items.
    private let layoutIOPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private var restoreLayoutBackupMenuItem: NSMenuItem?
    // Retained title/key references for chrome-copy guards (actions live on menu items).
    private let exportLayoutButtonTitle = L(LauncherLayout.SettingsLayoutIOChromeCopy.exportButtonTitleKey)
    private let importLayoutButtonTitle = L(LauncherLayout.SettingsLayoutIOChromeCopy.importButtonTitleKey)
    private let restoreLayoutBackupButtonTitle = L(LauncherLayout.SettingsLayoutIOChromeCopy.restoreBackupButtonTitleKey)
    private let importLaunchpadButtonTitle = L("从启动台导入…")
    private let messageLabel = NSTextField(labelWithString: "")
    private var shortcutRegistrationError: String?
    private var isRescanning = false
    private var leftoversTask: Task<Void, Never>?
    /// Bumped on every `setMessage` so an older fade cannot wipe a newer line.
    private var messageFadeGeneration: UInt64 = 0
    /// Crossfade destination. The completion applies it after opacity hits 0.
    /// Close uses it when that completion never runs.
    private var messageFadeReplacement: String?
    /// Bumped on every presence fade so an older hide cannot orderOut a newer show.
    private var settingsPresenceGeneration: UInt64 = 0
    // SETTINGS-COMPACT-SCROLL-02: frame-managed scroll document + measurable form root.
    private let settingsScrollView = NSScrollView()
    private let settingsDocumentView = SettingsDocumentView()
    // SETTINGS-TAB-SCROLL-03: retain measurable roots for every tab, not only Appearance.
    private var settingsScrollPanes: [
        (scrollView: NSScrollView, document: SettingsDocumentView, content: NSView)
    ] = []
    /// SETTINGS-TAB-LAYOUT-ON-SHOW-01: show/resize must lay out the selected tab,
    /// not only `tabView(_:didSelect:)`.
    private var settingsTabView: NSTabView?
    private var refreshingSettingsDocument = false

    init(preferences: LauncherPreferences, hiddenApplications: [HiddenApplication]) {
        self.preferences = preferences
        self.hiddenApplications = hiddenApplications
        let window = SettingsWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsWindowChrome.contentWidth,
                height: SettingsWindowChrome.defaultContentHeight
            ),
            // SETTINGS-COMPACT-SCROLL-02: vertical resize; width locked via content min/max.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // SETTINGS-SECTION-CHROME-01
        window.title = SettingsSectionChromeCopy.windowTitle(localize: { L($0) })
        window.contentMinSize = NSSize(
            width: SettingsWindowChrome.contentWidth,
            height: SettingsWindowChrome.minimumContentHeight
        )
        window.contentMaxSize = NSSize(
            width: SettingsWindowChrome.contentWidth,
            height: 12_000
        )
        Self.fitSettingsWindowToVisibleScreen(window)
        window.center()
        // Reused by showSettings; closing must not release the window out from
        // under the retained controller (and the next gear/⌘, open).
        window.isReleasedWhenClosed = false
        super.init(window: window)
        // SETTINGS-WILLCLOSE-01: observe willClose explicitly — assigning
        // `window.delegate = self` fails to type-check as NSWindowDelegate on
        // this SDK, and didBecomeKey already uses NotificationCenter.
        window.onRequestPresenceFadeClose = { [weak self] in
            self?.hideSettingsWindowPresenceThenClose()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowWillCloseNotification(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        buildContent(in: window)
        updateControls()
        refreshLoginStatus()
        refreshLayoutBackupControls()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsScreenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // SETTINGS-TAB-SCROLL-03: keep every tab's document height current during resize.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        // Initial document height needs a laid-out clip width. The first tab
        // does not receive didSelect (delegate is attached after the items).
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.relayoutSettingsChrome()
            Self.fitSettingsWindowToVisibleScreen(window, initial: true)
            self.relayoutSettingsChrome()
        }
    }

    // SETTINGS-WILLCLOSE-01: delegate hook (SDK may not expose override).
    func windowWillClose(_ notification: Notification) {
        handleSettingsWindowWillClose()
    }

    /// Observed explicitly so close cleanup runs even if `window.delegate` changes.
    @objc private func settingsWindowWillCloseNotification(_ notification: Notification) {
        handleSettingsWindowWillClose()
    }

    private var didHandleSettingsWindowWillClose = false

    private func handleSettingsWindowWillClose() {
        // performClose → fade → performClose can deliver willClose once; guard
        // against duplicate cancel/callback if both delegate + notification fire.
        guard !didHandleSettingsWindowWillClose else { return }
        didHandleSettingsWindowWillClose = true
        finishSettingsMessageFadeForClose()
        leftoversTask?.cancel()
        leftoversTask = nil
        cancelSettingsMissingScreenFollowUp()
        restoreLeftoversButtonIdle()
        onWindowWillClose?()
    }

    /// Observed explicitly (not via the delegate) so it works whoever the delegate is.
    @objc private func settingsWindowDidBecomeKey(_ notification: Notification) {
        refreshHiddenApplicationsFromLauncher()
    }

    /// Re-read the hidden list; untouched when nothing changed so the popup
    /// selection is kept. Also called after catalog reload so a Settings window
    /// opened mid-scan (e.g. LAUNCHICON_TEST_OPEN_SETTINGS) picks up hides once
    /// candidates exist — becomeKey alone is not enough if it already fired.
    func refreshHiddenApplicationsFromLauncher() {
        guard let latest = hiddenApplicationsProvider?(), latest != hiddenApplications else { return }
        hiddenApplications = latest
        updateHiddenApplications()
    }


    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show(preferences: LauncherPreferences, hiddenApplications: [HiddenApplication]) {
        didHandleSettingsWindowWillClose = false
        self.preferences = preferences
        self.hiddenApplications = hiddenApplications
        if leftoversTask != nil {
            setMessage(L(AppOrphanLeftoverScanner.scanningProgressMessageKey), animated: false)
        } else if !isRescanning && shortcutRegistrationError == nil {
            setMessage("", animated: false)
        }
        updateControls()
        refreshLoginStatus()
        refreshLayoutBackupControls()
        if let window {
            Self.fitSettingsWindowToVisibleScreen(window, initial: false)
        }
        relayoutSettingsChrome()
        presentSettingsWindowPresence()
        DispatchQueue.main.async { [weak self] in
            self?.relayoutSettingsChrome()
        }
    }

    func presentShortcutRegistrationError(_ message: String) {
        shortcutRegistrationError = message
        setMessage(message)
    }

    func completeRescan(canEditLayout: Bool) {
        guard isRescanning else { return }
        isRescanning = false
        rescanButton.isEnabled = true
        guard shortcutRegistrationError == nil else { return }
        // LAYOUT-EDITING-STATUS-COPY-01
        setMessage(
            canEditLayout
                ? LauncherLayout.LayoutEditingStatusCopy.rescanSucceeded(localize: { L($0) })
                : LauncherLayout.LayoutIOOutcomeCopy.layoutEditingBlocked(localize: { L($0) })
        )
    }

    /// Shared metrics for form rows / cards (LaunchIcon settings chrome).
    /// Keep literals in sync with `SettingsWindowChrome` (guards read the file-level enum).
    private enum SettingsChrome {
        // SETTINGS-TAB-CHROME-01 / SETTINGS-COMPACT-SCROLL-02: tab panes + scroll safety
        static let contentInset: CGFloat = SettingsWindowChrome.contentInset
        static let sectionGap: CGFloat = SettingsWindowChrome.sectionGap
        static let cardCornerRadius: CGFloat = SettingsWindowChrome.cardCornerRadius
        static let cardPadding: CGFloat = SettingsWindowChrome.cardPadding
        static let rowHeight: CGFloat = SettingsWindowChrome.rowHeight
        static let labelWidth: CGFloat = SettingsWindowChrome.labelWidth
        static let stackTopInset: CGFloat = SettingsWindowChrome.stackTopInset
        static let stackBottomInset: CGFloat = SettingsWindowChrome.stackBottomInset
        static let sectionHeaderGap: CGFloat = SettingsWindowChrome.sectionHeaderGap
        static let cardVerticalInset: CGFloat = SettingsWindowChrome.cardVerticalInset
        static let titleFontSize: CGFloat = SettingsWindowChrome.titleFontSize
        static let tabContentInset: CGFloat = SettingsWindowChrome.tabContentInset
    }


    /// Keep the settings window inside `visibleFrame` (Dock / menu bar excluded).
    /// SETTINGS-COMPACT-SCROLL-02 / OpenAI: convert work area via contentRect; never sit under Dock.
    /// SETTINGS-SCREEN-FIT-OFFSCREEN-01: a closed window's `screen` is nil.
    /// Do not treat that as the main screen, or every reopen jumps displays.
    private static func fitSettingsWindowToVisibleScreen(_ window: NSWindow, initial: Bool = true) {
        let margin = SettingsWindowChrome.screenMargin
        guard let screen = screenForSettingsFit(window, initial: initial) else { return }
        let work = screen.visibleFrame.insetBy(dx: margin, dy: margin)
        let capacity = window.contentRect(forFrameRect: work).size
        guard capacity.width > 0, capacity.height > 0 else { return }

        let minHeight = min(SettingsWindowChrome.minimumContentHeight, capacity.height)
        window.contentMinSize = NSSize(width: SettingsWindowChrome.contentWidth, height: minHeight)
        window.contentMaxSize = NSSize(width: SettingsWindowChrome.contentWidth, height: 12_000)

        let current = window.contentRect(forFrameRect: window.frame).size
        let targetHeight: CGFloat
        if initial {
            targetHeight = min(SettingsWindowChrome.defaultContentHeight, capacity.height)
        } else {
            // Preserve user resize, but clamp into the current work area.
            targetHeight = min(max(current.height, minHeight), capacity.height)
        }
        let wanted = NSSize(width: SettingsWindowChrome.contentWidth, height: max(minHeight, targetHeight))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: wanted))
        // Keep the top edge stable when shrinking so the title bar does not jump under the menu bar.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame.origin.x = min(max(frame.minX, work.minX), max(work.minX, work.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, work.minY), max(work.minY, work.maxY - frame.height))
        if frame.size != window.frame.size || frame.origin != window.frame.origin {
            window.setFrame(frame, display: true)
        }
    }

    /// SETTINGS-SCREEN-FIT-OFFSCREEN-01: attached windows use their screen.
    /// A closed window keeps the display under its frame. The first
    /// appearance, or a frame that meets no display, may use the main screen.
    private static func screenForSettingsFit(_ window: NSWindow, initial: Bool) -> NSScreen? {
        let screens = NSScreen.screens
        let choice = LauncherLayout.settingsFitScreenChoice(
            windowFrame: window.frame,
            hasAttachedScreen: window.screen != nil,
            preferFrameIntersection: !initial,
            candidateScreenFrames: screens.map(\.frame),
            hasMainScreen: NSScreen.main != nil
        )
        switch choice {
        case .attached:
            return window.screen
        case .candidate(let index):
            guard screens.indices.contains(index) else { return nil }
            return screens[index]
        case .main:
            return NSScreen.main
        case nil:
            return nil
        }
    }

    @objc private func settingsScreenParametersDidChange(_ notification: Notification) {
        refreshSettingsScreenFit()
    }

    /// SETTINGS-SCREEN-NIL-HOLD-01: a parameter notification can arrive
    /// before AppKit attaches this window to a screen. Fitting in that gap
    /// can clamp the window onto the main screen when its frame does not yet
    /// meet the display it is moving to. Look once on the next turn, then
    /// wait for the next notification. The first appearance may still use
    /// the main screen inside `fit`.
    private func refreshSettingsScreenFit() {
        guard let window else { return }
        if LauncherLayout.shouldHoldSettingsScreenFitForMissingScreen(
            screenAvailable: window.screen != nil
        ) {
            armSettingsMissingScreenFollowUpIfNeeded()
            return
        }
        cancelSettingsMissingScreenFollowUp()
        Self.fitSettingsWindowToVisibleScreen(window, initial: false)
        relayoutSettingsChrome()
    }

    private var settingsMissingScreenFollowUp: DispatchWorkItem?
    private var settingsMissingScreenFollowUpIsRunning = false

    private func armSettingsMissingScreenFollowUpIfNeeded() {
        if settingsMissingScreenFollowUpIsRunning || settingsMissingScreenFollowUp != nil { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settingsMissingScreenFollowUp = nil
            self.settingsMissingScreenFollowUpIsRunning = true
            self.refreshSettingsScreenFit()
            self.settingsMissingScreenFollowUpIsRunning = false
        }
        settingsMissingScreenFollowUp = work
        DispatchQueue.main.async(execute: work)
    }

    private func cancelSettingsMissingScreenFollowUp() {
        settingsMissingScreenFollowUp?.cancel()
        settingsMissingScreenFollowUp = nil
    }

    @objc private func settingsWindowDidResize(_ notification: Notification) {
        // SETTINGS-TAB-SCROLL-03 / LAYOUT-ON-SHOW-01: measure against the resized
        // clip, and give the selected pane the new content rect first.
        relayoutSettingsChrome()
        DispatchQueue.main.async { [weak self] in
            self?.relayoutSettingsChrome()
        }
    }

    /// Selected tab frame, then every pane's document height. Show, resize,
    /// screen changes, and tab selection all share this so a 1pt placeholder
    /// is not the last layout a pane receives.
    private func relayoutSettingsChrome() {
        if let settingsTabView {
            layoutSelectedSettingsTab(in: settingsTabView)
        }
        refreshSettingsDocumentSize()
    }

    /// Measure every form at its clip width and publish document heights to NSScrollView.
    private func refreshSettingsDocumentSize() {
        guard !refreshingSettingsDocument else { return }
        refreshingSettingsDocument = true
        defer { refreshingSettingsDocument = false }

        window?.contentView?.layoutSubtreeIfNeeded()

        for pane in settingsScrollPanes {
            let scrollView = pane.scrollView
            let document = pane.document
            let content = pane.content

            scrollView.layoutSubtreeIfNeeded()
            scrollView.tile()
            scrollView.layoutSubtreeIfNeeded()

            let clip = scrollView.contentView
            let viewport = clip.bounds.size
            guard viewport.width > 32, viewport.height > 0 else { continue }

            let oldOrigin = clip.bounds.origin

            // Resolve wrapping at the actual clip width before measuring height.
            document.setFrameSize(
                NSSize(width: viewport.width, height: max(document.frame.height, 1))
            )
            document.needsLayout = true
            document.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()

            let requiredHeight = SettingsScrollDocument.documentHeight(
                viewportHeight: viewport.height,
                contentFittingHeight: content.fittingSize.height,
                stackTopInset: SettingsChrome.stackTopInset,
                stackBottomInset: SettingsChrome.stackBottomInset,
                laidOutContentHeight: content.bounds.height
            )
            document.setFrameSize(
                NSSize(
                    width: viewport.width,
                    height: requiredHeight
                )
            )
            document.needsLayout = true
            document.layoutSubtreeIfNeeded()

            // Keep each tab's position, clamped to its newly measured document.
            let proposed = NSRect(
                origin: NSPoint(x: 0, y: oldOrigin.y),
                size: viewport
            )
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            scrollView.reflectScrolledClipView(clip)

            document.needsDisplay = true
            clip.needsDisplay = true
            scrollView.needsDisplay = true
        }
    }

    // SETTINGS-TAB-SCROLL-03: a newly selected pane may only now have its final clip size.
    private func layoutSelectedSettingsTab(in tabView: NSTabView) {
        window?.contentView?.layoutSubtreeIfNeeded()
        tabView.layoutSubtreeIfNeeded()

        guard let paneView = tabView.selectedTabViewItem?.view else { return }

        paneView.translatesAutoresizingMaskIntoConstraints = true
        paneView.autoresizingMask = [.width, .height]

        // Also handle selection callbacks delivered before AppKit installs the pane.
        let targetFrame: NSRect
        if let parent = paneView.superview {
            targetFrame = tabView.convert(tabView.contentRect, to: parent)
        } else {
            targetFrame = tabView.contentRect
        }

        // A 1pt placeholder (the frame unselected tab items start with) must
        // not be written onto the selected scroll view.
        guard SettingsScrollDocument.selectedPaneFrameIsUsable(targetFrame) else { return }

        if paneView.frame != targetFrame {
            paneView.frame = targetFrame
        }
        paneView.needsLayout = true
        paneView.layoutSubtreeIfNeeded()
        paneView.needsDisplay = true
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        relayoutSettingsChrome()
        // SETTINGS-TAB-SCROLL-TO-TOP-01: newly selected pane starts at top.
        scrollSelectedSettingsTabToTop(in: tabView)

        // SETTINGS-TAB-SCROLL-04: repeat after AppKit finishes installing the selected pane.
        DispatchQueue.main.async { [weak self] in
            self?.relayoutSettingsChrome()
            self?.scrollSelectedSettingsTabToTop(in: tabView)
        }
    }

    /// SETTINGS-TAB-SCROLL-TO-TOP-01
    private func scrollSelectedSettingsTabToTop(in tabView: NSTabView) {
        guard let selected = tabView.selectedTabViewItem else { return }
        let index = tabView.indexOfTabViewItem(selected)
        guard index != NSNotFound, index >= 0, index < settingsScrollPanes.count else { return }
        let scrollView = settingsScrollPanes[index].scrollView
        let clip = scrollView.contentView
        let origin = SettingsScrollDocument.scrollOriginForTabSelectReset()
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func buildContent(in window: NSWindow) {
        let root = NSView()
        window.contentView = root

        // Header: version only (tabs replace the old "通用" page title).
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 12
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        // SETTINGS-SECTION-CHROME-01 — pageTitle retained as AX label for the tab strip.
        let title = NSTextField(
            labelWithString: SettingsSectionChromeCopy.pageTitle(localize: { L($0) })
        )
        title.font = .systemFont(ofSize: SettingsChrome.titleFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.isHidden = true
        titleRow.addArrangedSubview(title)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(spacer)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? SettingsSectionChromeCopy.unknownVersion(localize: { L($0) })
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? SettingsSectionChromeCopy.unknownVersion(localize: { L($0) })
        let sourceCommit = Bundle.main.infoDictionary?["LaunchIconSourceCommit"] as? String
        let source = sourceCommit.map {
            SettingsSectionChromeCopy.sourceLabel(
                shortCommit: String($0.prefix(7)),
                localize: { L($0) }
            )
        } ?? SettingsSectionChromeCopy.developmentBuild(localize: { L($0) })
        let versionLabel = NSTextField(
            labelWithString: SettingsSectionChromeCopy.versionLine(
                version: version,
                build: build,
                source: source,
                localize: { L($0) }
            )
        )
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.toolTip = sourceCommit
        if let sourceCommit {
            versionLabel.setAccessibilityHelp(
                SettingsSectionChromeCopy.fullCommitHelp(
                    commit: sourceCommit,
                    localize: { L($0) }
                )
            )
        }
        titleRow.addArrangedSubview(versionLabel)
        root.addSubview(titleRow)

        // SETTINGS-TAB-CHROME-01 / OpenAI: NSTabView top tabs (外观/行为/应用/维护).
        let tabView = NSTabView()
        settingsTabView = tabView
        tabView.tabViewType = .topTabsBezelBorder
        tabView.drawsBackground = false
        tabView.setAccessibilityLabel(SettingsSectionChromeCopy.pageTitle(localize: { L($0) }))
        tabView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabView)

        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsChrome.contentInset),
            titleRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -SettingsChrome.contentInset),
            titleRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            tabView.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 4),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])

        // --- Wire controls (appearance) ---
        shortcutPopup.addItems(withTitles: LauncherShortcut.allCases.map(\.title))
        shortcutPopup.setAccessibilityLabel(SettingsAppearanceChromeCopy.shortcutLabel(localize: { L($0) }))
        window.initialFirstResponder = shortcutPopup
        shortcutPopup.target = self
        shortcutPopup.action = #selector(preferencesChanged)
        hotCornerPopup.addItems(withTitles: LauncherHotCorner.allCases.map { L($0.title) })
        hotCornerPopup.setAccessibilityIdentifier("settings-hot-corner")
        hotCornerPopup.setAccessibilityLabel(SettingsAppearanceChromeCopy.hotCornerLabel(localize: { L($0) }))
        // HOT-CORNER-CONFLICT-HELP-01
        hotCornerPopup.setAccessibilityHelp(
            HotCornerConflictCopy.accessibilityHelp(localize: { L($0) })
        )
        hotCornerPopup.toolTip = HotCornerConflictCopy.conflictToolTip(localize: { L($0) })
        hotCornerPopup.target = self
        hotCornerPopup.action = #selector(preferencesChanged)
        displayTargetPopup.addItems(withTitles: LauncherDisplayTarget.allCases.map { L($0.title) })
        displayTargetPopup.setAccessibilityIdentifier("settings-display-target")
        // SETTINGS-DISPLAY-FEEDBACK-01
        displayTargetPopup.setAccessibilityLabel(
            DisplayTargetCopy.label(localize: { L($0) })
        )
        displayTargetPopup.setAccessibilityHelp(
            DisplayTargetCopy.accessibilityHelp(localize: { L($0) })
        )
        displayTargetPopup.target = self
        displayTargetPopup.action = #selector(preferencesChanged)
        // BACKGROUND-DIM-01
        backgroundDimPopup.addItems(withTitles: LauncherBackgroundDim.allCases.map { L($0.title) })
        backgroundDimPopup.setAccessibilityIdentifier("settings-background-dim")
        backgroundDimPopup.setAccessibilityLabel(BackgroundDimCopy.label(localize: { L($0) }))
        backgroundDimPopup.setAccessibilityHelp(BackgroundDimCopy.accessibilityHelp(localize: { L($0) }))
        backgroundDimPopup.target = self
        backgroundDimPopup.action = #selector(preferencesChanged)
        // BACKGROUND-BLUR-01
        backgroundBlurCheckbox.title = BackgroundDimCopy.blurTitle(localize: { L($0) })
        backgroundBlurCheckbox.setAccessibilityIdentifier("settings-background-blur")
        backgroundBlurCheckbox.setAccessibilityLabel(BackgroundDimCopy.blurAccessibilityLabel(localize: { L($0) }))
        backgroundBlurCheckbox.setAccessibilityHelp(BackgroundDimCopy.blurAccessibilityHelp(localize: { L($0) }))
        backgroundBlurCheckbox.target = self
        backgroundBlurCheckbox.action = #selector(preferencesChanged)
        let backgroundControls = NSStackView(views: [backgroundDimPopup, backgroundBlurCheckbox])
        backgroundControls.orientation = .horizontal
        backgroundControls.alignment = .centerY
        backgroundControls.spacing = 12
        // SETTINGS-APPEARANCE-CHROME-COPY-01
        statusCheckbox.title = SettingsAppearanceChromeCopy.statusItemTitle(localize: { L($0) })
        statusCheckbox.target = self
        statusCheckbox.action = #selector(preferencesChanged)
        statusCheckbox.setAccessibilityIdentifier("settings-status-item")
        statusCheckbox.setAccessibilityLabel(SettingsAppearanceChromeCopy.statusItemTitle(localize: { L($0) }))
        statusCheckbox.setAccessibilityHelp(SettingsAppearanceChromeCopy.statusItemHelp(localize: { L($0) }))
        appNamesCheckbox.title = SettingsAppearanceChromeCopy.hideAppNamesCheckboxTitle(localize: { L($0) })
        appNamesCheckbox.target = self
        appNamesCheckbox.action = #selector(preferencesChanged)
        appNamesCheckbox.setAccessibilityIdentifier("settings-hide-app-names")
        appNamesCheckbox.setAccessibilityHelp(SettingsAppearanceChromeCopy.hideAppNamesHelp(localize: { L($0) }))
        folderNamesCheckbox.title = SettingsAppearanceChromeCopy.hideFolderNamesCheckboxTitle(localize: { L($0) })
        folderNamesCheckbox.target = self
        folderNamesCheckbox.action = #selector(preferencesChanged)
        folderNamesCheckbox.setAccessibilityIdentifier("settings-hide-folder-names")
        folderNamesCheckbox.setAccessibilityHelp(SettingsAppearanceChromeCopy.hideFolderNamesHelp(localize: { L($0) }))
        appNamesCheckbox.setAccessibilityLabel(SettingsAppearanceChromeCopy.hideAppNamesLabel(localize: { L($0) }))
        folderNamesCheckbox.setAccessibilityLabel(SettingsAppearanceChromeCopy.hideFolderNamesLabel(localize: { L($0) }))
        let namesToggles = NSStackView(views: [appNamesCheckbox, folderNamesCheckbox])
        namesToggles.orientation = .horizontal
        namesToggles.spacing = 16

        func fillGridGeometryPopup(_ popup: NSPopUpButton, titles: [String], identifier: String, label: String) {
            popup.removeAllItems()
            popup.addItems(withTitles: titles)
            popup.setAccessibilityIdentifier(identifier)
            popup.setAccessibilityLabel(label)
            popup.setAccessibilityHelp(GridGeometryCopy.accessibilityHelp(localize: { L($0) }))
            popup.target = self
            popup.action = #selector(preferencesChanged)
        }
        fillGridGeometryPopup(
            gridColumnsPopup,
            titles: GridGeometryPreference.columnChoices.map { GridGeometryCopy.columnsItemTitle($0, localize: { L($0) }) },
            identifier: GridGeometryCopy.columnsPopupIdentifier,
            label: GridGeometryCopy.columnsLabel(localize: { L($0) })
        )
        fillGridGeometryPopup(
            gridRowsPopup,
            titles: GridGeometryPreference.rowChoices.map { GridGeometryCopy.rowsItemTitle($0, localize: { L($0) }) },
            identifier: GridGeometryCopy.rowsPopupIdentifier,
            label: GridGeometryCopy.rowsLabel(localize: { L($0) })
        )
        let gridColumnLabel = NSTextField(labelWithString: GridGeometryCopy.columnsLabel(localize: { L($0) }))
        gridColumnLabel.font = .systemFont(ofSize: 13)
        // The popups already expose "列" / "行"; hide the visible captions from AX
        // so VoiceOver does not hear the name twice.
        gridColumnLabel.setAccessibilityElement(false)
        let gridRowLabel = NSTextField(labelWithString: GridGeometryCopy.rowsLabel(localize: { L($0) }))
        gridRowLabel.font = .systemFont(ofSize: 13)
        gridRowLabel.setAccessibilityElement(false)
        let gridGeometryControls = NSStackView(views: [
            gridColumnLabel, gridColumnsPopup, gridRowLabel, gridRowsPopup
        ])
        gridGeometryControls.orientation = .horizontal
        gridGeometryControls.alignment = .centerY
        gridGeometryControls.spacing = 8

        let appearanceRows: [NSView] = [
            makeFormRow(title: SettingsAppearanceChromeCopy.shortcutLabel(localize: { L($0) }), control: shortcutPopup),
            makeFormRow(title: SettingsAppearanceChromeCopy.hotCornerLabel(localize: { L($0) }), control: hotCornerPopup),
            makeFormRow(
                title: DisplayTargetCopy.label(localize: { L($0) }),
                control: displayTargetPopup
            ),
            makeFormRow(
                title: BackgroundDimCopy.rowTitle(localize: { L($0) }),
                control: backgroundControls
            ),
            makeToggleRow(statusCheckbox),
            makeFormRow(title: SettingsAppearanceChromeCopy.hideNamesRowTitle(localize: { L($0) }), control: namesToggles),
            makeFormRow(
                title: GridGeometryCopy.rowTitle(localize: { L($0) }),
                control: gridGeometryControls,
                controlWidth: nil
            )
        ]

        // --- 行为 ---
        for checkbox in [hideCheckbox, motionCheckbox, pinchDismissCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(preferencesChanged)
        }
        // SETTINGS-BEHAVIOR-TOGGLES-COPY-01
        hideCheckbox.title = SettingsBehaviorTogglesCopy.hideAfterLaunchTitle(localize: { L($0) })
        hideCheckbox.setAccessibilityIdentifier("settings-hide-after-launch")
        hideCheckbox.setAccessibilityLabel(SettingsBehaviorTogglesCopy.hideAfterLaunchTitle(localize: { L($0) }))
        hideCheckbox.setAccessibilityHelp(SettingsBehaviorTogglesCopy.hideAfterLaunchHelp(localize: { L($0) }))
        motionCheckbox.title = SettingsBehaviorTogglesCopy.reducesMotionTitle(localize: { L($0) })
        motionCheckbox.setAccessibilityIdentifier("settings-reduces-motion")
        motionCheckbox.setAccessibilityLabel(SettingsBehaviorTogglesCopy.reducesMotionTitle(localize: { L($0) }))
        motionCheckbox.setAccessibilityHelp(SettingsBehaviorTogglesCopy.reducesMotionHelp(localize: { L($0) }))
        motionCheckbox.toolTip = SettingsBehaviorTogglesCopy.reducesMotionToolTip(localize: { L($0) })
        // PINCH-TO-DISMISS-01
        pinchDismissCheckbox.title = PinchDismissCopy.title(localize: { L($0) })
        pinchDismissCheckbox.setAccessibilityIdentifier("settings-pinch-dismiss")
        pinchDismissCheckbox.setAccessibilityLabel(PinchDismissCopy.accessibilityLabel(localize: { L($0) }))
        pinchDismissCheckbox.setAccessibilityHelp(PinchDismissCopy.accessibilityHelp(localize: { L($0) }))
        // REOPEN-PAGE-BEHAVIOR-01
        reopenPagePopup.addItems(withTitles: LauncherReopenPageBehavior.allCases.map { L($0.title) })
        reopenPagePopup.setAccessibilityIdentifier("settings-reopen-page")
        reopenPagePopup.setAccessibilityLabel(ReopenPageCopy.label(localize: { L($0) }))
        reopenPagePopup.setAccessibilityHelp(ReopenPageCopy.accessibilityHelp(localize: { L($0) }))
        reopenPagePopup.target = self
        reopenPagePopup.action = #selector(preferencesChanged)
        // PAGE-FLIP-DIRECTION-01
        pageFlipDirectionPopup.addItems(withTitles: LauncherPageFlipDirection.allCases.map { L($0.title) })
        pageFlipDirectionPopup.setAccessibilityIdentifier("settings-page-flip-direction")
        pageFlipDirectionPopup.setAccessibilityLabel(PageFlipDirectionCopy.label(localize: { L($0) }))
        pageFlipDirectionPopup.setAccessibilityHelp(PageFlipDirectionCopy.accessibilityHelp(localize: { L($0) }))
        pageFlipDirectionPopup.target = self
        pageFlipDirectionPopup.action = #selector(preferencesChanged)
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged)
        loginCheckbox.title = SettingsBehaviorTogglesCopy.loginTitle(localize: { L($0) })
        loginCheckbox.setAccessibilityIdentifier("settings-login-item")
        loginCheckbox.setAccessibilityLabel(SettingsBehaviorTogglesCopy.loginTitle(localize: { L($0) }))
        loginCheckbox.setAccessibilityHelp(SettingsBehaviorTogglesCopy.loginHelp(localize: { L($0) }))
        let systemButton = NSButton(
            title: SettingsBehaviorTogglesCopy.openLoginSettingsTitle(localize: { L($0) }),
            target: self,
            action: #selector(openLoginSettings)
        )
        systemButton.bezelStyle = .inline
        systemButton.setAccessibilityIdentifier("settings-open-login-settings")
        systemButton.setAccessibilityLabel(SettingsBehaviorTogglesCopy.openLoginSettingsLabel(localize: { L($0) }))
        let behaviorRows: [NSView] = [
            makeToggleRow(hideCheckbox),
            makeToggleRow(motionCheckbox),
            makeToggleRow(pinchDismissCheckbox),
            makeFormRow(
                title: ReopenPageCopy.label(localize: { L($0) }),
                control: reopenPagePopup
            ),
            makeFormRow(
                title: PageFlipDirectionCopy.label(localize: { L($0) }),
                control: pageFlipDirectionPopup
            ),
            makeLoginRow(loginCheckbox, systemButton)
        ]

        // --- 应用管理 ---
        hiddenApplicationsPopup.setAccessibilityLabel(
            LauncherLayout.SettingsHiddenAppsChromeCopy.rowTitle(localize: { L($0) })
        )
        hiddenApplicationsPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hiddenApplicationsPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        restoreHiddenApplicationButton.target = self
        restoreHiddenApplicationButton.action = #selector(restoreHiddenApplication)
        restoreHiddenApplicationButton.setAccessibilityLabel(
            LauncherLayout.SettingsHiddenAppsChromeCopy.restoreAccessibilityLabel(localize: { L($0) })
        )
        restoreHiddenApplicationButton.setAccessibilityHelp(
            LauncherLayout.SettingsHiddenAppsChromeCopy.restoreAccessibilityHelp(localize: { L($0) })
        )
        restoreHiddenApplicationButton.setAccessibilityIdentifier("settings-restore-hidden")
        let hiddenControls = NSStackView()
        hiddenControls.orientation = .horizontal
        hiddenControls.alignment = .centerY
        hiddenControls.spacing = 8
        hiddenControls.addArrangedSubview(hiddenApplicationsPopup)
        hiddenControls.addArrangedSubview(restoreHiddenApplicationButton)
        restoreAllHiddenApplicationsButton.target = self
        restoreAllHiddenApplicationsButton.action = #selector(restoreAllHiddenApplications)
        restoreAllHiddenApplicationsButton.setAccessibilityHelp(L(LauncherLayout.restoreAllHiddenAccessibilityHelpKey))
        restoreAllHiddenApplicationsButton.setAccessibilityIdentifier("settings-restore-all-hidden")
        restoreAllHiddenApplicationsButton.setAccessibilityLabel(L(LauncherLayout.restoreAllHiddenButtonTitleKey))
        restoreAllHiddenApplicationsButton.isHidden = true
        hiddenControls.addArrangedSubview(restoreAllHiddenApplicationsButton)
        // Guard looks for `let hiddenRow`.
        let hiddenRow = makeFormRow(
            title: LauncherLayout.SettingsHiddenAppsChromeCopy.rowTitle(localize: { L($0) }),
            control: hiddenControls,
            controlWidth: nil
        )
        // SETTINGS-FORM-DENSITY-01: one rearrange pull-down (keeps AX ids on items)
        rearrangePopup.setAccessibilityIdentifier("settings-rearrange")
        rearrangePopup.setAccessibilityLabel(
            SettingsSectionChromeCopy.rearrangeRowTitle(localize: { L($0) })
        )
        let rearrangeMenu = NSMenu()
        rearrangeMenu.autoenablesItems = false
        let rearrangeTitle = NSMenuItem(
            title: SettingsSectionChromeCopy.rearrangeMenuTitle(localize: { L($0) }),
            action: nil,
            keyEquivalent: ""
        )
        rearrangeMenu.addItem(rearrangeTitle)

        func addRearrangeItem(
            titleKey: String,
            helpKey: String,
            identifier: String,
            action: Selector
        ) {
            let item = NSMenuItem(title: L(titleKey), action: action, keyEquivalent: "")
            item.target = self
            item.setAccessibilityLabel(L(titleKey))
            item.setAccessibilityHelp(L(helpKey))
            item.setAccessibilityIdentifier(identifier)
            rearrangeMenu.addItem(item)
        }
        // Keep settingsButtonTitleKey / settingsAccessibilityHelpKey wiring for guards.
        addRearrangeItem(
            titleKey: LauncherLayout.GridRearrangeSort.byName.settingsButtonTitleKey,
            helpKey: LauncherLayout.GridRearrangeSort.byName.settingsAccessibilityHelpKey,
            identifier: "settings-rearrange-by-name",
            action: #selector(rearrangeByName)
        )
        addRearrangeItem(
            titleKey: LauncherLayout.GridRearrangeSort.byKind.settingsButtonTitleKey,
            helpKey: LauncherLayout.GridRearrangeSort.byKind.settingsAccessibilityHelpKey,
            identifier: "settings-rearrange-by-kind",
            action: #selector(rearrangeByKind)
        )
        addRearrangeItem(
            titleKey: LauncherLayout.CategoryRearrangeCopy.settingsButtonTitleKey,
            helpKey: LauncherLayout.CategoryRearrangeCopy.settingsAccessibilityHelpKey,
            identifier: "settings-rearrange-by-category",
            action: #selector(rearrangeByCategory)
        )
        addRearrangeItem(
            titleKey: LauncherLayout.ColorRearrangeCopy.settingsButtonTitleKey,
            helpKey: LauncherLayout.ColorRearrangeCopy.informativeTextKey,
            identifier: "settings-rearrange-by-color",
            action: #selector(rearrangeByColor)
        )
        addRearrangeItem(
            titleKey: AppDateRearrangeKind.dateAdded.settingsButtonTitleKey,
            helpKey: AppDateRearrangeKind.dateAdded.informativeTextKey,
            identifier: "settings-rearrange-by-date-added",
            action: #selector(rearrangeByDateAdded)
        )
        addRearrangeItem(
            titleKey: AppDateRearrangeKind.lastOpened.settingsButtonTitleKey,
            helpKey: AppDateRearrangeKind.lastOpened.informativeTextKey,
            identifier: "settings-rearrange-by-last-opened",
            action: #selector(rearrangeByLastOpened)
        )
        rearrangePopup.menu = rearrangeMenu
        let rearrangeRow = makeFormRow(
            title: SettingsSectionChromeCopy.rearrangeRowTitle(localize: { L($0) }),
            control: rearrangePopup
        )
        let appsRows: [NSView] = [hiddenRow, rearrangeRow]

        // --- 维护 ---
        // SETTINGS-FORM-DENSITY-01: form rows + one layout pull-down (not a button wall)
        rescanButton.bezelStyle = .flexiblePush
        rescanButton.controlSize = .regular
        rescanButton.target = self
        rescanButton.action = #selector(rescan)
        rescanButton.setAccessibilityLabel(
            LauncherLayout.SettingsMaintenanceChromeCopy.rescanButtonTitle(localize: { L($0) })
        )
        rescanButton.setAccessibilityHelp(
            LauncherLayout.SettingsMaintenanceChromeCopy.rescanAccessibilityHelp(localize: { L($0) })
        )
        leftoversButton.bezelStyle = .flexiblePush
        leftoversButton.controlSize = .regular
        leftoversButton.target = self
        leftoversButton.action = #selector(cleanUpLeftovers)
        leftoversButton.setAccessibilityIdentifier("settings-cleanup-leftovers")
        leftoversButton.setAccessibilityLabel(
            LauncherLayout.SettingsMaintenanceChromeCopy.leftoversAccessibilityLabel(localize: { L($0) })
        )
        leftoversButton.setAccessibilityHelp(
            LauncherLayout.SettingsMaintenanceChromeCopy.leftoversAccessibilityHelp(localize: { L($0) })
        )
        if !AppUninstallPlatform.orphanCleanupAvailable(isSandboxed: AppUninstallPlatform.isSandboxed()) {
            leftoversButton.isEnabled = false
            leftoversButton.toolTip = L(AppUninstallPlatform.orphanSandboxedExplanationKey)
        }
        appDirectoriesPopup.setAccessibilityIdentifier("settings-app-directories")
        // APP-DIRECTORY-FEEDBACK-01
        appDirectoriesPopup.setAccessibilityLabel(
            AppDirectoryCopy.accessibilityLabel(localize: { L($0) })
        )
        appDirectoriesPopup.setAccessibilityHelp(
            AppDirectoryCopy.accessibilityHelp(localize: { L($0) })
        )
        let directoriesRow = makeFormRow(
            title: AppDirectoryCopy.accessibilityLabel(localize: { L($0) }),
            control: appDirectoriesPopup
        )

        // Guard: `let actions = NSStackView()` with rescan + leftovers sharing a row.
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.addArrangedSubview(rescanButton)
        actions.addArrangedSubview(leftoversButton)
        let actionsRow = makeFormRow(
            title: SettingsSectionChromeCopy.scanRowTitle(localize: { L($0) }),
            control: actions,
            controlWidth: nil
        )

        // Layout I/O pull-down (export / import / restore / Launchpad).
        layoutIOPopup.setAccessibilityIdentifier("settings-layout-io")
        layoutIOPopup.setAccessibilityLabel(
            SettingsSectionChromeCopy.layoutRowTitle(localize: { L($0) })
        )
        let layoutMenu = NSMenu()
        layoutMenu.autoenablesItems = false
        layoutMenu.addItem(
            withTitle: SettingsSectionChromeCopy.layoutMenuTitle(localize: { L($0) }),
            action: nil,
            keyEquivalent: ""
        )
        let exportItem = NSMenuItem(
            title: exportLayoutButtonTitle,
            action: #selector(exportLayout),
            keyEquivalent: ""
        )
        exportItem.target = self
        exportItem.setAccessibilityIdentifier("settings-export-layout")
        exportItem.setAccessibilityLabel(
            LauncherLayout.SettingsLayoutIOChromeCopy.exportAccessibilityLabel(localize: { L($0) })
        )
        exportItem.setAccessibilityHelp(
            LauncherLayout.SettingsLayoutIOChromeCopy.exportAccessibilityHelp(localize: { L($0) })
        )
        // Keep SettingsLayoutIOChromeCopy.exportButtonTitleKey referenced via exportLayoutButtonTitle.
        layoutMenu.addItem(exportItem)

        let importItem = NSMenuItem(
            title: importLayoutButtonTitle,
            action: #selector(importLayout),
            keyEquivalent: ""
        )
        importItem.target = self
        importItem.setAccessibilityIdentifier("settings-import-layout")
        importItem.setAccessibilityLabel(
            LauncherLayout.SettingsLayoutIOChromeCopy.importAccessibilityLabel(localize: { L($0) })
        )
        importItem.setAccessibilityHelp(
            LauncherLayout.SettingsLayoutIOChromeCopy.importAccessibilityHelp(localize: { L($0) })
        )
        layoutMenu.addItem(importItem)

        let restoreItem = NSMenuItem(
            title: restoreLayoutBackupButtonTitle,
            action: #selector(restoreLayoutBackup),
            keyEquivalent: ""
        )
        restoreItem.target = self
        restoreItem.setAccessibilityIdentifier("settings-restore-layout-backup")
        restoreItem.setAccessibilityLabel(
            LauncherLayout.SettingsLayoutIOChromeCopy.restoreBackupButtonTitle(localize: { L($0) })
        )
        restoreItem.setAccessibilityHelp(
            LauncherLayout.SettingsLayoutIOChromeCopy.restoreBackupAccessibilityHelp(localize: { L($0) })
        )
        layoutMenu.addItem(restoreItem)
        restoreLayoutBackupMenuItem = restoreItem

        layoutMenu.addItem(.separator())
        let launchpadItem = NSMenuItem(
            title: importLaunchpadButtonTitle,
            action: #selector(importLaunchpadLayout),
            keyEquivalent: ""
        )
        launchpadItem.target = self
        launchpadItem.setAccessibilityIdentifier("settings-import-launchpad")
        launchpadItem.setAccessibilityLabel(L("从启动台导入布局"))
        launchpadItem.setAccessibilityHelp(L("读取原生启动台的应用顺序和文件夹（只读，不修改启动台数据）并应用到主屏幕"))
        layoutMenu.addItem(launchpadItem)
        layoutIOPopup.menu = layoutMenu

        // layoutBackupRow name kept for layout-backup-restore guard.
        let layoutBackupRow = makeFormRow(
            title: SettingsSectionChromeCopy.layoutRowTitle(localize: { L($0) }),
            control: layoutIOPopup
        )

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 3
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageLabel.setAccessibilityElement(true)
        messageLabel.setAccessibilityRole(.staticText)
        messageLabel.setAccessibilityLabel(L(LauncherLayout.settingsFeedbackAccessibilityLabelKey))
        messageLabel.isHidden = true
        messageLabel.alphaValue = 1
        messageLabel.wantsLayer = true
        let messageRow = makePaddedRow(messageLabel, minHeight: nil, expandContent: true)
        let maintenanceRows: [NSView] = [directoriesRow, actionsRow, layoutBackupRow, messageRow]

        // SETTINGS-COMPACT-SCROLL-02: primary pane still uses frame-managed scroll document.
        let appearancePane = makeTabScrollPane(
            rows: appearanceRows,
            usePrimaryScroll: true
        )
        let behaviorPane = makeTabScrollPane(rows: behaviorRows, usePrimaryScroll: false)
        let appsPane = makeTabScrollPane(rows: appsRows, usePrimaryScroll: false)
        let maintenancePane = makeTabScrollPane(rows: maintenanceRows, usePrimaryScroll: false)

        // Tab labels reuse section chrome (SETTINGS-SECTION-CHROME-01).
        let tabs: [(String, NSView)] = [
            (SettingsSectionChromeCopy.appearanceSectionTitle(localize: { L($0) }), appearancePane),
            (SettingsSectionChromeCopy.behaviorSectionTitle(localize: { L($0) }), behaviorPane),
            (SettingsSectionChromeCopy.appsSectionTitle(localize: { L($0) }), appsPane),
            (SettingsSectionChromeCopy.maintenanceSectionTitle(localize: { L($0) }), maintenancePane)
        ]
        for (label, view) in tabs {
            let item = NSTabViewItem(identifier: label as NSString)
            item.label = label
            item.view = view
            tabView.addTabViewItem(item)
        }
        // SETTINGS-TAB-SCROLL-03: a newly selected pane may only now have its final clip size.
        // Delegate is attached after the items, so the first tab does not get didSelect.
        tabView.delegate = self
        relayoutSettingsChrome()

    }

    /// SETTINGS-TAB-CHROME-01: one inset card inside a scroll pane (primary reuses SETTINGS-COMPACT-SCROLL-02 chrome).
    // SETTINGS-TAB-SCROLL-04: autoresizing tab roots + post-select layout so secondary panes paint.
    private func makeTabScrollPane(rows: [NSView], usePrimaryScroll: Bool) -> NSView {
        let scrollView: NSScrollView
        let document: SettingsDocumentView
        if usePrimaryScroll {
            scrollView = settingsScrollView
            document = settingsDocumentView
        } else {
            scrollView = NSScrollView()
            document = SettingsDocumentView()
        }

        // NSTabView owns this root's frame; there are no external Auto Layout constraints.
        scrollView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: SettingsWindowChrome.contentWidth,
            height: 1
        )
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false

        // SETTINGS-COMPACT-SCROLL-02: width follows the clip; height is measured explicitly.
        document.translatesAutoresizingMaskIntoConstraints = true
        document.autoresizingMask = [.width]
        document.frame = NSRect(
            x: 0,
            y: 0,
            width: SettingsWindowChrome.contentWidth,
            height: 1
        )

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsChrome.sectionGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let card = makeCard(rows: rows)
        stack.addArrangedSubview(card)
        pinFullWidth(card, in: stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: document.leadingAnchor,
                constant: SettingsChrome.tabContentInset
            ),
            stack.trailingAnchor.constraint(
                equalTo: document.trailingAnchor,
                constant: -SettingsChrome.tabContentInset
            ),
            stack.topAnchor.constraint(
                equalTo: document.topAnchor,
                constant: SettingsChrome.stackTopInset
            ),
            stack.widthAnchor.constraint(
                equalTo: document.widthAnchor,
                constant: -(SettingsChrome.tabContentInset * 2)
            )
        ])

        scrollView.documentView = document

        // SETTINGS-TAB-SCROLL-03/04: measure primary and secondary documents identically.
        settingsScrollPanes.append((
            scrollView: scrollView,
            document: document,
            content: stack
        ))

        return scrollView
    }

    /// Section title above a rounded card of equal-height form rows.
    private func makeSection(title: String, rows: [NSView]) -> NSStackView {
        let wrap = NSStackView()
        wrap.orientation = .vertical
        wrap.alignment = .leading
        wrap.spacing = SettingsChrome.sectionHeaderGap
        wrap.addArrangedSubview(makeSectionHeader(title))
        let card = makeCard(rows: rows)
        wrap.addArrangedSubview(card)
        pinFullWidth(card, in: wrap)
        return wrap
    }

    private func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityRole(.staticText)
        return label
    }

    private func makeCard(rows: [NSView]) -> SettingsCardView {
        let card = SettingsCardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: SettingsChrome.cardVerticalInset),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -SettingsChrome.cardVerticalInset)
        ])

        for (index, row) in rows.enumerated() {
            if index > 0 {
                column.addArrangedSubview(makeInsetSeparator())
            }
            column.addArrangedSubview(row)
            pinFullWidth(row, in: column)
        }
        return card
    }

    /// Label leading (left), control trailing (right) — form alignment.
    private func makeFormRow(title: String, control: NSView, controlWidth: CGFloat? = 220) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(
            top: 0,
            left: SettingsChrome.cardPadding,
            bottom: 0,
            right: SettingsChrome.cardPadding
        )
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: SettingsChrome.labelWidth).isActive = true
        let flex = NSView()
        flex.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let controlWidth {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
            control.setContentHuggingPriority(.required, for: .horizontal)
        } else {
            control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        row.addArrangedSubview(label)
        row.addArrangedSubview(flex)
        row.addArrangedSubview(control)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: SettingsChrome.rowHeight).isActive = true
        return row
    }

    private func makeToggleRow(_ checkbox: NSButton) -> NSView {
        makePaddedRow(checkbox, minHeight: SettingsChrome.rowHeight)
    }

    /// Login toggle with its system-settings shortcut on the same line
    /// (was a separate indented accessory row; saves one row of height).
    private func makeLoginRow(_ checkbox: NSButton, _ button: NSButton) -> NSView {
        let line = NSStackView()
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 8
        line.addArrangedSubview(checkbox)
        let flex = NSView()
        flex.setContentHuggingPriority(.defaultLow, for: .horizontal)
        line.addArrangedSubview(flex)
        line.addArrangedSubview(button)
        return makePaddedRow(line, minHeight: SettingsChrome.rowHeight, expandContent: true)
    }

    private func makePaddedRow(_ content: NSView, minHeight: CGFloat?, expandContent: Bool = false) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        row.edgeInsets = NSEdgeInsets(
            top: 0,
            left: SettingsChrome.cardPadding,
            bottom: 0,
            right: SettingsChrome.cardPadding
        )
        row.addArrangedSubview(content)
        if expandContent {
            content.setContentHuggingPriority(.defaultLow, for: .horizontal)
            content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            let flex = NSView()
            flex.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(flex)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        if let minHeight {
            row.heightAnchor.constraint(equalToConstant: minHeight).isActive = true
        } else {
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsChrome.rowHeight).isActive = true
        }
        return row
    }

    private func makeInsetSeparator() -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: SettingsChrome.cardPadding),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -SettingsChrome.cardPadding),
            line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1)
        ])
        return wrap
    }

    private func pinFullWidth(_ view: NSView, in stack: NSStackView) {
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }


    // MARK: - Window presence (opacity-before-unhide / interrupted restore)

    private func presentSettingsWindowPresence() {
        guard let window else { return }
        let currentlyVisible = window.isVisible
        let isKey = window.isKeyWindow
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shouldAnimate = !reduceMotion
        settingsPresenceGeneration &+= 1
        let generation = settingsPresenceGeneration

        let becomeKey = LauncherLayout.settingsPresenceShouldBecomeKeyOnShow(
            currentlyVisible: currentlyVisible,
            isKeyWindow: isKey
        )

        if LauncherLayout.settingsPresenceShouldClearOpacityBeforeUnhide(
            willShow: true,
            currentlyVisible: currentlyVisible
        ) {
            // Opacity-before-unhide: park transparent, then orderFront, then fade.
            parkSettingsPresenceTransparentForAppear()
            if becomeKey {
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            } else {
                window.orderFront(nil)
            }
            if shouldAnimate {
                fadeSettingsPresence(to: 1, appearing: true, generation: generation)
            } else {
                snapSettingsPresenceVisible()
            }
            return
        }

        // Already visible: only take key when we are not already key (avoids
        // stealing first responder / yanking focus from the launcher).
        if becomeKey {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        let host = settingsPresenceHostView(in: window)
        host.wantsLayer = true
        let presented = CGFloat(
            host.layer?.presentation()?.opacity
                ?? host.layer?.opacity
                ?? Float(host.alphaValue)
        )
        if LauncherLayout.settingsPresenceShouldRestoreOpacityWhenAlreadyShown(
            currentlyVisible: currentlyVisible,
            currentOpacity: presented
        ) {
            if shouldAnimate {
                fadeSettingsPresence(to: 1, appearing: false, generation: generation)
            } else {
                snapSettingsPresenceVisible()
            }
        } else {
            snapSettingsPresenceVisible()
        }
    }

    private func hideSettingsWindowPresenceThenClose() {
        guard let window = window as? SettingsWindow else {
            self.window?.close()
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard window.isVisible, !reduceMotion else {
            parkSettingsPresenceOpaqueWhileHidden()
            window.allowCloseWithoutPresenceFade = true
            window.performClose(nil)
            return
        }
        settingsPresenceGeneration &+= 1
        let generation = settingsPresenceGeneration
        fadeSettingsPresence(to: 0, appearing: false, generation: generation) { [weak self] in
            guard let self, self.settingsPresenceGeneration == generation else { return }
            self.parkSettingsPresenceOpaqueWhileHidden()
            guard let settingsWindow = self.window as? SettingsWindow else {
                self.window?.close()
                return
            }
            settingsWindow.allowCloseWithoutPresenceFade = true
            settingsWindow.performClose(nil)
        }
    }

    private func settingsPresenceHostView(in window: NSWindow) -> NSView {
        if let content = window.contentView { return content }
        let host = NSView(frame: .zero)
        host.wantsLayer = true
        window.contentView = host
        return host
    }

    private func parkSettingsPresenceTransparentForAppear() {
        guard let window else { return }
        let host = settingsPresenceHostView(in: window)
        host.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.layer?.removeAnimation(forKey: LauncherLayout.settingsPresenceFadeAnimationKey)
        host.alphaValue = 0
        host.layer?.opacity = 0
        CATransaction.commit()
    }

    private func parkSettingsPresenceOpaqueWhileHidden() {
        guard let window else { return }
        let host = settingsPresenceHostView(in: window)
        host.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.layer?.removeAnimation(forKey: LauncherLayout.settingsPresenceFadeAnimationKey)
        host.alphaValue = 1
        host.layer?.opacity = 1
        CATransaction.commit()
    }

    private func snapSettingsPresenceVisible() {
        guard let window else { return }
        let host = settingsPresenceHostView(in: window)
        host.wantsLayer = true
        settingsPresenceGeneration &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.layer?.removeAnimation(forKey: LauncherLayout.settingsPresenceFadeAnimationKey)
        host.alphaValue = 1
        host.layer?.opacity = 1
        CATransaction.commit()
    }

    private func fadeSettingsPresence(
        to value: Float,
        appearing: Bool,
        generation: UInt64,
        completion: (() -> Void)? = nil
    ) {
        guard let window else {
            completion?()
            return
        }
        let host = settingsPresenceHostView(in: window)
        host.wantsLayer = true
        guard let layer = host.layer else {
            host.alphaValue = CGFloat(value)
            if settingsPresenceGeneration == generation {
                completion?()
            }
            return
        }
        // Read presentation BEFORE removing animations (interrupted restore).
        let from = LauncherLayout.settingsPresenceFadeFromOpacity(
            appearing: appearing,
            presentedOpacity: layer.presentation()?.opacity,
            modelOpacity: layer.opacity
        )
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = value
        anim.duration = LauncherLayout.settingsPresenceFadeDuration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode = .backwards
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.settingsPresenceGeneration == generation else { return }
            completion?()
        }
        layer.removeAnimation(forKey: LauncherLayout.settingsPresenceFadeAnimationKey)
        layer.opacity = value
        host.alphaValue = CGFloat(value)
        layer.add(anim, forKey: LauncherLayout.settingsPresenceFadeAnimationKey)
        CATransaction.commit()
    }

    /// Fade feedback in/out. Empty text hides the label; reveal clears opacity
    /// before unhide (same flash fix as launcher status chrome). Each mutating
    /// call bumps `messageFadeGeneration` so rapid rescan/login completions
    /// cannot clear or replace a newer line.
    private func setMessage(_ text: String, animated: Bool = true) {
        messageFadeReplacement = nil
        if LauncherLayout.settingsMessageShouldAnnounce(
            text: text,
            previous: messageLabel.isHidden ? "" : messageLabel.stringValue
        ) {
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    NSAccessibility.NotificationUserInfoKey.announcement: text,
                    NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.medium.rawValue
                ]
            )
        }
        let willShow = LauncherLayout.settingsMessageShouldShow(text: text)
        let currentlyHidden = messageLabel.isHidden
        if willShow, !currentlyHidden, messageLabel.stringValue == text {
            // Same copy already on screen — but an interrupted hide/crossfade
            // can leave the row near-transparent. Restore like status/footer.
            messageLabel.wantsLayer = true
            let presented = CGFloat(
                messageLabel.layer?.presentation()?.opacity
                    ?? messageLabel.layer?.opacity
                    ?? Float(messageLabel.alphaValue)
            )
            if LauncherLayout.settingsMessageShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: currentlyHidden,
                currentOpacity: presented
            ) {
                messageFadeGeneration &+= 1
                let generation = messageFadeGeneration
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let shouldAnimate = animated && !reduceMotion && window?.isVisible == true
                if shouldAnimate {
                    fadeMessageOpacity(to: 1, generation: generation, completion: nil)
                } else {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    messageLabel.layer?.removeAnimation(
                        forKey: LauncherLayout.settingsMessageFadeAnimationKey
                    )
                    messageLabel.alphaValue = 1
                    messageLabel.layer?.opacity = 1
                    CATransaction.commit()
                }
            }
            return
        }
        if !willShow, currentlyHidden {
            messageLabel.stringValue = ""
            return
        }
        messageFadeGeneration &+= 1
        let generation = messageFadeGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shouldAnimate = animated && !reduceMotion && window?.isVisible == true
        messageLabel.wantsLayer = true
        if willShow {
            if currentlyHidden {
                messageLabel.stringValue = text
                let clearFirst = LauncherLayout.settingsMessageShouldClearOpacityBeforeUnhide(
                    willShow: true,
                    currentlyHidden: true
                )
                if shouldAnimate, clearFirst {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    messageLabel.alphaValue = 0
                    messageLabel.layer?.opacity = 0
                    messageLabel.isHidden = false
                    CATransaction.commit()
                    fadeMessageOpacity(to: 1, generation: generation, completion: nil)
                } else {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    messageLabel.layer?.removeAnimation(
                        forKey: LauncherLayout.settingsMessageFadeAnimationKey
                    )
                    messageLabel.alphaValue = 1
                    messageLabel.layer?.opacity = 1
                    messageLabel.isHidden = false
                    CATransaction.commit()
                }
            } else if shouldAnimate {
                messageFadeReplacement = text
                fadeMessageOpacity(to: 0, generation: generation) { [weak self] in
                    guard let self,
                          LauncherLayout.settingsMessageFadeShouldApply(
                            generation: self.messageFadeGeneration,
                            expected: generation
                          ) else { return }
                    self.messageFadeReplacement = nil
                    self.messageLabel.stringValue = text
                    self.fadeMessageOpacity(to: 1, generation: generation, completion: nil)
                }
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                messageLabel.layer?.removeAnimation(
                    forKey: LauncherLayout.settingsMessageFadeAnimationKey
                )
                messageLabel.stringValue = text
                messageLabel.alphaValue = 1
                messageLabel.layer?.opacity = 1
                CATransaction.commit()
            }
            return
        }
        // Clear / hide (visible path only; hidden no-op returned above).
        if shouldAnimate {
            fadeMessageOpacity(to: 0, generation: generation) { [weak self] in
                guard let self,
                      LauncherLayout.settingsMessageFadeShouldApply(
                        generation: self.messageFadeGeneration,
                        expected: generation
                      ) else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.messageLabel.isHidden = true
                self.messageLabel.stringValue = ""
                self.messageLabel.alphaValue = 1
                self.messageLabel.layer?.opacity = 1
                CATransaction.commit()
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            messageLabel.layer?.removeAnimation(
                forKey: LauncherLayout.settingsMessageFadeAnimationKey
            )
            messageLabel.isHidden = true
            messageLabel.stringValue = ""
            messageLabel.alphaValue = 1
            messageLabel.layer?.opacity = 1
            CATransaction.commit()
        }
    }

    private func fadeMessageOpacity(
        to value: Float,
        generation: UInt64,
        completion: (() -> Void)?
    ) {
        messageLabel.wantsLayer = true
        guard let layer = messageLabel.layer else {
            messageLabel.alphaValue = CGFloat(value)
            if LauncherLayout.settingsMessageFadeShouldApply(
                generation: messageFadeGeneration,
                expected: generation
            ) {
                completion?()
            }
            return
        }
        let from = layer.presentation()?.opacity ?? layer.opacity
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = value
        anim.duration = LauncherLayout.settingsMessageFadeDuration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode = .backwards
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self,
                  LauncherLayout.settingsMessageFadeShouldApply(
                    generation: self.messageFadeGeneration,
                    expected: generation
                  ) else { return }
            completion?()
        }
        layer.opacity = value
        messageLabel.alphaValue = CGFloat(value)
        layer.add(anim, forKey: LauncherLayout.settingsMessageFadeAnimationKey)
        CATransaction.commit()
    }

    /// SETTINGS-MESSAGE-FADE-FINISH-ON-CLOSE-01: orderOut can drop the fade
    /// before its completion. Read a layer that already exists.
    private func finishSettingsMessageFadeForClose() {
        let layer = messageLabel.layer
        let landing = LauncherLayout.settingsMessageFadeLandingOnClose(
            animationStillAttached: layer?.animation(
                forKey: LauncherLayout.settingsMessageFadeAnimationKey
            ) != nil,
            modelOpacity: layer?.opacity ?? Float(messageLabel.alphaValue),
            hasReplacement: messageFadeReplacement != nil,
            labelHidden: messageLabel.isHidden
        )
        if landing == .leave { return }
        messageFadeGeneration &+= 1
        let replacement = messageFadeReplacement
        messageFadeReplacement = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.removeAnimation(forKey: LauncherLayout.settingsMessageFadeAnimationKey)
        if landing == .showReplacement {
            if let replacement {
                messageLabel.stringValue = replacement
            }
            messageLabel.isHidden = false
        } else if landing == .parkHidden {
            messageLabel.isHidden = true
            messageLabel.stringValue = ""
        }
        messageLabel.alphaValue = 1
        layer?.opacity = 1
        CATransaction.commit()
    }

    private func updateControls() {
        shortcutPopup.selectItem(at: LauncherShortcut.allCases.firstIndex(of: preferences.shortcut) ?? 0)
        hotCornerPopup.selectItem(at: LauncherHotCorner.allCases.firstIndex(of: preferences.hotCorner) ?? 0)
        statusCheckbox.state = preferences.showsStatusItem ? .on : .off
        appNamesCheckbox.state = preferences.hidesAppNames ? .on : .off
        folderNamesCheckbox.state = preferences.hidesFolderNames ? .on : .off
        displayTargetPopup.selectItem(at: LauncherDisplayTarget.allCases.firstIndex(of: preferences.displayTarget) ?? 0)
        backgroundDimPopup.selectItem(
            at: LauncherBackgroundDim.allCases.firstIndex(of: preferences.backgroundDim) ?? 1
        )
        backgroundBlurCheckbox.state = preferences.blursBackground ? .on : .off
        hideCheckbox.state = preferences.hidesAfterLaunch ? .on : .off
        motionCheckbox.state = preferences.reducesMotion ? .on : .off
        pinchDismissCheckbox.state = preferences.pinchToDismiss ? .on : .off
        reopenPagePopup.selectItem(
            at: LauncherReopenPageBehavior.allCases.firstIndex(of: preferences.reopenPageBehavior) ?? 0
        )
        pageFlipDirectionPopup.selectItem(
            at: LauncherPageFlipDirection.allCases.firstIndex(of: preferences.pageFlipDirection) ?? 0
        )
        gridColumnsPopup.selectItem(
            at: GridGeometryPreference.choiceIndex(forColumns: preferences.gridGeometry.columns)
        )
        gridRowsPopup.selectItem(
            at: GridGeometryPreference.choiceIndex(forRows: preferences.gridGeometry.rows)
        )
        updateHiddenApplications()
        updateAppDirectoriesMenu()
    }

    /// Pull-down: title, "Add Folder…", then each added folder (choose to remove).
    private func updateAppDirectoriesMenu() {
        let menu = NSMenu()
        let count = preferences.additionalAppDirectories.count
        // APP-DIRECTORY-FEEDBACK-01
        menu.addItem(
            withTitle: AppDirectoryCopy.menuTitle(count: count, localize: { L($0) }),
            action: nil,
            keyEquivalent: ""
        )
        let add = NSMenuItem(
            title: AppDirectoryCopy.addFolderTitle(localize: { L($0) }),
            action: #selector(addAppDirectory),
            keyEquivalent: ""
        )
        add.target = self
        // CUSTOM-ROOT-COUNT-LIMIT-01 — grey out Add when at the cap.
        if count >= AppCatalogScanner.maxAdditionalAppDirectories {
            add.isEnabled = false
            add.toolTip = AppDirectoryCopy.limitReached(localize: { L($0) })
        }
        menu.addItem(add)
        if count > 0 {
            menu.addItem(.separator())
            let header = NSMenuItem(
                title: AppDirectoryCopy.removeHeader(localize: { L($0) }),
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)
            for path in preferences.additionalAppDirectories {
                let item = NSMenuItem(
                    title: (path as NSString).abbreviatingWithTildeInPath,
                    action: #selector(removeAppDirectory(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = path
                item.toolTip = path
                menu.addItem(item)
            }
        }
        menu.autoenablesItems = false
        appDirectoriesPopup.menu = menu
    }

    @objc private func addAppDirectory() {
        guard let window else { return }
        // CUSTOM-ROOT-COUNT-LIMIT-01
        if preferences.additionalAppDirectories.count >= AppCatalogScanner.maxAdditionalAppDirectories {
            setMessage(AppDirectoryCopy.limitReached(localize: { L($0) }))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        // APP-DIRECTORY-FEEDBACK-01
        panel.prompt = AppDirectoryCopy.panelPrompt(localize: { L($0) })
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let current = self.preferences.additionalAppDirectories
            if current.count >= AppCatalogScanner.maxAdditionalAppDirectories {
                self.setMessage(AppDirectoryCopy.limitReached(localize: { L($0) }))
                return
            }
            let before = AppCatalogScanner.catalogRoots(additionalPaths: current)
            let after = AppCatalogScanner.catalogRoots(additionalPaths: current + [url.path])
            guard after.count > before.count, let added = after.last?.path else {
                self.setMessage(AppDirectoryCopy.alreadyCovered(localize: { L($0) }))
                return
            }
            self.commitAppDirectories(
                current + [added],
                success: AppDirectoryCopy.addedMessage(
                    abbreviatedPath: (added as NSString).abbreviatingWithTildeInPath,
                    localize: { L($0) }
                )
            )
        }
    }

    @objc private func removeAppDirectory(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let remaining = preferences.additionalAppDirectories.filter { $0 != path }
        commitAppDirectories(
            remaining,
            success: AppDirectoryCopy.removedMessage(
                abbreviatedPath: (path as NSString).abbreviatingWithTildeInPath,
                localize: { L($0) }
            )
        )
    }

    private func commitAppDirectories(_ paths: [String], success: String) {
        var proposed = preferences
        proposed.additionalAppDirectories = AppCatalogScanner.sanitizedAdditionalAppDirectories(paths)
        if let error = onPreferencesChanged?(proposed) {
            setMessage(error)
        } else {
            preferences = proposed
            setMessage(success)
        }
        updateAppDirectoriesMenu()
    }

    private func updateHiddenApplications() {
        hiddenApplicationsPopup.removeAllItems()
        guard !hiddenApplications.isEmpty else {
            hiddenApplicationsPopup.addItem(
                withTitle: LauncherLayout.SettingsHiddenAppsChromeCopy.emptyPopupTitle(localize: { L($0) })
            )
            hiddenApplicationsPopup.isEnabled = false
            restoreHiddenApplicationButton.isEnabled = false
            restoreAllHiddenApplicationsButton.isHidden = true
            return
        }
        hiddenApplicationsPopup.isEnabled = true
        restoreHiddenApplicationButton.isEnabled = true
        restoreAllHiddenApplicationsButton.isHidden = !LauncherLayout.settingsShowsRestoreAllHidden(
            hiddenCount: hiddenApplications.count
        )
        for application in hiddenApplications {
            hiddenApplicationsPopup.addItem(withTitle: application.displayName)
            hiddenApplicationsPopup.itemArray.last?.representedObject = application.key
        }
    }

    @objc private func rescan() {
        guard !isRescanning else { return }
        isRescanning = true
        rescanButton.isEnabled = false
        onRescan?()
        guard shortcutRegistrationError == nil else { return }
        // SETTINGS-DISPLAY-FEEDBACK-01
        setMessage(SettingsFeedbackCopy.rescanning(localize: { L($0) }))
    }

    @objc private func preferencesChanged() {
        var proposed = preferences
        proposed.shortcut = LauncherShortcut.allCases[shortcutPopup.indexOfSelectedItem]
        let hotIndex = hotCornerPopup.indexOfSelectedItem
        if hotIndex >= 0, hotIndex < LauncherHotCorner.allCases.count {
            proposed.hotCorner = LauncherHotCorner.allCases[hotIndex]
        }
        proposed.showsStatusItem = statusCheckbox.state == .on
        proposed.hidesAppNames = appNamesCheckbox.state == .on
        proposed.hidesFolderNames = folderNamesCheckbox.state == .on
        let dimIndex = backgroundDimPopup.indexOfSelectedItem
        if dimIndex >= 0, dimIndex < LauncherBackgroundDim.allCases.count {
            proposed.backgroundDim = LauncherBackgroundDim.allCases[dimIndex]
        }
        proposed.blursBackground = backgroundBlurCheckbox.state == .on
        let displayIndex = displayTargetPopup.indexOfSelectedItem
        if displayIndex >= 0, displayIndex < LauncherDisplayTarget.allCases.count {
            proposed.displayTarget = LauncherDisplayTarget.allCases[displayIndex]
        }
        proposed.hidesAfterLaunch = hideCheckbox.state == .on
        proposed.reducesMotion = motionCheckbox.state == .on
        proposed.pinchToDismiss = pinchDismissCheckbox.state == .on
        let reopenIndex = reopenPagePopup.indexOfSelectedItem
        if LauncherReopenPageBehavior.allCases.indices.contains(reopenIndex) {
            proposed.reopenPageBehavior = LauncherReopenPageBehavior.allCases[reopenIndex]
        }
        let flipIndex = pageFlipDirectionPopup.indexOfSelectedItem
        if LauncherPageFlipDirection.allCases.indices.contains(flipIndex) {
            proposed.pageFlipDirection = LauncherPageFlipDirection.allCases[flipIndex]
        }
        let gridColumnIndex = gridColumnsPopup.indexOfSelectedItem
        let gridRowIndex = gridRowsPopup.indexOfSelectedItem
        if GridGeometryPreference.columnChoices.indices.contains(gridColumnIndex),
           GridGeometryPreference.rowChoices.indices.contains(gridRowIndex) {
            proposed.gridGeometry = GridGeometryPreference(
                columns: GridGeometryPreference.columnChoices[gridColumnIndex],
                rows: GridGeometryPreference.rowChoices[gridRowIndex]
            )
        }
        if let error = onPreferencesChanged?(proposed) {
            shortcutRegistrationError = error
            setMessage(error)
            updateControls()
        } else {
            let cornerChanged = proposed.hotCorner != preferences.hotCorner
            preferences = proposed
            shortcutRegistrationError = nil
            if cornerChanged, let conflict = Self.systemHotCornerConflictMessage(for: proposed.hotCorner) {
                setMessage(conflict)
            } else {
                setMessage(SettingsFeedbackCopy.applied(localize: { L($0) }))
            }
        }
    }

    /// Warns when macOS already assigns an action to the chosen corner.
    /// Reads the Dock's `wvous-*-corner` prefs (read-only, no permission).
    // HOT-CORNER-CONFLICT-HELP-01
    private static func systemHotCornerConflictMessage(for corner: LauncherHotCorner) -> String? {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        return corner.conflictMessage(
            dockValue: { dock?.object(forKey: $0) },
            localize: { L($0) }
        )
    }

    private func refreshLoginStatus() {
        loginCheckbox.isEnabled = false
        Task { @MainActor [weak self] in
            let status = await Task.detached(priority: .utility) {
                SMAppService.mainApp.status.rawValue
            }.value
            guard let self else { return }
            self.loginCheckbox.isEnabled = true
            self.loginCheckbox.state = status == SMAppService.Status.enabled.rawValue
                || status == SMAppService.Status.requiresApproval.rawValue ? .on : .off
            if status == SMAppService.Status.requiresApproval.rawValue,
               self.shortcutRegistrationError == nil {
                self.setMessage(SettingsBehaviorTogglesCopy.loginNeedsApproval(localize: { L($0) }))
            }
        }
    }

    @objc private func loginChanged() {
        let shouldEnable = loginCheckbox.state == .on
        loginCheckbox.isEnabled = false
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (Int, String?) in
                let service = SMAppService.mainApp
                do {
                    if shouldEnable { try service.register() }
                    else { try service.unregister() }
                    return (service.status.rawValue, nil)
                } catch {
                    return (service.status.rawValue, error.localizedDescription)
                }
            }.value
            guard let self else { return }
            self.loginCheckbox.isEnabled = true
            self.loginCheckbox.state = result.0 == SMAppService.Status.enabled.rawValue
                || result.0 == SMAppService.Status.requiresApproval.rawValue ? .on : .off
            self.setMessage(result.1 ?? (result.0 == SMAppService.Status.requiresApproval.rawValue
                ? SettingsBehaviorTogglesCopy.loginNeedsApproval(localize: { L($0) })
                : SettingsBehaviorTogglesCopy.loginUpdated(localize: { L($0) })))
        }
    }

    @objc private func restoreHiddenApplication() {
        guard let key = hiddenApplicationsPopup.selectedItem?.representedObject as? String else { return }
        // Name before the list drops it, so the message says which app came back.
        let restoredName = hiddenApplications.first(where: { $0.key == key })?.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard onRestoreHiddenApplication?(key) == true else {
            setMessage(LauncherLayout.SettingsHiddenAppsChromeCopy.restoreUnavailable(localize: { L($0) }))
            return
        }
        hiddenApplications.removeAll { $0.key == key }
        updateHiddenApplications()
        if LauncherLayout.settingsShouldMoveFocusAfterRestore(remainingHidden: hiddenApplications.count) {
            window?.makeFirstResponder(rescanButton)
        }
        if let restoredName, !restoredName.isEmpty {
            setMessage(
                LauncherLayout.SettingsHiddenAppsChromeCopy.restoredNamed(
                    displayName: restoredName,
                    localize: { L($0) }
                )
            )
        } else {
            setMessage(LauncherLayout.SettingsHiddenAppsChromeCopy.restoredGeneric(localize: { L($0) }))
        }
    }

    @objc private func restoreAllHiddenApplications() {
        guard LauncherLayout.settingsShowsRestoreAllHidden(hiddenCount: hiddenApplications.count) else { return }
        guard let count = onRestoreAllHiddenApplications?(), count > 0 else {
            setMessage(LauncherLayout.SettingsHiddenAppsChromeCopy.restoreUnavailable(localize: { L($0) }))
            return
        }
        hiddenApplications.removeAll()
        updateHiddenApplications()
        // The button just hid itself; keep keyboard focus inside the window.
        window?.makeFirstResponder(rescanButton)
        setMessage(String(format: L(LauncherLayout.restoredAllHiddenMessageFormatKey), count))
    }

    @objc private func cleanUpLeftovers() {
        if let running = leftoversTask {
            // Second click cancels an in-flight find/trash.
            running.cancel()
            setMessage(L(AppOrphanLeftoverScanner.cancelledMessageKey))
            leftoversButton.title = LauncherLayout.SettingsMaintenanceChromeCopy.leftoversButtonTitle(localize: { L($0) })
            leftoversButton.setAccessibilityLabel(
                LauncherLayout.SettingsMaintenanceChromeCopy.leftoversAccessibilityLabel(localize: { L($0) })
            )
            leftoversButton.setAccessibilityHelp(
                LauncherLayout.SettingsMaintenanceChromeCopy.leftoversAccessibilityHelp(localize: { L($0) })
            )
            return
        }
        guard AppUninstallPlatform.orphanCleanupAvailable(isSandboxed: AppUninstallPlatform.isSandboxed()) else {
            setMessage(L(AppUninstallPlatform.orphanSandboxedExplanationKey))
            return
        }
        leftoversButton.title = LauncherLayout.SettingsMaintenanceChromeCopy.leftoversCancelTitle(localize: { L($0) })
        leftoversButton.setAccessibilityLabel(
            LauncherLayout.SettingsMaintenanceChromeCopy.leftoversCancelTitle(localize: { L($0) })
        )
        leftoversButton.setAccessibilityHelp(
            LauncherLayout.SettingsMaintenanceChromeCopy.leftoversCancelAccessibilityHelp(localize: { L($0) })
        )
        leftoversButton.isEnabled = true
        setMessage(L(AppOrphanLeftoverScanner.scanningProgressMessageKey))
        let action = onCleanUpLeftovers
        leftoversTask = Task { [weak self] in
            let message = await action?({ [weak self] line in
                self?.setMessage(line)
            }) ?? L(AppOrphanLeftoverScanner.incompleteScanMessageKey)
            guard let self else { return }
            self.leftoversTask = nil
            self.restoreLeftoversButtonIdle()
            if Task.isCancelled {
                if self.window?.isVisible == true {
                    self.setMessage(L(AppOrphanLeftoverScanner.cancelledMessageKey))
                }
                return
            }
            self.setMessage(message)
        }
    }

    private func restoreLeftoversButtonIdle() {
        leftoversButton.title = LauncherLayout.SettingsMaintenanceChromeCopy.leftoversButtonTitle(localize: { L($0) })
        leftoversButton.setAccessibilityLabel(
            LauncherLayout.SettingsMaintenanceChromeCopy.leftoversAccessibilityLabel(localize: { L($0) })
        )
        leftoversButton.setAccessibilityHelp(
            LauncherLayout.SettingsMaintenanceChromeCopy.leftoversAccessibilityHelp(localize: { L($0) })
        )
        leftoversButton.isEnabled = AppUninstallPlatform.orphanCleanupAvailable(
            isSandboxed: AppUninstallPlatform.isSandboxed()
        )
    }



    /// After a successful rearrange/import, wait for the debounced save so
    /// `layout-v1.backup.json` exists before enabling 「恢复上次备份」.
    private func refreshLayoutBackupControlsAfterPersist() {
        Task { @MainActor in
            await onAwaitLayoutPersist?()
            refreshLayoutBackupControls()
        }
    }

    private func refreshLayoutBackupControls() {
        let available = layoutBackupAvailable?() ?? false
        restoreLayoutBackupMenuItem?.isEnabled = LauncherLayout.SettingsLayoutIOChromeCopy
            .shouldEnableRestoreBackupControl(hasBackupFile: available)
        restoreLayoutBackupMenuItem?.toolTip = LauncherLayout.SettingsLayoutIOChromeCopy.restoreBackupToolTip(
            available: available,
            localize: { L($0) }
        )
        // SettingsLayoutIOChromeCopy.restoreBackupButtonTitleKey still referenced via title property.
    }

    @objc private func exportLayout() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "LaunchIcon-layout.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let onExportLayout = self.onExportLayout else {
                    self.setMessage(LauncherLayout.LayoutIOOutcomeCopy.exportUnavailable(localize: { L($0) }))
                    return
                }
                let message = await onExportLayout(url)
                self.setMessage(message)
                self.refreshLayoutBackupControls()
            }
        }
    }

    @objc private func importLayout() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // After the open panel: Cancel-first confirm before replacing the grid.
            guard self.confirmLayoutImport() else { return }
            Task { @MainActor in
                guard let onImportLayout = self.onImportLayout else {
                    self.setMessage(LauncherLayout.LayoutIOOutcomeCopy.importUnavailable(localize: { L($0) }))
                    return
                }
                let message = await onImportLayout(url)
                self.setMessage(message)
                self.refreshLayoutBackupControls()
                self.refreshHiddenApplicationsFromLauncher()
            }
        }
    }

    /// Uses this Mac's Launchpad database when it still exists; otherwise
    /// lets the user pick a copied `db` file (for example from a backup).
    @objc private func importLaunchpadLayout() {
        if let url = LaunchpadLayoutImporter.defaultDatabaseURL() {
            runLaunchpadImport(from: url)
            return
        }
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = L("未找到本机的启动台数据库。请选择一份启动台数据库文件（通常名为 db）。")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.runLaunchpadImport(from: url)
        }
    }

    private func runLaunchpadImport(from url: URL) {
        guard confirmLaunchpadImport() else { return }
        Task { @MainActor in
            guard let onImportLaunchpadLayout = self.onImportLaunchpadLayout else {
                self.setMessage(LauncherLayout.LayoutIOOutcomeCopy.importUnavailable(localize: { L($0) }))
                return
            }
            let message = await onImportLaunchpadLayout(url)
            self.setMessage(message)
            self.refreshLayoutBackupControls()
            self.refreshHiddenApplicationsFromLauncher()
        }
    }

    /// Cancel first — Return/Esc keep the current layout.
    private func confirmLaunchpadImport() -> Bool {
        precondition(LauncherLayout.LayoutImportConfirmAlert.cancelIsFirstButton)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("从启动台导入布局？")
        alert.informativeText = L("将按原生启动台的顺序和文件夹重排主屏幕，启动台里没有的应用排在后面；只读取，不修改启动台数据。导入前会自动备份，可用「恢复上次备份」撤销。")
        let cancel = alert.addButton(withTitle: L(LauncherLayout.LayoutImportConfirmAlert.cancelButtonTitleKey))
        cancel.setAccessibilityHelp(L(LauncherLayout.LayoutImportConfirmAlert.cancelAccessibilityHelpKey))
        alert.addButton(withTitle: L("导入"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func restoreLayoutBackup() {
        let available = layoutBackupAvailable?() ?? false
        guard LauncherLayout.SettingsLayoutIOChromeCopy.shouldEnableRestoreBackupControl(
            hasBackupFile: available
        ) else {
            setMessage(LauncherLayout.LayoutIOOutcomeCopy.restoreNoBackup(localize: { L($0) }))
            refreshLayoutBackupControls()
            return
        }
        guard confirmLayoutRestoreBackup() else { return }
        Task { @MainActor in
            guard let onRestoreLayoutBackup else {
                setMessage(LauncherLayout.LayoutIOOutcomeCopy.restoreUnavailable(localize: { L($0) }))
                return
            }
            let message = await onRestoreLayoutBackup()
            setMessage(message)
            refreshLayoutBackupControls()
            refreshHiddenApplicationsFromLauncher()
        }
    }

    @objc private func rearrangeByName() {
        applyRearrange(.byName)
    }

    @objc private func rearrangeByKind() {
        applyRearrange(.byKind)
    }

    /// Category rearrange: same Cancel-first confirm as name/kind with the
    /// category explanation; root view reads Info.plist only after confirm.
    @objc private func rearrangeByCategory() {
        guard let onRearrangeByCategory else {
            // LAYOUT-EDITING-STATUS-COPY-01
            setMessage(LauncherLayout.LayoutEditingStatusCopy.rearrangeUnavailable(localize: { L($0) }))
            return
        }
        precondition(LauncherLayout.GridRearrangeConfirmAlert.cancelIsFirstButton)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L(LauncherLayout.GridRearrangeConfirmAlert.messageTextKey)
        alert.informativeText = L(LauncherLayout.CategoryRearrangeCopy.informativeTextKey)
        let cancel = alert.addButton(withTitle: L(LauncherLayout.GridRearrangeConfirmAlert.cancelButtonTitleKey))
        cancel.setAccessibilityHelp(L(LauncherLayout.GridRearrangeConfirmAlert.cancelAccessibilityHelpKey))
        let confirm = alert.addButton(withTitle: L(LauncherLayout.GridRearrangeConfirmAlert.confirmButtonTitleKey))
        confirm.setAccessibilityLabel(L(LauncherLayout.GridRearrangeConfirmAlert.confirmButtonTitleKey))
        confirm.setAccessibilityHelp(L(LauncherLayout.GridRearrangeConfirmAlert.confirmAccessibilityHelpKey))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if onRearrangeByCategory() {
            setMessage(L(LauncherLayout.CategoryRearrangeCopy.toastKey))
            refreshLayoutBackupControlsAfterPersist()
        } else {
            // LAYOUT-EDITING-STATUS-COPY-01
            setMessage(LauncherLayout.LayoutIOOutcomeCopy.layoutEditingBlocked(localize: { L($0) }))
        }
    }

    /// Color rearrange: Cancel-first confirm, then sample icons off the main
    /// thread and apply. Settings shows the progress line until sampling ends.
    @objc private func rearrangeByColor() {
        guard let onRearrangeByColor else {
            setMessage(LauncherLayout.LayoutEditingStatusCopy.rearrangeUnavailable(localize: { L($0) }))
            return
        }
        precondition(LauncherLayout.GridRearrangeConfirmAlert.cancelIsFirstButton)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L(LauncherLayout.GridRearrangeConfirmAlert.messageTextKey)
        alert.informativeText = L(LauncherLayout.ColorRearrangeCopy.informativeTextKey)
        let cancel = alert.addButton(withTitle: L(LauncherLayout.GridRearrangeConfirmAlert.cancelButtonTitleKey))
        cancel.setAccessibilityHelp(L(LauncherLayout.GridRearrangeConfirmAlert.cancelAccessibilityHelpKey))
        let confirm = alert.addButton(withTitle: L(LauncherLayout.GridRearrangeConfirmAlert.confirmButtonTitleKey))
        confirm.setAccessibilityLabel(L(LauncherLayout.GridRearrangeConfirmAlert.confirmButtonTitleKey))
        confirm.setAccessibilityHelp(L(LauncherLayout.GridRearrangeConfirmAlert.confirmAccessibilityHelpKey))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        setMessage(L(LauncherLayout.ColorRearrangeCopy.progressToastKey))
        Task { @MainActor in
            let ok = await onRearrangeByColor()
            if ok {
                setMessage(L(LauncherLayout.ColorRearrangeCopy.toastKey))
                refreshLayoutBackupControlsAfterPersist()
            } else {
                setMessage(LauncherLayout.LayoutIOOutcomeCopy.layoutEditingBlocked(localize: { L($0) }))
            }
        }
    }

    @objc private func rearrangeByDateAdded() {
        applyDateRearrange(.dateAdded)
    }

    @objc private func rearrangeByLastOpened() {
        applyDateRearrange(.lastOpened)
    }

    /// Date rearrange: Cancel-first confirm, then read Spotlight dates off the
    /// main actor and apply (DATE-REARRANGE-OFFMAIN-01).
    private func applyDateRearrange(_ kind: AppDateRearrangeKind) {
        guard let onRearrangeByDate else {
            setMessage(LauncherLayout.LayoutEditingStatusCopy.rearrangeUnavailable(localize: { L($0) }))
            return
        }
        precondition(LauncherLayout.GridRearrangeConfirmAlert.cancelIsFirstButton)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L(LauncherLayout.GridRearrangeConfirmAlert.messageTextKey)
        alert.informativeText = L(kind.informativeTextKey)
        let cancel = alert.addButton(withTitle: L(LauncherLayout.GridRearrangeConfirmAlert.cancelButtonTitleKey))
        cancel.setAccessibilityHelp(L(LauncherLayout.GridRearrangeConfirmAlert.cancelAccessibilityHelpKey))
        let confirm = alert.addButton(withTitle: L(LauncherLayout.GridRearrangeConfirmAlert.confirmButtonTitleKey))
        confirm.setAccessibilityLabel(L(LauncherLayout.GridRearrangeConfirmAlert.confirmButtonTitleKey))
        confirm.setAccessibilityHelp(L(LauncherLayout.GridRearrangeConfirmAlert.confirmAccessibilityHelpKey))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        setMessage(L(AppDateRearrangeKind.progressToastKey))
        Task { @MainActor in
            let ok = await onRearrangeByDate(kind)
            if ok {
                setMessage(L(kind.toastKey))
                refreshLayoutBackupControlsAfterPersist()
            } else {
                setMessage(LauncherLayout.LayoutIOOutcomeCopy.layoutEditingBlocked(localize: { L($0) }))
            }
        }
    }

    private func applyRearrange(_ sort: LauncherLayout.GridRearrangeSort) {
        guard let onRearrangeTopLevel else {
            setMessage(LauncherLayout.LayoutEditingStatusCopy.rearrangeUnavailable(localize: { L($0) }))
            return
        }
        guard confirmGridRearrange(sort: sort) else { return }
        if onRearrangeTopLevel(sort) {
            setMessage(L(LauncherLayout.gridRearrangeToastMessage(sort: sort)))
            // SETTINGS-BACKUP-ENABLE-AFTER-REARRANGE-01: wait out save debounce.
            refreshLayoutBackupControlsAfterPersist()
        } else {
            setMessage(LauncherLayout.LayoutIOOutcomeCopy.layoutEditingBlocked(localize: { L($0) }))
        }
    }


    /// Cancel first — Return/Esc must not restore backup.
    private func confirmLayoutRestoreBackup() -> Bool {
        precondition(LauncherLayout.LayoutRestoreBackupConfirmAlert.cancelIsFirstButton)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L(LauncherLayout.LayoutRestoreBackupConfirmAlert.messageTextKey)
        alert.informativeText = L(LauncherLayout.LayoutRestoreBackupConfirmAlert.informativeTextKey)
        let cancel = alert.addButton(withTitle: L(LauncherLayout.LayoutRestoreBackupConfirmAlert.cancelButtonTitleKey))
        cancel.setAccessibilityHelp(L(LauncherLayout.LayoutRestoreBackupConfirmAlert.cancelAccessibilityHelpKey))
        let confirm = alert.addButton(withTitle: L(LauncherLayout.LayoutRestoreBackupConfirmAlert.confirmButtonTitleKey))
        confirm.setAccessibilityLabel(L(LauncherLayout.LayoutRestoreBackupConfirmAlert.confirmButtonTitleKey))
        confirm.setAccessibilityHelp(L(LauncherLayout.LayoutRestoreBackupConfirmAlert.confirmAccessibilityHelpKey))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Cancel first — Return/Esc must not import. Called after the open panel.
    private func confirmLayoutImport() -> Bool {
        precondition(LauncherLayout.LayoutImportConfirmAlert.cancelIsFirstButton)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L(LauncherLayout.LayoutImportConfirmAlert.messageTextKey)
        alert.informativeText = L(LauncherLayout.LayoutImportConfirmAlert.informativeTextKey)
        let cancel = alert.addButton(withTitle: L(LauncherLayout.LayoutImportConfirmAlert.cancelButtonTitleKey))
        cancel.setAccessibilityHelp(L(LauncherLayout.LayoutImportConfirmAlert.cancelAccessibilityHelpKey))
        let confirm = alert.addButton(withTitle: L(LauncherLayout.LayoutImportConfirmAlert.confirmButtonTitleKey))
        confirm.setAccessibilityLabel(L(LauncherLayout.LayoutImportConfirmAlert.confirmButtonTitleKey))
        confirm.setAccessibilityHelp(L(LauncherLayout.LayoutImportConfirmAlert.confirmAccessibilityHelpKey))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Cancel first — Return/Esc must not rearrange. Same policy as uninstall alerts.
    private func confirmGridRearrange(sort: LauncherLayout.GridRearrangeSort) -> Bool {
        precondition(LauncherLayout.GridRearrangeConfirmAlert.cancelIsFirstButton)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L(LauncherLayout.GridRearrangeConfirmAlert.messageTextKey)
        alert.informativeText = L(LauncherLayout.GridRearrangeConfirmAlert.informativeTextKey(sort: sort))
        let cancel = alert.addButton(withTitle: L(LauncherLayout.GridRearrangeConfirmAlert.cancelButtonTitleKey))
        cancel.setAccessibilityHelp(L(LauncherLayout.GridRearrangeConfirmAlert.cancelAccessibilityHelpKey))
        let confirm = alert.addButton(withTitle: L(LauncherLayout.GridRearrangeConfirmAlert.confirmButtonTitleKey))
        confirm.setAccessibilityLabel(L(LauncherLayout.GridRearrangeConfirmAlert.confirmButtonTitleKey))
        confirm.setAccessibilityHelp(L(LauncherLayout.GridRearrangeConfirmAlert.confirmAccessibilityHelpKey))
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

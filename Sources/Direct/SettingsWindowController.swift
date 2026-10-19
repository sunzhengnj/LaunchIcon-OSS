import AppKit
import QuartzCore
import LaunchIconCore
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
/// Esc closes settings like other preference windows. A modal alert or open
/// popup menu consumes Escape first, so this only fires on the bare window.

/// Rounded settings card; refreshes fill when the effective appearance flips.
private final class SettingsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
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
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
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

final class SettingsWindowController: NSWindowController {
    var onPreferencesChanged: ((LauncherPreferences) -> String?)?
    var onRestoreHiddenApplication: ((String) -> Bool)?
    var onRescan: (() -> Void)?
    /// One-shot top-level grid rearrange (name / kind).
    var onRearrangeTopLevel: ((LauncherLayout.GridRearrangeSort) -> Bool)?
    /// True when layout-v1.backup.json exists (automatic prior-layout backup).
    var layoutBackupAvailable: (() -> Bool)?
    /// Export current layout JSON to the given URL.
    var onExportLayout: ((URL) async -> String)?
    /// Import layout JSON from the given URL (reconcile + commit).
    var onImportLayout: ((URL) async -> String)?
    /// Restore automatic last backup (reconcile + commit).
    var onRestoreLayoutBackup: (() async -> String)?
    /// Runs the orphan-leftovers flow; progress lines update the settings message.
    var onCleanUpLeftovers: (((@MainActor (String) -> Void)?) async -> String)?
    /// Fired when the settings window is closing (red button / Close).
    var onWindowWillClose: (() -> Void)?

    private var preferences: LauncherPreferences
    private var hiddenApplications: [HiddenApplication]
    private let shortcutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hotCornerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loginCheckbox = NSButton(checkboxWithTitle: L("开机登录"), target: nil, action: nil)
    private let statusCheckbox = NSButton(checkboxWithTitle: L("显示菜单栏图标"), target: nil, action: nil)
    private let hideCheckbox = NSButton(checkboxWithTitle: L("启动应用后自动收起"), target: nil, action: nil)
    private let motionCheckbox = NSButton(checkboxWithTitle: L("减少动态效果"), target: nil, action: nil)
    private let hiddenApplicationsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let restoreHiddenApplicationButton = NSButton(title: L("恢复"), target: nil, action: nil)
    private let rearrangeByNameButton = NSButton(title: L("按名称排列"), target: nil, action: nil)
    private let rearrangeByKindButton = NSButton(title: L("按类型排列"), target: nil, action: nil)
    private let rescanButton = NSButton(title: L("重新扫描"), target: nil, action: nil)
    private let leftoversButton = NSButton(title: L("残留文件…"), target: nil, action: nil)
    private let exportLayoutButton = NSButton(title: L("导出布局…"), target: nil, action: nil)
    private let importLayoutButton = NSButton(title: L("导入布局…"), target: nil, action: nil)
    private let restoreLayoutBackupButton = NSButton(title: L("恢复上次备份"), target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private var shortcutRegistrationError: String?
    private var isRescanning = false
    private var leftoversTask: Task<Void, Never>?
    /// Bumped on every `setMessage` so an older fade cannot wipe a newer line.
    private var messageFadeGeneration: UInt64 = 0
    /// Bumped on every presence fade so an older hide cannot orderOut a newer show.
    private var settingsPresenceGeneration: UInt64 = 0

    init(preferences: LauncherPreferences, hiddenApplications: [HiddenApplication]) {
        self.preferences = preferences
        self.hiddenApplications = hiddenApplications
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 790),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("LaunchIcon 设置")
        window.center()
        // Reused by showSettings; closing must not release the window out from
        // under the retained controller (and the next gear/⌘, open).
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.onRequestPresenceFadeClose = { [weak self] in
            self?.hideSettingsWindowPresenceThenClose()
        }
        buildContent(in: window)
        updateControls()
        refreshLoginStatus()
        refreshLayoutBackupControls()
    }

    // NSWindowController is the window's delegate; this SDK does not expose
    // windowWillClose as an overridable superclass method — implement the
    // delegate hook directly.
    func windowWillClose(_ notification: Notification) {
        leftoversTask?.cancel()
        leftoversTask = nil
        restoreLeftoversButtonIdle()
        onWindowWillClose?()
    }


    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(preferences: LauncherPreferences, hiddenApplications: [HiddenApplication]) {
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
        presentSettingsWindowPresence()
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
        setMessage(
            canEditLayout
                ? L("重新扫描完成")
                : L("暂时无法整理，请查看主界面提示")
        )
    }

    /// Shared metrics for form rows / cards (LaunchIcon settings chrome).
    private enum SettingsChrome {
        static let contentInset: CGFloat = 28
        static let sectionGap: CGFloat = 20
        static let cardCornerRadius: CGFloat = 10
        static let cardPadding: CGFloat = 14
        static let rowHeight: CGFloat = 32
        static let labelWidth: CGFloat = 108
    }

    private func buildContent(in window: NSWindow) {
        let root = NSView()
        window.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsChrome.sectionGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsChrome.contentInset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -SettingsChrome.contentInset),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -22)
        ])

        // Header: page title + version (own brand, not System Settings chrome).
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 12
        let title = NSTextField(labelWithString: L("通用"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        titleRow.addArrangedSubview(title)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(spacer)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? L("未知")
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? L("未知")
        let sourceCommit = Bundle.main.infoDictionary?["LaunchIconSourceCommit"] as? String
        let source = sourceCommit.map { String(format: L("源码 %@"), String($0.prefix(7))) } ?? L("开发构建")
        let versionLabel = NSTextField(labelWithString: String(format: L("版本 %@ (%@) · %@"), version, build, source))
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.toolTip = sourceCommit
        if let sourceCommit {
            versionLabel.setAccessibilityHelp(String(format: L("完整源码提交：%@"), sourceCommit))
        }
        titleRow.addArrangedSubview(versionLabel)
        stack.addArrangedSubview(titleRow)
        pinFullWidth(titleRow, in: stack)

        // --- 外观与呼出 ---
        shortcutPopup.addItems(withTitles: LauncherShortcut.allCases.map(\.title))
        shortcutPopup.setAccessibilityLabel(L("呼出快捷键"))
        window.initialFirstResponder = shortcutPopup
        shortcutPopup.target = self
        shortcutPopup.action = #selector(preferencesChanged)
        hotCornerPopup.addItems(withTitles: LauncherHotCorner.allCases.map(\.title))
        hotCornerPopup.setAccessibilityIdentifier("settings-hot-corner")
        hotCornerPopup.setAccessibilityLabel(L("呼出触发角"))
        hotCornerPopup.setAccessibilityHelp(L("将指针移入所选屏幕角可显示或隐藏启动器。若与系统设置「桌面与程序坞 → 触发角」选同一角，系统动作会一并触发；请选未占用的角，或在系统里将该角设为「-」。不需要辅助功能权限。"))
        hotCornerPopup.toolTip = L("与系统触发角冲突时请换角或关闭系统该角")
        hotCornerPopup.target = self
        hotCornerPopup.action = #selector(preferencesChanged)
        statusCheckbox.target = self
        statusCheckbox.action = #selector(preferencesChanged)
        statusCheckbox.setAccessibilityHelp(L("关闭后仍可用快捷键呼出；从启动器顶部设置按钮或按 Command-逗号可再次打开设置"))
        stack.addArrangedSubview(makeSection(
            title: L("外观与呼出"),
            rows: [
                makeFormRow(title: L("呼出快捷键"), control: shortcutPopup),
                makeFormRow(title: L("呼出触发角"), control: hotCornerPopup),
                makeToggleRow(statusCheckbox)
            ]
        ))

        // --- 行为 ---
        for checkbox in [hideCheckbox, motionCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(preferencesChanged)
        }
        hideCheckbox.setAccessibilityHelp(L("打开应用后自动收起启动器"))
        motionCheckbox.setAccessibilityLabel(L("减少动态效果"))
        motionCheckbox.setAccessibilityHelp(L("开启后不播放合并图标飞入与文件夹弹跳，只保留短淡入；关闭可恢复完整过渡。macOS 系统的减少动态效果设置仍会优先生效"))
        motionCheckbox.toolTip = L("关闭此项可显示完整合并过渡动画；系统减少动态效果开启时仍会简化动画")
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged)
        loginCheckbox.setAccessibilityHelp(L("登录 macOS 时自动启动 LaunchIcon"))
        let systemButton = NSButton(title: L("打开系统登录项设置…"), target: self, action: #selector(openLoginSettings))
        systemButton.bezelStyle = .inline
        systemButton.setAccessibilityLabel(L("打开系统登录项设置"))
        stack.addArrangedSubview(makeSection(
            title: L("行为"),
            rows: [
                makeToggleRow(hideCheckbox),
                makeToggleRow(motionCheckbox),
                makeToggleRow(loginCheckbox),
                makeAccessoryRow(systemButton)
            ]
        ))

        // --- 应用管理 ---
        hiddenApplicationsPopup.setAccessibilityLabel(L("隐藏的应用"))
        hiddenApplicationsPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hiddenApplicationsPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        restoreHiddenApplicationButton.target = self
        restoreHiddenApplicationButton.action = #selector(restoreHiddenApplication)
        restoreHiddenApplicationButton.setAccessibilityLabel(L("恢复所选应用"))
        restoreHiddenApplicationButton.setAccessibilityHelp(L("把隐藏的应用放回启动器"))
        let hiddenControls = NSStackView()
        hiddenControls.orientation = .horizontal
        hiddenControls.alignment = .centerY
        hiddenControls.spacing = 8
        hiddenControls.addArrangedSubview(hiddenApplicationsPopup)
        hiddenControls.addArrangedSubview(restoreHiddenApplicationButton)
        // Guard looks for `let hiddenRow`.
        let hiddenRow = makeFormRow(title: L("隐藏的应用"), control: hiddenControls)
        rearrangeByNameButton.bezelStyle = .rounded
        rearrangeByNameButton.target = self
        rearrangeByNameButton.action = #selector(rearrangeByName)
        rearrangeByNameButton.setAccessibilityLabel(L("按名称排列"))
        rearrangeByNameButton.setAccessibilityHelp(L("按显示名称重新排列主屏幕图标；文件夹内应用不变"))
        rearrangeByKindButton.bezelStyle = .rounded
        rearrangeByKindButton.target = self
        rearrangeByKindButton.action = #selector(rearrangeByKind)
        rearrangeByKindButton.setAccessibilityLabel(L("按类型排列"))
        rearrangeByKindButton.setAccessibilityHelp(L("系统应用在前，其余按名称；文件夹内应用不变"))
        let rearrangeActions = NSStackView()
        rearrangeActions.orientation = .horizontal
        rearrangeActions.alignment = .centerY
        rearrangeActions.spacing = 10
        rearrangeActions.addArrangedSubview(rearrangeByNameButton)
        rearrangeActions.addArrangedSubview(rearrangeByKindButton)
        let rearrangeFlex = NSView()
        rearrangeFlex.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rearrangeActions.addArrangedSubview(rearrangeFlex)
        let rearrangeRow = makePaddedRow(rearrangeActions, minHeight: SettingsChrome.rowHeight + 4)
        stack.addArrangedSubview(makeSection(
            title: L("应用管理"),
            rows: [hiddenRow, rearrangeRow]
        ))

        // --- 维护 ---
        rescanButton.bezelStyle = .rounded
        rescanButton.target = self
        rescanButton.action = #selector(rescan)
        rescanButton.setAccessibilityLabel(L("重新扫描"))
        rescanButton.setAccessibilityHelp(L("重新扫描 Applications 文件夹"))
        leftoversButton.bezelStyle = .rounded
        leftoversButton.target = self
        leftoversButton.action = #selector(cleanUpLeftovers)
        leftoversButton.setAccessibilityIdentifier("settings-cleanup-leftovers")
        leftoversButton.setAccessibilityLabel(L("残留文件"))
        leftoversButton.setAccessibilityHelp(L("查找已卸载应用留在用户资料库中的文件，确认后移到废纸篓"))
        if !AppUninstallPlatform.orphanCleanupAvailable(isSandboxed: AppUninstallPlatform.isSandboxed()) {
            leftoversButton.isEnabled = false
            leftoversButton.toolTip = L(AppUninstallPlatform.orphanSandboxedExplanationKey)
        }
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10
        actions.addArrangedSubview(rescanButton)
        actions.addArrangedSubview(leftoversButton)
        let actionsSpacer = NSView()
        actionsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actions.addArrangedSubview(actionsSpacer)
        let actionsRow = makePaddedRow(actions, minHeight: SettingsChrome.rowHeight + 4)

        exportLayoutButton.bezelStyle = .rounded
        exportLayoutButton.target = self
        exportLayoutButton.action = #selector(exportLayout)
        exportLayoutButton.setAccessibilityIdentifier("settings-export-layout")
        exportLayoutButton.setAccessibilityLabel(L("导出布局"))
        exportLayoutButton.setAccessibilityHelp(L("将当前主屏幕布局导出为 JSON 文件"))
        importLayoutButton.bezelStyle = .rounded
        importLayoutButton.target = self
        importLayoutButton.action = #selector(importLayout)
        importLayoutButton.setAccessibilityIdentifier("settings-import-layout")
        importLayoutButton.setAccessibilityLabel(L("导入布局"))
        importLayoutButton.setAccessibilityHelp(L("从 JSON 文件导入布局并与当前应用列表合并"))
        restoreLayoutBackupButton.bezelStyle = .rounded
        restoreLayoutBackupButton.target = self
        restoreLayoutBackupButton.action = #selector(restoreLayoutBackup)
        restoreLayoutBackupButton.setAccessibilityIdentifier("settings-restore-layout-backup")
        restoreLayoutBackupButton.setAccessibilityLabel(L("恢复上次备份"))
        restoreLayoutBackupButton.setAccessibilityHelp(L("恢复最近一次自动保存前的布局；再次恢复可撤销"))
        let layoutBackupActions = NSStackView()
        layoutBackupActions.orientation = .horizontal
        layoutBackupActions.alignment = .centerY
        layoutBackupActions.spacing = 10
        layoutBackupActions.addArrangedSubview(exportLayoutButton)
        layoutBackupActions.addArrangedSubview(importLayoutButton)
        layoutBackupActions.addArrangedSubview(restoreLayoutBackupButton)
        let layoutBackupSpacer = NSView()
        layoutBackupSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        layoutBackupActions.addArrangedSubview(layoutBackupSpacer)
        let layoutBackupRow = makePaddedRow(layoutBackupActions, minHeight: SettingsChrome.rowHeight + 4)

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

        stack.addArrangedSubview(makeSection(
            title: L("维护"),
            rows: [actionsRow, layoutBackupRow, messageRow]
        ))

        for section in stack.arrangedSubviews.dropFirst() {
            pinFullWidth(section, in: stack)
        }
    }

    /// Section title above a rounded card of equal-height form rows.
    private func makeSection(title: String, rows: [NSView]) -> NSStackView {
        let wrap = NSStackView()
        wrap.orientation = .vertical
        wrap.alignment = .leading
        wrap.spacing = 8
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
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4)
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
    private func makeFormRow(title: String, control: NSView) -> NSView {
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
        label.alignment = .left
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: SettingsChrome.labelWidth).isActive = true
        let flex = NSView()
        flex.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
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

    private func makeAccessoryRow(_ control: NSView) -> NSView {
        // Indent under related toggle (e.g. login → system login items).
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        row.edgeInsets = NSEdgeInsets(
            top: 0,
            left: SettingsChrome.cardPadding + 22,
            bottom: 0,
            right: SettingsChrome.cardPadding
        )
        row.addArrangedSubview(control)
        let flex = NSView()
        flex.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(flex)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: SettingsChrome.rowHeight - 4).isActive = true
        return row
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
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
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
                fadeMessageOpacity(to: 0, generation: generation) { [weak self] in
                    guard let self,
                          LauncherLayout.settingsMessageFadeShouldApply(
                            generation: self.messageFadeGeneration,
                            expected: generation
                          ) else { return }
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

    private func updateControls() {
        shortcutPopup.selectItem(at: LauncherShortcut.allCases.firstIndex(of: preferences.shortcut) ?? 0)
        hotCornerPopup.selectItem(at: LauncherHotCorner.allCases.firstIndex(of: preferences.hotCorner) ?? 0)
        statusCheckbox.state = preferences.showsStatusItem ? .on : .off
        hideCheckbox.state = preferences.hidesAfterLaunch ? .on : .off
        motionCheckbox.state = preferences.reducesMotion ? .on : .off
        updateHiddenApplications()
    }

    private func updateHiddenApplications() {
        hiddenApplicationsPopup.removeAllItems()
        guard !hiddenApplications.isEmpty else {
            hiddenApplicationsPopup.addItem(withTitle: L("没有隐藏的应用"))
            hiddenApplicationsPopup.isEnabled = false
            restoreHiddenApplicationButton.isEnabled = false
            return
        }
        hiddenApplicationsPopup.isEnabled = true
        restoreHiddenApplicationButton.isEnabled = true
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
        setMessage(L("正在重新扫描"))
    }

    @objc private func preferencesChanged() {
        var proposed = preferences
        proposed.shortcut = LauncherShortcut.allCases[shortcutPopup.indexOfSelectedItem]
        let hotIndex = hotCornerPopup.indexOfSelectedItem
        if hotIndex >= 0, hotIndex < LauncherHotCorner.allCases.count {
            proposed.hotCorner = LauncherHotCorner.allCases[hotIndex]
        }
        proposed.showsStatusItem = statusCheckbox.state == .on
        proposed.hidesAfterLaunch = hideCheckbox.state == .on
        proposed.reducesMotion = motionCheckbox.state == .on
        if let error = onPreferencesChanged?(proposed) {
            shortcutRegistrationError = error
            setMessage(error)
            updateControls()
        } else {
            preferences = proposed
            shortcutRegistrationError = nil
            setMessage(L("设置已应用"))
        }
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
                self.setMessage(L("请在系统设置的登录项中允许 LaunchIcon。"))
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
                ? L("请在系统设置的登录项中允许 LaunchIcon。") : L("开机登录设置已更新")))
        }
    }

    @objc private func restoreHiddenApplication() {
        guard let key = hiddenApplicationsPopup.selectedItem?.representedObject as? String else { return }
        guard onRestoreHiddenApplication?(key) == true else {
            setMessage(L("当前无法恢复该应用，请等待扫描完成后重试。"))
            return
        }
        hiddenApplications.removeAll { $0.key == key }
        updateHiddenApplications()
        if LauncherLayout.settingsShouldMoveFocusAfterRestore(remainingHidden: hiddenApplications.count) {
            window?.makeFirstResponder(rescanButton)
        }
        setMessage(L("已恢复应用"))
    }

    @objc private func cleanUpLeftovers() {
        if let running = leftoversTask {
            // Second click cancels an in-flight find/trash.
            running.cancel()
            setMessage(L(AppOrphanLeftoverScanner.cancelledMessageKey))
            leftoversButton.title = L("残留文件…")
            leftoversButton.setAccessibilityLabel(L("残留文件"))
            leftoversButton.setAccessibilityHelp(L("查找已卸载应用留在用户资料库中的文件，确认后移到废纸篓"))
            return
        }
        guard AppUninstallPlatform.orphanCleanupAvailable(isSandboxed: AppUninstallPlatform.isSandboxed()) else {
            setMessage(L(AppUninstallPlatform.orphanSandboxedExplanationKey))
            return
        }
        leftoversButton.title = L("取消查找")
        leftoversButton.setAccessibilityLabel(L("取消查找"))
        leftoversButton.setAccessibilityHelp(L("取消正在进行的残留文件查找或清理"))
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
        leftoversButton.title = L("残留文件…")
        leftoversButton.setAccessibilityLabel(L("残留文件"))
        leftoversButton.setAccessibilityHelp(L("查找已卸载应用留在用户资料库中的文件，确认后移到废纸篓"))
        leftoversButton.isEnabled = AppUninstallPlatform.orphanCleanupAvailable(
            isSandboxed: AppUninstallPlatform.isSandboxed()
        )
    }


    private func refreshLayoutBackupControls() {
        let available = layoutBackupAvailable?() ?? false
        restoreLayoutBackupButton.isEnabled = available
        restoreLayoutBackupButton.toolTip = available
            ? L("恢复最近一次自动保存前的布局")
            : L("尚无自动备份（修改布局后会生成）")
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
                    self.setMessage(L("当前无法导出布局"))
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
                    self.setMessage(L("当前无法导入布局"))
                    return
                }
                let message = await onImportLayout(url)
                self.setMessage(message)
                self.refreshLayoutBackupControls()
            }
        }
    }

    @objc private func restoreLayoutBackup() {
        guard confirmLayoutRestoreBackup() else { return }
        Task { @MainActor in
            guard let onRestoreLayoutBackup else {
                setMessage(L("当前无法恢复备份"))
                return
            }
            let message = await onRestoreLayoutBackup()
            setMessage(message)
            refreshLayoutBackupControls()
        }
    }

    @objc private func rearrangeByName() {
        applyRearrange(.byName)
    }

    @objc private func rearrangeByKind() {
        applyRearrange(.byKind)
    }

    private func applyRearrange(_ sort: LauncherLayout.GridRearrangeSort) {
        guard let onRearrangeTopLevel else {
            setMessage(L("当前无法重新排列"))
            return
        }
        guard confirmGridRearrange(sort: sort) else { return }
        if onRearrangeTopLevel(sort) {
            setMessage(L(LauncherLayout.gridRearrangeToastMessage(sort: sort)))
            // Rearrange persists via LayoutStore; enable restore once backup exists.
            refreshLayoutBackupControls()
        } else {
            setMessage(L("暂时无法整理，请查看主界面提示"))
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

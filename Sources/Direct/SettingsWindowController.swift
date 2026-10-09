import AppKit
import LaunchIconCore
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    var onPreferencesChanged: ((LauncherPreferences) -> String?)?
    var onRestoreHiddenApplication: ((String) -> Bool)?
    var onRescan: (() -> Void)?

    private var preferences: LauncherPreferences
    private var hiddenApplications: [HiddenApplication]
    private let shortcutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loginCheckbox = NSButton(checkboxWithTitle: "开机登录", target: nil, action: nil)
    private let statusCheckbox = NSButton(checkboxWithTitle: "显示菜单栏图标", target: nil, action: nil)
    private let hideCheckbox = NSButton(checkboxWithTitle: "启动应用后自动收起", target: nil, action: nil)
    private let motionCheckbox = NSButton(checkboxWithTitle: "减少动态效果（合并只保留短淡入）", target: nil, action: nil)
    private let hiddenApplicationsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let restoreHiddenApplicationButton = NSButton(title: "恢复", target: nil, action: nil)
    private let rescanButton = NSButton(title: "重新扫描", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private var shortcutRegistrationError: String?
    private var isRescanning = false

    init(preferences: LauncherPreferences, hiddenApplications: [HiddenApplication]) {
        self.preferences = preferences
        self.hiddenApplications = hiddenApplications
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LaunchIcon 设置"
        window.center()
        super.init(window: window)
        buildContent(in: window)
        updateControls()
        refreshLoginStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(preferences: LauncherPreferences, hiddenApplications: [HiddenApplication]) {
        self.preferences = preferences
        self.hiddenApplications = hiddenApplications
        if !isRescanning && shortcutRegistrationError == nil {
            messageLabel.stringValue = ""
        }
        updateControls()
        refreshLoginStatus()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func presentShortcutRegistrationError(_ message: String) {
        shortcutRegistrationError = message
        messageLabel.stringValue = message
    }

    func completeRescan(canEditLayout: Bool) {
        guard isRescanning else { return }
        isRescanning = false
        rescanButton.isEnabled = true
        guard shortcutRegistrationError == nil else { return }
        messageLabel.stringValue = canEditLayout
            ? "重新扫描完成"
            : "扫描仍不完整，暂时无法整理"
    }

    private func buildContent(in window: NSWindow) {
        let root = NSView()
        window.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)
        ])

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        let title = NSTextField(labelWithString: "通用")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        titleRow.addArrangedSubview(title)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(spacer)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        let sourceCommit = Bundle.main.infoDictionary?["LaunchIconSourceCommit"] as? String
        let source = sourceCommit.map { "源码 \($0.prefix(7))" } ?? "开发构建"
        let versionLabel = NSTextField(labelWithString: "版本 \(version) (\(build)) · \(source)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.toolTip = sourceCommit
        if let sourceCommit {
            versionLabel.setAccessibilityHelp("完整源码提交：\(sourceCommit)")
        }
        titleRow.addArrangedSubview(versionLabel)
        stack.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let shortcutRow = NSStackView()
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 16
        let shortcutLabel = NSTextField(labelWithString: "呼出快捷键")
        shortcutLabel.widthAnchor.constraint(equalToConstant: 112).isActive = true
        shortcutPopup.addItems(withTitles: LauncherShortcut.allCases.map(\.title))
        shortcutPopup.setAccessibilityLabel("呼出快捷键")
        shortcutPopup.target = self
        shortcutPopup.action = #selector(preferencesChanged)
        shortcutRow.addArrangedSubview(shortcutLabel)
        shortcutRow.addArrangedSubview(shortcutPopup)
        stack.addArrangedSubview(shortcutRow)

        for checkbox in [statusCheckbox, hideCheckbox, motionCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(preferencesChanged)
            stack.addArrangedSubview(checkbox)
        }
        statusCheckbox.setAccessibilityHelp("关闭后仍可用快捷键呼出；从启动器顶部设置按钮或按 Command-逗号可再次打开设置")
        motionCheckbox.setAccessibilityLabel("减少动态效果")
        motionCheckbox.setAccessibilityHelp("开启后不播放合并图标飞入与文件夹弹跳，只保留短淡入；关闭可恢复完整过渡。macOS 系统的减少动态效果设置仍会优先生效")
        motionCheckbox.toolTip = "关闭此项可显示完整合并过渡动画；系统减少动态效果开启时仍会简化动画"

        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged)
        stack.addArrangedSubview(loginCheckbox)
        let systemButton = NSButton(title: "打开系统登录项设置…", target: self, action: #selector(openLoginSettings))
        systemButton.bezelStyle = .inline
        stack.addArrangedSubview(systemButton)

        let hiddenSeparator = NSBox()
        hiddenSeparator.boxType = .separator
        stack.addArrangedSubview(hiddenSeparator)
        hiddenSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let hiddenTitle = NSTextField(labelWithString: "隐藏的应用")
        hiddenTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(hiddenTitle)
        let hiddenRow = NSStackView()
        hiddenRow.orientation = .horizontal
        hiddenRow.spacing = 10
        hiddenApplicationsPopup.setAccessibilityLabel("隐藏的应用")
        hiddenApplicationsPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        restoreHiddenApplicationButton.target = self
        restoreHiddenApplicationButton.action = #selector(restoreHiddenApplication)
        hiddenRow.addArrangedSubview(hiddenApplicationsPopup)
        hiddenRow.addArrangedSubview(restoreHiddenApplicationButton)
        stack.addArrangedSubview(hiddenRow)

        rescanButton.bezelStyle = .rounded
        rescanButton.target = self
        rescanButton.action = #selector(rescan)
        rescanButton.setAccessibilityLabel("重新扫描")
        rescanButton.setAccessibilityHelp("重新扫描 Applications 文件夹")
        stack.addArrangedSubview(rescanButton)

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 3
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(messageLabel)
        messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func updateControls() {
        shortcutPopup.selectItem(at: LauncherShortcut.allCases.firstIndex(of: preferences.shortcut) ?? 0)
        statusCheckbox.state = preferences.showsStatusItem ? .on : .off
        hideCheckbox.state = preferences.hidesAfterLaunch ? .on : .off
        motionCheckbox.state = preferences.reducesMotion ? .on : .off
        updateHiddenApplications()
    }

    private func updateHiddenApplications() {
        hiddenApplicationsPopup.removeAllItems()
        guard !hiddenApplications.isEmpty else {
            hiddenApplicationsPopup.addItem(withTitle: "没有隐藏的应用")
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
        messageLabel.stringValue = "正在重新扫描"
    }

    @objc private func preferencesChanged() {
        var proposed = preferences
        proposed.shortcut = LauncherShortcut.allCases[shortcutPopup.indexOfSelectedItem]
        proposed.showsStatusItem = statusCheckbox.state == .on
        proposed.hidesAfterLaunch = hideCheckbox.state == .on
        proposed.reducesMotion = motionCheckbox.state == .on
        if let error = onPreferencesChanged?(proposed) {
            shortcutRegistrationError = error
            messageLabel.stringValue = error
            updateControls()
        } else {
            preferences = proposed
            shortcutRegistrationError = nil
            messageLabel.stringValue = "设置已应用"
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
                self.messageLabel.stringValue = "请在系统设置的登录项中允许 LaunchIcon。"
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
            self.messageLabel.stringValue = result.1 ?? (result.0 == SMAppService.Status.requiresApproval.rawValue
                ? "请在系统设置的登录项中允许 LaunchIcon。" : "开机登录设置已更新")
        }
    }

    @objc private func restoreHiddenApplication() {
        guard let key = hiddenApplicationsPopup.selectedItem?.representedObject as? String else { return }
        guard onRestoreHiddenApplication?(key) == true else {
            messageLabel.stringValue = "当前无法恢复该应用，请等待扫描完成后重试。"
            return
        }
        hiddenApplications.removeAll { $0.key == key }
        updateHiddenApplications()
        messageLabel.stringValue = "已恢复应用"
    }

    @objc private func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

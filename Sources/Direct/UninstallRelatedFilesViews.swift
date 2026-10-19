import AppKit
import LaunchIconCore

@MainActor

/// Checkbox accessory for the uninstall confirmation sheet (default off).
final class UninstallRelatedFilesToggleView: NSView {
    private let checkbox = NSButton(
        checkboxWithTitle: L("同时删除相关用户文件…"),
        target: nil,
        action: nil
    )

    var isChecked: Bool { checkbox.state == .on }
    var isEnabled: Bool {
        get { checkbox.isEnabled }
        set {
            checkbox.isEnabled = newValue
            applyToggleAccessibilityHelp()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        checkbox.setButtonType(.switch)
        checkbox.state = .off
        checkbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        checkbox.setAccessibilityLabel(L("同时删除相关用户文件"))
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        applyToggleAccessibilityHelp()
    }

    private func applyToggleAccessibilityHelp() {
        let key = AppRelatedFileScanner.relatedFilesToggleAccessibilityHelp(
            isEnabled: checkbox.isEnabled
        )
        checkbox.setAccessibilityHelp(L(key))
        checkbox.toolTip = L(key)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// Scrollable checklist of related support files.
/// Default selection follows `AppRelatedFileScanner.relatedCleanupDefaultSelected`
/// (off) so users opt in per path. Footer/trash track 全选 / 全不选 and toggles.
final class UninstallRelatedFilesListView: NSView {
    private let toolbar = NSStackView()
    private let selectAllButton = NSButton(title: L("全选"), target: nil, action: nil)
    private let selectNoneButton = NSButton(title: L("全不选"), target: nil, action: nil)
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private weak var trashButton: NSButton?
    private var boxes: [(AppRelatedFileCandidate, NSButton)] = []

    init(files: [AppRelatedFileCandidate], defaultSelected: Bool = AppRelatedFileScanner.relatedCleanupDefaultSelected) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 236))
        wantsLayer = true

        selectAllButton.bezelStyle = .roundRect
        selectAllButton.controlSize = .small
        selectAllButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        selectAllButton.setAccessibilityIdentifier("uninstall-related-select-all")
        selectAllButton.setAccessibilityLabel(L(AppRelatedFileScanner.relatedCleanupSelectAllAccessibilityLabelKey))
        selectAllButton.setAccessibilityHelp(L(AppRelatedFileScanner.relatedCleanupSelectAllAccessibilityHelpKey))
        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllRelatedFiles)

        selectNoneButton.bezelStyle = .roundRect
        selectNoneButton.controlSize = .small
        selectNoneButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        selectNoneButton.setAccessibilityIdentifier("uninstall-related-select-none")
        selectNoneButton.setAccessibilityLabel(L(AppRelatedFileScanner.relatedCleanupSelectNoneAccessibilityLabelKey))
        selectNoneButton.setAccessibilityHelp(L(AppRelatedFileScanner.relatedCleanupSelectNoneAccessibilityHelpKey))
        selectNoneButton.target = self
        selectNoneButton.action = #selector(selectNoneRelatedFiles)

        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addArrangedSubview(selectAllButton)
        toolbar.addArrangedSubview(selectNoneButton)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)
        addSubview(toolbar)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for file in files {
            let size = AppRelatedFileScanner.formatByteSize(file.byteSize)
            let title = "\(file.url.path) — \(kindLabel(file.kind)) (\(size))"
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.setButtonType(.switch)
            box.state = defaultSelected ? .on : .off
            box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            box.lineBreakMode = .byTruncatingMiddle
            box.setAccessibilityLabel(file.url.path)
            box.setAccessibilityHelp(
                AppRelatedFileScanner.relatedCleanupItemAccessibilityHelp(
                    kindLabel: kindLabel(file.kind),
                    sizeLabel: size
                )
            )
            box.target = self
            box.action = #selector(relatedFileCheckboxChanged(_:))
            stack.addArrangedSubview(box)
            boxes.append((file, box))
        }

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            stack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -8)
        ])

        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        footerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.setAccessibilityIdentifier("uninstall-related-selected-total")
        footerLabel.setAccessibilityLabel(L(AppRelatedFileScanner.relatedCleanupSelectedTotalAccessibilityLabelKey))
        addSubview(footerLabel)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L(AppRelatedFileScanner.relatedCleanupListAccessibilityLabelKey))
        scroll.setAccessibilityElement(true)
        scroll.setAccessibilityRole(.scrollArea)
        scroll.setAccessibilityLabel(L(AppRelatedFileScanner.relatedCleanupListAccessibilityLabelKey))

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -6),
            footerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            footerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 236),
            widthAnchor.constraint(equalToConstant: 420)
        ])
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        wireKeyViewLoop()
        refreshSelectedTotal()
    }

    /// Tab order: 全选 → 全不选 → each checkbox (scroll content).
    private func wireKeyViewLoop() {
        selectAllButton.nextKeyView = selectNoneButton
        var previous: NSView = selectNoneButton
        for (_, box) in boxes {
            previous.nextKeyView = box
            previous = box
        }
        previous.nextKeyView = selectAllButton
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func selectedFiles() -> [AppRelatedFileCandidate] {
        boxes.compactMap { file, box in box.state == .on ? file : nil }
    }

    /// Keep the destructive confirm disabled when nothing is checked.
    func adoptTrashButton(_ button: NSButton) {
        trashButton = button
        refreshSelectedTotal()
    }

    @objc private func relatedFileCheckboxChanged(_ sender: NSButton) {
        refreshSelectedTotal()
    }

    @objc private func selectAllRelatedFiles() {
        setAllCheckboxes(on: true)
    }

    @objc private func selectNoneRelatedFiles() {
        setAllCheckboxes(on: false)
    }

    private func setAllCheckboxes(on: Bool) {
        let state: NSControl.StateValue = on ? .on : .off
        for (_, box) in boxes {
            box.state = state
        }
        refreshSelectedTotal()
    }

    private func refreshSelectedTotal() {
        let selected = selectedFiles()
        let total = AppRelatedFileScanner.selectedByteTotal(of: selected)
        let sizeText = AppRelatedFileScanner.formatByteSize(total)
        footerLabel.stringValue = String(
            format: L("已选 %d 项，共 %@"),
            selected.count,
            sizeText
        )
        footerLabel.toolTip = footerLabel.stringValue
        let confirmEnabled = AppRelatedFileScanner.relatedCleanupConfirmEnabled(selectedCount: selected.count)
        trashButton?.isEnabled = confirmEnabled
        let trashHelp = L(AppRelatedFileScanner.relatedCleanupTrashAccessibilityHelp(selectedCount: selected.count))
        trashButton?.setAccessibilityHelp(trashHelp)
        trashButton?.toolTip = confirmEnabled ? nil : trashHelp
        selectAllButton.isEnabled = !boxes.isEmpty && selected.count < boxes.count
        selectNoneButton.isEnabled = !selected.isEmpty
    }

    private func kindLabel(_ kind: AppRelatedFileCandidate.Kind) -> String {
        switch kind {
        case .applicationSupport: return L("支持文件")
        case .preferences: return L("偏好设置")
        case .caches: return L("缓存")
        case .containers: return L("容器")
        case .groupContainers: return L("组容器")
        case .logs: return L("日志")
        case .savedState: return L("保存的状态")
        case .launchAgents: return L("登录项代理")
        case .httpStorages: return L("网络存储")
        case .webKit: return L("WebKit 数据")
        case .crashReporter: return L("崩溃报告")
        }
    }
}

import AppKit
import LaunchIconCore

@MainActor
final class StoreSpikeWindowController: NSWindowController {
    private let resultView = NSTextView()
    private let diagnosticsQueue = DispatchQueue(label: "LaunchIcon.StoreSpike.Diagnostics", qos: .utility)
    private var candidates: [AppCandidate] = []
    private var probeTask: Task<Void, Never>?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LaunchIcon Store Capability Spike"
        window.center()
        super.init(window: window)
        window.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        probeTask?.cancel()
    }

    func toggleVisibility() {
        guard let window else { return }
        if window.isVisible { window.orderOut(nil) } else { showWindow(nil) }
    }

    func setHotKeyResult(_ result: String) {
        append("Option + Space: \(result)")
    }

    private func makeContentView() -> NSView {
        let view = NSView()
        let description = NSTextField(wrappingLabelWithString: "沙箱 spike：扫描、图标读取、显式启动请求与全局快捷键分别记录。点击启动才会请求打开系统计算器。")
        description.translatesAutoresizingMaskIntoConstraints = false

        let probeButton = NSButton(title: "运行扫描与图标 probe", target: self, action: #selector(runCapabilityProbe))
        probeButton.translatesAutoresizingMaskIntoConstraints = false
        let launchButton = NSButton(title: "启动系统计算器（测试）", target: self, action: #selector(requestLaunchFromButton))
        launchButton.translatesAutoresizingMaskIntoConstraints = false

        resultView.isEditable = false
        resultView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        resultView.backgroundColor = .textBackgroundColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = resultView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(description)
        view.addSubview(probeButton)
        view.addSubview(launchButton)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            description.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            description.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            description.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            probeButton.leadingAnchor.constraint(equalTo: description.leadingAnchor),
            probeButton.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 16),
            launchButton.leadingAnchor.constraint(equalTo: probeButton.trailingAnchor, constant: 12),
            launchButton.centerYAnchor.constraint(equalTo: probeButton.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: description.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: description.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: probeButton.bottomAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
        return view
    }

    @objc func runCapabilityProbe() {
        probeTask?.cancel()
        append("Scanning standard roots…")
        probeTask = Task { [weak self] in
            let report = await AppCatalogScanner().scan(roots: AppCatalogScanner.standardRoots)
            guard !Task.isCancelled else { return }
            let iconReadable = await Task.detached(priority: .utility) { () -> Bool in
                let iconProvider = WorkspaceIconProvider()
                return report.candidates.first.map {
                    iconProvider.icon(for: $0.canonicalURL).isValid
                } ?? false
            }.value
            guard !Task.isCancelled else { return }
            self?.candidates = report.candidates
            self?.append("Discovery: \(report.candidates.count) candidates; skipped: \(report.skippedPaths.count)")
            let clockName = report.candidates.first { $0.canonicalURL.lastPathComponent == "Clock.app" }?.displayName ?? "not found"
            self?.append("Clock display name: \(clockName)")
            self?.append("Icon read for first candidate: \(iconReadable)")
        }
    }

    @objc private func requestLaunchFromButton() {
        guard let candidate = candidates.first(where: { $0.canonicalURL.lastPathComponent == "Calculator.app" }) else {
            append("Launch: Calculator not discovered")
            return
        }
        requestLaunch(at: candidate.canonicalURL, displayName: candidate.displayName)
    }

    private func requestLaunch(at url: URL, displayName: String) {
        append("Launch requested: \(displayName)")
        Task { [weak self] in
            do {
                try await WorkspaceAppLauncher().launch(url)
                await MainActor.run { self?.append("Launch request submitted") }
            } catch {
                await MainActor.run { self?.append("Launch failed: \(error.localizedDescription)") }
            }
        }
    }

    private func append(_ line: String) {
        NSLog("LaunchIconStoreSpike: %@", line)
        let current = resultView.string
        resultView.string = current + (current.isEmpty ? "" : "\n") + line
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.sunzheng.LaunchIcon.StoreSpike"
        let environment = ProcessInfo.processInfo.environment
        diagnosticsQueue.async {
            LocalDiagnostics.appendEvidence(
                line,
                environment: environment,
                defaults: .standard,
                bundleIdentifier: bundleIdentifier
            )
        }
    }
}

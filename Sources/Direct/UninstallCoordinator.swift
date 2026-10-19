import AppKit
import LaunchIconCore

/// Direct uninstall flows moved out of `LauncherRootView` with no intentional
/// behavior change: sheets, process waits, and prompt/orphan orchestration.

@MainActor
protocol UninstallHost: AnyObject {
    var isPromptingForUninstall: Bool { get set }
    var isLayoutEditingEnabled: Bool { get }
    var uninstallCatalogRoots: [URL] { get }
    var uninstallCandidates: [AppCandidate] { get }
    func acceptsIconContextMenuAction() -> Bool
    func displayName(for candidate: AppCandidate) -> String
    func showUninstallToast(_ message: String, help: String?, autoDismiss: Bool)
    func hideUninstallToast(animated: Bool)
    func clearMatchingProgressToast(_ message: String)
    func applySuccessfulUninstall(of candidate: AppCandidate, otherCopyMayExist: Bool)
    func requestCatalogReloadAfterUninstall()
    /// Remember the tile that opened uninstall so keyboard returns after sheets.
    func noteUninstallSheetFocusItemID(_ id: UUID?)
    func restoreFocusAfterUninstallSheet()
}

@MainActor
enum UninstallCoordinator {

    private static func toast(
        _ host: UninstallHost,
        _ message: String,
        help: String? = nil,
        autoDismiss: Bool = true
    ) {
        host.showUninstallToast(message, help: help, autoDismiss: autoDismiss)
    }

    private static func clearMatchingProgressToast(_ host: UninstallHost, _ message: String) {
        host.clearMatchingProgressToast(message)
    }


    static func forceQuitRunningApplications(_ apps: [NSRunningApplication]) async -> Bool {
        guard !Task.isCancelled else { return false }
        for app in apps where !app.isTerminated {
            _ = app.forceTerminate()
        }
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            if apps.allSatisfy(\.isTerminated) { return true }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return false }
        }
        return !Task.isCancelled && apps.allSatisfy(\.isTerminated)
    }

    static func quitRunningApplications(_ apps: [NSRunningApplication]) async -> Bool {
        guard !Task.isCancelled else { return false }
        for app in apps where !app.isTerminated {
            _ = app.terminate()
        }
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            if apps.allSatisfy(\.isTerminated) { return true }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return false }
        }
        return !Task.isCancelled && apps.allSatisfy(\.isTerminated)
    }

    static func runningApplications(matching candidate: AppCandidate) -> [NSRunningApplication] {
        return NSWorkspace.shared.runningApplications.filter { app in
            AppUninstallEligibility.runningProcessBelongsToTarget(
                bundleURL: app.bundleURL,
                executableURL: app.executableURL,
                targetURL: candidate.canonicalURL
            )
        }
    }

    static func confirmRelatedFileDeletion(
        _ files: [AppRelatedFileCandidate],
        appName: String
    ) -> [AppRelatedFileCandidate]? {
        precondition(AppRelatedFileScanner.relatedCleanupAlertCancelIsFirstButton)
        let list = UninstallRelatedFilesListView(
            files: files,
            defaultSelected: AppRelatedFileScanner.relatedCleanupDefaultSelected
        )
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L("选择要清理的“%@”相关文件"), appName)
        alert.informativeText = L(AppRelatedFileScanner.relatedCleanupReviewMessageKey)
        alert.accessoryView = list
        // Cancel first: Return stays on Cancel; Esc dismisses without trash.
        alert.addButton(withTitle: L("取消"))
        let trash = alert.addButton(withTitle: L("移到废纸篓"))
        trash.hasDestructiveAction = true
        list.adoptTrashButton(trash)
        alert.layout()
        guard alert.runModal() == .alertSecondButtonReturn else { return nil }
        return list.selectedFiles()
    }

    /// Force-quit sheet: Cancel first (Return/Esc safe); VoiceOver help on both buttons.
    /// Focus returns via `promptToUninstall`'s defer + host restore.
    @discardableResult
    static func confirmForceQuitBeforeUninstall() -> Bool {
        precondition(AppUninstallForceQuitAlert.cancelIsFirstButton)
        let force = NSAlert()
        force.alertStyle = .warning
        force.messageText = L(AppUninstallForceQuitAlert.messageTextKey)
        force.informativeText = L(AppUninstallForceQuitAlert.informativeTextKey)
        let cancel = force.addButton(withTitle: L(AppUninstallForceQuitAlert.cancelButtonTitleKey))
        cancel.setAccessibilityHelp(L(AppUninstallForceQuitAlert.cancelAccessibilityHelpKey))
        let forceButton = force.addButton(withTitle: L(AppUninstallForceQuitAlert.confirmButtonTitleKey))
        forceButton.hasDestructiveAction = true
        forceButton.setAccessibilityLabel(L(AppUninstallForceQuitAlert.confirmButtonTitleKey))
        forceButton.setAccessibilityHelp(L(AppUninstallForceQuitAlert.confirmAccessibilityHelpKey))
        force.layout()
        return force.runModal() == .alertSecondButtonReturn
    }

    static func uninstallDecision(for candidate: AppCandidate, host: UninstallHost) -> AppUninstallDecision {
        AppUninstallEligibility.evaluate(
            candidate: candidate,
            layoutEditingEnabled: host.isLayoutEditingEnabled,
            selfBundleURL: Bundle.main.bundleURL,
            selfBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static func promptToUninstall(_ candidate: AppCandidate, host: UninstallHost) async {
        guard host.acceptsIconContextMenuAction(), !host.isPromptingForUninstall else { return }
        let decision = uninstallDecision(for: candidate, host: host)
        guard decision.isAllowed else {
            if let key = decision.explanationKey {
                toast(host, L(key))
            }
            return
        }
        guard let bundleIdentity = AppUninstallEligibility.captureBundleIdentity(of: candidate) else {
            toast(host, L("应用已变化，请重新尝试卸载"), autoDismiss: false)
            return
        }

        host.isPromptingForUninstall = true
        defer {
            host.isPromptingForUninstall = false
            if AppRelatedFileScanner.relatedCleanupRestoresLauncherFocusAfterSheet {
                host.restoreFocusAfterUninstallSheet()
            }
        }
        let copyCheckMessage = L("正在检查应用副本…")
        toast(host, copyCheckMessage, autoDismiss: false)
        let otherCopy = await hasOtherInstalledCopy(of: candidate, host: host)
        clearMatchingProgressToast(host, copyCheckMessage)
        guard !Task.isCancelled, host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled else { return }

        let name = host.displayName(for: candidate)
        let running = runningApplications(matching: candidate)
        let relatedToggle = UninstallRelatedFilesToggleView()
        relatedToggle.isEnabled = otherCopy == false

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L("卸载“%@”？"), name)
        var info = candidate.canonicalURL.path
        if let bundleID = candidate.bundleIdentifier, !bundleID.isEmpty {
            info += "\n" + bundleID
        }
        if running.isEmpty {
            info += "\n\n" + L("应用将被移到废纸篓。默认不删除用户数据文件。")
        } else {
            info += "\n\n" + L("该应用正在运行。继续前将先尝试退出，再移到废纸篓。默认不删除用户数据文件。")
        }
        if otherCopy == true {
            info += "\n" + L("发现同一应用的其他副本，相关用户文件将保留。")
        } else if otherCopy == nil {
            info += "\n" + L("无法确认是否有其他副本，相关用户文件将保留。")
        }
        alert.informativeText = info
        alert.accessoryView = relatedToggle
        precondition(AppRelatedFileScanner.relatedCleanupAlertCancelIsFirstButton)
        // Cancel is first so Return does not immediately trash; Esc → Cancel.
        alert.addButton(withTitle: L("取消"))
        let trashTitle = running.isEmpty ? L("移到废纸篓") : L("退出并移到废纸篓")
        let trash = alert.addButton(withTitle: trashTitle)
        trash.hasDestructiveAction = true
        alert.layout()

        guard alert.runModal() == .alertSecondButtonReturn, !Task.isCancelled else { return }
        guard host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled else { return }

        var relatedSelection: [AppRelatedFileCandidate] = []
        if relatedToggle.isChecked {
            let progressMessage = L(AppRelatedFileScanner.scanningProgressMessageKey)
            toast(host, progressMessage, autoDismiss: false)
            let home = FileManager.default.homeDirectoryForCurrentUser
            let scan = Task.detached(priority: .utility) {
                AppRelatedFileScanner.discover(
                    candidate: candidate,
                    homeDirectory: home,
                    isCancelled: { Task.isCancelled }
                )
            }
            let discovered = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            clearMatchingProgressToast(host, progressMessage)
            guard !Task.isCancelled else {
                toast(host, L(AppRelatedFileScanner.cancelledMessageKey))
                return
            }
            guard host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled else { return }
            if discovered.isEmpty {
                // Opt-in cleanup found nothing — say so, then continue trash-only.
                toast(host, L(AppRelatedFileScanner.emptyRelatedFilesMessageKey))
            } else {
                guard let confirmed = confirmRelatedFileDeletion(discovered, appName: name) else {
                    return
                }
                relatedSelection = confirmed
            }
        }

        guard !Task.isCancelled, host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled,
              AppUninstallEligibility.matchesBundleIdentity(bundleIdentity, of: candidate) else { return }
        let currentlyRunning = runningApplications(matching: candidate)
        if !currentlyRunning.isEmpty {
            let quittingMessage = L(AppUninstallQuitProgress.quittingMessageKey)
            toast(host, quittingMessage, help: L(AppUninstallQuitProgress.quittingAccessibilityHelpKey), autoDismiss: false)
            let quitOK = await quitRunningApplications(currentlyRunning)
            clearMatchingProgressToast(host, quittingMessage)
            guard !Task.isCancelled else {
                toast(host, L(AppRelatedFileScanner.cancelledMessageKey))
                return
            }
            guard host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled else { return }
            if !quitOK {
                guard confirmForceQuitBeforeUninstall() else { return }
                guard !Task.isCancelled, host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled,
                      AppUninstallEligibility.matchesBundleIdentity(bundleIdentity, of: candidate) else { return }
                let forceQuitOK = await forceQuitRunningApplications(currentlyRunning)
                guard !Task.isCancelled, host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled else { return }
                guard forceQuitOK else {
                    toast(host, L("应用仍在运行，未移到废纸篓；请退出后重试"), autoDismiss: false)
                    return
                }
            }
        }

        // Re-check after the modal sheets: the scan may have restarted, the
        // bundle may be gone, or editing may have been turned off meanwhile.
        let recheck = uninstallDecision(for: candidate, host: host)
        guard !Task.isCancelled, recheck.isAllowed,
              AppUninstallEligibility.matchesBundleIdentity(bundleIdentity, of: candidate) else {
            if let key = recheck.explanationKey { toast(host, L(key)) }
            else if !Task.isCancelled { toast(host, L("应用已变化，请重新尝试卸载"), autoDismiss: false) }
            return
        }
        let finalOtherCopy = await hasOtherInstalledCopy(of: candidate, host: host)
        guard !Task.isCancelled, host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled,
              AppUninstallEligibility.matchesBundleIdentity(bundleIdentity, of: candidate) else { return }
        if !relatedSelection.isEmpty {
            guard finalOtherCopy == false else {
                if !Task.isCancelled {
                    toast(host, L("应用副本状态已变化，未移除应用或用户数据；请重新尝试"), autoDismiss: false)
                }
                return
            }
        }
        guard !Task.isCancelled, host.isLayoutEditingEnabled else { return }
        guard runningApplications(matching: candidate).isEmpty else {
            toast(host, L("应用仍在运行，未移到废纸篓；请退出后重试"), autoDismiss: false)
            return
        }

        // Confirm→Trash atomicity for related: re-discover, refuse if selection
        // paths changed/gone, then snapshot device+inode for the executor gate.
        var relatedIdentities: [AppUninstallPathIdentity] = []
        if !relatedSelection.isEmpty {
            let recheckMessage = L(AppRelatedFileScanner.recheckingProgressMessageKey)
            toast(host, recheckMessage, autoDismiss: false)
            let homeForRecheck = FileManager.default.homeDirectoryForCurrentUser
            let candidateForRecheck = candidate
            let recheckScan = Task.detached(priority: .utility) {
                AppRelatedFileScanner.discover(
                    candidate: candidateForRecheck,
                    homeDirectory: homeForRecheck,
                    isCancelled: { Task.isCancelled }
                )
            }
            let rediscovered = await withTaskCancellationHandler {
                await recheckScan.value
            } onCancel: {
                recheckScan.cancel()
            }
            clearMatchingProgressToast(host, recheckMessage)
            guard !Task.isCancelled else {
                toast(host, L(AppRelatedFileScanner.cancelledMessageKey))
                return
            }
            guard host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled,
                  AppUninstallEligibility.matchesBundleIdentity(bundleIdentity, of: candidate) else {
                toast(host, L(AppRelatedFileScanner.changedBeforeTrashMessageKey), autoDismiss: false)
                return
            }
            guard AppRelatedFileScanner.relatedCleanupSelectionStillValid(
                selected: relatedSelection,
                rediscovered: rediscovered
            ) else {
                toast(host, L(AppRelatedFileScanner.changedBeforeTrashMessageKey), autoDismiss: false)
                return
            }
            relatedIdentities = AppUninstallEligibility.capturePathIdentities(of: relatedSelection)
            guard relatedIdentities.count == relatedSelection.count else {
                toast(host, L(AppRelatedFileScanner.changedBeforeTrashMessageKey), autoDismiss: false)
                return
            }
        }

        // Trash I/O off the main actor: large trees / auth sheets must not freeze
        // the grid or hotkey. Bundle + related identities are rechecked again
        // inside the executor immediately before each trashItem.
        let progressMessage = L("正在移到废纸篓…")
        toast(host, progressMessage, autoDismiss: false)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let relatedForTrash = relatedSelection
        let relatedIdentitiesForTrash = relatedIdentities
        let identityForTrash = bundleIdentity
        let candidateForTrash = candidate
        let trashTask = Task.detached(priority: .utility) {
            AppUninstallExecutor.perform(
                bundleURL: candidateForTrash.canonicalURL,
                related: relatedForTrash,
                homeDirectory: home,
                expectedIdentity: identityForTrash,
                expectedRelatedIdentities: relatedIdentitiesForTrash,
                candidate: candidateForTrash,
                fileManager: FileManager(),
                isCancelled: { Task.isCancelled }
            )
        }
        let report = await withTaskCancellationHandler {
            await trashTask.value
        } onCancel: {
            trashTask.cancel()
        }
        clearMatchingProgressToast(host, progressMessage)
        guard !Task.isCancelled else { return }
        switch report.outcome {
        case .bundleFailed:
            let detail = report.bundleFailure?.detail ?? ""
            switch report.bundleFailure?.reason {
            case .cancelled:
                return
            case .identityMismatch:
                toast(host, L("应用已变化，请重新尝试卸载"), autoDismiss: false)
            case .permissionDenied:
                toast(host, L("没有权限移到废纸篓；应用和用户数据均未改动"), help: detail, autoDismiss: false)
            default:
                toast(host, L("无法移到废纸篓；应用和用户数据均未改动"), help: detail, autoDismiss: false)
            }
            return
        case .bundleOnly:
            host.applySuccessfulUninstall(of: candidate, otherCopyMayExist: finalOtherCopy != false)
            toast(host, L(AppUninstallReport.undoHintKey))
        case .bundleAndAllRelated:
            host.applySuccessfulUninstall(of: candidate, otherCopyMayExist: finalOtherCopy != false)
            toast(host, String(format: L("已移到废纸篓（含 %d 项相关文件），可在废纸篓中放回原处"), report.trashedRelated.count))
        case .partialRelated:
            host.applySuccessfulUninstall(of: candidate, otherCopyMayExist: finalOtherCopy != false)
            let failedList = report.failedRelated.map { failure -> String in
                let why: String
                switch failure.reason {
                case .permissionDenied: why = L("没有权限")
                case .unsafePath: why = L("路径不安全，已跳过")
                case .missing: why = L("已不存在")
                case .identityMismatch: why = L("路径已变化")
                case .cancelled: why = L("已取消")
                case .other: why = failure.detail
                }
                return "\(failure.url.path) — \(why)"
            }
            toast(host, 
                String(
                    format: L("应用已移到废纸篓；%d 项相关文件已移走，%d 项失败（仍在原处）"),
                    report.trashedRelated.count,
                    report.failedRelated.count
                ),
                help: failedList.joined(separator: "\n"),
                autoDismiss: false
            )
        }
        host.requestCatalogReloadAfterUninstall()
    }

    /// Orphan leftovers (apps no longer installed). Same opt-in checklist,
    /// same Trash-only move; never runs on an incomplete scan or sandboxed build.
    static func cleanUpOrphanLeftovers(
        host: UninstallHost,
        progress: (@MainActor (String) -> Void)? = nil
    ) async -> String {
        guard AppUninstallPlatform.orphanCleanupAvailable(isSandboxed: AppUninstallPlatform.isSandboxed()) else {
            return L(AppUninstallPlatform.orphanSandboxedExplanationKey)
        }
        guard host.isLayoutEditingEnabled, !host.isPromptingForUninstall else {
            return L(AppOrphanLeftoverScanner.incompleteScanMessageKey)
        }
        @MainActor func report(_ key: String) {
            progress?(L(key))
        }
        var installedIDs = Set(host.uninstallCandidates.compactMap { $0.bundleIdentifier })
        if let selfID = Bundle.main.bundleIdentifier { installedIDs.insert(selfID) }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { installedIDs.insert(id) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        host.isPromptingForUninstall = true
        defer {
            host.isPromptingForUninstall = false
            if AppRelatedFileScanner.relatedCleanupRestoresLauncherFocusAfterSheet {
                host.restoreFocusAfterUninstallSheet()
            }
        }
        report(AppOrphanLeftoverScanner.scanningProgressMessageKey)
        let scan = Task.detached(priority: .utility) {
            AppOrphanLeftoverScanner.discover(
                homeDirectory: home,
                installedBundleIdentifiers: installedIDs,
                isInstalledElsewhere: {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
                },
                isCancelled: { Task.isCancelled }
            )
        }
        let found = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        guard !Task.isCancelled else { return L(AppOrphanLeftoverScanner.cancelledMessageKey) }
        guard host.isLayoutEditingEnabled else { return L(AppOrphanLeftoverScanner.incompleteScanMessageKey) }
        guard !found.isEmpty else { return L(AppOrphanLeftoverScanner.noneFoundMessageKey) }

        precondition(AppRelatedFileScanner.relatedCleanupAlertCancelIsFirstButton)
        let list = UninstallRelatedFilesListView(files: found, defaultSelected: AppRelatedFileScanner.relatedCleanupDefaultSelected)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("清理已卸载应用的残留文件")
        alert.informativeText = L("这些项目可能属于已卸载的应用。默认不选；请确认路径并勾选要移到废纸篓的项目。")
        alert.accessoryView = list
        // Cancel first — Return/Esc never trash without an explicit second click.
        alert.addButton(withTitle: L("取消"))
        let trash = alert.addButton(withTitle: L("移到废纸篓"))
        trash.hasDestructiveAction = true
        list.adoptTrashButton(trash)
        alert.layout()
        guard alert.runModal() == .alertSecondButtonReturn else { return "" }
        let selected = list.selectedFiles()
        guard !selected.isEmpty else { return "" }
        report(AppOrphanLeftoverScanner.recheckingProgressMessageKey)
        let currentCatalog = await AppCatalogScanner().scan(roots: host.uninstallCatalogRoots)
        guard !Task.isCancelled else { return L(AppOrphanLeftoverScanner.cancelledMessageKey) }
        guard host.isLayoutEditingEnabled, currentCatalog.canPersistReconciledLayout else {
            return L("无法确认应用安装状态，请稍后重试")
        }
        var currentInstalledIDs = Set(currentCatalog.candidates.compactMap { $0.bundleIdentifier })
        currentInstalledIDs.formUnion(host.uninstallCandidates.compactMap { $0.bundleIdentifier })
        if let selfID = Bundle.main.bundleIdentifier { currentInstalledIDs.insert(selfID) }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { currentInstalledIDs.insert(id) }
        }
        let recheck = Task.detached(priority: .utility) {
            AppOrphanLeftoverScanner.discover(
                homeDirectory: home,
                installedBundleIdentifiers: currentInstalledIDs,
                isInstalledElsewhere: {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
                },
                isCancelled: { Task.isCancelled }
            )
        }
        let stillOrphan = await withTaskCancellationHandler {
            await recheck.value
        } onCancel: {
            recheck.cancel()
        }
        guard !Task.isCancelled else { return L(AppOrphanLeftoverScanner.cancelledMessageKey) }
        guard host.isLayoutEditingEnabled else { return "" }
        let stillOrphanPaths = Set(stillOrphan.map(\.url.path))
        guard selected.allSatisfy({ stillOrphanPaths.contains($0.url.path) }) else {
            return L("应用或残留文件已变化，请重新查找后再清理")
        }
        // Capture device+inode for each selected path, then trash off the main
        // actor with a final per-item identity recheck inside the executor.
        let expectedIdentities = AppUninstallEligibility.capturePathIdentities(of: selected)
        guard expectedIdentities.count == selected.count else {
            return L("应用或残留文件已变化，请重新查找后再清理")
        }
        report(AppOrphanLeftoverScanner.trashingProgressMessageKey)
        let selectedForTrash = selected
        let identitiesForTrash = expectedIdentities
        let trashTask = Task.detached(priority: .utility) {
            AppUninstallExecutor.trashRelated(
                selectedForTrash,
                homeDirectory: home,
                expectedIdentities: identitiesForTrash,
                fileManager: FileManager(),
                isCancelled: { Task.isCancelled }
            )
        }
        let moved = await withTaskCancellationHandler {
            await trashTask.value
        } onCancel: {
            trashTask.cancel()
        }
        guard !Task.isCancelled else {
            // Partial trash may have happened; still say cancelled so Settings is not blank.
            if moved.trashed.isEmpty {
                return L(AppOrphanLeftoverScanner.cancelledMessageKey)
            }
            return String(
                format: L("已取消；已移走 %d 项，其余保留"),
                moved.trashed.count
            )
        }
        if moved.failed.isEmpty {
            return String(format: L("已把 %d 项残留文件移到废纸篓，可在废纸篓中放回原处"), moved.trashed.count)
        }
        let names = moved.failed.prefix(3).map { $0.url.lastPathComponent }.joined(separator: ", ")
        return String(
            format: L("已移走 %d 项，%d 项失败（仍在原处）：%@"),
            moved.trashed.count,
            moved.failed.count,
            names
        )
    }

    static func hasOtherInstalledCopy(of candidate: AppCandidate, host: UninstallHost) async -> Bool? {
        guard let bundleID = candidate.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else { return nil }
        let runningCopyURLs = NSWorkspace.shared.runningApplications.compactMap { app -> URL? in
            guard let runningID = app.bundleIdentifier,
                  bundleID.compare(runningID, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
                  !AppUninstallEligibility.runningProcessBelongsToTarget(
                    bundleURL: app.bundleURL,
                    executableURL: app.executableURL,
                    targetURL: candidate.canonicalURL
                  ) else { return nil }
            return app.bundleURL ?? app.executableURL
        }
        let roots = host.uninstallCatalogRoots
        let probe = Task.detached(priority: .utility) {
            let report = await AppCatalogScanner().scanIncludingHiddenApplications(roots: roots)
            let registered = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            return (report, registered + runningCopyURLs)
        }
        let (report, registered) = await withTaskCancellationHandler {
            await probe.value
        } onCancel: {
            probe.cancel()
        }
        guard !Task.isCancelled, report.canPersistReconciledLayout else { return nil }
        return AppUninstallEligibility.hasOtherCopy(
            of: candidate,
            in: report,
            registeredURLs: registered
        )
    }
}

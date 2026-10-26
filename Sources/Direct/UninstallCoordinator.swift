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
        // RELATED-CLEANUP-CONFIRM-COPY-01
        alert.messageText = AppRelatedFileScanner.relatedCleanupConfirmTitle(
            appName: appName,
            localize: { L($0) }
        )
        alert.informativeText = AppRelatedFileScanner.relatedCleanupReviewMessage(localize: { L($0) })
        alert.accessoryView = list
        // Cancel first: Return stays on Cancel; Esc dismisses without trash.
        // Share Core button titles with batch / single-app / orphan confirm.
        alert.addButton(withTitle: AppBatchUninstallPlan.confirmCancelButtonTitle(localize: { L($0) }))
        let trash = alert.addButton(withTitle: AppBatchUninstallPlan.confirmDestructiveButtonTitle(
            anyRunning: false,
            localize: { L($0) }
        ))
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
            toast(host, AppUninstallOutcomeToast.appChanged(localize: { L($0) }), autoDismiss: false)
            return
        }

        host.isPromptingForUninstall = true
        defer {
            host.isPromptingForUninstall = false
            if AppRelatedFileScanner.relatedCleanupRestoresLauncherFocusAfterSheet {
                host.restoreFocusAfterUninstallSheet()
            }
        }
        // UNINSTALL-COPY-CHECK-PROGRESS-01
        let copyCheckMessage = L(AppUninstallCopyCheckProgress.messageKey)
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
        // UNINSTALL-SINGLE-CONFIRM-COPY-01
        alert.messageText = AppUninstallSingleConfirmCopy.title(appName: name, localize: { L($0) })
        alert.informativeText = AppUninstallSingleConfirmCopy.informativeText(
            path: candidate.canonicalURL.path,
            bundleIdentifier: candidate.bundleIdentifier,
            isRunning: !running.isEmpty,
            otherCopy: otherCopy,
            localize: { L($0) }
        )
        alert.accessoryView = relatedToggle
        precondition(AppRelatedFileScanner.relatedCleanupAlertCancelIsFirstButton)
        // Cancel is first so Return does not immediately trash; Esc → Cancel.
        // UNINSTALL-SINGLE-CONFIRM-CHROME-01: share Core button titles with batch confirm.
        alert.addButton(withTitle: AppBatchUninstallPlan.confirmCancelButtonTitle(localize: { L($0) }))
        let trashTitle = AppBatchUninstallPlan.confirmDestructiveButtonTitle(
            anyRunning: !running.isEmpty,
            localize: { L($0) }
        )
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
                    toast(host, AppUninstallOutcomeToast.stillRunning(localize: { L($0) }), autoDismiss: false)
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
            else if !Task.isCancelled { toast(host, AppUninstallOutcomeToast.appChanged(localize: { L($0) }), autoDismiss: false) }
            return
        }
        let finalOtherCopy = await hasOtherInstalledCopy(of: candidate, host: host)
        guard !Task.isCancelled, host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled,
              AppUninstallEligibility.matchesBundleIdentity(bundleIdentity, of: candidate) else { return }
        if !relatedSelection.isEmpty {
            guard finalOtherCopy == false else {
                if !Task.isCancelled {
                    toast(host, AppUninstallOutcomeToast.copiesChanged(localize: { L($0) }), autoDismiss: false)
                }
                return
            }
        }
        guard !Task.isCancelled, host.isLayoutEditingEnabled else { return }
        guard runningApplications(matching: candidate).isEmpty else {
            toast(host, AppUninstallOutcomeToast.stillRunning(localize: { L($0) }), autoDismiss: false)
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
        // UNINSTALL-SINGLE-CONFIRM-CHROME-01
        let progressMessage = L(AppUninstallTrashProgress.messageKey)
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
            // UNINSTALL-OUTCOME-TOASTS-01
            let detail = report.bundleFailure?.detail ?? ""
            guard let message = AppUninstallOutcomeToast.bundleFailedMessage(
                reason: report.bundleFailure?.reason,
                localize: { L($0) }
            ) else { return }
            toast(host, message, help: detail.isEmpty ? nil : detail, autoDismiss: false)
            return
        case .bundleOnly, .bundleAndAllRelated:
            // UNINSTALL-RELATED-RESULT-TOAST-01
            host.applySuccessfulUninstall(
                of: candidate,
                otherCopyMayExist: AppUninstallEligibility.otherCopyMayExistAfterUninstall(probe: finalOtherCopy)
            )
            if let message = report.successToastMessage(localize: { L($0) }) {
                toast(host, message)
            }
        case .partialRelated:
            host.applySuccessfulUninstall(
                of: candidate,
                otherCopyMayExist: AppUninstallEligibility.otherCopyMayExistAfterUninstall(probe: finalOtherCopy)
            )
            if let partial = report.partialRelatedToast(localize: { L($0) }) {
                toast(host, partial.message, help: partial.help, autoDismiss: false)
            }
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
        // ORPHAN-LEFTOVER-CONFIRM-COPY-01
        alert.messageText = AppOrphanLeftoverScanner.confirmTitle(localize: { L($0) })
        alert.informativeText = AppOrphanLeftoverScanner.confirmInformativeText(localize: { L($0) })
        alert.accessoryView = list
        // Cancel first — Return/Esc never trash without an explicit second click.
        // Share Core button titles with batch / single-app confirm.
        alert.addButton(withTitle: AppBatchUninstallPlan.confirmCancelButtonTitle(localize: { L($0) }))
        let trash = alert.addButton(withTitle: AppBatchUninstallPlan.confirmDestructiveButtonTitle(
            anyRunning: false,
            localize: { L($0) }
        ))
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
            // ORPHAN-LEFTOVER-RESULT-TOAST-01
            return AppOrphanLeftoverScanner.catalogUnavailable(localize: { L($0) })
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
            return AppOrphanLeftoverScanner.changedBeforeTrash(localize: { L($0) })
        }
        // Capture device+inode for each selected path, then trash off the main
        // actor with a final per-item identity recheck inside the executor.
        let expectedIdentities = AppUninstallEligibility.capturePathIdentities(of: selected)
        guard expectedIdentities.count == selected.count else {
            return AppOrphanLeftoverScanner.changedBeforeTrash(localize: { L($0) })
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
            // ORPHAN-LEFTOVER-RESULT-TOAST-01
            return AppOrphanLeftoverScanner.cancelledPartialMessage(
                trashedCount: moved.trashed.count,
                localize: { L($0) }
            )
        }
        // ORPHAN-LEFTOVER-RESULT-TOAST-01
        return AppOrphanLeftoverScanner.trashOutcomeMessage(
            trashedCount: moved.trashed.count,
            failedLastPathComponents: moved.failed.map { $0.url.lastPathComponent },
            localize: { L($0) }
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

    // MARK: - Batch uninstall (BATCH-UNINSTALL-WIRE-01)

    /// One confirmation, then sequential quit + trash-only (no related-file
    /// sheets). Must not be called while paging; host dismiss guards still apply.
    static func promptToBatchUninstall(
        _ plan: AppBatchUninstallPlan,
        host: UninstallHost
    ) async {
        guard host.acceptsIconContextMenuAction(), !host.isPromptingForUninstall else { return }
        guard plan.menuPresentation == .enabled, !plan.eligibleCandidates.isEmpty else {
            if case .disabled(let key) = plan.menuPresentation, let key {
                toast(host, L(key))
            }
            return
        }

        host.isPromptingForUninstall = true
        defer {
            host.isPromptingForUninstall = false
            if AppRelatedFileScanner.relatedCleanupRestoresLauncherFocusAfterSheet {
                host.restoreFocusAfterUninstallSheet()
            }
        }

        // BATCH-UNINSTALL-CONFIRM-COPY-01: Core owns confirm informative copy.
        let anyRunning = plan.eligibleCandidates.contains { !runningApplications(matching: $0).isEmpty }
        let info = plan.confirmInformativeText(localize: { L($0) }, anyRunning: anyRunning)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: L(AppBatchUninstallPlan.confirmTitleFormatKey),
            plan.eligibleIDs.count
        )
        alert.informativeText = info
        // Cancel first: Return/Esc stay safe. BATCH-UNINSTALL-CONFIRM-BUTTONS-01
        alert.addButton(withTitle: AppBatchUninstallPlan.confirmCancelButtonTitle(localize: { L($0) }))
        let trashTitle = AppBatchUninstallPlan.confirmDestructiveButtonTitle(anyRunning: anyRunning, localize: { L($0) })
        let trash = alert.addButton(withTitle: trashTitle)
        trash.hasDestructiveAction = true
        alert.layout()

        guard alert.runModal() == .alertSecondButtonReturn, !Task.isCancelled else { return }
        guard host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled else { return }

        var succeeded = 0
        var failed = 0
        let total = plan.eligibleCandidates.count
        for (index, candidate) in plan.eligibleCandidates.enumerated() {
            guard !Task.isCancelled, host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled else {
                break
            }
            // BATCH-UNINSTALL-PROGRESS-NAME-01
            let progress = AppBatchUninstallPlan.progressToastMessage(
                index: index + 1,
                total: total,
                appName: host.displayName(for: candidate),
                localize: { L($0) }
            )
            toast(host, progress, autoDismiss: false)

            let decision = uninstallDecision(for: candidate, host: host)
            guard decision.isAllowed,
                  let bundleIdentity = AppUninstallEligibility.captureBundleIdentity(of: candidate) else {
                clearMatchingProgressToast(host, progress)
                failed += 1
                continue
            }

            let running = runningApplications(matching: candidate)
            if !running.isEmpty {
                let quittingMessage = L(AppUninstallQuitProgress.quittingMessageKey)
                toast(host, quittingMessage, help: L(AppUninstallQuitProgress.quittingAccessibilityHelpKey), autoDismiss: false)
                let quitOK = await quitRunningApplications(running)
                clearMatchingProgressToast(host, quittingMessage)
                guard !Task.isCancelled, host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled else {
                    break
                }
                if !quitOK {
                    guard confirmForceQuitBeforeUninstall() else {
                        failed += 1
                        continue
                    }
                    guard !Task.isCancelled, host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled else {
                        break
                    }
                    let forceOK = await forceQuitRunningApplications(running)
                    guard !Task.isCancelled, host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled else {
                        break
                    }
                    guard forceOK, runningApplications(matching: candidate).isEmpty else {
                        failed += 1
                        continue
                    }
                }
            }

            let recheck = uninstallDecision(for: candidate, host: host)
            guard recheck.isAllowed,
                  AppUninstallEligibility.matchesBundleIdentity(bundleIdentity, of: candidate) else {
                clearMatchingProgressToast(host, progress)
                failed += 1
                continue
            }

            // UNINSTALL-BATCH-OTHER-COPY-01: same other-copy probe as the single
            // path, before trashing, so a surviving copy keeps its layout state.
            let otherCopy = await hasOtherInstalledCopy(of: candidate, host: host)
            guard !Task.isCancelled, host.acceptsIconContextMenuAction(), host.isLayoutEditingEnabled else {
                clearMatchingProgressToast(host, progress)
                break
            }
            guard AppUninstallEligibility.matchesBundleIdentity(bundleIdentity, of: candidate) else {
                clearMatchingProgressToast(host, progress)
                failed += 1
                continue
            }

            toast(host, progress, autoDismiss: false)
            let home = FileManager.default.homeDirectoryForCurrentUser
            let identityForTrash = bundleIdentity
            let candidateForTrash = candidate
            let trashTask = Task.detached(priority: .utility) {
                AppUninstallExecutor.perform(
                    bundleURL: candidateForTrash.canonicalURL,
                    related: [],
                    homeDirectory: home,
                    expectedIdentity: identityForTrash,
                    expectedRelatedIdentities: [],
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
            clearMatchingProgressToast(host, progress)
            guard !Task.isCancelled else { break }
            switch report.outcome {
            case .bundleFailed:
                failed += 1
            case .bundleOnly, .bundleAndAllRelated, .partialRelated:
                host.applySuccessfulUninstall(
                    of: candidate,
                    otherCopyMayExist: AppUninstallEligibility.otherCopyMayExistAfterUninstall(probe: otherCopy)
                )
                succeeded += 1
            }
        }

        host.requestCatalogReloadAfterUninstall()
        guard !Task.isCancelled else { return }
        // BATCH-UNINSTALL-RESULT-TOAST-01 / BATCH-UNINSTALL-REMAINING-01
        let unprocessed = AppBatchUninstallPlan.unprocessedCount(
            total: total,
            succeeded: succeeded,
            failed: failed
        )
        let result = AppBatchUninstallPlan.resultToast(
            succeeded: succeeded,
            failed: failed,
            unprocessed: unprocessed
        )
        if let message = result.message(localize: { L($0) }) {
            let help = result == .success(count: succeeded) ? L(AppUninstallReport.undoHintKey) : nil
            toast(host, message, help: help, autoDismiss: result.autoDismiss)
        }
    }
}

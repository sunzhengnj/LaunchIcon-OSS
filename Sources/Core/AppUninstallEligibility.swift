import Foundation

/// Why an app tile cannot offer genuine uninstall (trash the `.app`).
public enum AppUninstallBlockReason: String, Equatable, Sendable {
    case layoutEditingDisabled
    case missingBundle
    case systemProtected
    case selfApplication
    case parentNotWritable
    case sandboxedBuild
    /// The `.app` sits inside another bundle (helper / bundled app); trashing
    /// it would break the outer application.
    case embeddedInAnotherApp
}

public struct AppUninstallDecision: Equatable, Sendable {
    public let isAllowed: Bool
    public let blockReason: AppUninstallBlockReason?

    public init(allowed: Bool, blockReason: AppUninstallBlockReason? = nil) {
        if allowed {
            self.isAllowed = true
            self.blockReason = nil
        } else {
            self.isAllowed = false
            self.blockReason = blockReason
        }
    }

    /// Localization key for menu tooltips / refusal toasts (`L(...)`).
    public var explanationKey: String? {
        switch blockReason {
        case .layoutEditingDisabled:
            return "暂时无法整理应用，请先完成扫描"
        case .missingBundle:
            return "找不到该应用，可能已被移除"
        case .systemProtected:
            return "系统应用受保护，无法卸载"
        case .selfApplication:
            return "不能卸载 LaunchIcon 自身"
        case .parentNotWritable:
            return "没有权限移除此应用"
        case .sandboxedBuild:
            return AppUninstallPlatform.sandboxedExplanationKey
        case .embeddedInAnotherApp:
            return "该应用属于另一个应用的组成部分，无法单独卸载"
        case nil:
            return nil
        }
    }
}


/// How the tile context menu should expose uninstall.
public enum AppUninstallMenuPresentation: Equatable, Sendable {
    case hidden
    case disabled(explanationKey: String?)
    case enabled
}

/// Distribution-channel policy for real uninstall.
public enum AppUninstallPlatform {
    public static let sandboxedExplanationKey = "App Store 版受沙箱限制，无法卸载应用；请在访达中移除"
    public static let orphanSandboxedExplanationKey = "App Store 版受沙箱限制，无法清理残留文件"

    /// macOS sets `APP_SANDBOX_CONTAINER_ID` for App Sandbox processes.
    public static func isSandboxed(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let id = environment["APP_SANDBOX_CONTAINER_ID"] else { return false }
        return !id.isEmpty
    }

    public static func orphanCleanupAvailable(isSandboxed: Bool) -> Bool { !isSandboxed }
}

/// Force-quit confirmation sheet (after a polite quit fails).
public enum AppUninstallForceQuitAlert {
    /// Cancel is first so Return/Esc never force-quits; destructive confirm is second.
    public static let cancelIsFirstButton = true

    public static let messageTextKey = "应用仍在运行"
    public static let informativeTextKey =
        "无法正常退出。强制退出可能丢失未保存的内容，仍要继续吗？"
    public static let cancelButtonTitleKey = "取消"
    public static let confirmButtonTitleKey = "强制退出并卸载"

    public static let cancelAccessibilityHelpKey = "取消强制退出，保留应用并中止本次卸载"
    public static let confirmAccessibilityHelpKey =
        "强制退出该应用并继续卸载；未保存的内容可能丢失"

    /// Same focus restore policy as related-file sheets (host defer).
    public static let restoresLauncherFocusAfterSheet = true
}

/// Progress copy while a polite terminate() wait runs before trash / force-quit.
public enum AppUninstallQuitProgress {
    public static let quittingMessageKey = "正在退出应用…"
    public static let quittingAccessibilityHelpKey = "正在请求应用退出，随后移到废纸篓"
}

/// Progress copy while trashItem runs (bundle and/or related). UNINSTALL-SINGLE-CONFIRM-CHROME-01
public enum AppUninstallTrashProgress {
    public static let messageKey = "正在移到废纸篓…"
}

/// Progress while scanning for other installed copies. UNINSTALL-COPY-CHECK-PROGRESS-01
public enum AppUninstallCopyCheckProgress {
    public static let messageKey = "正在检查应用副本…"
}

/// Single-app uninstall confirm title + informative body. UNINSTALL-SINGLE-CONFIRM-COPY-01
public enum AppUninstallSingleConfirmCopy {
    public static let titleFormatKey = "卸载“%@”？"
    public static let idleBodyKey = "应用将被移到废纸篓。默认不删除用户数据文件。"
    public static let runningBodyKey = "该应用正在运行。继续前将先尝试退出，再移到废纸篓。默认不删除用户数据文件。"
    public static let otherCopyKnownKey = "发现同一应用的其他副本，相关用户文件将保留。"
    public static let otherCopyUnknownKey = "无法确认是否有其他副本，相关用户文件将保留。"

    public static func title(
        appName: String,
        localize: (String) -> String = { $0 }
    ) -> String {
        String(format: localize(titleFormatKey), appName)
    }

    /// Builds path / optional bundle ID / body / other-copy note.
    /// `otherCopy`: `true` known sibling, `false` none, `nil` unknown.
    public static func informativeText(
        path: String,
        bundleIdentifier: String?,
        isRunning: Bool,
        otherCopy: Bool?,
        localize: (String) -> String = { $0 }
    ) -> String {
        var info = path
        if let bundleID = bundleIdentifier, !bundleID.isEmpty {
            info += "\n" + bundleID
        }
        let bodyKey = isRunning ? runningBodyKey : idleBodyKey
        info += "\n\n" + localize(bodyKey)
        if otherCopy == true {
            info += "\n" + localize(otherCopyKnownKey)
        } else if otherCopy == nil {
            info += "\n" + localize(otherCopyUnknownKey)
        }
        return info
    }
}

/// Abort / failure toasts for single-app uninstall. UNINSTALL-OUTCOME-TOASTS-01
public enum AppUninstallOutcomeToast {
    public static let appChangedKey = "应用已变化，请重新尝试卸载"
    public static let stillRunningKey = "应用仍在运行，未移到废纸篓；请退出后重试"
    public static let copiesChangedKey = "应用副本状态已变化，未移除应用或用户数据；请重新尝试"
    public static let permissionDeniedKey = "没有权限移到废纸篓；应用和用户数据均未改动"
    /// Same copy as batch all-failed; keep one source of truth.
    public static var trashFailedKey: String { AppBatchUninstallPlan.allFailedToastKey }

    public static func appChanged(localize: (String) -> String = { $0 }) -> String {
        localize(appChangedKey)
    }

    public static func stillRunning(localize: (String) -> String = { $0 }) -> String {
        localize(stillRunningKey)
    }

    public static func copiesChanged(localize: (String) -> String = { $0 }) -> String {
        localize(copiesChangedKey)
    }

    /// Message for `.bundleFailed` (nil when cancelled — caller should stay silent).
    public static func bundleFailedMessage(
        reason: AppUninstallFailureReason?,
        localize: (String) -> String = { $0 }
    ) -> String? {
        switch reason {
        case .cancelled:
            return nil
        case .identityMismatch:
            return appChanged(localize: localize)
        case .permissionDenied:
            return localize(permissionDeniedKey)
        default:
            return localize(trashFailedKey)
        }
    }
}

/// Pure eligibility for trashing an application bundle (slice 1).
public struct AppUninstallBundleIdentity: Equatable, Sendable {
    public let systemNumber: UInt64
    public let fileNumber: UInt64
    public let bundleIdentifier: String?
}

/// Device + inode for a single related/orphan path (not just a reusable pathname).
public struct AppUninstallPathIdentity: Equatable, Sendable, Hashable {
    public let path: String
    public let systemNumber: UInt64
    public let fileNumber: UInt64
}

public enum AppUninstallEligibility {
    /// Snapshot the selected directory itself, not just its reusable pathname.
    public static func captureBundleIdentity(
        of candidate: AppCandidate,
        fileManager: FileManager = .default
    ) -> AppUninstallBundleIdentity? {
        let url = candidate.canonicalURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let system = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else { return nil }
        let fresh = AppCatalogScanner.makeCandidate(at: url, sourcePriority: candidate.sourcePriority)
        guard fresh.bundleIdentifier == candidate.bundleIdentifier else { return nil }
        return AppUninstallBundleIdentity(
            systemNumber: system.uint64Value,
            fileNumber: file.uint64Value,
            bundleIdentifier: fresh.bundleIdentifier
        )
    }

    public static func matchesBundleIdentity(
        _ identity: AppUninstallBundleIdentity,
        of candidate: AppCandidate,
        fileManager: FileManager = .default
    ) -> Bool {
        captureBundleIdentity(of: candidate, fileManager: fileManager) == identity
    }

    public static func capturePathIdentity(
        of url: URL,
        fileManager: FileManager = .default
    ) -> AppUninstallPathIdentity? {
        let standardized = url.resolvingSymlinksInPath().standardizedFileURL
        guard fileManager.fileExists(atPath: standardized.path),
              let attributes = try? fileManager.attributesOfItem(atPath: standardized.path),
              let system = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return AppUninstallPathIdentity(
            path: standardized.path,
            systemNumber: system.uint64Value,
            fileNumber: file.uint64Value
        )
    }

    public static func matchesPathIdentity(
        _ identity: AppUninstallPathIdentity,
        fileManager: FileManager = .default
    ) -> Bool {
        capturePathIdentity(of: URL(fileURLWithPath: identity.path), fileManager: fileManager) == identity
    }

    public static func capturePathIdentities(
        of files: [AppRelatedFileCandidate],
        fileManager: FileManager = .default
    ) -> [AppUninstallPathIdentity] {
        files.compactMap { capturePathIdentity(of: $0.url, fileManager: fileManager) }
    }

    /// The catalog keeps one tile per bundle ID, so inspect its hidden copies
    /// as well as Launch Services registrations before offering data cleanup.
    public static func hasOtherCopy(
        of candidate: AppCandidate,
        in report: CatalogScanReport,
        registeredURLs: [URL]
    ) -> Bool {
        guard let bundleID = candidate.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else { return false }
        let target = candidate.canonicalURL.resolvingSymlinksInPath().standardizedFileURL
        let catalogCopy = (report.candidates + report.duplicateCandidates).contains { other in
            guard let otherID = other.bundleIdentifier,
                  bundleID.compare(otherID, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else {
                return false
            }
            return other.canonicalURL.resolvingSymlinksInPath().standardizedFileURL != target
        }
        return catalogCopy || registeredURLs.contains {
            $0.resolvingSymlinksInPath().standardizedFileURL != target
        }
    }

    /// UNINSTALL-BATCH-OTHER-COPY-01: layout state (position / folder / alias /
    /// hidden) is forgotten only when the copy probe positively found no other
    /// installed copy. `nil` (probe unknown / incomplete scan) keeps state, so a
    /// surviving copy in /Applications vs ~/Applications never loses its tile.
    /// Single and batch uninstall must both route through this.
    public static func otherCopyMayExistAfterUninstall(probe: Bool?) -> Bool {
        probe != false
    }

    /// UNINSTALL-BATCH-OTHER-COPY-02: the in-memory catalog after a successful
    /// trash. When another copy may survive, keep its entry so a later forget +
    /// reconcile in the same batch (or before the catalog reload lands) does not
    /// drop the surviving tile's ID, slot, folder, alias or hidden state.
    public static func catalogAfterUninstall(
        _ candidates: [AppCandidate],
        removing candidate: AppCandidate,
        otherCopyMayExist: Bool
    ) -> [AppCandidate] {
        guard !otherCopyMayExist else { return candidates }
        let key = candidate.deduplicationKey
        return candidates.filter { $0.deduplicationKey != key }
    }

    /// Bundle-ID equality alone may refer to a different installed copy.
    /// A nested login item or helper belongs to the selected bundle.
    public static func runningProcessBelongsToTarget(
        bundleURL: URL?,
        executableURL: URL?,
        targetURL: URL
    ) -> Bool {
        let targetPath = targetURL.resolvingSymlinksInPath().standardizedFileURL.path
        func isInside(_ url: URL?) -> Bool {
            guard let url else { return false }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            return path == targetPath || path.hasPrefix(targetPath + "/")
        }
        return isInside(bundleURL) || isInside(executableURL)
    }

    /// Context-menu presentation: when layout is read-only (incomplete scan /
    /// loading), show uninstall disabled with an explanation so VoiceOver and
    /// tooltips explain the block. Otherwise enabled or disabled per decision.
    public static func menuPresentation(
        layoutEditingEnabled: Bool,
        decision: AppUninstallDecision
    ) -> AppUninstallMenuPresentation {
        if !layoutEditingEnabled {
            let key = decision.explanationKey
                ?? AppUninstallDecision(
                    allowed: false,
                    blockReason: .layoutEditingDisabled
                ).explanationKey
            return .disabled(explanationKey: key)
        }
        if decision.isAllowed { return .enabled }
        return .disabled(explanationKey: decision.explanationKey)
    }

    /// Paths under `/System/` (including Cryptex Applications) are SIP-protected.
    public static func isSystemProtectedPath(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        return standardized == "/System" || standardized.hasPrefix("/System/")
    }

    public static func evaluate(
        candidate: AppCandidate,
        layoutEditingEnabled: Bool,
        selfBundleURL: URL?,
        selfBundleIdentifier: String?,
        isSandboxed: Bool = AppUninstallPlatform.isSandboxed(),
        fileManager: FileManager = .default
    ) -> AppUninstallDecision {
        guard layoutEditingEnabled else {
            return AppUninstallDecision(allowed: false, blockReason: .layoutEditingDisabled)
        }
        // App Store / sandboxed builds cannot trash other apps' bundles and
        // we never widen entitlements: explain instead of failing late.
        guard !isSandboxed else {
            return AppUninstallDecision(allowed: false, blockReason: .sandboxedBuild)
        }

        let url = candidate.canonicalURL.resolvingSymlinksInPath().standardizedFileURL
        let path = url.path

        if isSystemProtectedPath(path) {
            return AppUninstallDecision(allowed: false, blockReason: .systemProtected)
        }

        if isEmbeddedInAnotherBundle(path) {
            return AppUninstallDecision(allowed: false, blockReason: .embeddedInAnotherApp)
        }

        if isSelfApplication(
            candidateURL: url,
            candidateBundleID: candidate.bundleIdentifier,
            selfBundleURL: selfBundleURL,
            selfBundleIdentifier: selfBundleIdentifier
        ) {
            return AppUninstallDecision(allowed: false, blockReason: .selfApplication)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return AppUninstallDecision(allowed: false, blockReason: .missingBundle)
        }

        // Apple apps outside /System (e.g. /Applications/Safari.app) are
        // SIP-restricted: the trash call would only fail late.
        if isSIPRestricted(path) {
            return AppUninstallDecision(allowed: false, blockReason: .systemProtected)
        }

        let parent = url.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: parent) else {
            return AppUninstallDecision(allowed: false, blockReason: .parentNotWritable)
        }

        return AppUninstallDecision(allowed: true)
    }

    /// True when any ancestor directory is itself a bundle (`*.app`, also
    /// `.framework` / `.appex` / `.bundle` containers that ship nested apps).
    public static func isEmbeddedInAnotherBundle(_ path: String) -> Bool {
        let components = (path as NSString).standardizingPath.split(separator: "/").dropLast()
        let bundleExtensions: Set<String> = ["app", "framework", "appex", "bundle", "xpc", "plugin"]
        return components.contains { component in
            let ext = (String(component) as NSString).pathExtension.lowercased()
            return bundleExtensions.contains(ext)
        }
    }

    /// `SF_RESTRICTED` (SIP) on the bundle directory itself. Symlinks are not
    /// followed; callers pass the already-resolved path.
    public static func isSIPRestricted(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_flags & 0x0008_0000) != 0
    }

    public static func isSelfApplication(
        candidateURL: URL,
        candidateBundleID: String?,
        selfBundleURL: URL?,
        selfBundleIdentifier: String?
    ) -> Bool {
        if let selfID = selfBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selfID.isEmpty,
           let candidateID = candidateBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidateID.isEmpty,
           selfID.compare(candidateID, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }
        guard let selfBundleURL else { return false }
        let selfURL = selfBundleURL.resolvingSymlinksInPath().standardizedFileURL
        return selfURL == candidateURL.resolvingSymlinksInPath().standardizedFileURL
    }
}

/// Moves a `.app` bundle (or any single item) to the Trash via public API.
public enum AppBundleUninstaller {
    public static func trashApplicationBundle(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        var resulting: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resulting)
        if let resulting {
            return resulting as URL
        }
        return url
    }
}

/// Why one related path was not moved to the Trash.
public enum AppUninstallFailureReason: String, Equatable, Sendable {
    case permissionDenied
    case unsafePath
    case missing
    case identityMismatch
    case cancelled
    case other

    /// Short label for related-file failure help lines. UNINSTALL-RELATED-RESULT-TOAST-01
    public var relatedLabelKey: String? {
        switch self {
        case .permissionDenied: return "没有权限"
        case .unsafePath: return "路径不安全，已跳过"
        case .missing: return "已不存在"
        case .identityMismatch: return "路径已变化"
        case .cancelled: return "已取消"
        case .other: return nil
        }
    }

    public static func classify(_ error: Error) -> AppUninstallFailureReason {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return .permissionDenied
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .missing
            default:
                break
            }
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EACCES) || ns.code == Int(EPERM) {
            return .permissionDenied
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error,
           classify(underlying) == .permissionDenied {
            return .permissionDenied
        }
        return .other
    }
}

public struct AppUninstallFailure: Equatable, Sendable {
    public let url: URL
    public let reason: AppUninstallFailureReason
    public let detail: String
}

public enum AppUninstallOutcome: Equatable, Sendable {
    /// App is still installed; nothing else was touched.
    case bundleFailed
    case bundleOnly
    case bundleAndAllRelated
    /// App trashed, but at least one related item stayed behind.
    case partialRelated
}

/// Result of one uninstall run: everything that moved and everything that did not.
public struct AppUninstallReport: Equatable, Sendable {
    public let bundleTrashed: Bool
    public let bundleFailure: AppUninstallFailure?
    public let trashedRelated: [URL]
    public let failedRelated: [AppUninstallFailure]

    /// Shown with every success so users know items are recoverable.
    public static let undoHintKey = "已移到废纸篓，可在废纸篓中放回原处"
    /// UNINSTALL-RELATED-RESULT-TOAST-01
    public static let relatedSuccessFormatKey = "已移到废纸篓（含 %d 项相关文件），可在废纸篓中放回原处"
    public static let partialRelatedFormatKey = "应用已移到废纸篓；%d 项相关文件已移走，%d 项失败（仍在原处）"

    public var outcome: AppUninstallOutcome {
        guard bundleTrashed else { return .bundleFailed }
        if !failedRelated.isEmpty { return .partialRelated }
        return trashedRelated.isEmpty ? .bundleOnly : .bundleAndAllRelated
    }

    /// One line per failed path: `name — reason`, for the persistent toast help.
    public var failureLines: [String] {
        failedRelated.map { "\($0.url.lastPathComponent) — \($0.reason.rawValue)" }
    }

    /// Localized success toast for `.bundleOnly` / `.bundleAndAllRelated`. UNINSTALL-RELATED-RESULT-TOAST-01
    public func successToastMessage(localize: (String) -> String = { $0 }) -> String? {
        switch outcome {
        case .bundleOnly:
            return localize(Self.undoHintKey)
        case .bundleAndAllRelated:
            return String(format: localize(Self.relatedSuccessFormatKey), trashedRelated.count)
        default:
            return nil
        }
    }

    /// Localized title + help for `.partialRelated`.
    public func partialRelatedToast(
        localize: (String) -> String = { $0 }
    ) -> (message: String, help: String)? {
        guard outcome == .partialRelated else { return nil }
        let message = String(
            format: localize(Self.partialRelatedFormatKey),
            trashedRelated.count,
            failedRelated.count
        )
        let help = failedRelated.map { failure -> String in
            let why: String
            if let key = failure.reason.relatedLabelKey {
                why = localize(key)
            } else {
                why = failure.detail
            }
            return "\(failure.url.path) — \(why)"
        }.joined(separator: "\n")
        return (message, help)
    }
}

/// Runs the destructive part of uninstall with explicit per-item accounting.
/// Callers that may block the UI should run these helpers off the main actor
/// (e.g. `Task.detached`) and pass `isCancelled` / identity snapshots so work
/// stops promptly and refuses a swapped bundle.
public enum AppUninstallExecutor {
    public typealias Trasher = (URL) throws -> URL

    public static func perform(
        bundleURL: URL,
        related: [AppRelatedFileCandidate],
        homeDirectory: URL,
        expectedIdentity: AppUninstallBundleIdentity? = nil,
        expectedRelatedIdentities: [AppUninstallPathIdentity] = [],
        candidate: AppCandidate? = nil,
        fileManager: FileManager = .default,
        trash: Trasher? = nil,
        isCancelled: () -> Bool = { false }
    ) -> AppUninstallReport {
        let trasher: Trasher = trash ?? { try AppBundleUninstaller.trashApplicationBundle(at: $0, fileManager: fileManager) }
        if isCancelled() {
            return AppUninstallReport(
                bundleTrashed: false,
                bundleFailure: AppUninstallFailure(
                    url: bundleURL,
                    reason: .cancelled,
                    detail: "cancelled"
                ),
                trashedRelated: [],
                failedRelated: []
            )
        }
        // Final identity gate: as close as possible to the first trashItem.
        if let expectedIdentity, let candidate {
            guard AppUninstallEligibility.matchesBundleIdentity(
                expectedIdentity,
                of: candidate,
                fileManager: fileManager
            ) else {
                return AppUninstallReport(
                    bundleTrashed: false,
                    bundleFailure: AppUninstallFailure(
                        url: bundleURL,
                        reason: .identityMismatch,
                        detail: "identity changed"
                    ),
                    trashedRelated: [],
                    failedRelated: []
                )
            }
        }
        do {
            _ = try trasher(bundleURL)
        } catch {
            // Bundle first: if it cannot move, leave user data untouched.
            return AppUninstallReport(
                bundleTrashed: false,
                bundleFailure: AppUninstallFailure(
                    url: bundleURL,
                    reason: AppUninstallFailureReason.classify(error),
                    detail: error.localizedDescription
                ),
                trashedRelated: [],
                failedRelated: []
            )
        }
        // Related paths: same final device+inode gate as orphan leftovers when
        // the caller captured identities at confirm→trash boundary.
        let moved = trashRelated(
            related,
            homeDirectory: homeDirectory,
            expectedIdentities: expectedRelatedIdentities,
            fileManager: fileManager,
            trash: trasher,
            isCancelled: isCancelled
        )
        return AppUninstallReport(
            bundleTrashed: true,
            bundleFailure: nil,
            trashedRelated: moved.trashed,
            failedRelated: moved.failed
        )
    }

    /// Moves only items that pass the Library safety gate; reports each result.
    /// When `expectedIdentities` is non-empty, each item must still match its
    /// device+inode snapshot immediately before that item is trashed.
    public static func trashRelated(
        _ items: [AppRelatedFileCandidate],
        homeDirectory: URL,
        expectedIdentities: [AppUninstallPathIdentity] = [],
        fileManager: FileManager = .default,
        trash: Trasher? = nil,
        isCancelled: () -> Bool = { false }
    ) -> (trashed: [URL], failed: [AppUninstallFailure]) {
        let trasher: Trasher = trash ?? { try AppBundleUninstaller.trashApplicationBundle(at: $0, fileManager: fileManager) }
        let identityByPath = Dictionary(uniqueKeysWithValues: expectedIdentities.map { ($0.path, $0) })
        var trashed: [URL] = []
        var failed: [AppUninstallFailure] = []
        for (index, item) in items.enumerated() {
            if isCancelled() {
                // Account for this item and every remaining one — no silent drop.
                for leftover in items[index...] {
                    failed.append(AppUninstallFailure(url: leftover.url, reason: .cancelled, detail: "cancelled"))
                }
                break
            }
            guard AppRelatedFileSafety.isSafeToTrash(
                item.url,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ) else {
                failed.append(AppUninstallFailure(url: item.url, reason: .unsafePath, detail: "unsafe path"))
                continue
            }
            let standardized = item.url.resolvingSymlinksInPath().standardizedFileURL
            if let expected = identityByPath[standardized.path] {
                guard AppUninstallEligibility.matchesPathIdentity(expected, fileManager: fileManager) else {
                    failed.append(AppUninstallFailure(
                        url: item.url,
                        reason: .identityMismatch,
                        detail: "identity changed"
                    ))
                    continue
                }
            } else if !identityByPath.isEmpty {
                // Snapshot was required but this path was not in it — refuse.
                failed.append(AppUninstallFailure(
                    url: item.url,
                    reason: .identityMismatch,
                    detail: "not in confirmed set"
                ))
                continue
            }
            do {
                _ = try trasher(item.url)
                trashed.append(item.url)
            } catch {
                failed.append(AppUninstallFailure(
                    url: item.url,
                    reason: AppUninstallFailureReason.classify(error),
                    detail: error.localizedDescription
                ))
            }
        }
        return (trashed, failed)
    }
}

/// Multi-select「卸载 N 个应用」(BATCH-UNINSTALL-PLAN / WIRE / NAMES / BLOCKED-NAMES).
///
/// Rules:
/// - Only when the right-clicked app is part of a selection of ≥ 2 items;
///   otherwise the single-app flow applies (`plan` returns nil).
/// - Folders in the selection are skipped, never expanded: uninstalling a
///   folder's contents must be an explicit choice per app.
/// - Every app goes through the same `AppUninstallDecision` as a single
///   uninstall; blocked apps are listed with their reason and skipped.
/// - Duplicate tiles for the same app (same dedup key) count once.
/// - More than `maximumCount` eligible apps refuses the batch outright
///   rather than silently truncating.
public struct AppBatchUninstallPlan: Equatable, Sendable {
    public struct Blocked: Equatable, Sendable {
        public let appID: UUID
        public let displayName: String
        public let reason: AppUninstallBlockReason?
    }

    public static let maximumCount = 20
    public static let menuTitleFormatKey = "卸载 %d 个应用…"
    public static let confirmTitleFormatKey = "要将 %d 个应用移到废纸篓吗？"
    public static let skippedSummaryFormatKey = "%d 项无法卸载，将被跳过"
    public static let noneEligibleExplanationKey = "所选应用都无法卸载"
    public static let tooManyExplanationKey = "一次最多卸载 20 个应用"

    /// Apps to trash, selection order.
    public let eligibleIDs: [UUID]
    public let eligibleCandidates: [AppCandidate]
    public let blocked: [Blocked]
    public let skippedFolderCount: Int
    /// App tiles whose catalog entry is gone (stale layout id).
    public let missingCount: Int

    public var skippedCount: Int { blocked.count + skippedFolderCount + missingCount }
    public var exceedsLimit: Bool { eligibleIDs.count > Self.maximumCount }

    public var menuPresentation: AppUninstallMenuPresentation {
        if eligibleIDs.isEmpty {
            let reasons = Set(blocked.map(\.reason))
            if reasons.count == 1, let only = reasons.first, let reason = only {
                return .disabled(explanationKey: AppUninstallDecision(allowed: false, blockReason: reason).explanationKey)
            }
            return .disabled(explanationKey: Self.noneEligibleExplanationKey)
        }
        if exceedsLimit { return .disabled(explanationKey: Self.tooManyExplanationKey) }
        return .enabled
    }

    public static func plan(
        selection: LauncherItemSelection,
        anchorID: UUID,
        in state: LayoutState,
        candidatesByKey: [String: AppCandidate],
        decide: (AppCandidate) -> AppUninstallDecision
    ) -> AppBatchUninstallPlan? {
        guard selection.count >= 2, selection.contains(anchorID) else { return nil }
        var ids: [UUID] = []
        var candidates: [AppCandidate] = []
        var blocked: [Blocked] = []
        var folders = 0
        var missing = 0
        var seenKeys = Set<String>()
        for id in selection.orderedIDs {
            if state.folders[id] != nil {
                folders += 1
                continue
            }
            guard let key = state.appKeys[id], let candidate = candidatesByKey[key] else {
                missing += 1
                continue
            }
            guard seenKeys.insert(candidate.deduplicationKey).inserted else { continue }
            let decision = decide(candidate)
            if decision.isAllowed {
                ids.append(id)
                candidates.append(candidate)
            } else {
                let trimmed = candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = trimmed.isEmpty
                    ? candidate.canonicalURL.deletingPathExtension().lastPathComponent
                    : trimmed
                blocked.append(Blocked(appID: id, displayName: name, reason: decision.blockReason))
            }
        }
        return AppBatchUninstallPlan(
            eligibleIDs: ids,
            eligibleCandidates: candidates,
            blocked: blocked,
            skippedFolderCount: folders,
            missingCount: missing
        )
    }
}

// MARK: - Confirmation copy helpers (NAMES + BLOCKED-NAMES + BLOCKED-REASONS)

extension AppBatchUninstallPlan {
    public static let nameListLimit = 5
    public static let nameListSeparator = "、"
    /// `%@` = first names joined by `nameListSeparator`, `%d` = total count.
    public static let nameListOverflowFormatKey = "%@ 等 %d 个应用"
    /// BATCH-UNINSTALL-BLOCKED-NAMES-01: listed under the skipped count line.
    public static let blockedNameListFormatKey = "无法卸载：%@"
    public static let blockedNameListOverflowFormatKey = "无法卸载：%@ 等 %d 个"
    /// BATCH-UNINSTALL-BLOCKED-REASONS-01: "%@" = localized reason, "%d" = count.
    public static let blockedReasonCountFormatKey = "%@ ×%d"
    public static let blockedReasonListSeparator = "、"
    /// BATCH-UNINSTALL-CONFIRM-COPY-01
    public static let userDataDisclaimerKey = "批量卸载不会删除用户数据文件。"
    public static let quitBeforeTrashKey = "继续前将先尝试退出仍在运行的应用，再移到废纸篓。"
    /// BATCH-UNINSTALL-RESULT-TOAST-01
    public static let successToastFormatKey = "已卸载 %d 个应用"
    public static let partialToastFormatKey = "已卸载 %d 个应用，%d 个失败"
    public static let allFailedToastKey = "无法移到废纸篓；应用和用户数据均未改动"
    /// BATCH-UNINSTALL-REMAINING-01: mid-batch stop (hide / cancel / edit lock).
    public static let interruptedSuccessFormatKey = "已卸载 %d 个应用，%d 个未处理"
    public static let interruptedPartialFormatKey = "已卸载 %d 个应用，%d 个失败，%d 个未处理"
    public static let interruptedFailedFormatKey = "%d 个失败，%d 个未处理"
    public static let interruptedOnlyFormatKey = "%d 个未处理"
    /// BATCH-UNINSTALL-PROGRESS-TOAST-01
    public static let progressToastFormatKey = "正在卸载 %d / %d…"
    /// BATCH-UNINSTALL-PROGRESS-NAME-01
    public static let progressToastWithNameFormatKey = "正在卸载 %d / %d：%@"
    /// BATCH-UNINSTALL-CONFIRM-BUTTONS-01
    public static let cancelButtonTitleKey = "取消"
    public static let trashButtonTitleKey = "移到废纸篓"
    public static let quitAndTrashButtonTitleKey = "退出并移到废纸篓"

    public struct NameList: Equatable, Sendable {
        public let shown: [String]
        public let totalCount: Int
        public var isTruncated: Bool { totalCount > shown.count }
        /// Joined names; when truncated, Direct wraps this in `nameListOverflowFormatKey`.
        public var joined: String { shown.joined(separator: AppBatchUninstallPlan.nameListSeparator) }
    }

    /// Names in selection order, trimmed, blank names replaced by the bundle file name.
    public static func nameList(_ candidates: [AppCandidate], limit: Int = nameListLimit) -> NameList {
        let names = candidates.map { candidate -> String in
            let trimmed = candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? candidate.canonicalURL.deletingPathExtension().lastPathComponent : trimmed
        }
        return NameList(shown: Array(names.prefix(max(0, limit))), totalCount: names.count)
    }

    public var eligibleNameList: NameList { Self.nameList(eligibleCandidates) }

    public var blockedNameList: NameList {
        // Names are normalized when Blocked is built (same empty→bundle fallback as eligible).
        NameList(shown: Array(blocked.map(\.displayName).prefix(Self.nameListLimit)), totalCount: blocked.count)
    }

    /// Localized reason × count lines for the confirm sheet (stable reason order).
    /// BATCH-UNINSTALL-BLOCKED-REASONS-01.
    public func blockedReasonSummary(
        localize: (String) -> String = { $0 }
    ) -> String? {
        guard !blocked.isEmpty else { return nil }
        var counts: [(key: String, count: Int)] = []
        var index: [String: Int] = [:]
        for item in blocked {
            let decision = AppUninstallDecision(allowed: false, blockReason: item.reason)
            let key = decision.explanationKey ?? Self.noneEligibleExplanationKey
            if let i = index[key] {
                counts[i].count += 1
            } else {
                index[key] = counts.count
                counts.append((key, 1))
            }
        }
        let parts = counts.map { entry in
            String(
                format: Self.blockedReasonCountFormatKey,
                localize(entry.key),
                entry.count
            )
        }
        return parts.joined(separator: Self.blockedReasonListSeparator)
    }

    /// Full confirm sheet informative text (eligible names, skipped, blocked names/reasons, disclaimer).
    /// BATCH-UNINSTALL-CONFIRM-COPY-01 — keeps Direct from assembling copy ad hoc.
    public func confirmInformativeText(
        localize: (String) -> String = { $0 },
        anyRunning: Bool
    ) -> String {
        let names = eligibleNameList
        let nameLine: String
        if names.isTruncated {
            nameLine = String(
                format: localize(Self.nameListOverflowFormatKey),
                names.joined,
                names.totalCount
            )
        } else {
            nameLine = names.joined
        }
        var info = nameLine
        if skippedCount > 0 {
            info += "\n" + String(
                format: localize(Self.skippedSummaryFormatKey),
                skippedCount
            )
            let blockedNames = blockedNameList
            if blockedNames.totalCount > 0 {
                if blockedNames.isTruncated {
                    info += "\n" + String(
                        format: localize(Self.blockedNameListOverflowFormatKey),
                        blockedNames.joined,
                        blockedNames.totalCount
                    )
                } else {
                    info += "\n" + String(
                        format: localize(Self.blockedNameListFormatKey),
                        blockedNames.joined
                    )
                }
                if let reasons = blockedReasonSummary(localize: localize) {
                    info += "\n" + reasons
                }
            }
        }
        info += "\n\n" + localize(Self.userDataDisclaimerKey)
        if anyRunning {
            info += "\n" + localize(Self.quitBeforeTrashKey)
        }
        return info
    }

    /// Result toast after sequential batch trash. BATCH-UNINSTALL-RESULT-TOAST-01.
    public enum BatchResultToast: Equatable, Sendable {
        case success(count: Int)
        case partial(succeeded: Int, failed: Int)
        /// Batch stopped before every eligible app was attempted.
        case interrupted(succeeded: Int, failed: Int, unprocessed: Int)
        case allFailed
        case none

        public var autoDismiss: Bool {
            switch self {
            case .success: return true
            case .partial, .interrupted, .allFailed: return false
            case .none: return true
            }
        }

        public func message(localize: (String) -> String = { $0 }) -> String? {
            switch self {
            case .success(let count):
                return String(format: localize(AppBatchUninstallPlan.successToastFormatKey), count)
            case .partial(let succeeded, let failed):
                return String(
                    format: localize(AppBatchUninstallPlan.partialToastFormatKey),
                    succeeded,
                    failed
                )
            case .interrupted(let succeeded, let failed, let unprocessed):
                precondition(unprocessed > 0)
                if succeeded > 0, failed == 0 {
                    return String(
                        format: localize(AppBatchUninstallPlan.interruptedSuccessFormatKey),
                        succeeded,
                        unprocessed
                    )
                }
                if succeeded > 0, failed > 0 {
                    return String(
                        format: localize(AppBatchUninstallPlan.interruptedPartialFormatKey),
                        succeeded,
                        failed,
                        unprocessed
                    )
                }
                if failed > 0 {
                    return String(
                        format: localize(AppBatchUninstallPlan.interruptedFailedFormatKey),
                        failed,
                        unprocessed
                    )
                }
                return String(
                    format: localize(AppBatchUninstallPlan.interruptedOnlyFormatKey),
                    unprocessed
                )
            case .allFailed:
                return localize(AppBatchUninstallPlan.allFailedToastKey)
            case .none:
                return nil
            }
        }
    }


    public static func progressToastMessage(
        index: Int,
        total: Int,
        localize: (String) -> String = { $0 }
    ) -> String {
        String(format: localize(progressToastFormatKey), index, total)
    }

    /// Prefers named form when `appName` is non-blank after trim. BATCH-UNINSTALL-PROGRESS-NAME-01
    public static func progressToastMessage(
        index: Int,
        total: Int,
        appName: String,
        localize: (String) -> String = { $0 }
    ) -> String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return progressToastMessage(index: index, total: total, localize: localize)
        }
        return String(format: localize(progressToastWithNameFormatKey), index, total, trimmed)
    }

    /// Cancel is always first so Return/Esc stay safe. BATCH-UNINSTALL-CONFIRM-BUTTONS-01
    public static func confirmCancelButtonTitle(
        localize: (String) -> String = { $0 }
    ) -> String {
        localize(cancelButtonTitleKey)
    }

    public static func confirmDestructiveButtonTitle(
        anyRunning: Bool,
        localize: (String) -> String = { $0 }
    ) -> String {
        localize(anyRunning ? quitAndTrashButtonTitleKey : trashButtonTitleKey)
    }

    /// `unprocessed` counts eligible apps never attempted because the batch
    /// stopped early (launcher hide, edit lock, cancellation). BATCH-UNINSTALL-REMAINING-01
    public static func resultToast(succeeded: Int, failed: Int, unprocessed: Int = 0) -> BatchResultToast {
        let s = max(0, succeeded)
        let f = max(0, failed)
        let u = max(0, unprocessed)
        if u > 0 {
            return .interrupted(succeeded: s, failed: f, unprocessed: u)
        }
        if f == 0, s > 0 { return .success(count: s) }
        if s > 0 { return .partial(succeeded: s, failed: f) }
        if f > 0 { return .allFailed }
        return .none
    }

    /// Eligible left unfinished after a mid-batch stop. Never negative.
    public static func unprocessedCount(total: Int, succeeded: Int, failed: Int) -> Int {
        max(0, total - max(0, succeeded) - max(0, failed))
    }
}


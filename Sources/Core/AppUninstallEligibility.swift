import Foundation

/// Why an app tile cannot offer genuine uninstall (trash the `.app`).
public enum AppUninstallBlockReason: String, Equatable, Sendable {
    case layoutEditingDisabled
    case missingBundle
    case systemProtected
    case selfApplication
    case parentNotWritable
    case sandboxedBuild
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

        let parent = url.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: parent) else {
            return AppUninstallDecision(allowed: false, blockReason: .parentNotWritable)
        }

        return AppUninstallDecision(allowed: true)
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

    public var outcome: AppUninstallOutcome {
        guard bundleTrashed else { return .bundleFailed }
        if !failedRelated.isEmpty { return .partialRelated }
        return trashedRelated.isEmpty ? .bundleOnly : .bundleAndAllRelated
    }

    /// One line per failed path: `name — reason`, for the persistent toast help.
    public var failureLines: [String] {
        failedRelated.map { "\($0.url.lastPathComponent) — \($0.reason.rawValue)" }
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

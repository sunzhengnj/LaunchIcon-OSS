import Foundation

/// A user-domain support file/folder that may be trashed with an app (opt-in).
public struct AppRelatedFileCandidate: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case applicationSupport
        case preferences
        case caches
        case containers
        case groupContainers
        case logs
        case savedState
        case launchAgents
        case httpStorages
        case webKit
        case crashReporter
    }

    public var id: String { url.path }
    public let url: URL
    public let kind: Kind
    public let byteSize: UInt64?

    public init(url: URL, kind: Kind, byteSize: UInt64? = nil) {
        self.url = url
        self.kind = kind
        self.byteSize = byteSize
    }
}

/// Discovers related files under the current user's Library. Bundle-ID first;
/// package-name fallback only for unambiguous Application Support folders.
public enum AppRelatedFileScanner {
    /// Localization key when related cleanup was requested but nothing matched.
    public static let emptyRelatedFilesMessageKey = "未发现可清理的相关用户文件"
    /// Progress / cancel copy for the single-app related-files path (parity with leftovers).
    public static let scanningProgressMessageKey = "正在查找相关文件…"
    public static let recheckingProgressMessageKey = "正在确认相关文件…"
    public static let cancelledMessageKey = "已取消相关文件清理"
    public static let changedBeforeTrashMessageKey = "应用或相关文件已变化，未移到废纸篓；请重新尝试"

    /// True when every confirmed selection path is still present in a fresh discover.
    public static func relatedCleanupSelectionStillValid(
        selected: [AppRelatedFileCandidate],
        rediscovered: [AppRelatedFileCandidate]
    ) -> Bool {
        guard !selected.isEmpty else { return true }
        let still = Set(
            rediscovered.map {
                $0.url.resolvingSymlinksInPath().standardizedFileURL.path
            }
        )
        return selected.allSatisfy {
            still.contains($0.url.resolvingSymlinksInPath().standardizedFileURL.path)
        }
    }

    public static func discover(
        candidate: AppCandidate,
        homeDirectory: URL,
        isCancelled: () -> Bool = { false },
        fileManager: FileManager = .default
    ) -> [AppRelatedFileCandidate] {
        guard !isCancelled() else { return [] }
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        guard fileManager.fileExists(atPath: library.path) else { return [] }

        let bundleID = usableBundleID(candidate.bundleIdentifier)
        let packageName = candidate.canonicalURL.deletingPathExtension().lastPathComponent
        var found: [AppRelatedFileCandidate] = []
        var seen = Set<String>()

        let libraryRoot = library.resolvingSymlinksInPath().standardizedFileURL
        func append(_ url: URL, kind: AppRelatedFileCandidate.Kind) {
            guard !isCancelled() else { return }
            guard AppRelatedFileSafety.isSafeToTrash(
                url,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ) else { return }
            let standardized = url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent).standardizedFileURL
            let path = standardized.path
            guard path.hasPrefix(libraryRoot.path + "/") else { return }
            guard !seen.contains(path) else { return }
            guard fileManager.fileExists(atPath: path) else { return }
            seen.insert(path)
            found.append(
                AppRelatedFileCandidate(
                    url: standardized,
                    kind: kind,
                    byteSize: kind == .containers || kind == .groupContainers
                        ? nil : approximateSize(
                            of: standardized, fileManager: fileManager, isCancelled: isCancelled
                        )
                )
            )
        }

        if let bundleID {
            append(
                library.appendingPathComponent("Application Support/\(bundleID)", isDirectory: true),
                kind: .applicationSupport
            )
            append(
                library.appendingPathComponent("Preferences/\(bundleID).plist", isDirectory: false),
                kind: .preferences
            )
            append(
                library.appendingPathComponent("Caches/\(bundleID)", isDirectory: true),
                kind: .caches
            )
            append(
                library.appendingPathComponent("Containers/\(bundleID)", isDirectory: true),
                kind: .containers
            )
            append(
                library.appendingPathComponent(
                    "Saved Application State/\(bundleID).savedState",
                    isDirectory: true
                ),
                kind: .savedState
            )
            append(
                library.appendingPathComponent("Logs/\(bundleID)", isDirectory: true),
                kind: .logs
            )

            let groupRoot = library.appendingPathComponent("Group Containers", isDirectory: true)
            if let contents = try? fileManager.contentsOfDirectory(
                at: groupRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for item in contents where nameMatchesBundleID(item.lastPathComponent, bundleID: bundleID, allowsTeamPrefix: true) {
                    guard !isCancelled() else { return [] }
                    append(item, kind: .groupContainers)
                }
            }

            // User LaunchAgents only (never /Library/LaunchDaemons — needs admin/FDA).
            let agents = library.appendingPathComponent("LaunchAgents", isDirectory: true)
            if let agentItems = try? fileManager.contentsOfDirectory(
                at: agents,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for item in agentItems where item.pathExtension.lowercased() == "plist"
                    && nameMatchesBundleID(item.lastPathComponent, bundleID: bundleID, allowsTeamPrefix: false) {
                    guard !isCancelled() else { return [] }
                    append(item, kind: .launchAgents)
                }
            }

            append(
                library.appendingPathComponent("HTTPStorages/\(bundleID)", isDirectory: true),
                kind: .httpStorages
            )
            append(
                library.appendingPathComponent("WebKit/\(bundleID)", isDirectory: true),
                kind: .webKit
            )

            let crashes = library.appendingPathComponent(
                "Application Support/CrashReporter",
                isDirectory: true
            )
            if let crashItems = try? fileManager.contentsOfDirectory(
                at: crashes,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for item in crashItems where nameMatchesBundleID(item.lastPathComponent, bundleID: bundleID, allowsTeamPrefix: false) {
                    guard !isCancelled() else { return [] }
                    append(item, kind: .crashReporter)
                }
            }
        }

        // Package-name fallback: only Application Support / Logs when the folder
        // name exactly matches the .app basename and is not a trivial short token.
        if isSafePackageNameFallback(packageName) {
            let support = library.appendingPathComponent(
                "Application Support/\(packageName)",
                isDirectory: true
            )
            if bundleID == nil || !seen.contains(support.path) {
                append(support, kind: .applicationSupport)
            }
            let logs = library.appendingPathComponent("Logs/\(packageName)", isDirectory: true)
            if bundleID == nil || !seen.contains(logs.path) {
                append(logs, kind: .logs)
            }
        }

        guard !isCancelled() else { return [] }
        return found.sorted { lhs, rhs in
            let left = lhs.byteSize ?? 0
            let right = rhs.byteSize ?? 0
            if left != right { return left > right }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
    }

    /// Pure running-match helper (Direct supplies live process identifiers).
    public static func isRunning(
        candidate: AppCandidate,
        runningBundleIdentifiers: Set<String>,
        runningBundlePaths: Set<String>
    ) -> Bool {
        if let bundleID = normalizedBundleID(candidate.bundleIdentifier),
           runningBundleIdentifiers.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return true
        }
        let path = candidate.canonicalURL.resolvingSymlinksInPath().standardizedFileURL.path
        return runningBundlePaths.contains(path)
    }

    public static func normalizedBundleID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }


    /// Bundle IDs used to build paths must be plain reverse-DNS tokens: no
    /// separators / traversal, at least two components.
    public static func usableBundleID(_ raw: String?) -> String? {
        guard let id = normalizedBundleID(raw) else { return nil }
        guard id.count >= 5, id.count <= 255 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return id
    }

    /// Exact bundle-ID match, or the ID as a whole dot/dash-delimited token
    /// (`ABCD.com.x.App`, `com.x.App.helper.plist`). `com.x.App2` never matches
    /// `com.x.App`. Two-component IDs (`md.obsidian`) only match exactly.
    public static func nameMatchesBundleID(
        _ name: String,
        bundleID: String,
        allowsTeamPrefix: Bool
    ) -> Bool {
        let lowerName = name.lowercased()
        let lowerID = bundleID.lowercased()
        if lowerName == lowerID { return true }
        let componentCount = lowerID.split(separator: ".").count
        guard componentCount >= 3 else { return false }
        var searchStart = lowerName.startIndex
        while let range = lowerName.range(of: lowerID, range: searchStart..<lowerName.endIndex) {
            let beforeOK: Bool
            if range.lowerBound == lowerName.startIndex {
                beforeOK = true
            } else {
                beforeOK = allowsTeamPrefix && lowerName[lowerName.index(before: range.lowerBound)] == "."
            }
            let afterOK: Bool
            if range.upperBound == lowerName.endIndex {
                afterOK = true
            } else {
                afterOK = ".-_".contains(lowerName[range.upperBound])
            }
            if beforeOK && afterOK { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// Avoid matching generic folders like "data", "tmp", "app".
    public static func isSafePackageNameFallback(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        let blocked: Set<String> = [
            "app", "apps", "data", "tmp", "temp", "bin", "lib", "log", "logs",
            "cache", "caches", "shared", "user", "users", "util", "utils",
            "helper", "helpers", "service", "services", "agent", "agents",
            // Vendor-wide folders shared by several products.
            "apple", "google", "microsoft", "adobe", "mozilla", "jetbrains",
            "setapp", "steam", "default", "common", "support", "preferences",
            "launcher", "updater", "update", "crashreporter", "webkit", "chrome"
        ]
        return !blocked.contains(trimmed.lowercased())
    }


    /// Sum of known sizes for a selection (nil sizes count as 0).
    /// Destructive confirm stays off until at least one related path is checked.
    /// Single-app related cleanup and orphan leftovers both start with nothing
    /// checked so the user must opt in per path (trash stays disabled at 0).
    public static let relatedCleanupDefaultSelected = false

    /// Informative copy for the single-app related-files sheet (aligned with orphans).
    public static let relatedCleanupReviewMessageKey =
        "默认不选。请确认路径并勾选要移到废纸篓的项目；未登记且未运行的根外副本可能无法发现。"
    /// RELATED-CLEANUP-CONFIRM-COPY-01 — checklist alert title (app name filled in).
    public static let relatedCleanupConfirmTitleFormatKey = "选择要清理的“%@”相关文件"

    public static func relatedCleanupConfirmTitle(
        appName: String,
        localize: (String) -> String = { $0 }
    ) -> String {
        String(format: localize(relatedCleanupConfirmTitleFormatKey), appName)
    }

    public static func relatedCleanupReviewMessage(
        localize: (String) -> String = { $0 }
    ) -> String {
        localize(relatedCleanupReviewMessageKey)
    }

    public static func relatedCleanupConfirmEnabled(selectedCount: Int) -> Bool {
        selectedCount > 0
    }

    /// Cancel is the first alert button so Return/Enter never trashes; Esc maps
    /// to Cancel on AppKit alerts. Destructive trash stays second.
    public static let relatedCleanupAlertCancelIsFirstButton = true

    /// VoiceOver name for the scrollable checklist accessory.
    public static let relatedCleanupListAccessibilityLabelKey = "相关文件列表"

    public static let relatedCleanupSelectAllAccessibilityLabelKey = "全选相关文件"
    public static let relatedCleanupSelectNoneAccessibilityLabelKey = "全不选相关文件"
    public static let relatedCleanupSelectAllAccessibilityHelpKey = "勾选列表中的全部路径"
    public static let relatedCleanupSelectNoneAccessibilityHelpKey = "取消勾选全部路径"
    public static let relatedCleanupSelectedTotalAccessibilityLabelKey = "已选相关文件合计"
    public static let relatedCleanupTrashDisabledAccessibilityHelpKey = "请先勾选要移到废纸篓的项目"
    public static let relatedCleanupTrashEnabledAccessibilityHelpKey = "将勾选的项目移到废纸篓"
    public static let relatedFilesToggleAccessibilityHelpKey =
        "勾选后可再选择要删除的支持文件、偏好设置与缓存等；默认不删用户数据"
    public static let relatedFilesToggleDisabledAccessibilityHelpKey =
        "发现同一应用的其他副本或无法确认副本时，不能删除相关用户文件"

    /// Checkbox VoiceOver help: kind + size (path stays the accessibility label).
    public static func relatedCleanupItemAccessibilityHelp(kindLabel: String, sizeLabel: String) -> String {
        "\(kindLabel)，\(sizeLabel)"
    }

    public static func relatedCleanupTrashAccessibilityHelp(selectedCount: Int) -> String {
        relatedCleanupConfirmEnabled(selectedCount: selectedCount)
            ? relatedCleanupTrashEnabledAccessibilityHelpKey
            : relatedCleanupTrashDisabledAccessibilityHelpKey
    }

    public static func relatedFilesToggleAccessibilityHelp(isEnabled: Bool) -> String {
        isEnabled
            ? relatedFilesToggleAccessibilityHelpKey
            : relatedFilesToggleDisabledAccessibilityHelpKey
    }

    /// After an uninstall/related sheet closes, put keyboard focus back on the
    /// tile that opened the menu (alias rename already does the same).
    public static let relatedCleanupRestoresLauncherFocusAfterSheet = true

    public static func selectedByteTotal(of files: [AppRelatedFileCandidate]) -> UInt64 {
        files.reduce(into: UInt64(0)) { total, file in
            total += file.byteSize ?? 0
        }
    }

    public static func formatByteSize(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func approximateSizeForScan(
        of url: URL, fileManager: FileManager, isCancelled: () -> Bool = { false }
    ) -> UInt64? {
        approximateSize(of: url, fileManager: fileManager, isCancelled: isCancelled)
    }

    private static func approximateSize(
        of url: URL, fileManager: FileManager, isCancelled: () -> Bool = { false }
    ) -> UInt64? {
        guard !isCancelled() else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if values?.isDirectory == true {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return nil }
            var total: UInt64 = 0
            var count = 0
            for case let fileURL as URL in enumerator {
                guard !isCancelled() else { return nil }
                count += 1
                if count > 5_000 { return total }
                let size = (try? fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey]))?.fileAllocatedSize
                total += UInt64(size ?? 0)
            }
            return total
        }
        if let allocated = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize {
            return UInt64(allocated)
        }
        return nil
    }
}

/// Guards every destructive related-file move.
public enum AppRelatedFileSafety {
    /// Safe only when the item itself is not a symlink, lives strictly inside
    /// `~/Library/<category>/…` (never a whole category folder), and every
    /// parent resolves back inside the user's real Library.
    public static func isSafeToTrash(
        _ url: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let item = url.standardizedFileURL
        let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true { return false }
        let parentResolved = item.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let candidate = parentResolved.appendingPathComponent(item.lastPathComponent)
        let path = candidate.path
        guard path.hasPrefix(library.path + "/") else { return false }
        let relative = path.dropFirst(library.path.count + 1)
        // Need `<category>/<item>` at minimum.
        guard relative.split(separator: "/").count >= 2 else { return false }
        guard !relative.contains("..") else { return false }
        return true
    }
}

/// Leftovers in the user's Library for apps that are no longer installed.
/// Deliberately conservative: bundle-ID-named items only, never Apple IDs,
/// never anything sharing a vendor prefix with an installed app, and the
/// caller must prove the scan of installed apps is complete.
public enum AppOrphanLeftoverScanner {
    public static let incompleteScanMessageKey = "请等待扫描完成后再清理残留文件"
    public static let noneFoundMessageKey = "未发现可清理的残留文件（仅匹配已卸载应用的用户资料库项目）"
    public static let cancelledMessageKey = "已取消残留文件清理"
    public static let scanningProgressMessageKey = "正在查找残留文件…"
    public static let trashingProgressMessageKey = "正在移到废纸篓…"
    public static let recheckingProgressMessageKey = "正在确认安装状态…"
    /// ORPHAN-LEFTOVER-CONFIRM-COPY-01 — checklist alert title / body.
    public static let confirmTitleKey = "清理已卸载应用的残留文件"
    public static let confirmInformativeKey =
        "这些项目可能属于已卸载的应用。默认不选；请确认路径并勾选要移到废纸篓的项目。"

    public static func confirmTitle(localize: (String) -> String = { $0 }) -> String {
        localize(confirmTitleKey)
    }

    public static func confirmInformativeText(localize: (String) -> String = { $0 }) -> String {
        localize(confirmInformativeKey)
    }

    /// ORPHAN-LEFTOVER-RESULT-TOAST-01 — post-checklist outcome copy.
    public static let catalogUnavailableKey = "无法确认应用安装状态，请稍后重试"
    public static let changedBeforeTrashKey = "应用或残留文件已变化，请重新查找后再清理"
    public static let successFormatKey = "已把 %d 项残留文件移到废纸篓，可在废纸篓中放回原处"
    public static let cancelledPartialFormatKey = "已取消；已移走 %d 项，其余保留"
    public static let partialFailFormatKey = "已移走 %d 项，%d 项失败（仍在原处）：%@"
    public static let failedNameListLimit = 3
    public static let failedNameSeparator = ", "

    public static func catalogUnavailable(localize: (String) -> String = { $0 }) -> String {
        localize(catalogUnavailableKey)
    }

    public static func changedBeforeTrash(localize: (String) -> String = { $0 }) -> String {
        localize(changedBeforeTrashKey)
    }

    public static func successMessage(
        trashedCount: Int,
        localize: (String) -> String = { $0 }
    ) -> String {
        String(format: localize(successFormatKey), trashedCount)
    }

    public static func cancelledPartialMessage(
        trashedCount: Int,
        localize: (String) -> String = { $0 }
    ) -> String {
        String(format: localize(cancelledPartialFormatKey), trashedCount)
    }

    public static func partialFailMessage(
        trashedCount: Int,
        failedNames: [String],
        localize: (String) -> String = { $0 }
    ) -> String {
        let names = failedNames.prefix(failedNameListLimit).joined(separator: failedNameSeparator)
        return String(
            format: localize(partialFailFormatKey),
            trashedCount,
            failedNames.count,
            names
        )
    }

    /// Final toast after trash: empty-fail → success; otherwise partial with names.
    public static func trashOutcomeMessage(
        trashedCount: Int,
        failedLastPathComponents: [String],
        localize: (String) -> String = { $0 }
    ) -> String {
        if failedLastPathComponents.isEmpty {
            return successMessage(trashedCount: trashedCount, localize: localize)
        }
        return partialFailMessage(
            trashedCount: trashedCount,
            failedNames: failedLastPathComponents,
            localize: localize
        )
    }

    private static let categories: [(String, String, AppRelatedFileCandidate.Kind)] = [
        ("Application Support", "", .applicationSupport),
        ("Caches", "", .caches),
        ("Containers", "", .containers),
        ("Saved Application State", ".savedState", .savedState),
        ("Preferences", ".plist", .preferences),
        ("HTTPStorages", "", .httpStorages),
        ("WebKit", "", .webKit)
    ]

    public static func discover(
        homeDirectory: URL,
        installedBundleIdentifiers: Set<String>,
        isInstalledElsewhere: (String) -> Bool = { _ in false },
        isCancelled: () -> Bool = { false },
        fileManager: FileManager = .default
    ) -> [AppRelatedFileCandidate] {
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        let installed = Set(installedBundleIdentifiers.map { $0.lowercased() })
        let installedVendors = Set(installed.compactMap(vendorPrefix))
        var found: [AppRelatedFileCandidate] = []
        var seen = Set<String>()

        for (folder, suffix, kind) in categories {
            guard !isCancelled() else { return [] }
            let root = library.appendingPathComponent(folder, isDirectory: true)
            guard let items = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in items {
                guard !isCancelled() else { return [] }
                var name = item.lastPathComponent
                if !suffix.isEmpty {
                    guard name.lowercased().hasSuffix(suffix.lowercased()) else { continue }
                    name = String(name.dropLast(suffix.count))
                }
                guard let id = candidateOrphanBundleID(name) else { continue }
                let lower = id.lowercased()
                if installed.contains(lower) { continue }
                if installed.contains(where: { AppRelatedFileScanner.nameMatchesBundleID(lower, bundleID: $0, allowsTeamPrefix: false) }) { continue }
                if let vendor = vendorPrefix(lower), installedVendors.contains(vendor) { continue }
                if isInstalledElsewhere(id) { continue }
                guard !isCancelled() else { return [] }
                guard AppRelatedFileSafety.isSafeToTrash(item, homeDirectory: homeDirectory, fileManager: fileManager) else { continue }
                let standardized = item.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent(item.lastPathComponent).standardizedFileURL
                guard seen.insert(standardized.path).inserted else { continue }
                found.append(AppRelatedFileCandidate(
                    url: standardized,
                    kind: kind,
                    byteSize: kind == .containers ? nil : AppRelatedFileScanner.approximateSizeForScan(
                        of: standardized, fileManager: fileManager, isCancelled: isCancelled
                    )
                ))
            }
        }
        guard !isCancelled() else { return [] }
        return found.sorted { lhs, rhs in
            let left = lhs.byteSize ?? 0
            let right = rhs.byteSize ?? 0
            if left != right { return left > right }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
    }

    /// Orphans need a stricter ID than live apps: ≥3 components, never Apple.
    public static func candidateOrphanBundleID(_ name: String) -> String? {
        guard let id = AppRelatedFileScanner.usableBundleID(name) else { return nil }
        let parts = id.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return nil }
        if parts[0] == "com", parts[1] == "apple" { return nil }
        if parts[0] == "group" || parts[0] == "systemgroup" { return nil }
        return id
    }

    /// `com.vendor` for `com.vendor.Product`.
    static func vendorPrefix(_ lowerID: String) -> String? {
        let parts = lowerID.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts[0] + "." + parts[1]
    }
}

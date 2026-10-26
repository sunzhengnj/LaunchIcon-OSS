import Foundation
import CoreServices

public protocol AppCataloging: Sendable {
    func scan(roots: [URL]) async -> CatalogScanReport
}

public actor AppCatalogScanner: AppCataloging {
    public static let standardRoots: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true)
    ]

    /// CUSTOM-ROOT-SCAN-LIMIT-01 — caps for user-added roots only (not standard).
    /// Relative path components under the root (`Foo.app` = 1).
    public static let customRootMaxRelativeDepth = 4
    /// Hard stop per user-added root so huge trees cannot stall the scan.
    public static let customRootMaxAppsDefault = 500
    /// CUSTOM-ROOT-COUNT-LIMIT-01 — how many user folders Settings may keep.
    public static let maxAdditionalAppDirectories = 12

    /// Drop invalid / duplicate / over-limit paths so persisted prefs match
    /// what `catalogRoots` will actually scan.
    public static func sanitizedAdditionalAppDirectories(
        _ paths: [String],
        standard: [URL] = AppCatalogScanner.standardRoots,
        limit: Int = maxAdditionalAppDirectories
    ) -> [String] {
        let roots = catalogRoots(standard: standard, additionalPaths: paths)
        let standardPaths = Set(standard.map { normalizedRootPath($0.path) })
        let extras = roots.map(\.path).filter { !standardPaths.contains(normalizedRootPath($0)) }
        return Array(extras.prefix(max(0, limit)))
    }
    #if DEBUG
    /// Test-only override; production always uses `customRootMaxAppsDefault`.
    nonisolated(unsafe) public static var customRootMaxAppsOverride: Int?
    #endif
    public static var customRootMaxApps: Int {
        #if DEBUG
        if let override = customRootMaxAppsOverride { return override }
        #endif
        return customRootMaxAppsDefault
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(roots: [URL] = AppCatalogScanner.standardRoots) async -> CatalogScanReport {
        Self.scanSynchronously(roots: roots, fileManager: fileManager, includeHiddenApplications: false)
    }

    /// Like `scan(roots:)`, but a missing root listed in `requiredRootPaths`
    /// (a user-added folder on an unmounted drive) is reported as
    /// `unavailableRequiredRootPaths` so callers can retain prior candidates
    /// under that root without locking the whole layout read-only.
    public func scan(roots: [URL], requiredRootPaths: Set<String>) async -> CatalogScanReport {
        Self.scanSynchronously(
            roots: roots, fileManager: fileManager, includeHiddenApplications: false,
            requiredRootPaths: requiredRootPaths
        )
    }

    /// Standard roots first (they win deduplication), then valid user folders.
    /// Drops blanks, relative paths, duplicates, standard roots themselves,
    /// paths inside an app bundle, and ancestors of a standard root (`/`,
    /// `/System`, the home folder) whose recursive scan would be enormous.
    public nonisolated static func catalogRoots(
        standard: [URL] = AppCatalogScanner.standardRoots,
        additionalPaths: [String]
    ) -> [URL] {
        var roots = standard
        let standardPaths = standard.map { normalizedRootPath($0.path) }
        var seen = Set(standardPaths)
        for raw in additionalPaths {
            if roots.count - standard.count >= maxAdditionalAppDirectories { break }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") else { continue }
            let path = normalizedRootPath(trimmed)
            guard path != "/", !seen.contains(path),
                  !path.split(separator: "/").contains(where: { $0.lowercased().hasSuffix(".app") }),
                  !standardPaths.contains(where: { $0.hasPrefix(path + "/") }) else { continue }
            seen.insert(path)
            roots.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return roots
    }

    public nonisolated static func normalizedRootPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }

    /// Uninstall safety must see copies in hidden directories that the grid omits.
    public func scanIncludingHiddenApplications(roots: [URL]) async -> CatalogScanReport {
        Self.scanSynchronously(roots: roots, fileManager: fileManager, includeHiddenApplications: true)
    }

    private nonisolated static func scanSynchronously(
        roots: [URL], fileManager: FileManager, includeHiddenApplications: Bool,
        requiredRootPaths: Set<String> = []
    ) -> CatalogScanReport {
        var candidates: [AppCandidate] = []
        var skippedPaths: [URL] = []
        var unavailableRequiredRootPaths: [URL] = []
        var truncatedScanRootPaths: [URL] = []
        var unreadableMetadataPaths: [URL] = []
        var unlaunchablePaths: [URL] = []

        for (priority, root) in roots.enumerated() {
            do {
                _ = try fileManager.attributesOfItem(atPath: root.path)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
                // A standard Applications root may simply not exist on this Mac.
                // A missing *required* (user-added) root is unavailable, not a
                // scan failure — editing stays open; retain prior apps under it.
                if requiredRootPaths.contains(normalizedRootPath(root.path)) {
                    unavailableRequiredRootPaths.append(root)
                }
                continue
            } catch {
                skippedPaths.append(root)
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: root.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .contentModificationDateKey],
                options: includeHiddenApplications ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, _ in
                    skippedPaths.append(url)
                    return true
                }
            ) else {
                skippedPaths.append(root)
                continue
            }

            // CUSTOM-ROOT-SCAN-LIMIT-01: only user-added (required) roots are capped.
            let rootNormalized = normalizedRootPath(root.path)
            let applyCustomLimits = requiredRootPaths.contains(rootNormalized)
            var appsUnderRoot = 0
            var didTruncateRoot = false

            for case let url as URL in enumerator {
                guard !Task.isCancelled else {
                    let selected = deduplicate(candidates)
                    let selectedURLs = Set(selected.map(\.canonicalURL))
                    return CatalogScanReport(
                        candidates: disambiguateDisplayNames(selected),
                        skippedPaths: skippedPaths,
                        unreadableMetadataPaths: unreadableMetadataPaths,
                        unlaunchablePaths: unlaunchablePaths,
                        duplicateCandidates: candidates.filter { !selectedURLs.contains($0.canonicalURL) },
                        unavailableRequiredRootPaths: unavailableRequiredRootPaths,
                        truncatedScanRootPaths: truncatedScanRootPaths,
                        wasCancelled: true
                    )
                }

                if applyCustomLimits {
                    let itemPath = normalizedRootPath(url.path)
                    let relative: String
                    if itemPath == rootNormalized {
                        relative = ""
                    } else if itemPath.hasPrefix(rootNormalized + "/") {
                        relative = String(itemPath.dropFirst(rootNormalized.count + 1))
                    } else {
                        relative = ""
                    }
                    let depth = relative.isEmpty ? 0 : relative.split(separator: "/").count
                    if depth > customRootMaxRelativeDepth {
                        enumerator.skipDescendants()
                        didTruncateRoot = true
                        continue
                    }
                }

                guard url.pathExtension.lowercased() == "app" else { continue }

                do {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .contentModificationDateKey])
                    // A regular file named *.app is not an unreadable application bundle.
                    if values.isDirectory == false && values.isSymbolicLink == false { continue }
                    let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
                    let resolvedValues = try resolvedURL.resourceValues(
                        forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .contentModificationDateKey]
                    )
                    guard resolvedValues.isDirectory == true,
                          resolvedValues.isSymbolicLink != true,
                          (includeHiddenApplications || (values.isHidden != true && resolvedValues.isHidden != true)) else {
                        skippedPaths.append(url)
                        continue
                    }
                    if applyCustomLimits && appsUnderRoot >= customRootMaxApps {
                        didTruncateRoot = true
                        break
                    }
                    let info = bundleInfoDictionary(at: resolvedURL, fileManager: fileManager)
                    if info == nil {
                        unreadableMetadataPaths.append(resolvedURL)
                    } else if !isExecutableBundle(at: resolvedURL) {
                        unlaunchablePaths.append(resolvedURL)
                    }
                    candidates.append(
                        makeCandidate(
                            at: resolvedURL,
                            sourcePriority: priority,
                            modificationDate: resolvedValues.contentModificationDate,
                            info: info
                        )
                    )
                    if applyCustomLimits {
                        appsUnderRoot += 1
                    }
                } catch {
                    skippedPaths.append(url)
                }
            }
            if didTruncateRoot {
                truncatedScanRootPaths.append(root)
            }
        }

        let selected = deduplicate(candidates)
        let selectedURLs = Set(selected.map(\.canonicalURL))
        return CatalogScanReport(
            candidates: disambiguateDisplayNames(selected),
            skippedPaths: skippedPaths,
            unreadableMetadataPaths: unreadableMetadataPaths,
            unlaunchablePaths: unlaunchablePaths,
            duplicateCandidates: candidates.filter { !selectedURLs.contains($0.canonicalURL) },
            unavailableRequiredRootPaths: unavailableRequiredRootPaths,
            truncatedScanRootPaths: truncatedScanRootPaths,
            wasCancelled: Task.isCancelled
        )
    }

    nonisolated static func makeCandidate(at url: URL, sourcePriority: Int, modificationDate: Date? = nil) -> AppCandidate {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let info = bundleInfoDictionary(at: resolvedURL, fileManager: .default)
        return makeCandidate(at: resolvedURL, sourcePriority: sourcePriority, modificationDate: modificationDate, info: info)
    }

    /// Mac bundles keep metadata in Contents/Info.plist. iOS apps installed into
    /// Applications have no Contents directory; their identity lives in the
    /// inner bundle pointed at by WrappedBundle, or under Wrapper/*.app.
    /// A Contents/Info.plist that exists but cannot be read stays unreadable.
    private nonisolated static func bundleInfoDictionary(at resolvedURL: URL, fileManager: FileManager) -> [String: Any]? {
        let contentsInfo = resolvedURL.appendingPathComponent("Contents/Info.plist")
        if let info = NSDictionary(contentsOf: contentsInfo) as? [String: Any] {
            return info
        }
        if fileManager.fileExists(atPath: contentsInfo.path) {
            return nil
        }
        let wrappedBundle = resolvedURL.appendingPathComponent("WrappedBundle")
        if fileManager.fileExists(atPath: wrappedBundle.path) {
            let innerInfo = wrappedBundle.resolvingSymlinksInPath().appendingPathComponent("Info.plist")
            if let info = NSDictionary(contentsOf: innerInfo) as? [String: Any] {
                return info
            }
        }
        let wrapper = resolvedURL.appendingPathComponent("Wrapper", isDirectory: true)
        guard let children = try? fileManager.contentsOfDirectory(
            at: wrapper,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for child in children where child.pathExtension.lowercased() == "app" {
            let innerInfo = child.appendingPathComponent("Info.plist")
            if let info = NSDictionary(contentsOf: innerInfo) as? [String: Any] {
                return info
            }
        }
        return nil
    }

    private nonisolated static func makeCandidate(
        at resolvedURL: URL,
        sourcePriority: Int,
        modificationDate: Date?,
        info: [String: Any]?
    ) -> AppCandidate {
        let indexedName: String?
        if let item = MDItemCreate(kCFAllocatorDefault, resolvedURL.path as NSString) {
            indexedName = MDItemCopyAttribute(item, kMDItemDisplayName) as? String
        } else {
            indexedName = nil
        }
        let packageName = resolvedURL.deletingPathExtension().lastPathComponent
        func nonBlank(_ name: String?) -> String? {
            guard let name else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let displayName = nonBlank(indexedName).flatMap { $0 == packageName ? nil : $0 }
            ?? nonBlank(info?["CFBundleDisplayName"] as? String)
            ?? nonBlank(info?["CFBundleName"] as? String)
            ?? packageName
        return AppCandidate(
            canonicalURL: resolvedURL,
            bundleIdentifier: info?["CFBundleIdentifier"] as? String,
            displayName: displayName,
            sourcePriority: sourcePriority,
            discoveredAt: Date(timeIntervalSince1970: 0),
            modificationDate: modificationDate
        )
    }

    public nonisolated static func deduplicate(_ candidates: [AppCandidate]) -> [AppCandidate] {
        let sorted = candidates.sorted {
            if $0.sourcePriority != $1.sourcePriority { return $0.sourcePriority < $1.sourcePriority }
            return $0.canonicalURL.path.localizedStandardCompare($1.canonicalURL.path) == .orderedAscending
        }
        let duplicateGroups = Dictionary(grouping: sorted.indices) { sorted[$0].deduplicationKey }
        let selectedIndices = Set(duplicateGroups.values.map { indices in
            guard indices.count > 1 else { return indices[0] }
            return indices.first { isExecutableBundle(at: sorted[$0].canonicalURL) } ?? indices[0]
        })
        return sorted.enumerated().compactMap { index, candidate in
            selectedIndices.contains(index) ? candidate : nil
        }
    }

    private nonisolated static func isExecutableBundle(at url: URL) -> Bool {
        guard let executableURL = Bundle(url: url)?.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    public nonisolated static func disambiguateDisplayNames(_ candidates: [AppCandidate]) -> [AppCandidate] {
        let duplicateNames = Set(
            Dictionary(grouping: candidates) { normalizedDisplayName($0.displayName) }
                .compactMap { $0.value.count > 1 ? $0.key : nil }
        )
        let packageNameDisambiguated = candidates.map { candidate in
            guard duplicateNames.contains(normalizedDisplayName(candidate.displayName)) else { return candidate }
            let packageName = candidate.canonicalURL.deletingPathExtension().lastPathComponent
            guard normalizedDisplayName(packageName) != normalizedDisplayName(candidate.displayName) else { return candidate }
            return copy(candidate, withDisplayName: packageName)
        }

        let remainingGroups = Dictionary(grouping: packageNameDisambiguated) {
            normalizedDisplayName($0.displayName)
        }
        return packageNameDisambiguated.map { candidate in
            guard let group = remainingGroups[normalizedDisplayName(candidate.displayName)],
                  group.count > 1 else {
                return candidate
            }
            let disambiguator = candidate.bundleIdentifier.flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
                ?? distinguishingParentPath(for: candidate, among: group)
            return copy(candidate, withDisplayName: "\(candidate.displayName) — \(disambiguator)")
        }
    }

    private nonisolated static func distinguishingParentPath(
        for candidate: AppCandidate,
        among group: [AppCandidate]
    ) -> String {
        let parentPath = candidate.canonicalURL.deletingLastPathComponent().path
        let components = parentPath.split(separator: "/")
        guard !components.isEmpty else { return parentPath }
        let otherParents = group.filter {
            $0.canonicalURL != candidate.canonicalURL &&
                ($0.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }.map { $0.canonicalURL.deletingLastPathComponent().path }
        let usedIdentifiers = Set(group.compactMap { other -> String? in
            guard let id = other.bundleIdentifier,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return normalizedDisplayName(id)
        })

        for depth in 1...components.count {
            let suffix = components.suffix(depth).joined(separator: "/")
            let normalizedSuffix = normalizedDisplayName(suffix)
            if !usedIdentifiers.contains(normalizedSuffix) && otherParents.allSatisfy({ other in
                normalizedDisplayName(other.split(separator: "/").suffix(depth).joined(separator: "/")) != normalizedSuffix
            }) {
                return suffix
            }
        }
        return parentPath
    }

    private nonisolated static func normalizedDisplayName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private nonisolated static func copy(_ candidate: AppCandidate, withDisplayName displayName: String) -> AppCandidate {
        AppCandidate(
            canonicalURL: candidate.canonicalURL,
            bundleIdentifier: candidate.bundleIdentifier,
            displayName: displayName,
            sourcePriority: candidate.sourcePriority,
            discoveredAt: candidate.discoveredAt,
            modificationDate: candidate.modificationDate
        )
    }
}

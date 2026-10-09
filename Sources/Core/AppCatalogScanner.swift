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

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(roots: [URL] = AppCatalogScanner.standardRoots) async -> CatalogScanReport {
        Self.scanSynchronously(roots: roots, fileManager: fileManager)
    }

    private nonisolated static func scanSynchronously(roots: [URL], fileManager: FileManager) -> CatalogScanReport {
        var candidates: [AppCandidate] = []
        var skippedPaths: [URL] = []
        var unreadableMetadataPaths: [URL] = []
        var unlaunchablePaths: [URL] = []

        for (priority, root) in roots.enumerated() {
            do {
                _ = try fileManager.attributesOfItem(atPath: root.path)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
                // A standard Applications root may simply not exist on this Mac.
                continue
            } catch {
                skippedPaths.append(root)
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: root.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, _ in
                    skippedPaths.append(url)
                    return true
                }
            ) else {
                skippedPaths.append(root)
                continue
            }

            for case let url as URL in enumerator {
                guard !Task.isCancelled else {
                    return CatalogScanReport(
                        candidates: disambiguateDisplayNames(deduplicate(candidates)),
                        skippedPaths: skippedPaths,
                        unreadableMetadataPaths: unreadableMetadataPaths,
                        unlaunchablePaths: unlaunchablePaths,
                        wasCancelled: true
                    )
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
                    guard values.isHidden != true,
                          resolvedValues.isDirectory == true,
                          resolvedValues.isSymbolicLink != true,
                          resolvedValues.isHidden != true else {
                        skippedPaths.append(url)
                        continue
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
                } catch {
                    skippedPaths.append(url)
                }
            }
        }

        return CatalogScanReport(
            candidates: disambiguateDisplayNames(deduplicate(candidates)),
            skippedPaths: skippedPaths,
            unreadableMetadataPaths: unreadableMetadataPaths,
            unlaunchablePaths: unlaunchablePaths,
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

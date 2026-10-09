import Foundation

public struct AppCandidate: Codable, Hashable, Identifiable, Sendable {
    public let canonicalURL: URL
    public let bundleIdentifier: String?
    public let displayName: String
    public let sourcePriority: Int
    public let discoveredAt: Date
    public let modificationDate: Date?

    public var id: String { deduplicationKey }

    public init(
        canonicalURL: URL,
        bundleIdentifier: String?,
        displayName: String,
        sourcePriority: Int,
        discoveredAt: Date,
        modificationDate: Date? = nil
    ) {
        self.canonicalURL = canonicalURL
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.sourcePriority = sourcePriority
        self.discoveredAt = discoveredAt
        self.modificationDate = modificationDate
    }

    public var deduplicationKey: String {
        if let bundleIdentifier,
           !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "bundle:\(bundleIdentifier.lowercased())"
        }
        return "url:\(canonicalURL.standardizedFileURL.path.lowercased())"
    }

    public static func firstByDeduplicationKey(_ candidates: [AppCandidate]) -> [String: AppCandidate] {
        candidates.reduce(into: [:]) { result, candidate in
            if result[candidate.deduplicationKey] == nil {
                result[candidate.deduplicationKey] = candidate
            }
        }
    }
}

public struct CatalogScanReport: Sendable {
    public let candidates: [AppCandidate]
    public let skippedPaths: [URL]
    public let unreadableMetadataPaths: [URL]
    public let unlaunchablePaths: [URL]
    public let wasCancelled: Bool

    /// An empty or identity-incomplete snapshot must not erase the user's saved arrangement.
    public var canPersistReconciledLayout: Bool {
        !wasCancelled && !candidates.isEmpty
            && Set(candidates.map(\.deduplicationKey)).count == candidates.count
            && skippedPaths.isEmpty && unreadableMetadataPaths.isEmpty
    }

    public init(
        candidates: [AppCandidate],
        skippedPaths: [URL],
        unreadableMetadataPaths: [URL] = [],
        unlaunchablePaths: [URL] = [],
        wasCancelled: Bool = false
    ) {
        self.candidates = candidates
        self.skippedPaths = skippedPaths
        self.unreadableMetadataPaths = unreadableMetadataPaths
        self.unlaunchablePaths = unlaunchablePaths
        self.wasCancelled = wasCancelled
    }
}

public enum LauncherSearchHit: Hashable, Sendable {
    case app(AppCandidate)
    case folder(UUID, String)
}

public enum AppSearch {
    public static func filter(
        _ candidates: [AppCandidate],
        query: String,
        aliases: [String: String] = [:]
    ) -> [AppCandidate] {
        AppSearchIndex(candidates: candidates, aliases: aliases).filter(candidates, query: query)
    }
}

/// Caches normalized and phonetic search forms for a catalog snapshot so each keystroke
/// only normalizes the query and checks already-prepared candidate text.
public struct AppSearchIndex: Sendable {
    private struct SearchText: Sendable {
        let normalized: String
        let spacedLatin: String?
        let compactLatin: String?
        let initials: String?

        init(_ value: String) {
            normalized = Self.normalize(value)
            guard let latin = value.applyingTransform(.toLatin, reverse: false) else {
                spacedLatin = nil
                compactLatin = nil
                initials = nil
                return
            }
            let normalizedLatin = Self.normalize(latin)
            guard normalizedLatin != normalized else {
                spacedLatin = nil
                compactLatin = nil
                initials = nil
                return
            }
            spacedLatin = normalizedLatin
            compactLatin = normalizedLatin.filter { !$0.isWhitespace }
            initials = normalizedLatin
                .split(whereSeparator: { $0.isWhitespace })
                .compactMap { $0.first.map(String.init) }
                .joined()
        }

        func matches(_ query: String) -> Bool {
            if contains(normalized, query) { return true }
            if let spacedLatin, contains(spacedLatin, query) { return true }
            if let compactLatin, contains(compactLatin, query) { return true }
            if let initials, contains(initials, query) { return true }
            return false
        }

        /// Lower is a closer hit. Exact name, then prefix, then any other match.
        func matchRank(for query: String) -> Int? {
            guard matches(query) else { return nil }
            if isExact(query) { return 0 }
            if isPrefix(query) { return 1 }
            return 3
        }

        private func isExact(_ query: String) -> Bool {
            compare(query) { field, compactField, compactQuery, folded in
                field == query || (folded && compactField == compactQuery)
            }
        }

        private func isPrefix(_ query: String) -> Bool {
            compare(query) { field, compactField, compactQuery, folded in
                field.hasPrefix(query) || (folded && compactField.hasPrefix(compactQuery))
            }
        }

        private func compare(
            _ query: String,
            _ body: (String, String, String, Bool) -> Bool
        ) -> Bool {
            let compactQuery = String(query.filter { !$0.isWhitespace })
            let folded = compactQuery.count >= 2
            func compact(_ field: String) -> String {
                String(field.filter { !$0.isWhitespace })
            }
            if body(normalized, compact(normalized), compactQuery, folded) { return true }
            if let spacedLatin, body(spacedLatin, compact(spacedLatin), compactQuery, folded) { return true }
            if let compactLatin, folded, body(compactLatin, compactLatin, compactQuery, folded) { return true }
            return false
        }

        /// A query may include or omit spaces that the name has. "oldtool" finds
        /// "Old Tool", and "photo shop" finds "PhotoShop". One-character queries
        /// stay exact so a single letter does not match every compacted name.
        private func contains(_ field: String, _ query: String) -> Bool {
            if field.contains(query) { return true }
            let compactQuery = String(query.filter { !$0.isWhitespace })
            guard compactQuery.count >= 2 else { return false }
            let compactField = String(field.filter { !$0.isWhitespace })
            guard compactField != field || compactQuery != query else { return false }
            return compactField.contains(compactQuery)
        }

        private static func normalize(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        }
    }

    private struct CandidateText: Sendable {
        let sourceDisplayName: String
        let sourceURL: URL
        let sourceBundleIdentifier: String?
        let displayName: SearchText
        let packageName: SearchText
        let bundleIdentifier: String?
    }

    private let textByKey: [String: CandidateText]
    private var aliasesByKey: [String: SearchText]

    public init(candidates: [AppCandidate], aliases: [String: String] = [:]) {
        var textByKey: [String: CandidateText] = [:]
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            guard textByKey[candidate.deduplicationKey] == nil else { continue }
            textByKey[candidate.deduplicationKey] = CandidateText(
                sourceDisplayName: candidate.displayName,
                sourceURL: candidate.canonicalURL,
                sourceBundleIdentifier: candidate.bundleIdentifier,
                displayName: SearchText(candidate.displayName),
                packageName: SearchText(candidate.canonicalURL.deletingPathExtension().lastPathComponent),
                bundleIdentifier: candidate.bundleIdentifier.map(Self.normalize)
            )
        }
        self.textByKey = textByKey
        aliasesByKey = Self.indexAliases(aliases)
    }

    public mutating func setAliases(_ aliases: [String: String]) {
        aliasesByKey = Self.indexAliases(aliases)
    }

    public func filter(_ candidates: [AppCandidate], query: String) -> [AppCandidate] {
        let normalizedQuery = Self.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalizedQuery.isEmpty else { return candidates }

        return candidates.enumerated().compactMap { offset, candidate -> (Int, Int, AppCandidate)? in
            guard let rank = matchRank(of: candidate, query: normalizedQuery) else { return nil }
            return (rank, offset, candidate)
        }
        .sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        .map(\.2)
    }

    /// Display and alias matches outrank the package name, which outranks the bundle id.
    /// Equal ranks keep the layout order so Return opens the closest name.
    private func matchRank(of candidate: AppCandidate, query: String) -> Int? {
        let display: SearchText
        let package: SearchText
        let bundle: String?
        if let text = textByKey[candidate.deduplicationKey],
           text.sourceDisplayName == candidate.displayName,
           text.sourceURL == candidate.canonicalURL,
           text.sourceBundleIdentifier == candidate.bundleIdentifier {
            display = text.displayName
            package = text.packageName
            bundle = text.bundleIdentifier
        } else {
            display = SearchText(candidate.displayName)
            package = SearchText(candidate.canonicalURL.deletingPathExtension().lastPathComponent)
            bundle = candidate.bundleIdentifier.map(Self.normalize)
        }
        var ranks: [Int] = []
        if let rank = display.matchRank(for: query) {
            ranks.append(rank)
        }
        if let rank = aliasesByKey[candidate.deduplicationKey]?.matchRank(for: query) {
            ranks.append(rank)
        }
        if let rank = package.matchRank(for: query) {
            ranks.append(rank == 0 ? 2 : (rank == 1 ? 4 : 5))
        }
        if let bundle, let rank = SearchText(bundle).matchRank(for: query) {
            ranks.append(rank == 0 ? 6 : 8)
        }
        return ranks.min()
    }

    /// Same ranks as app filtering. A folder name uses the display-name ranks
    /// (exact, then prefix, then contains), including space-insensitive and
    /// pinyin forms. Equal ranks keep the order of `hits`.
    public func filter(_ hits: [LauncherSearchHit], query: String) -> [LauncherSearchHit] {
        let normalizedQuery = Self.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalizedQuery.isEmpty else { return hits }
        return hits.enumerated().compactMap { offset, hit -> (Int, Int, LauncherSearchHit)? in
            let rank: Int?
            switch hit {
            case .app(let candidate):
                rank = matchRank(of: candidate, query: normalizedQuery)
            case .folder(_, let name):
                rank = SearchText(name).matchRank(for: normalizedQuery)
            }
            guard let rank else { return nil }
            return (rank, offset, hit)
        }
        .sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        .map(\.2)
    }

    private static func indexAliases(_ aliases: [String: String]) -> [String: SearchText] {
        aliases.reduce(into: [:]) { result, entry in
            result[entry.key] = SearchText(entry.value)
        }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

public enum LauncherEntry: Codable, Hashable, Identifiable, Sendable {
    case app(UUID)
    case folder(UUID)

    public var id: UUID {
        switch self {
        case let .app(id), let .folder(id): id
        }
    }
}

public struct LauncherFolder: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var itemIDs: [UUID]
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, itemIDs: [UUID], createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
        self.createdAt = createdAt
    }
}

public struct LayoutState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var orderedEntries: [LauncherEntry]
    public var folders: [UUID: LauncherFolder]
    public var appKeys: [UUID: String]
    public var hiddenAppKeys: Set<String>
    public var appAliases: [String: String]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = LayoutState.currentSchemaVersion,
        orderedEntries: [LauncherEntry] = [],
        folders: [UUID: LauncherFolder] = [:],
        appKeys: [UUID: String] = [:],
        hiddenAppKeys: Set<String> = [],
        appAliases: [String: String] = [:],
        updatedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.orderedEntries = orderedEntries
        self.folders = folders
        self.appKeys = appKeys
        self.hiddenAppKeys = hiddenAppKeys
        self.appAliases = appAliases
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, orderedEntries, folders, appKeys, hiddenAppKeys, appAliases, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        orderedEntries = try container.decode([LauncherEntry].self, forKey: .orderedEntries)
        folders = try container.decodeIfPresent([UUID: LauncherFolder].self, forKey: .folders) ?? [:]
        appKeys = try container.decodeIfPresent([UUID: String].self, forKey: .appKeys) ?? [:]
        hiddenAppKeys = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenAppKeys) ?? []
        appAliases = try container.decodeIfPresent([String: String].self, forKey: .appAliases) ?? [:]
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(orderedEntries, forKey: .orderedEntries)
        try container.encode(folders, forKey: .folders)
        try container.encode(appKeys, forKey: .appKeys)
        try container.encode(hiddenAppKeys, forKey: .hiddenAppKeys)
        try container.encode(appAliases, forKey: .appAliases)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

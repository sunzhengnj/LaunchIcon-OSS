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
    /// Other physical bundles hidden by bundle-ID deduplication.
    public let duplicateCandidates: [AppCandidate]
    public let skippedPaths: [URL]
    public let unreadableMetadataPaths: [URL]
    public let unlaunchablePaths: [URL]
    /// User-added roots that are currently missing (unmounted volume).
    /// These do **not** block `canPersistReconciledLayout`; callers should
    /// retain prior candidates under these roots before reconcile.
    public let unavailableRequiredRootPaths: [URL]
    /// User-added roots whose scan stopped early (depth / app-count cap).
    /// Informational only — does **not** block `canPersistReconciledLayout`.
    public let truncatedScanRootPaths: [URL]
    public let wasCancelled: Bool

    /// An empty or identity-incomplete snapshot must not erase the user's saved arrangement.
    /// Missing optional/user roots are tracked separately and do not lock editing.
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
        duplicateCandidates: [AppCandidate] = [],
        unavailableRequiredRootPaths: [URL] = [],
        truncatedScanRootPaths: [URL] = [],
        wasCancelled: Bool = false
    ) {
        self.candidates = candidates
        self.duplicateCandidates = duplicateCandidates
        self.skippedPaths = skippedPaths
        self.unreadableMetadataPaths = unreadableMetadataPaths
        self.unlaunchablePaths = unlaunchablePaths
        self.unavailableRequiredRootPaths = unavailableRequiredRootPaths
        self.truncatedScanRootPaths = truncatedScanRootPaths
        self.wasCancelled = wasCancelled
    }

    /// MISSING-ROOT-PARTIAL-EDIT-01 — keep prior apps that lived under an
    /// unmounted required root so reconcile does not drop their layout slots.
    public func retainingCandidates(
        from previous: [AppCandidate],
        underUnavailableRoots roots: [URL] = []
    ) -> CatalogScanReport {
        let roots = roots.isEmpty ? unavailableRequiredRootPaths : roots
        guard !roots.isEmpty, !previous.isEmpty else { return self }
        let rootPaths = roots.map { AppCatalogScanner.normalizedRootPath($0.path) }
        let presentKeys = Set(candidates.map(\.deduplicationKey))
        var extras: [AppCandidate] = []
        for candidate in previous {
            let key = candidate.deduplicationKey
            guard !presentKeys.contains(key) else { continue }
            let path = AppCatalogScanner.normalizedRootPath(candidate.canonicalURL.path)
            guard rootPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            extras.append(candidate)
        }
        guard !extras.isEmpty else { return self }
        return CatalogScanReport(
            candidates: candidates + extras,
            skippedPaths: skippedPaths,
            unreadableMetadataPaths: unreadableMetadataPaths,
            unlaunchablePaths: unlaunchablePaths,
            duplicateCandidates: duplicateCandidates,
            unavailableRequiredRootPaths: unavailableRequiredRootPaths,
            truncatedScanRootPaths: truncatedScanRootPaths,
            wasCancelled: wasCancelled
        )
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
        /// First letter of each word, splitting on spaces/punctuation and
        /// camel-case humps ("Visual Studio Code" → "vsc", "GarageBand" → "gb").
        /// Nil for single-word names.
        let wordInitials: String?

        init(_ value: String) {
            normalized = Self.normalize(value)
            wordInitials = Self.wordInitials(of: value)
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
            if matchesWordInitials(query) { return true }
            return false
        }

        /// Abbreviation hit: a ≥2-letter query is a prefix of the word
        /// initials. SEARCH-INITIALS-RANK-01: ranks with word-start hits (3),
        /// after exact / prefix, ahead of plain contains ("ss" → System Settings
        /// before Chess / Messages).
        func matchesWordInitials(_ query: String) -> Bool {
            guard let wordInitials else { return false }
            let compactQuery = String(query.filter { !$0.isWhitespace })
            guard compactQuery.count >= 2 else { return false }
            return wordInitials.hasPrefix(compactQuery)
        }

        /// Typo fallback: a ≥5-character query without spaces is within one
        /// edit (insert, delete, substitute, or swap of neighbours) of the
        /// start of a word in the name or its pinyin. The first letter must
        /// agree so short queries do not pull in unrelated names.
        func matchesWithOneTypo(_ query: String) -> Bool {
            let needle = Array(query)
            guard needle.count >= 5, !needle.contains(where: { $0.isWhitespace }) else { return false }
            for field in [normalized, spacedLatin, compactLatin].compactMap({ $0 }) {
                let words = field.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                for word in words where word.first == needle.first {
                    let letters = Array(word)
                    for length in (needle.count - 1)...(needle.count + 1) where length <= letters.count {
                        if Self.isWithinOneEdit(needle, Array(letters.prefix(length))) { return true }
                    }
                }
            }
            return false
        }

        /// Optimal-string-alignment distance ≤ 1.
        static func isWithinOneEdit(_ a: [Character], _ b: [Character]) -> Bool {
            if a == b { return true }
            let (m, n) = (a.count, b.count)
            if abs(m - n) > 1 { return false }
            if m == n {
                let diffs = (0..<m).filter { a[$0] != b[$0] }
                if diffs.count == 1 { return true }
                if diffs.count == 2, diffs[1] == diffs[0] + 1,
                   a[diffs[0]] == b[diffs[1]], a[diffs[1]] == b[diffs[0]] { return true }
                return false
            }
            let (short, long) = m < n ? (a, b) : (b, a)
            var i = 0
            while i < short.count, short[i] == long[i] { i += 1 }
            return Array(short[i...]) == Array(long[(i + 1)...])
        }

        static func wordInitials(of value: String) -> String? {
            var result = ""
            var previous: Character?
            var words = 0
            for character in value {
                defer { previous = character }
                guard character.isLetter || character.isNumber else { continue }
                let startsWord: Bool
                if let previous {
                    if !previous.isLetter && !previous.isNumber {
                        startsWord = true
                    } else if character.isUppercase && previous.isLowercase {
                        startsWord = true
                    } else if character.isNumber != previous.isNumber {
                        startsWord = true
                    } else {
                        startsWord = false
                    }
                } else {
                    startsWord = true
                }
                if startsWord {
                    words += 1
                    result.append(character)
                }
            }
            guard words >= 2 else { return nil }
            return normalize(result)
        }

        /// Lower is a closer hit. Exact name, then prefix, then a match at the
        /// start of a later word ("code" in "Visual Studio Code"), then any
        /// other match.
        func matchRank(for query: String) -> Int? {
            guard matches(query) else { return nil }
            if isExact(query) { return 0 }
            if isPrefix(query) { return 1 }
            if isWordStart(query) || matchesWordInitials(query) { return 3 }
            return 4
        }

        private func isWordStart(_ query: String) -> Bool {
            if Self.hasWordStartMatch(normalized, query) { return true }
            if let spacedLatin, Self.hasWordStartMatch(spacedLatin, query) { return true }
            return false
        }

        /// `query` occurs right after a non-alphanumeric character (space,
        /// hyphen, dot, underscore…).
        static func hasWordStartMatch(_ field: String, _ query: String) -> Bool {
            guard !query.isEmpty else { return false }
            var searchRange = field.startIndex..<field.endIndex
            while let found = field.range(of: query, range: searchRange) {
                if found.lowerBound > field.startIndex {
                    let previous = field[field.index(before: found.lowerBound)]
                    if !previous.isLetter && !previous.isNumber { return true }
                }
                guard found.lowerBound < field.endIndex else { break }
                searchRange = field.index(after: found.lowerBound)..<field.endIndex
            }
            return false
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
    /// Order: name exact 0, name prefix 1, package exact 2, name word-start 3,
    /// name contains 4, package prefix 5, package other 6, bundle exact 7,
    /// bundle other 9, one-typo (≥5 chars) name/alias word start 10, package
    /// one-typo 11 (only when nothing else matched, so it never reorders real hits).
    /// Word initials rank with word starts (name 3, package 5).
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
            // SEARCH-INITIALS-RANK-01: package initials share the package-prefix tier.
            let initials = rank == 3 && package.matchesWordInitials(query)
            ranks.append(rank == 0 ? 2 : (rank == 1 || initials ? 5 : 6))
        }
        if let bundle, let rank = SearchText(bundle).matchRank(for: query) {
            ranks.append(rank == 0 ? 7 : 9)
        }
        if ranks.isEmpty,
           display.matchesWithOneTypo(query)
            || aliasesByKey[candidate.deduplicationKey]?.matchesWithOneTypo(query) == true {
            return 10
        }
        // SEARCH-TYPO-PACKAGE-01: a localized display name ("计算器") hides the
        // English bundle name; let "calculater" still find Calculator.app.
        if ranks.isEmpty, package.matchesWithOneTypo(query) {
            return 11
        }
        return ranks.min()
    }

    /// Same ranks as app filtering. A folder name uses the display-name ranks
    /// (exact, then prefix, then contains), including space-insensitive and
    /// pinyin forms. At equal match rank, top-level apps (keys in
    /// `topLevelKeys`) sort before folder members; folder name hits stay
    /// between those tiers. Remaining ties keep `hits` order.
    public func filter(
        _ hits: [LauncherSearchHit],
        query: String,
        topLevelKeys: Set<String> = []
    ) -> [LauncherSearchHit] {
        let normalizedQuery = Self.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalizedQuery.isEmpty else { return hits }
        return hits.enumerated().compactMap { offset, hit -> (Int, Int, Int, LauncherSearchHit)? in
            let rank: Int?
            switch hit {
            case .app(let candidate):
                rank = matchRank(of: candidate, query: normalizedQuery)
            case .folder(_, let name):
                rank = SearchText(name).matchRank(for: normalizedQuery)
            }
            guard let rank else { return nil }
            let placement = Self.searchHitPlacementTier(hit, topLevelKeys: topLevelKeys)
            return (rank, placement, offset, hit)
        }
        .sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 < rhs.2
        }
        .map(\.3)
    }

    /// Equal-rank tie-break: top-level apps, then folder name hits, then folder members.
    /// Empty `topLevelKeys` disables the tier (callers keep hit order only).
    private static func searchHitPlacementTier(
        _ hit: LauncherSearchHit,
        topLevelKeys: Set<String>
    ) -> Int {
        guard !topLevelKeys.isEmpty else { return 0 }
        switch hit {
        case .app(let candidate):
            return topLevelKeys.contains(candidate.deduplicationKey) ? 0 : 2
        case .folder:
            return 1
        }
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

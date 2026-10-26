import Foundation
import CryptoKit
import SQLite3

public protocol LayoutStoring: Sendable {
    func load() async throws -> LayoutState?
    func save(_ state: LayoutState) async throws
}

public enum LayoutStoreIssue: Error, Equatable {
    case unsupportedSchema(Int)
    case corruptedFile(URL)
}

public actor JSONLayoutStore: LayoutStoring {
    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }

    public nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LaunchIcon/layout-v1.json", directoryHint: .notDirectory)
    }

    public nonisolated let fileURL: URL
    /// Sibling of `fileURL`; nonisolated so Settings can probe existence without hopping the actor.
    public nonisolated let backupURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var recoveredCorruptPrimary: Data?

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.backupURL = fileURL.deletingPathExtension().appendingPathExtension("backup.json")
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func load() throws -> LayoutState? {
        try Task.checkCancellation()
        recoveredCorruptPrimary = nil
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try decode(at: fileURL)
        } catch LayoutStoreIssue.unsupportedSchema(let version) {
            try preserve(fileURL)
            throw LayoutStoreIssue.unsupportedSchema(version)
        } catch {
            try preserve(fileURL)
            if fileManager.fileExists(atPath: backupURL.path), let restored = try? decode(at: backupURL) {
                recoveredCorruptPrimary = try Data(contentsOf: fileURL)
                return restored
            }
            throw LayoutStoreIssue.corruptedFile(fileURL)
        }
    }

    public func save(_ state: LayoutState) throws {
        try Task.checkCancellation()
        guard state.schemaVersion == LayoutState.currentSchemaVersion else {
            throw LayoutStoreIssue.unsupportedSchema(state.schemaVersion)
        }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: fileURL.path) {
            let previousData = try Data(contentsOf: fileURL)
            let previousState: LayoutState?
            do {
                previousState = try decode(previousData)
            } catch LayoutStoreIssue.unsupportedSchema(let version) {
                throw LayoutStoreIssue.unsupportedSchema(version)
            } catch {
                previousState = nil
            }
            if let previousState {
                if previousState == state { return }
                try previousData.write(to: backupURL, options: .atomic)
            } else {
                guard previousData == recoveredCorruptPrimary else {
                    throw LayoutStoreIssue.corruptedFile(fileURL)
                }
            }
        }
        let temporaryURL = fileURL.deletingLastPathComponent().appendingPathComponent(".layout-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        let data = try encoder.encode(state)
        try data.write(to: temporaryURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
        recoveredCorruptPrimary = nil
    }

    /// True when the automatic previous-layout backup file exists on disk.
    public nonisolated var hasBackupFile: Bool {
        FileManager.default.fileExists(atPath: backupURL.path)
    }

    /// Decode the automatic backup written by the last successful `save` that changed state.
    public func loadBackup() throws -> LayoutState? {
        try Task.checkCancellation()
        guard fileManager.fileExists(atPath: backupURL.path) else { return nil }
        return try decode(at: backupURL)
    }

    /// Write `state` to a user-chosen URL without touching the live primary/backup pair.
    public func export(_ state: LayoutState, to url: URL) throws {
        try Task.checkCancellation()
        guard state.schemaVersion == LayoutState.currentSchemaVersion else {
            throw LayoutStoreIssue.unsupportedSchema(state.schemaVersion)
        }
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    /// Decode a user-chosen layout file (export or backup copy). Does not write the live store.
    /// Rejects oversized files (a real export is well under 1 MB) and cleans
    /// imported folder names / aliases the same way the in-app editors do.
    /// Structure (dangling ids, duplicates) is still repaired by `reconcile`.
    public func importLayout(from url: URL) throws -> LayoutState {
        try Task.checkCancellation()
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= JSONLayoutStore.maximumImportFileSize else {
            throw LayoutStoreIssue.corruptedFile(url)
        }
        return LauncherLayout.sanitizedImportedLayout(try decode(at: url))
    }

    /// Upper bound for a user-chosen import file (LAYOUT-IMPORT-HARDENING-01).
    public nonisolated static let maximumImportFileSize = 8 * 1024 * 1024

    private func decode(at url: URL) throws -> LayoutState {
        try decode(Data(contentsOf: url))
    }

    private func decode(_ data: Data) throws -> LayoutState {
        // A newer schema can change every other field, so check its version
        // before interpreting the current layout or recovering an old backup.
        let header = try decoder.decode(SchemaHeader.self, from: data)
        guard header.schemaVersion == LayoutState.currentSchemaVersion else {
            throw LayoutStoreIssue.unsupportedSchema(header.schemaVersion)
        }
        return try decoder.decode(LayoutState.self, from: data)
    }

    private func preserve(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let preservedURL = url.deletingPathExtension().appendingPathExtension("invalid-\(digest).json")
        guard !fileManager.fileExists(atPath: preservedURL.path) else { return }
        do {
            try fileManager.copyItem(at: url, to: preservedURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileWriteFileExistsError {
            // Another instance preserved the same content first.
        }
    }
}

// MARK: - Native Launchpad layout import (LAUNCHPAD-IMPORT-CORE-01)

/// Order and folders read from the pre-macOS 26 Launchpad database
/// (`$(getconf DARWIN_USER_DIR)/com.apple.dock.launchpad/db/db`).
/// Page breaks are flattened: LaunchIcon pages are derived from the grid.
public struct LaunchpadLayoutSnapshot: Equatable, Sendable {
    public struct App: Equatable, Sendable {
        public var bundleIdentifier: String?
        public var title: String
        public init(bundleIdentifier: String?, title: String) {
            self.bundleIdentifier = bundleIdentifier
            self.title = title
        }
    }

    public enum Item: Equatable, Sendable {
        case app(App)
        case folder(title: String, apps: [App])
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    public var appCount: Int {
        items.reduce(0) { total, item in
            switch item {
            case .app: total + 1
            case let .folder(_, apps): total + apps.count
            }
        }
    }

    public var folderCount: Int {
        items.reduce(0) { total, item in
            if case .folder = item { return total + 1 }
            return total
        }
    }
}

public enum LaunchpadLayoutImporter {
    public enum Failure: Error, Equatable {
        case unreadable
        case notLaunchpadDatabase
        case empty
    }

    /// One `items` row. Types: 1 root, 2 folder, 3 page, 4 app (5+ ignored).
    public struct ItemRow: Equatable, Sendable {
        public var rowID: Int64
        public var type: Int
        public var parentID: Int64
        public var ordering: Int
        public var uuid: String?
        public init(rowID: Int64, type: Int, parentID: Int64, ordering: Int, uuid: String? = nil) {
            self.rowID = rowID
            self.type = type
            self.parentID = parentID
            self.ordering = ordering
            self.uuid = uuid
        }
    }

    static let rootType = 1
    static let folderType = 2
    static let pageType = 3
    static let appType = 4

    /// Where macOS kept the Launchpad database; nil when it does not exist.
    public static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 else { return nil }
        let path = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let base = URL(fileURLWithPath: path, isDirectory: true)
        let url = base.appendingPathComponent("com.apple.dock.launchpad/db/db")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Reads the database read-only. Never writes or locks it for writing.
    public static func read(databaseAt url: URL) throws -> LaunchpadLayoutSnapshot {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Failure.unreadable
        }
        guard let items = query(db, "SELECT rowid, type, parent_id, ordering, uuid FROM items", { stmt in
            ItemRow(
                rowID: sqlite3_column_int64(stmt, 0),
                type: Int(sqlite3_column_int(stmt, 1)),
                parentID: sqlite3_column_int64(stmt, 2),
                ordering: Int(sqlite3_column_int(stmt, 3)),
                uuid: text(stmt, 4)
            )
        }) else {
            throw Failure.notLaunchpadDatabase
        }
        var apps: [Int64: LaunchpadLayoutSnapshot.App] = [:]
        for (id, app) in query(db, "SELECT item_id, title, bundleid FROM apps", { stmt in
            (sqlite3_column_int64(stmt, 0),
             LaunchpadLayoutSnapshot.App(bundleIdentifier: text(stmt, 2), title: text(stmt, 1) ?? ""))
        }) ?? [] {
            apps[id] = app
        }
        var groups: [Int64: String] = [:]
        for (id, title) in query(db, "SELECT item_id, title FROM groups", { stmt in
            (sqlite3_column_int64(stmt, 0), text(stmt, 1) ?? "")
        }) ?? [] {
            groups[id] = title
        }
        let snapshot = snapshot(rows: items, apps: apps, groupTitles: groups)
        guard snapshot.appCount > 0 else { throw Failure.empty }
        return snapshot
    }

    /// Builds root → pages → (apps | folders → pages → apps), each level in
    /// `ordering` order. The root is `ROOTPAGE`, else the lowest type-1 row.
    public static func snapshot(
        rows: [ItemRow],
        apps: [Int64: LaunchpadLayoutSnapshot.App],
        groupTitles: [Int64: String]
    ) -> LaunchpadLayoutSnapshot {
        let roots = rows.filter { $0.type == rootType }
        guard let root = roots.first(where: { $0.uuid == "ROOTPAGE" })
            ?? roots.min(by: { $0.rowID < $1.rowID }) else {
            return LaunchpadLayoutSnapshot(items: [])
        }
        var children: [Int64: [ItemRow]] = [:]
        for row in rows where row.rowID != row.parentID {
            children[row.parentID, default: []].append(row)
        }
        func ordered(_ parent: Int64) -> [ItemRow] {
            (children[parent] ?? []).sorted {
                $0.ordering != $1.ordering ? $0.ordering < $1.ordering : $0.rowID < $1.rowID
            }
        }
        var seenApps = Set<Int64>()
        func app(_ row: ItemRow) -> LaunchpadLayoutSnapshot.App? {
            guard row.type == appType, let app = apps[row.rowID], seenApps.insert(row.rowID).inserted else {
                return nil
            }
            return app
        }
        func folderApps(_ folder: ItemRow) -> [LaunchpadLayoutSnapshot.App] {
            var result: [LaunchpadLayoutSnapshot.App] = []
            for child in ordered(folder.rowID) {
                if child.type == pageType {
                    result += ordered(child.rowID).compactMap(app)
                } else if let direct = app(child) {
                    result.append(direct)
                }
            }
            return result
        }
        var items: [LaunchpadLayoutSnapshot.Item] = []
        for page in ordered(root.rowID) where page.type == pageType {
            for row in ordered(page.rowID) {
                if row.type == folderType {
                    let members = folderApps(row)
                    guard !members.isEmpty else { continue }
                    items.append(.folder(title: groupTitles[row.rowID] ?? "", apps: members))
                } else if let single = app(row) {
                    items.append(.app(single))
                }
            }
        }
        return LaunchpadLayoutSnapshot(items: items)
    }

    /// Applies the Launchpad order to `base`. Apps match installed candidates
    /// by bundle id, else by a unique display name. Folders keep their title
    /// and need two installed members (one left → plain app, like Launchpad).
    /// Installed apps Launchpad did not know keep their order after the
    /// imported ones (their old folders are dissolved). Hidden apps and
    /// aliases are kept. `reconcile` still runs afterwards.
    public static func layoutState(
        from snapshot: LaunchpadLayoutSnapshot,
        candidates: [AppCandidate],
        base: LayoutState,
        defaultFolderName: String = "文件夹",
        now: Date = .now
    ) -> LayoutState {
        var keyByBundle: [String: String] = [:]
        var keysByName: [String: [String]] = [:]
        for candidate in candidates {
            let key = candidate.deduplicationKey
            if let bundle = candidate.bundleIdentifier?.lowercased(), !bundle.isEmpty, keyByBundle[bundle] == nil {
                keyByBundle[bundle] = key
            }
            keysByName[candidate.displayName.lowercased(), default: []].append(key)
        }
        func key(for app: LaunchpadLayoutSnapshot.App) -> String? {
            if let bundle = app.bundleIdentifier?.lowercased(), let key = keyByBundle[bundle] { return key }
            let named = Set(keysByName[app.title.lowercased()] ?? [])
            return named.count == 1 ? named.first : nil
        }

        var idByKey: [String: UUID] = [:]
        for (id, key) in base.appKeys where idByKey[key] == nil { idByKey[key] = id }
        var appKeys: [UUID: String] = [:]
        var placed = Set<String>()
        func appID(_ key: String) -> UUID {
            let id = idByKey[key] ?? UUID()
            idByKey[key] = id
            appKeys[id] = key
            placed.insert(key)
            return id
        }

        var entries: [LauncherEntry] = []
        var folders: [UUID: LauncherFolder] = [:]
        for item in snapshot.items {
            switch item {
            case let .app(app):
                guard let key = key(for: app), !placed.contains(key) else { continue }
                entries.append(.app(appID(key)))
            case let .folder(title, apps):
                var memberKeys: [String] = []
                for app in apps {
                    guard let key = key(for: app), !placed.contains(key), !memberKeys.contains(key) else { continue }
                    memberKeys.append(key)
                }
                if memberKeys.count == 1 {
                    entries.append(.app(appID(memberKeys[0])))
                } else if memberKeys.count > 1 {
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let folder = LauncherFolder(
                        name: trimmed.isEmpty ? defaultFolderName : trimmed,
                        itemIDs: memberKeys.map(appID),
                        createdAt: now
                    )
                    folders[folder.id] = folder
                    entries.append(.folder(folder.id))
                }
            }
        }

        // Apps Launchpad did not list keep their old relative order.
        func keepRemaining(_ id: UUID) {
            guard let key = base.appKeys[id], !placed.contains(key) else { return }
            entries.append(.app(appID(key)))
        }
        for entry in base.orderedEntries {
            switch entry {
            case let .app(id): keepRemaining(id)
            case let .folder(id): base.folders[id]?.itemIDs.forEach(keepRemaining)
            }
        }

        var state = base
        state.orderedEntries = entries
        state.folders = folders
        state.appKeys = appKeys
        state.updatedAt = now
        return state
    }

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: pointer)
    }

    private static func query<T>(
        _ db: OpaquePointer,
        _ sql: String,
        _ row: (OpaquePointer?) -> T
    ) -> [T]? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        var result: [T] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                result.append(row(stmt))
            } else if step == SQLITE_DONE {
                return result
            } else {
                return nil
            }
        }
    }
}

import Foundation
import CryptoKit

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
    public let backupURL: URL
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

import Foundation

public actor CatalogSnapshotStore {
    private struct Snapshot: Codable {
        let schemaVersion: Int
        let candidates: [AppCandidate]
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [AppCandidate]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.schemaVersion == 1,
              !snapshot.candidates.isEmpty,
              Set(snapshot.candidates.map(\.deduplicationKey)).count == snapshot.candidates.count else { return nil }
        return snapshot.candidates
    }

    public func save(_ report: CatalogScanReport) throws {
        guard report.canPersistReconciledLayout else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let snapshot = Snapshot(schemaVersion: 1, candidates: report.candidates)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }
}

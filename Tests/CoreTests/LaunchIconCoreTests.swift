import Foundation
import CoreServices
import AppKit
import XCTest
@testable import LaunchIconCore

private final class IconDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    var count: Int {
        lock.withLock { value }
    }
}

private final class IconDecodeActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var startedCount = 0
    private var activeCount = 0
    private var peakActiveCount = 0

    func start() -> (started: Int, active: Int) {
        lock.withLock {
            startedCount += 1
            activeCount += 1
            peakActiveCount = max(peakActiveCount, activeCount)
            return (startedCount, activeCount)
        }
    }

    func finish() {
        lock.withLock { activeCount -= 1 }
    }

    var counts: (started: Int, peakActive: Int) {
        lock.withLock { (startedCount, peakActiveCount) }
    }
}

private final class CancelOnRootAttributesFileManager: FileManager, @unchecked Sendable {
    var cancellationPath: String = ""

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if path == cancellationPath {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return try super.attributesOfItem(atPath: path)
    }
}

final class LaunchIconCoreTests: XCTestCase {
    func testReducedMotionChangeUsesEffectivePreference() {
        let systemReducedMotion = true
        let beforeAppToggle = false || systemReducedMotion
        let afterAppToggle = true || systemReducedMotion
        XCTAssertFalse(LauncherLayout.shouldApplyReducedMotionChange(
            previousEffective: beforeAppToggle,
            currentEffective: afterAppToggle
        ))
        XCTAssertTrue(LauncherLayout.shouldApplyReducedMotionChange(
            previousEffective: false,
            currentEffective: true
        ))
        XCTAssertFalse(LauncherLayout.shouldApplyReducedMotionChange(
            previousEffective: true,
            currentEffective: true
        ))
    }

    func testCancelledPartialScanCannotBePersisted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-CancelledScan-\(UUID().uuidString)", isDirectory: true)
        let firstRoot = directory.appendingPathComponent("First", isDirectory: true)
        let secondRoot = directory.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(
            at: firstRoot.appendingPathComponent("Calculator.app"),
            withDestinationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app")
        )
        try Data("marker".utf8).write(to: secondRoot.appendingPathComponent("Marker.txt"))

        let fileManager = CancelOnRootAttributesFileManager()
        fileManager.cancellationPath = secondRoot.path
        let report = await AppCatalogScanner(fileManager: fileManager).scan(roots: [firstRoot, secondRoot])

        XCTAssertEqual(report.candidates.map(\.bundleIdentifier), ["com.apple.calculator"])
        XCTAssertTrue(report.skippedPaths.isEmpty)
        XCTAssertTrue(report.unreadableMetadataPaths.isEmpty)
        XCTAssertTrue(report.wasCancelled)
        XCTAssertFalse(report.canPersistReconciledLayout)

        let store = CatalogSnapshotStore(fileURL: directory.appendingPathComponent("catalog-v1.json"))
        let previousCandidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Previous.app"),
            bundleIdentifier: "com.example.previous",
            displayName: "Previous",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        try await store.save(CatalogScanReport(candidates: [previousCandidate], skippedPaths: []))
        try await store.save(report)
        let saved = try await store.load()
        XCTAssertEqual(saved, [previousCandidate])
    }

    func testCatalogSnapshotOnlyChangesAfterCompleteScan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-CatalogSnapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog-v1.json")
        let store = CatalogSnapshotStore(fileURL: url)
        let candidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Example.app"),
            bundleIdentifier: "com.example.app",
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )

        let initial = try await store.load()
        XCTAssertNil(initial)
        try await store.save(CatalogScanReport(candidates: [candidate], skippedPaths: []))
        let saved = try await store.load()
        XCTAssertEqual(saved, [candidate])
        let completeData = try Data(contentsOf: url)

        try await store.save(CatalogScanReport(candidates: [], skippedPaths: []))
        try await store.save(CatalogScanReport(candidates: [candidate], skippedPaths: [url]))
        XCTAssertEqual(try Data(contentsOf: url), completeData)

        let damagedData = Data("not JSON".utf8)
        try damagedData.write(to: url)
        do {
            _ = try await store.load()
            XCTFail("A damaged snapshot should not be shown")
        } catch {
            XCTAssertEqual(try Data(contentsOf: url), damagedData)
        }
    }

    func testCatalogSnapshotRejectsDuplicateApplicationIdentities() async throws {
        struct SnapshotFixture: Encodable {
            let schemaVersion: Int
            let candidates: [AppCandidate]
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-DuplicateCatalogSnapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog-v1.json")
        let store = CatalogSnapshotStore(fileURL: url)
        let candidates = ["First", "Second"].map { name in
            AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                bundleIdentifier: "com.example.duplicate",
                displayName: name,
                sourcePriority: 0,
                discoveredAt: .distantPast
            )
        }
        let valid = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Valid.app"),
            bundleIdentifier: "com.example.valid",
            displayName: "Valid",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        try await store.save(CatalogScanReport(candidates: [valid], skippedPaths: []))
        let original = try Data(contentsOf: url)
        let duplicateReport = CatalogScanReport(candidates: candidates, skippedPaths: [])
        XCTAssertFalse(duplicateReport.canPersistReconciledLayout)
        try await store.save(duplicateReport)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let preserved = try await store.load()
        XCTAssertEqual(preserved, [valid])

        let malformed = try JSONEncoder().encode(SnapshotFixture(schemaVersion: 1, candidates: candidates))
        try malformed.write(to: url)
        let loaded = try await store.load()
        XCTAssertNil(loaded)
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }

    func testIsolatedLaunchLeavesUserEvidenceAndDiagnosticsUntouched() throws {
        if ProcessInfo.processInfo.environment["LAUNCHICON_DIAGNOSTICS_PATH"] != nil {
            throw XCTSkip("A diagnostics path override is active")
        }
        let suiteName = "com.sunzheng.LaunchIcon.EvidenceIsolation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bundleIdentifier = "com.sunzheng.LaunchIcon.EvidenceIsolation.\(UUID().uuidString)"
        let log = LocalDiagnostics.fileURL(for: bundleIdentifier)
        defer { try? FileManager.default.removeItem(at: log) }

        let isolatedCases = [
            ["LAUNCHICON_TEST_LAYOUT_PATH": "/tmp/LaunchIcon-isolated-layout.json"],
            ["LAUNCHICON_TEST_PREFERENCES_SUITE": suiteName],
            [
                "LAUNCHICON_TEST_LAYOUT_PATH": "  /tmp/LaunchIcon-isolated-layout.json  ",
                "LAUNCHICON_TEST_PREFERENCES_SUITE": "  \(suiteName)  "
            ],
            ["LAUNCHICON_TEST_LAYOUT_PATH": "   ", "LAUNCHICON_TEST_PREFERENCES_SUITE": ""]
        ]
        for environment in isolatedCases.dropLast() {
            LocalDiagnostics.appendEvidence(
                "isolated-line",
                environment: environment,
                defaults: defaults,
                bundleIdentifier: bundleIdentifier
            )
        }
        XCTAssertNil(defaults.stringArray(forKey: "M0SpikeEvidence"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))

        let isolatedLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-isolated-diagnostics-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: isolatedLog) }
        LocalDiagnostics.appendEvidence(
            "isolated-file-line",
            environment: [
                "LAUNCHICON_TEST_LAYOUT_PATH": "/tmp/LaunchIcon-isolated-layout.json",
                "LAUNCHICON_DIAGNOSTICS_PATH": isolatedLog.path
            ],
            defaults: defaults,
            bundleIdentifier: bundleIdentifier
        )
        XCTAssertNil(defaults.stringArray(forKey: "M0SpikeEvidence"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertTrue(try String(contentsOf: isolatedLog, encoding: .utf8).contains("isolated-file-line"))

        LocalDiagnostics.appendEvidence(
            "real-line",
            environment: isolatedCases[3],
            defaults: defaults,
            bundleIdentifier: bundleIdentifier
        )
        XCTAssertEqual(defaults.stringArray(forKey: "M0SpikeEvidence"), ["real-line"])
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("real-line"))
        XCTAssertFalse(text.contains("isolated-line"))
    }

    func testLocalDiagnosticsKeepsEveryConcurrentAppend() throws {
        if ProcessInfo.processInfo.environment["LAUNCHICON_DIAGNOSTICS_PATH"] != nil {
            throw XCTSkip("A diagnostics path override is active")
        }
        let bundleIdentifier = "com.sunzheng.LaunchIcon.DiagnosticsTests.\(UUID().uuidString)"
        let url = LocalDiagnostics.fileURL(for: bundleIdentifier)
        defer { try? FileManager.default.removeItem(at: url) }

        let recordCount = 200
        DispatchQueue.concurrentPerform(iterations: recordCount) { index in
            LocalDiagnostics.append("record-\(index)", bundleIdentifier: bundleIdentifier)
        }

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { $0.split(separator: " ", maxSplits: 1).last.map(String.init) }
        XCTAssertEqual(lines.count, recordCount)
        XCTAssertEqual(Set(lines), Set((0..<recordCount).map { "record-\($0)" }))
    }

    func testLocalDiagnosticsBoundsLogAndKeepsNewestRecords() throws {
        if ProcessInfo.processInfo.environment["LAUNCHICON_DIAGNOSTICS_PATH"] != nil {
            throw XCTSkip("A diagnostics path override is active")
        }
        let bundleIdentifier = "com.sunzheng.LaunchIcon.DiagnosticsLimitTests.\(UUID().uuidString)"
        let url = LocalDiagnostics.fileURL(for: bundleIdentifier)
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = String(repeating: "x", count: 8_192)
        for index in 0..<300 {
            LocalDiagnostics.append("record-\(index):\(payload)", bundleIdentifier: bundleIdentifier)
        }

        let data = try Data(contentsOf: url)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertLessThanOrEqual(data.count, 1_048_576)
        XCTAssertTrue(text.contains("record-299:"))
        XCTAssertFalse(text.contains("record-0:"))
        XCTAssertTrue(text.split(separator: "\n").allSatisfy { $0.contains("record-") })
    }

    func testLocalDiagnosticsTruncatesAnOversizedSingleRecord() throws {
        if ProcessInfo.processInfo.environment["LAUNCHICON_DIAGNOSTICS_PATH"] != nil {
            throw XCTSkip("A diagnostics path override is active")
        }
        let bundleIdentifier = "com.sunzheng.LaunchIcon.DiagnosticsOversizedRecordTests.\(UUID().uuidString)"
        let url = LocalDiagnostics.fileURL(for: bundleIdentifier)
        defer { try? FileManager.default.removeItem(at: url) }

        LocalDiagnostics.append(
            "oversized:\(String(repeating: "界", count: 400_000))",
            bundleIdentifier: bundleIdentifier
        )

        let data = try Data(contentsOf: url)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertLessThanOrEqual(data.count, 1_048_576)
        XCTAssertTrue(text.contains("oversized:"))
        XCTAssertTrue(text.hasSuffix("[truncated]\n"))
    }

    func testLauncherPreferencesRoundTripAndDefaults() async throws {
        let suiteName = "com.sunzheng.LaunchIcon.Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LauncherPreferencesStore(suiteName: suiteName)

        let initial = await store.load()
        XCTAssertEqual(initial, LauncherPreferences())
        let changed = LauncherPreferences(
            shortcut: .optionShiftSpace,
            showsStatusItem: false,
            hidesAfterLaunch: false,
            reducesMotion: true
        )
        await store.save(changed)
        let restored = await store.load()
        XCTAssertEqual(restored, changed)
        defaults.set("unrecognized", forKey: "LaunchIcon.Preferences.shortcut")
        let fallback = await store.load()
        XCTAssertEqual(fallback.shortcut, .optionSpace)
    }

    func testStandardRootsPreferUserThenSharedThenSystemAndCryptexApplications() {
        let roots = AppCatalogScanner.standardRoots.map(\.standardizedFileURL.path)
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).standardizedFileURL.path
        XCTAssertEqual(
            roots,
            [
                userApplications,
                "/Applications",
                "/System/Applications",
                "/System/Cryptexes/App/System/Applications"
            ]
        )
    }

    func testSystemApplicationUsesAvailableLocalizedDisplayName() async throws {
        let clockURL = URL(fileURLWithPath: "/System/Applications/Clock.app")
        guard let metadata = MDItemCreate(kCFAllocatorDefault, clockURL.path as NSString),
              let localizedName = MDItemCopyAttribute(metadata, kMDItemDisplayName) as? String,
              localizedName != "Clock" else {
            throw XCTSkip("This Mac does not provide a localized Clock display name")
        }

        let report = await AppCatalogScanner().scan(roots: [clockURL.deletingLastPathComponent()])
        let clock = try XCTUnwrap(report.candidates.first { $0.canonicalURL == clockURL })
        XCTAssertEqual(clock.displayName, localizedName)
    }

    func testDeduplicatePrefersEarlierRootForSameBundleIdentifier() {
        let applications = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Example.app"),
            bundleIdentifier: "com.example.app",
            displayName: "Example",
            sourcePriority: 1,
            discoveredAt: .now
        )
        let userApplications = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Users/test/Applications/Example.app"),
            bundleIdentifier: "com.example.app",
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )

        XCTAssertEqual(AppCatalogScanner.deduplicate([applications, userApplications]), [userApplications])
    }

    func testDeduplicateTreatsBlankBundleIdentifiersAsMissing() {
        let first = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/First.app"),
            bundleIdentifier: "  ",
            displayName: "First",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let second = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Second.app"),
            bundleIdentifier: "  ",
            displayName: "Second",
            sourcePriority: 0,
            discoveredAt: .now
        )

        XCTAssertEqual(first.deduplicationKey, "url:/applications/first.app")
        XCTAssertNotEqual(first.deduplicationKey, second.deduplicationKey)
        XCTAssertEqual(AppCatalogScanner.deduplicate([first, second]), [first, second])
    }

    func testScanPrefersExecutableDuplicateOverBrokenHigherPriorityCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let userRoot = root.appendingPathComponent("UserApplications", isDirectory: true)
        let sharedRoot = root.appendingPathComponent("SharedApplications", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for applicationsRoot in [userRoot, sharedRoot] {
            let contents = applicationsRoot.appendingPathComponent("Example.app/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.launchicon.duplicate-test",
                "CFBundleName": "Example",
                "CFBundlePackageType": "APPL",
                "CFBundleExecutable": "Example"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let executable = sharedRoot.appendingPathComponent("Example.app/Contents/MacOS/Example")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))

        let report = await AppCatalogScanner().scan(roots: [userRoot, sharedRoot])
        XCTAssertEqual(report.candidates.map(\.canonicalURL), [sharedRoot.appendingPathComponent("Example.app")])
        XCTAssertTrue(report.skippedPaths.isEmpty)

        let userExecutable = userRoot.appendingPathComponent("Example.app/Contents/MacOS/Example")
        try FileManager.default.createDirectory(at: userExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: userExecutable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let bothExecutable = await AppCatalogScanner().scan(roots: [userRoot, sharedRoot])
        XCTAssertEqual(bothExecutable.candidates.map(\.canonicalURL), [userRoot.appendingPathComponent("Example.app")])
    }

    func testDisambiguateDisplayNamesPrefersApplicationBundleNameThenBundleIdentifier() {
        let classic = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/ChatGPT Classic.app"),
            bundleIdentifier: "com.openai.chat",
            displayName: "ChatGPT",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let codex = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            bundleIdentifier: "com.openai.codex",
            displayName: "ChatGPT",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let firstDuplicate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Example One.app"),
            bundleIdentifier: "com.example.one",
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let secondDuplicate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Example Two.app"),
            bundleIdentifier: "com.example.two",
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )

        let displayNames = AppCatalogScanner.disambiguateDisplayNames(
            [classic, codex, firstDuplicate, secondDuplicate]
        ).map(\.displayName)

        XCTAssertEqual(
            displayNames,
            ["ChatGPT Classic", "ChatGPT", "Example One", "Example Two"]
        )

        let samePackageFirst = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Example.app"),
            bundleIdentifier: "com.example.one",
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let samePackageSecond = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Users/test/Applications/Example.app"),
            bundleIdentifier: "com.example.two",
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )
        XCTAssertEqual(
            AppCatalogScanner.disambiguateDisplayNames([samePackageFirst, samePackageSecond]).map(\.displayName),
            ["Example — com.example.one", "Example — com.example.two"]
        )

        let missingBundleFirst = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Example.app"),
            bundleIdentifier: nil,
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let missingBundleSecond = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Users/test/Applications/Example.app"),
            bundleIdentifier: nil,
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )
        XCTAssertEqual(
            AppCatalogScanner.disambiguateDisplayNames([missingBundleFirst, missingBundleSecond]).map(\.displayName),
            ["Example — /Applications", "Example — test/Applications"]
        )

        let blankBundleFirst = AppCandidate(
            canonicalURL: missingBundleFirst.canonicalURL,
            bundleIdentifier: "  ",
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let blankBundleSecond = AppCandidate(
            canonicalURL: missingBundleSecond.canonicalURL,
            bundleIdentifier: "  ",
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )
        XCTAssertEqual(
            AppCatalogScanner.disambiguateDisplayNames([blankBundleFirst, blankBundleSecond]).map(\.displayName),
            ["Example — /Applications", "Example — test/Applications"]
        )

        let nestedFirst = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Long/Shared/Path/Alpha/Example.app"),
            bundleIdentifier: "  ",
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let nestedSecond = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Long/Shared/Path/Beta/Example.app"),
            bundleIdentifier: "  ",
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )
        XCTAssertEqual(
            AppCatalogScanner.disambiguateDisplayNames([nestedFirst, nestedSecond]).map(\.displayName),
            ["Example — Alpha", "Example — Beta"]
        )

        let identifierClash = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Other/Example.app"),
            bundleIdentifier: "Alpha",
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .now
        )
        XCTAssertEqual(
            AppCatalogScanner.disambiguateDisplayNames([identifierClash, nestedFirst]).map(\.displayName),
            ["Example — Alpha", "Example — Path/Alpha"]
        )
    }

    func testLayoutStoreRoundTripsAndCreatesBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONLayoutStore(fileURL: directory.appendingPathComponent("layout-v1.json"))
        let first = LayoutState(orderedEntries: [.app(UUID())])
        try await store.save(first)
        let second = LayoutState(orderedEntries: [.folder(UUID())])
        try await store.save(second)

        let loaded = try await store.load()
        let backupURL = await store.backupURL
        XCTAssertEqual(loaded, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testUnchangedCatalogDoesNotRewriteLayoutOrCreateBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layout-v1.json")
        let store = JSONLayoutStore(fileURL: url)
        let candidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Existing.app"),
            bundleIdentifier: "com.example.existing",
            displayName: "Existing",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let id = UUID()
        let stored = LayoutState(
            orderedEntries: [.app(id)],
            appKeys: [id: candidate.deduplicationKey],
            updatedAt: Date(timeIntervalSinceReferenceDate: 123_456)
        )
        try await store.save(stored)
        let originalData = try Data(contentsOf: url)

        let loaded = try await store.load()
        let reconciled = LauncherLayout.reconcile(candidates: [candidate], into: try XCTUnwrap(loaded))
        XCTAssertEqual(reconciled, stored)
        try await store.save(reconciled)

        XCTAssertEqual(try Data(contentsOf: url), originalData)
        let backupURL = await store.backupURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testUnchangedFolderNameDoesNotRewriteLayout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layout-v1.json")
        let store = JSONLayoutStore(fileURL: url)
        let folderID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let stored = LayoutState(
            orderedEntries: [.folder(folderID)],
            folders: [folderID: LauncherFolder(id: folderID, name: "测试", itemIDs: [firstID, secondID])],
            appKeys: [firstID: "bundle:first", secondID: "bundle:second"],
            updatedAt: Date(timeIntervalSinceReferenceDate: 123_456)
        )
        try await store.save(stored)
        let originalData = try Data(contentsOf: url)

        let renamed = LauncherLayout.renameFolder(folderID, to: "测试", in: stored)
        XCTAssertEqual(renamed, stored)
        try await store.save(renamed)
        XCTAssertEqual(try Data(contentsOf: url), originalData)
        let backupURL = await store.backupURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testUnchangedAliasDoesNotRewriteLayout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layout-v1.json")
        let store = JSONLayoutStore(fileURL: url)
        let key = "bundle:com.example.existing"
        let stored = LayoutState(
            appKeys: [UUID(): key],
            appAliases: [key: "常用应用"],
            updatedAt: Date(timeIntervalSinceReferenceDate: 123_456)
        )
        try await store.save(stored)
        let originalData = try Data(contentsOf: url)

        let unchanged = LauncherLayout.setAlias(" 常用应用 ", forApplicationKey: key, in: stored)
        XCTAssertEqual(unchanged, stored)
        try await store.save(unchanged)
        XCTAssertEqual(try Data(contentsOf: url), originalData)
        let backupURL = await store.backupURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))

        let empty = LayoutState(updatedAt: Date(timeIntervalSinceReferenceDate: 123_456))
        XCTAssertEqual(LauncherLayout.setAlias("   ", forApplicationKey: key, in: empty), empty)

        let changed = LauncherLayout.setAlias("新别名", forApplicationKey: key, in: stored)
        XCTAssertEqual(changed.appAliases[key], "新别名")
        XCTAssertNotEqual(changed.updatedAt, stored.updatedAt)
        try await store.save(changed)
        XCTAssertNotEqual(try Data(contentsOf: url), originalData)
        XCTAssertEqual(try Data(contentsOf: backupURL), originalData)
    }

    func testSavingRecoveredLayoutPreservesLastValidBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layout-v1.json")
        let store = JSONLayoutStore(fileURL: url)
        let lastValidBackup = LayoutState(orderedEntries: [.app(UUID())])
        try await store.save(lastValidBackup)
        try await store.save(LayoutState(orderedEntries: [.folder(UUID())]))
        try Data("corrupted primary".utf8).write(to: url)

        let loaded = try await store.load()
        let recovered = try XCTUnwrap(loaded)
        XCTAssertEqual(recovered, lastValidBackup)
        try await store.save(recovered)

        let backupURL = await store.backupURL
        let backup = try JSONDecoder().decode(LayoutState.self, from: Data(contentsOf: backupURL))
        XCTAssertEqual(backup, lastValidBackup)
    }

    func testDirectSaveRefusesToReplaceCorruptedPrimary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layout-v1.json")
        let store = JSONLayoutStore(fileURL: url)
        let damagedData = Data("corrupted primary".utf8)
        try await store.save(LayoutState(orderedEntries: [.app(UUID())]))
        try await store.save(LayoutState(orderedEntries: [.folder(UUID())]))
        let backupURL = await store.backupURL
        let backupData = try Data(contentsOf: backupURL)
        try damagedData.write(to: url)

        let replacement = LayoutState(orderedEntries: [.app(UUID())])
        await XCTAssertThrowsErrorAsync(try await store.save(replacement)) { error in
            XCTAssertEqual(error as? LayoutStoreIssue, .corruptedFile(url))
        }
        XCTAssertEqual(try Data(contentsOf: url), damagedData)
        XCTAssertEqual(try Data(contentsOf: backupURL), backupData)
    }

    func testFailedLayoutReplacementDoesNotLeaveTemporaryFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("layout-v1.json")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try await JSONLayoutStore(fileURL: url).save(LayoutState(orderedEntries: [.app(UUID())]))
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        let store = JSONLayoutStore(fileURL: url)

        await XCTAssertThrowsErrorAsync(try await store.save(LayoutState(orderedEntries: [.app(UUID())]))) { _ in }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".layout-") && $0.pathExtension == "tmp" }
        XCTAssertTrue(temporaryFiles.isEmpty)
    }

    func testRecoveredLayoutDoesNotOverwritePrimaryChangedAfterLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layout-v1.json")
        let store = JSONLayoutStore(fileURL: url)
        let original = LayoutState(orderedEntries: [.app(UUID())])
        try await store.save(original)
        try await store.save(LayoutState(orderedEntries: [.folder(UUID())]))
        let backupURL = await store.backupURL
        let backupData = try Data(contentsOf: backupURL)
        try Data("first damaged primary".utf8).write(to: url)

        let recovered = try await store.load()
        XCTAssertEqual(recovered, original)
        let changedData = Data("changed after recovery".utf8)
        try changedData.write(to: url)

        await XCTAssertThrowsErrorAsync(try await store.save(original)) { error in
            XCTAssertEqual(error as? LayoutStoreIssue, .corruptedFile(url))
        }
        XCTAssertEqual(try Data(contentsOf: url), changedData)
        XCTAssertEqual(try Data(contentsOf: backupURL), backupData)
    }

    func testLayoutStoreRejectsUnknownSchemaWithoutReplacingExistingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layout-v1.json")
        let store = JSONLayoutStore(fileURL: url)
        try await store.save(LayoutState())
        let original = try Data(contentsOf: url)

        await XCTAssertThrowsErrorAsync(try await store.save(LayoutState(schemaVersion: 99))) { error in
            XCTAssertEqual(error as? LayoutStoreIssue, .unsupportedSchema(99))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testLayoutStoreKeepsNewerSchemaReadOnlyDespiteBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layout-v1.json")
        let store = JSONLayoutStore(fileURL: url)
        try await store.save(LayoutState(orderedEntries: [.app(UUID())]))
        try await store.save(LayoutState(orderedEntries: [.folder(UUID())]))

        let backupURL = await store.backupURL
        let backup = try Data(contentsOf: backupURL)
        let newerSchema = try JSONEncoder().encode(LayoutState(schemaVersion: 99))
        try newerSchema.write(to: url)

        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(error as? LayoutStoreIssue, .unsupportedSchema(99))
        }
        await XCTAssertThrowsErrorAsync(try await store.save(LayoutState())) { error in
            XCTAssertEqual(error as? LayoutStoreIssue, .unsupportedSchema(99))
        }
        XCTAssertEqual(try Data(contentsOf: url), newerSchema)
        XCTAssertEqual(try Data(contentsOf: backupURL), backup)
    }

    func testCorruptedLayoutIsPreservedWhenNoBackupCanBeLoaded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("layout-v1.json")
        let invalidData = Data("not valid JSON".utf8)
        try invalidData.write(to: url)
        let store = JSONLayoutStore(fileURL: url)

        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(error as? LayoutStoreIssue, .corruptedFile(url))
        }
        XCTAssertEqual(try Data(contentsOf: url), invalidData)
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("layout-v1.invalid-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved[0]), invalidData)
    }

    func testRepeatedCorruptedLayoutLoadsPreserveEachDistinctContentOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("layout-v1.json")
        let first = Data("first invalid layout".utf8)
        let second = Data("second invalid layout".utf8)

        for data in [first, second] {
            try data.write(to: url)
            for _ in 0..<2 {
                let store = JSONLayoutStore(fileURL: url)
                await XCTAssertThrowsErrorAsync(try await store.load()) { error in
                    XCTAssertEqual(error as? LayoutStoreIssue, .corruptedFile(url))
                }
            }
        }

        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("layout-v1.invalid-") }
        XCTAssertEqual(preserved.count, 2)
        XCTAssertEqual(Set(try preserved.map { try Data(contentsOf: $0) }), Set([first, second]))
        XCTAssertEqual(try Data(contentsOf: url), second)
    }

    func testCurrentMachineStandardCatalogProducesAnIcon() async throws {
        let report = await AppCatalogScanner().scan(roots: AppCatalogScanner.standardRoots)
        let firstCandidate = try XCTUnwrap(report.candidates.first)
        XCTAssertTrue(WorkspaceIconProvider().icon(for: firstCandidate.canonicalURL).isValid)
    }

    func testWorkspaceLauncherRejectsMissingApplicationWithoutHanging() async {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")

        await XCTAssertThrowsErrorAsync(try await WorkspaceAppLauncher().launch(missingURL)) { error in
            XCTAssertEqual(error as? WorkspaceLaunchError, .requestRejected(missingURL))
        }
    }

    func testWorkspaceLauncherRejectsIncompleteApplication() async throws {
        let applicationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-Incomplete-\(UUID().uuidString).app")
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: applicationURL) }
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.sunzheng.LaunchIcon.Tests.Incomplete",
            "CFBundleName": "Incomplete",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "MissingExecutable"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))

        await XCTAssertThrowsErrorAsync(try await WorkspaceAppLauncher().launch(applicationURL)) { error in
            XCTAssertEqual(error as? WorkspaceLaunchError, .requestRejected(applicationURL))
        }
    }

    func testIconCacheReturnsTheSameImageInstanceForTheSamePath() async throws {
        let report = await AppCatalogScanner().scan(roots: AppCatalogScanner.standardRoots)
        let candidate = try XCTUnwrap(report.candidates.first)
        let url = candidate.canonicalURL
        let cache = WorkspaceIconCache()
        let first = cache.icon(for: url)
        let second = cache.icon(for: url)
        XCTAssertTrue(first.isValid)
        XCTAssertTrue(first === second)
        XCTAssertTrue(cache.cachedIcon(for: url) === first)
        let bitmap = try XCTUnwrap(first.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        XCTAssertLessThanOrEqual(bitmap.pixelsWide, 168)
        XCTAssertLessThanOrEqual(bitmap.pixelsHigh, 168)

        let asynchronouslyLoaded = try await WorkspaceIconCache().loadIcon(for: url)
        XCTAssertTrue(asynchronouslyLoaded.isValid)

        let versioned = cache.icon(for: candidate)
        XCTAssertTrue(cache.cachedIcon(for: candidate) === versioned)
        let updated = AppCandidate(
            canonicalURL: url,
            bundleIdentifier: candidate.bundleIdentifier,
            displayName: candidate.displayName,
            sourcePriority: candidate.sourcePriority,
            discoveredAt: candidate.discoveredAt,
            modificationDate: (candidate.modificationDate ?? .distantPast).addingTimeInterval(1)
        )
        let refreshed = try await cache.loadIcon(for: updated)
        XCTAssertFalse(versioned === refreshed)
        XCTAssertTrue(cache.cachedIcon(for: updated) === refreshed)
        XCTAssertTrue(cache.cachedIcon(for: candidate) === versioned)
    }

    func testCancellingIconLoadSkipsQueuedDecode() async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let blockerStarted = expectation(description: "Icon queue blocker started")
        let releaseBlocker = DispatchSemaphore(value: 0)
        queue.addOperation {
            blockerStarted.fulfill()
            releaseBlocker.wait()
        }
        await fulfillment(of: [blockerStarted], timeout: 2)
        defer { releaseBlocker.signal() }

        let loaderCalled = expectation(description: "Cancelled icon was decoded")
        loaderCalled.isInverted = true
        let cache = WorkspaceIconCache(iconQueue: queue) { _ in
            loaderCalled.fulfill()
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let loadTask = Task { try await cache.loadIcon(for: URL(fileURLWithPath: "/Applications/Example.app")) }
        for _ in 0..<100 where queue.operationCount < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(queue.operationCount, 2)

        loadTask.cancel()
        releaseBlocker.signal()
        do {
            _ = try await loadTask.value
            XCTFail("A cancelled icon load should throw CancellationError")
        } catch is CancellationError {
        }
        let queueDrained = expectation(description: "Icon queue drained")
        queue.addBarrierBlock { queueDrained.fulfill() }
        await fulfillment(of: [queueDrained], timeout: 2)
        await fulfillment(of: [loaderCalled], timeout: 0.1)
    }

    func testCancellingRunningIconLoadResumesWaiterBeforeDecodeFinishes() async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let decoderStarted = expectation(description: "Icon decoder started")
        let releaseDecoder = DispatchSemaphore(value: 0)
        let cache = WorkspaceIconCache(iconQueue: queue) { _ in
            decoderStarted.fulfill()
            releaseDecoder.wait()
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let loadTask = Task { try await cache.loadIcon(for: URL(fileURLWithPath: "/Applications/Running.app")) }
        await fulfillment(of: [decoderStarted], timeout: 2)
        defer { releaseDecoder.signal() }

        loadTask.cancel()
        let cancellationObserved = expectation(description: "Cancelled icon waiter resumed")
        let observationTask = Task {
            if case .failure(let error) = await loadTask.result, error is CancellationError {
                cancellationObserved.fulfill()
            }
        }
        await fulfillment(of: [cancellationObserved], timeout: 1)
        releaseDecoder.signal()
        let queueDrained = expectation(description: "Running icon decode finished")
        queue.addBarrierBlock { queueDrained.fulfill() }
        await fulfillment(of: [queueDrained], timeout: 2)
        await observationTask.value
    }

    func testConcurrentIconLoadsForSameURLShareOneDecode() async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        let decoderStarted = expectation(description: "Shared icon decoder started")
        let secondRequestStarted = expectation(description: "Second icon request started")
        let releaseDecoder = DispatchSemaphore(value: 0)
        let decodeCounter = IconDecodeCounter()
        let cache = WorkspaceIconCache(iconQueue: queue) { _ in
            let currentCount = decodeCounter.increment()
            if currentCount == 1 { decoderStarted.fulfill() }
            releaseDecoder.wait()
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let url = URL(fileURLWithPath: "/Applications/Shared.app")
        let firstTask = Task { try await cache.loadIcon(for: url) }
        await fulfillment(of: [decoderStarted], timeout: 2)
        let secondTask = Task {
            secondRequestStarted.fulfill()
            return try await cache.loadIcon(for: url)
        }
        await fulfillment(of: [secondRequestStarted], timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        releaseDecoder.signal()
        releaseDecoder.signal()
        let firstImage = try await firstTask.value
        let secondImage = try await secondTask.value
        XCTAssertTrue(firstImage === secondImage)
        XCTAssertEqual(decodeCounter.count, 1)
    }

    func testIconPrefetchRunsConcurrentBatchesOfAtMostTwenty() async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 64
        queue.qualityOfService = .userInitiated
        let firstBatchStarted = expectation(description: "First prefetch batch started")
        let secondBatchStarted = expectation(description: "Second prefetch batch started")
        let releaseDecoders = DispatchSemaphore(value: 0)
        let activity = IconDecodeActivity()
        let cache = WorkspaceIconCache(iconQueue: queue) { _ in
            let counts = activity.start()
            if counts.started == 20 { firstBatchStarted.fulfill() }
            if counts.started == 25 { secondBatchStarted.fulfill() }
            defer { activity.finish() }
            releaseDecoders.wait()
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let candidates = (0..<25).map { index in
            AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/Applications/Prefetch-\(index).app"),
                bundleIdentifier: "com.example.prefetch.\(index)",
                displayName: "Prefetch \(index)",
                sourcePriority: 0,
                discoveredAt: .distantPast
            )
        }
        let prefetchTask = Task { try await cache.prefetchIcons(for: candidates) }
        defer { for _ in candidates { releaseDecoders.signal() } }

        await fulfillment(of: [firstBatchStarted], timeout: 2)
        XCTAssertEqual(activity.counts.started, 20)
        releaseDecoders.signal()
        for _ in 1..<20 { releaseDecoders.signal() }

        await fulfillment(of: [secondBatchStarted], timeout: 2)
        XCTAssertEqual(activity.counts.started, 25)
        releaseDecoders.signal()
        for _ in 1..<5 { releaseDecoders.signal() }
        try await prefetchTask.value
        XCTAssertEqual(activity.counts.peakActive, 20)
    }

    func testLoadIconsRunsFourInParallelAndPreservesCandidateOrder() async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        let allDecodersStarted = expectation(description: "All four icon decoders started")
        let releaseDecoders = DispatchSemaphore(value: 0)
        let activity = IconDecodeActivity()
        let cache = WorkspaceIconCache(iconQueue: queue) { url in
            let counts = activity.start()
            if counts.started == 4 { allDecodersStarted.fulfill() }
            defer { activity.finish() }
            releaseDecoders.wait()
            let index = Int(url.deletingPathExtension().lastPathComponent) ?? 0
            return NSImage(size: NSSize(width: CGFloat(index), height: 1))
        }
        let candidates = (1...4).map { index in
            AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/Applications/\(index).app"),
                bundleIdentifier: "com.example.preview.\(index)",
                displayName: "Preview \(index)",
                sourcePriority: 0,
                discoveredAt: .distantPast
            )
        }
        let loadTask = Task { try await cache.loadIcons(for: candidates) }
        defer { for _ in candidates { releaseDecoders.signal() } }

        await fulfillment(of: [allDecodersStarted], timeout: 2)
        releaseDecoders.signal()
        for _ in 1..<candidates.count { releaseDecoders.signal() }
        let images = try await loadTask.value

        XCTAssertEqual(images.map(\.size.width), [1, 2, 3, 4])
        XCTAssertEqual(activity.counts.peakActive, 4)
    }

    func testCancellingOneSharedIconWaiterDoesNotCancelAnother() async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        let decoderStarted = expectation(description: "Shared icon decoder started")
        let secondRequestStarted = expectation(description: "Second icon request started")
        let cancellationObserved = expectation(description: "First shared waiter cancelled")
        let releaseDecoder = DispatchSemaphore(value: 0)
        let decodeCounter = IconDecodeCounter()
        let cache = WorkspaceIconCache(iconQueue: queue) { _ in
            if decodeCounter.increment() == 1 { decoderStarted.fulfill() }
            releaseDecoder.wait()
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let url = URL(fileURLWithPath: "/Applications/SharedCancellation.app")
        let firstTask = Task { try await cache.loadIcon(for: url) }
        await fulfillment(of: [decoderStarted], timeout: 2)
        let secondTask = Task {
            secondRequestStarted.fulfill()
            return try await cache.loadIcon(for: url)
        }
        await fulfillment(of: [secondRequestStarted], timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)

        firstTask.cancel()
        let cancellationTask = Task {
            if case .failure(let error) = await firstTask.result, error is CancellationError {
                cancellationObserved.fulfill()
            }
        }
        await fulfillment(of: [cancellationObserved], timeout: 1)
        releaseDecoder.signal()
        releaseDecoder.signal()
        let result = try await secondTask.value
        XCTAssertTrue(result.isValid)
        await cancellationTask.value
        XCTAssertEqual(decodeCounter.count, 1)
    }

    func testScanReadsDisplayNameFromInfoPlist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("FakeApp.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: String] = [
            "CFBundleDisplayName": "Fake Display",
            "CFBundleName": "FakeName",
            "CFBundleIdentifier": "com.launchicon.fake"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: root) }

        let report = await AppCatalogScanner().scan(roots: [root])
        let candidate = try XCTUnwrap(report.candidates.first)
        XCTAssertEqual(candidate.displayName, "Fake Display")
        XCTAssertEqual(candidate.bundleIdentifier, "com.launchicon.fake")
        XCTAssertNotNil(candidate.modificationDate)
        XCTAssertTrue(report.unreadableMetadataPaths.isEmpty)
    }

    func testScanFallsBackWhenDeclaredDisplayNamesAreBlank() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (packageName, displayName, bundleName) in [
            ("EmptyDisplay", "", "Fallback Name"),
            ("BlankMetadata", "  ", "\t")
        ] {
            let contents = root.appendingPathComponent("\(packageName).app/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = [
                "CFBundleDisplayName": displayName,
                "CFBundleName": bundleName,
                "CFBundleIdentifier": "com.launchicon.\(packageName.lowercased())"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }

        let report = await AppCatalogScanner().scan(roots: [root])
        let namesByPackage = Dictionary(uniqueKeysWithValues: report.candidates.map {
            ($0.canonicalURL.lastPathComponent, $0.displayName)
        })
        XCTAssertEqual(namesByPackage["EmptyDisplay.app"], "Fallback Name")
        XCTAssertEqual(namesByPackage["BlankMetadata.app"], "BlankMetadata")
    }

    func testScanKeepsDamagedBundleVisibleAndDiagnosesMissingMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let damagedApp = root.appendingPathComponent("Broken.app", isDirectory: true)
        try FileManager.default.createDirectory(at: damagedApp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = await AppCatalogScanner().scan(roots: [root])
        XCTAssertEqual(report.candidates.map(\.displayName), ["Broken"])
        XCTAssertTrue(report.skippedPaths.isEmpty)
        XCTAssertEqual(report.unreadableMetadataPaths, [damagedApp.standardizedFileURL])
        XCTAssertTrue(report.unlaunchablePaths.isEmpty)
        XCTAssertFalse(report.canPersistReconciledLayout)
    }

    func testScanReadsIOSApplicationWrapperMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outer = root.appendingPathComponent("Player.app", isDirectory: true)
        let inner = outer.appendingPathComponent("Wrapper/Inner.app", isDirectory: true)
        let macContents = root.appendingPathComponent("Valid.app/Contents", isDirectory: true)
        let decoy = root.appendingPathComponent("Valid.app/Wrapper/Other.app", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macContents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func write(_ info: [String: String], to url: URL) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: url)
        }
        try write([
            "CFBundleDisplayName": "CMSPlayer",
            "CFBundleIdentifier": "com.example.wrapper",
            "CFBundleName": "CMSPlayer",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Inner"
        ], to: inner.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(
            at: outer.appendingPathComponent("WrappedBundle"),
            withDestinationURL: inner
        )
        try write([
            "CFBundleIdentifier": "com.example.valid",
            "CFBundleName": "Valid"
        ], to: macContents.appendingPathComponent("Info.plist"))
        try write([
            "CFBundleIdentifier": "com.example.decoy",
            "CFBundleName": "Decoy"
        ], to: decoy.appendingPathComponent("Info.plist"))

        let report = await AppCatalogScanner().scan(roots: [root])
        let byID = Dictionary(uniqueKeysWithValues: report.candidates.compactMap { candidate -> (String, AppCandidate)? in
            guard let bundleIdentifier = candidate.bundleIdentifier else { return nil }
            return (bundleIdentifier, candidate)
        })

        XCTAssertEqual(Set(byID.keys), ["com.example.wrapper", "com.example.valid"])
        XCTAssertEqual(byID["com.example.wrapper"]?.displayName, "CMSPlayer")
        XCTAssertEqual(byID["com.example.wrapper"]?.canonicalURL, outer.standardizedFileURL)
        XCTAssertTrue(report.unreadableMetadataPaths.isEmpty)
        XCTAssertTrue(report.skippedPaths.isEmpty)
        XCTAssertTrue(report.canPersistReconciledLayout)
    }

    func testScanDoesNotTreatCorruptMacPlistAsIOSWrapper() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contents = root.appendingPathComponent("BrokenMac.app/Contents", isDirectory: true)
        let inner = root.appendingPathComponent("BrokenMac.app/Wrapper/Inner.app", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a plist".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        let info = ["CFBundleIdentifier": "com.example.inner", "CFBundleName": "Inner"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: inner.appendingPathComponent("Info.plist"))

        let report = await AppCatalogScanner().scan(roots: [root])
        XCTAssertEqual(report.candidates.map(\.bundleIdentifier), [nil])
        XCTAssertEqual(report.unreadableMetadataPaths.map(\.lastPathComponent), ["BrokenMac.app"])
        XCTAssertFalse(report.canPersistReconciledLayout)
    }

    func testScanDiagnosesMissingExecutableWithoutHidingBundle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("Broken.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: String] = [
            "CFBundleIdentifier": "com.launchicon.missing-executable",
            "CFBundleName": "Broken",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "MissingExecutable"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let report = await AppCatalogScanner().scan(roots: [root])
        XCTAssertEqual(report.candidates.map(\.canonicalURL), [app.standardizedFileURL])
        XCTAssertTrue(report.skippedPaths.isEmpty)
        XCTAssertTrue(report.unreadableMetadataPaths.isEmpty)
        XCTAssertEqual(report.unlaunchablePaths, [app.standardizedFileURL])
        XCTAssertTrue(report.canPersistReconciledLayout)
    }

    func testScanIgnoresOrdinaryFileWithAppExtensionWithoutDisablingLayoutEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contents = root.appendingPathComponent("Valid.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = ["CFBundleIdentifier": "com.launchicon.valid", "CFBundleName": "Valid"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("not an app bundle".utf8).write(to: root.appendingPathComponent("NotAnApp.app"))

        let report = await AppCatalogScanner().scan(roots: [root])

        XCTAssertEqual(report.candidates.map(\.bundleIdentifier), ["com.launchicon.valid"])
        XCTAssertTrue(report.skippedPaths.isEmpty)
        XCTAssertTrue(report.canPersistReconciledLayout)
    }

    func testScanMarksBrokenApplicationSymlinkIncomplete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contents = root.appendingPathComponent("Valid.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = ["CFBundleIdentifier": "com.launchicon.valid", "CFBundleName": "Valid"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let brokenLink = root.appendingPathComponent("Broken.app")
        try FileManager.default.createSymbolicLink(
            at: brokenLink,
            withDestinationURL: root.appendingPathComponent("Missing.app")
        )

        let report = await AppCatalogScanner().scan(roots: [root])

        XCTAssertEqual(report.candidates.map(\.bundleIdentifier), ["com.launchicon.valid"])
        XCTAssertEqual(report.skippedPaths.map(\.lastPathComponent), [brokenLink.lastPathComponent])
        XCTAssertFalse(report.canPersistReconciledLayout)
    }

    func testScanIncludesResolvableApplicationSymlink() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scannedRoot = directory.appendingPathComponent("Applications", isDirectory: true)
        let target = directory.appendingPathComponent("Cryptex/Safari.app", isDirectory: true)
        let contents = target.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: scannedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plist: [String: String] = [
            "CFBundleDisplayName": "Safari",
            "CFBundleIdentifier": "com.apple.Safari"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(
            at: scannedRoot.appendingPathComponent("Safari.app"),
            withDestinationURL: target
        )

        let report = await AppCatalogScanner().scan(roots: [scannedRoot])
        let candidate = try XCTUnwrap(report.candidates.first)
        XCTAssertEqual(report.candidates.count, 1)
        XCTAssertEqual(candidate.canonicalURL, target.standardizedFileURL)
        XCTAssertEqual(candidate.displayName, "Safari")
        XCTAssertEqual(candidate.bundleIdentifier, "com.apple.Safari")
    }

    func testScanFollowsRetargetedApplicationsRootSymlink() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = parent.appendingPathComponent("First", isDirectory: true)
        let second = parent.appendingPathComponent("Second", isDirectory: true)
        let alias = parent.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: first.appendingPathComponent("Calculator.app"),
            withDestinationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app")
        )
        try FileManager.default.createSymbolicLink(
            at: second.appendingPathComponent("Clock.app"),
            withDestinationURL: URL(fileURLWithPath: "/System/Applications/Clock.app")
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        defer { try? FileManager.default.removeItem(at: parent) }

        let scanner = AppCatalogScanner()
        let before = await scanner.scan(roots: [alias])
        XCTAssertEqual(before.candidates.map(\.bundleIdentifier), ["com.apple.calculator"])
        XCTAssertTrue(before.skippedPaths.isEmpty)

        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        let after = await scanner.scan(roots: [alias])
        XCTAssertEqual(after.candidates.map(\.bundleIdentifier), ["com.apple.clock"])
        XCTAssertTrue(after.skippedPaths.isEmpty)
    }

    func testCatalogPersistenceRequiresCompleteNonemptyScan() {
        let candidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Existing.app"),
            bundleIdentifier: "com.example.existing",
            displayName: "Existing",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let missingRoot = URL(fileURLWithPath: "/Applications/Unavailable", isDirectory: true)
        XCTAssertFalse(CatalogScanReport(candidates: [], skippedPaths: []).canPersistReconciledLayout)
        XCTAssertFalse(CatalogScanReport(candidates: [candidate], skippedPaths: [missingRoot]).canPersistReconciledLayout)
        XCTAssertFalse(CatalogScanReport(
            candidates: [candidate],
            skippedPaths: [],
            unreadableMetadataPaths: [missingRoot]
        ).canPersistReconciledLayout)
        XCTAssertTrue(CatalogScanReport(
            candidates: [candidate],
            skippedPaths: [],
            unlaunchablePaths: [missingRoot]
        ).canPersistReconciledLayout)
        XCTAssertTrue(CatalogScanReport(candidates: [candidate], skippedPaths: []).canPersistReconciledLayout)
    }

    func testAbsentOptionalApplicationRootIsNotAReadFailure() async {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let report = await AppCatalogScanner().scan(roots: [missingRoot])
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertTrue(report.skippedPaths.isEmpty)
    }

    func testDirectoryWatcherSignalsApplicationFolderChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let changed = expectation(description: "Applications directory changed")
        let watcher = ApplicationDirectoryWatcher { changed.fulfill() }
        XCTAssertTrue(watcher.start(roots: [root]))
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(250))
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/mkdir")
        installer.arguments = [root.appendingPathComponent("New.app", isDirectory: true).path]
        try installer.run()
        installer.waitUntilExit()
        XCTAssertEqual(installer.terminationStatus, 0)
        await fulfillment(of: [changed], timeout: 8)
    }

    func testDirectoryWatcherSignalsChangeThroughSymlinkedRoot() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = parent.appendingPathComponent("RealApplications", isDirectory: true)
        let alias = parent.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: parent) }

        let changed = expectation(description: "Symlinked Applications directory changed")
        let watcher = ApplicationDirectoryWatcher { changed.fulfill() }
        XCTAssertTrue(watcher.start(roots: [alias]))
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(250))
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/mkdir")
        installer.arguments = [target.appendingPathComponent("New.app", isDirectory: true).path]
        try installer.run()
        installer.waitUntilExit()
        XCTAssertEqual(installer.terminationStatus, 0)
        await fulfillment(of: [changed], timeout: 8)
    }

    func testDirectoryWatcherSignalsRetargetedSymlinkRoot() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstTarget = parent.appendingPathComponent("First", isDirectory: true)
        let secondTarget = parent.appendingPathComponent("Second", isDirectory: true)
        let alias = parent.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: firstTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: firstTarget)
        defer { try? FileManager.default.removeItem(at: parent) }

        let changed = expectation(description: "Retargeted Applications directory changed")
        let retargeted = expectation(description: "Applications symlink retargeted")
        let watcher = ApplicationDirectoryWatcher(
            onChange: { changed.fulfill() },
            onRootChanged: { retargeted.fulfill() }
        )
        XCTAssertTrue(watcher.start(roots: [alias]))
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(250))
        let retargeter = Process()
        retargeter.executableURL = URL(fileURLWithPath: "/bin/ln")
        retargeter.arguments = ["-sfn", secondTarget.path, alias.path]
        try retargeter.run()
        retargeter.waitUntilExit()
        XCTAssertEqual(retargeter.terminationStatus, 0)
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/mkdir")
        installer.arguments = [secondTarget.appendingPathComponent("New.app", isDirectory: true).path]
        try installer.run()
        installer.waitUntilExit()
        XCTAssertEqual(installer.terminationStatus, 0)
        await fulfillment(of: [changed, retargeted], timeout: 8)
    }

    func testDirectoryWatcherReportsMissingRootCoverage() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let existing = parent.appendingPathComponent("Applications", isDirectory: true)
        let missing = parent.appendingPathComponent("UserApplications", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let watcher = ApplicationDirectoryWatcher {}
        XCTAssertTrue(watcher.start(roots: [existing, missing]))
        XCTAssertFalse(watcher.watchesAllRoots)
        watcher.stop()

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        XCTAssertTrue(watcher.start(roots: [existing, missing]))
        XCTAssertTrue(watcher.watchesAllRoots)
        watcher.stop()
        XCTAssertFalse(watcher.watchesAllRoots)
    }

    func testDirectoryWatcherSignalsNewlyCreatedOptionalRoot() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let existing = parent.appendingPathComponent("SharedApplications", isDirectory: true)
        let missing = parent.appendingPathComponent("UserApplications", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let changed = expectation(description: "New Applications root changed")
        let rebound = expectation(description: "New Applications root needs a watcher")
        let watcher = ApplicationDirectoryWatcher(
            onChange: { changed.fulfill() },
            onRootChanged: { rebound.fulfill() }
        )
        XCTAssertTrue(watcher.start(roots: [existing, missing]))
        XCTAssertFalse(watcher.watchesAllRoots)
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(250))
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/mkdir")
        installer.arguments = ["-p", missing.appendingPathComponent("New.app", isDirectory: true).path]
        try installer.run()
        installer.waitUntilExit()
        XCTAssertEqual(installer.terminationStatus, 0)
        await fulfillment(of: [changed, rebound], timeout: 8)
        XCTAssertTrue(watcher.start(roots: [existing, missing]))
        XCTAssertTrue(watcher.watchesAllRoots)
    }

    func testDirectoryWatcherCanStartBeforeItsOnlyRootExists() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missing = parent.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let changed = expectation(description: "First Applications root changed")
        let rebound = expectation(description: "First Applications root needs a watcher")
        let watcher = ApplicationDirectoryWatcher(
            onChange: { changed.fulfill() },
            onRootChanged: { rebound.fulfill() }
        )
        XCTAssertTrue(watcher.start(roots: [missing]))
        XCTAssertFalse(watcher.watchesAllRoots)
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(250))
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/mkdir")
        installer.arguments = ["-p", missing.appendingPathComponent("New.app", isDirectory: true).path]
        try installer.run()
        installer.waitUntilExit()
        XCTAssertEqual(installer.terminationStatus, 0)
        await fulfillment(of: [changed, rebound], timeout: 8)
        XCTAssertTrue(watcher.start(roots: [missing]))
        XCTAssertTrue(watcher.watchesAllRoots)
    }

    func testDirectoryWatcherIgnoresUnrelatedChangesBesideMissingRoot() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missing = parent.appendingPathComponent("Applications", isDirectory: true)
        let unrelated = parent.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let changed = expectation(description: "Unrelated directory must not rescan")
        changed.isInverted = true
        let rebound = expectation(description: "Unrelated directory must not rebind")
        rebound.isInverted = true
        let watcher = ApplicationDirectoryWatcher(
            onChange: { changed.fulfill() },
            onRootChanged: { rebound.fulfill() }
        )
        XCTAssertTrue(watcher.start(roots: [missing]))
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(250))
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        writer.arguments = [unrelated.appendingPathComponent("Unrelated.txt").path]
        try writer.run()
        writer.waitUntilExit()
        XCTAssertEqual(writer.terminationStatus, 0)
        await fulfillment(of: [changed, rebound], timeout: 3)
    }

    func testDirectoryWatcherIgnoresSustainedChangesBesideMissingRoot() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missing = parent.appendingPathComponent("Applications", isDirectory: true)
        let unrelated = parent.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let changed = expectation(description: "Unrelated file burst must not rescan")
        changed.isInverted = true
        let rebound = expectation(description: "Unrelated file burst must not rebind")
        rebound.isInverted = true
        let watcher = ApplicationDirectoryWatcher(
            onChange: { changed.fulfill() },
            onRootChanged: { rebound.fulfill() }
        )
        XCTAssertTrue(watcher.start(roots: [missing]))
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(250))
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Keep the burst sustained (~1s) but short enough to finish inside the
        // observation window on slower CI runners (was 40×0.05≈2s+ under 4s).
        writer.arguments = [
            "-c",
            "index=0; while [ \"$index\" -lt 20 ]; do /usr/bin/touch \"$1/Noise-$index\"; index=$((index + 1)); /bin/sleep 0.05; done",
            "watcher-noise",
            unrelated.path
        ]
        try writer.run()
        defer {
            if writer.isRunning {
                writer.terminate()
                writer.waitUntilExit()
            }
        }
        await fulfillment(of: [changed, rebound], timeout: 6)
        if writer.isRunning {
            writer.terminate()
            writer.waitUntilExit()
            XCTFail("noise writer overran observation window")
        } else {
            XCTAssertEqual(writer.terminationStatus, 0)
        }
    }

    func testDirectoryWatcherDiscoversRootBelowMissingParent() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missing = parent.appendingPathComponent("Nested/Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let changed = expectation(description: "Nested Applications root changed")
        let rebound = expectation(description: "Nested Applications root needs a watcher")
        let watcher = ApplicationDirectoryWatcher(
            onChange: { changed.fulfill() },
            onRootChanged: { rebound.fulfill() }
        )
        XCTAssertTrue(watcher.start(roots: [missing]))
        XCTAssertFalse(watcher.watchesAllRoots)
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(250))
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/mkdir")
        installer.arguments = ["-p", missing.appendingPathComponent("New.app", isDirectory: true).path]
        try installer.run()
        installer.waitUntilExit()
        XCTAssertEqual(installer.terminationStatus, 0)
        await fulfillment(of: [changed, rebound], timeout: 8)
        XCTAssertTrue(watcher.start(roots: [missing]))
        XCTAssertTrue(watcher.watchesAllRoots)
    }

    func testDirectoryWatcherRebindsAfterApplicationRootIsReplaced() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("Applications", isDirectory: true)
        let moved = parent.appendingPathComponent("OldApplications", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let changed = expectation(description: "Replaced Applications root changed")
        let rebound = expectation(description: "Replaced Applications root needs a watcher")
        let watcher = ApplicationDirectoryWatcher(
            onChange: { changed.fulfill() },
            onRootChanged: { rebound.fulfill() }
        )
        XCTAssertTrue(watcher.start(roots: [root]))
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(250))
        let mover = Process()
        mover.executableURL = URL(fileURLWithPath: "/bin/mv")
        mover.arguments = [root.path, moved.path]
        try mover.run()
        mover.waitUntilExit()
        XCTAssertEqual(mover.terminationStatus, 0)
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/mkdir")
        installer.arguments = ["-p", root.appendingPathComponent("New.app", isDirectory: true).path]
        try installer.run()
        installer.waitUntilExit()
        XCTAssertEqual(installer.terminationStatus, 0)
        await fulfillment(of: [changed, rebound], timeout: 8)
        XCTAssertTrue(watcher.start(roots: [root]))
        XCTAssertTrue(watcher.watchesAllRoots)
    }

    func testShouldTurnPageUsesDistanceOrVelocity() {
        XCTAssertFalse(LauncherLayout.shouldTurnPage(distance: 20, velocity: 0, pageWidth: 1000))
        XCTAssertFalse(LauncherLayout.shouldTurnPage(distance: 179, velocity: 0, pageWidth: 1000))
        XCTAssertTrue(LauncherLayout.shouldTurnPage(distance: 200, velocity: 0, pageWidth: 1000))
        XCTAssertTrue(LauncherLayout.shouldTurnPage(distance: 10, velocity: 500, pageWidth: 1000))
    }

    func testDiscreteScrollRequiresThreeStepsBeforeTurningPage() {
        XCTAssertFalse(LauncherLayout.shouldTurnDiscretePage(accumulatedDelta: 2))
        XCTAssertFalse(LauncherLayout.shouldTurnDiscretePage(accumulatedDelta: -2))
        XCTAssertTrue(LauncherLayout.shouldTurnDiscretePage(accumulatedDelta: 3))
        XCTAssertTrue(LauncherLayout.shouldTurnDiscretePage(accumulatedDelta: -3))
    }

    func testDiscreteScrollDuringQuietPeriodHoldsOneTurn() {
        let quiet = LauncherLayout.pageAnimationDuration + 0.05
        let below = LauncherLayout.discreteScrollTurn(
            accumulatedDelta: 0,
            incomingDelta: 2,
            now: 10,
            lastScroll: nil,
            lastTurn: 10,
            quietPeriod: quiet
        )
        XCTAssertNil(below.direction)
        XCTAssertEqual(below.accumulatedDelta, 2)

        let held = LauncherLayout.discreteScrollTurn(
            accumulatedDelta: 0,
            incomingDelta: -3,
            now: 10.05,
            lastScroll: 10,
            lastTurn: 10,
            quietPeriod: quiet
        )
        XCTAssertEqual(held.direction, 1)
        XCTAssertEqual(held.accumulatedDelta, 0)
        XCTAssertEqual(held.holdDelay ?? -1, quiet - 0.05, accuracy: 0.001)

        let delivered = LauncherLayout.discreteScrollTurn(
            accumulatedDelta: 0,
            incomingDelta: -3,
            now: 10 + quiet,
            lastScroll: 10.05,
            lastTurn: 10,
            quietPeriod: quiet
        )
        XCTAssertEqual(delivered.direction, 1)
        XCTAssertNil(delivered.holdDelay)
        XCTAssertEqual(delivered.accumulatedDelta, 0)

        let stale = LauncherLayout.discreteScrollTurn(
            accumulatedDelta: 20,
            incomingDelta: 1,
            now: 10 + quiet + 0.1,
            lastScroll: 10,
            lastTurn: -.infinity,
            quietPeriod: quiet
        )
        XCTAssertNil(stale.direction)
        XCTAssertEqual(stale.accumulatedDelta, 1)
    }

    func testRestingPageDragDoesNotAnimateAClampedOrEmptyRelease() {
        XCTAssertEqual(
            LauncherLayout.pageDragFinish(direction: nil, isVisuallyDragging: false, currentPage: 1, pageCount: 4),
            LauncherLayout.PageDragFinish.ignore
        )
        XCTAssertEqual(
            LauncherLayout.pageDragFinish(direction: nil, isVisuallyDragging: true, currentPage: 1, pageCount: 4),
            LauncherLayout.PageDragFinish.settle
        )
        XCTAssertEqual(
            LauncherLayout.pageDragFinish(direction: 1, isVisuallyDragging: false, currentPage: 3, pageCount: 4),
            LauncherLayout.PageDragFinish.ignore
        )
        XCTAssertEqual(
            LauncherLayout.pageDragFinish(direction: 1, isVisuallyDragging: true, currentPage: 3, pageCount: 4),
            LauncherLayout.PageDragFinish.settle
        )
        XCTAssertEqual(
            LauncherLayout.pageDragFinish(direction: 1, isVisuallyDragging: false, currentPage: 0, pageCount: 4),
            LauncherLayout.PageDragFinish.turn(1)
        )
        XCTAssertEqual(
            LauncherLayout.pageDragFinish(direction: -1, isVisuallyDragging: true, currentPage: 0, pageCount: 4),
            LauncherLayout.PageDragFinish.settle
        )
        XCTAssertEqual(
            LauncherLayout.pageDragFinish(direction: 1, isVisuallyDragging: true, currentPage: 0, pageCount: 0),
            LauncherLayout.PageDragFinish.ignore
        )
    }

    func testLaunchHighlightFollowsAnAppThatIsStillOpening() {
        XCTAssertEqual(
            LauncherLayout.launchHighlightChange(finishedKey: "b", highlightedKey: "b", remainingKeys: ["a"]),
            LauncherLayout.LaunchHighlightChange.show("a")
        )
        XCTAssertEqual(
            LauncherLayout.launchHighlightChange(finishedKey: "a", highlightedKey: "b", remainingKeys: ["b"]),
            LauncherLayout.LaunchHighlightChange.keep
        )
        XCTAssertEqual(
            LauncherLayout.launchHighlightChange(finishedKey: "a", highlightedKey: "a", remainingKeys: []),
            LauncherLayout.LaunchHighlightChange.show(nil)
        )
        XCTAssertEqual(
            LauncherLayout.launchHighlightChange(finishedKey: "b", highlightedKey: "b", remainingKeys: ["c", "a"]),
            LauncherLayout.LaunchHighlightChange.show("a")
        )
    }

    func testSuccessfulLaunchDoesNotHideAfterTheLauncherIsShownAgain() {
        XCTAssertTrue(LauncherLayout.shouldDismissAfterSuccessfulLaunch(
            hidesAfterLaunch: true,
            launchGeneration: 4,
            currentGeneration: 4
        ))
        XCTAssertFalse(LauncherLayout.shouldDismissAfterSuccessfulLaunch(
            hidesAfterLaunch: false,
            launchGeneration: 4,
            currentGeneration: 4
        ))
        XCTAssertFalse(LauncherLayout.shouldDismissAfterSuccessfulLaunch(
            hidesAfterLaunch: true,
            launchGeneration: 4,
            currentGeneration: 5
        ))
        XCTAssertFalse(LauncherLayout.shouldDismissAfterSuccessfulLaunch(
            hidesAfterLaunch: false,
            launchGeneration: 1,
            currentGeneration: 2
        ))
    }

    func testVisibilityToggleShowsAgainWhileTheDismissAnimationIsStillVisible() {
        XCTAssertTrue(LauncherLayout.shouldKeepLauncherFocusWhenShown(isAppearing: false, isKey: true))
        XCTAssertFalse(LauncherLayout.shouldKeepLauncherFocusWhenShown(isAppearing: true, isKey: true))
        XCTAssertFalse(LauncherLayout.shouldKeepLauncherFocusWhenShown(isAppearing: false, isKey: false))
        XCTAssertFalse(LauncherLayout.shouldKeepLauncherFocusWhenShown(isAppearing: true, isKey: false))
        XCTAssertEqual(
            LauncherLayout.visibilityToggle(isVisible: true, isDismissing: false),
            .hide
        )
        XCTAssertEqual(
            LauncherLayout.visibilityToggle(isVisible: false, isDismissing: false),
            .show
        )
        XCTAssertEqual(
            LauncherLayout.visibilityToggle(isVisible: true, isDismissing: true),
            .show
        )
        XCTAssertEqual(
            LauncherLayout.visibilityToggle(isVisible: false, isDismissing: true),
            .show
        )
        XCTAssertEqual(
            LauncherLayout.statusItemToggleTitle(isVisible: true, isDismissing: false),
            "隐藏 LaunchIcon"
        )
        XCTAssertEqual(
            LauncherLayout.statusItemToggleTitle(isVisible: false, isDismissing: false),
            "显示 LaunchIcon"
        )
        XCTAssertEqual(
            LauncherLayout.statusItemToggleTitle(isVisible: true, isDismissing: true),
            "显示 LaunchIcon"
        )
        XCTAssertEqual(
            LauncherLayout.statusItemToggleTitle(isVisible: false, isDismissing: true),
            "显示 LaunchIcon"
        )
    }

    func testDismissAnimationSuspendsLauncherKeyboard() {
        XCTAssertFalse(LauncherLayout.shouldSuspendLauncherKeyboard(isDismissing: false))
        XCTAssertTrue(LauncherLayout.shouldSuspendLauncherKeyboard(isDismissing: true))
        XCTAssertFalse(LauncherLayout.shouldConsumeLauncherKeyEquivalent(isDismissing: false))
        XCTAssertTrue(LauncherLayout.shouldConsumeLauncherKeyEquivalent(isDismissing: true))
        XCTAssertTrue(LauncherLayout.shouldAcceptContentScroll(isDismissing: false))
        XCTAssertFalse(LauncherLayout.shouldAcceptContentScroll(isDismissing: true))
        XCTAssertTrue(LauncherLayout.shouldAcceptPagingGesture(isDismissing: false))
        XCTAssertFalse(LauncherLayout.shouldAcceptPagingGesture(isDismissing: true))
        XCTAssertEqual(
            LauncherLayout.shouldAcceptPagingGesture(isDismissing: true),
            LauncherLayout.shouldAcceptContentScroll(isDismissing: true)
        )
        XCTAssertTrue(LauncherLayout.shouldAcceptPointerActivation(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldAcceptPointerActivation(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldAcceptPointerActivation(isDismissing: false, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldAcceptPointerActivation(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldApplyBackgroundRelease(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldApplyBackgroundRelease(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldApplyBackgroundRelease(isDismissing: false, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldApplyBackgroundRelease(isDismissing: true, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldApplyBackgroundRelease(isDismissing: true, isVisible: true),
            LauncherLayout.shouldAcceptPointerActivation(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldApplySearchFieldEdit(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldApplySearchFieldEdit(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldApplySearchFieldEdit(isDismissing: false, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldApplySearchFieldEdit(isDismissing: true, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldApplySearchFieldEdit(isDismissing: true, isVisible: true),
            LauncherLayout.shouldAcceptPointerActivation(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldDeliverPointerEventWhileInactive(.press))
        XCTAssertTrue(LauncherLayout.shouldDeliverPointerEventWhileInactive(.leftDrag))
        XCTAssertTrue(LauncherLayout.shouldDeliverPointerEventWhileInactive(.leftRelease))
        XCTAssertFalse(LauncherLayout.shouldDeliverPointerEventWhileInactive(.otherButton))
        XCTAssertFalse(LauncherLayout.shouldAbandonAliasPromptOnDismiss(isPrompting: false))
        XCTAssertTrue(LauncherLayout.shouldAbandonAliasPromptOnDismiss(isPrompting: true))
        XCTAssertFalse(LauncherLayout.shouldCancelIconContextMenuOnDismiss(isTracking: false))
        XCTAssertTrue(LauncherLayout.shouldCancelIconContextMenuOnDismiss(isTracking: true))
        XCTAssertTrue(LauncherLayout.shouldApplyIconContextMenuAction(
            isDismissing: false,
            isVisible: true,
            isCancellingMenu: false
        ))
        XCTAssertFalse(LauncherLayout.shouldApplyIconContextMenuAction(
            isDismissing: true,
            isVisible: true,
            isCancellingMenu: false
        ))
        XCTAssertFalse(LauncherLayout.shouldApplyIconContextMenuAction(
            isDismissing: false,
            isVisible: false,
            isCancellingMenu: false
        ))
        XCTAssertFalse(LauncherLayout.shouldApplyIconContextMenuAction(
            isDismissing: false,
            isVisible: true,
            isCancellingMenu: true
        ))
        XCTAssertTrue(LauncherLayout.shouldAcceptLayoutDrop(isDismissing: false))
        XCTAssertFalse(LauncherLayout.shouldAcceptLayoutDrop(isDismissing: true))
        XCTAssertTrue(LauncherLayout.shouldBeginLayoutDrag(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldBeginLayoutDrag(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldBeginLayoutDrag(isDismissing: false, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldBeginLayoutDrag(isDismissing: true, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldBeginLayoutDrag(isDismissing: true, isVisible: true),
            LauncherLayout.shouldAcceptPointerActivation(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldAbandonFolderRenameOnOrderOut(isEditingTitle: false))
        XCTAssertTrue(LauncherLayout.shouldAbandonFolderRenameOnOrderOut(isEditingTitle: true))
        XCTAssertFalse(LauncherLayout.shouldAbandonFolderRenameOnResignKey(isEditingTitle: false))
        XCTAssertTrue(LauncherLayout.shouldAbandonFolderRenameOnResignKey(isEditingTitle: true))
        XCTAssertFalse(LauncherLayout.shouldDiscardSearchCompositionOnResignKey(hasMarkedText: false))
        XCTAssertTrue(LauncherLayout.shouldDiscardSearchCompositionOnResignKey(hasMarkedText: true))
        XCTAssertFalse(LauncherLayout.shouldRefilterSearchAfterFieldEditorEnds(
            appliedQuery: "计算器",
            committedQuery: "计算器"
        ))
        XCTAssertFalse(LauncherLayout.shouldRefilterSearchAfterFieldEditorEnds(
            appliedQuery: "",
            committedQuery: ""
        ))
        XCTAssertTrue(LauncherLayout.shouldRefilterSearchAfterFieldEditorEnds(
            appliedQuery: "jisuan",
            committedQuery: ""
        ))
        XCTAssertTrue(LauncherLayout.shouldRefilterSearchAfterFieldEditorEnds(
            appliedQuery: "caljisuan",
            committedQuery: "cal"
        ))
        XCTAssertTrue(LauncherLayout.shouldApplyDeferredSearchRefilter(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldApplyDeferredSearchRefilter(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldApplyDeferredSearchRefilter(isDismissing: false, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldApplyDeferredSearchRefilter(isDismissing: true, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldApplyDeferredSearchRefilter(isDismissing: true, isVisible: true),
            LauncherLayout.shouldApplySearchFieldEdit(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldRefreshInstalledSearchIndex(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldRefreshInstalledSearchIndex(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldRefreshInstalledSearchIndex(isDismissing: false, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldRefreshInstalledSearchIndex(isDismissing: true, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldRefreshInstalledSearchIndex(isDismissing: true, isVisible: true),
            LauncherLayout.shouldApplyDeferredSearchRefilter(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldApplyDeferredSearchBacktab(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldApplyDeferredSearchBacktab(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldApplyDeferredSearchBacktab(isDismissing: false, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldApplyDeferredSearchBacktab(isDismissing: true, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldApplyDeferredSearchBacktab(isDismissing: true, isVisible: true),
            LauncherLayout.shouldApplyDeferredSearchRefilter(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldPresentCatalogWhileLauncherIsUp(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldPresentCatalogWhileLauncherIsUp(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldPresentCatalogWhileLauncherIsUp(isDismissing: false, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldPresentCatalogWhileLauncherIsUp(isDismissing: true, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldPresentCatalogWhileLauncherIsUp(isDismissing: true, isVisible: true),
            LauncherLayout.shouldApplyDeferredSearchRefilter(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldPresentCatalogChromeWhileLauncherIsUp(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldPresentCatalogChromeWhileLauncherIsUp(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldPresentCatalogChromeWhileLauncherIsUp(isDismissing: false, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldPresentCatalogChromeWhileLauncherIsUp(isDismissing: true, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldPresentCatalogChromeWhileLauncherIsUp(isDismissing: true, isVisible: true),
            LauncherLayout.shouldPresentCatalogWhileLauncherIsUp(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldPresentLaunchHighlightWhileLauncherIsUp(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldPresentLaunchHighlightWhileLauncherIsUp(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldPresentLaunchHighlightWhileLauncherIsUp(isDismissing: false, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldPresentLaunchHighlightWhileLauncherIsUp(isDismissing: true, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldPresentLaunchHighlightWhileLauncherIsUp(isDismissing: true, isVisible: true),
            LauncherLayout.shouldPresentCatalogWhileLauncherIsUp(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldApplyLoadedIcon(isDismissing: false))
        XCTAssertFalse(LauncherLayout.shouldApplyLoadedIcon(isDismissing: true))
        XCTAssertTrue(LauncherLayout.shouldApplyDesktopBackground(isDismissing: false))
        XCTAssertFalse(LauncherLayout.shouldApplyDesktopBackground(isDismissing: true))
        XCTAssertEqual(
            LauncherLayout.shouldApplyDesktopBackground(isDismissing: true),
            LauncherLayout.shouldApplyLoadedIcon(isDismissing: true)
        )
        XCTAssertTrue(LauncherLayout.shouldPresentToastWhileLauncherIsUp(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldPresentToastWhileLauncherIsUp(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldPresentToastWhileLauncherIsUp(isDismissing: false, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldPresentToastWhileLauncherIsUp(isDismissing: true, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldPresentToastWhileLauncherIsUp(isDismissing: true, isVisible: true),
            LauncherLayout.shouldPresentCatalogWhileLauncherIsUp(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldAnimateToastDismissal(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldAnimateToastDismissal(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldAnimateToastDismissal(isDismissing: false, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldAnimateToastDismissal(isDismissing: true, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldAnimateToastDismissal(isDismissing: true, isVisible: true),
            LauncherLayout.shouldPresentToastWhileLauncherIsUp(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldHoldToastDismissal(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldToastDismissal(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldToastDismissal(isDismissing: true, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldHoldToastDismissal(isDismissing: false, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldHoldInFlightToastFade(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldInFlightToastFade(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldInFlightToastFade(isDismissing: true, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldHoldInFlightToastFade(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldHoldInFlightToastFade(isDismissing: true, isVisible: true),
            LauncherLayout.shouldHoldToastDismissal(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldSnapInFlightToastFade(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightToastFade(isDismissing: false, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightToastFade(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightToastFade(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldSnapInFlightToastFade(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldInFlightToastFade(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldCommitRestoredGridPage(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldCommitRestoredGridPage(isDismissing: false, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldCommitRestoredGridPage(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldCommitRestoredGridPage(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldCommitRestoredGridPage(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldToastDismissal(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldClearDropHighlight(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldClearDropHighlight(isDismissing: false, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldClearDropHighlight(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldClearDropHighlight(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldClearDropHighlight(isDismissing: true, isVisible: true),
            LauncherLayout.shouldCommitRestoredGridPage(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldCommitFolderLanding(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldCommitFolderLanding(isDismissing: false, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldCommitFolderLanding(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldCommitFolderLanding(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldCommitFolderLanding(isDismissing: true, isVisible: true),
            LauncherLayout.shouldClearDropHighlight(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(
            LauncherLayout.shouldAnimateReducedMotionFolderLanding(
                isDismissing: false, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimateReducedMotionFolderLanding(
                isDismissing: true, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimateReducedMotionFolderLanding(
                isDismissing: true, isVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimateReducedMotionFolderLanding(
                isDismissing: false, isVisible: false
            )
        )
        XCTAssertEqual(
            LauncherLayout.shouldAnimateReducedMotionFolderLanding(
                isDismissing: true, isVisible: true
            ),
            LauncherLayout.shouldAdvanceMergeFlight(isDismissing: true, isVisible: true)
        )
        XCTAssertEqual(
            LauncherLayout.shouldAnimateReducedMotionFolderLanding(
                isDismissing: false, isVisible: true
            ),
            LauncherLayout.shouldAdvanceMergeFlight(isDismissing: false, isVisible: true)
        )
        XCTAssertTrue(
            LauncherLayout.shouldPinTrackedFolderLanding(
                isTracked: true, tokenMatches: true, isDismissing: true, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldPinTrackedFolderLanding(
                isTracked: false, tokenMatches: true, isDismissing: true, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldPinTrackedFolderLanding(
                isTracked: true, tokenMatches: false, isDismissing: true, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldPinTrackedFolderLanding(
                isTracked: true, tokenMatches: true, isDismissing: false, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldPinTrackedFolderLanding(
                isTracked: true, tokenMatches: true, isDismissing: true, isVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldPinTrackedFolderLanding(
                isTracked: true, tokenMatches: true, isDismissing: false, isVisible: false
            )
        )
        XCTAssertEqual(
            LauncherLayout.shouldPinTrackedFolderLanding(
                isTracked: true, tokenMatches: true, isDismissing: true, isVisible: true
            ),
            !LauncherLayout.shouldCommitFolderLanding(isDismissing: true, isVisible: true)
        )
        XCTAssertEqual(
            LauncherLayout.shouldPinTrackedFolderLanding(
                isTracked: true, tokenMatches: true, isDismissing: false, isVisible: true
            ),
            !LauncherLayout.shouldCommitFolderLanding(isDismissing: false, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldSnapInFlightFolderLanding(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightFolderLanding(isDismissing: false, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightFolderLanding(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightFolderLanding(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldSnapInFlightFolderLanding(isDismissing: true, isVisible: true),
            LauncherLayout.shouldCommitFolderLanding(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldHoldInFlightLauncherPresence(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldInFlightLauncherPresence(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldInFlightLauncherPresence(isDismissing: true, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldHoldInFlightLauncherPresence(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldHoldInFlightLauncherPresence(isDismissing: true, isVisible: true),
            LauncherLayout.shouldHoldInFlightToastFade(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldSnapInFlightLauncherPresence(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightLauncherPresence(isDismissing: false, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightLauncherPresence(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightLauncherPresence(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldSnapInFlightLauncherPresence(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldInFlightLauncherPresence(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldDropInFlightDragLift(
                isDismissing: true, isVisible: true, reducesMotion: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldDropInFlightDragLift(
                isDismissing: false, isVisible: true, reducesMotion: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldDropInFlightDragLift(
                isDismissing: true, isVisible: false, reducesMotion: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldDropInFlightDragLift(
                isDismissing: false, isVisible: true, reducesMotion: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldDropInFlightDragLift(
                isDismissing: true, isVisible: true, reducesMotion: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldDropInFlightDragLift(
                isDismissing: true, isVisible: false, reducesMotion: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldDropInFlightDragLift(
                isDismissing: false, isVisible: false, reducesMotion: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldDropInFlightDragLift(
                isDismissing: false, isVisible: false, reducesMotion: false
            )
        )
        XCTAssertEqual(
            LauncherLayout.shouldDropInFlightDragLift(
                isDismissing: false, isVisible: true, reducesMotion: true
            ),
            LauncherLayout.shouldSnapInFlightLauncherPresence(isDismissing: false, isVisible: true)
        )
        XCTAssertEqual(
            LauncherLayout.shouldDropInFlightDragLift(
                isDismissing: true, isVisible: true, reducesMotion: true
            ),
            LauncherLayout.shouldSnapInFlightLauncherPresence(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(
            LauncherLayout.shouldFollowPageDrag(
                reducesMotion: false, isDismissing: false, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldFollowPageDrag(
                reducesMotion: true, isDismissing: false, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldFollowPageDrag(
                reducesMotion: false, isDismissing: true, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldFollowPageDrag(
                reducesMotion: true, isDismissing: true, isVisible: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldFollowPageDrag(
                reducesMotion: false, isDismissing: true, isVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldFollowPageDrag(
                reducesMotion: true, isDismissing: false, isVisible: false
            )
        )
        XCTAssertEqual(
            LauncherLayout.shouldFollowPageDrag(
                reducesMotion: false, isDismissing: false, isVisible: true
            ),
            LauncherLayout.shouldSnapInFlightPageSlide(isDismissing: false, isVisible: true)
        )
        XCTAssertEqual(
            LauncherLayout.shouldFollowPageDrag(
                reducesMotion: true, isDismissing: true, isVisible: true
            ),
            false
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestInFlightPageDrag(
                reducesMotion: true, isDismissing: true, isVisible: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldRestInFlightPageDrag(
                reducesMotion: true, isDismissing: false, isVisible: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldRestInFlightPageDrag(
                reducesMotion: true, isDismissing: true, isVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestInFlightPageDrag(
                reducesMotion: false, isDismissing: false, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestInFlightPageDrag(
                reducesMotion: false, isDismissing: true, isVisible: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldRestInFlightPageDrag(
                reducesMotion: true, isDismissing: false, isVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestInFlightPageDrag(
                reducesMotion: false, isDismissing: false, isVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestInFlightPageDrag(
                reducesMotion: false, isDismissing: true, isVisible: false
            )
        )
        XCTAssertEqual(
            LauncherLayout.shouldRestInFlightPageDrag(
                reducesMotion: true, isDismissing: false, isVisible: true
            ),
            LauncherLayout.shouldSnapInFlightPageSlide(isDismissing: false, isVisible: true)
        )
        XCTAssertEqual(
            LauncherLayout.shouldRestInFlightPageDrag(
                reducesMotion: true, isDismissing: true, isVisible: true
            ),
            LauncherLayout.shouldSnapInFlightPageSlide(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(
            LauncherLayout.shouldAllowContentElasticity(
                reducesMotion: false, isDismissing: false, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAllowContentElasticity(
                reducesMotion: true, isDismissing: false, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAllowContentElasticity(
                reducesMotion: false, isDismissing: true, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAllowContentElasticity(
                reducesMotion: true, isDismissing: true, isVisible: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldAllowContentElasticity(
                reducesMotion: false, isDismissing: true, isVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAllowContentElasticity(
                reducesMotion: true, isDismissing: false, isVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAllowContentElasticity(
                reducesMotion: true, isDismissing: true, isVisible: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldAllowContentElasticity(
                reducesMotion: false, isDismissing: false, isVisible: false
            )
        )
        XCTAssertEqual(
            LauncherLayout.shouldAllowContentElasticity(
                reducesMotion: false, isDismissing: false, isVisible: true
            ),
            LauncherLayout.shouldFollowPageDrag(
                reducesMotion: false, isDismissing: false, isVisible: true
            )
        )
        XCTAssertEqual(
            LauncherLayout.shouldAllowContentElasticity(
                reducesMotion: true, isDismissing: true, isVisible: true
            ),
            LauncherLayout.shouldFollowPageDrag(
                reducesMotion: true, isDismissing: true, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestInFlightContentScroll(
                reducesMotion: true, isDismissing: true, isVisible: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldRestInFlightContentScroll(
                reducesMotion: true, isDismissing: false, isVisible: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldRestInFlightContentScroll(
                reducesMotion: true, isDismissing: true, isVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestInFlightContentScroll(
                reducesMotion: false, isDismissing: false, isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestInFlightContentScroll(
                reducesMotion: false, isDismissing: true, isVisible: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldRestInFlightContentScroll(
                reducesMotion: true, isDismissing: false, isVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestInFlightContentScroll(
                reducesMotion: false, isDismissing: false, isVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestInFlightContentScroll(
                reducesMotion: false, isDismissing: true, isVisible: false
            )
        )
        XCTAssertEqual(
            LauncherLayout.shouldRestInFlightContentScroll(
                reducesMotion: true, isDismissing: false, isVisible: true
            ),
            LauncherLayout.shouldRestInFlightPageDrag(
                reducesMotion: true, isDismissing: false, isVisible: true
            )
        )
        XCTAssertEqual(
            LauncherLayout.shouldRestInFlightContentScroll(
                reducesMotion: true, isDismissing: true, isVisible: true
            ),
            LauncherLayout.shouldSnapInFlightPageSlide(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldHoldMergeFlight(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldMergeFlight(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldMergeFlight(isDismissing: true, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldHoldMergeFlight(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldHoldMergeFlight(isDismissing: true, isVisible: true),
            LauncherLayout.shouldHoldToastDismissal(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldAdvanceMergeFlight(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldAdvanceMergeFlight(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldAdvanceMergeFlight(isDismissing: true, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldAdvanceMergeFlight(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldAdvanceMergeFlight(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldMergeFlight(isDismissing: true, isVisible: true)
        )
        XCTAssertEqual(
            LauncherLayout.shouldAdvanceMergeFlight(isDismissing: false, isVisible: true),
            !LauncherLayout.shouldHoldMergeFlight(isDismissing: false, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldSnapInFlightMergeFlight(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightMergeFlight(isDismissing: false, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightMergeFlight(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightMergeFlight(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldSnapInFlightMergeFlight(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldMergeFlight(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldHoldFolderChromeAnimation(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldFolderChromeAnimation(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldFolderChromeAnimation(isDismissing: true, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldHoldFolderChromeAnimation(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldHoldFolderChromeAnimation(isDismissing: true, isVisible: true),
            LauncherLayout.shouldHoldMergeFlight(isDismissing: true, isVisible: true)
        )
        let openBackdrop = LauncherLayout.folderBackdropStyle(open: true, reducesMotion: false)
        XCTAssertEqual(openBackdrop.opacity, 0.45, accuracy: 0.001)
        XCTAssertEqual(openBackdrop.scale, 0.96, accuracy: 0.001)
        XCTAssertTrue(openBackdrop.blurs)
        let reducedBackdrop = LauncherLayout.folderBackdropStyle(open: true, reducesMotion: true)
        XCTAssertEqual(reducedBackdrop.opacity, openBackdrop.opacity, accuracy: 0.001)
        XCTAssertEqual(reducedBackdrop.scale, 1, accuracy: 0.001)
        XCTAssertFalse(reducedBackdrop.blurs)
        let closedBackdrop = LauncherLayout.folderBackdropStyle(open: false, reducesMotion: false)
        XCTAssertEqual(closedBackdrop.opacity, 1, accuracy: 0.001)
        XCTAssertEqual(closedBackdrop.scale, 1, accuracy: 0.001)
        XCTAssertFalse(closedBackdrop.blurs)
        XCTAssertFalse(LauncherLayout.folderBackdropStyle(open: false, reducesMotion: true).blurs)
        XCTAssertFalse(
            LauncherLayout.shouldApplyFolderBackdropStyle(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(
            LauncherLayout.shouldApplyFolderBackdropStyle(isDismissing: false, isVisible: true)
        )
        XCTAssertTrue(
            LauncherLayout.shouldApplyFolderBackdropStyle(isDismissing: true, isVisible: false)
        )
        XCTAssertTrue(
            LauncherLayout.shouldApplyFolderBackdropStyle(isDismissing: false, isVisible: false)
        )
        XCTAssertEqual(
            LauncherLayout.shouldApplyFolderBackdropStyle(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldFolderChromeAnimation(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapInFlightFolderChromeAnimation(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(
            LauncherLayout.shouldSnapInFlightFolderChromeAnimation(isDismissing: false, isVisible: true)
        )
        XCTAssertTrue(
            LauncherLayout.shouldSnapInFlightFolderChromeAnimation(isDismissing: true, isVisible: false)
        )
        XCTAssertTrue(
            LauncherLayout.shouldSnapInFlightFolderChromeAnimation(isDismissing: false, isVisible: false)
        )
        XCTAssertEqual(
            LauncherLayout.shouldSnapInFlightFolderChromeAnimation(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldFolderChromeAnimation(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldHoldSearchChromeAnimation(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldSearchChromeAnimation(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldSearchChromeAnimation(isDismissing: true, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldHoldSearchChromeAnimation(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldHoldSearchChromeAnimation(isDismissing: true, isVisible: true),
            LauncherLayout.shouldHoldFolderChromeAnimation(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldSnapInFlightSearchChromeFade(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightSearchChromeFade(isDismissing: false, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightSearchChromeFade(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightSearchChromeFade(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldSnapInFlightSearchChromeFade(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldSearchChromeAnimation(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldHoldDissolvedGridFade(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldDissolvedGridFade(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldDissolvedGridFade(isDismissing: true, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldHoldDissolvedGridFade(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldHoldDissolvedGridFade(isDismissing: true, isVisible: true),
            LauncherLayout.shouldHoldSearchChromeAnimation(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldSnapInFlightDissolvedGridFade(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightDissolvedGridFade(isDismissing: false, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightDissolvedGridFade(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightDissolvedGridFade(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldSnapInFlightDissolvedGridFade(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldDissolvedGridFade(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldHoldPageSlide(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldPageSlide(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldPageSlide(isDismissing: true, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldHoldPageSlide(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldHoldPageSlide(isDismissing: true, isVisible: true),
            LauncherLayout.shouldHoldDissolvedGridFade(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldSnapInFlightPageSlide(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightPageSlide(isDismissing: false, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightPageSlide(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightPageSlide(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldSnapInFlightPageSlide(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldPageSlide(isDismissing: true, isVisible: true)
        )
        XCTAssertEqual(
            LauncherLayout.shouldCommitRestoredGridPage(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldPageSlide(isDismissing: true, isVisible: true)
        )
        XCTAssertEqual(
            LauncherLayout.shouldCommitRestoredGridPage(isDismissing: false, isVisible: true),
            !LauncherLayout.shouldHoldPageSlide(isDismissing: false, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldHoldLaunchFeedback(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldLaunchFeedback(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldLaunchFeedback(isDismissing: true, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldHoldLaunchFeedback(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldHoldLaunchFeedback(isDismissing: true, isVisible: true),
            LauncherLayout.shouldHoldPageSlide(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldPlayLaunchFeedback(isDismissing: false, reducesMotion: false))
        XCTAssertFalse(LauncherLayout.shouldPlayLaunchFeedback(isDismissing: true, reducesMotion: false))
        XCTAssertFalse(LauncherLayout.shouldPlayLaunchFeedback(isDismissing: false, reducesMotion: true))
        XCTAssertFalse(LauncherLayout.shouldPlayLaunchFeedback(isDismissing: true, reducesMotion: true))
        XCTAssertFalse(LauncherLayout.shouldSnapInFlightLaunchFeedback(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightLaunchFeedback(isDismissing: false, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightLaunchFeedback(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightLaunchFeedback(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldSnapInFlightLaunchFeedback(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldLaunchFeedback(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldHoldReorderSlide(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldReorderSlide(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldReorderSlide(isDismissing: true, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldHoldReorderSlide(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldHoldReorderSlide(isDismissing: true, isVisible: true),
            LauncherLayout.shouldHoldLaunchFeedback(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(
            LauncherLayout.shouldAnimateReorderSlide(
                isDismissing: false, isVisible: true, reducesMotion: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimateReorderSlide(
                isDismissing: true, isVisible: true, reducesMotion: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimateReorderSlide(
                isDismissing: false, isVisible: true, reducesMotion: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimateReorderSlide(
                isDismissing: true, isVisible: true, reducesMotion: true
            )
        )
        XCTAssertEqual(
            LauncherLayout.shouldAnimateReorderSlide(
                isDismissing: true, isVisible: true, reducesMotion: false
            ),
            !LauncherLayout.shouldHoldReorderSlide(isDismissing: true, isVisible: true)
        )
        XCTAssertFalse(LauncherLayout.shouldSnapInFlightReorderSlide(isDismissing: true, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightReorderSlide(isDismissing: false, isVisible: true))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightReorderSlide(isDismissing: true, isVisible: false))
        XCTAssertTrue(LauncherLayout.shouldSnapInFlightReorderSlide(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldSnapInFlightReorderSlide(isDismissing: true, isVisible: true),
            !LauncherLayout.shouldHoldReorderSlide(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(LauncherLayout.shouldHoldPageButtonHover(isDismissing: true, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldPageButtonHover(isDismissing: false, isVisible: true))
        XCTAssertFalse(LauncherLayout.shouldHoldPageButtonHover(isDismissing: true, isVisible: false))
        XCTAssertFalse(LauncherLayout.shouldHoldPageButtonHover(isDismissing: false, isVisible: false))
        XCTAssertEqual(
            LauncherLayout.shouldHoldPageButtonHover(isDismissing: true, isVisible: true),
            LauncherLayout.shouldHoldReorderSlide(isDismissing: true, isVisible: true)
        )
        XCTAssertTrue(
            LauncherLayout.shouldAnimatePageButtonHover(
                isDismissing: false, isVisible: true, reducesMotion: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageButtonHover(
                isDismissing: true, isVisible: true, reducesMotion: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageButtonHover(
                isDismissing: true, isVisible: false, reducesMotion: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageButtonHover(
                isDismissing: false, isVisible: false, reducesMotion: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageButtonHover(
                isDismissing: false, isVisible: true, reducesMotion: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageButtonHover(
                isDismissing: true, isVisible: true, reducesMotion: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageButtonHover(
                isDismissing: false, isVisible: false, reducesMotion: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageButtonHover(
                isDismissing: true, isVisible: false, reducesMotion: true
            )
        )
        XCTAssertEqual(
            LauncherLayout.shouldAnimatePageButtonHover(
                isDismissing: true, isVisible: true, reducesMotion: false
            ),
            !LauncherLayout.shouldHoldPageButtonHover(isDismissing: true, isVisible: true)
        )
    }

    func testDragLiftScalesTheSourceAndReservesShadowUnlessMotionIsReduced() {
        let source = CGSize(width: 100, height: 120)
        let lifted = LauncherLayout.dragLiftPresentation(for: source, reducesMotion: false)
        XCTAssertEqual(lifted.scale, 1.06, accuracy: 0.001)
        XCTAssertEqual(lifted.shadowOpacity, 0.18, accuracy: 0.001)
        XCTAssertEqual(lifted.contentSize.width, 106, accuracy: 0.01)
        XCTAssertEqual(lifted.contentSize.height, 127.2, accuracy: 0.01)
        XCTAssertGreaterThan(lifted.canvasSize.width, lifted.contentSize.width)
        XCTAssertGreaterThan(lifted.canvasSize.height, lifted.contentSize.height)
        XCTAssertGreaterThan(lifted.shadowRadius, 0)
        let frame = lifted.canvasFrame(centering: CGRect(x: 10, y: 20, width: 100, height: 120))
        XCTAssertEqual(frame.midX, 60, accuracy: 0.01)
        XCTAssertEqual(frame.midY, 80, accuracy: 0.01)
        XCTAssertEqual(frame.size, lifted.canvasSize)
        let content = lifted.contentOrigin
        XCTAssertEqual(content.x, lifted.shadowRadius, accuracy: 0.01)
        XCTAssertEqual(content.y, lifted.shadowRadius - lifted.shadowOffset.height, accuracy: 0.01)
        XCTAssertLessThanOrEqual(content.x + lifted.contentSize.width + lifted.shadowRadius, lifted.canvasSize.width + 0.01)
        XCTAssertLessThanOrEqual(content.y + lifted.contentSize.height + lifted.shadowRadius, lifted.canvasSize.height + 0.01)

        let reduced = LauncherLayout.dragLiftPresentation(for: source, reducesMotion: true)
        XCTAssertEqual(reduced.scale, 1, accuracy: 0.001)
        XCTAssertEqual(reduced.shadowOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(reduced.canvasSize, source)
        XCTAssertEqual(reduced.contentOrigin, .zero)

        let empty = LauncherLayout.dragLiftPresentation(for: .zero, reducesMotion: false)
        XCTAssertEqual(empty.canvasSize, .zero)
        XCTAssertEqual(empty.shadowOpacity, 0, accuracy: 0.001)
    }

    func testItemSizeIsPositiveForTypicalViewport() {
        let size = LauncherLayout.itemSize(in: CGSize(width: 1200, height: 700))
        XCTAssertGreaterThanOrEqual(size.width, 72)
        XCTAssertGreaterThanOrEqual(size.height, 124)
        XCTAssertEqual(LauncherLayout.pageAnimationDuration, 0.28, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.pageColumns, 7)
        XCTAssertEqual(LauncherLayout.pageRows, 5)
    }

    func testCompactViewportFitsAllSevenByFiveItems() {
        // A 1365×768 display leaves this viewport after the search and page-indicator margins.
        let viewport = CGSize(width: 1173, height: 578)
        let item = LauncherLayout.itemSize(in: viewport)
        let contentWidth = CGFloat(LauncherLayout.pageColumns) * item.width + 6 * 12 + 16
        let contentHeight = CGFloat(LauncherLayout.pageRows) * item.height + 4 * 10 + 12
        XCTAssertLessThanOrEqual(contentWidth, viewport.width)
        XCTAssertLessThanOrEqual(contentHeight, viewport.height)
        XCTAssertGreaterThanOrEqual(item.height, LauncherLayout.iconPointSize(in: item) + 40)
    }

    func testIconSizeAdaptsWithinLaunchpadRange() {
        XCTAssertEqual(LauncherLayout.iconPointSize(in: CGSize(width: 72, height: 124)), 60)
        XCTAssertEqual(LauncherLayout.iconPointSize(in: CGSize(width: 148, height: 112)), 72)
        XCTAssertEqual(LauncherLayout.iconPointSize(in: CGSize(width: 220, height: 160)), 84)
    }

    func testFolderPanelWidthAdaptsToVisibleColumns() {
        XCTAssertEqual(LauncherLayout.folderDisplayColumns(forItemCount: 2), 2)
        XCTAssertEqual(LauncherLayout.preferredFolderPanelWidth(forItemCount: 2), 460)
        XCTAssertEqual(LauncherLayout.preferredFolderPanelWidth(forItemCount: 3), 512)
        XCTAssertEqual(LauncherLayout.preferredFolderPanelWidth(forItemCount: 4), 672)
        XCTAssertEqual(LauncherLayout.folderDisplayColumns(forItemCount: 25), 5)
        XCTAssertEqual(LauncherLayout.preferredFolderPanelWidth(forItemCount: 25), 820)
    }

    func testCompactViewportKeepsIconAndCaptionInsideEachGridCell() {
        let viewport = CGSize(width: 800, height: 400)
        let item = LauncherLayout.itemSize(in: viewport)
        let icon = LauncherLayout.iconPointSize(in: item)

        XCTAssertLessThanOrEqual(icon + 40, item.height)
        XCTAssertLessThanOrEqual(icon, item.width)
        XCTAssertLessThanOrEqual(LauncherLayout.iconPointSize(in: CGSize(width: 44, height: 124)), 44)
    }

    func testSearchMatchesDisplayNameAndBundleIdentifierIgnoringCaseAndDiacritics() {
        let cafe = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Café.app"),
            bundleIdentifier: "com.example.cafe",
            displayName: "Café",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let calendar = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Calendar.app"),
            bundleIdentifier: "com.apple.iCal",
            displayName: "日历",
            sourcePriority: 0,
            discoveredAt: .now
        )

        XCTAssertEqual(AppSearch.filter([cafe, calendar], query: "CAFE"), [cafe])
        XCTAssertEqual(AppSearch.filter([cafe, calendar], query: "ical"), [calendar])
        XCTAssertEqual(AppSearch.filter([cafe, calendar], query: "日历"), [calendar])
        XCTAssertEqual(AppSearch.filter([cafe, calendar], query: "Calendar"), [calendar])
        XCTAssertEqual(AppSearch.filter([cafe, calendar], query: "  Calendar \n"), [calendar])
        XCTAssertEqual(AppSearch.filter([cafe, calendar], query: " \t "), [cafe, calendar])

        let photoShop = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/PhotoShop.app"),
            bundleIdentifier: "com.example.photoshop",
            displayName: "Photo Shop",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let vsCode = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/VSCode.app"),
            bundleIdentifier: "com.example.vscode",
            displayName: "VSCode",
            sourcePriority: 0,
            discoveredAt: .now
        )
        XCTAssertEqual(AppSearch.filter([photoShop, vsCode], query: "photoshop"), [photoShop])
        XCTAssertEqual(AppSearch.filter([photoShop, vsCode], query: "photo shop"), [photoShop])
        XCTAssertEqual(AppSearch.filter([photoShop, vsCode], query: "vs code"), [vsCode])
        XCTAssertEqual(AppSearch.filter([photoShop], query: "p"), [photoShop])

        let shop = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Shop.app"),
            bundleIdentifier: "com.example.shop",
            displayName: "Shop",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let shopHelper = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/PhotoShopHelper.app"),
            bundleIdentifier: "com.example.photoshophelper",
            displayName: "Photo Shop Helper",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let localizedShop = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Shop.app"),
            bundleIdentifier: "com.example.localizedshop",
            displayName: "商店",
            sourcePriority: 0,
            discoveredAt: .now
        )
        XCTAssertEqual(AppSearch.filter([shopHelper, shop], query: "shop"), [shop, shopHelper])
        XCTAssertEqual(AppSearch.filter([shopHelper, localizedShop], query: "shop"), [localizedShop, shopHelper])
        XCTAssertEqual(AppSearch.filter([shopHelper, shop], query: " "), [shopHelper, shop])

        let localCalendar = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/LocalCalendar.app"),
            bundleIdentifier: "com.example.localcalendar",
            displayName: "Local Calendar",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let plainCalendar = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Calendar.app"),
            bundleIdentifier: "com.example.calendar",
            displayName: "Calendar",
            sourcePriority: 0,
            discoveredAt: .now
        )
        XCTAssertEqual(AppSearch.filter([localCalendar, plainCalendar], query: "cal"), [plainCalendar, localCalendar])
    }

    func testSearchMatchesChineseNamesAndAliasesByFullPinyinAndInitials() {
        let calendar = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/日历.app"),
            bundleIdentifier: "com.apple.iCal",
            displayName: "工具",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let aliases = [calendar.deduplicationKey: "我的工具"]

        XCTAssertEqual(AppSearch.filter([calendar], query: "ri li"), [calendar])
        XCTAssertEqual(AppSearch.filter([calendar], query: "rili"), [calendar])
        XCTAssertEqual(AppSearch.filter([calendar], query: "rl"), [calendar])
        XCTAssertEqual(AppSearch.filter([calendar], query: "gongju"), [calendar])
        XCTAssertEqual(AppSearch.filter([calendar], query: "gj"), [calendar])
        XCTAssertEqual(AppSearch.filter([calendar], query: "wodegongju", aliases: aliases), [calendar])
        XCTAssertEqual(AppSearch.filter([calendar], query: "wdgj", aliases: aliases), [calendar])
    }

    func testSearchIndexCachesCatalogTermsAndRefreshesAliases() {
        let calendar = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/日历.app"),
            bundleIdentifier: "com.apple.iCal",
            displayName: "日历",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let tools = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/工具箱.app"),
            bundleIdentifier: "com.example.tools",
            displayName: "工具箱",
            sourcePriority: 0,
            discoveredAt: .now
        )
        var index = AppSearchIndex(candidates: [calendar, tools])

        XCTAssertEqual(index.filter([tools, calendar], query: "rl"), [calendar])
        XCTAssertEqual(index.filter([tools, calendar], query: "gongju"), [tools])
        XCTAssertEqual(index.filter([tools, calendar], query: "ical"), [calendar])
        XCTAssertEqual(index.filter([tools, calendar], query: " "), [tools, calendar])

        index.setAliases([calendar.deduplicationKey: "我的日历"])
        XCTAssertEqual(index.filter([tools, calendar], query: "woderili"), [calendar])
        XCTAssertEqual(index.filter([tools, calendar], query: "wdrl"), [calendar])
        index.setAliases([:])
        XCTAssertTrue(index.filter([tools, calendar], query: "woderili").isEmpty)
    }

    func testSearchIndexUsesCurrentMetadataWhileCatalogIndexRebuilds() {
        let old = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/LegacyBinary.app"),
            bundleIdentifier: "com.example.tool",
            displayName: "Old Tool",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let renamed = AppCandidate(
            canonicalURL: old.canonicalURL,
            bundleIdentifier: old.bundleIdentifier,
            displayName: "New Photo",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let moved = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/NewPhoto.app"),
            bundleIdentifier: old.bundleIdentifier,
            displayName: old.displayName,
            sourcePriority: 0,
            discoveredAt: .now
        )
        let index = AppSearchIndex(candidates: [old])

        XCTAssertEqual(old.deduplicationKey, renamed.deduplicationKey)
        XCTAssertEqual(old.deduplicationKey, moved.deduplicationKey)
        XCTAssertEqual(index.filter([renamed], query: "New Photo"), [renamed])
        XCTAssertTrue(index.filter([renamed], query: "Old Tool").isEmpty)
        XCTAssertEqual(index.filter([moved], query: "NewPhoto"), [moved])
        XCTAssertEqual(index.filter([moved], query: "OldTool"), [moved])
        XCTAssertTrue(index.filter([moved], query: "LegacyBinary").isEmpty)
    }

    func testPageSlottingUsesSevenByFiveCapacity() {
        XCTAssertEqual(LauncherLayout.pageColumns * LauncherLayout.pageRows, 35)
        XCTAssertEqual(LauncherLayout.pageCapacity, 35)
        XCTAssertEqual(LauncherLayout.folderColumns * LauncherLayout.folderRows, 25)

        let entries = (0..<36).map { _ in LauncherEntry.app(UUID()) }
        XCTAssertEqual(LauncherLayout.pageCount(forEntryCount: entries.count), 2)
        XCTAssertEqual(LauncherLayout.entries(onPage: 0, from: entries).count, 35)
        XCTAssertEqual(LauncherLayout.entries(onPage: 1, from: entries).count, 1)
        XCTAssertEqual(LauncherLayout.pageIndex(containingEntryAt: 34), 0)
        XCTAssertEqual(LauncherLayout.pageIndex(containingEntryAt: 35), 1)
        XCTAssertEqual(LauncherLayout.visiblePageIndices(pageCount: 9, selectedPage: 0), Array(0..<7))
        XCTAssertEqual(LauncherLayout.visiblePageIndices(pageCount: 9, selectedPage: 8), Array(2..<9))
        XCTAssertEqual(
            LauncherLayout.pageIndicatorSlots(pageCount: 9, selectedPage: 0),
            [.page(0), .page(1), .page(2), .page(3), .page(4), .page(5), .page(6), .ellipsis]
        )
        XCTAssertEqual(
            LauncherLayout.pageIndicatorSlots(pageCount: 9, selectedPage: 4),
            [.ellipsis, .page(1), .page(2), .page(3), .page(4), .page(5), .page(6), .page(7), .ellipsis]
        )
        XCTAssertEqual(
            LauncherLayout.pageIndicatorSlots(pageCount: 9, selectedPage: 8),
            [.ellipsis, .page(2), .page(3), .page(4), .page(5), .page(6), .page(7), .page(8)]
        )
    }

    func testFocusSlotAfterPageTurnKeepsRelativeGridPosition() {
        let fullPage = LauncherLayout.pageCapacity
        XCTAssertEqual(LauncherLayout.focusSlot(previousSlot: 12, itemCount: fullPage), 12)
        XCTAssertEqual(LauncherLayout.focusSlot(previousSlot: 0, itemCount: fullPage), 0)
        XCTAssertEqual(LauncherLayout.focusSlot(previousSlot: fullPage - 1, itemCount: fullPage), fullPage - 1)

        XCTAssertEqual(LauncherLayout.focusSlot(previousSlot: 2, itemCount: 8), 2)
        XCTAssertEqual(LauncherLayout.focusSlot(previousSlot: 34, itemCount: 8), 7)
        XCTAssertEqual(LauncherLayout.focusSlot(previousSlot: 20, itemCount: 1), 0)

        XCTAssertNil(LauncherLayout.focusSlot(previousSlot: 4, itemCount: 0))
        XCTAssertNil(LauncherLayout.focusSlot(previousSlot: nil, itemCount: fullPage))
    }

    func testRepeatedPageTurnContinuesFromInFlightPage() {
        XCTAssertEqual(
            LauncherLayout.pageIndex(movingBy: 1, from: 0, inFlightPage: nil, queuedPage: nil, pageCount: 4),
            1
        )
        XCTAssertEqual(
            LauncherLayout.pageIndex(movingBy: 1, from: 0, inFlightPage: 1, queuedPage: nil, pageCount: 4),
            2
        )
        XCTAssertEqual(
            LauncherLayout.pageIndex(movingBy: 1, from: 0, inFlightPage: 1, queuedPage: 2, pageCount: 4),
            3
        )
        XCTAssertEqual(
            LauncherLayout.pageIndex(movingBy: 1, from: 2, inFlightPage: 3, queuedPage: nil, pageCount: 4),
            3
        )
        XCTAssertEqual(
            LauncherLayout.pageIndex(movingBy: -1, from: 1, inFlightPage: 2, queuedPage: nil, pageCount: 4),
            1
        )
        XCTAssertEqual(
            LauncherLayout.pageIndex(movingBy: -1, from: 0, inFlightPage: nil, queuedPage: nil, pageCount: 4),
            0
        )
        XCTAssertEqual(
            LauncherLayout.pageIndex(movingBy: 1, from: 0, inFlightPage: nil, queuedPage: nil, pageCount: 0),
            0
        )

        XCTAssertEqual(LauncherLayout.pagingControlPage(currentPage: 0, inFlightPage: nil, queuedPage: nil), 0)
        XCTAssertEqual(LauncherLayout.pagingControlPage(currentPage: 0, inFlightPage: 1, queuedPage: nil), 1)
        XCTAssertEqual(LauncherLayout.pagingControlPage(currentPage: 0, inFlightPage: 1, queuedPage: 2), 2)
    }

    func testCatalogReloadKeepsTheNewerLayout() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let appID = UUID()
        let stored = LayoutState(
            orderedEntries: [.app(appID)],
            appKeys: [appID: "stored"],
            updatedAt: older
        )
        let edited = LayoutState(
            orderedEntries: [.app(appID)],
            appKeys: [appID: "edited"],
            appAliases: ["edited": "新名字"],
            updatedAt: newer
        )
        XCTAssertEqual(LauncherLayout.layoutBaseForCatalogReload(memory: LayoutState(updatedAt: newer), stored: stored).appKeys, stored.appKeys)
        XCTAssertEqual(LauncherLayout.layoutBaseForCatalogReload(memory: edited, stored: stored).appAliases, edited.appAliases)
        XCTAssertEqual(
            LauncherLayout.layoutBaseForCatalogReload(memory: edited, stored: LayoutState(updatedAt: newer)).appAliases,
            edited.appAliases
        )
        let diskNewer = LayoutState(orderedEntries: [.app(appID)], appKeys: [appID: "disk"], updatedAt: newer)
        let memoryOlder = LayoutState(orderedEntries: [.app(appID)], appKeys: [appID: "memory"], updatedAt: older)
        XCTAssertEqual(LauncherLayout.layoutBaseForCatalogReload(memory: memoryOlder, stored: diskNewer).appKeys, diskNewer.appKeys)
    }

    func testPageToRestoreKeepsTheRequestedPageAndClamps() {
        XCTAssertEqual(LauncherLayout.pageToRestore(currentPage: 2, inFlightPage: nil, queuedPage: nil, pageCount: 4), 2)
        XCTAssertEqual(LauncherLayout.pageToRestore(currentPage: 0, inFlightPage: 1, queuedPage: nil, pageCount: 4), 1)
        XCTAssertEqual(LauncherLayout.pageToRestore(currentPage: 0, inFlightPage: 1, queuedPage: 3, pageCount: 4), 3)
        XCTAssertEqual(LauncherLayout.pageToRestore(currentPage: 5, inFlightPage: nil, queuedPage: nil, pageCount: 2), 1)
        XCTAssertEqual(LauncherLayout.pageToRestore(currentPage: 1, inFlightPage: 4, queuedPage: nil, pageCount: 2), 1)
        XCTAssertEqual(LauncherLayout.pageToRestore(currentPage: 3, inFlightPage: nil, queuedPage: nil, pageCount: 0), 0)
        XCTAssertEqual(LauncherLayout.pageToRestore(currentPage: -2, inFlightPage: nil, queuedPage: nil, pageCount: 3), 0)
    }

    func testClampedScrollOffsetStaysInsideAShorterDocument() {
        XCTAssertEqual(LauncherLayout.clampedScrollOffset(500, documentLength: 400, viewportLength: 100), 300)
        XCTAssertEqual(LauncherLayout.clampedScrollOffset(40, documentLength: 400, viewportLength: 100), 40)
        XCTAssertEqual(LauncherLayout.clampedScrollOffset(-8, documentLength: 400, viewportLength: 100), 0)
        XCTAssertEqual(LauncherLayout.clampedScrollOffset(80, documentLength: 50, viewportLength: 100), 0)
    }

    func testSearchQueryEditingKeepsMarkedTextAndDeletesAGraphemeOrWord() {
        XCTAssertEqual(LauncherLayout.searchQuery(committed: "时钟", editing: nil), "时钟")
        XCTAssertEqual(LauncherLayout.searchQuery(committed: "时钟", editing: "时钟shizhong"), "时钟shizhong")
        XCTAssertEqual(LauncherLayout.searchQuery(committed: "Clock", editing: ""), "")

        XCTAssertEqual(LauncherLayout.searchQueryAppending("Clock", "k"), "Clockk")
        XCTAssertEqual(LauncherLayout.searchQueryAppending("Photo", " Shop"), "Photo Shop")
        XCTAssertEqual(LauncherLayout.searchQueryAppending("", "c"), "c")

        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastCharacter(""), "")
        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastCharacter("Clock"), "Cloc")
        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastCharacter("时钟"), "时")
        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastCharacter("a👋"), "a")
        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastCharacter("👨‍👩‍👧‍👦b"), "👨‍👩‍👧‍👦")

        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastWord(""), "")
        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastWord("one two"), "one ")
        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastWord("one two "), "one ")
        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastWord("one  two"), "one  ")
        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastWord("hello,"), "hello")
        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastWord("hello, "), "hello")
        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastWord("hello "), "")
        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastWord("   "), "")
        XCTAssertEqual(LauncherLayout.searchQueryDeletingLastWord("时钟"), "")

        let emoji = "a👋b"
        let emojiLocation = ("a" as NSString).length
        let emojiLength = ("👋" as NSString).length
        XCTAssertEqual(
            LauncherLayout.textByRemovingMarkedRange(emoji, utf16Location: emojiLocation, utf16Length: emojiLength),
            "ab"
        )
        XCTAssertEqual(LauncherLayout.textByRemovingMarkedRange("草稿", utf16Location: 0, utf16Length: 0), "草稿")
        XCTAssertEqual(LauncherLayout.textByRemovingMarkedRange("草稿", utf16Location: -1, utf16Length: 1), "草稿")
        XCTAssertEqual(LauncherLayout.textByRemovingMarkedRange("草稿", utf16Location: 1, utf16Length: 8), "草稿")
        XCTAssertEqual(LauncherLayout.textByRemovingMarkedRange("草稿", utf16Location: 0, utf16Length: 1), "稿")
    }

    func testSearchScrollQueryKeyIgnoresCaseWidthAccentsAndInteriorSpaces() {
        let fullwidthClock = "\u{FF23}\u{FF4C}\u{FF4F}\u{FF43}\u{FF4B}"
        XCTAssertEqual(LauncherLayout.searchScrollQueryKey("Clock"), LauncherLayout.searchScrollQueryKey("clock"))
        XCTAssertEqual(LauncherLayout.searchScrollQueryKey("CLOCK"), LauncherLayout.searchScrollQueryKey(fullwidthClock))
        XCTAssertEqual(LauncherLayout.searchScrollQueryKey("Café"), LauncherLayout.searchScrollQueryKey("cafe"))
        XCTAssertEqual(LauncherLayout.searchScrollQueryKey("Photo Shop"), LauncherLayout.searchScrollQueryKey("photoshop"))
        XCTAssertEqual(LauncherLayout.searchScrollQueryKey("photo  shop"), LauncherLayout.searchScrollQueryKey("PhotoShop"))
        XCTAssertEqual(LauncherLayout.searchScrollQueryKey(" a "), "a")
        XCTAssertEqual(LauncherLayout.searchScrollQueryKey("A"), "a")
        XCTAssertNotEqual(LauncherLayout.searchScrollQueryKey("a"), LauncherLayout.searchScrollQueryKey("ab"))
        XCTAssertEqual(LauncherLayout.searchScrollQueryKey("a b"), "ab")
        XCTAssertEqual(LauncherLayout.searchScrollQueryKey("  "), "")
        XCTAssertEqual(LauncherLayout.searchScrollQueryKey(""), "")
        XCTAssertNotEqual(LauncherLayout.searchScrollQueryKey("Clock"), LauncherLayout.searchScrollQueryKey("Calculator"))
    }

    func testFullwidthLettersMatchTheSameSearchHits() {
        let cafe = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Café.app"),
            bundleIdentifier: "com.example.cafe",
            displayName: "Café",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let photoShop = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/PhotoShop.app"),
            bundleIdentifier: "com.example.photoshop",
            displayName: "Photo Shop",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let fullwidthCafe = "\u{FF23}\u{FF21}\u{FF26}\u{FF25}"
        let fullwidthPhotoShop = "\u{FF30}\u{FF48}\u{FF4F}\u{FF54}\u{FF4F} \u{FF33}\u{FF48}\u{FF4F}\u{FF50}"
        XCTAssertEqual(AppSearch.filter([cafe, photoShop], query: fullwidthCafe), [cafe])
        XCTAssertEqual(AppSearch.filter([photoShop, cafe], query: fullwidthPhotoShop), [photoShop])
        XCTAssertEqual(AppSearch.filter([photoShop], query: "\u{FF30}"), [photoShop])
        // A single fullwidth letter matches like its ASCII form. "P" is a display
        // prefix of Photo Shop and also sits inside Café's bundle id, so the
        // closer name stays first.
        XCTAssertEqual(AppSearch.filter([cafe, photoShop], query: "\u{FF30}"), [photoShop, cafe])
    }

    func testScrolledPageOffsetMovesOneViewportAndClamps() {
        XCTAssertEqual(
            LauncherLayout.scrolledPageOffset(current: 0, documentLength: 1000, viewportLength: 100, forward: true),
            100
        )
        XCTAssertEqual(
            LauncherLayout.scrolledPageOffset(current: 100, documentLength: 1000, viewportLength: 100, forward: false),
            0
        )
        XCTAssertEqual(
            LauncherLayout.scrolledPageOffset(current: 950, documentLength: 1000, viewportLength: 100, forward: true),
            900
        )
        XCTAssertEqual(
            LauncherLayout.scrolledPageOffset(current: 0, documentLength: 1000, viewportLength: 100, forward: false),
            0
        )
        XCTAssertEqual(
            LauncherLayout.scrolledPageOffset(current: 40, documentLength: 1000, viewportLength: 0, forward: true),
            40
        )
        XCTAssertEqual(
            LauncherLayout.scrolledPageOffset(current: -20, documentLength: 100, viewportLength: 50, forward: true),
            30
        )
    }

    func testInsertionIndexAfterRemovingSourceMatchesCollectionViewPreRemovalDrop() {
        XCTAssertEqual(
            LauncherLayout.insertionIndexAfterRemovingSource(sourceIndex: 0, proposedIndex: 2, countBeforeRemoval: 3),
            1
        )
        XCTAssertEqual(
            LauncherLayout.insertionIndexAfterRemovingSource(sourceIndex: 0, proposedIndex: 3, countBeforeRemoval: 3),
            2
        )


        XCTAssertEqual(LauncherLayout.topLevelDropIndex(page: 0, localIndex: 3), 3)
        XCTAssertEqual(LauncherLayout.topLevelDropIndex(page: 1, localIndex: 0), LauncherLayout.pageCapacity)
        XCTAssertEqual(LauncherLayout.topLevelDropIndex(page: 2, localIndex: 4), LauncherLayout.pageCapacity * 2 + 4)
        XCTAssertEqual(LauncherLayout.topLevelDropIndex(page: -1, localIndex: -2), 0)
        XCTAssertEqual(
            LauncherLayout.insertionIndexAfterRemovingSource(sourceIndex: 2, proposedIndex: 0, countBeforeRemoval: 3),
            0
        )
        XCTAssertEqual(
            LauncherLayout.insertionIndexAfterRemovingSource(sourceIndex: 0, proposedIndex: 1, countBeforeRemoval: 3),
            0
        )
        XCTAssertEqual(
            LauncherLayout.insertionIndexAfterRemovingSource(sourceIndex: nil, proposedIndex: 2, countBeforeRemoval: 2),
            2
        )
    }

    func testReorderGapFollowsTheTrailingHalfOfTheHoveredItem() {
        XCTAssertEqual(
            LauncherLayout.reorderGapIndex(hoveredItem: 2, pointerX: 10, itemMinX: 0, itemWidth: 100, itemCount: 5),
            2
        )
        XCTAssertEqual(
            LauncherLayout.reorderGapIndex(hoveredItem: 2, pointerX: 50, itemMinX: 0, itemWidth: 100, itemCount: 5),
            3
        )
        XCTAssertEqual(
            LauncherLayout.reorderGapIndex(hoveredItem: 4, pointerX: 80, itemMinX: 0, itemWidth: 100, itemCount: 5),
            5
        )
        XCTAssertEqual(
            LauncherLayout.reorderGapIndex(hoveredItem: 0, pointerX: 10, itemMinX: 20, itemWidth: 40, itemCount: 2),
            0
        )
        XCTAssertEqual(
            LauncherLayout.reorderGapIndex(hoveredItem: -1, pointerX: 0, itemMinX: 0, itemWidth: 10, itemCount: 2),
            0
        )
        XCTAssertEqual(
            LauncherLayout.reorderGapIndex(hoveredItem: 3, pointerX: 9, itemMinX: 0, itemWidth: 0, itemCount: 3),
            3
        )
    }

    func testDropOntoTheNextPageReportsThatPageAndAFolderReorderDoesNot() {
        let ids = (0..<36).map { _ in UUID() }
        var moved = ids
        let dragged = moved.removeFirst()
        moved.append(dragged)
        let state = LayoutState(
            orderedEntries: moved.map { .app($0) },
            appKeys: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, "bundle:\($0)") }),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let drop = LayoutDrop(source: .topLevel(dragged), destination: .topLevelIndex(36))
        XCTAssertEqual(LauncherLayout.pageContainingDrop(drop, in: state), 1)

        let folderID = UUID()
        let member = ids[0]
        let inside = LayoutState(
            orderedEntries: [.folder(folderID)],
            folders: [folderID: LauncherFolder(id: folderID, name: "工具", itemIDs: [member, ids[1]])],
            appKeys: [member: "bundle:0", ids[1]: "bundle:1"],
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let reorder = LayoutDrop(
            source: .folderMember(folderID: folderID, itemID: member),
            destination: .folderIndex(folderID: folderID, index: 1)
        )
        XCTAssertNil(LauncherLayout.pageContainingDrop(reorder, in: inside))
    }

    func testDropFromEarlierPageKeepsTheItemOnTheVisibleTargetPage() {
        let ids = (0..<36).map { _ in UUID() }
        let dragged = ids[0]
        let state = LayoutState(
            orderedEntries: ids.map { .app($0) },
            appKeys: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, "bundle:\($0)") }),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let destinationIndex = LauncherLayout.topLevelDropIndex(
            page: 1,
            localIndex: 0,
            sourceIndex: 0,
            countBeforeRemoval: ids.count
        )
        let drop = LayoutDrop(source: .topLevel(dragged), destination: .topLevelIndex(destinationIndex))

        guard case .success(let moved) = LauncherLayout.applyDrop(drop, to: state) else {
            return XCTFail("Expected the cross-page drop to succeed")
        }
        XCTAssertEqual(moved.orderedEntries[LauncherLayout.pageCapacity].id, dragged)
        XCTAssertEqual(LauncherLayout.pageContainingDrop(drop, in: moved), 1)
    }

    func testPageAwareDropIndexPreservesEveryVisibleGapAfterSourceRemoval() {
        let capacity = LauncherLayout.pageCapacity
        let counts = [1, capacity - 1, capacity, capacity + 1, capacity * 2, capacity * 2 + 1]

        for count in counts {
            let pageCount = LauncherLayout.pageCount(forEntryCount: count)
            for sourceIndex in 0..<count {
                for page in 0..<pageCount {
                    let pageStart = page * capacity
                    let itemCount = min(capacity, count - pageStart)
                    for localIndex in 0...itemCount {
                        let flatGap = LauncherLayout.topLevelDropIndex(page: page, localIndex: localIndex)
                        let pageAwareGap = LauncherLayout.topLevelDropIndex(
                            page: page,
                            localIndex: localIndex,
                            sourceIndex: sourceIndex,
                            countBeforeRemoval: count
                        )
                        let expected: Int
                        if sourceIndex / capacity < page {
                            // Removing an earlier-page source must not pull the
                            // visible target page back by one slot.
                            expected = min(flatGap, count - 1)
                        } else {
                            expected = LauncherLayout.insertionIndexAfterRemovingSource(
                                sourceIndex: sourceIndex,
                                proposedIndex: flatGap,
                                countBeforeRemoval: count
                            )
                        }
                        let actual = LauncherLayout.insertionIndexAfterRemovingSource(
                            sourceIndex: sourceIndex,
                            proposedIndex: pageAwareGap,
                            countBeforeRemoval: count
                        )

                        XCTAssertEqual(
                            actual,
                            expected,
                            "count=\(count), source=\(sourceIndex), page=\(page), gap=\(localIndex)"
                        )
                    }
                }
            }
        }
    }

    func testDissolvedFolderFocusStaysOnTheRemainingApp() {
        let folderID = UUID()
        let kept = UUID()
        let neighbor = UUID()
        XCTAssertEqual(
            LauncherLayout.entryReplacingDissolvedFolder(
                folderID: folderID,
                previousEntries: [.app(neighbor), .folder(folderID)],
                currentEntries: [.app(neighbor), .app(kept)]
            ),
            kept
        )
        XCTAssertEqual(
            LauncherLayout.entryReplacingDissolvedFolder(
                folderID: folderID,
                previousEntries: [.app(neighbor), .folder(folderID)],
                currentEntries: [.app(neighbor)]
            ),
            neighbor
        )
        XCTAssertEqual(
            LauncherLayout.entryReplacingDissolvedFolder(
                folderID: folderID,
                previousEntries: [.folder(folderID), .app(neighbor)],
                currentEntries: [.folder(folderID), .app(neighbor)]
            ),
            folderID
        )
    }

    func testSearchTransitionUsesTheFastMotionToken() {
        XCTAssertEqual(LauncherLayout.searchTransitionDuration, 0.12, accuracy: 0.001)
    }

    func testSearchFieldUsesTheSpecifiedChromeSize() {
        XCTAssertGreaterThanOrEqual(LauncherLayout.searchFieldWidth, 360)
        XCTAssertLessThanOrEqual(LauncherLayout.searchFieldWidth, 520)
        XCTAssertEqual(LauncherLayout.searchFieldWidth, 400)
        XCTAssertEqual(LauncherLayout.searchFieldHeight, 42)
        XCTAssertEqual(LauncherLayout.searchFieldCornerRadius, 21)
    }

    func testDragReorderPreviewSlidesOtherItemsAroundTheGap() {
        XCTAssertEqual(LauncherLayout.reorderSlideDuration, 0.18, accuracy: 0.001)

        let movedToEnd = LauncherLayout.dragReorderPreview(sourceIndex: 0, proposedIndex: 4, count: 4)
        XCTAssertEqual(movedToEnd?.gapIndex, 3)
        XCTAssertEqual(movedToEnd?.slotByItem, [nil, 0, 1, 2])

        let openedAfterFirst = LauncherLayout.dragReorderPreview(sourceIndex: 0, proposedIndex: 2, count: 4)
        XCTAssertEqual(openedAfterFirst?.gapIndex, 1)
        XCTAssertEqual(openedAfterFirst?.slotByItem, [nil, 0, 2, 3])

        let movedToFront = LauncherLayout.dragReorderPreview(sourceIndex: 2, proposedIndex: 0, count: 4)
        XCTAssertEqual(movedToFront?.gapIndex, 0)
        XCTAssertEqual(movedToFront?.slotByItem, [1, 2, nil, 3])

        let stayedPut = LauncherLayout.dragReorderPreview(sourceIndex: 1, proposedIndex: 1, count: 4)
        let justAfterSelf = LauncherLayout.dragReorderPreview(sourceIndex: 1, proposedIndex: 2, count: 4)
        XCTAssertEqual(stayedPut?.gapIndex, 1)
        XCTAssertEqual(stayedPut?.slotByItem, [0, nil, 2, 3])
        XCTAssertEqual(justAfterSelf, stayedPut)

        XCTAssertNil(LauncherLayout.dragReorderPreview(sourceIndex: nil, proposedIndex: 1, count: 4))
        XCTAssertNil(LauncherLayout.dragReorderPreview(sourceIndex: -1, proposedIndex: 0, count: 4))
        XCTAssertNil(LauncherLayout.dragReorderPreview(sourceIndex: 4, proposedIndex: 0, count: 4))
        XCTAssertNil(LauncherLayout.dragReorderPreview(sourceIndex: 0, proposedIndex: 0, count: 0))

        for preview in [movedToEnd, openedAfterFirst, movedToFront, stayedPut] {
            guard let preview else {
                XCTFail("missing reorder preview")
                continue
            }
            let occupied = preview.slotByItem.compactMap { $0 }
            XCTAssertEqual(Set(occupied).count, occupied.count)
            XCTAssertFalse(occupied.contains(preview.gapIndex))
        }
    }

    func testReorderUsesPreRemovalDropIndexSoDragRightDoesNotOvershoot() throws {
        let ids = (0..<3).map { _ in UUID() }
        let state = LayoutState(
            orderedEntries: ids.map { .app($0) },
            appKeys: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ("bundle:\($0)", $1) }.map { ($0.1, $0.0) }),
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        let droppedBeforeC = try LauncherLayout.applyDrop(
            LayoutDrop(source: .topLevel(ids[0]), destination: .topLevelIndex(2)),
            to: state
        ).get()
        XCTAssertEqual(droppedBeforeC.orderedEntries.map(\.id), [ids[1], ids[0], ids[2]])

        let droppedAtEnd = try LauncherLayout.applyDrop(
            LayoutDrop(source: .topLevel(ids[0]), destination: .topLevelIndex(3)),
            to: state
        ).get()
        XCTAssertEqual(droppedAtEnd.orderedEntries.map(\.id), [ids[1], ids[2], ids[0]])

        let droppedBeforeA = try LauncherLayout.applyDrop(
            LayoutDrop(source: .topLevel(ids[2]), destination: .topLevelIndex(0)),
            to: state
        ).get()
        XCTAssertEqual(droppedBeforeA.orderedEntries.map(\.id), [ids[2], ids[0], ids[1]])
    }

    func testDroppingBackAtSamePositionPreservesLayoutAndTimestamp() throws {
        let ids = (0..<3).map { _ in UUID() }
        let folderID = UUID()
        let timestamp = Date(timeIntervalSinceReferenceDate: 123_456)
        let state = LayoutState(
            orderedEntries: [.app(ids[0]), .folder(folderID)],
            folders: [folderID: LauncherFolder(id: folderID, name: "常用", itemIDs: [ids[1], ids[2]])],
            appKeys: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, "bundle:\($0)") }),
            updatedAt: timestamp
        )

        for index in [0, 1] {
            let unchanged = try LauncherLayout.applyDrop(
                LayoutDrop(source: .topLevel(ids[0]), destination: .topLevelIndex(index)),
                to: state
            ).get()
            XCTAssertEqual(unchanged, state)
        }
        for index in [0, 1] {
            let unchanged = try LauncherLayout.applyDrop(
                LayoutDrop(
                    source: .folderMember(folderID: folderID, itemID: ids[1]),
                    destination: .folderIndex(folderID: folderID, index: index)
                ),
                to: state
            ).get()
            XCTAssertEqual(unchanged, state)
        }
    }

    func testFolderReorderUsesTheSamePreRemovalInsertionIndex() throws {
        let folderID = UUID()
        let ids = (0..<3).map { _ in UUID() }
        let state = LayoutState(
            orderedEntries: [.folder(folderID)],
            folders: [folderID: LauncherFolder(id: folderID, name: "Folder", itemIDs: ids, createdAt: Date(timeIntervalSince1970: 0))],
            appKeys: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, "bundle:\($0)") }),
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        let moved = try LauncherLayout.applyDrop(
            LayoutDrop(
                source: .folderMember(folderID: folderID, itemID: ids[0]),
                destination: .folderIndex(folderID: folderID, index: 2)
            ),
            to: state
        ).get()

        XCTAssertEqual(moved.folders[folderID]?.itemIDs, [ids[1], ids[0], ids[2]])
    }

    func testDropOnAppCreatesFolderAndDropOnFolderAddsApp() throws {
        let alpha = UUID()
        let beta = UUID()
        let gamma = UUID()
        var state = LayoutState(
            orderedEntries: [.app(alpha), .app(beta), .app(gamma)],
            appKeys: [alpha: "bundle:alpha", beta: "bundle:beta", gamma: "bundle:gamma"],
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        state = try LauncherLayout.applyDrop(
            LayoutDrop(source: .topLevel(alpha), destination: .merge(.topLevel(beta))),
            to: state
        ).get()

        XCTAssertEqual(state.orderedEntries.count, 2)
        guard case .folder(let folderID) = state.orderedEntries[0] else {
            return XCTFail("Expected a folder at the target's slot")
        }
        XCTAssertEqual(state.folders[folderID]?.name, "新建文件夹")
        XCTAssertEqual(state.folders[folderID]?.itemIDs, [beta, alpha])
        XCTAssertEqual(state.orderedEntries[1], .app(gamma))

        state = try LauncherLayout.applyDrop(
            LayoutDrop(source: .topLevel(gamma), destination: .merge(.topLevel(folderID))),
            to: state
        ).get()
        XCTAssertEqual(state.orderedEntries, [.folder(folderID)])
        XCTAssertEqual(state.folders[folderID]?.itemIDs, [beta, alpha, gamma])

        state = LauncherLayout.renameFolder(folderID, to: "  工具  ", in: state)
        XCTAssertEqual(state.folders[folderID]?.name, "工具")
        state = LauncherLayout.renameFolder(folderID, to: "   ", in: state)
        XCTAssertEqual(state.folders[folderID]?.name, "工具")
    }

    func testDropUsesLocalizedFolderNameProvidedByUI() throws {
        let first = UUID()
        let second = UUID()
        let state = LayoutState(
            orderedEntries: [.app(first), .app(second)],
            appKeys: [first: "bundle:first", second: "bundle:second"],
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let result = try LauncherLayout.applyDrop(
            LayoutDrop(source: .topLevel(first), destination: .merge(.topLevel(second))),
            to: state,
            newFolderName: "New Folder"
        ).get()
        guard case .folder(let folderID) = result.orderedEntries.first else {
            return XCTFail("Expected merged folder")
        }
        XCTAssertEqual(result.folders[folderID]?.name, "New Folder")
    }

    func testDragOutReturnsAppToTopLevelAndDissolvesSingleMemberFolder() throws {
        let folderID = UUID()
        let kept = UUID()
        let dragged = UUID()
        let neighbor = UUID()
        let state = LayoutState(
            orderedEntries: [.folder(folderID), .app(neighbor)],
            folders: [folderID: LauncherFolder(id: folderID, name: "Folder", itemIDs: [kept, dragged], createdAt: Date(timeIntervalSince1970: 0))],
            appKeys: [kept: "bundle:kept", dragged: "bundle:dragged", neighbor: "bundle:neighbor"],
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        let moved = try LauncherLayout.applyDrop(
            LayoutDrop(source: .folderMember(folderID: folderID, itemID: dragged), destination: .topLevelIndex(2)),
            to: state
        ).get()

        XCTAssertNil(moved.folders[folderID])
        XCTAssertEqual(moved.orderedEntries, [.app(kept), .app(neighbor), .app(dragged)])

        let beside = LauncherLayout.topLevelIndexAfterFolder(folderID, in: state)
        XCTAssertEqual(beside, 1)
        let keptTogether = try LauncherLayout.applyDrop(
            LayoutDrop(source: .folderMember(folderID: folderID, itemID: dragged), destination: .topLevelIndex(beside)),
            to: state
        ).get()
        XCTAssertEqual(keptTogether.orderedEntries, [.app(kept), .app(dragged), .app(neighbor)])
        XCTAssertEqual(LauncherLayout.topLevelIndexAfterFolder(UUID(), in: state), state.orderedEntries.count)
    }

    func testEveryAcceptedDropKeepsAppsPlacedExactlyOnce() {
        let apps = (0..<6).map { _ in UUID() }
        let folders = (0..<2).map { _ in UUID() }
        let state = LayoutState(
            orderedEntries: [.folder(folders[0]), .app(apps[4]), .folder(folders[1]), .app(apps[5])],
            folders: [
                folders[0]: LauncherFolder(id: folders[0], name: "A", itemIDs: Array(apps[0...1])),
                folders[1]: LauncherFolder(id: folders[1], name: "B", itemIDs: Array(apps[2...3]))
            ],
            appKeys: Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($1, "bundle:\($0)") })
        )
        let sources: [LayoutItemRef] = [
            .topLevel(folders[0]), .topLevel(apps[4]), .topLevel(folders[1]), .topLevel(apps[5]),
            .folderMember(folderID: folders[0], itemID: apps[0]),
            .folderMember(folderID: folders[0], itemID: apps[1]),
            .folderMember(folderID: folders[1], itemID: apps[2]),
            .folderMember(folderID: folders[1], itemID: apps[3])
        ]
        let destinations: [LayoutDestination] =
            (0...4).map(LayoutDestination.topLevelIndex)
            + state.orderedEntries.map { .merge(.topLevel($0.id)) }
            + folders.flatMap { folderID in
                (0...3).map { .folderIndex(folderID: folderID, index: $0) }
            }

        var accepted = 0
        for source in sources {
            for destination in destinations {
                guard case .success(let moved) = LauncherLayout.applyDrop(
                    LayoutDrop(source: source, destination: destination), to: state
                ) else { continue }
                accepted += 1
                let placed = moved.orderedEntries.flatMap { entry -> [UUID] in
                    switch entry {
                    case .app(let id): [id]
                    case .folder(let id): moved.folders[id]?.itemIDs ?? []
                    }
                }
                XCTAssertEqual(placed.count, apps.count, "\(source) → \(destination)")
                XCTAssertEqual(Set(placed), Set(apps), "\(source) → \(destination)")
                XCTAssertEqual(moved.appKeys, state.appKeys, "\(source) → \(destination)")
                XCTAssertEqual(
                    Set(moved.folders.keys),
                    Set(moved.orderedEntries.compactMap { entry -> UUID? in
                        if case .folder(let id) = entry { return id }
                        return nil
                    }),
                    "\(source) → \(destination)"
                )
                XCTAssertTrue(moved.folders.values.allSatisfy { $0.itemIDs.count >= 2 })
            }
        }
        XCTAssertGreaterThan(accepted, 20)
    }

    func testDeterministicDropSequencesPreserveLayoutInvariants() {
        let appIDs = (0..<12).map { _ in UUID() }
        let folderIDs = (0..<3).map { _ in UUID() }
        var state = LayoutState(
            orderedEntries: folderIDs.map(LauncherEntry.folder) + appIDs[6...].map(LauncherEntry.app),
            folders: Dictionary(uniqueKeysWithValues: folderIDs.enumerated().map { index, folderID in
                (folderID, LauncherFolder(
                    id: folderID,
                    name: "Folder \(index)",
                    itemIDs: Array(appIDs[(index * 2)..<(index * 2 + 2)])
                ))
            }),
            appKeys: Dictionary(uniqueKeysWithValues: appIDs.enumerated().map { ($1, "bundle:\($0)") })
        )
        let originalAppKeys = state.appKeys
        var seed: UInt64 = 0x4c61756e63684963
        var acceptedDrops = 0
        var rejectedDrops = 0

        func nextIndex(_ count: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed % UInt64(count))
        }

        for step in 0..<300 {
            var sources: [LayoutItemRef] = []
            var destinations = (0...state.orderedEntries.count).map(LayoutDestination.topLevelIndex)
            destinations += state.orderedEntries.map { .merge(.topLevel($0.id)) }

            for entry in state.orderedEntries {
                sources.append(.topLevel(entry.id))
                guard case .folder(let folderID) = entry,
                      let folder = state.folders[folderID] else { continue }
                sources += folder.itemIDs.map { .folderMember(folderID: folderID, itemID: $0) }
                destinations += (0...folder.itemIDs.count).map {
                    .folderIndex(folderID: folderID, index: $0)
                }
                destinations += folder.itemIDs.map {
                    .merge(.folderMember(folderID: folderID, itemID: $0))
                }
            }

            guard !sources.isEmpty, !destinations.isEmpty else {
                XCTFail("A valid layout should always have drag sources and destinations")
                return
            }
            let drop = LayoutDrop(
                source: sources[nextIndex(sources.count)],
                destination: destinations[nextIndex(destinations.count)]
            )
            guard case .success(let updated) = LauncherLayout.applyDrop(drop, to: state) else {
                rejectedDrops += 1
                continue
            }

            state = updated
            acceptedDrops += 1
            let placedApps = state.orderedEntries.flatMap { entry -> [UUID] in
                switch entry {
                case .app(let id): [id]
                case .folder(let id): state.folders[id]?.itemIDs ?? []
                }
            }
            let folderEntryIDs = Set(state.orderedEntries.compactMap { entry -> UUID? in
                if case .folder(let id) = entry { return id }
                return nil
            })
            let folderMemberIDs = state.folders.values.flatMap(\.itemIDs)

            XCTAssertEqual(placedApps.count, appIDs.count, "step \(step)")
            XCTAssertEqual(Set(placedApps), Set(appIDs), "step \(step)")
            XCTAssertEqual(Set(state.folders.keys), folderEntryIDs, "step \(step)")
            XCTAssertEqual(Set(folderMemberIDs).count, folderMemberIDs.count, "step \(step)")
            XCTAssertTrue(Set(folderMemberIDs).isDisjoint(with: folderEntryIDs), "step \(step)")
            XCTAssertTrue(state.folders.values.allSatisfy {
                $0.itemIDs.count >= 2
            }, "step \(step)")
            XCTAssertEqual(state.appKeys, originalAppKeys, "step \(step)")
        }

        XCTAssertGreaterThan(acceptedDrops, 150)
        XCTAssertGreaterThan(rejectedDrops, 0)
    }

    func testNestedFolderDropsAreRejectedAndFoldersCanExceedTwentyFiveMembers() {
        let folderA = UUID()
        let folderB = UUID()
        let memberA = UUID()
        let appID = UUID()
        let members = (0..<25).map { _ in UUID() }
        let extra = UUID()
        let fullFolder = UUID()
        let state = LayoutState(
            orderedEntries: [.folder(folderA), .folder(folderB), .app(appID), .folder(fullFolder), .app(extra)],
            folders: [
                folderA: LauncherFolder(id: folderA, name: "A", itemIDs: [memberA], createdAt: Date(timeIntervalSince1970: 0)),
                folderB: LauncherFolder(id: folderB, name: "B", itemIDs: [UUID()], createdAt: Date(timeIntervalSince1970: 0)),
                fullFolder: LauncherFolder(id: fullFolder, name: "Full", itemIDs: members, createdAt: Date(timeIntervalSince1970: 0))
            ],
            appKeys: [appID: "bundle:app", extra: "bundle:extra"],
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(
            LauncherLayout.applyDrop(LayoutDrop(source: .topLevel(folderA), destination: .merge(.topLevel(folderB))), to: state),
            .failure(.nestedFolder)
        )
        XCTAssertEqual(
            LauncherLayout.applyDrop(LayoutDrop(source: .topLevel(folderA), destination: .merge(.topLevel(appID))), to: state),
            .failure(.nestedFolder)
        )
        XCTAssertEqual(
            LauncherLayout.applyDrop(
                LayoutDrop(source: .topLevel(extra), destination: .merge(.folderMember(folderID: folderA, itemID: memberA))),
                to: state
            ),
            .failure(.nestedFolder)
        )
        guard case .success(let expanded) = LauncherLayout.applyDrop(
            LayoutDrop(source: .topLevel(extra), destination: .merge(.topLevel(fullFolder))), to: state
        ) else { return XCTFail("A 25-member folder should accept another app") }
        XCTAssertEqual(expanded.folders[fullFolder]?.itemIDs, members + [extra])
    }

    func testSearchMatchesAppsInsideFolders() {
        let cafeID = UUID()
        let calendarID = UUID()
        let folderID = UUID()
        let cafe = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Café.app"),
            bundleIdentifier: "com.example.cafe",
            displayName: "Café",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let calendar = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Calendar.app"),
            bundleIdentifier: "com.apple.iCal",
            displayName: "Calendar",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let state = LayoutState(
            orderedEntries: [.folder(folderID), .app(calendarID)],
            folders: [folderID: LauncherFolder(id: folderID, name: "Folder", itemIDs: [cafeID], createdAt: Date(timeIntervalSince1970: 0))],
            appKeys: [cafeID: cafe.deduplicationKey, calendarID: calendar.deduplicationKey],
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        let searchable = LauncherLayout.searchableApps(in: state, catalog: [cafe, calendar])
        XCTAssertEqual(AppSearch.filter(searchable, query: "CAFE"), [cafe])
        XCTAssertEqual(AppSearch.filter(searchable, query: "ical"), [calendar])
    }

    func testSearchHitsMatchFolderNamesWithTheSameRanks() {
        let helperID = UUID()
        let shopID = UUID()
        let calendarID = UUID()
        let shopFolderID = UUID()
        let photoFolderID = UUID()
        let helper = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/PhotoShopHelper.app"),
            bundleIdentifier: "com.example.photoshophelper",
            displayName: "Photo Shop Helper",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let shop = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Shop.app"),
            bundleIdentifier: "com.example.shop",
            displayName: "Shop",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let calendar = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Calendar.app"),
            bundleIdentifier: "com.example.calendar",
            displayName: "Calendar",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let state = LayoutState(
            orderedEntries: [.folder(shopFolderID), .app(helperID), .folder(photoFolderID), .app(shopID), .app(calendarID)],
            folders: [
                shopFolderID: LauncherFolder(id: shopFolderID, name: "Shop", itemIDs: [], createdAt: Date(timeIntervalSince1970: 0)),
                photoFolderID: LauncherFolder(id: photoFolderID, name: "Photo Shop", itemIDs: [calendarID], createdAt: Date(timeIntervalSince1970: 0))
            ],
            appKeys: [
                helperID: helper.deduplicationKey,
                shopID: shop.deduplicationKey,
                calendarID: calendar.deduplicationKey
            ],
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let catalog = [helper, shop, calendar]
        let hits = LauncherLayout.searchHits(in: state, catalog: catalog)
        let index = AppSearchIndex(candidates: catalog)
        let shopHits = index.filter(hits, query: "shop")
        XCTAssertEqual(shopHits, [
            .folder(shopFolderID, "Shop"),
            .app(shop),
            .app(helper),
            .folder(photoFolderID, "Photo Shop")
        ])
        XCTAssertEqual(index.filter(hits, query: "photoshop"), [
            .folder(photoFolderID, "Photo Shop"),
            .app(helper)
        ])
        XCTAssertEqual(index.filter(hits, query: "photo shop"), [
            .folder(photoFolderID, "Photo Shop"),
            .app(helper)
        ])
        XCTAssertEqual(index.filter(hits, query: " "), hits)
        XCTAssertEqual(index.filter(hits, query: "tools"), [])
        XCTAssertEqual(AppSearch.filter([helper, shop], query: "shop"), [shop, helper])
    }

    func testSearchableAppsKeepsFirstCandidateForDuplicateIdentity() {
        let firstID = UUID()
        let duplicateID = UUID()
        let first = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/First.app"),
            bundleIdentifier: "com.example.duplicate",
            displayName: "First",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let duplicate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Second.app"),
            bundleIdentifier: "com.example.duplicate",
            displayName: "Second",
            sourcePriority: 1,
            discoveredAt: Date(timeIntervalSince1970: 1)
        )
        let state = LayoutState(
            orderedEntries: [.app(firstID), .app(duplicateID)],
            appKeys: [firstID: first.deduplicationKey, duplicateID: duplicate.deduplicationKey],
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(AppCandidate.firstByDeduplicationKey([first, duplicate]), [first.deduplicationKey: first])
        XCTAssertEqual(LauncherLayout.searchableApps(in: state, catalog: [first, duplicate]), [first])
    }

    func testAliasesParticipateInSearchAndRoundTripThroughLayout() {
        let candidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Terminal.app"),
            bundleIdentifier: "com.apple.Terminal",
            displayName: "Terminal",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let id = UUID()
        let initial = LayoutState(
            orderedEntries: [.app(id)],
            appKeys: [id: candidate.deduplicationKey],
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let aliased = LauncherLayout.setAlias("  命令行  ", forApplicationKey: candidate.deduplicationKey, in: initial)

        XCTAssertEqual(aliased.appAliases[candidate.deduplicationKey], "命令行")
        XCTAssertEqual(
            AppSearch.filter([candidate], query: "命令", aliases: aliased.appAliases),
            [candidate]
        )
        XCTAssertNil(
            LauncherLayout.setAlias("   ", forApplicationKey: candidate.deduplicationKey, in: aliased)
                .appAliases[candidate.deduplicationKey]
        )
    }

    func testLegacyLayoutWithoutAliasesDecodesWithAnEmptyAliasDictionary() throws {
        let original = LayoutState(
            appKeys: [UUID(): "bundle:com.apple.Terminal"],
            hiddenAppKeys: ["bundle:com.apple.Calculator"],
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let encoded = try JSONEncoder().encode(original)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "appAliases")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoded = try JSONDecoder().decode(LayoutState.self, from: legacyData)

        XCTAssertEqual(decoded.appAliases, [:])
        XCTAssertEqual(decoded.appKeys, original.appKeys)
        XCTAssertEqual(decoded.hiddenAppKeys, original.hiddenAppKeys)
    }

    func testHideApplicationDissolvesFolderAndRestoreReconcilesCandidate() throws {
        let first = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/First.app"),
            bundleIdentifier: "com.example.first",
            displayName: "First",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let second = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Second.app"),
            bundleIdentifier: "com.example.second",
            displayName: "Second",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let firstID = UUID()
        let secondID = UUID()
        let folderID = UUID()
        let initial = LayoutState(
            orderedEntries: [.folder(folderID)],
            folders: [folderID: LauncherFolder(id: folderID, name: "Folder", itemIDs: [firstID, secondID])],
            appKeys: [firstID: first.deduplicationKey, secondID: second.deduplicationKey],
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        let hidden = LauncherLayout.hideApplication(withKey: first.deduplicationKey, in: initial)
        XCTAssertEqual(hidden.orderedEntries, [.app(secondID)])
        XCTAssertNil(hidden.folders[folderID])
        XCTAssertNil(hidden.appKeys[firstID])
        XCTAssertTrue(hidden.hiddenAppKeys.contains(first.deduplicationKey))

        let restored = LauncherLayout.reconcile(
            candidates: [first, second],
            into: LauncherLayout.restoreApplication(withKey: first.deduplicationKey, in: hidden)
        )
        XCTAssertFalse(restored.hiddenAppKeys.contains(first.deduplicationKey))
        XCTAssertEqual(restored.orderedEntries.count, 2)
        XCTAssertTrue(restored.appKeys.values.contains(first.deduplicationKey))
        XCTAssertTrue(restored.appKeys.values.contains(second.deduplicationKey))
    }

    func testLayoutStoreRoundTripsFoldersAndLeavesUnknownSchemaFileUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layout-v1.json")
        let store = JSONLayoutStore(fileURL: url)
        let folderID = UUID()
        let appA = UUID()
        let appB = UUID()
        let original = LayoutState(
            orderedEntries: [.folder(folderID)],
            folders: [folderID: LauncherFolder(id: folderID, name: "Utils", itemIDs: [appA, appB], createdAt: Date(timeIntervalSince1970: 1))],
            appKeys: [appA: "bundle:a", appB: "bundle:b"],
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        try await store.save(original)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, original)

        let onDisk = try Data(contentsOf: url)
        let text = try XCTUnwrap(String(data: onDisk, encoding: .utf8))
        try Data(text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99").utf8).write(to: url)
        let mutated = try Data(contentsOf: url)
        do {
            _ = try await store.load()
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? LayoutStoreIssue, .unsupportedSchema(99))
        }
        XCTAssertEqual(try Data(contentsOf: url), mutated)
    }

    func testReconcileKeepsIdentitiesAndDropsMissingApps() {
        let first = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/First.app"),
            bundleIdentifier: "com.example.first",
            displayName: "First",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let second = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Second.app"),
            bundleIdentifier: "com.example.second",
            displayName: "Second",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        var state = LauncherLayout.reconcile(candidates: [first], into: LayoutState(updatedAt: Date(timeIntervalSince1970: 0)))
        let retainedID = state.orderedEntries[0].id
        state = LauncherLayout.reconcile(candidates: [first, second], into: state)
        XCTAssertEqual(state.orderedEntries[0].id, retainedID)
        XCTAssertEqual(state.orderedEntries.count, 2)
        state = LauncherLayout.reconcile(candidates: [second], into: state)
        XCTAssertEqual(state.orderedEntries.count, 1)
        XCTAssertEqual(state.appKeys[state.orderedEntries[0].id], second.deduplicationKey)
    }

    func testReconcileAppendsNewlyInstalledAppAtTheEnd() {
        let existing = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Old.app"),
            bundleIdentifier: "com.example.old",
            displayName: "Old",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let installed = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/New.app"),
            bundleIdentifier: "com.example.new",
            displayName: "New",
            sourcePriority: 0,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        var state = LauncherLayout.reconcile(candidates: [existing], into: LayoutState(updatedAt: Date(timeIntervalSince1970: 0)))
        let keptID = state.orderedEntries[0].id
        state = LauncherLayout.reconcile(candidates: [existing, installed], into: state)
        XCTAssertEqual(state.orderedEntries.count, 2)
        XCTAssertEqual(state.orderedEntries[0].id, keptID)
        XCTAssertEqual(state.appKeys[state.orderedEntries[1].id], installed.deduplicationKey)
    }

    func testReconcileRestoresLiveAppWithOrphanedIdentity() {
        let existingID = UUID()
        let orphanID = UUID()
        let existing = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Existing.app"),
            bundleIdentifier: "com.example.existing",
            displayName: "Existing",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        let orphan = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Orphan.app"),
            bundleIdentifier: "com.example.orphan",
            displayName: "Orphan",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        let stored = LayoutState(
            orderedEntries: [.app(existingID)],
            appKeys: [existingID: existing.deduplicationKey, orphanID: orphan.deduplicationKey],
            updatedAt: .distantPast
        )

        let restored = LauncherLayout.reconcile(candidates: [existing, orphan], into: stored)
        XCTAssertEqual(restored.orderedEntries, [.app(existingID), .app(orphanID)])
        XCTAssertEqual(
            LauncherLayout.searchableApps(in: restored, catalog: [existing, orphan]).map(\.deduplicationKey),
            [existing.deduplicationKey, orphan.deduplicationKey]
        )
    }

    func testReconcileRestoresFolderMissingFromTopLevel() {
        let existingID = UUID()
        let folderID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let candidates = ["Existing", "First", "Second"].map { name in
            AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                bundleIdentifier: "com.example.\(name.lowercased())",
                displayName: name,
                sourcePriority: 0,
                discoveredAt: .distantPast
            )
        }
        let stored = LayoutState(
            orderedEntries: [.app(existingID)],
            folders: [folderID: LauncherFolder(id: folderID, name: "Tools", itemIDs: [firstID, secondID])],
            appKeys: [
                existingID: candidates[0].deduplicationKey,
                firstID: candidates[1].deduplicationKey,
                secondID: candidates[2].deduplicationKey
            ],
            updatedAt: .distantPast
        )

        let restored = LauncherLayout.reconcile(candidates: candidates, into: stored)
        XCTAssertEqual(restored.orderedEntries, [.app(existingID), .folder(folderID)])
        XCTAssertEqual(restored.folders[folderID]?.itemIDs, [firstID, secondID])
        XCTAssertEqual(
            LauncherLayout.searchableApps(in: restored, catalog: candidates).map(\.deduplicationKey),
            candidates.map(\.deduplicationKey)
        )
    }

    func testReconcileDropsFolderMemberWithoutAppIdentity() {
        let folderID = UUID()
        let firstID = UUID()
        let staleID = UUID()
        let secondID = UUID()
        let candidates = ["First", "Second"].map { name in
            AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                bundleIdentifier: "com.example.\(name.lowercased())",
                displayName: name,
                sourcePriority: 0,
                discoveredAt: .distantPast
            )
        }
        let stored = LayoutState(
            orderedEntries: [.folder(folderID)],
            folders: [folderID: LauncherFolder(id: folderID, name: "Tools", itemIDs: [firstID, staleID, secondID])],
            appKeys: [
                firstID: candidates[0].deduplicationKey,
                secondID: candidates[1].deduplicationKey
            ],
            updatedAt: .distantPast
        )

        let restored = LauncherLayout.reconcile(candidates: candidates, into: stored)
        XCTAssertEqual(restored.orderedEntries, [.folder(folderID)])
        XCTAssertEqual(restored.folders[folderID]?.itemIDs, [firstID, secondID])
        XCTAssertEqual(
            LauncherLayout.searchableApps(in: restored, catalog: candidates).map(\.deduplicationKey),
            candidates.map(\.deduplicationKey)
        )
    }

    func testReconcileRepairsFolderIDCollidingWithApplicationID() {
        let collisionID = UUID()
        let firstMemberID = UUID()
        let secondMemberID = UUID()
        let candidates = ["Standalone", "First", "Second"].map { name in
            AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                bundleIdentifier: "com.example.\(name.lowercased())",
                displayName: name,
                sourcePriority: 0,
                discoveredAt: .distantPast
            )
        }
        let stored = LayoutState(
            orderedEntries: [.app(collisionID), .folder(collisionID)],
            folders: [collisionID: LauncherFolder(
                id: collisionID, name: "Tools", itemIDs: [firstMemberID, secondMemberID]
            )],
            appKeys: [
                collisionID: candidates[0].deduplicationKey,
                firstMemberID: candidates[1].deduplicationKey,
                secondMemberID: candidates[2].deduplicationKey
            ],
            updatedAt: .distantPast
        )

        let restored = LauncherLayout.reconcile(candidates: candidates, into: stored)

        XCTAssertEqual(restored.orderedEntries.count, 2)
        XCTAssertEqual(restored.orderedEntries.first, .app(collisionID))
        guard case .folder(let repairedFolderID)? = restored.orderedEntries.last else {
            return XCTFail("Expected the colliding folder to be preserved")
        }
        XCTAssertNotEqual(repairedFolderID, collisionID)
        XCTAssertEqual(Set(restored.orderedEntries.map(\.id)).count, restored.orderedEntries.count)
        XCTAssertEqual(restored.folders[repairedFolderID]?.name, "Tools")
        XCTAssertEqual(restored.folders[repairedFolderID]?.itemIDs, [firstMemberID, secondMemberID])
        XCTAssertEqual(restored.appKeys[collisionID], candidates[0].deduplicationKey)
    }

    func testReconcileRepairsFolderRecordIdentityMismatch() {
        let folderID = UUID()
        let mismatchedID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let createdAt = Date(timeIntervalSince1970: 123)
        let candidates = ["First", "Second"].map { name in
            AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                bundleIdentifier: "com.example.\(name.lowercased())",
                displayName: name,
                sourcePriority: 0,
                discoveredAt: .distantPast
            )
        }
        let stored = LayoutState(
            orderedEntries: [.folder(folderID)],
            folders: [folderID: LauncherFolder(
                id: mismatchedID, name: "Tools", itemIDs: [firstID, secondID], createdAt: createdAt
            )],
            appKeys: [
                firstID: candidates[0].deduplicationKey,
                secondID: candidates[1].deduplicationKey
            ],
            updatedAt: .distantPast
        )

        let restored = LauncherLayout.reconcile(candidates: candidates, into: stored)
        XCTAssertEqual(restored.orderedEntries, [.folder(folderID)])
        XCTAssertEqual(restored.folders[folderID]?.id, folderID)
        XCTAssertEqual(restored.folders[folderID]?.name, "Tools")
        XCTAssertEqual(restored.folders[folderID]?.itemIDs, [firstID, secondID])
        XCTAssertEqual(restored.folders[folderID]?.createdAt, createdAt)
    }

    func testReconcileRemovesFolderEntryWithoutFolderRecord() {
        let existingID = UUID()
        let missingFolderID = UUID()
        let recoveredID = UUID()
        let existing = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Existing.app"),
            bundleIdentifier: "com.example.existing",
            displayName: "Existing",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        let recovered = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Recovered.app"),
            bundleIdentifier: "com.example.recovered",
            displayName: "Recovered",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        let stored = LayoutState(
            orderedEntries: [.app(existingID), .folder(missingFolderID)],
            appKeys: [existingID: existing.deduplicationKey, recoveredID: recovered.deduplicationKey],
            updatedAt: .distantPast
        )

        let restored = LauncherLayout.reconcile(candidates: [existing, recovered], into: stored)
        XCTAssertEqual(restored.orderedEntries, [.app(existingID), .app(recoveredID)])
        XCTAssertEqual(
            LauncherLayout.searchableApps(in: restored, catalog: [existing, recovered]).map(\.deduplicationKey),
            [existing.deduplicationKey, recovered.deduplicationKey]
        )
    }

    func testReconcileRemovesAppEntryWithoutIdentity() {
        let existingID = UUID()
        let missingAppID = UUID()
        let existing = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Existing.app"),
            bundleIdentifier: "com.example.existing",
            displayName: "Existing",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        let newApp = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/New.app"),
            bundleIdentifier: "com.example.new",
            displayName: "New",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        let stored = LayoutState(
            orderedEntries: [.app(existingID), .app(missingAppID)],
            appKeys: [existingID: existing.deduplicationKey],
            updatedAt: .distantPast
        )

        let restored = LauncherLayout.reconcile(candidates: [existing, newApp], into: stored)
        XCTAssertEqual(restored.orderedEntries.count, 2)
        XCTAssertEqual(restored.orderedEntries.first, .app(existingID))
        XCTAssertFalse(restored.orderedEntries.contains(.app(missingAppID)))
        XCTAssertEqual(
            LauncherLayout.searchableApps(in: restored, catalog: [existing, newApp]).map(\.deduplicationKey),
            [existing.deduplicationKey, newApp.deduplicationKey]
        )
    }

    func testReconcileRemovesDuplicateTopLevelEntryWithoutMovingFirst() {
        let firstID = UUID()
        let secondID = UUID()
        let first = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/First.app"),
            bundleIdentifier: "com.example.first",
            displayName: "First",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        let second = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Second.app"),
            bundleIdentifier: "com.example.second",
            displayName: "Second",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        let stored = LayoutState(
            orderedEntries: [.app(firstID), .app(secondID), .app(firstID)],
            appKeys: [firstID: first.deduplicationKey, secondID: second.deduplicationKey],
            updatedAt: .distantPast
        )

        let restored = LauncherLayout.reconcile(candidates: [first, second], into: stored)
        XCTAssertEqual(restored.orderedEntries, [.app(firstID), .app(secondID)])
    }

    func testReconcileKeepsFirstPlacementForDuplicateAppIdentity() {
        let firstID = UUID()
        let duplicateID = UUID()
        let otherID = UUID()
        let folderID = UUID()
        let app = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/First.app"),
            bundleIdentifier: "com.example.first",
            displayName: "First",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        let other = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Other.app"),
            bundleIdentifier: "com.example.other",
            displayName: "Other",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        let keys = [firstID: app.deduplicationKey, duplicateID: app.deduplicationKey, otherID: other.deduplicationKey]
        let topLevel = LayoutState(
            orderedEntries: [.app(firstID), .app(otherID), .app(duplicateID)],
            appKeys: keys,
            updatedAt: .distantPast
        )
        let restoredTopLevel = LauncherLayout.reconcile(candidates: [app, other], into: topLevel)
        XCTAssertEqual(restoredTopLevel.orderedEntries, [.app(firstID), .app(otherID)])
        XCTAssertNil(restoredTopLevel.appKeys[duplicateID])

        let folder = LauncherFolder(id: folderID, name: "Tools", itemIDs: [duplicateID, otherID])
        let stored = LayoutState(
            orderedEntries: [.app(firstID), .folder(folderID)],
            folders: [folderID: folder],
            appKeys: keys,
            updatedAt: .distantPast
        )
        let restored = LauncherLayout.reconcile(candidates: [app, other], into: stored)
        XCTAssertEqual(restored.orderedEntries, [.app(firstID), .app(otherID)])
        XCTAssertNil(restored.folders[folderID])
        XCTAssertNil(restored.appKeys[duplicateID])
        XCTAssertEqual(
            LauncherLayout.searchableApps(in: restored, catalog: [app, other]).map(\.deduplicationKey),
            [app.deduplicationKey, other.deduplicationKey]
        )

        let folderFirst = LayoutState(
            orderedEntries: [.folder(folderID), .app(firstID)],
            folders: [folderID: folder],
            appKeys: keys,
            updatedAt: .distantPast
        )
        let restoredFolderFirst = LauncherLayout.reconcile(candidates: [app, other], into: folderFirst)
        XCTAssertEqual(restoredFolderFirst.orderedEntries, [.folder(folderID)])
        XCTAssertEqual(restoredFolderFirst.folders[folderID]?.itemIDs, [duplicateID, otherID])
        XCTAssertNil(restoredFolderFirst.appKeys[firstID])
    }

    func testReconcilePreservesFolderMembersBeyondTwentyFive() {
        let folderID = UUID()
        let memberIDs = (0..<28).map { _ in UUID() }
        let candidatesInFolderOrder = memberIDs.enumerated().map { index, _ in
            AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/Applications/Member\(index).app"),
                bundleIdentifier: "com.example.member\(index)",
                displayName: "Member \(index)",
                sourcePriority: 0,
                discoveredAt: .distantPast
            )
        }
        let candidates = Array(candidatesInFolderOrder.reversed())
        let stored = LayoutState(
            orderedEntries: [.folder(folderID)],
            folders: [folderID: LauncherFolder(id: folderID, name: "Tools", itemIDs: memberIDs)],
            appKeys: Dictionary(uniqueKeysWithValues: zip(memberIDs, candidatesInFolderOrder.map(\.deduplicationKey))),
            updatedAt: .distantPast
        )

        let restored = LauncherLayout.reconcile(candidates: candidates, into: stored)

        XCTAssertEqual(restored.folders[folderID]?.itemIDs, memberIDs)
        XCTAssertEqual(restored.orderedEntries, [.folder(folderID)])
        XCTAssertEqual(
            LauncherLayout.searchableApps(in: restored, catalog: candidates).map(\.deduplicationKey),
            candidatesInFolderOrder.map(\.deduplicationKey)
        )
    }

    func testReconcileRemovesDuplicateFolderMember() {
        let folderID = UUID()
        let memberIDs = (0..<25).map { _ in UUID() }
        let candidates = memberIDs.enumerated().map { index, _ in
            AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/Applications/Member\(index).app"),
                bundleIdentifier: "com.example.member\(index)",
                displayName: "Member \(index)",
                sourcePriority: 0,
                discoveredAt: .distantPast
            )
        }
        let stored = LayoutState(
            orderedEntries: [.folder(folderID)],
            folders: [folderID: LauncherFolder(
                id: folderID,
                name: "Tools",
                itemIDs: [memberIDs[0]] + memberIDs
            )],
            appKeys: Dictionary(uniqueKeysWithValues: zip(memberIDs, candidates.map(\.deduplicationKey))),
            updatedAt: .distantPast
        )

        let restored = LauncherLayout.reconcile(candidates: candidates, into: stored)

        XCTAssertEqual(restored.folders[folderID]?.itemIDs, memberIDs)
        XCTAssertEqual(restored.orderedEntries, [.folder(folderID)])
    }

    func testReconcileRemovesDuplicateFolderIdentity() {
        let folderID = UUID()
        let memberIDs = (0..<25).map { _ in UUID() }
        let duplicateID = UUID()
        let candidates = memberIDs.enumerated().map { index, _ in
            AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/Applications/Member\(index).app"),
                bundleIdentifier: "com.example.member\(index)",
                displayName: "Member \(index)",
                sourcePriority: 0,
                discoveredAt: .distantPast
            )
        }
        var appKeys = Dictionary(uniqueKeysWithValues: zip(memberIDs, candidates.map(\.deduplicationKey)))
        appKeys[duplicateID] = candidates[0].deduplicationKey
        let stored = LayoutState(
            orderedEntries: [.folder(folderID)],
            folders: [folderID: LauncherFolder(
                id: folderID,
                name: "Tools",
                itemIDs: [memberIDs[0], duplicateID] + Array(memberIDs.dropFirst())
            )],
            appKeys: appKeys,
            updatedAt: .distantPast
        )

        let restored = LauncherLayout.reconcile(candidates: candidates, into: stored)

        XCTAssertEqual(restored.folders[folderID]?.itemIDs, memberIDs)
        XCTAssertEqual(restored.orderedEntries, [.folder(folderID)])
        XCTAssertNil(restored.appKeys[duplicateID])
    }

    func testReconcileRemovesUnreferencedDuplicateApplicationIdentities() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let duplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let app = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Example.app"),
            bundleIdentifier: "com.example.identity",
            displayName: "Example",
            sourcePriority: 0,
            discoveredAt: .distantPast
        )
        let stored = LayoutState(
            appKeys: [firstID: app.deduplicationKey, duplicateID: app.deduplicationKey],
            updatedAt: .distantPast
        )

        let restored = LauncherLayout.reconcile(candidates: [app], into: stored)

        XCTAssertEqual(restored.orderedEntries.count, 1)
        guard case .app(let restoredID)? = restored.orderedEntries.first else {
            return XCTFail("Expected the live application to be restored at top level")
        }
        XCTAssertEqual(restored.appKeys, [restoredID: app.deduplicationKey])
    }

    func testReconcileRestoresCorruptedLayoutsToIdentityAndFolderInvariants() {
        let candidates = (0..<5).map { index in
            AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/Applications/App\(index).app"),
                bundleIdentifier: "com.example.app\(index)",
                displayName: "App \(index)",
                sourcePriority: 0,
                discoveredAt: .distantPast
            )
        }
        let candidateKeys = candidates.map(\.deduplicationKey)

        for initialSeed in 0..<1_024 {
            var seed = UInt64(initialSeed + 1)
            let next: (Int) -> Int = { upperBound in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int(seed % UInt64(upperBound))
            }
            let nextUUID: () -> UUID = {
                let parts = (0..<8).map { _ in String(format: "%04x", next(0x1_0000)) }
                let segments = [
                    "\(parts[0])\(parts[1])",
                    parts[2], parts[3], parts[4],
                    "\(parts[5])\(parts[6])\(parts[7])"
                ]
                return UUID(uuidString: segments.joined(separator: "-"))!
            }
            let appIDs = (0..<8).map { _ in nextUUID() }
            let folderIDs = [appIDs[0], nextUUID(), nextUUID()]
            let missingIDs = (0..<4).map { _ in nextUUID() }
            var appKeys: [UUID: String] = [:]
            for id in appIDs + missingIDs {
                let keyIndex = next(candidateKeys.count + 1)
                appKeys[id] = keyIndex < candidateKeys.count ? candidateKeys[keyIndex] : "bundle:removed"
            }
            let folders = Dictionary(uniqueKeysWithValues: folderIDs.map { id in
                let memberCount = next(32)
                let members = (0..<memberCount).map { _ in
                    let allIDs = appIDs + missingIDs
                    return allIDs[next(allIDs.count)]
                }
                return (id, LauncherFolder(
                    id: next(2) == 0 ? id : nextUUID(),
                    name: "Folder",
                    itemIDs: members,
                    createdAt: .distantPast
                ))
            })
            let allEntryIDs = appIDs + folderIDs + missingIDs
            let entries = (0..<next(18)).map { _ in
                let id = allEntryIDs[next(allEntryIDs.count)]
                return next(2) == 0 ? LauncherEntry.app(id) : .folder(id)
            }
            let hiddenKey = initialSeed.isMultiple(of: 3) ? candidateKeys[0] : nil
            let stored = LayoutState(
                orderedEntries: entries,
                folders: folders,
                appKeys: appKeys,
                hiddenAppKeys: hiddenKey.map { [$0] } ?? [],
                updatedAt: .distantPast
            )

            let restored = LauncherLayout.reconcile(candidates: candidates, into: stored)
            let topLevelAppIDs = restored.orderedEntries.compactMap { entry -> UUID? in
                guard case .app(let id) = entry else { return nil }
                return id
            }
            let referencedAppIDs = Set(topLevelAppIDs).union(restored.folders.values.flatMap(\.itemIDs))

            XCTAssertEqual(Set(restored.orderedEntries.map(\.id)).count, restored.orderedEntries.count, "seed \(initialSeed)")
            XCTAssertEqual(Set(restored.appKeys.keys), referencedAppIDs, "seed \(initialSeed)")
            XCTAssertEqual(Set(restored.appKeys.values).count, restored.appKeys.count, "seed \(initialSeed)")
            XCTAssertTrue(restored.orderedEntries.allSatisfy { entry in
                if case .folder(let id) = entry { return restored.folders[id] != nil }
                return restored.appKeys[entry.id] != nil
            }, "seed \(initialSeed)")
            XCTAssertTrue(restored.folders.allSatisfy { id, folder in
                id == folder.id
                    && folder.itemIDs.count >= 2
                    && Set(folder.itemIDs).count == folder.itemIDs.count
                    && folder.itemIDs.allSatisfy { restored.appKeys[$0] != nil }
            }, "seed \(initialSeed)")
            XCTAssertEqual(
                Set(LauncherLayout.searchableApps(in: restored, catalog: candidates).map(\.deduplicationKey)),
                Set(candidateKeys).subtracting(hiddenKey.map { [$0] } ?? []),
                "seed \(initialSeed)"
            )
            let repeated = LauncherLayout.reconcile(candidates: candidates, into: restored)
            XCTAssertEqual(repeated.orderedEntries, restored.orderedEntries, "seed \(initialSeed)")
            XCTAssertEqual(repeated.folders, restored.folders, "seed \(initialSeed)")
            XCTAssertEqual(repeated.appKeys, restored.appKeys, "seed \(initialSeed)")
        }
    }

    func testFreshLayoutShowsSystemAppsFirstWithoutReorderingExistingLayout() {
        let thirdParty = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Example.app"),
            bundleIdentifier: "com.example.third-party",
            displayName: "Example",
            sourcePriority: 1,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let system = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
            bundleIdentifier: "com.apple.iCal",
            displayName: "日历",
            sourcePriority: 2,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )
        let cryptex = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"),
            bundleIdentifier: "com.apple.Safari",
            displayName: "Safari",
            sourcePriority: 3,
            discoveredAt: Date(timeIntervalSince1970: 0)
        )

        let fresh = LauncherLayout.reconcile(candidates: [thirdParty, system, cryptex], into: LayoutState())
        XCTAssertEqual(fresh.orderedEntries.compactMap { fresh.appKeys[$0.id] }, [
            system.deduplicationKey,
            cryptex.deduplicationKey,
            thirdParty.deduplicationKey
        ])
        XCTAssertEqual(
            LauncherLayout.searchableApps(in: fresh, catalog: [thirdParty, system, cryptex]).map(\.deduplicationKey),
            [system.deduplicationKey, cryptex.deduplicationKey, thirdParty.deduplicationKey]
        )

        let existing = LauncherLayout.reconcile(candidates: [thirdParty], into: LayoutState())
        let refreshed = LauncherLayout.reconcile(candidates: [thirdParty, system], into: existing)
        XCTAssertEqual(refreshed.orderedEntries.compactMap { refreshed.appKeys[$0.id] }, [
            thirdParty.deduplicationKey,
            system.deduplicationKey
        ])
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch {
        errorHandler(error)
    }
}

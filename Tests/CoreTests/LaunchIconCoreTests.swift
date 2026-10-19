import Foundation
import CoreServices
import Darwin
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

    func testDeferredVisualStateOrderMatchesHistoricalRegistry() {
        XCTAssertEqual(
            LauncherLayout.deferredVisualStateOrder,
            [
                .dropHighlightClear,
                .folderLanding,
                .mergeFlight,
                .folderChrome,
                .searchChrome,
                .dissolvedGridFade,
                .launchFeedback,
                .dragLiftDrop,
                .pageDragRest,
                .contentScrollRest,
                .pageButtonHover,
                .toastFade,
                .dropLanding
            ]
        )
        XCTAssertEqual(
            Set(LauncherLayout.deferredVisualStateOrder),
            Set(LauncherLayout.DeferredVisualSlot.allCases)
        )
    }

    func testReducedMotionSnapOrderMatchesHistoricalRegistry() {
        XCTAssertEqual(
            LauncherLayout.reducedMotionSnapOrder,
            [
                .pageButtonHover,
                .folderBackdrop,
                .toastFade,
                .searchChrome,
                .dissolvedGridFade,
                .pageSlide,
                .launchFeedback,
                .folderChrome,
                .mergeFlight,
                .folderLanding,
                .launcherPresence,
                .dragLiftDrop,
                .pageDragRest,
                .contentScrollRest,
                .reloadVisibleCollections,
                .reorderSlideLand,
                .dropLanding
            ]
        )
        XCTAssertEqual(
            Set(LauncherLayout.reducedMotionSnapOrder),
            Set(LauncherLayout.ReducedMotionSnapSlot.allCases)
        )
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
        let scanner = AppCatalogScanner(fileManager: fileManager)
        // Cancel the scan task without cancelling the later cache assertions.
        let report = await Task {
            await scanner.scan(roots: [firstRoot, secondRoot])
        }.value

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

    func testCancelledCatalogSnapshotSaveKeepsPreviousSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog-v1.json")
        let store = CatalogSnapshotStore(fileURL: url)
        let candidates = ["Previous", "Replacement"].map { name in
            AppCandidate(
                canonicalURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                bundleIdentifier: "com.example.\(name.lowercased())",
                displayName: name,
                sourcePriority: 0,
                discoveredAt: .distantPast
            )
        }
        try await store.save(CatalogScanReport(candidates: [candidates[0]], skippedPaths: []))
        let original = try Data(contentsOf: url)
        let save = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.save(CatalogScanReport(candidates: [candidates[1]], skippedPaths: []))
        }
        await XCTAssertThrowsErrorAsync(try await save.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [candidates[0]])
    }

    func testCancelledCatalogSnapshotLoadDoesNotDecodeDamagedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("catalog-v1.json")
        let original = Data("not JSON".utf8)
        try original.write(to: url)
        let store = CatalogSnapshotStore(fileURL: url)
        let load = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await store.load()
        }
        await XCTAssertThrowsErrorAsync(try await load.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
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
            reducesMotion: true,
            hotCorner: .topRight
        )
        await store.save(changed)
        let restored = await store.load()
        XCTAssertEqual(restored, changed)
        XCTAssertEqual(restored.hotCorner, .topRight)
        defaults.set("unrecognized", forKey: "LaunchIcon.Preferences.shortcut")
        let fallback = await store.load()
        XCTAssertEqual(fallback.shortcut, .optionSpace)
        defaults.set("unrecognized", forKey: "LaunchIcon.Preferences.hotCorner")
        let hotFallback = await store.load()
        XCTAssertEqual(hotFallback.hotCorner, .off)
    }

    func testHotCornerGeometryAndEdgeTrigger() {
        let screen = CGRect(x: 100, y: 200, width: 800, height: 600)
        XCTAssertEqual(
            LauncherLayout.hotCorner(at: CGPoint(x: 100, y: 800), screenFrame: screen),
            .topLeft
        )
        XCTAssertEqual(
            LauncherLayout.hotCorner(at: CGPoint(x: 900, y: 800), screenFrame: screen),
            .topRight
        )
        XCTAssertEqual(
            LauncherLayout.hotCorner(at: CGPoint(x: 100, y: 200), screenFrame: screen),
            .bottomLeft
        )
        XCTAssertEqual(
            LauncherLayout.hotCorner(at: CGPoint(x: 900, y: 200), screenFrame: screen),
            .bottomRight
        )
        XCTAssertNil(LauncherLayout.hotCorner(at: CGPoint(x: 500, y: 500), screenFrame: screen))
        // Outside threshold
        XCTAssertNil(LauncherLayout.hotCorner(at: CGPoint(x: 100 + 6, y: 800), screenFrame: screen))

        XCTAssertFalse(
            LauncherLayout.shouldFireHotCorner(configured: .off, previousHit: nil, currentHit: .topLeft)
        )
        XCTAssertTrue(
            LauncherLayout.shouldFireHotCorner(
                configured: .topLeft, previousHit: nil, currentHit: .topLeft
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldFireHotCorner(
                configured: .topLeft, previousHit: .topLeft, currentHit: .topLeft
            ),
            "must edge-trigger only"
        )
        XCTAssertTrue(
            LauncherLayout.shouldFireHotCorner(
                configured: .topLeft, previousHit: .topRight, currentHit: .topLeft
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldFireHotCorner(
                configured: .topLeft, previousHit: nil, currentHit: .bottomLeft
            )
        )

        let secondary = CGRect(x: 900, y: 0, width: 400, height: 300)
        XCTAssertEqual(
            LauncherLayout.hotCorner(
                at: CGPoint(x: 1300, y: 300),
                screenFrames: [screen, secondary]
            ),
            .topRight
        )
    }


    func testHotCornerUsesAnimatedLauncherPresenceNotPagingSnaps() {
        XCTAssertTrue(LauncherLayout.shouldAnimateLauncherPresenceForHotCorner())
        XCTAssertFalse(LauncherLayout.shouldSnapPagingChromeForHotCornerTrigger())
        // Distinct from settings handoff (instant hide / no appear fade).
        XCTAssertNotEqual(
            LauncherLayout.shouldAnimateLauncherPresenceForHotCorner(),
            LauncherLayout.shouldAnimateLauncherHideForSettingsHandoff()
        )
        XCTAssertNotEqual(
            LauncherLayout.shouldAnimateLauncherPresenceForHotCorner(),
            LauncherLayout.shouldAnimateLauncherShowForSettingsHandoff()
        )
    }


    func testLauncherPresenceSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapLauncherPresenceForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapLauncherPresenceForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.launcherPresenceFadeDuration(visible: true, reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.launcherPresenceFadeDuration(visible: false, reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.launcherPresenceFadeDuration(visible: true, reducesMotion: false),
            0.22
        )
        XCTAssertEqual(
            LauncherLayout.launcherPresenceFadeDuration(visible: false, reducesMotion: false),
            0.15
        )
        // Hot corner still uses the animated show/hide entry (which snaps when reduced).
        XCTAssertTrue(LauncherLayout.shouldAnimateLauncherPresenceForHotCorner())
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
        XCTAssertEqual(report.duplicateCandidates.map(\.canonicalURL), [userRoot.appendingPathComponent("Example.app")])
        XCTAssertTrue(AppUninstallEligibility.hasOtherCopy(
            of: report.candidates[0], in: report, registeredURLs: []
        ))
        XCTAssertTrue(report.skippedPaths.isEmpty)

        let userExecutable = userRoot.appendingPathComponent("Example.app/Contents/MacOS/Example")
        try FileManager.default.createDirectory(at: userExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: userExecutable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let bothExecutable = await AppCatalogScanner().scan(roots: [userRoot, sharedRoot])
        XCTAssertEqual(bothExecutable.candidates.map(\.canonicalURL), [userRoot.appendingPathComponent("Example.app")])
        XCTAssertEqual(bothExecutable.duplicateCandidates.map(\.canonicalURL), [sharedRoot.appendingPathComponent("Example.app")])
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
        XCTAssertTrue(store.hasBackupFile)
        let backup = try await store.loadBackup()
        XCTAssertEqual(backup, first)
    }

    func testLayoutStoreExportImportRoundTripDoesNotTouchLiveFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let liveURL = directory.appendingPathComponent("layout-v1.json")
        let store = JSONLayoutStore(fileURL: liveURL)
        let live = LayoutState(orderedEntries: [.app(UUID())])
        try await store.save(live)
        let liveData = try Data(contentsOf: liveURL)
        XCTAssertFalse(store.hasBackupFile)

        let exportURL = directory.appendingPathComponent("LaunchIcon-layout-export.json")
        let exported = LayoutState(orderedEntries: [.folder(UUID()), .app(UUID())])
        try await store.export(exported, to: exportURL)
        XCTAssertEqual(try Data(contentsOf: liveURL), liveData, "export must not rewrite live primary")
        XCTAssertFalse(store.hasBackupFile, "export must not create automatic backup")

        let imported = try await store.importLayout(from: exportURL)
        XCTAssertEqual(imported, exported)
        XCTAssertEqual(try Data(contentsOf: liveURL), liveData, "importLayout must not write live primary")
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

    func testCancelledLayoutSaveLeavesPrimaryAndBackupUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layout-v1.json")
        let store = JSONLayoutStore(fileURL: url)
        try await store.save(LayoutState(orderedEntries: [.app(UUID())]))
        try await store.save(LayoutState(orderedEntries: [.app(UUID())]))
        let backupURL = await store.backupURL
        let primary = try Data(contentsOf: url)
        let backup = try Data(contentsOf: backupURL)

        let save = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.save(LayoutState(orderedEntries: [.app(UUID())]))
        }
        await XCTAssertThrowsErrorAsync(try await save.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: url), primary)
        XCTAssertEqual(try Data(contentsOf: backupURL), backup)
    }

    func testCancelledLayoutLoadDoesNotPreserveUnknownSchema() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("layout-v1.json")
        let original = Data("{\"schemaVersion\":99}".utf8)
        try original.write(to: url)
        let store = JSONLayoutStore(fileURL: url)

        let load = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await store.load()
        }
        await XCTAssertThrowsErrorAsync(try await load.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["layout-v1.json"])
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

    func testUnknownLayoutSchemaWithChangedStructureRemainsReadOnly() async throws {
        for loadFirst in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("layout-v1.json")
            let store = JSONLayoutStore(fileURL: url)
            try await store.save(LayoutState(orderedEntries: [.app(UUID())]))
            try await store.save(LayoutState(orderedEntries: [.app(UUID())]))
            let backupURL = await store.backupURL
            let backup = try Data(contentsOf: backupURL)
            // A future version need not retain today's field types or required fields.
            let future = Data(#"{"schemaVersion":99,"orderedEntries":{"pages":[]},"modified":"new-format"}"#.utf8)
            try future.write(to: url)

            if loadFirst {
                await XCTAssertThrowsErrorAsync(try await store.load()) { error in
                    XCTAssertEqual(error as? LayoutStoreIssue, .unsupportedSchema(99))
                }
            }
            await XCTAssertThrowsErrorAsync(try await store.save(LayoutState())) { error in
                XCTAssertEqual(error as? LayoutStoreIssue, .unsupportedSchema(99))
            }
            XCTAssertEqual(try Data(contentsOf: url), future)
            XCTAssertEqual(try Data(contentsOf: backupURL), backup)
        }
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

    func testWorkspaceLauncherOpenImmediatelyReturnsOpenedWithoutWaiting() throws {
        let url = URL(fileURLWithPath: "/Applications/Ready.app")
        let launcher = WorkspaceAppLauncher(immediateOpen: { _ in .opened })
        XCTAssertEqual(try launcher.openImmediately(url), .opened)
    }

    func testWorkspaceLauncherOpenImmediatelyReturnsActivated() throws {
        let url = URL(fileURLWithPath: "/Applications/Ready.app")
        let launcher = WorkspaceAppLauncher(immediateOpen: { _ in .activated })
        XCTAssertEqual(try launcher.openImmediately(url), .activated)
    }

    func testWorkspaceLauncherOpenImmediatelyPropagatesRejection() {
        let url = URL(fileURLWithPath: "/Applications/Missing.app")
        let launcher = WorkspaceAppLauncher(immediateOpen: { thrownURL in
            throw WorkspaceLaunchError.requestRejected(thrownURL)
        })
        XCTAssertThrowsError(try launcher.openImmediately(url)) { error in
            XCTAssertEqual(error as? WorkspaceLaunchError, .requestRejected(url))
        }
    }

    func testWorkspaceLauncherAsyncLaunchUsesImmediateOpen() async throws {
        let url = URL(fileURLWithPath: "/Applications/Ready.app")
        final class Flag: @unchecked Sendable { var value = false }
        let opened = Flag()
        let launcher = WorkspaceAppLauncher(immediateOpen: { _ in
            opened.value = true
            return .opened
        })
        try await launcher.launch(url)
        XCTAssertTrue(opened.value)
    }

    func testWorkspaceLauncherRejectsMissingApplicationWithoutHanging() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")

        XCTAssertThrowsError(try WorkspaceAppLauncher().openImmediately(missingURL)) { error in
            XCTAssertEqual(error as? WorkspaceLaunchError, .requestRejected(missingURL))
        }
    }

    func testWorkspaceLauncherHandsUnclassifiedBundleToOpenWithoutBundleAPIs() throws {
        // No Contents/Info.plist: do not guess, and do not call Bundle.
        // Spawn `/usr/bin/open` and return. A readable Mac Info.plist that
        // already shows a missing executable is rejected before spawn.
        let applicationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-Unclassified-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: applicationURL) }
        XCTAssertEqual(
            WorkspaceAppLauncher.openBundleExecutable(at: applicationURL),
            .notMacInfoPlist
        )
        XCTAssertEqual(try WorkspaceAppLauncher().openImmediately(applicationURL), .opened)
    }

    func testWorkspaceLauncherOpenImmediatelyReturnsWithoutWaitingForOpenExit() throws {
        let url = URL(fileURLWithPath: "/Applications/Ready.app")
        let started = Date()
        final class Flag: @unchecked Sendable { var waited = false }
        let flag = Flag()
        let launcher = WorkspaceAppLauncher(immediateOpen: { _ in
            // Mimic fire-and-forget: return before any simulated wait.
            flag.waited = false
            return .opened
        })
        XCTAssertEqual(try launcher.openImmediately(url), .opened)
        XCTAssertFalse(flag.waited)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
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

    func testPageTurnsKeepAdjacentHostsFromOverlapping() {
        XCTAssertEqual(LauncherLayout.pageTurnDistanceFraction, 0.18, accuracy: 0.001)
        for discrete in [false, true] {
            let travel = LauncherLayout.pageSlideDistance(pageWidth: 1000, discrete: discrete)
            let outgoing = CGRect(x: -travel / 2, y: 0, width: 1000, height: 600)
            let incoming = CGRect(x: travel / 2, y: 0, width: 1000, height: 600)
            XCTAssertLessThanOrEqual(outgoing.maxX, incoming.minX)
        }
        XCTAssertEqual(LauncherLayout.pageSlideDistance(pageWidth: 0, discrete: true), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.pageSlideDistance(pageWidth: -40, discrete: true), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.pageSlideDistance(pageWidth: .nan, discrete: true), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.pageSlideDistance(pageWidth: .infinity, discrete: false), 0, accuracy: 0.001)

        let fullDrag = LauncherLayout.pageDragFollowOffsets(distance: -1000, pageWidth: 1000, direction: 1)
        XCTAssertEqual(fullDrag.activeX, -1000, accuracy: 0.001)
        XCTAssertEqual(fullDrag.stagingX, 0, accuracy: 0.001)
        let untouched = LauncherLayout.pageDragFollowOffsets(distance: 0, pageWidth: 1000, direction: 1)
        XCTAssertEqual(untouched.activeX, 0, accuracy: 0.001)
        XCTAssertEqual(untouched.stagingX, 1000, accuracy: 0.001)
        let halfway = LauncherLayout.pageDragFollowOffsets(distance: -500, pageWidth: 800, direction: 1)
        XCTAssertEqual(halfway.activeX, -500, accuracy: 0.001)
        XCTAssertEqual(halfway.stagingX, 300, accuracy: 0.001)
        XCTAssertFalse(LauncherLayout.shouldTurnPage(distance: 179, velocity: 0, pageWidth: 1000))
        XCTAssertTrue(LauncherLayout.shouldTurnPage(distance: 180, velocity: 0, pageWidth: 1000))
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

    func testPageTurnCurveEasesOutAheadOfTheClock() {
        XCTAssertEqual(LauncherLayout.pageTurnCurveProgress(0), 0, accuracy: 0.000_001)
        XCTAssertEqual(LauncherLayout.pageTurnCurveProgress(1), 1, accuracy: 0.000_001)
        XCTAssertEqual(LauncherLayout.pageTurnCurveProgress(-0.2), 0, accuracy: 0.000_001)
        XCTAssertEqual(LauncherLayout.pageTurnCurveProgress(1.4), 1, accuracy: 0.000_001)
        // The previous curve jumped almost 40% in its first 28 ms and had
        // already travelled 95% halfway through a 280 ms page turn.
        XCTAssertLessThan(LauncherLayout.pageTurnCurveProgress(0.1), 0.28)
        let midpoint = LauncherLayout.pageTurnCurveProgress(0.5)
        XCTAssertGreaterThan(midpoint, 0.75)
        XCTAssertLessThan(midpoint, 0.87)
        XCTAssertGreaterThan(LauncherLayout.pageTurnCurveProgress(0.75), 0.95)
        var previous: CGFloat = -0.01
        for step in 0...20 {
            let progress = LauncherLayout.pageTurnCurveProgress(CGFloat(step) / 20)
            XCTAssertGreaterThan(progress, previous)
            XCTAssertLessThanOrEqual(progress, 1)
            previous = progress
        }
    }

    func testPageSlideCompletionDoesNotWaitAfterFingerReachesDestination() {
        XCTAssertEqual(LauncherLayout.pageSlideCompletionDuration(remainingFraction: 0), 0)
        XCTAssertEqual(
            LauncherLayout.pageSlideCompletionDuration(remainingFraction: 1),
            LauncherLayout.pageAnimationDuration,
            accuracy: 0.001
        )
        let shortTail = LauncherLayout.pageSlideCompletionDuration(remainingFraction: 0.01)
        XCTAssertLessThanOrEqual(shortTail, 0.07, "1% travel must not occupy a 120 ms dead tail")
        XCTAssertGreaterThan(shortTail, 0)
        XCTAssertGreaterThan(
            LauncherLayout.pageSlideCompletionDuration(remainingFraction: 0.25),
            shortTail
        )
    }

    func testPageDotWeightUsesThePageClockFromTheFirstFrame() {
        XCTAssertEqual(
            LauncherLayout.pageDotWeightProgress(elapsed: 0, duration: 0.28),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LauncherLayout.pageDotWeightProgress(elapsed: -0.02, duration: 0.28),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LauncherLayout.pageDotWeightProgress(elapsed: 0.28, duration: 0.28),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LauncherLayout.pageDotWeightProgress(elapsed: 0.4, duration: 0.28),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LauncherLayout.pageDotWeightProgress(elapsed: 0.05, duration: 0),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LauncherLayout.pageDotWeightProgress(elapsed: .nan, duration: 0.28),
            0,
            accuracy: 0.000_001
        )
        let early = LauncherLayout.pageDotWeightProgress(elapsed: 0.28 * 0.06, duration: 0.28)
        XCTAssertEqual(early, LauncherLayout.pageTurnCurveProgress(0.06), accuracy: 0.000_001)
        XCTAssertGreaterThan(early, 0.06)
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

    func testShouldReleasePresentationBeforeOpenFollowsHidePreference() {
        XCTAssertTrue(LauncherLayout.shouldReleasePresentationBeforeOpen(hidesAfterLaunch: true))
        XCTAssertFalse(LauncherLayout.shouldReleasePresentationBeforeOpen(hidesAfterLaunch: false))
    }

    func testShouldForceReloadLaunchHighlightAfterImmediateOpen() {
        XCTAssertTrue(LauncherLayout.shouldForceReloadLaunchHighlightAfterImmediateOpen(isDismissing: true))
        XCTAssertTrue(LauncherLayout.shouldForceReloadLaunchHighlightAfterImmediateOpen(isDismissing: false))
    }

    func testShouldSkipLaunchPendingHighlightBeforeOpen() {
        // Feedback is restored; highlight must be in-place (not reloadItems).
        XCTAssertFalse(LauncherLayout.shouldSkipLaunchPendingHighlightBeforeOpen())
    }

    func testShouldApplyLaunchPendingHighlightInPlaceOnly() {
        // preview.74: reloadItems before open aborted Devin. Click-stack UI
        // must update tiles in place only.
        XCTAssertTrue(LauncherLayout.shouldApplyLaunchPendingHighlightInPlaceOnly())
    }

    func testShouldRejectOpenBeforeSpawnWhenTheMacExecutableCannotRun() {
        XCTAssertFalse(LauncherLayout.shouldRejectOpenBeforeSpawn(executable: .notMacInfoPlist))
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(executable: .absolute))
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(executable: .outsideBundle))
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(executable: .absent))
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(executable: .named(.missing)))
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(executable: .named(.directory)))
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(executable: .named(.notExecutable)))
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(executable: .named(.notRegularFile)))
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(executable: .named(.emptyFile)))
        XCTAssertFalse(LauncherLayout.shouldRejectOpenBeforeSpawn(executable: .named(.executableFile)))
    }

    func testOpenBundleExecutableReadsMacInfoPlistWithoutLaunching() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-OpenBundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let plainDirectory = root.appendingPathComponent("Plain.app")
        try FileManager.default.createDirectory(at: plainDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: plainDirectory), .notMacInfoPlist)

        let absent = try makeMacBundle(named: "Absent", in: root, executable: nil)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: absent), .absent)
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(
            executable: WorkspaceAppLauncher.openBundleExecutable(at: absent)
        ))

        let missing = try makeMacBundle(named: "Missing", in: root, executable: "Missing")
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: missing), .named(.missing))

        let placeholder = try makeMacBundle(
            named: "Placeholder",
            in: root,
            executable: "Placeholder",
            writeExecutable: true,
            posixPermissions: 0o644
        )
        XCTAssertEqual(
            WorkspaceAppLauncher.openBundleExecutable(at: placeholder),
            .named(.notExecutable)
        )

        let directory = try makeMacBundle(named: "Directory", in: root, executable: "Directory")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Contents/MacOS/Directory"),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: directory), .named(.directory))

        let empty = try makeMacBundle(named: "Empty", in: root, executable: "Empty", writeExecutable: true)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: empty), .named(.emptyFile))
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(
            executable: WorkspaceAppLauncher.openBundleExecutable(at: empty)
        ))

        let emptyTarget = root.appendingPathComponent("empty-target")
        try Data().write(to: emptyTarget)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: emptyTarget.path)
        let emptyLink = try makeMacBundle(named: "EmptyLink", in: root, executable: "EmptyLink")
        let emptyLinkMacOS = emptyLink.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyLinkMacOS, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: emptyLinkMacOS.appendingPathComponent("EmptyLink"),
            withDestinationURL: emptyTarget
        )
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: emptyLink), .named(.emptyFile))

        let fifo = try makeMacBundle(named: "Fifo", in: root, executable: "Fifo")
        let fifoMacOS = fifo.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: fifoMacOS, withIntermediateDirectories: true)
        let fifoPath = fifoMacOS.appendingPathComponent("Fifo").path
        XCTAssertEqual(mkfifo(fifoPath, mode_t(0o755)), 0)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: fifo), .named(.notRegularFile))

        let ready = try makeMacBundle(named: "Ready", in: root, executable: "Ready", writeExecutable: true)
        let readyFile = ready.appendingPathComponent("Contents/MacOS/Ready")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: readyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readyFile.path)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: ready), .named(.executableFile))
        XCTAssertFalse(LauncherLayout.shouldRejectOpenBeforeSpawn(
            executable: WorkspaceAppLauncher.openBundleExecutable(at: ready)
        ))

        let shared = root.appendingPathComponent("shared-bin")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: shared)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path)
        let linked = try makeMacBundle(named: "Linked", in: root, executable: "Linked")
        let linkedMacOS = linked.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedMacOS, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedMacOS.appendingPathComponent("Linked"),
            withDestinationURL: shared
        )
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: linked), .named(.executableFile))

        let dangling = try makeMacBundle(named: "Dangling", in: root, executable: "Dangling")
        let danglingMacOS = dangling.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: danglingMacOS, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: danglingMacOS.appendingPathComponent("Dangling"),
            withDestinationURL: root.appendingPathComponent("missing-bin")
        )
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: dangling), .named(.missing))

        // `/usr/bin/open` does not trim. Three spaces is a real filename.
        let spacedName = "   "
        let spaced = try makeMacBundle(named: "Spaced", in: root, executable: spacedName)
        let spacedMacOS = spaced.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: spacedMacOS, withIntermediateDirectories: true)
        let spacedFile = spacedMacOS.appendingPathComponent(spacedName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: spacedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: spacedFile.path)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: spaced), .named(.executableFile))
        XCTAssertFalse(LauncherLayout.shouldRejectOpenBeforeSpawn(
            executable: WorkspaceAppLauncher.openBundleExecutable(at: spaced)
        ))

        let spacedMissing = try makeMacBundle(named: "SpacedMissing", in: root, executable: spacedName)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: spacedMissing), .named(.missing))
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(
            executable: WorkspaceAppLauncher.openBundleExecutable(at: spacedMissing)
        ))

        // Trailing space is a different file from the trimmed name. The file
        // without the space must not count as the one `open` will launch.
        let trailingSpace = try makeMacBundle(named: "TrailingSpace", in: root, executable: "Tool ")
        let trailingMacOS = trailingSpace.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: trailingMacOS, withIntermediateDirectories: true)
        let unspaced = trailingMacOS.appendingPathComponent("Tool")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: unspaced)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unspaced.path)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: trailingSpace), .named(.missing))

        let nested = try makeMacBundle(named: "Nested", in: root, executable: "MacOS/Nested")
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: nested), .named(.missing))
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(
            executable: WorkspaceAppLauncher.openBundleExecutable(at: nested)
        ))

        // Missing, empty, and non-string names fall back to the bundle filename.
        // `Foo.bar.app` uses `Foo.bar`, not `Foo`. An explicit other name does not.
        let omitted = try makeMacBundle(named: "Foo.bar", in: root, executable: nil)
        try writeLaunchableExecutable(named: "Foo.bar", in: omitted)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: omitted), .named(.executableFile))
        XCTAssertFalse(LauncherLayout.shouldRejectOpenBeforeSpawn(
            executable: WorkspaceAppLauncher.openBundleExecutable(at: omitted)
        ))

        let spacedBundle = try makeMacBundle(named: "My App", in: root, executable: nil)
        try writeLaunchableExecutable(named: "My App", in: spacedBundle)
        XCTAssertEqual(
            WorkspaceAppLauncher.openBundleExecutable(at: spacedBundle),
            .named(.executableFile)
        )

        let shortOnly = try makeMacBundle(named: "Short.bar", in: root, executable: nil)
        try writeLaunchableExecutable(named: "Short", in: shortOnly)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: shortOnly), .absent)

        let emptyName = try makeMacBundle(named: "EmptyKey", in: root, executable: "")
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: emptyName), .absent)
        try writeLaunchableExecutable(named: "EmptyKey", in: emptyName)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: emptyName), .named(.executableFile))

        let integerMissing = try makeMacBundle(named: "IntegerMissing", in: root, executableObject: 1)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: integerMissing), .absent)
        let integer = try makeMacBundle(named: "Integer", in: root, executableObject: 1)
        try writeLaunchableExecutable(named: "Integer", in: integer)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: integer), .named(.executableFile))

        let explicit = try makeMacBundle(named: "ExplicitMiss", in: root, executable: "Other")
        try writeLaunchableExecutable(named: "ExplicitMiss", in: explicit)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: explicit), .named(.missing))

        let dot = try makeMacBundle(named: "DotDef", in: root, executable: ".")
        try writeLaunchableExecutable(named: "DotDef", in: dot)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: dot), .named(.directory))
        XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(
            executable: WorkspaceAppLauncher.openBundleExecutable(at: dot)
        ))

        let dotDot = try makeMacBundle(named: "DotDotDef", in: root, executable: "..")
        try writeLaunchableExecutable(named: "DotDotDef", in: dotDot)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: dotDot), .named(.directory))
    }

    func testOpenBundleExecutableUsesTheSearchOrderOpenUses() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-OpenSearch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func writeScript(at file: URL) throws {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        // A plain name is not only `Contents/MacOS`. `open` keeps looking.
        let rooted = try makeMacBundle(named: "Rooted", in: root, executable: "Tool")
        try writeScript(at: rooted.appendingPathComponent("Tool"))
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: rooted), .named(.executableFile))

        let contentsOnly = try makeMacBundle(named: "ContentsOnly", in: root, executable: "Tool")
        try writeScript(at: contentsOnly
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Tool"))
        XCTAssertEqual(
            WorkspaceAppLauncher.openBundleExecutable(at: contentsOnly),
            .named(.executableFile)
        )

        // The first path that exists wins. A directory in MacOS hides a good
        // file at the bundle root; `open` does not keep searching.
        let hidden = try makeMacBundle(named: "Hidden", in: root, executable: "Tool")
        try FileManager.default.createDirectory(
            at: hidden
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent("Tool", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeScript(at: hidden.appendingPathComponent("Tool"))
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: hidden), .named(.directory))

        let sub = try makeMacBundle(named: "Sub", in: root, executable: "Sub/Tool")
        try writeScript(at: sub
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Sub", isDirectory: true)
            .appendingPathComponent("Tool"))
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: sub), .named(.executableFile))

        let resources = try makeMacBundle(named: "Resources", in: root, executable: "../Resources/Tool")
        try writeScript(at: resources
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Tool"))
        XCTAssertEqual(
            WorkspaceAppLauncher.openBundleExecutable(at: resources),
            .named(.executableFile)
        )

        let relEmpty = try makeMacBundle(named: "RelEmpty", in: root, executable: "./Empty")
        let emptyFile = relEmpty
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Empty")
        try FileManager.default.createDirectory(
            at: emptyFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: emptyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: emptyFile.path)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: relEmpty), .named(.emptyFile))

        let relFifo = try makeMacBundle(named: "RelFifo", in: root, executable: "./Fifo")
        let fifo = relFifo
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Fifo")
        try FileManager.default.createDirectory(
            at: fifo.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o755)), 0)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: relFifo), .named(.notRegularFile))

        let outside = root.appendingPathComponent("outside.sh")
        try writeScript(at: outside)
        let absolute = try makeMacBundle(named: "Absolute", in: root, executable: outside.path)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: absolute), .absolute)
        let missingAbsolute = try makeMacBundle(
            named: "MissingAbsolute",
            in: root,
            executable: root.appendingPathComponent("no-such-bin").path
        )
        XCTAssertEqual(
            WorkspaceAppLauncher.openBundleExecutable(at: missingAbsolute),
            .named(.missing)
        )

        // From Contents/MacOS, `../../outside.sh` is the script next to the app.
        let escaped = try makeMacBundle(named: "Escaped", in: root, executable: "../../outside.sh")
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: escaped), .outsideBundle)

        let legacy = try makeMacBundle(named: "Legacy", in: root, legacyExecutable: "Tool")
        try writeScript(at: legacy
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Tool"))
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: legacy), .named(.executableFile))

        // A missing NSExecutable does not fall through to the bundle filename.
        let legacyMiss = try makeMacBundle(named: "LegacyMiss", in: root, legacyExecutable: "Tool")
        try writeScript(at: legacyMiss.appendingPathComponent("LegacyMiss"))
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: legacyMiss), .named(.missing))

        // "" and non-strings ignore NSExecutable and use the bundle filename.
        let integerTool = try makeMacBundle(
            named: "IntegerTool",
            in: root,
            executableObject: 1,
            legacyExecutable: "Tool"
        )
        try writeScript(at: integerTool
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Tool"))
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: integerTool), .absent)
        let integerStem = try makeMacBundle(
            named: "IntegerStem",
            in: root,
            executableObject: 1,
            legacyExecutable: "Tool"
        )
        try writeScript(at: integerStem.appendingPathComponent("IntegerStem"))
        XCTAssertEqual(
            WorkspaceAppLauncher.openBundleExecutable(at: integerStem),
            .named(.executableFile)
        )
        let emptyCF = try makeMacBundle(
            named: "EmptyCF",
            in: root,
            executable: "",
            legacyExecutable: "Tool"
        )
        try writeScript(at: emptyCF
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Tool"))
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: emptyCF), .absent)

        let stemContents = try makeMacBundle(named: "StemC", in: root, executable: nil)
        try writeScript(at: stemContents
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("StemC"))
        XCTAssertEqual(
            WorkspaceAppLauncher.openBundleExecutable(at: stemContents),
            .named(.executableFile)
        )
        let multi = try makeMacBundle(named: "Foo.bar", in: root, executable: nil)
        try writeScript(at: multi.appendingPathComponent("Foo.bar"))
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: multi), .named(.executableFile))

        for app in [hidden, relEmpty, relFifo, absolute, escaped, legacyMiss, integerTool, emptyCF] {
            let launcher = WorkspaceAppLauncher { _, _ in
                XCTFail("unlaunchable bundle must not spawn /usr/bin/open: \(app.lastPathComponent)")
            }
            XCTAssertThrowsError(try launcher.openImmediately(app)) { error in
                XCTAssertEqual(error as? WorkspaceLaunchError, .requestRejected(app))
            }
        }
        for app in [rooted, contentsOnly, sub, resources, legacy, integerStem, stemContents, multi] {
            XCTAssertEqual(try WorkspaceAppLauncher().openImmediately(app), .opened, app.lastPathComponent)
        }
    }

    func testUnreadableMacInfoPlistUsesTheBundleFilenameBeforeSpawn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-OpenUnreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func makeApp(named name: String) throws -> URL {
            let app = root.appendingPathComponent("\(name).app")
            try FileManager.default.createDirectory(
                at: app.appendingPathComponent("Contents", isDirectory: true),
                withIntermediateDirectories: true
            )
            return app
        }
        func writePlistBytes(_ data: Data, in app: URL) throws {
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        func writeExe(in app: URL, relativePath: String) throws {
            let file = app.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        // Empty and corrupt plists are present, so `open` uses the bundle
        // filename and keeps searching past MacOS.
        let emptyGood = try makeApp(named: "EmptyGood")
        try writePlistBytes(Data(), in: emptyGood)
        try writeExe(in: emptyGood, relativePath: "Contents/MacOS/EmptyGood")
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: emptyGood), .named(.executableFile))

        let corruptContents = try makeApp(named: "CorruptContents")
        try writePlistBytes(Data("not a plist".utf8), in: corruptContents)
        try writeExe(in: corruptContents, relativePath: "Contents/CorruptContents")
        XCTAssertEqual(
            WorkspaceAppLauncher.openBundleExecutable(at: corruptContents),
            .named(.executableFile)
        )

        let emptyRoot = try makeApp(named: "EmptyRoot")
        try writePlistBytes(Data(), in: emptyRoot)
        try writeExe(in: emptyRoot, relativePath: "EmptyRoot")
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: emptyRoot), .named(.executableFile))

        let emptyMissing = try makeApp(named: "EmptyMissing")
        try writePlistBytes(Data(), in: emptyMissing)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: emptyMissing), .absent)

        let emptyDir = try makeApp(named: "EmptyDir")
        try writePlistBytes(Data(), in: emptyDir)
        try FileManager.default.createDirectory(
            at: emptyDir.appendingPathComponent("Contents/MacOS/EmptyDir"),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: emptyDir), .absent)

        let emptyZero = try makeApp(named: "EmptyZero")
        try writePlistBytes(Data(), in: emptyZero)
        let zero = emptyZero.appendingPathComponent("Contents/MacOS/EmptyZero")
        try FileManager.default.createDirectory(
            at: zero.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: zero)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zero.path)
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: emptyZero), .absent)

        let emptyFifo = try makeApp(named: "EmptyFifo")
        try writePlistBytes(Data(), in: emptyFifo)
        let emptyFifoMacOS = emptyFifo.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyFifoMacOS, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(emptyFifoMacOS.appendingPathComponent("EmptyFifo").path, mode_t(0o755)), 0)
        XCTAssertEqual(
            WorkspaceAppLauncher.openBundleExecutable(at: emptyFifo),
            .named(.notRegularFile)
        )

        let dirPlist = try makeApp(named: "DirPlist")
        try FileManager.default.createDirectory(
            at: dirPlist.appendingPathComponent("Contents/Info.plist", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeExe(in: dirPlist, relativePath: "Contents/MacOS/DirPlist")
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: dirPlist), .named(.executableFile))

        // No plist node still goes to `open` when the bundle-name file can run.
        let noPlist = try makeApp(named: "NoPlist")
        try writeExe(in: noPlist, relativePath: "Contents/MacOS/NoPlist")
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: noPlist), .notMacInfoPlist)
        XCTAssertFalse(LauncherLayout.shouldRejectOpenBeforeSpawn(
            executable: WorkspaceAppLauncher.openBundleExecutable(at: noPlist)
        ))

        let noPlistFifo = try makeApp(named: "NoPlistFifo")
        let noPlistFifoMacOS = noPlistFifo.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: noPlistFifoMacOS, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(noPlistFifoMacOS.appendingPathComponent("NoPlistFifo").path, mode_t(0o755)), 0)
        XCTAssertEqual(
            WorkspaceAppLauncher.openBundleExecutable(at: noPlistFifo),
            .named(.notRegularFile)
        )

        let explicit = try makeMacBundle(named: "ExplicitStill", in: root, executable: "Other")
        try writeExe(in: explicit, relativePath: "Contents/MacOS/ExplicitStill")
        XCTAssertEqual(WorkspaceAppLauncher.openBundleExecutable(at: explicit), .named(.missing))

        for app in [emptyMissing, emptyDir, emptyZero, emptyFifo, noPlistFifo, explicit] {
            XCTAssertTrue(LauncherLayout.shouldRejectOpenBeforeSpawn(
                executable: WorkspaceAppLauncher.openBundleExecutable(at: app)
            ), app.lastPathComponent)
            let launcher = WorkspaceAppLauncher { _, _ in
                XCTFail("must not spawn /usr/bin/open: \(app.lastPathComponent)")
            }
            XCTAssertThrowsError(try launcher.openImmediately(app)) { error in
                XCTAssertEqual(error as? WorkspaceLaunchError, .requestRejected(app))
            }
        }
        for app in [emptyGood, corruptContents, emptyRoot, dirPlist, noPlist] {
            XCTAssertEqual(try WorkspaceAppLauncher().openImmediately(app), .opened, app.lastPathComponent)
        }
    }

    func testWorkspaceLauncherRejectsMacBundleWithNoExecutableWithoutSpawningOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-OpenReject-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingKey = try makeMacBundle(named: "Fixture 01", in: root, executable: nil)
        let placeholder = try makeMacBundle(
            named: "Fixture 02",
            in: root,
            executable: "Fixture 02",
            writeExecutable: true,
            posixPermissions: 0o644
        )
        let directory = try makeMacBundle(named: "Fixture 03", in: root, executable: "Fixture 03")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Contents/MacOS/Fixture 03"),
            withIntermediateDirectories: true
        )
        let empty = try makeMacBundle(
            named: "Fixture 04",
            in: root,
            executable: "Fixture 04",
            writeExecutable: true
        )
        let fifo = try makeMacBundle(named: "Fixture 05", in: root, executable: "Fixture 05")
        let fifoMacOS = fifo.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: fifoMacOS, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(fifoMacOS.appendingPathComponent("Fixture 05").path, mode_t(0o755)), 0)
        let trailingSpace = try makeMacBundle(named: "Fixture 06", in: root, executable: "Fixture 06 ")
        let trailingMacOS = trailingSpace.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: trailingMacOS, withIntermediateDirectories: true)
        let unspaced = trailingMacOS.appendingPathComponent("Fixture 06")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: unspaced)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unspaced.path)
        let omittedUnusable = try makeMacBundle(named: "Fixture 07", in: root, executable: nil)
        try writeLaunchableExecutable(named: "Fixture 07", in: omittedUnusable, permissions: 0o644)
        let omittedEmpty = try makeMacBundle(named: "Fixture 08", in: root, executable: nil)
        try writeLaunchableExecutable(named: "Fixture 08", in: omittedEmpty, bytes: Data())
        let explicitOther = try makeMacBundle(named: "Fixture 09", in: root, executable: "Other")
        try writeLaunchableExecutable(named: "Fixture 09", in: explicitOther)
        let dotName = try makeMacBundle(named: "Fixture 10", in: root, executable: ".")
        try writeLaunchableExecutable(named: "Fixture 10", in: dotName)
        let dotDotName = try makeMacBundle(named: "Fixture 11", in: root, executable: "..")
        try writeLaunchableExecutable(named: "Fixture 11", in: dotDotName)
        let integerMissing = try makeMacBundle(named: "Fixture 12", in: root, executableObject: 1)
        for app in [
            missingKey, placeholder, directory, empty, fifo, trailingSpace,
            omittedUnusable, omittedEmpty, explicitOther, dotName, dotDotName, integerMissing
        ] {
            let launcher = WorkspaceAppLauncher { _, _ in
                XCTFail("unlaunchable bundle must not spawn /usr/bin/open: \(app.lastPathComponent)")
            }
            XCTAssertThrowsError(try launcher.openImmediately(app)) { error in
                XCTAssertEqual(error as? WorkspaceLaunchError, .requestRejected(app))
            }
        }
    }

    func testWorkspaceLauncherSpawnsOpenForBundleNameFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-OpenFallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let omitted = try makeMacBundle(named: "Foo.bar", in: root, executable: nil)
        try writeLaunchableExecutable(named: "Foo.bar", in: omitted)
        let emptyName = try makeMacBundle(named: "EmptyKey", in: root, executable: "")
        try writeLaunchableExecutable(named: "EmptyKey", in: emptyName)
        let integer = try makeMacBundle(named: "Integer", in: root, executableObject: 1)
        try writeLaunchableExecutable(named: "Integer", in: integer)
        for app in [omitted, emptyName, integer] {
            XCTAssertEqual(try WorkspaceAppLauncher().openImmediately(app), .opened, app.lastPathComponent)
        }
    }

    func testWorkspaceLauncherSpawnsOpenForUntrimmedExecutableName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-OpenSpaced-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "   "
        let app = try makeMacBundle(named: "Spaced", in: root, executable: name)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let file = macOS.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        XCTAssertEqual(try WorkspaceAppLauncher().openImmediately(app), .opened)
    }

    private func makeMacBundle(
        named name: String,
        in root: URL,
        executable: String? = nil,
        executableObject: Any? = nil,
        legacyExecutable: String? = nil,
        writeExecutable: Bool = false,
        posixPermissions: Int = 0o755
    ) throws -> URL {
        let app = root.appendingPathComponent("\(name).app")
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": "com.sunzheng.LaunchIcon.OpenBundle.\(name)",
            "CFBundleName": name,
            "CFBundlePackageType": "APPL"
        ]
        if let executableObject {
            info["CFBundleExecutable"] = executableObject
        } else if let executable {
            info["CFBundleExecutable"] = executable
        }
        if let legacyExecutable {
            info["NSExecutable"] = legacyExecutable
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if writeExecutable, let executable {
            let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            let file = macOS.appendingPathComponent(executable)
            try Data().write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: posixPermissions],
                ofItemAtPath: file.path
            )
        }
        return app
    }

    private func writeLaunchableExecutable(
        named fileName: String,
        in app: URL,
        permissions: Int = 0o755,
        bytes: Data = Data("#!/bin/sh\nexit 0\n".utf8)
    ) throws {
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let file = macOS.appendingPathComponent(fileName)
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
    }

    func testShouldReportOpenProcessFailureOnlyForNonZeroStatus() {
        XCTAssertFalse(LauncherLayout.shouldReportOpenProcessFailure(terminationStatus: 0))
        XCTAssertTrue(LauncherLayout.shouldReportOpenProcessFailure(terminationStatus: 1))
        XCTAssertTrue(LauncherLayout.shouldReportOpenProcessFailure(terminationStatus: 127))
    }

    func testDelayedOpenFailureAppliesOnlyToTheLatestAttempt() {
        XCTAssertTrue(
            LauncherLayout.shouldApplyDelayedOpenFailure(
                finishedAttempt: 1,
                latestAttempt: 1,
                terminationStatus: 1
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldApplyDelayedOpenFailure(
                finishedAttempt: 1,
                latestAttempt: 2,
                terminationStatus: 1
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldApplyDelayedOpenFailure(
                finishedAttempt: 2,
                latestAttempt: 2,
                terminationStatus: 0
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldApplyDelayedOpenFailure(
                finishedAttempt: 0,
                latestAttempt: 0,
                terminationStatus: 1
            )
        )
    }

    func testDelayedOpenFailureReshowsOnlyTheHideItStarted() {
        XCTAssertTrue(
            LauncherLayout.shouldReshowLauncherAfterDelayedOpenFailure(
                hidForThisLaunch: true,
                launchDismissGeneration: 4,
                currentDismissGeneration: 4,
                finishedAttempt: 1,
                latestAttempt: 1,
                terminationStatus: 1
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldReshowLauncherAfterDelayedOpenFailure(
                hidForThisLaunch: false,
                launchDismissGeneration: 4,
                currentDismissGeneration: 4,
                finishedAttempt: 1,
                latestAttempt: 1,
                terminationStatus: 1
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldReshowLauncherAfterDelayedOpenFailure(
                hidForThisLaunch: true,
                launchDismissGeneration: 4,
                currentDismissGeneration: 5,
                finishedAttempt: 1,
                latestAttempt: 1,
                terminationStatus: 1
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldReshowLauncherAfterDelayedOpenFailure(
                hidForThisLaunch: true,
                launchDismissGeneration: 4,
                currentDismissGeneration: 4,
                finishedAttempt: 1,
                latestAttempt: 2,
                terminationStatus: 1
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldReshowLauncherAfterDelayedOpenFailure(
                hidForThisLaunch: true,
                launchDismissGeneration: 4,
                currentDismissGeneration: 4,
                finishedAttempt: 1,
                latestAttempt: 1,
                terminationStatus: 0
            )
        )
    }

    func testWorkspaceLauncherReportsNonZeroOpenExitWithoutWaitingOnTheCaller() throws {
        // `/dev/null` exists, so the file-URL guard spawns `/usr/bin/open`.
        // Launch Services rejects it (exit 1) without opening an application.
        let url = URL(fileURLWithPath: "/dev/null")
        let done = expectation(description: "open process finished")
        final class Box: @unchecked Sendable {
            var status: Int32 = 0
            var path = ""
        }
        let box = Box()
        let started = Date()
        let launcher = WorkspaceAppLauncher { finishedURL, status in
            box.path = finishedURL.path
            box.status = status
            done.fulfill()
        }
        XCTAssertEqual(try launcher.openImmediately(url), .opened)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(box.path, "/dev/null")
        XCTAssertNotEqual(box.status, 0)
    }

    func testShouldSurfaceDelayedOpenFailureOnlyWhileLauncherIsUp() {
        XCTAssertTrue(
            LauncherLayout.shouldSurfaceDelayedOpenFailureWhileLauncherVisible(
                isDismissing: false,
                isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldSurfaceDelayedOpenFailureWhileLauncherVisible(
                isDismissing: true,
                isVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldSurfaceDelayedOpenFailureWhileLauncherVisible(
                isDismissing: false,
                isVisible: false
            )
        )
    }

    func testWorkspaceLauncherRejectsNonFileURLWithoutSpawningOpen() {
        let remote = URL(string: "https://example.com/App.app")!
        XCTAssertThrowsError(try WorkspaceAppLauncher().openImmediately(remote)) { error in
            XCTAssertEqual(error as? WorkspaceLaunchError, .requestRejected(remote))
        }
    }

    func testTimedOutLaunchErrorDescriptionNoLongerHardcodesTenSeconds() {
        let url = URL(fileURLWithPath: "/Applications/Ready.app")
        let description = WorkspaceLaunchError.timedOut(url).errorDescription ?? ""
        XCTAssertFalse(description.contains("10 秒"))
        XCTAssertFalse(description.isEmpty)
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


    func testStatusItemToggleTitleRefreshGatesDuringDismissFade() {
        XCTAssertTrue(LauncherLayout.shouldRefreshStatusItemToggleTitleOnDismissArm())
        XCTAssertTrue(
            LauncherLayout.shouldRefreshStatusItemToggleTitleOnDismissCancel(wasDismissing: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldRefreshStatusItemToggleTitleOnDismissCancel(wasDismissing: false)
        )
        // Mid-fade: visible + dismissing →「显示」(not stale「隐藏»).
        XCTAssertEqual(
            LauncherLayout.statusItemToggleTitle(isVisible: true, isDismissing: true),
            "显示 LaunchIcon"
        )
        XCTAssertEqual(
            LauncherLayout.visibilityToggle(isVisible: true, isDismissing: true),
            .show
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

        XCTAssertEqual(
            LauncherLayout.launcherPresenceFadeFromOpacity(
                visible: true, appearing: true, presentedOpacity: 0.4, modelOpacity: 1
            ),
            0,
            "fresh appear always parks from 0"
        )
        XCTAssertEqual(
            LauncherLayout.launcherPresenceFadeFromOpacity(
                visible: true, appearing: false, presentedOpacity: 0.35, modelOpacity: 0
            ),
            0.35,
            "cancelled dismiss continues from presentation"
        )
        XCTAssertEqual(
            LauncherLayout.launcherPresenceFadeFromOpacity(
                visible: false, appearing: false, presentedOpacity: nil, modelOpacity: 0.8
            ),
            0.8
        )
        XCTAssertEqual(LauncherLayout.launcherPresenceFadeAnimationKey, "launcherFade")
        XCTAssertEqual(LauncherLayout.launcherPresenceRiseAnimationKey, "launcherRise")
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
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
        let focus = CGPoint(x: 620, y: 360)
        let recede = LauncherLayout.folderBackdropRecede(
            open: true,
            reducesMotion: false,
            bounds: bounds,
            focus: focus
        )
        XCTAssertEqual(recede.scale, openBackdrop.scale, accuracy: 0.001)
        let shift = 1 - openBackdrop.scale
        XCTAssertEqual(recede.translationX, focus.x * shift, accuracy: 0.001)
        XCTAssertEqual(recede.translationY, focus.y * shift, accuracy: 0.001)
        XCTAssertGreaterThan(recede.translationX, 0)
        XCTAssertGreaterThan(recede.translationY, 0)
        let pinnedX = focus.x * recede.scale + recede.translationX
        let pinnedY = focus.y * recede.scale + recede.translationY
        XCTAssertEqual(pinnedX, focus.x, accuracy: 0.001)
        XCTAssertEqual(pinnedY, focus.y, accuracy: 0.001)
        let centeredFocus = CGPoint(x: bounds.midX, y: bounds.midY)
        let centered = LauncherLayout.folderBackdropRecede(
            open: true,
            reducesMotion: false,
            bounds: bounds,
            focus: centeredFocus
        )
        XCTAssertEqual(centered.translationX, centeredFocus.x * shift, accuracy: 0.001)
        XCTAssertEqual(centered.translationY, centeredFocus.y * shift, accuracy: 0.001)
        XCTAssertGreaterThan(abs(centered.translationX), 1)
        XCTAssertEqual(
            centeredFocus.x * centered.scale + centered.translationX,
            centeredFocus.x,
            accuracy: 0.001
        )
        XCTAssertEqual(
            centeredFocus.y * centered.scale + centered.translationY,
            centeredFocus.y,
            accuracy: 0.001
        )
        let closedRecede = LauncherLayout.folderBackdropRecede(
            open: false,
            reducesMotion: false,
            bounds: bounds,
            focus: focus
        )
        XCTAssertEqual(closedRecede.scale, 1, accuracy: 0.001)
        XCTAssertEqual(closedRecede.translationX, 0, accuracy: 0.001)
        XCTAssertEqual(closedRecede.translationY, 0, accuracy: 0.001)
        let reducedRecede = LauncherLayout.folderBackdropRecede(
            open: true,
            reducesMotion: true,
            bounds: bounds,
            focus: focus
        )
        XCTAssertEqual(reducedRecede.scale, 1, accuracy: 0.001)
        XCTAssertEqual(reducedRecede.translationX, 0, accuracy: 0.001)
        let unpinned = LauncherLayout.folderBackdropRecede(
            open: true,
            reducesMotion: false,
            bounds: bounds,
            focus: nil
        )
        XCTAssertEqual(unpinned.scale, openBackdrop.scale, accuracy: 0.001)
        XCTAssertEqual(unpinned.translationX, 0, accuracy: 0.001)
        XCTAssertEqual(unpinned.translationY, 0, accuracy: 0.001)
        let outside = LauncherLayout.folderBackdropRecede(
            open: true,
            reducesMotion: false,
            bounds: bounds,
            focus: CGPoint(x: 2000, y: -40)
        )
        XCTAssertEqual(outside.translationX, bounds.maxX * shift, accuracy: 0.001)
        XCTAssertEqual(outside.translationY, bounds.minY * shift, accuracy: 0.001)
        XCTAssertEqual(bounds.maxX * outside.scale + outside.translationX, bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(bounds.minY * outside.scale + outside.translationY, bounds.minY, accuracy: 0.001)
        let brokenRecede = LauncherLayout.folderBackdropRecede(
            open: true,
            reducesMotion: false,
            bounds: .zero,
            focus: focus
        )
        XCTAssertEqual(brokenRecede.translationX, 0, accuracy: 0.001)
        XCTAssertEqual(brokenRecede.scale, openBackdrop.scale, accuracy: 0.001)
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
        XCTAssertEqual(LauncherLayout.launchPressScale, 0.93, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.launchPressHalfDuration, 0.045, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.launchPressHalfDuration * 2, 0.09, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.launchFeedbackAnimationKey, "launch-feedback")
        let pressedIcon = CGPoint(x: 56, y: 76)
        let pressShift = LauncherLayout.originPinnedScaleTranslation(
            point: pressedIcon,
            scale: LauncherLayout.launchPressScale
        )
        XCTAssertEqual(
            pressedIcon.x * LauncherLayout.launchPressScale + pressShift.x,
            pressedIcon.x,
            accuracy: 0.001
        )
        XCTAssertEqual(
            pressedIcon.y * LauncherLayout.launchPressScale + pressShift.y,
            pressedIcon.y,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(pressShift.x, 1)
        XCTAssertGreaterThan(pressShift.y, 1)
        XCTAssertEqual(
            LauncherLayout.originPinnedScaleTranslation(point: .zero, scale: LauncherLayout.launchPressScale),
            .zero
        )
        XCTAssertEqual(
            LauncherLayout.originPinnedScaleTranslation(
                point: CGPoint(x: CGFloat.nan, y: 4),
                scale: LauncherLayout.launchPressScale
            ),
            .zero
        )
        XCTAssertEqual(
            LauncherLayout.originPinnedScaleTranslation(point: pressedIcon, scale: 0),
            .zero
        )
        XCTAssertEqual(
            LauncherLayout.originPinnedScaleTranslation(point: pressedIcon, scale: CGFloat.nan),
            .zero
        )
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
        let shown = LauncherLayout.pageButtonHoverFade(shown: true)
        let hidden = LauncherLayout.pageButtonHoverFade(shown: false)
        XCTAssertEqual(shown.opacity, 0.9, accuracy: 0.001)
        XCTAssertEqual(hidden.opacity, 0, accuracy: 0.001)
        XCTAssertEqual(shown.plateAlpha, 0.22, accuracy: 0.001)
        XCTAssertEqual(hidden.plateAlpha, shown.plateAlpha, accuracy: 0.001)
        XCTAssertEqual(shown.duration, 0.2, accuracy: 0.001)
        XCTAssertLessThan(shown.duration, 0.25)
        let early = LauncherLayout.pageButtonHoverSample(appearing: true, time: 0.15)
        XCTAssertGreaterThan(early.controlOpacity, 0.4)
        XCTAssertEqual(early.plateAlpha, shown.plateAlpha, accuracy: 0.001)
        XCTAssertGreaterThan(
            early.controlOpacity,
            LauncherLayout.pageButtonHoverShownOpacity * 0.15
        )
        let leavingStart = LauncherLayout.pageButtonHoverSample(appearing: false, time: 0)
        XCTAssertEqual(leavingStart.controlOpacity, 0.9, accuracy: 0.001)
        XCTAssertEqual(leavingStart.plateAlpha, shown.plateAlpha, accuracy: 0.001)
        let leavingEnd = LauncherLayout.pageButtonHoverSample(appearing: false, time: 1)
        XCTAssertEqual(leavingEnd.controlOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(leavingEnd.plateAlpha, shown.plateAlpha, accuracy: 0.001)
        let earlyTravel = LauncherLayout.pageButtonHoverSample(appearing: true, time: 0.2).controlOpacity
        let lateTravel = LauncherLayout.pageButtonHoverSample(appearing: true, time: 1).controlOpacity
            - LauncherLayout.pageButtonHoverSample(appearing: true, time: 0.8).controlOpacity
        XCTAssertGreaterThan(earlyTravel, lateTravel * 2)
        XCTAssertTrue(LauncherLayout.pageButtonHoverShown(
            pointerInside: false, dragInside: true, focused: false
        ))
        XCTAssertTrue(LauncherLayout.pageButtonHoverShown(
            pointerInside: true, dragInside: false, focused: false
        ))
        XCTAssertTrue(LauncherLayout.pageButtonHoverShown(
            pointerInside: false, dragInside: false, focused: true
        ))
        XCTAssertFalse(LauncherLayout.pageButtonHoverShown(
            pointerInside: false, dragInside: false, focused: false
        ))
        XCTAssertEqual(LauncherLayout.pageButtonDragHoverDelay, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(LauncherLayout.pageButtonDragHoverDelay, shown.duration)
        XCTAssertEqual(
            LauncherLayout.pageButtonHoverFade(shown: LauncherLayout.pageButtonHoverShown(
                pointerInside: false, dragInside: true, focused: false
            )).opacity,
            shown.opacity,
            accuracy: 0.001
        )
    }

    func testTileChromeAlphasKeepIdleFullyTransparent() {
        XCTAssertEqual(LauncherLayout.tileChromeIdleAlpha, 0, accuracy: 0.0001)
        XCTAssertEqual(LauncherLayout.tileChromeFocusAlpha, 0.08, accuracy: 0.0001)
        XCTAssertEqual(LauncherLayout.tileChromeDropTargetAlpha, 0.12, accuracy: 0.0001)
        XCTAssertEqual(LauncherLayout.tileChromeLaunchingAlpha, 0.35, accuracy: 0.0001)
        XCTAssertLessThan(LauncherLayout.tileChromeIdleAlpha, LauncherLayout.tileChromeFocusAlpha)
        XCTAssertLessThan(LauncherLayout.tileChromeFocusAlpha, LauncherLayout.tileChromeSelectionAlpha)
        XCTAssertLessThan(LauncherLayout.tileChromeSelectionAlpha, LauncherLayout.tileChromeDropTargetAlpha)
        XCTAssertLessThan(LauncherLayout.tileChromeDropTargetAlpha, LauncherLayout.tileChromeLaunchingAlpha)
        XCTAssertEqual(LauncherLayout.tileChromeSelectionAlpha, 0.10, accuracy: 0.0001)

        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlpha(isLaunching: false, isDropTarget: false, focused: false),
            LauncherLayout.tileChromeIdleAlpha,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlpha(isLaunching: false, isDropTarget: false, focused: true),
            LauncherLayout.tileChromeFocusAlpha,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlpha(
                isLaunching: false,
                isDropTarget: false,
                focused: false,
                selected: true
            ),
            LauncherLayout.tileChromeSelectionAlpha,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlpha(
                isLaunching: false,
                isDropTarget: false,
                focused: true,
                selected: true
            ),
            LauncherLayout.tileChromeSelectionAlpha,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlpha(
                isLaunching: false,
                isDropTarget: false,
                focused: false,
                selected: true,
                folderPanelChromeInFlight: true
            ),
            LauncherLayout.tileChromeIdleAlpha,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlpha(
                isLaunching: false,
                isDropTarget: true,
                focused: false,
                selected: true
            ),
            LauncherLayout.tileChromeDropTargetAlpha,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlpha(
                isLaunching: false,
                isDropTarget: false,
                focused: true,
                folderPanelChromeInFlight: true
            ),
            LauncherLayout.tileChromeIdleAlpha,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlpha(
                isLaunching: false,
                isDropTarget: true,
                focused: true,
                folderPanelChromeInFlight: true
            ),
            LauncherLayout.tileChromeDropTargetAlpha,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlpha(isLaunching: false, isDropTarget: true, focused: true),
            LauncherLayout.tileChromeDropTargetAlpha,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlpha(isLaunching: true, isDropTarget: true, focused: true),
            LauncherLayout.tileChromeLaunchingAlpha,
            accuracy: 0.0001
        )
        // Drag-lift must never bake focus/drop/launch chrome into the flying image.
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlphaForDragLiftSnapshot(),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlphaForDragLiftSnapshot(),
            LauncherLayout.tileChromeIdleAlpha,
            accuracy: 0.0001
        )
        XCTAssertLessThan(
            LauncherLayout.tileChromeFillAlphaForDragLiftSnapshot(),
            LauncherLayout.tileChromeFocusAlpha
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillFadeDuration,
            LauncherLayout.searchTransitionDuration,
            accuracy: 0.0001
        )
        XCTAssertTrue(
            LauncherLayout.shouldAnimateTileChromeFocusFill(
                fromAlpha: 0,
                toAlpha: LauncherLayout.tileChromeFocusAlpha,
                reducesMotion: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldAnimateTileChromeFocusFill(
                fromAlpha: LauncherLayout.tileChromeFocusAlpha,
                toAlpha: 0,
                reducesMotion: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimateTileChromeFocusFill(
                fromAlpha: 0,
                toAlpha: LauncherLayout.tileChromeFocusAlpha,
                reducesMotion: true
            )
        )
        // Drop / launch stay immediate.
        XCTAssertFalse(
            LauncherLayout.shouldAnimateTileChromeFocusFill(
                fromAlpha: LauncherLayout.tileChromeFocusAlpha,
                toAlpha: LauncherLayout.tileChromeDropTargetAlpha,
                reducesMotion: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimateTileChromeFocusFill(
                fromAlpha: 0,
                toAlpha: LauncherLayout.tileChromeLaunchingAlpha,
                reducesMotion: false
            )
        )
    }

    func testShouldDismissToastWhenOpeningFolder() {
        XCTAssertTrue(
            LauncherLayout.shouldDismissToastWhenOpeningFolder(isToastVisible: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldDismissToastWhenOpeningFolder(isToastVisible: false)
        )
    }

    func testSettingsLauncherVisibilityRestorePolicy() {
        XCTAssertTrue(
            LauncherLayout.shouldHideLauncherToShowSettings(launcherVisible: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldHideLauncherToShowSettings(launcherVisible: false)
        )
        XCTAssertTrue(
            LauncherLayout.shouldRestoreLauncherWhenSettingsCloses(
                didHideLauncherToShowSettings: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestoreLauncherWhenSettingsCloses(
                didHideLauncherToShowSettings: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldClearSettingsLauncherRestoreFlag(
                didHideLauncherToShowSettings: true,
                launcherVisible: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldClearSettingsLauncherRestoreFlag(
                didHideLauncherToShowSettings: true,
                launcherVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldClearSettingsLauncherRestoreFlag(
                didHideLauncherToShowSettings: false,
                launcherVisible: true
            )
        )
        XCTAssertFalse(LauncherLayout.shouldAnimateLauncherHideForSettingsHandoff())
        XCTAssertFalse(LauncherLayout.shouldAnimateLauncherShowForSettingsHandoff())
        XCTAssertFalse(
            LauncherLayout.shouldClearSearchQueryWhenPreparingPresentation(
                preservesQueryAcrossHandoff: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldClearSearchQueryWhenPreparingPresentation(
                preservesQueryAcrossHandoff: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldParkSearchFocusForSettingsHandoff(
                searchHoldsKeyboardFocus: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldParkSearchFocusForSettingsHandoff(
                searchHoldsKeyboardFocus: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldRestoreSearchFocusAfterSettingsHandoff(
                isSettingsHandoffRestore: true,
                searchHeldFocusBeforeHandoff: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestoreSearchFocusAfterSettingsHandoff(
                isSettingsHandoffRestore: true,
                searchHeldFocusBeforeHandoff: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestoreSearchFocusAfterSettingsHandoff(
                isSettingsHandoffRestore: false,
                searchHeldFocusBeforeHandoff: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldParkSearchResultsChromeForSettingsHandoff(
                queryIsNonEmpty: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldParkSearchResultsChromeForSettingsHandoff(
                queryIsNonEmpty: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldRestoreSearchResultsChromeAfterSettingsHandoff(
                isSettingsHandoffRestore: true,
                hadNonEmptyQueryBeforeHandoff: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestoreSearchResultsChromeAfterSettingsHandoff(
                isSettingsHandoffRestore: true,
                hadNonEmptyQueryBeforeHandoff: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestoreSearchResultsChromeAfterSettingsHandoff(
                isSettingsHandoffRestore: false,
                hadNonEmptyQueryBeforeHandoff: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldEnsureSearchResultsChromeWhenPreservingQuery(
                queryIsNonEmpty: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldEnsureSearchResultsChromeWhenPreservingQuery(
                queryIsNonEmpty: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldSuppressPageIndicatorAfterSettingsHandoff(
                isSettingsHandoffRestore: true,
                hadNonEmptyQueryBeforeHandoff: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldSuppressPageIndicatorAfterSettingsHandoff(
                isSettingsHandoffRestore: true,
                hadNonEmptyQueryBeforeHandoff: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldSuppressPageIndicatorAfterSettingsHandoff(
                isSettingsHandoffRestore: false,
                hadNonEmptyQueryBeforeHandoff: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldEnsurePageIndicatorSuppressedWhenPreservingQuery(
                queryIsNonEmpty: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldEnsurePageIndicatorSuppressedWhenPreservingQuery(
                queryIsNonEmpty: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldSuppressPageArrowsAfterSettingsHandoff(
                isSettingsHandoffRestore: true,
                hadNonEmptyQueryBeforeHandoff: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldSuppressPageArrowsAfterSettingsHandoff(
                isSettingsHandoffRestore: true,
                hadNonEmptyQueryBeforeHandoff: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldSuppressPageArrowsAfterSettingsHandoff(
                isSettingsHandoffRestore: false,
                hadNonEmptyQueryBeforeHandoff: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldEnsurePageArrowsSuppressedWhenPreservingQuery(
                queryIsNonEmpty: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldEnsurePageArrowsSuppressedWhenPreservingQuery(
                queryIsNonEmpty: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldSnapSearchFooterChromeAfterSettingsHandoff(
                isSettingsHandoffRestore: true,
                hadNonEmptyQueryBeforeHandoff: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapSearchFooterChromeAfterSettingsHandoff(
                isSettingsHandoffRestore: true,
                hadNonEmptyQueryBeforeHandoff: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapSearchFooterChromeAfterSettingsHandoff(
                isSettingsHandoffRestore: false,
                hadNonEmptyQueryBeforeHandoff: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldEnsureSearchFooterChromeWhenPreservingQuery(
                queryIsNonEmpty: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldEnsureSearchFooterChromeWhenPreservingQuery(
                queryIsNonEmpty: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldSnapSearchAdjacentChromeAfterSettingsHandoff(
                isSettingsHandoffRestore: true,
                hadNonEmptyQueryBeforeHandoff: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapSearchAdjacentChromeAfterSettingsHandoff(
                isSettingsHandoffRestore: true,
                hadNonEmptyQueryBeforeHandoff: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapSearchAdjacentChromeAfterSettingsHandoff(
                isSettingsHandoffRestore: false,
                hadNonEmptyQueryBeforeHandoff: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldEnsureSearchAdjacentChromeWhenPreservingQuery(
                queryIsNonEmpty: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldEnsureSearchAdjacentChromeWhenPreservingQuery(
                queryIsNonEmpty: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldRestoreGridFocusAfterClearingSearch(
                hadFocusedSearchResult: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldRestoreGridFocusAfterClearingSearch(
                hadFocusedSearchResult: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldFocusFirstGridItemAfterClearingSearch(
                hadFocusedSearchResult: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldFocusFirstGridItemAfterClearingSearch(
                hadFocusedSearchResult: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldFocusFirstGridItemAfterSearchQueryEmptied(
                wasSearching: true,
                isSearchingNow: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldFocusFirstGridItemAfterSearchQueryEmptied(
                wasSearching: false,
                isSearchingNow: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldFocusFirstGridItemAfterSearchQueryEmptied(
                wasSearching: true,
                isSearchingNow: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldFocusFirstGridItemAfterSearchFieldDidEndSearching(
                isSearching: false,
                searchHoldsKeyboardFocus: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldFocusFirstGridItemAfterSearchFieldDidEndSearching(
                isSearching: true,
                searchHoldsKeyboardFocus: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldFocusFirstGridItemAfterSearchFieldDidEndSearching(
                isSearching: false,
                searchHoldsKeyboardFocus: false
            )
        )
    }

    func testSearchKeyboardHighlightPinsFirstHitWithoutStealingFieldFocusPolicy() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        XCTAssertEqual(
            LauncherLayout.searchKeyboardHighlightID(
                isSearching: true,
                presentedIDs: [a, b, c],
                previousHighlightID: nil
            ),
            a
        )
        // Query edit passes nil previous → always first.
        XCTAssertEqual(
            LauncherLayout.searchKeyboardHighlightID(
                isSearching: true,
                presentedIDs: [b, c],
                previousHighlightID: nil
            ),
            b
        )
        // Preserve arrow target when still present.
        XCTAssertEqual(
            LauncherLayout.searchKeyboardHighlightID(
                isSearching: true,
                presentedIDs: [a, b, c],
                previousHighlightID: b
            ),
            b
        )
        // Drop stale highlight → first.
        XCTAssertEqual(
            LauncherLayout.searchKeyboardHighlightID(
                isSearching: true,
                presentedIDs: [a, c],
                previousHighlightID: b
            ),
            a
        )
        XCTAssertNil(
            LauncherLayout.searchKeyboardHighlightID(
                isSearching: false,
                presentedIDs: [a],
                previousHighlightID: a
            )
        )
        XCTAssertNil(
            LauncherLayout.searchKeyboardHighlightID(
                isSearching: true,
                presentedIDs: [],
                previousHighlightID: a
            )
        )
        XCTAssertEqual(
            LauncherLayout.searchKeyboardHighlightIDMoving(from: a, in: [a, b, c], by: 1),
            b
        )
        XCTAssertEqual(
            LauncherLayout.searchKeyboardHighlightIDMoving(from: b, in: [a, b, c], by: -1),
            a
        )
        XCTAssertEqual(
            LauncherLayout.searchKeyboardHighlightIDMoving(from: c, in: [a, b, c], by: 1),
            c
        )
        XCTAssertEqual(
            LauncherLayout.searchKeyboardHighlightIDMoving(from: nil, in: [a, b, c], by: 1),
            a
        )
        XCTAssertEqual(
            LauncherLayout.searchKeyboardHighlightIDMoving(from: nil, in: [a, b, c], by: -1),
            c
        )
        XCTAssertTrue(
            LauncherLayout.tileShowsKeyboardFocusChrome(
                isFirstResponder: false,
                isSearchKeyboardHighlighted: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.tileShowsKeyboardFocusChrome(
                isFirstResponder: true,
                isSearchKeyboardHighlighted: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.tileShowsKeyboardFocusChrome(
                isFirstResponder: false,
                isSearchKeyboardHighlighted: false
            )
        )
    }

    func testSearchFieldTabHandoffToHighlightAndBacktabToField() {
        let a = UUID()
        let b = UUID()
        XCTAssertTrue(
            LauncherLayout.shouldHandOffSearchFieldTabToHit(
                isSearching: true,
                hasHits: true,
                hasMarkedText: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldHandOffSearchFieldTabToHit(
                isSearching: true,
                hasHits: true,
                hasMarkedText: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldHandOffSearchFieldTabToHit(
                isSearching: true,
                hasHits: false,
                hasMarkedText: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldHandOffSearchFieldTabToHit(
                isSearching: false,
                hasHits: true,
                hasMarkedText: false
            )
        )
        XCTAssertEqual(
            LauncherLayout.searchFieldTabHandoffTargetID(highlightID: b, presentedIDs: [a, b]),
            b
        )
        XCTAssertEqual(
            LauncherLayout.searchFieldTabHandoffTargetID(highlightID: nil, presentedIDs: [a, b]),
            a
        )
        XCTAssertEqual(
            LauncherLayout.searchFieldTabHandoffTargetID(highlightID: UUID(), presentedIDs: [a, b]),
            a
        )
        XCTAssertNil(
            LauncherLayout.searchFieldTabHandoffTargetID(highlightID: a, presentedIDs: [])
        )
        XCTAssertTrue(
            LauncherLayout.shouldReturnSearchHitBacktabToField(
                isSearchCollection: true,
                tabDirection: -1
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldReturnSearchHitBacktabToField(
                isSearchCollection: true,
                tabDirection: 1
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldReturnSearchHitBacktabToField(
                isSearchCollection: false,
                tabDirection: -1
            )
        )
    }

    func testShouldPresentToastWhileFolderChromeQuiet() {
        XCTAssertTrue(
            LauncherLayout.shouldPresentToastWhileFolderChromeQuiet(
                folderOpen: false,
                folderClosing: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldPresentToastWhileFolderChromeQuiet(
                folderOpen: true,
                folderClosing: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldPresentToastWhileFolderChromeQuiet(
                folderOpen: false,
                folderClosing: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldPresentToastWhileFolderChromeQuiet(
                folderOpen: true,
                folderClosing: true
            )
        )
    }

    func testFolderTitleEditUnderlineFadeMatchesSearchChromeClock() {
        XCTAssertEqual(
            LauncherLayout.folderTitleEditUnderlineAlpha,
            0.55,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.folderTitleEditUnderlineFadeDuration,
            LauncherLayout.searchTransitionDuration,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.aliasEditUnderlineFadeDuration,
            LauncherLayout.searchTransitionDuration,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.aliasEditUnderlineFadeDuration,
            LauncherLayout.folderTitleEditUnderlineFadeDuration,
            accuracy: 0.0001
        )
        XCTAssertTrue(
            LauncherLayout.shouldAnimateFolderTitleEditUnderline(
                fromOpacity: 0,
                toOpacity: 1,
                reducesMotion: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimateFolderTitleEditUnderline(
                fromOpacity: 0,
                toOpacity: 1,
                reducesMotion: true
            )
        )
    }

    func testAppUninstallEligibilityBlocksSystemAndSelf() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let system = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            bundleIdentifier: "com.apple.calculator",
            displayName: "计算器",
            sourcePriority: 2,
            discoveredAt: now
        )
        let systemDecision = AppUninstallEligibility.evaluate(
            candidate: system,
            layoutEditingEnabled: true,
            selfBundleURL: URL(fileURLWithPath: "/Applications/LaunchIcon.app"),
            selfBundleIdentifier: "com.sunzheng.LaunchIcon"
        )
        XCTAssertFalse(systemDecision.isAllowed)
        XCTAssertEqual(systemDecision.blockReason, .systemProtected)
        XCTAssertEqual(systemDecision.explanationKey, "系统应用受保护，无法卸载")

        let cryptex = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications/Safari.app"),
            bundleIdentifier: "com.apple.Safari",
            displayName: "Safari",
            sourcePriority: 3,
            discoveredAt: now
        )
        XCTAssertFalse(
            AppUninstallEligibility.evaluate(
                candidate: cryptex,
                layoutEditingEnabled: true,
                selfBundleURL: nil,
                selfBundleIdentifier: nil
            ).isAllowed
        )

        let selfApp = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/LaunchIcon.app"),
            bundleIdentifier: "com.sunzheng.LaunchIcon",
            displayName: "LaunchIcon",
            sourcePriority: 1,
            discoveredAt: now
        )
        let selfDecision = AppUninstallEligibility.evaluate(
            candidate: selfApp,
            layoutEditingEnabled: true,
            selfBundleURL: URL(fileURLWithPath: "/Applications/LaunchIcon.app"),
            selfBundleIdentifier: "com.sunzheng.LaunchIcon"
        )
        XCTAssertFalse(selfDecision.isAllowed)
        XCTAssertEqual(selfDecision.blockReason, .selfApplication)

        let editingOff = AppUninstallEligibility.evaluate(
            candidate: system,
            layoutEditingEnabled: false,
            selfBundleURL: nil,
            selfBundleIdentifier: nil
        )
        XCTAssertFalse(editingOff.isAllowed)
        XCTAssertEqual(editingOff.blockReason, .layoutEditingDisabled)

        XCTAssertTrue(AppUninstallEligibility.isSystemProtectedPath("/System/Applications/X.app"))
        XCTAssertFalse(AppUninstallEligibility.isSystemProtectedPath("/Applications/X.app"))
        XCTAssertFalse(AppUninstallEligibility.isSystemProtectedPath("/Users/me/Applications/X.app"))
    }

    func testWritableUserApplicationsBundleEnablesUninstallMenu() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-UninstallMenuEnabled-\(UUID().uuidString)", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let bundle = apps.appendingPathComponent("UserSample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let candidate = AppCandidate(
            canonicalURL: bundle,
            bundleIdentifier: "com.example.UserSample",
            displayName: "UserSample",
            sourcePriority: 0,
            discoveredAt: Date()
        )
        let decision = AppUninstallEligibility.evaluate(
            candidate: candidate,
            layoutEditingEnabled: true,
            selfBundleURL: URL(fileURLWithPath: "/Applications/LaunchIcon.app"),
            selfBundleIdentifier: "com.sunzheng.LaunchIcon"
        )
        XCTAssertTrue(decision.isAllowed)
        XCTAssertEqual(
            AppUninstallEligibility.menuPresentation(layoutEditingEnabled: true, decision: decision),
            .enabled
        )
    }

    func testAppUninstallMenuPresentationDisablesWhenReadOnlyAndDisablesProtected() {
        let systemBlocked = AppUninstallDecision(allowed: false, blockReason: .systemProtected)
        // Incomplete scan / read-only: still expose uninstall disabled + reason (VoiceOver).
        XCTAssertEqual(
            AppUninstallEligibility.menuPresentation(layoutEditingEnabled: false, decision: systemBlocked),
            .disabled(explanationKey: "系统应用受保护，无法卸载")
        )
        XCTAssertEqual(
            AppUninstallEligibility.menuPresentation(layoutEditingEnabled: true, decision: systemBlocked),
            .disabled(explanationKey: "系统应用受保护，无法卸载")
        )
        XCTAssertEqual(
            AppUninstallEligibility.menuPresentation(
                layoutEditingEnabled: true,
                decision: AppUninstallDecision(allowed: true)
            ),
            .enabled
        )
        let editingOff = AppUninstallDecision(allowed: false, blockReason: .layoutEditingDisabled)
        XCTAssertEqual(
            AppUninstallEligibility.menuPresentation(layoutEditingEnabled: false, decision: editingOff),
            .disabled(explanationKey: "暂时无法整理应用，请先完成扫描")
        )
    }

    func testAppUninstallEligibilityAllowsWritableUserApplicationsBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-UninstallEligibility-\(UUID().uuidString)", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let bundle = apps.appendingPathComponent("Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let candidate = AppCandidate(
            canonicalURL: bundle,
            bundleIdentifier: "com.example.Sample",
            displayName: "Sample",
            sourcePriority: 0,
            discoveredAt: Date()
        )
        let decision = AppUninstallEligibility.evaluate(
            candidate: candidate,
            layoutEditingEnabled: true,
            selfBundleURL: URL(fileURLWithPath: "/Applications/LaunchIcon.app"),
            selfBundleIdentifier: "com.sunzheng.LaunchIcon",
            fileManager: .default
        )
        XCTAssertTrue(decision.isAllowed, "\(String(describing: decision.blockReason))")
        XCTAssertNil(decision.blockReason)
        XCTAssertEqual(
            AppUninstallEligibility.menuPresentation(layoutEditingEnabled: true, decision: decision),
            .enabled,
            "Writable user Applications bundles must expose an enabled uninstall item"
        )
        XCTAssertEqual(
            AppUninstallEligibility.menuPresentation(layoutEditingEnabled: false, decision: decision),
            .disabled(explanationKey: "暂时无法整理应用，请先完成扫描")
        )

        let missing = AppCandidate(
            canonicalURL: apps.appendingPathComponent("Gone.app"),
            bundleIdentifier: "com.example.Gone",
            displayName: "Gone",
            sourcePriority: 0,
            discoveredAt: Date()
        )
        let missingDecision = AppUninstallEligibility.evaluate(
            candidate: missing,
            layoutEditingEnabled: true,
            selfBundleURL: nil,
            selfBundleIdentifier: nil
        )
        XCTAssertFalse(missingDecision.isAllowed)
        XCTAssertEqual(missingDecision.blockReason, .missingBundle)
    }

    func testForgetUninstalledApplicationClearsAliasHideAndSlots() {
        let key = "bundle:com.example.Sample"
        var id = UUID()
        var state = LayoutState(
            orderedEntries: [.app(id)],
            folders: [:],
            appKeys: [id: key],
            hiddenAppKeys: [key],
            appAliases: [key: "别名"],
            updatedAt: Date()
        )
        state = LauncherLayout.forgetUninstalledApplication(withKey: key, in: state)
        XCTAssertTrue(state.orderedEntries.isEmpty)
        XCTAssertNil(state.appKeys[id])
        XCTAssertFalse(state.hiddenAppKeys.contains(key))
        XCTAssertNil(state.appAliases[key])
    }

    func testRemainingCopyKeepsFolderPlacementAndAliasAfterCatalogReconcile() {
        let key = "bundle:com.example.sample"
        let appID = UUID(), otherID = UUID(), folderID = UUID()
        let state = LayoutState(
            orderedEntries: [.folder(folderID)],
            folders: [folderID: LauncherFolder(id: folderID, name: "Work", itemIDs: [appID, otherID])],
            appKeys: [appID: key, otherID: "bundle:com.example.other"],
            appAliases: [key: "我的别名"], updatedAt: .now
        )
        let remainingCopy = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Users/me/Applications/Sample.app"),
            bundleIdentifier: "com.example.Sample", displayName: "Sample", sourcePriority: 0, discoveredAt: .now
        )
        let other = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Other.app"),
            bundleIdentifier: "com.example.Other", displayName: "Other", sourcePriority: 0, discoveredAt: .now
        )
        let reconciled = LauncherLayout.reconcile(candidates: [remainingCopy, other], into: state)
        XCTAssertEqual(reconciled.orderedEntries, [.folder(folderID)])
        XCTAssertEqual(reconciled.folders[folderID]?.itemIDs, [appID, otherID])
        XCTAssertEqual(reconciled.appKeys[appID], key)
        XCTAssertEqual(reconciled.appAliases[key], "我的别名")
    }

    func testTrashApplicationBundleMovesIntoTrash() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-TrashBundle-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("TrashMe.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)

        let trashed = try AppBundleUninstaller.trashApplicationBundle(at: bundle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        // Clean the trashed copy so the test leaves no debris.
        try? FileManager.default.removeItem(at: trashed)
    }

    func testAppRelatedFileScannerDiscoversBundleIDPaths() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-RelatedScan-\(UUID().uuidString)", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support/com.example.Sample", isDirectory: true)
        let prefs = library.appendingPathComponent("Preferences/com.example.Sample.plist", isDirectory: false)
        let caches = library.appendingPathComponent("Caches/com.example.Sample", isDirectory: true)
        let group = library.appendingPathComponent("Group Containers/ABCD.com.example.Sample", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: prefs)
        defer { try? FileManager.default.removeItem(at: home) }

        let candidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Sample.app"),
            bundleIdentifier: "com.example.Sample",
            displayName: "Sample",
            sourcePriority: 0,
            discoveredAt: Date()
        )
        let found = AppRelatedFileScanner.discover(candidate: candidate, homeDirectory: home)
        let paths = Set(found.map(\.url.lastPathComponent))
        XCTAssertTrue(paths.contains("com.example.Sample"))
        XCTAssertTrue(paths.contains("com.example.Sample.plist"))
        XCTAssertTrue(paths.contains("ABCD.com.example.Sample"))
        XCTAssertTrue(found.contains(where: { $0.kind == .applicationSupport }))
        XCTAssertTrue(found.contains(where: { $0.kind == .preferences }))
        XCTAssertTrue(found.contains(where: { $0.kind == .groupContainers }))
    }

    func testAppRelatedFileScannerRejectsUnsafePackageNamesAndOutsideHome() throws {
        XCTAssertFalse(AppRelatedFileScanner.isSafePackageNameFallback("data"))
        XCTAssertFalse(AppRelatedFileScanner.isSafePackageNameFallback("ab"))
        XCTAssertTrue(AppRelatedFileScanner.isSafePackageNameFallback("SampleApp"))

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-RelatedSafe-\(UUID().uuidString)", isDirectory: true)
        let library = home.appendingPathComponent("Library/Application Support/SampleApp", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let candidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/SampleApp.app"),
            bundleIdentifier: nil,
            displayName: "SampleApp",
            sourcePriority: 0,
            discoveredAt: Date()
        )
        let found = AppRelatedFileScanner.discover(candidate: candidate, homeDirectory: home)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].kind, .applicationSupport)
    }



    func testEmptyRelatedFilesMessageKeyIsLocalizedLiteral() {
        XCTAssertEqual(
            AppRelatedFileScanner.emptyRelatedFilesMessageKey,
            "未发现可清理的相关用户文件"
        )
        // discover on a home with Library but no matching paths stays empty.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-RelatedEmpty-\(UUID().uuidString)", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let candidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/NoSupport.app"),
            bundleIdentifier: "com.example.NoSupport.\(UUID().uuidString)",
            displayName: "NoSupport",
            sourcePriority: 0,
            discoveredAt: Date()
        )
        let found = AppRelatedFileScanner.discover(candidate: candidate, homeDirectory: home)
        XCTAssertTrue(found.isEmpty)
        XCTAssertFalse(AppRelatedFileScanner.relatedCleanupConfirmEnabled(selectedCount: found.count))
    }

    func testOrphanLeftoverProgressAndCancelMessageKeys() {
        XCTAssertEqual(AppOrphanLeftoverScanner.cancelledMessageKey, "已取消残留文件清理")
        XCTAssertTrue(AppOrphanLeftoverScanner.noneFoundMessageKey.contains("未发现可清理的残留文件"))
        XCTAssertEqual(AppOrphanLeftoverScanner.scanningProgressMessageKey, "正在查找残留文件…")
        XCTAssertEqual(AppOrphanLeftoverScanner.trashingProgressMessageKey, "正在移到废纸篓…")
        XCTAssertEqual(AppOrphanLeftoverScanner.recheckingProgressMessageKey, "正在确认安装状态…")
        XCTAssertNotEqual(AppOrphanLeftoverScanner.noneFoundMessageKey, "未发现可清理的残留文件",
                          "empty-state copy should explain matching scope")
    }

    func testRelatedCleanupProgressCancelAndSelectionStillValid() {
        XCTAssertEqual(AppRelatedFileScanner.scanningProgressMessageKey, "正在查找相关文件…")
        XCTAssertEqual(AppRelatedFileScanner.recheckingProgressMessageKey, "正在确认相关文件…")
        XCTAssertEqual(AppRelatedFileScanner.cancelledMessageKey, "已取消相关文件清理")
        XCTAssertTrue(AppRelatedFileScanner.changedBeforeTrashMessageKey.contains("未移到废纸篓"))
        let a = AppRelatedFileCandidate(
            url: URL(fileURLWithPath: "/tmp/Library/Caches/com.example.A"),
            kind: .caches, byteSize: 1
        )
        let b = AppRelatedFileCandidate(
            url: URL(fileURLWithPath: "/tmp/Library/Caches/com.example.B"),
            kind: .caches, byteSize: 1
        )
        XCTAssertTrue(AppRelatedFileScanner.relatedCleanupSelectionStillValid(selected: [], rediscovered: [a]))
        XCTAssertTrue(AppRelatedFileScanner.relatedCleanupSelectionStillValid(selected: [a], rediscovered: [a, b]))
        XCTAssertFalse(AppRelatedFileScanner.relatedCleanupSelectionStillValid(selected: [a, b], rediscovered: [a]))
    }

    func testPerformRefusesRelatedWhenPathIdentityChangesBeforeTrash() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-RelatedIdentityPerform-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("Keep.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.Keep"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let candidate = AppCandidate(
            canonicalURL: bundle, bundleIdentifier: "com.example.Keep",
            displayName: "Keep", sourcePriority: 0, discoveredAt: Date()
        )
        let bundleIdentity = try XCTUnwrap(AppUninstallEligibility.captureBundleIdentity(of: candidate))
        let relatedURL = library.appendingPathComponent("Caches/com.example.Keep", isDirectory: true)
        try FileManager.default.createDirectory(at: relatedURL, withIntermediateDirectories: true)
        let related = [AppRelatedFileCandidate(url: relatedURL, kind: .caches, byteSize: 1)]
        let relatedIdentity = try XCTUnwrap(AppUninstallEligibility.capturePathIdentity(of: relatedURL))
        // Swap the related directory inode while keeping the pathname.
        try FileManager.default.removeItem(at: relatedURL)
        try FileManager.default.createDirectory(at: relatedURL, withIntermediateDirectories: true)
        var trashCalls: [URL] = []
        let report = AppUninstallExecutor.perform(
            bundleURL: bundle,
            related: related,
            homeDirectory: home,
            expectedIdentity: bundleIdentity,
            expectedRelatedIdentities: [relatedIdentity],
            candidate: candidate,
            trash: { url in
                trashCalls.append(url)
                return url
            }
        )
        // Bundle may trash (identity OK); related must refuse identity mismatch.
        XCTAssertTrue(report.bundleTrashed)
        XCTAssertEqual(trashCalls.first, bundle)
        XCTAssertEqual(report.trashedRelated.count, 0)
        XCTAssertEqual(report.failedRelated.count, 1)
        XCTAssertEqual(report.failedRelated.first?.reason, AppUninstallFailureReason.identityMismatch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: relatedURL.path))
    }

    func testRelatedCleanupDefaultsToOptInSelection() {
        XCTAssertFalse(AppRelatedFileScanner.relatedCleanupDefaultSelected)
        XCTAssertFalse(AppRelatedFileScanner.relatedCleanupConfirmEnabled(selectedCount: 0))
        XCTAssertTrue(AppRelatedFileScanner.relatedCleanupConfirmEnabled(selectedCount: 1))
        XCTAssertTrue(AppRelatedFileScanner.relatedCleanupReviewMessageKey.contains("默认不选"))
        XCTAssertFalse(AppRelatedFileScanner.relatedCleanupReviewMessageKey.contains("默认全选"))
        XCTAssertTrue(AppRelatedFileScanner.relatedCleanupAlertCancelIsFirstButton)
        XCTAssertTrue(AppRelatedFileScanner.relatedCleanupRestoresLauncherFocusAfterSheet)
        XCTAssertEqual(
            AppRelatedFileScanner.relatedCleanupItemAccessibilityHelp(
                kindLabel: "缓存",
                sizeLabel: "1.2 MB"
            ),
            "缓存，1.2 MB"
        )
        XCTAssertEqual(
            AppRelatedFileScanner.relatedCleanupTrashAccessibilityHelp(selectedCount: 0),
            AppRelatedFileScanner.relatedCleanupTrashDisabledAccessibilityHelpKey
        )
        XCTAssertEqual(
            AppRelatedFileScanner.relatedCleanupTrashAccessibilityHelp(selectedCount: 2),
            AppRelatedFileScanner.relatedCleanupTrashEnabledAccessibilityHelpKey
        )
        XCTAssertEqual(
            AppRelatedFileScanner.relatedFilesToggleAccessibilityHelp(isEnabled: true),
            AppRelatedFileScanner.relatedFilesToggleAccessibilityHelpKey
        )
        XCTAssertEqual(
            AppRelatedFileScanner.relatedFilesToggleAccessibilityHelp(isEnabled: false),
            AppRelatedFileScanner.relatedFilesToggleDisabledAccessibilityHelpKey
        )
    }

    func testRelatedCleanupConfirmRequiresSelection() {
        XCTAssertFalse(AppRelatedFileScanner.relatedCleanupConfirmEnabled(selectedCount: 0))
        XCTAssertTrue(AppRelatedFileScanner.relatedCleanupConfirmEnabled(selectedCount: 1))
        XCTAssertEqual(AppRelatedFileScanner.selectedByteTotal(of: []), 0)
        XCTAssertEqual(
            AppRelatedFileScanner.formatByteSize(AppRelatedFileScanner.selectedByteTotal(of: [])),
            AppRelatedFileScanner.formatByteSize(0)
        )
    }

    // MARK: - Uninstall hardening (edge cases)

    func testUninstallCopyCheckIgnoresSamePathAndDetectsRegisteredSibling() {
        let target = sampleCandidate()
        let alias = URL(fileURLWithPath: target.canonicalURL.path + "/../Sample.app")
        let sibling = URL(fileURLWithPath: "/Users/other/Applications/Sample.app")
        let report = CatalogScanReport(candidates: [target], skippedPaths: [])
        XCTAssertFalse(AppUninstallEligibility.hasOtherCopy(
            of: target, in: report, registeredURLs: [alias]
        ))
        XCTAssertTrue(AppUninstallEligibility.hasOtherCopy(
            of: target, in: report, registeredURLs: [sibling]
        ))
    }

    func testUninstallProcessScopeKeepsOtherCopyAndIncludesNestedHelper() {
        let target = URL(fileURLWithPath: "/Applications/Sample.app")
        let other = URL(fileURLWithPath: "/Users/other/Applications/Sample.app")
        let helper = target.appendingPathComponent("Contents/Library/LoginItems/Helper.app")
        let executable = target.appendingPathComponent("Contents/MacOS/Sample")
        XCTAssertTrue(AppUninstallEligibility.runningProcessBelongsToTarget(
            bundleURL: target, executableURL: executable, targetURL: target
        ))
        XCTAssertTrue(AppUninstallEligibility.runningProcessBelongsToTarget(
            bundleURL: helper, executableURL: nil, targetURL: target
        ))
        XCTAssertTrue(AppUninstallEligibility.runningProcessBelongsToTarget(
            bundleURL: nil, executableURL: executable, targetURL: target
        ))
        XCTAssertFalse(AppUninstallEligibility.runningProcessBelongsToTarget(
            bundleURL: other, executableURL: other.appendingPathComponent("Contents/MacOS/Sample"), targetURL: target
        ))
        XCTAssertFalse(AppUninstallEligibility.runningProcessBelongsToTarget(
            bundleURL: URL(fileURLWithPath: "/Applications/Sample.app-copy"), executableURL: nil, targetURL: target
        ))
    }

    func testUninstallIdentityRejectsReplacedBundleAtSamePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchIcon-UninstallIdentity-\(UUID())")
        let app = root.appendingPathComponent("Selected.app")
        func install(_ bundleID: String) throws {
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = ["CFBundleIdentifier": bundleID]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try install("com.example.Selected")
        let candidate = AppCandidate(canonicalURL: app, bundleIdentifier: "com.example.Selected",
                                     displayName: "Selected", sourcePriority: 0, discoveredAt: .now)
        let identity = try XCTUnwrap(AppUninstallEligibility.captureBundleIdentity(of: candidate))
        XCTAssertTrue(AppUninstallEligibility.matchesBundleIdentity(identity, of: candidate))
        try FileManager.default.removeItem(at: app)
        try install("com.example.Replacement")
        XCTAssertFalse(AppUninstallEligibility.matchesBundleIdentity(identity, of: candidate))
        try FileManager.default.removeItem(at: app)
        try install("com.example.Selected")
        XCTAssertFalse(AppUninstallEligibility.matchesBundleIdentity(identity, of: candidate),
                       "A new physical copy with the same ID must require a fresh confirmation")
    }

    func testUninstallSafetyScanFindsHiddenCopyWithinRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchIcon-HiddenCopy-\(UUID())")
        let visible = root.appendingPathComponent("Visible.app")
        let hidden = root.appendingPathComponent(".Archive/Hidden.app")
        defer { try? FileManager.default.removeItem(at: root) }
        for app in [visible, hidden] {
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "com.example.Copy"], format: .xml, options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let report = await AppCatalogScanner().scanIncludingHiddenApplications(roots: [root])
        let physicalCopies = report.candidates + report.duplicateCandidates
        let visibleURL = visible.resolvingSymlinksInPath().standardizedFileURL
        let hiddenURL = hidden.resolvingSymlinksInPath().standardizedFileURL
        let target = try XCTUnwrap(physicalCopies.first { $0.canonicalURL == visibleURL })
        XCTAssertTrue(physicalCopies.contains { $0.canonicalURL == hiddenURL })
        XCTAssertTrue(AppUninstallEligibility.hasOtherCopy(of: target, in: report, registeredURLs: []))
    }

    private func makeUninstallHome() throws -> (home: URL, library: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-UninstallHome-\(UUID().uuidString)", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return (home, library)
    }

    private func sampleCandidate(bundleID: String? = "com.example.Sample", name: String = "Sample") -> AppCandidate {
        AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            bundleIdentifier: bundleID,
            displayName: name,
            sourcePriority: 0,
            discoveredAt: Date()
        )
    }

    func testBundleIDMatchingUsesTokenBoundariesNotSubstrings() {
        let id = "com.example.Sample"
        XCTAssertTrue(AppRelatedFileScanner.nameMatchesBundleID("com.example.Sample", bundleID: id, allowsTeamPrefix: false))
        XCTAssertTrue(AppRelatedFileScanner.nameMatchesBundleID("COM.EXAMPLE.SAMPLE", bundleID: id, allowsTeamPrefix: false))
        XCTAssertTrue(AppRelatedFileScanner.nameMatchesBundleID("com.example.Sample.helper.plist", bundleID: id, allowsTeamPrefix: false))
        XCTAssertTrue(AppRelatedFileScanner.nameMatchesBundleID("ABCD.com.example.Sample", bundleID: id, allowsTeamPrefix: true))
        XCTAssertFalse(AppRelatedFileScanner.nameMatchesBundleID("ABCD.com.example.Sample", bundleID: id, allowsTeamPrefix: false))
        XCTAssertFalse(AppRelatedFileScanner.nameMatchesBundleID("com.example.Sample2", bundleID: id, allowsTeamPrefix: true))
        XCTAssertFalse(AppRelatedFileScanner.nameMatchesBundleID("com.example.SampleOther", bundleID: id, allowsTeamPrefix: true))
        XCTAssertFalse(AppRelatedFileScanner.nameMatchesBundleID("xcom.example.Sample", bundleID: id, allowsTeamPrefix: true))
        // Two-component IDs match exactly only.
        XCTAssertTrue(AppRelatedFileScanner.nameMatchesBundleID("md.obsidian", bundleID: "md.obsidian", allowsTeamPrefix: true))
        XCTAssertFalse(AppRelatedFileScanner.nameMatchesBundleID("md.obsidian.helper", bundleID: "md.obsidian", allowsTeamPrefix: true))
    }

    func testUsableBundleIDRejectsTraversalAndGenericTokens() {
        XCTAssertNil(AppRelatedFileScanner.usableBundleID("../../Documents"))
        XCTAssertNil(AppRelatedFileScanner.usableBundleID("com.example/../x"))
        XCTAssertNil(AppRelatedFileScanner.usableBundleID("single"))
        XCTAssertNil(AppRelatedFileScanner.usableBundleID("a.b"))
        XCTAssertNil(AppRelatedFileScanner.usableBundleID("com..example"))
        XCTAssertNil(AppRelatedFileScanner.usableBundleID("   "))
        XCTAssertNil(AppRelatedFileScanner.usableBundleID(nil))
        XCTAssertEqual(AppRelatedFileScanner.usableBundleID(" com.example.Sample "), "com.example.Sample")
        XCTAssertEqual(AppRelatedFileScanner.usableBundleID("md.obsidian"), "md.obsidian")
    }

    func testScannerDoesNotMatchSiblingBundleIDsInGroupContainersOrAgents() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        for name in ["Group Containers/TEAM.com.example.Sample", "Group Containers/TEAM.com.example.Sample2",
                     "Group Containers/group.com.example.SampleOther"] {
            try fm.createDirectory(at: library.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let agents = library.appendingPathComponent("LaunchAgents", isDirectory: true)
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: agents.appendingPathComponent("com.example.Sample.agent.plist"))
        try Data("x".utf8).write(to: agents.appendingPathComponent("com.example.Sample2.agent.plist"))
        let found = AppRelatedFileScanner.discover(candidate: sampleCandidate(), homeDirectory: home)
        let names = Set(found.map(\.url.lastPathComponent))
        XCTAssertEqual(names, ["TEAM.com.example.Sample", "com.example.Sample.agent.plist"])
    }

    func testScannerRejectsGenericAndVendorPackageNameFallbacks() throws {
        for name in ["Google", "Microsoft", "Adobe", "Mozilla", "Apple", "Support", "Chrome"] {
            XCTAssertFalse(AppRelatedFileScanner.isSafePackageNameFallback(name), name)
        }
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Application Support/Google", isDirectory: true),
            withIntermediateDirectories: true
        )
        let candidate = sampleCandidate(bundleID: nil, name: "Google")
        XCTAssertTrue(AppRelatedFileScanner.discover(candidate: candidate, homeDirectory: home).isEmpty)
    }

    func testScannerNeverFollowsSymlinksOutOfLibrary() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let precious = home.appendingPathComponent("Documents/Precious", isDirectory: true)
        try fm.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: precious.appendingPathComponent("a.txt"))
        let caches = library.appendingPathComponent("Caches", isDirectory: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let link = caches.appendingPathComponent("com.example.Sample")
        try fm.createSymbolicLink(at: link, withDestinationURL: precious)

        XCTAssertTrue(AppRelatedFileScanner.discover(candidate: sampleCandidate(), homeDirectory: home).isEmpty)
        XCTAssertFalse(AppRelatedFileSafety.isSafeToTrash(link, homeDirectory: home))

        // Even if a stale checklist still carries the link, execution refuses it.
        let stale = AppRelatedFileCandidate(url: link, kind: .caches, byteSize: 1)
        var trashCalls: [URL] = []
        let moved = AppUninstallExecutor.trashRelated(
            [stale],
            homeDirectory: home,
            trash: { url in
                trashCalls.append(url)
                return url
            }
        )
        XCTAssertTrue(trashCalls.isEmpty)
        XCTAssertTrue(moved.trashed.isEmpty)
        XCTAssertEqual(moved.failed.first?.reason, AppUninstallFailureReason.unsafePath)
        XCTAssertTrue(fm.fileExists(atPath: precious.appendingPathComponent("a.txt").path))
    }

    func testRelatedSafetyRejectsPathsOutsideLibraryAndWholeCategories() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertFalse(AppRelatedFileSafety.isSafeToTrash(home.appendingPathComponent("Documents/x"), homeDirectory: home))
        XCTAssertFalse(AppRelatedFileSafety.isSafeToTrash(URL(fileURLWithPath: "/Applications/Foo.app"), homeDirectory: home))
        XCTAssertFalse(AppRelatedFileSafety.isSafeToTrash(library, homeDirectory: home))
        XCTAssertFalse(AppRelatedFileSafety.isSafeToTrash(library.appendingPathComponent("Caches"), homeDirectory: home))
        XCTAssertFalse(AppRelatedFileSafety.isSafeToTrash(
            library.appendingPathComponent("Caches/../../Documents/x"), homeDirectory: home))
        XCTAssertTrue(AppRelatedFileSafety.isSafeToTrash(
            library.appendingPathComponent("Caches/com.example.Sample"), homeDirectory: home))
    }

    private struct FakeTrashError: Error {}

    func testExecutorAbortsWhenIdentityChangesBeforeTrash() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-TrashIdentity-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("Swap.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func install(_ id: String) throws {
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": id]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try install("com.example.Original")
        let candidate = AppCandidate(
            canonicalURL: bundle, bundleIdentifier: "com.example.Original",
            displayName: "Swap", sourcePriority: 0, discoveredAt: Date()
        )
        let identity = try XCTUnwrap(AppUninstallEligibility.captureBundleIdentity(of: candidate))
        let relatedURL = library.appendingPathComponent("Caches/com.example.Original", isDirectory: true)
        try FileManager.default.createDirectory(at: relatedURL, withIntermediateDirectories: true)
        let related = [AppRelatedFileCandidate(url: relatedURL, kind: .caches, byteSize: 1)]
        // Replace the physical directory while keeping the pathname.
        try FileManager.default.removeItem(at: bundle)
        try install("com.example.Original")
        var trashCalls: [URL] = []
        let report = AppUninstallExecutor.perform(
            bundleURL: bundle,
            related: related,
            homeDirectory: home,
            expectedIdentity: identity,
            candidate: candidate,
            trash: { url in
                trashCalls.append(url)
                return url
            }
        )
        XCTAssertEqual(report.outcome, AppUninstallOutcome.bundleFailed)
        XCTAssertEqual(report.bundleFailure?.reason, AppUninstallFailureReason.identityMismatch)
        XCTAssertTrue(trashCalls.isEmpty, "identity mismatch must refuse before any trashItem")
        XCTAssertTrue(FileManager.default.fileExists(atPath: relatedURL.path))
    }

    func testExecutorCancelBeforeTrashLeavesEverything() throws {
        let (home, _) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var calls = 0
        let report = AppUninstallExecutor.perform(
            bundleURL: URL(fileURLWithPath: "/Applications/Sample.app"),
            related: [],
            homeDirectory: home,
            trash: { url in
                calls += 1
                return url
            },
            isCancelled: { true }
        )
        XCTAssertEqual(report.outcome, AppUninstallOutcome.bundleFailed)
        XCTAssertEqual(report.bundleFailure?.reason, AppUninstallFailureReason.cancelled)
        XCTAssertEqual(calls, 0)
    }

    func testExecutorCancelMidRelatedAccountsForRemainder() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var related: [AppRelatedFileCandidate] = []
        for name in ["Caches/com.example.Sample", "Application Support/com.example.Sample", "Logs/com.example.Sample"] {
            let url = library.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            related.append(AppRelatedFileCandidate(url: url, kind: .caches, byteSize: 1))
        }
        var calls = 0
        let report = AppUninstallExecutor.perform(
            bundleURL: URL(fileURLWithPath: "/Applications/Sample.app"),
            related: related,
            homeDirectory: home,
            trash: { url in
                calls += 1
                return url
            },
            isCancelled: {
                // Cancel after the bundle and the first related item succeed.
                calls >= 2
            }
        )
        XCTAssertTrue(report.bundleTrashed)
        XCTAssertEqual(report.trashedRelated.count, 1)
        XCTAssertEqual(report.failedRelated.count, 2)
        XCTAssertTrue(report.failedRelated.allSatisfy { $0.reason == AppUninstallFailureReason.cancelled })
        XCTAssertEqual(report.trashedRelated.count + report.failedRelated.count, related.count)
    }

    func testPathIdentityRejectsReplacedRelatedFile() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = library.appendingPathComponent("Caches/com.example.Sample", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let identity = try XCTUnwrap(AppUninstallEligibility.capturePathIdentity(of: url))
        XCTAssertTrue(AppUninstallEligibility.matchesPathIdentity(identity))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertFalse(AppUninstallEligibility.matchesPathIdentity(identity))

        let stale = AppRelatedFileCandidate(url: url, kind: .caches, byteSize: 1)
        var calls = 0
        let moved = AppUninstallExecutor.trashRelated(
            [stale],
            homeDirectory: home,
            expectedIdentities: [identity],
            trash: { url in
                calls += 1
                return url
            }
        )
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(moved.trashed.isEmpty)
        XCTAssertEqual(moved.failed.first?.reason, AppUninstallFailureReason.identityMismatch)
    }

    func testTrashRelatedRequiresSnapshotWhenIdentitiesProvided() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = library.appendingPathComponent("Caches/com.example.Sample", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let other = library.appendingPathComponent("Caches/com.example.Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let identity = try XCTUnwrap(AppUninstallEligibility.capturePathIdentity(of: url))
        let moved = AppUninstallExecutor.trashRelated(
            [AppRelatedFileCandidate(url: other, kind: .caches, byteSize: 1)],
            homeDirectory: home,
            expectedIdentities: [identity],
            trash: { $0 }
        )
        XCTAssertTrue(moved.trashed.isEmpty)
        XCTAssertEqual(moved.failed.first?.reason, AppUninstallFailureReason.identityMismatch)
    }

    func testExecutorReportsPartialRelatedFailuresWithoutSilentLoss() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        var related: [AppRelatedFileCandidate] = []
        for name in ["Caches/com.example.Sample", "Application Support/com.example.Sample", "Logs/com.example.Sample"] {
            let url = library.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            related.append(AppRelatedFileCandidate(url: url, kind: .caches, byteSize: 10))
        }
        let bundle = URL(fileURLWithPath: "/Applications/Sample.app")
        var calls: [String] = []
        let report = AppUninstallExecutor.perform(
            bundleURL: bundle, related: related, homeDirectory: home,
            trash: { url in
                calls.append(url.path)
                if url.path.contains("Application Support") {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
                }
                if url.path.contains("/Logs/") { throw FakeTrashError() }
                return url
            }
        )
        XCTAssertTrue(report.bundleTrashed)
        XCTAssertEqual(report.outcome, .partialRelated)
        XCTAssertEqual(report.trashedRelated.count, 1)
        XCTAssertEqual(report.failedRelated.count, 2)
        XCTAssertEqual(
            Set(report.failedRelated.map(\.reason)), [.permissionDenied, .other]
        )
        // Every selected item was attempted: trashed + failed == selected.
        XCTAssertEqual(report.trashedRelated.count + report.failedRelated.count, related.count)
        XCTAssertEqual(report.failureLines.count, 2)
        XCTAssertEqual(calls.first, bundle.path, "bundle moves first")
    }

    func testExecutorLeavesRelatedFilesUntouchedWhenBundleCannotMove() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = library.appendingPathComponent("Caches/com.example.Sample", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var calls = 0
        let report = AppUninstallExecutor.perform(
            bundleURL: URL(fileURLWithPath: "/Applications/Sample.app"),
            related: [AppRelatedFileCandidate(url: url, kind: .caches, byteSize: 1)],
            homeDirectory: home,
            trash: { _ in
                calls += 1
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            }
        )
        XCTAssertEqual(calls, 1, "related files must not be attempted after bundle failure")
        XCTAssertEqual(report.outcome, AppUninstallOutcome.bundleFailed)
        XCTAssertEqual(report.bundleFailure?.reason, AppUninstallFailureReason.permissionDenied)
        XCTAssertTrue(report.trashedRelated.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testUninstallOutcomeMappingAndUndoHint() {
        let url = URL(fileURLWithPath: "/tmp/x")
        let fail = AppUninstallFailure(url: url, reason: .other, detail: "d")
        XCTAssertEqual(AppUninstallReport(bundleTrashed: true, bundleFailure: nil, trashedRelated: [], failedRelated: []).outcome, .bundleOnly)
        XCTAssertEqual(AppUninstallReport(bundleTrashed: true, bundleFailure: nil, trashedRelated: [url], failedRelated: []).outcome, .bundleAndAllRelated)
        XCTAssertEqual(AppUninstallReport(bundleTrashed: true, bundleFailure: nil, trashedRelated: [url], failedRelated: [fail]).outcome, .partialRelated)
        XCTAssertEqual(AppUninstallReport(bundleTrashed: false, bundleFailure: fail, trashedRelated: [], failedRelated: []).outcome, .bundleFailed)
        XCTAssertTrue(AppUninstallReport.undoHintKey.contains("废纸篓"))
        XCTAssertEqual(AppUninstallFailureReason.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)), .permissionDenied)
        XCTAssertEqual(AppUninstallFailureReason.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))), .permissionDenied)
        XCTAssertEqual(AppUninstallFailureReason.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)), .missing)
        let wrapped = NSError(domain: "X", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        XCTAssertEqual(AppUninstallFailureReason.classify(wrapped), .permissionDenied)
        XCTAssertEqual(AppUninstallFailureReason.classify(FakeTrashError()), .other)
    }

    func testForgetUninstalledApplicationRemovesFolderMembershipEverywhere() {
        let key = "bundle:com.example.Sample"
        let other = "bundle:com.example.Other"
        let a = UUID(), b = UUID(), c = UUID(), folderID = UUID()
        var state = LayoutState(
            orderedEntries: [.app(a), .folder(folderID), .app(c)],
            folders: [folderID: LauncherFolder(id: folderID, name: "F", itemIDs: [b, c], createdAt: Date())],
            appKeys: [a: key, b: key, c: other],
            hiddenAppKeys: [key],
            appAliases: [key: "别名"],
            updatedAt: Date()
        )
        state = LauncherLayout.forgetUninstalledApplication(withKey: key, in: state)
        XCTAssertFalse(state.appKeys.values.contains(key))
        XCTAssertFalse(state.orderedEntries.contains(.app(a)))
        XCTAssertFalse(state.folders.values.contains { $0.itemIDs.contains(b) })
        XCTAssertTrue(state.hiddenAppKeys.isEmpty)
        XCTAssertTrue(state.appAliases.isEmpty)
        // The other app survives.
        XCTAssertEqual(state.appKeys[c], other)
        // Reconciling with a catalog that no longer has the app must not resurrect it.
        let remaining = [AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Other.app"),
            bundleIdentifier: "com.example.Other",
            displayName: "Other", sourcePriority: 0, discoveredAt: Date()
        )]
        let reconciled = LauncherLayout.reconcile(candidates: remaining, into: state)
        XCTAssertFalse(reconciled.appKeys.values.contains(key))
        XCTAssertFalse(reconciled.hiddenAppKeys.contains(key))
    }

    func testUninstallBlockedWhenEditingTurnsOffOrBundleVanishesAfterConfirm() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-UninstallRecheck-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("Recheck.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = AppCandidate(
            canonicalURL: bundle, bundleIdentifier: "com.example.Recheck",
            displayName: "Recheck", sourcePriority: 0, discoveredAt: Date()
        )
        func decide(editing: Bool) -> AppUninstallDecision {
            AppUninstallEligibility.evaluate(
                candidate: candidate, layoutEditingEnabled: editing,
                selfBundleURL: nil, selfBundleIdentifier: nil, isSandboxed: false
            )
        }
        XCTAssertTrue(decide(editing: true).isAllowed)
        // Scan restarts while the sheet is up -> editing off -> re-check blocks.
        XCTAssertEqual(decide(editing: false).blockReason, .layoutEditingDisabled)
        XCTAssertEqual(
            AppUninstallEligibility.menuPresentation(layoutEditingEnabled: false, decision: decide(editing: false)),
            .disabled(explanationKey: "暂时无法整理应用，请先完成扫描")
        )
        // Bundle removed while the sheet is up -> re-check blocks.
        try FileManager.default.removeItem(at: bundle)
        XCTAssertEqual(decide(editing: true).blockReason, .missingBundle)
    }

    func testSandboxedBuildExplainsInsteadOfUninstalling() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-UninstallSandbox-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("Boxed.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = AppCandidate(
            canonicalURL: bundle, bundleIdentifier: "com.example.Boxed",
            displayName: "Boxed", sourcePriority: 0, discoveredAt: Date()
        )
        let decision = AppUninstallEligibility.evaluate(
            candidate: candidate, layoutEditingEnabled: true,
            selfBundleURL: nil, selfBundleIdentifier: nil, isSandboxed: true
        )
        XCTAssertFalse(decision.isAllowed)
        XCTAssertEqual(decision.blockReason, .sandboxedBuild)
        XCTAssertEqual(decision.explanationKey, AppUninstallPlatform.sandboxedExplanationKey)
        XCTAssertEqual(
            AppUninstallEligibility.menuPresentation(layoutEditingEnabled: true, decision: decision),
            .disabled(explanationKey: AppUninstallPlatform.sandboxedExplanationKey)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertTrue(AppUninstallPlatform.isSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": "com.example.Boxed"]))
        XCTAssertFalse(AppUninstallPlatform.isSandboxed(environment: [:]))
        XCTAssertFalse(AppUninstallPlatform.isSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": ""]))
        XCTAssertFalse(AppUninstallPlatform.orphanCleanupAvailable(isSandboxed: true))
        XCTAssertTrue(AppUninstallPlatform.orphanCleanupAvailable(isSandboxed: false))
    }

    func testOrphanLeftoverScannerFindsOnlyUninstalledBundleIDItems() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        func dir(_ rel: String, bytes: Int = 0) throws {
            let url = library.appendingPathComponent(rel, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            if bytes > 0 { try Data(repeating: 1, count: bytes).write(to: url.appendingPathComponent("f.bin")) }
        }
        try dir("Application Support/com.gone.Old", bytes: 50_000)   // 3 components -> orphan
        try dir("Caches/com.gone.Old", bytes: 100)
        try dir("Saved Application State/com.gone.Old.savedState")
        try dir("Application Support/com.keep.Present")              // installed
        try dir("Caches/com.keep.Present.helper")                    // installed helper
        try dir("Caches/com.keep.OtherProduct")                      // vendor shared with installed app
        try dir("Application Support/com.apple.Safari")              // Apple
        try dir("Application Support/Random Folder")                 // not a bundle ID
        try dir("Application Support/gone.tiny")                     // 2 components
        try dir("Application Support/com.running.Elsewhere")         // installed outside scan roots
        let prefs = library.appendingPathComponent("Preferences", isDirectory: true)
        try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: prefs.appendingPathComponent("com.gone.Old.plist"))
        // Symlink named like an orphan must never be offered.
        let outside = home.appendingPathComponent("Documents/Keep", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: library.appendingPathComponent("Caches/com.gone.Linked"), withDestinationURL: outside
        )

        let found = AppOrphanLeftoverScanner.discover(
            homeDirectory: home,
            installedBundleIdentifiers: ["com.keep.Present"],
            isInstalledElsewhere: { $0 == "com.running.Elsewhere" }
        )
        let names = found.map(\.url.lastPathComponent)
        XCTAssertEqual(Set(names), ["com.gone.Old", "com.gone.Old.savedState", "com.gone.Old.plist"])
        XCTAssertEqual(found.count, 4) // Application Support + Caches both named com.gone.Old
        XCTAssertEqual(found.first?.kind, .applicationSupport, "size-descending order")
        XCTAssertTrue(found.allSatisfy { AppRelatedFileSafety.isSafeToTrash($0.url, homeDirectory: home) })
        XCTAssertEqual(AppRelatedFileScanner.selectedByteTotal(of: found), found.reduce(0) { $0 + ($1.byteSize ?? 0) })
        // Empty installed set must not widen to Apple / short IDs.
        let all = AppOrphanLeftoverScanner.discover(homeDirectory: home, installedBundleIdentifiers: [])
        XCTAssertFalse(all.contains { $0.url.lastPathComponent.contains("apple") })
        XCTAssertFalse(all.contains { $0.url.lastPathComponent == "gone.tiny" })
        XCTAssertNil(AppOrphanLeftoverScanner.candidateOrphanBundleID("com.apple.Safari"))
        XCTAssertNil(AppOrphanLeftoverScanner.candidateOrphanBundleID("group.com.foo.bar"))
        XCTAssertNil(AppOrphanLeftoverScanner.candidateOrphanBundleID("../com.foo.bar"))
    }

    func testRelatedAndOrphanScannersDoNotSizeContainerContents() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let container = library.appendingPathComponent("Containers/com.example.Sample", isDirectory: true)
        let group = library.appendingPathComponent("Group Containers/TEAM.com.example.Sample", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: container.appendingPathComponent("private.bin"))
        try Data(repeating: 1, count: 2048).write(to: group.appendingPathComponent("private.bin"))

        let candidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Sample.app"),
            bundleIdentifier: "com.example.Sample", displayName: "Sample",
            sourcePriority: 0, discoveredAt: Date()
        )
        let related = AppRelatedFileScanner.discover(candidate: candidate, homeDirectory: home)
        XCTAssertNotNil(related.first(where: { $0.kind == .containers }))
        XCTAssertNotNil(related.first(where: { $0.kind == .groupContainers }))
        XCTAssertNil(related.first(where: { $0.kind == .containers })?.byteSize)
        XCTAssertNil(related.first(where: { $0.kind == .groupContainers })?.byteSize)

        let orphans = AppOrphanLeftoverScanner.discover(homeDirectory: home, installedBundleIdentifiers: [])
        XCTAssertNotNil(orphans.first(where: { $0.kind == .containers }))
        XCTAssertNil(orphans.first(where: { $0.kind == .containers })?.byteSize)
    }

    func testOrphanLeftoverScannerStopsWhenCancelled() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Application Support/com.example.Sample", isDirectory: true),
            withIntermediateDirectories: true
        )
        var checks = 0
        let found = AppOrphanLeftoverScanner.discover(
            homeDirectory: home,
            installedBundleIdentifiers: [],
            isCancelled: {
                checks += 1
                return checks >= 2
            }
        )
        XCTAssertTrue(found.isEmpty)
        XCTAssertGreaterThanOrEqual(checks, 2)
    }

    func testRelatedFileScannerStopsWhenCancelled() throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Application Support/com.example.Sample", isDirectory: true),
            withIntermediateDirectories: true
        )
        let candidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Sample.app"),
            bundleIdentifier: "com.example.Sample", displayName: "Sample",
            sourcePriority: 0, discoveredAt: Date()
        )
        var checks = 0
        let found = AppRelatedFileScanner.discover(
            candidate: candidate, homeDirectory: home,
            isCancelled: {
                checks += 1
                return checks >= 2
            }
        )
        XCTAssertTrue(found.isEmpty)
        XCTAssertGreaterThanOrEqual(checks, 2)
    }

    func testOrphanRecheckExcludesAppInstalledAfterInitialDiscovery() async throws {
        let (home, library) = try makeUninstallHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let leftover = library.appendingPathComponent("Application Support/com.example.Returned", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let initial = AppOrphanLeftoverScanner.discover(
            homeDirectory: home, installedBundleIdentifiers: []
        )
        XCTAssertEqual(initial.map(\.url), [leftover])

        let appRoot = home.appendingPathComponent("Applications", isDirectory: true)
        let contents = appRoot.appendingPathComponent("Returned.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.example.Returned", "CFBundleName": "Returned"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let currentCatalog = await AppCatalogScanner().scan(roots: [appRoot])
        XCTAssertTrue(currentCatalog.canPersistReconciledLayout)
        let installedIDs = Set(currentCatalog.candidates.compactMap(\.bundleIdentifier))
        let rechecked = AppOrphanLeftoverScanner.discover(
            homeDirectory: home, installedBundleIdentifiers: installedIDs
        )
        XCTAssertTrue(rechecked.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))
    }

    func testAppRelatedFileScannerOrdersByDescendingSize() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-RelatedSizeOrder-\(UUID().uuidString)", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support/com.example.Sample", isDirectory: true)
        let prefs = library.appendingPathComponent("Preferences/com.example.Sample.plist", isDirectory: false)
        let caches = library.appendingPathComponent("Caches/com.example.Sample", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Small prefs vs larger support payload so size-desc order is deterministic.
        try Data(repeating: 1, count: 32).write(to: prefs)
        try Data(repeating: 2, count: 120_000).write(to: support.appendingPathComponent("payload.bin"))
        try Data(repeating: 3, count: 4_000).write(to: caches.appendingPathComponent("cache.bin"))
        defer { try? FileManager.default.removeItem(at: home) }

        let candidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Sample.app"),
            bundleIdentifier: "com.example.Sample",
            displayName: "Sample",
            sourcePriority: 0,
            discoveredAt: Date()
        )
        let found = AppRelatedFileScanner.discover(candidate: candidate, homeDirectory: home)
        XCTAssertEqual(found.count, 3)
        let sizes = found.map { $0.byteSize ?? 0 }
        XCTAssertEqual(sizes, sizes.sorted(by: >), "discover should return size-descending order")
        XCTAssertEqual(found.first?.kind, .applicationSupport)
        XCTAssertEqual(found.last?.kind, .preferences)
        XCTAssertEqual(
            AppRelatedFileScanner.selectedByteTotal(of: found),
            sizes.reduce(0, +)
        )
        XCTAssertEqual(AppRelatedFileScanner.selectedByteTotal(of: Array(found.dropFirst())), sizes.dropFirst().reduce(0, +))
    }

    func testAppRelatedFileScannerFindsUserLaunchAgentByBundleID() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchIcon-RelatedAgents-\(UUID().uuidString)", isDirectory: true)
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent("com.example.Sample.helper.plist")
        try Data("<?=xml?>".utf8).write(to: plist)
        defer { try? FileManager.default.removeItem(at: home) }

        let candidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Sample.app"),
            bundleIdentifier: "com.example.Sample",
            displayName: "Sample",
            sourcePriority: 0,
            discoveredAt: Date()
        )
        let found = AppRelatedFileScanner.discover(candidate: candidate, homeDirectory: home)
        XCTAssertTrue(found.contains(where: { $0.kind == .launchAgents }))
        XCTAssertEqual(AppRelatedFileScanner.formatByteSize(nil), "—")
        XCTAssertFalse(AppRelatedFileScanner.formatByteSize(2_000_000).isEmpty)
    }

    func testAppUninstallRunningMatchUsesBundleIDOrPath() {
        let candidate = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Sample.app"),
            bundleIdentifier: "com.example.Sample",
            displayName: "Sample",
            sourcePriority: 0,
            discoveredAt: Date()
        )
        XCTAssertTrue(
            AppRelatedFileScanner.isRunning(
                candidate: candidate,
                runningBundleIdentifiers: ["com.example.Sample"],
                runningBundlePaths: []
            )
        )
        XCTAssertTrue(
            AppRelatedFileScanner.isRunning(
                candidate: candidate,
                runningBundleIdentifiers: [],
                runningBundlePaths: ["/Applications/Sample.app"]
            )
        )
        XCTAssertFalse(
            AppRelatedFileScanner.isRunning(
                candidate: candidate,
                runningBundleIdentifiers: ["com.other"],
                runningBundlePaths: ["/Applications/Other.app"]
            )
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

    func testCachedCatalogIsReplacedOnlyByCompleteScan() {
        XCTAssertTrue(LauncherLayout.shouldReplaceCachedCatalog(isShowingCache: false, newScanPersistable: false))
        XCTAssertTrue(LauncherLayout.shouldReplaceCachedCatalog(isShowingCache: false, newScanPersistable: true))
        XCTAssertFalse(LauncherLayout.shouldReplaceCachedCatalog(isShowingCache: true, newScanPersistable: false))
        XCTAssertTrue(LauncherLayout.shouldReplaceCachedCatalog(isShowingCache: true, newScanPersistable: true))
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

    func testFlyerSlideAnimationKeyIsDistinctFromPageHostKeys() {
        XCTAssertEqual(LauncherLayout.flyerSlideAnimationKey, "flyer-slide")
        XCTAssertNotEqual(
            LauncherLayout.flyerSlideAnimationKey,
            LauncherLayout.pageHostSlideAnimationKey
        )
        XCTAssertNotEqual(
            LauncherLayout.flyerSlideAnimationKey,
            LauncherLayout.pageHostFadeAnimationKey
        )
    }

    func testPageHostSlideAnimationKeyIsDistinctFromFade() {
        XCTAssertEqual(LauncherLayout.pageHostFadeAnimationKey, "page-host-fade")
        XCTAssertEqual(LauncherLayout.pageHostSlideAnimationKey, "page-host-slide")
        XCTAssertNotEqual(
            LauncherLayout.pageHostFadeAnimationKey,
            LauncherLayout.pageHostSlideAnimationKey
        )
    }

    func testFolderTitleStaysHiddenUntilChromeLands() {
        XCTAssertTrue(
            LauncherLayout.folderTitlePointerEditingAvailable(
                isAnimatingClose: false,
                panelAnimationKeys: []
            )
        )
        XCTAssertFalse(
            LauncherLayout.folderTitlePointerEditingAvailable(
                isAnimatingClose: true,
                panelAnimationKeys: []
            )
        )
        // Scale flight (full motion) and fade-only (reduced motion) both block.
        for key in ["folderOpenScale", "folderCloseScale", "folderOpenFade", "folderCloseFade"] {
            XCTAssertFalse(
                LauncherLayout.folderTitlePointerEditingAvailable(
                    isAnimatingClose: false,
                    panelAnimationKeys: [key]
                ),
                key
            )
        }
        XCTAssertTrue(
            LauncherLayout.folderTitlePointerEditingAvailable(
                isAnimatingClose: false,
                panelAnimationKeys: ["unrelated"]
            )
        )
        // AX: keyboard editor stays exposed; idle title waits for chrome.
        XCTAssertFalse(
            LauncherLayout.folderTitleAccessibilityHidden(
                baseHidden: false,
                hasFieldEditor: true,
                pointerEditingAvailable: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.folderTitleAccessibilityHidden(
                baseHidden: false,
                hasFieldEditor: false,
                pointerEditingAvailable: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.folderTitleAccessibilityHidden(
                baseHidden: false,
                hasFieldEditor: false,
                pointerEditingAvailable: true
            )
        )
        XCTAssertEqual(
            LauncherLayout.folderTitleBlockingChromeAnimationKeys,
            Set(["folderOpenScale", "folderCloseScale", "folderOpenFade", "folderCloseFade"])
        )
    }

    func testFolderTitleKeyboardFocusWaitsForChrome() {
        XCTAssertFalse(
            LauncherLayout.folderTitleKeyboardFocusAvailable(
                hasFieldEditor: false,
                pointerEditingAvailable: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.folderTitleKeyboardFocusAvailable(
                hasFieldEditor: false,
                pointerEditingAvailable: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.folderTitleKeyboardFocusAvailable(
                hasFieldEditor: true,
                pointerEditingAvailable: false
            )
        )
    }


    func testFolderMemberFocusFillWaitsForPanelChrome() {
        XCTAssertTrue(
            LauncherLayout.folderPanelChromeInFlight(
                isAnimatingClose: false,
                panelAnimationKeys: ["folderOpenFade"]
            )
        )
        XCTAssertTrue(
            LauncherLayout.folderPanelChromeInFlight(
                isAnimatingClose: false,
                panelAnimationKeys: ["folderOpenScale"]
            )
        )
        XCTAssertTrue(
            LauncherLayout.folderPanelChromeInFlight(
                isAnimatingClose: true,
                panelAnimationKeys: []
            )
        )
        XCTAssertFalse(
            LauncherLayout.folderPanelChromeInFlight(
                isAnimatingClose: false,
                panelAnimationKeys: ["folderOpenCorner"]
            )
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlpha(
                isLaunching: false,
                isDropTarget: false,
                focused: true,
                folderPanelChromeInFlight: true
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillAlpha(
                isLaunching: false,
                isDropTarget: false,
                focused: true,
                folderPanelChromeInFlight: false
            ),
            LauncherLayout.tileChromeFocusAlpha,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.folderOpenFocusHandoff(owner: .outsideOverlay),
            .focusFirstMember
        )
        XCTAssertEqual(
            LauncherLayout.folderOpenFocusHandoff(owner: .otherOverlayChrome),
            .focusFirstMember
        )
        XCTAssertEqual(
            LauncherLayout.folderOpenFocusHandoff(owner: .memberTile),
            .refreshMemberChrome
        )
        XCTAssertEqual(
            LauncherLayout.folderOpenFocusHandoff(owner: .titleOrClose),
            .preserveControl
        )
        XCTAssertTrue(
            LauncherLayout.folderCloseShouldRestoreGridFocusOnChromeLand(
                restoreFocusRequested: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.folderCloseShouldRestoreGridFocusOnChromeLand(
                restoreFocusRequested: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.folderOverlayKeyboardFocusAvailable(panelChromeInFlight: true)
        )
        XCTAssertTrue(
            LauncherLayout.folderOverlayKeyboardFocusAvailable(panelChromeInFlight: false)
        )
        XCTAssertFalse(
            LauncherLayout.folderOverlayKeyViewsShouldIncludeControls(isAnimatingClose: true)
        )
        XCTAssertTrue(
            LauncherLayout.folderOverlayKeyViewsShouldIncludeControls(isAnimatingClose: false)
        )
    }



    func testFolderEmptyFocusesTitleNotEmptyCollection() {
        XCTAssertTrue(LauncherLayout.folderOpenEmptyFocusesTitle(memberCount: 0))
        XCTAssertFalse(LauncherLayout.folderOpenEmptyFocusesTitle(memberCount: 1))
        XCTAssertFalse(LauncherLayout.folderOpenEmptyFocusesTitle(memberCount: 8))
        XCTAssertEqual(
            LauncherLayout.folderTitleEndFocusTarget(memberCount: 3),
            .firstMember
        )
        XCTAssertEqual(
            LauncherLayout.folderTitleEndFocusTarget(memberCount: 0),
            .title
        )
        // Non-empty open handoff unchanged.
        XCTAssertEqual(
            LauncherLayout.folderOpenFocusHandoff(owner: .outsideOverlay),
            .focusFirstMember
        )
        XCTAssertEqual(
            LauncherLayout.folderOpenFocusHandoff(owner: .titleOrClose),
            .preserveControl
        )
        XCTAssertTrue(LauncherLayout.folderTitleFocusesFirstMemberAfterEndingEdit)
    }




    func testSearchAdjacentChromeRestoreParityWithStatus() {
        XCTAssertEqual(
            LauncherLayout.searchAdjacentChromeShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 0.2
            ),
            LauncherLayout.statusChromeShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 0.2
            )
        )
        XCTAssertEqual(
            LauncherLayout.searchAdjacentChromeShouldClearOpacityBeforeUnhide(
                willShow: true,
                currentlyHidden: true
            ),
            LauncherLayout.statusChromeShouldClearOpacityBeforeUnhide(
                willShow: true,
                currentlyHidden: true
            )
        )
        XCTAssertNotEqual(
            LauncherLayout.searchAdjacentChromeFadeAnimationKey,
            LauncherLayout.statusChromeFadeAnimationKey
        )
        XCTAssertFalse(
            LauncherLayout.searchAdjacentChromeShouldShow(folderOpen: true, folderClosing: false)
        )
        XCTAssertTrue(
            LauncherLayout.searchAdjacentChromeShouldShow(folderOpen: false, folderClosing: false)
        )
    }

    func testSettingsPresenceOpacityGatesAndFocusPolicy() {
        XCTAssertTrue(
            LauncherLayout.settingsPresenceShouldClearOpacityBeforeUnhide(
                willShow: true,
                currentlyVisible: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.settingsPresenceShouldClearOpacityBeforeUnhide(
                willShow: true,
                currentlyVisible: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.settingsPresenceShouldRestoreOpacityWhenAlreadyShown(
                currentlyVisible: true,
                currentOpacity: 0.2
            )
        )
        XCTAssertFalse(
            LauncherLayout.settingsPresenceShouldRestoreOpacityWhenAlreadyShown(
                currentlyVisible: true,
                currentOpacity: 1.0
            )
        )
        // Already key + visible → do not re-activate (focus steal guard).
        XCTAssertFalse(
            LauncherLayout.settingsPresenceShouldBecomeKeyOnShow(
                currentlyVisible: true,
                isKeyWindow: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.settingsPresenceShouldBecomeKeyOnShow(
                currentlyVisible: false,
                isKeyWindow: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.settingsPresenceShouldBecomeKeyOnShow(
                currentlyVisible: true,
                isKeyWindow: false
            )
        )
        XCTAssertEqual(
            LauncherLayout.settingsPresenceFadeFromOpacity(
                appearing: true,
                presentedOpacity: 0.4,
                modelOpacity: 0.4
            ),
            0
        )
        XCTAssertEqual(
            LauncherLayout.settingsPresenceFadeFromOpacity(
                appearing: false,
                presentedOpacity: 0.35,
                modelOpacity: 0
            ),
            0.35
        )
        XCTAssertEqual(
            LauncherLayout.settingsPresenceFadeDuration,
            LauncherLayout.searchTransitionDuration
        )
    }

    func testSettingsMessageRestoresInterruptedFadeWhenAlreadyShown() {
        XCTAssertTrue(
            LauncherLayout.settingsMessageShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 0.12
            )
        )
        XCTAssertTrue(
            LauncherLayout.settingsMessageShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 0.98
            )
        )
        XCTAssertFalse(
            LauncherLayout.settingsMessageShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 0.99
            )
        )
        XCTAssertFalse(
            LauncherLayout.settingsMessageShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: true,
                currentOpacity: 0.0
            )
        )
        // Parity with status chrome restore gate.
        XCTAssertEqual(
            LauncherLayout.settingsMessageShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 0.4
            ),
            LauncherLayout.statusChromeShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 0.4
            )
        )
    }

    func testSettingsMessageRevealClearsOpacityBeforeUnhide() {
        XCTAssertTrue(LauncherLayout.settingsMessageShouldShow(text: "重新扫描完成"))
        XCTAssertFalse(LauncherLayout.settingsMessageShouldShow(text: ""))
        XCTAssertTrue(
            LauncherLayout.settingsMessageShouldClearOpacityBeforeUnhide(
                willShow: true,
                currentlyHidden: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.settingsMessageShouldClearOpacityBeforeUnhide(
                willShow: true,
                currentlyHidden: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.settingsMessageShouldClearOpacityBeforeUnhide(
                willShow: false,
                currentlyHidden: true
            )
        )
        XCTAssertEqual(
            LauncherLayout.settingsMessageFadeDuration,
            LauncherLayout.searchTransitionDuration,
            accuracy: 0.0001
        )
        XCTAssertFalse(LauncherLayout.settingsMessageFadeAnimationKey.isEmpty)
        XCTAssertTrue(
            LauncherLayout.settingsMessageFadeShouldApply(generation: 3, expected: 3)
        )
        XCTAssertFalse(
            LauncherLayout.settingsMessageFadeShouldApply(generation: 4, expected: 3)
        )
    }


    func testSearchAdjacentChromeQuietWhileFolderChrome() {
        XCTAssertTrue(
            LauncherLayout.searchAdjacentChromeShouldShow(
                folderOpen: false,
                folderClosing: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.searchAdjacentChromeShouldShow(
                folderOpen: true,
                folderClosing: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.searchAdjacentChromeShouldShow(
                folderOpen: false,
                folderClosing: true
            )
        )
        XCTAssertEqual(
            LauncherLayout.searchCountLabelKind(
                isSearching: true,
                folderOpen: false,
                folderClosing: false
            ),
            .results
        )
        XCTAssertEqual(
            LauncherLayout.searchCountLabelKind(
                isSearching: false,
                folderOpen: false,
                folderClosing: false
            ),
            .items
        )
        XCTAssertNil(
            LauncherLayout.searchCountLabelKind(
                isSearching: true,
                folderOpen: true,
                folderClosing: false
            )
        )
        XCTAssertNil(
            LauncherLayout.searchCountLabelKind(
                isSearching: false,
                folderOpen: false,
                folderClosing: true
            )
        )
    }

    func testStatusChromeCrossfadesTextWhenAlreadyVisible() {
        XCTAssertTrue(
            LauncherLayout.statusChromeShouldCrossfadeText(
                willShow: true,
                currentlyHidden: false,
                textChanging: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.statusChromeShouldCrossfadeText(
                willShow: true,
                currentlyHidden: true,
                textChanging: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.statusChromeShouldCrossfadeText(
                willShow: true,
                currentlyHidden: false,
                textChanging: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.statusChromeShouldCrossfadeText(
                willShow: false,
                currentlyHidden: false,
                textChanging: true
            )
        )
        // Reduced motion / dismiss / snappy: snap copy, do not crossfade.
        XCTAssertFalse(
            LauncherLayout.statusChromeShouldCrossfadeText(
                willShow: true,
                currentlyHidden: false,
                textChanging: true,
                animated: false
            )
        )
        XCTAssertEqual(
            LauncherLayout.statusChromeLabeledTextToShow(show: true, text: "只读说明"),
            "只读说明"
        )
        XCTAssertNil(LauncherLayout.statusChromeLabeledTextToShow(show: true, text: "   "))
        XCTAssertNil(LauncherLayout.statusChromeLabeledTextToShow(show: false, text: "只读说明"))
    }

    func testHideApplicationToastAndFocusHandoff() {
        XCTAssertEqual(
            LauncherLayout.hideApplicationToastMessage(displayName: "计算器"),
            "已隐藏“计算器”"
        )
        XCTAssertTrue(LauncherLayout.hideApplicationToastHelpKey.contains("隐藏的应用"))
        let a = UUID()
        let b = UUID()
        let c = UUID()
        XCTAssertEqual(
            LauncherLayout.focusItemIDAfterHiding(
                hiddenID: b,
                remainingIDs: [a, c],
                previousOrderedIDs: [a, b, c]
            ),
            c
        )
        XCTAssertEqual(
            LauncherLayout.focusItemIDAfterHiding(
                hiddenID: c,
                remainingIDs: [a, b],
                previousOrderedIDs: [a, b, c]
            ),
            b
        )
        XCTAssertNil(
            LauncherLayout.focusItemIDAfterHiding(
                hiddenID: a,
                remainingIDs: [],
                previousOrderedIDs: [a]
            )
        )
    }

    func testToastAnnouncementDedupesRepeatsAndQuitProgressKeys() {
        XCTAssertTrue(
            LauncherLayout.toastShouldAnnounce(
                message: "正在退出应用…",
                previousAnnounced: "",
                toastWasHidden: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.toastShouldAnnounce(
                message: "正在退出应用…",
                previousAnnounced: "正在退出应用…",
                toastWasHidden: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.toastShouldAnnounce(
                message: "正在退出应用…",
                previousAnnounced: "正在退出应用…",
                toastWasHidden: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.toastShouldAnnounce(
                message: "   ",
                previousAnnounced: "",
                toastWasHidden: true
            )
        )
        XCTAssertTrue(LauncherLayout.toastAnnouncementPriority(autoDismiss: true))
        XCTAssertFalse(LauncherLayout.toastAnnouncementPriority(autoDismiss: false))
        XCTAssertEqual(AppUninstallQuitProgress.quittingMessageKey, "正在退出应用…")
        XCTAssertFalse(AppUninstallQuitProgress.quittingAccessibilityHelpKey.isEmpty)
    }

    func testUninstallForceQuitAlertCancelFirstAndAccessibilityKeys() {
        XCTAssertTrue(AppUninstallForceQuitAlert.cancelIsFirstButton)
        XCTAssertTrue(AppUninstallForceQuitAlert.restoresLauncherFocusAfterSheet)
        XCTAssertEqual(AppUninstallForceQuitAlert.messageTextKey, "应用仍在运行")
        XCTAssertEqual(AppUninstallForceQuitAlert.confirmButtonTitleKey, "强制退出并卸载")
        XCTAssertFalse(AppUninstallForceQuitAlert.confirmAccessibilityHelpKey.isEmpty)
        XCTAssertFalse(AppUninstallForceQuitAlert.cancelAccessibilityHelpKey.isEmpty)
        XCTAssertTrue(
            AppUninstallForceQuitAlert.informativeTextKey.contains("强制退出")
        )
    }

    func testSettingsAccessibilityAndKeyboardPolicy() {
        XCTAssertTrue(LauncherLayout.settingsMessageShouldAnnounce(text: "重新扫描完成", previous: ""))
        XCTAssertFalse(LauncherLayout.settingsMessageShouldAnnounce(text: "重新扫描完成", previous: "重新扫描完成"))
        XCTAssertFalse(LauncherLayout.settingsMessageShouldAnnounce(text: "", previous: "旧"))
        XCTAssertTrue(LauncherLayout.settingsShouldMoveFocusAfterRestore(remainingHidden: 0))
        XCTAssertFalse(LauncherLayout.settingsShouldMoveFocusAfterRestore(remainingHidden: 2))
        XCTAssertTrue(LauncherLayout.settingsEscapeClosesWindow)
    }

    func testStatusChromeClearsOpacityBeforeUnhideAndRestoresWhenInterrupted() {
        XCTAssertTrue(
            LauncherLayout.statusChromeShouldClearOpacityBeforeUnhide(
                willShow: true,
                currentlyHidden: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.statusChromeShouldClearOpacityBeforeUnhide(
                willShow: true,
                currentlyHidden: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.statusChromeShouldClearOpacityBeforeUnhide(
                willShow: false,
                currentlyHidden: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.statusChromeShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 0.2
            )
        )
        XCTAssertFalse(
            LauncherLayout.statusChromeShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 1
            )
        )
        XCTAssertFalse(
            LauncherLayout.statusChromeShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: true,
                currentOpacity: 0
            )
        )
    }

    func testFooterNavigationClearsOpacityBeforeUnhide() {
        XCTAssertTrue(
            LauncherLayout.footerNavigationShouldClearOpacityBeforeUnhide(
                isHidden: true,
                textChanging: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.footerNavigationShouldClearOpacityBeforeUnhide(
                isHidden: false,
                textChanging: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.footerNavigationShouldSnapUnhide(
                isHidden: true,
                textChanging: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.footerNavigationShouldRestoreOpacityWhenTextUnchanged(
                isHidden: false, textChanging: false, currentOpacity: 0
            )
        )
        XCTAssertFalse(
            LauncherLayout.footerNavigationShouldRestoreOpacityWhenTextUnchanged(
                isHidden: false, textChanging: false, currentOpacity: 1
            )
        )
        XCTAssertFalse(
            LauncherLayout.footerNavigationShouldRestoreOpacityWhenTextUnchanged(
                isHidden: false, textChanging: true, currentOpacity: 0
            )
        )
        XCTAssertFalse(
            LauncherLayout.footerNavigationShouldRestoreOpacityWhenTextUnchanged(
                isHidden: true, textChanging: false, currentOpacity: 0
            )
        )
        XCTAssertFalse(
            LauncherLayout.footerNavigationShouldSnapUnhide(
                isHidden: true,
                textChanging: true
            )
        )
    }

    func testFooterHintVisibilityFollowsSearchAndFolder() {
        XCTAssertTrue(
            LauncherLayout.footerDragHintShouldShow(
                isSearching: false,
                folderOpen: false,
                isLayoutEditingEnabled: true,
                hasEntries: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.footerDragHintShouldShow(
                isSearching: true,
                folderOpen: false,
                isLayoutEditingEnabled: true,
                hasEntries: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.footerDragHintShouldShow(
                isSearching: false,
                folderOpen: true,
                isLayoutEditingEnabled: true,
                hasEntries: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.footerDragHintShouldShow(
                isSearching: false,
                folderOpen: false,
                isLayoutEditingEnabled: false,
                hasEntries: true
            )
        )
        XCTAssertTrue(LauncherLayout.footerChromeShouldShow(folderOpen: false))
        XCTAssertFalse(LauncherLayout.footerChromeShouldShow(folderOpen: true))
        XCTAssertEqual(LauncherLayout.footerHintFadeAnimationKey, "footer-hint-fade")
    }

    func testPageArrowVisibilityFadesWithSearchChromeClock() {
        XCTAssertTrue(
            LauncherLayout.pageArrowShouldShow(hasMultiplePages: true, atUnavailableEdge: false)
        )
        XCTAssertFalse(
            LauncherLayout.pageArrowShouldShow(hasMultiplePages: true, atUnavailableEdge: true)
        )
        XCTAssertFalse(
            LauncherLayout.pageArrowShouldShow(hasMultiplePages: false, atUnavailableEdge: false)
        )
        XCTAssertTrue(
            LauncherLayout.shouldAnimatePageArrowVisibility(
                shouldShow: false,
                currentlyShown: true,
                reducesMotion: false,
                holdsForLauncherFade: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageArrowVisibility(
                shouldShow: false,
                currentlyShown: true,
                reducesMotion: true,
                holdsForLauncherFade: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageArrowVisibility(
                shouldShow: true,
                currentlyShown: true,
                reducesMotion: false,
                holdsForLauncherFade: false
            )
        )
        XCTAssertEqual(LauncherLayout.pageArrowPresenceAnimationKey, "page-arrow-presence")
        // Shared gate matches indicator policy.
        XCTAssertEqual(
            LauncherLayout.shouldAnimatePagingChromeVisibility(
                shouldShow: false,
                currentlyShown: true,
                reducesMotion: false,
                holdsForLauncherFade: false
            ),
            LauncherLayout.shouldAnimatePageIndicatorVisibility(
                pageCount: 0,
                currentlyShown: true,
                reducesMotion: false,
                holdsForLauncherFade: false
            )
        )
    }

    func testPageIndicatorVisibilityFadesWithSearchChromeClock() {
        XCTAssertTrue(LauncherLayout.pageIndicatorShouldShow(pageCount: 2))
        XCTAssertTrue(LauncherLayout.pageIndicatorShouldShow(pageCount: 9))
        XCTAssertFalse(LauncherLayout.pageIndicatorShouldShow(pageCount: 1))
        XCTAssertFalse(LauncherLayout.pageIndicatorShouldShow(pageCount: 0))
        // Entering search (0 pages) while dots are shown animates.
        XCTAssertTrue(
            LauncherLayout.shouldAnimatePageIndicatorVisibility(
                pageCount: 0,
                currentlyShown: true,
                reducesMotion: false,
                holdsForLauncherFade: false
            )
        )
        // Leaving search back to multiple pages animates.
        XCTAssertTrue(
            LauncherLayout.shouldAnimatePageIndicatorVisibility(
                pageCount: 3,
                currentlyShown: false,
                reducesMotion: false,
                holdsForLauncherFade: false
            )
        )
        // Reduced motion and launcher-fade hold snap.
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageIndicatorVisibility(
                pageCount: 0,
                currentlyShown: true,
                reducesMotion: true,
                holdsForLauncherFade: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageIndicatorVisibility(
                pageCount: 0,
                currentlyShown: true,
                reducesMotion: false,
                holdsForLauncherFade: true
            )
        )
        // No-op when visibility is already correct.
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageIndicatorVisibility(
                pageCount: 3,
                currentlyShown: true,
                reducesMotion: false,
                holdsForLauncherFade: false
            )
        )
        XCTAssertEqual(LauncherLayout.pageIndicatorFadeAnimationKey, "page-indicator-fade")
        XCTAssertEqual(LauncherLayout.searchTransitionDuration, 0.12, accuracy: 0.0001)
    }

    func testSearchSectionHorizontalInsetCentersShortRows() {
        let itemWidth: CGFloat = 100
        let spacing: CGFloat = 12
        let viewport: CGFloat = 800
        // One result: centered under the search field.
        let one = LauncherLayout.searchSectionHorizontalInset(
            itemCount: 1,
            itemWidth: itemWidth,
            interitemSpacing: spacing,
            viewportWidth: viewport
        )
        XCTAssertEqual(one, floor((viewport - itemWidth) / 2), accuracy: 0.001)
        // Four of seven: same centering math.
        let fourWidth = 4 * itemWidth + 3 * spacing
        let four = LauncherLayout.searchSectionHorizontalInset(
            itemCount: 4,
            itemWidth: itemWidth,
            interitemSpacing: spacing,
            viewportWidth: viewport
        )
        XCTAssertEqual(four, floor((viewport - fourWidth) / 2), accuracy: 0.001)
        // Full row and denser lists keep the minimum inset.
        XCTAssertEqual(
            LauncherLayout.searchSectionHorizontalInset(
                itemCount: LauncherLayout.pageColumns,
                itemWidth: itemWidth,
                interitemSpacing: spacing,
                viewportWidth: viewport
            ),
            8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LauncherLayout.searchSectionHorizontalInset(
                itemCount: 0,
                itemWidth: itemWidth,
                interitemSpacing: spacing,
                viewportWidth: viewport
            ),
            8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LauncherLayout.searchSectionHorizontalInset(
                itemCount: 8,
                itemWidth: itemWidth,
                interitemSpacing: spacing,
                viewportWidth: viewport
            ),
            8,
            accuracy: 0.001
        )
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

    func testFolderCloseGridFocusPrefersFolderThenDissolvedNeighbor() {
        let folderID = UUID()
        let kept = UUID()
        let neighbor = UUID()
        // Esc / dimmer: folder still present → folder tile.
        XCTAssertEqual(
            LauncherLayout.folderCloseGridFocusID(
                pendingFolderID: folderID,
                previousEntries: [.app(neighbor), .folder(folderID)],
                currentEntries: [.app(neighbor), .folder(folderID)]
            ),
            folderID
        )
        // Dissolved empty folder (nothing took the slot) → previous neighbor.
        XCTAssertEqual(
            LauncherLayout.folderCloseGridFocusID(
                pendingFolderID: folderID,
                previousEntries: [.app(neighbor), .folder(folderID)],
                currentEntries: [.app(neighbor)]
            ),
            neighbor
        )
        // Dissolved with member keeping the slot.
        XCTAssertEqual(
            LauncherLayout.folderCloseGridFocusID(
                pendingFolderID: folderID,
                previousEntries: [.app(neighbor), .folder(folderID)],
                currentEntries: [.app(neighbor), .app(kept)]
            ),
            kept
        )
        // Empty grid after dissolve → nil.
        XCTAssertNil(
            LauncherLayout.folderCloseGridFocusID(
                pendingFolderID: folderID,
                previousEntries: [.folder(folderID)],
                currentEntries: []
            )
        )
    }


    func testFolderMemberFocusFillMatchesTitleChromeFlightGate() {
        // In flight: focused member paints idle (title also blocks pointer/AX).
        XCTAssertEqual(
            LauncherLayout.folderMemberFocusFillAlpha(
                focused: true,
                panelChromeInFlight: true
            ),
            LauncherLayout.tileChromeIdleAlpha
        )
        // Landed: focused member paints 8% focus fill.
        XCTAssertEqual(
            LauncherLayout.folderMemberFocusFillAlpha(
                focused: true,
                panelChromeInFlight: false
            ),
            LauncherLayout.tileChromeFocusAlpha
        )
        XCTAssertEqual(
            LauncherLayout.folderMemberFocusFillAlpha(
                focused: false,
                panelChromeInFlight: false
            ),
            LauncherLayout.tileChromeIdleAlpha
        )
        // Flight begin / land both use the shared search-chrome fade clock.
        XCTAssertEqual(
            LauncherLayout.tileChromeFillFadeDuration,
            LauncherLayout.folderTitleEditUnderlineFadeDuration
        )
        XCTAssertEqual(
            LauncherLayout.tileChromeFillFadeDuration,
            LauncherLayout.searchTransitionDuration
        )
    }

    func testSearchTransitionUsesTheFastMotionToken() {
        XCTAssertEqual(LauncherLayout.searchTransitionDuration, 0.12, accuracy: 0.001)
        let fade = LauncherLayout.searchChromeFade(
            reducesMotion: false,
            holdsForLauncherFade: false,
            incomingIsFolderBackdrop: false
        )
        XCTAssertTrue(fade.keepsOutgoingVisible)
        XCTAssertEqual(fade.duration, 0.12, accuracy: 0.001)
        XCTAssertEqual(fade.incomingOpacity, 1, accuracy: 0.001)
        XCTAssertEqual(fade.outgoingOpacity, 0, accuracy: 0.001)
        XCTAssertFalse(LauncherLayout.searchChromeOutgoingAcceptsClicks(fadingOut: true))
        XCTAssertTrue(LauncherLayout.searchChromeOutgoingAcceptsClicks(fadingOut: false))
        for skipped in [
            LauncherLayout.searchChromeFade(
                reducesMotion: true, holdsForLauncherFade: false, incomingIsFolderBackdrop: false
            ),
            LauncherLayout.searchChromeFade(
                reducesMotion: false, holdsForLauncherFade: true, incomingIsFolderBackdrop: false
            ),
            LauncherLayout.searchChromeFade(
                reducesMotion: false, holdsForLauncherFade: false, incomingIsFolderBackdrop: true
            )
        ] {
            XCTAssertFalse(skipped.keepsOutgoingVisible)
            XCTAssertEqual(skipped.duration, 0, accuracy: 0.001)
            XCTAssertEqual(skipped.outgoingOpacity, 1, accuracy: 0.001)
        }
        XCTAssertEqual(
            LauncherLayout.searchChromeFade(
                reducesMotion: false, holdsForLauncherFade: false, incomingIsFolderBackdrop: true
            ).incomingOpacity,
            0.45,
            accuracy: 0.001
        )
    }

    func testSearchGridCrossfadeSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapSearchChromeForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapSearchChromeForReducedMotion(reducesMotion: false)
        )
        let snap = LauncherLayout.searchChromeFade(
            reducesMotion: true,
            holdsForLauncherFade: false,
            incomingIsFolderBackdrop: false
        )
        XCTAssertFalse(snap.keepsOutgoingVisible)
        XCTAssertEqual(snap.duration, 0, accuracy: 0.0001)
        XCTAssertEqual(snap.incomingOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(snap.outgoingOpacity, 1, accuracy: 0.0001)
        let full = LauncherLayout.searchChromeFade(
            reducesMotion: false,
            holdsForLauncherFade: false,
            incomingIsFolderBackdrop: false
        )
        XCTAssertTrue(full.keepsOutgoingVisible)
        XCTAssertEqual(full.duration, LauncherLayout.searchTransitionDuration, accuracy: 0.0001)
    }

    func testDissolvedGridFadeSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapDissolvedGridFadeForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapDissolvedGridFadeForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.dissolvedGridFadeDuration(reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.dissolvedGridFadeDuration(reducesMotion: false),
            0.22,
            accuracy: 0.0001
        )
    }

    func testFolderBackdropSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapFolderBackdropForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapFolderBackdropForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.folderBackdropFadeDuration(reducesMotion: true, motionDuration: 0.34),
            0
        )
        XCTAssertEqual(
            LauncherLayout.folderBackdropFadeDuration(reducesMotion: true, motionDuration: nil),
            0
        )
        XCTAssertEqual(
            LauncherLayout.folderBackdropFadeDuration(reducesMotion: false, motionDuration: 0.34),
            0.34,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LauncherLayout.folderBackdropFadeDuration(reducesMotion: false, motionDuration: nil),
            LauncherLayout.folderChromeFallbackDuration,
            accuracy: 0.0001
        )
        // Reduced open style stays opacity-only (no scale/blur) — snap lands here.
        let reducedOpen = LauncherLayout.folderBackdropStyle(open: true, reducesMotion: true)
        XCTAssertEqual(reducedOpen.opacity, LauncherLayout.folderBackdropOpenOpacity, accuracy: 0.0001)
        XCTAssertEqual(reducedOpen.scale, 1, accuracy: 0.0001)
        XCTAssertFalse(reducedOpen.blurs)
    }

    /// Open and close share this pose. The scaled panel's center is the
    /// folder preview, and the same value is the close destination.
    func testFolderChromeSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapFolderChromeForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapFolderChromeForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(LauncherLayout.folderChromeReducedDuration, 0, accuracy: 0.0001)
        XCTAssertEqual(
            LauncherLayout.folderChromeFadeDuration(reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.folderChromeFadeDuration(reducesMotion: false),
            LauncherLayout.folderChromeFallbackDuration,
            accuracy: 0.0001
        )
        let collapse = LauncherLayout.folderChromeCollapse(
            panelFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            iconFrame: CGRect(x: 10, y: 10, width: 72, height: 72),
            reducesMotion: true
        )
        XCTAssertEqual(collapse.duration, 0, accuracy: 0.0001)
        XCTAssertFalse(collapse.animatesTransform)
        let dissolve = LauncherLayout.folderDissolveChrome(reducesMotion: true)
        XCTAssertEqual(dissolve.duration, 0, accuracy: 0.0001)
    }


    func testFolderCreatedSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapFolderCreatedForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapFolderCreatedForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.folderCreatedFadeDuration(reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.folderCreatedFadeDuration(reducesMotion: false),
            0.12,
            accuracy: 0.0001
        )
    }


    func testMergeFlyerSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapMergeFlyerForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapMergeFlyerForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.mergeReducedFadeDuration(reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.mergeReducedFadeDuration(reducesMotion: false),
            0.12,
            accuracy: 0.0001
        )
    }


    func testLaunchPressSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapLaunchPressForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapLaunchPressForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.launchPressPulseHalfDuration(reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.launchPressPulseHalfDuration(reducesMotion: false),
            LauncherLayout.launchPressHalfDuration,
            accuracy: 0.0001
        )
        XCTAssertFalse(
            LauncherLayout.shouldPlayLaunchFeedback(isDismissing: false, reducesMotion: true)
        )
        XCTAssertTrue(
            LauncherLayout.shouldPlayLaunchFeedback(isDismissing: false, reducesMotion: false)
        )
    }


    func testPageButtonHoverSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapPageButtonHoverForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapPageButtonHoverForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.pageButtonHoverOpacityFadeDuration(reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.pageButtonHoverOpacityFadeDuration(reducesMotion: false),
            LauncherLayout.pageButtonHoverFadeDuration,
            accuracy: 0.0001
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePageButtonHover(
                isDismissing: false, isVisible: true, reducesMotion: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldAnimatePageButtonHover(
                isDismissing: false, isVisible: true, reducesMotion: false
            )
        )
    }


    func testReorderSlideSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapReorderSlideForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapReorderSlideForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.reorderSlideSpringDuration(reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.reorderSlideSpringDuration(reducesMotion: false),
            LauncherLayout.reorderSlideDuration,
            accuracy: 0.0001
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimateReorderSlide(
                isDismissing: false, isVisible: true, reducesMotion: true
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldAnimateReorderSlide(
                isDismissing: false, isVisible: true, reducesMotion: false
            )
        )
    }


    func testDragLiftSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapDragLiftForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapDragLiftForReducedMotion(reducesMotion: false)
        )
        let source = CGSize(width: 80, height: 96)
        let snap = LauncherLayout.dragLiftPresentation(for: source, reducesMotion: true)
        XCTAssertEqual(snap.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(snap.shadowOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(snap.canvasSize, source)
        let full = LauncherLayout.dragLiftPresentation(for: source, reducesMotion: false)
        XCTAssertEqual(full.scale, LauncherLayout.dragLiftScale, accuracy: 0.0001)
        XCTAssertGreaterThan(full.shadowOpacity, 0)
    }


    func testDropLandingSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapDropLandingForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapDropLandingForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.dropLandingTravelDuration(reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.dropLandingTravelDuration(reducesMotion: false),
            LauncherLayout.dropLandingFlightDuration,
            accuracy: 0.0001
        )
        let cell = CGRect(x: 10, y: 20, width: 100, height: 120)
        let start = LauncherLayout.dropLandingStartFrame(cell: cell, reducesMotion: true)
        XCTAssertEqual(start, cell)
        XCTAssertNil(
            LauncherLayout.dropLandingFlight(
                from: cell.offsetBy(dx: 5, dy: 5),
                to: cell,
                reducesMotion: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldPlayDropLanding(
                reducesMotion: true, isDismissing: false, isVisible: true
            )
        )
    }


    func testFooterChromeVisibilitySnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapFooterChromeVisibilityForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapFooterChromeVisibilityForReducedMotion(reducesMotion: false)
        )
        // Presence gate: reduced motion snaps (no opacity travel).
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePagingChromeVisibility(
                shouldShow: false,
                currentlyShown: true,
                reducesMotion: true,
                holdsForLauncherFade: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.shouldAnimatePagingChromeVisibility(
                shouldShow: false,
                currentlyShown: true,
                reducesMotion: false,
                holdsForLauncherFade: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldAnimatePagingChromeVisibility(
                shouldShow: false,
                currentlyShown: true,
                reducesMotion: false,
                holdsForLauncherFade: true
            )
        )
    }


    func testFolderMergePreviewSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapFolderMergePreviewForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapFolderMergePreviewForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.folderMergePreviewTravelDuration(reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.folderMergePreviewTravelDuration(reducesMotion: false),
            LauncherLayout.folderChromeTravelDuration,
            accuracy: 0.0001
        )
        let resident = CGRect(x: 100, y: 200, width: 64, height: 64)
        let incoming = CGRect(x: 280, y: 180, width: 48, height: 48)
        let destinations = [
            CGRect(x: 10, y: 50, width: 16, height: 16),
            CGRect(x: 30, y: 50, width: 16, height: 16)
        ]
        XCTAssertTrue(
            LauncherLayout.folderMergePreviewLandings(
                resident: resident,
                incoming: incoming,
                destinations: destinations,
                reducesMotion: true
            ).isEmpty
        )
        XCTAssertEqual(
            LauncherLayout.folderMergePreviewLandings(
                resident: resident,
                incoming: incoming,
                destinations: destinations,
                reducesMotion: false
            ).count,
            2
        )
    }


    func testFolderIncomingPreviewSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapFolderIncomingPreviewForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapFolderIncomingPreviewForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.folderIncomingPreviewTravelDuration(reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.folderIncomingPreviewTravelDuration(reducesMotion: false),
            LauncherLayout.folderChromeTravelDuration,
            accuracy: 0.0001
        )
        let incoming = CGRect(x: 280, y: 180, width: 48, height: 48)
        let destination = CGRect(x: 51, y: 63, width: 16, height: 16)
        let well = CGRect(x: 10, y: 20, width: 64, height: 64)
        XCTAssertNil(
            LauncherLayout.folderIncomingPreviewLanding(
                incoming: incoming, destination: destination, reducesMotion: true
            )
        )
        XCTAssertNotNil(
            LauncherLayout.folderIncomingPreviewLanding(
                incoming: incoming, destination: destination, reducesMotion: false
            )
        )
        XCTAssertNil(
            LauncherLayout.folderIncomingPreviewCenterLanding(
                incoming: incoming, well: well, reducesMotion: true
            )
        )
        XCTAssertNotNil(
            LauncherLayout.folderIncomingPreviewCenterLanding(
                incoming: incoming, well: well, reducesMotion: false
            )
        )
    }


    func testFolderPreviewGlyphSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapFolderPreviewGlyphForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapFolderPreviewGlyphForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.folderPreviewGlyphTravelDuration(reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.folderPreviewGlyphTravelDuration(reducesMotion: false),
            LauncherLayout.folderPreviewGlyphFlightDuration,
            accuracy: 0.0001
        )
        let placement = LauncherLayout.FolderPreviewGlyphPlacement(
            itemID: UUID(),
            source: CGRect(x: 0, y: 0, width: 16, height: 16),
            destination: CGRect(x: 200, y: 180, width: 72, height: 72)
        )
        XCTAssertTrue(
            LauncherLayout.folderPreviewGlyphFlights(placements: [placement], reducesMotion: true).isEmpty
        )
        XCTAssertFalse(
            LauncherLayout.folderPreviewGlyphFlights(placements: [placement], reducesMotion: false).isEmpty
        )
        XCTAssertTrue(
            LauncherLayout.folderPreviewGlyphReturnFlights(placements: [placement], reducesMotion: true).isEmpty
        )
        XCTAssertFalse(
            LauncherLayout.shouldPlayFolderPreviewGlyphFlight(
                reducesMotion: true, isDismissing: false, isVisible: true, tracksIcon: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldPlayFolderPreviewGlyphReturn(
                reducesMotion: true, isDismissing: false, isVisible: true, tracksIcon: true
            )
        )
    }


    func testDissolveScatterSnapsUnderReducedMotion() {
        XCTAssertTrue(
            LauncherLayout.shouldSnapDissolveScatterForReducedMotion(reducesMotion: true)
        )
        XCTAssertFalse(
            LauncherLayout.shouldSnapDissolveScatterForReducedMotion(reducesMotion: false)
        )
        XCTAssertEqual(
            LauncherLayout.dissolveScatterTravelDuration(reducesMotion: true),
            0
        )
        XCTAssertEqual(
            LauncherLayout.dissolveScatterTravelDuration(reducesMotion: false),
            LauncherLayout.folderDissolveFlightDuration,
            accuracy: 0.0001
        )
        let placement = LauncherLayout.FolderDissolveIconPlacement(
            itemID: UUID(),
            source: CGRect(x: 0, y: 0, width: 40, height: 40),
            destination: CGRect(x: 100, y: 80, width: 40, height: 40)
        )
        XCTAssertTrue(
            LauncherLayout.folderDissolveFlights(placements: [placement], reducesMotion: true).isEmpty
        )
        XCTAssertFalse(
            LauncherLayout.folderDissolveFlights(placements: [placement], reducesMotion: false).isEmpty
        )
        XCTAssertFalse(
            LauncherLayout.shouldPlayFolderDissolveScatter(
                reducesMotion: true, isDismissing: false, isVisible: true
            )
        )
    }


    func testFolderChromeCollapseTracksTheFolderIcon() {
        let panel = CGRect(x: 100, y: 80, width: 500, height: 360)
        let icon = CGRect(x: 40, y: 420, width: 72, height: 72)
        let collapse = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: icon,
            reducesMotion: false
        )
        XCTAssertTrue(collapse.tracksIcon)
        XCTAssertTrue(collapse.animatesTransform)
        // The whole panel fits in the preview. Width is the tighter ratio.
        XCTAssertEqual(collapse.scale, 72.0 / 500.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(panel.width * collapse.scale, icon.width + 0.001)
        XCTAssertLessThanOrEqual(panel.height * collapse.scale, icon.height + 0.001)
        XCTAssertEqual(collapse.translationX, icon.midX - panel.midX, accuracy: 0.0001)
        XCTAssertEqual(collapse.translationY, icon.midY - panel.midY, accuracy: 0.0001)
        XCTAssertEqual(panel.midX + collapse.translationX, icon.midX, accuracy: 0.0001)
        XCTAssertEqual(panel.midY + collapse.translationY, icon.midY, accuracy: 0.0001)
        XCTAssertEqual(collapse.panelOpacity, 1, accuracy: 0.001)
        XCTAssertEqual(collapse.duration, 0.34, accuracy: 0.001)
        XCTAssertEqual(
            LauncherLayout.folderChromeCollapse(panelFrame: panel, iconFrame: icon, reducesMotion: false),
            collapse
        )

        let tiny = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: CGRect(x: 0, y: 0, width: 8, height: 8),
            reducesMotion: false
        )
        XCTAssertEqual(tiny.scale, LauncherLayout.folderChromeMinimumScale, accuracy: 0.0001)
        XCTAssertEqual(tiny.translationX, 4 - panel.midX, accuracy: 0.0001)
        XCTAssertTrue(tiny.tracksIcon)

        let huge = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: CGRect(x: 0, y: 0, width: 900, height: 900),
            reducesMotion: false
        )
        XCTAssertEqual(huge.scale, LauncherLayout.folderChromeMaximumScale, accuracy: 0.0001)
        XCTAssertEqual(huge.translationX, 450 - panel.midX, accuracy: 0.0001)

        let reduced = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: icon,
            reducesMotion: true
        )
        XCTAssertFalse(reduced.tracksIcon)
        XCTAssertFalse(reduced.animatesTransform)
        XCTAssertEqual(reduced.scale, 1, accuracy: 0.001)
        XCTAssertEqual(reduced.translationX, 0, accuracy: 0.001)
        XCTAssertEqual(reduced.translationY, 0, accuracy: 0.001)
        XCTAssertEqual(reduced.panelOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(reduced.duration, 0, accuracy: 0.001)
        XCTAssertTrue(LauncherLayout.shouldSnapFolderChromeForReducedMotion(reducesMotion: true))

        let missing = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: nil,
            reducesMotion: false
        )
        XCTAssertFalse(missing.tracksIcon)
        XCTAssertTrue(missing.animatesTransform)
        XCTAssertEqual(missing.scale, 0.92, accuracy: 0.001)
        XCTAssertEqual(missing.translationX, 0, accuracy: 0.001)
        XCTAssertEqual(missing.translationY, 0, accuracy: 0.001)
        XCTAssertEqual(missing.panelOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(missing.duration, 0.22, accuracy: 0.001)

        let emptyPanel = LauncherLayout.folderChromeCollapse(
            panelFrame: .zero,
            iconFrame: icon,
            reducesMotion: false
        )
        XCTAssertFalse(emptyPanel.tracksIcon)
        XCTAssertEqual(emptyPanel.scale, 0.92, accuracy: 0.001)

        let invalid = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: CGRect(x: CGFloat.nan, y: 0, width: 72, height: 72),
            reducesMotion: false
        )
        XCTAssertFalse(invalid.tracksIcon)
        XCTAssertEqual(invalid.duration, 0.22, accuracy: 0.001)

        let bounds = CGRect(origin: .zero, size: panel.size)
        let shift = LauncherLayout.folderPanelCollapseShift(
            scale: collapse.scale,
            translationX: collapse.translationX,
            translationY: collapse.translationY,
            panelBounds: bounds
        )
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        XCTAssertEqual(
            collapse.scale * center.x + shift.x,
            center.x + collapse.translationX,
            accuracy: 0.001
        )
        XCTAssertEqual(
            collapse.scale * center.y + shift.y,
            center.y + collapse.translationY,
            accuracy: 0.001
        )
        XCTAssertEqual(panel.minX + collapse.scale * center.x + shift.x, icon.midX, accuracy: 0.001)
        XCTAssertEqual(panel.minY + collapse.scale * center.y + shift.y, icon.midY, accuracy: 0.001)
        let fallbackShift = LauncherLayout.folderPanelCollapseShift(
            scale: missing.scale,
            translationX: missing.translationX,
            translationY: missing.translationY,
            panelBounds: bounds
        )
        XCTAssertEqual(missing.scale * center.x + fallbackShift.x, center.x, accuracy: 0.001)
        XCTAssertEqual(missing.scale * center.y + fallbackShift.y, center.y, accuracy: 0.001)
        XCTAssertEqual(
            LauncherLayout.folderPanelCollapseShift(
                scale: CGFloat.nan,
                translationX: 4,
                translationY: 4,
                panelBounds: bounds
            ),
            .zero
        )
        XCTAssertEqual(
            LauncherLayout.folderPanelCollapseShift(
                scale: 0.5,
                translationX: CGFloat.nan,
                translationY: 0,
                panelBounds: bounds
            ),
            .zero
        )
        XCTAssertEqual(
            LauncherLayout.folderPanelCollapseShift(
                scale: 0,
                translationX: 0,
                translationY: 0,
                panelBounds: bounds
            ),
            .zero
        )
        XCTAssertEqual(
            LauncherLayout.folderPanelCollapseShift(
                scale: 0.5,
                translationX: 1,
                translationY: 1,
                panelBounds: .zero
            ),
            .zero
        )
    }

    /// The panel grows out of the preview plate. The plate stays hidden for
    /// that flight and for the time the folder is open. The close draws it
    /// again, faint until the panel has settled on the icon. Reduced motion
    /// and a centered pop do not borrow the plate.
    func testFolderPreviewPlateHidesUntilTheCloseLands() {
        let panel = CGRect(x: 100, y: 80, width: 500, height: 360)
        let icon = CGRect(x: 40, y: 420, width: 72, height: 72)
        let tracked = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: icon,
            reducesMotion: false
        )
        XCTAssertTrue(tracked.tracksIcon)
        XCTAssertTrue(LauncherLayout.shouldHideFolderPreviewPlate(
            tracksIcon: tracked.tracksIcon,
            phase: .borrowed
        ))
        XCTAssertFalse(LauncherLayout.shouldHideFolderPreviewPlate(
            tracksIcon: tracked.tracksIcon,
            phase: .returning
        ))
        XCTAssertFalse(LauncherLayout.shouldHideFolderPreviewPlate(
            tracksIcon: tracked.tracksIcon,
            phase: .yielding
        ))
        XCTAssertFalse(LauncherLayout.shouldHideFolderPreviewPlate(
            tracksIcon: tracked.tracksIcon,
            phase: .resting
        ))

        let reduced = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: icon,
            reducesMotion: true
        )
        XCTAssertFalse(reduced.tracksIcon)
        XCTAssertFalse(LauncherLayout.shouldHideFolderPreviewPlate(
            tracksIcon: reduced.tracksIcon,
            phase: .borrowed
        ))
        XCTAssertFalse(LauncherLayout.shouldHideFolderPreviewPlate(
            tracksIcon: reduced.tracksIcon,
            phase: .returning
        ))

        let centered = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: nil,
            reducesMotion: false
        )
        XCTAssertFalse(centered.tracksIcon)
        XCTAssertFalse(LauncherLayout.shouldHideFolderPreviewPlate(
            tracksIcon: centered.tracksIcon,
            phase: .borrowed
        ))
        XCTAssertFalse(LauncherLayout.shouldHideFolderPreviewPlate(
            tracksIcon: false,
            phase: .resting
        ))

        let dissolved = LauncherLayout.folderDissolveChrome(reducesMotion: false)
        XCTAssertFalse(dissolved.tracksIcon)
        XCTAssertFalse(LauncherLayout.shouldHideFolderPreviewPlate(
            tracksIcon: dissolved.tracksIcon,
            phase: .returning
        ))
    }

    /// The close used to fade the panel out and then draw the plate. The plate
    /// now takes the opacity the panel gives up, on the same late dissolve.
    /// Halfway the panel is still mostly there, so the plate is still faint.
    /// They sum to 1. A bad clock does not draw a plate.
    func testFolderPreviewPlateFadesInAsThePanelDissolves() {
        XCTAssertEqual(LauncherLayout.folderPreviewPlateReturnOpacity(at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderPreviewPlateReturnOpacity(at: 1), 1, accuracy: 0.001)
        XCTAssertLessThan(LauncherLayout.folderPreviewPlateReturnOpacity(at: 0.5), 0.2)
        XCTAssertGreaterThan(LauncherLayout.folderPreviewPlateReturnOpacity(at: 0.9), 0.6)
        var previous: CGFloat = -1
        for step in 0...10 {
            let time = CGFloat(step) / 10
            let plate = LauncherLayout.folderPreviewPlateReturnOpacity(at: time)
            let panel = LauncherLayout.wholeCellMergeFlightOpacity(at: time)
            XCTAssertEqual(plate + panel, 1, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(plate, previous)
            previous = plate
        }
        XCTAssertEqual(LauncherLayout.folderPreviewPlateReturnOpacity(at: -0.2), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderPreviewPlateReturnOpacity(at: 1.4), 1, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderPreviewPlateReturnOpacity(at: .nan), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderPreviewPlateReturnOpacity(at: .infinity), 0, accuracy: 0.001)
    }

    /// A close that interrupts a reversed open used to snap the plate off and
    /// fade it back up from nothing. It now continues from the opacity on
    /// screen. A fresh close still starts at 0. A bad start stays hidden.
    func testFolderPreviewPlateReturnContinuesFromTheOpacityOnScreen() {
        XCTAssertEqual(
            LauncherLayout.folderPreviewPlateReturnOpacity(from: 0, at: 0.4),
            LauncherLayout.folderPreviewPlateReturnOpacity(at: 0.4),
            accuracy: 0.001
        )
        XCTAssertEqual(LauncherLayout.folderPreviewPlateReturnOpacity(from: 0.4, at: 0), 0.4, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderPreviewPlateReturnOpacity(from: 0.4, at: 1), 1, accuracy: 0.001)
        var previous: CGFloat = -1
        for step in 0...10 {
            let time = CGFloat(step) / 10
            let plate = LauncherLayout.folderPreviewPlateReturnOpacity(from: 0.4, at: time)
            let gained = LauncherLayout.folderPreviewPlateReturnOpacity(at: time)
            XCTAssertEqual(plate, 0.4 + 0.6 * gained, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(plate, previous)
            previous = plate
        }
        XCTAssertEqual(LauncherLayout.folderPreviewPlateReturnOpacity(from: .nan, at: 0.5), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderPreviewPlateReturnOpacity(from: 0.4, at: .nan), 0, accuracy: 0.001)
    }

    /// Reopening a closing folder used to hide the plate while the panel was
    /// still faint. The plate now gives back the travel curve the panel uses
    /// to fade in. Halfway the travel is mostly done, so the plate is faint.
    /// When the two started complementary, they stay that way. A bad clock
    /// draws nothing.
    func testFolderPreviewPlateYieldsBackWhenTheCloseReverses() {
        XCTAssertEqual(LauncherLayout.folderChromeTravelX1, 0.22, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderChromeTravelY1, 0.7, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderChromeTravelX2, 0.3, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderChromeTravelY2, 1, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderChromeTravelProgress(at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderChromeTravelProgress(at: 1), 1, accuracy: 0.001)
        XCTAssertGreaterThan(LauncherLayout.folderChromeTravelProgress(at: 0.5), 0.75)
        XCTAssertEqual(LauncherLayout.folderChromeTravelProgress(at: .nan), 0, accuracy: 0.001)

        let start: CGFloat = 0.62
        XCTAssertEqual(LauncherLayout.folderPreviewPlateYieldOpacity(from: start, at: 0), start, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderPreviewPlateYieldOpacity(from: start, at: 1), 0, accuracy: 0.001)
        XCTAssertLessThan(
            LauncherLayout.folderPreviewPlateYieldOpacity(from: start, at: 0.5),
            start * 0.3
        )
        var previous = start + 0.01
        for step in 0...10 {
            let time = CGFloat(step) / 10
            let progress = LauncherLayout.folderChromeTravelProgress(at: time)
            let plate = LauncherLayout.folderPreviewPlateYieldOpacity(from: start, at: time)
            let panel = (1 - start) + start * progress
            XCTAssertEqual(plate + panel, 1, accuracy: 0.001)
            XCTAssertLessThanOrEqual(plate, previous)
            previous = plate
        }
        XCTAssertEqual(LauncherLayout.folderPreviewPlateYieldOpacity(from: .nan, at: 0.2), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderPreviewPlateYieldOpacity(from: start, at: .infinity), 0, accuracy: 0.001)
    }

    /// The plate used to wait out a timer interval before its first sample.
    /// A reversed close is ease-out, so that wait jumped the plate while the
    /// panel had already moved. The clock is the frame about to draw.
    func testPreviewPlateFadeUsesTheFrameAboutToDraw() {
        let duration = LauncherLayout.folderChromeTravelDuration
        XCTAssertEqual(
            LauncherLayout.previewPlateFadeTime(elapsed: 0, duration: duration),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LauncherLayout.previewPlateFadeTime(elapsed: -0.02, duration: duration),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LauncherLayout.previewPlateFadeTime(elapsed: duration, duration: duration),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LauncherLayout.previewPlateFadeTime(elapsed: duration + 0.1, duration: duration),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LauncherLayout.previewPlateFadeTime(elapsed: 0.05, duration: 0),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LauncherLayout.previewPlateFadeTime(elapsed: .nan, duration: duration),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LauncherLayout.previewPlateFadeTime(elapsed: 0.02, duration: .infinity),
            0,
            accuracy: 0.000_001
        )
        let frame = LauncherLayout.previewPlateFadeTime(elapsed: 1.0 / 60.0, duration: duration)
        XCTAssertEqual(frame, CGFloat((1.0 / 60.0) / duration), accuracy: 0.000_001)
        let yielded = LauncherLayout.folderPreviewPlateYieldOpacity(from: 1, at: frame)
        XCTAssertLessThan(yielded, 1)
        XCTAssertLessThan(yielded, 1 - frame)
    }

    /// A tracked close used to lift the scrim, the grid's brightness, and the
    /// blur on the travel curve. The panel stays solid until late, so the grid
    /// was already bright and sharp behind it. That veil now waits for the
    /// same late dissolve. Scale does not: the icons still grow back on the
    /// travel curve. Opening, reduced motion, and a centered pop keep one curve.
    func testFolderCloseKeepsTheGridVeiledUntilThePanelDissolves() {
        XCTAssertTrue(LauncherLayout.folderCloseVeilUsesLateDissolve(tracksIcon: true, closing: true))
        XCTAssertFalse(LauncherLayout.folderCloseVeilUsesLateDissolve(tracksIcon: true, closing: false))
        XCTAssertFalse(LauncherLayout.folderCloseVeilUsesLateDissolve(tracksIcon: false, closing: true))
        XCTAssertFalse(LauncherLayout.folderCloseVeilUsesLateDissolve(tracksIcon: false, closing: false))
        let panel = CGRect(x: 100, y: 80, width: 500, height: 360)
        let icon = CGRect(x: 40, y: 420, width: 72, height: 72)
        let tracked = LauncherLayout.folderChromeCollapse(panelFrame: panel, iconFrame: icon, reducesMotion: false)
        let reduced = LauncherLayout.folderChromeCollapse(panelFrame: panel, iconFrame: icon, reducesMotion: true)
        let centered = LauncherLayout.folderChromeCollapse(panelFrame: panel, iconFrame: nil, reducesMotion: false)
        XCTAssertTrue(LauncherLayout.folderCloseVeilUsesLateDissolve(
            tracksIcon: tracked.tracksIcon, closing: true
        ))
        XCTAssertFalse(LauncherLayout.folderCloseVeilUsesLateDissolve(
            tracksIcon: reduced.tracksIcon, closing: true
        ))
        XCTAssertFalse(LauncherLayout.folderCloseVeilUsesLateDissolve(
            tracksIcon: centered.tracksIcon, closing: true
        ))
        XCTAssertFalse(LauncherLayout.folderCloseVeilUsesLateDissolve(
            tracksIcon: LauncherLayout.folderDissolveChrome(reducesMotion: false).tracksIcon,
            closing: true
        ))
        XCTAssertGreaterThan(LauncherLayout.wholeCellMergeFlightOpacity(at: 0.5), 0.8)
    }

    /// The collapsed panel is the preview plate. Its layer radius is divided
    /// by the scale, so the corner on screen matches the plate. Open settles
    /// at 22. Reduced motion, a centered pop, and a dissolve stay at 22.
    func testFolderPanelCornerMatchesThePlateWhenCollapsed() {
        XCTAssertEqual(LauncherLayout.folderPanelCornerRadius, 22, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderPreviewPlateCornerFraction, 0.24, accuracy: 0.001)

        let panel = CGRect(x: 100, y: 80, width: 500, height: 360)
        let icon = CGRect(x: 40, y: 420, width: 72, height: 72)
        let collapse = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: icon,
            reducesMotion: false
        )
        let plateRadius = icon.width * LauncherLayout.folderPreviewPlateCornerFraction
        XCTAssertEqual(collapse.scale, 72.0 / 500.0, accuracy: 0.0001)
        XCTAssertEqual(
            collapse.collapsedCornerRadius * collapse.scale,
            plateRadius,
            accuracy: 0.001
        )
        XCTAssertEqual(collapse.collapsedCornerRadius, plateRadius / collapse.scale, accuracy: 0.001)
        XCTAssertGreaterThan(collapse.collapsedCornerRadius, LauncherLayout.folderPanelCornerRadius)

        let tinyIcon = CGRect(x: 0, y: 0, width: 8, height: 8)
        let tiny = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: tinyIcon,
            reducesMotion: false
        )
        XCTAssertEqual(tiny.scale, LauncherLayout.folderChromeMinimumScale, accuracy: 0.0001)
        XCTAssertEqual(
            tiny.collapsedCornerRadius * tiny.scale,
            tinyIcon.width * LauncherLayout.folderPreviewPlateCornerFraction,
            accuracy: 0.001
        )

        let hugeIcon = CGRect(x: 0, y: 0, width: 900, height: 900)
        let huge = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: hugeIcon,
            reducesMotion: false
        )
        XCTAssertEqual(huge.scale, LauncherLayout.folderChromeMaximumScale, accuracy: 0.0001)
        XCTAssertEqual(
            huge.collapsedCornerRadius * huge.scale,
            hugeIcon.width * LauncherLayout.folderPreviewPlateCornerFraction,
            accuracy: 0.001
        )

        let reduced = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: icon,
            reducesMotion: true
        )
        XCTAssertEqual(reduced.collapsedCornerRadius, 22, accuracy: 0.001)
        let centered = LauncherLayout.folderChromeCollapse(
            panelFrame: panel,
            iconFrame: nil,
            reducesMotion: false
        )
        XCTAssertEqual(centered.collapsedCornerRadius, 22, accuracy: 0.001)
        XCTAssertEqual(
            LauncherLayout.folderDissolveChrome(reducesMotion: false).collapsedCornerRadius,
            22,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LauncherLayout.folderDissolveChrome(reducesMotion: true).collapsedCornerRadius,
            22,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LauncherLayout.folderPanelCollapsedCornerRadius(scale: .nan, iconSide: 72, tracksIcon: true),
            22,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LauncherLayout.folderPanelCollapsedCornerRadius(scale: 0, iconSide: 72, tracksIcon: true),
            22,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LauncherLayout.folderPanelCollapsedCornerRadius(scale: 1, iconSide: 72, tracksIcon: true),
            22,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LauncherLayout.folderPanelCollapsedCornerRadius(scale: 0.2, iconSide: 0, tracksIcon: true),
            22,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LauncherLayout.folderPanelCollapsedCornerRadius(scale: 0.2, iconSide: 72, tracksIcon: false),
            22,
            accuracy: 0.001
        )
    }

    /// The icon still on the pointer is not flown again. The one left in the
    /// folder is, in member order. An app that never reached the grid is not.
    func testAppsScatteredFromDissolvedFolderSkipsTheDraggedIcon() {
        let kept = UUID()
        let dragged = UUID()
        let gone = UUID()
        let neighbor = UUID()
        let entries: [LauncherEntry] = [.app(neighbor), .app(dragged), .app(kept)]
        XCTAssertEqual(
            LauncherLayout.appsScatteredFromDissolvedFolder(
                memberIDs: [kept, dragged, gone, kept],
                draggedItemID: dragged,
                currentEntries: entries
            ),
            [kept]
        )
        XCTAssertEqual(
            LauncherLayout.appsScatteredFromDissolvedFolder(
                memberIDs: [kept, dragged],
                draggedItemID: nil,
                currentEntries: [.app(kept)]
            ),
            [kept]
        )
        XCTAssertEqual(
            LauncherLayout.appsScatteredFromDissolvedFolder(
                memberIDs: [dragged],
                draggedItemID: dragged,
                currentEntries: [.app(dragged)]
            ),
            []
        )
        XCTAssertEqual(
            LauncherLayout.appsScatteredFromDissolvedFolder(
                memberIDs: [],
                draggedItemID: nil,
                currentEntries: [.app(neighbor)]
            ),
            []
        )
    }

    /// Leftover icons travel from the open folder to the grid on the merge
    /// flight's clock. Reduced motion, a bad frame, a repeat, and a hop
    /// under a point do not travel. The panel fades with that flight instead
    /// of snapping shut.
    func testFolderDissolveFlightsUseTheMergeTiming() {
        let kept = UUID()
        let other = UUID()
        let source = CGRect(x: 180, y: 240, width: 64, height: 64)
        let destination = CGRect(x: 40, y: 80, width: 72, height: 72)
        let flight = LauncherLayout.folderDissolveFlights(
            placements: [
                LauncherLayout.FolderDissolveIconPlacement(itemID: kept, source: source, destination: destination),
                LauncherLayout.FolderDissolveIconPlacement(itemID: kept, source: source, destination: destination),
                LauncherLayout.FolderDissolveIconPlacement(
                    itemID: other,
                    source: CGRect(x: 10, y: 10, width: 64, height: 64),
                    destination: CGRect(x: 10.2, y: 10.2, width: 64.2, height: 64.2)
                )
            ],
            reducesMotion: false
        )
        XCTAssertEqual(flight.count, 1)
        XCTAssertEqual(flight[0].itemID, kept)
        XCTAssertEqual(flight[0].source, source)
        XCTAssertEqual(flight[0].destination, destination)
        XCTAssertEqual(flight[0].duration, LauncherLayout.folderDissolveFlightDuration, accuracy: 0.001)
        XCTAssertEqual(flight[0].duration, LauncherLayout.folderChromeTravelDuration, accuracy: 0.001)
        XCTAssertEqual(flight[0].duration, 0.34, accuracy: 0.001)

        XCTAssertEqual(
            LauncherLayout.folderDissolveFlights(
                placements: [
                    LauncherLayout.FolderDissolveIconPlacement(itemID: kept, source: source, destination: destination)
                ],
                reducesMotion: true
            ),
            []
        )
        XCTAssertEqual(
            LauncherLayout.folderDissolveFlights(
                placements: [
                    LauncherLayout.FolderDissolveIconPlacement(
                        itemID: kept,
                        source: .zero,
                        destination: destination
                    ),
                    LauncherLayout.FolderDissolveIconPlacement(
                        itemID: other,
                        source: source,
                        destination: CGRect(x: CGFloat.nan, y: 0, width: 72, height: 72)
                    )
                ],
                reducesMotion: false
            ),
            []
        )

        let chrome = LauncherLayout.folderDissolveChrome(reducesMotion: false)
        XCTAssertFalse(chrome.tracksIcon)
        XCTAssertTrue(chrome.animatesTransform)
        XCTAssertEqual(chrome.scale, LauncherLayout.folderBackdropOpenScale, accuracy: 0.001)
        XCTAssertEqual(chrome.translationX, 0, accuracy: 0.001)
        XCTAssertEqual(chrome.translationY, 0, accuracy: 0.001)
        XCTAssertEqual(chrome.panelOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(chrome.duration, LauncherLayout.folderDissolveFlightDuration, accuracy: 0.001)

        let reduced = LauncherLayout.folderDissolveChrome(reducesMotion: true)
        XCTAssertFalse(reduced.animatesTransform)
        XCTAssertEqual(reduced.scale, 1, accuracy: 0.001)
        XCTAssertEqual(reduced.duration, 0, accuracy: 0.001)

        XCTAssertTrue(LauncherLayout.shouldPlayFolderDissolveScatter(
            reducesMotion: false, isDismissing: false, isVisible: true
        ))
        XCTAssertFalse(LauncherLayout.shouldPlayFolderDissolveScatter(
            reducesMotion: true, isDismissing: false, isVisible: true
        ))
        XCTAssertFalse(LauncherLayout.shouldPlayFolderDissolveScatter(
            reducesMotion: false, isDismissing: true, isVisible: true
        ))
        XCTAssertFalse(LauncherLayout.shouldPlayFolderDissolveScatter(
            reducesMotion: false, isDismissing: false, isVisible: false
        ))
    }

    /// The scatter completion is already on the main thread. Another hop
    /// leaves the flying picture sitting on the cell. Commit on this turn.
    /// A callback off the main thread still hops.
    func testFlightLandingCommitsOnTheTurnThatArrives() {
        XCTAssertTrue(LauncherLayout.flightLandingCommitsOnThisTurn(isMainThread: true))
        XCTAssertFalse(LauncherLayout.flightLandingCommitsOnThisTurn(isMainThread: false))
    }

    /// The open-folder flight leaves the same 3×3 the preview plate draws.
    /// Nine glyphs, top row first. Reduced motion, a bad frame, a repeat, and
    /// a hop under a point do not travel. The clock matches the panel.
    func testFolderPreviewGlyphsUseThePlateMathAndTheMergeTiming() {
        let well = CGRect(x: 10, y: 20, width: 64, height: 64)
        let frames = LauncherLayout.folderPreviewGlyphFrames(well: well, count: 12)
        XCTAssertEqual(frames.count, 9)
        XCTAssertEqual(frames[0], CGRect(x: 15, y: 63, width: 16, height: 16))
        XCTAssertEqual(frames[1], CGRect(x: 33, y: 63, width: 16, height: 16))
        XCTAssertEqual(frames[3], CGRect(x: 15, y: 45, width: 16, height: 16))
        XCTAssertEqual(frames[8], CGRect(x: 51, y: 27, width: 16, height: 16))
        XCTAssertGreaterThan(frames[0].minY, frames[3].minY)
        XCTAssertEqual(
            LauncherLayout.folderPreviewGlyphFrames(well: well, count: 0),
            []
        )
        XCTAssertEqual(
            LauncherLayout.folderPreviewGlyphFrames(well: CGRect(x: 0, y: 0, width: 16, height: 16), count: 4),
            []
        )
        XCTAssertEqual(
            LauncherLayout.folderPreviewGlyphFrames(
                well: CGRect(x: CGFloat.nan, y: 0, width: 64, height: 64),
                count: 2
            ),
            []
        )

        let first = UUID()
        let second = UUID()
        let source = frames[0]
        let destination = CGRect(x: 200, y: 180, width: 72, height: 72)
        let flights = LauncherLayout.folderPreviewGlyphFlights(
            placements: [
                LauncherLayout.FolderPreviewGlyphPlacement(itemID: first, source: source, destination: destination),
                LauncherLayout.FolderPreviewGlyphPlacement(itemID: first, source: source, destination: destination),
                LauncherLayout.FolderPreviewGlyphPlacement(
                    itemID: second,
                    source: frames[1],
                    destination: CGRect(x: frames[1].minX + 0.2, y: frames[1].minY, width: 16, height: 16)
                )
            ],
            reducesMotion: false
        )
        XCTAssertEqual(flights.count, 1)
        XCTAssertEqual(flights[0].itemID, first)
        XCTAssertEqual(flights[0].source, source)
        XCTAssertEqual(flights[0].destination, destination)
        XCTAssertEqual(flights[0].duration, LauncherLayout.folderPreviewGlyphFlightDuration, accuracy: 0.001)
        XCTAssertEqual(flights[0].duration, LauncherLayout.folderChromeTravelDuration, accuracy: 0.001)
        XCTAssertEqual(flights[0].duration, 0.34, accuracy: 0.001)
        XCTAssertEqual(
            LauncherLayout.folderPreviewGlyphFlights(
                placements: [
                    LauncherLayout.FolderPreviewGlyphPlacement(itemID: first, source: source, destination: destination)
                ],
                reducesMotion: true
            ),
            []
        )
        XCTAssertEqual(
            LauncherLayout.folderPreviewGlyphFlights(
                placements: [
                    LauncherLayout.FolderPreviewGlyphPlacement(itemID: first, source: .zero, destination: destination),
                    LauncherLayout.FolderPreviewGlyphPlacement(
                        itemID: second,
                        source: source,
                        destination: CGRect(x: CGFloat.nan, y: 0, width: 72, height: 72)
                    )
                ],
                reducesMotion: false
            ),
            []
        )
        XCTAssertTrue(LauncherLayout.shouldPlayFolderPreviewGlyphFlight(
            reducesMotion: false, isDismissing: false, isVisible: true, tracksIcon: true
        ))
        XCTAssertFalse(LauncherLayout.shouldPlayFolderPreviewGlyphFlight(
            reducesMotion: false, isDismissing: false, isVisible: true, tracksIcon: false
        ))
        XCTAssertFalse(LauncherLayout.shouldPlayFolderPreviewGlyphFlight(
            reducesMotion: true, isDismissing: false, isVisible: true, tracksIcon: true
        ))
        XCTAssertFalse(LauncherLayout.shouldPlayFolderPreviewGlyphFlight(
            reducesMotion: false, isDismissing: true, isVisible: true, tracksIcon: true
        ))
        XCTAssertFalse(LauncherLayout.shouldPlayFolderPreviewGlyphFlight(
            reducesMotion: false, isDismissing: false, isVisible: false, tracksIcon: true
        ))
    }

    /// Closing a folder sends each icon back along the path it opened on.
    /// The cell is the start and the glyph on the plate is the end. The clock
    /// stays 0.34s, with no stagger. Reduced motion, a bad frame, a repeat,
    /// and a hop under a point stay put. The gate matches the flight in.
    func testFolderPreviewGlyphReturnUsesTheOpenPathInReverse() {
        let well = CGRect(x: 10, y: 20, width: 64, height: 64)
        let glyphs = LauncherLayout.folderPreviewGlyphFrames(well: well, count: 3)
        XCTAssertEqual(glyphs.count, 3)
        let cells = [
            CGRect(x: 200, y: 300, width: 64, height: 64),
            CGRect(x: 280, y: 300, width: 64, height: 64),
            CGRect(x: 360, y: 300, width: 64, height: 64)
        ]
        let ids = [UUID(), UUID(), UUID()]
        var outboundPlacements: [LauncherLayout.FolderPreviewGlyphPlacement] = []
        var returnPlacements: [LauncherLayout.FolderPreviewGlyphPlacement] = []
        for index in 0..<3 {
            outboundPlacements.append(LauncherLayout.FolderPreviewGlyphPlacement(
                itemID: ids[index], source: glyphs[index], destination: cells[index]
            ))
            returnPlacements.append(LauncherLayout.FolderPreviewGlyphPlacement(
                itemID: ids[index], source: cells[index], destination: glyphs[index]
            ))
        }
        let outbound = LauncherLayout.folderPreviewGlyphFlights(
            placements: outboundPlacements,
            reducesMotion: false
        )
        let returning = LauncherLayout.folderPreviewGlyphReturnFlights(
            placements: returnPlacements,
            reducesMotion: false
        )
        XCTAssertEqual(returning.count, 3)
        XCTAssertEqual(outbound.count, returning.count)
        for index in 0..<3 {
            XCTAssertEqual(returning[index].itemID, ids[index])
            XCTAssertEqual(returning[index].source, cells[index])
            XCTAssertEqual(returning[index].destination, glyphs[index])
            XCTAssertEqual(outbound[index].source, returning[index].destination)
            XCTAssertEqual(outbound[index].destination, returning[index].source)
            XCTAssertEqual(returning[index].duration, 0.34, accuracy: 0.001)
            XCTAssertEqual(returning[index].duration, outbound[index].duration, accuracy: 0.001)
            XCTAssertEqual(returning[index].duration, LauncherLayout.folderChromeTravelDuration, accuracy: 0.001)
        }

        let repeated = ids[0]
        XCTAssertEqual(
            LauncherLayout.folderPreviewGlyphReturnFlights(
                placements: [
                    LauncherLayout.FolderPreviewGlyphPlacement(
                        itemID: repeated, source: cells[0], destination: glyphs[0]
                    ),
                    LauncherLayout.FolderPreviewGlyphPlacement(
                        itemID: repeated, source: cells[1], destination: glyphs[1]
                    ),
                    LauncherLayout.FolderPreviewGlyphPlacement(
                        itemID: ids[1],
                        source: cells[2],
                        destination: CGRect(
                            x: cells[2].minX + 0.2,
                            y: cells[2].minY,
                            width: cells[2].width,
                            height: cells[2].height
                        )
                    )
                ],
                reducesMotion: false
            ).map(\.itemID),
            [repeated]
        )
        XCTAssertEqual(
            LauncherLayout.folderPreviewGlyphReturnFlights(
                placements: returnPlacements,
                reducesMotion: true
            ),
            []
        )
        XCTAssertEqual(
            LauncherLayout.folderPreviewGlyphReturnFlights(
                placements: [
                    LauncherLayout.FolderPreviewGlyphPlacement(
                        itemID: ids[0], source: .zero, destination: glyphs[0]
                    ),
                    LauncherLayout.FolderPreviewGlyphPlacement(
                        itemID: ids[1],
                        source: cells[1],
                        destination: CGRect(x: CGFloat.nan, y: 0, width: 16, height: 16)
                    )
                ],
                reducesMotion: false
            ),
            []
        )

        let gates: [(Bool, Bool, Bool, Bool)] = [
            (false, false, true, true),
            (false, false, true, false),
            (true, false, true, true),
            (false, true, true, true),
            (false, false, false, true)
        ]
        for gate in gates {
            XCTAssertEqual(
                LauncherLayout.shouldPlayFolderPreviewGlyphReturn(
                    reducesMotion: gate.0,
                    isDismissing: gate.1,
                    isVisible: gate.2,
                    tracksIcon: gate.3
                ),
                LauncherLayout.shouldPlayFolderPreviewGlyphFlight(
                    reducesMotion: gate.0,
                    isDismissing: gate.1,
                    isVisible: gate.2,
                    tracksIcon: gate.3
                )
            )
        }
        XCTAssertTrue(LauncherLayout.shouldPlayFolderPreviewGlyphReturn(
            reducesMotion: false, isDismissing: false, isVisible: true, tracksIcon: true
        ))
        XCTAssertFalse(LauncherLayout.shouldPlayFolderPreviewGlyphReturn(
            reducesMotion: false, isDismissing: false, isVisible: true, tracksIcon: false
        ))
    }

    /// An icon past the nine preview slots sinks into the plate center when
    /// the folder closes. That fade is the whole-cell dissolve, so the icon
    /// is still bright halfway home. Opening fades it back in with the flight.
    func testOverflowIconStaysVisibleUntilItSinksBackIntoThePlate() {
        XCTAssertFalse(LauncherLayout.folderOverflowIconFadeSharesFlightEase(returningToPlate: true))
        XCTAssertTrue(LauncherLayout.folderOverflowIconFadeSharesFlightEase(returningToPlate: false))
        XCTAssertGreaterThan(LauncherLayout.wholeCellMergeFlightOpacity(at: 0.5), 0.8)
        XCTAssertLessThan(LauncherLayout.wholeCellMergeFlightOpacity(at: 0.9), 0.4)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFlightOpacity(at: 0), 1, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFlightOpacity(at: 1), 0, accuracy: 0.001)
    }

    /// Opening a folder used to pop icons past the nine preview slots on at
    /// the last frame. They fade in on the same dissolve, still hidden
    /// halfway through, and only as the folder settles. Closing does not
    /// run that fade.

    func testToastClearAndRestoreOpacityParityWithStatus() {
        XCTAssertTrue(
            LauncherLayout.toastShouldClearOpacityBeforeUnhide(
                willShow: true,
                currentlyHidden: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.toastShouldClearOpacityBeforeUnhide(
                willShow: true,
                currentlyHidden: false
            )
        )
        XCTAssertTrue(
            LauncherLayout.toastShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 0.2
            )
        )
        XCTAssertFalse(
            LauncherLayout.toastShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 1.0
            )
        )
        XCTAssertFalse(
            LauncherLayout.toastShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: true,
                currentOpacity: 0.0
            )
        )
        XCTAssertEqual(
            LauncherLayout.toastShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 0.5
            ),
            LauncherLayout.statusChromeShouldRestoreOpacityWhenAlreadyShown(
                currentlyHidden: false,
                currentOpacity: 0.5
            )
        )
        XCTAssertEqual(
            LauncherLayout.toastShouldClearOpacityBeforeUnhide(
                willShow: true,
                currentlyHidden: true
            ),
            LauncherLayout.settingsMessageShouldClearOpacityBeforeUnhide(
                willShow: true,
                currentlyHidden: true
            )
        )
    }

    func testToastFadeUsesPresentationBackedDurationAndKey() {
        XCTAssertEqual(LauncherLayout.toastFadeDuration, 0.12, accuracy: 0.0001)
        XCTAssertEqual(LauncherLayout.toastFadeAnimationKey, "toast-fade")
        XCTAssertEqual(LauncherLayout.toastFadeDuration, LauncherLayout.searchTransitionDuration, accuracy: 0.0001)
    }

    func testHostCrossfadeAnimationKeysHoldPresentationPolicy() {
        XCTAssertEqual(LauncherLayout.searchChromeFadeAnimationKey, "search-chrome-fade")
        XCTAssertEqual(LauncherLayout.pageHostFadeAnimationKey, "page-host-fade")
        XCTAssertEqual(LauncherLayout.dissolvedGridFadeAnimationKey, "dissolved-grid-fade")
        // Crossfade still lands incoming at full opacity when not a folder backdrop.
        let fade = LauncherLayout.searchChromeFade(
            reducesMotion: false,
            holdsForLauncherFade: false,
            incomingIsFolderBackdrop: false
        )
        XCTAssertEqual(fade.incomingOpacity, 1, accuracy: 0.001)
        XCTAssertEqual(fade.outgoingOpacity, 0, accuracy: 0.001)
        XCTAssertGreaterThan(fade.duration, 0)
    }

    func testOverflowIconsFadeInAsTheFolderSettles() {
        XCTAssertTrue(LauncherLayout.shouldFadeFolderOverflowIconsIn(opening: true))
        XCTAssertFalse(LauncherLayout.shouldFadeFolderOverflowIconsIn(opening: false))
        XCTAssertEqual(LauncherLayout.folderOverflowIconRevealOpacity(at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderOverflowIconRevealOpacity(at: 1), 1, accuracy: 0.001)
        XCTAssertLessThan(LauncherLayout.folderOverflowIconRevealOpacity(at: 0.5), 0.25)
        XCTAssertGreaterThan(LauncherLayout.folderOverflowIconRevealOpacity(at: 0.9), 0.6)
        XCTAssertEqual(
            LauncherLayout.folderOverflowIconRevealOpacity(at: 0.5),
            1 - LauncherLayout.wholeCellMergeFlightOpacity(at: 0.5),
            accuracy: 0.001
        )
        XCTAssertEqual(LauncherLayout.folderOverflowOpenFadeAnimationKey, "overflow-open-fade")
    }

    /// Creating a folder lands the icon that was already there in the first
    /// preview slot, and the dropped icon in the second. Same 3×3, same 0.34s
    /// clock, no stagger. Reduced motion, a missing slot, a bad frame, and a
    /// hop under a point do not travel, so the caller can keep the old flight.
    func testFolderMergePreviewLandingsUseTheFirstTwoSlots() {
        let well = CGRect(x: 10, y: 20, width: 64, height: 64)
        let slots = LauncherLayout.folderPreviewGlyphFrames(well: well, count: 2)
        XCTAssertEqual(slots.count, 2)
        XCTAssertLessThan(slots[0].minX, slots[1].minX)
        XCTAssertEqual(slots[0].minY, slots[1].minY)
        XCTAssertEqual(slots[0], CGRect(x: 15, y: 63, width: 16, height: 16))
        XCTAssertEqual(slots[1], CGRect(x: 33, y: 63, width: 16, height: 16))

        let resident = CGRect(x: 100, y: 200, width: 64, height: 64)
        let incoming = CGRect(x: 280, y: 180, width: 48, height: 48)
        let landings = LauncherLayout.folderMergePreviewLandings(
            resident: resident,
            incoming: incoming,
            destinations: slots,
            reducesMotion: false
        )
        XCTAssertEqual(landings.count, 2)
        XCTAssertEqual(landings[0].source, resident)
        XCTAssertEqual(landings[0].destination, slots[0])
        XCTAssertEqual(landings[1].source, incoming)
        XCTAssertEqual(landings[1].destination, slots[1])
        XCTAssertEqual(landings[0].duration, 0.34, accuracy: 0.001)
        XCTAssertEqual(landings[1].duration, LauncherLayout.folderChromeTravelDuration, accuracy: 0.001)
        XCTAssertEqual(landings[0].duration, landings[1].duration, accuracy: 0.001)

        let nine = LauncherLayout.folderPreviewGlyphFrames(well: well, count: 9)
        let trimmed = LauncherLayout.folderMergePreviewLandings(
            resident: resident,
            incoming: incoming,
            destinations: nine,
            reducesMotion: false
        )
        XCTAssertEqual(trimmed.count, 2)
        XCTAssertEqual(trimmed[0].destination, nine[0])
        XCTAssertEqual(trimmed[1].destination, nine[1])
        XCTAssertNotEqual(trimmed[1].destination, nine[2])

        XCTAssertEqual(
            LauncherLayout.folderMergePreviewLandings(
                resident: resident,
                incoming: incoming,
                destinations: slots,
                reducesMotion: true
            ),
            []
        )
        XCTAssertEqual(
            LauncherLayout.folderMergePreviewLandings(
                resident: resident,
                incoming: incoming,
                destinations: [slots[0]],
                reducesMotion: false
            ),
            []
        )
        XCTAssertEqual(
            LauncherLayout.folderMergePreviewLandings(
                resident: .zero,
                incoming: incoming,
                destinations: slots,
                reducesMotion: false
            ),
            []
        )
        XCTAssertEqual(
            LauncherLayout.folderMergePreviewLandings(
                resident: resident,
                incoming: CGRect(x: CGFloat.nan, y: 0, width: 48, height: 48),
                destinations: slots,
                reducesMotion: false
            ),
            []
        )
        XCTAssertEqual(
            LauncherLayout.folderMergePreviewLandings(
                resident: resident,
                incoming: incoming,
                destinations: [slots[0], .zero],
                reducesMotion: false
            ),
            []
        )
        XCTAssertEqual(
            LauncherLayout.folderMergePreviewLandings(
                resident: slots[0],
                incoming: incoming,
                destinations: slots,
                reducesMotion: false
            ),
            []
        )
        XCTAssertEqual(
            LauncherLayout.folderMergePreviewLandings(
                resident: resident,
                incoming: slots[1].offsetBy(dx: 0.2, dy: 0),
                destinations: slots,
                reducesMotion: false
            ),
            []
        )
    }

    /// Creating a folder used to show the plate at full opacity on the first
    /// frame. It now fades in over the early part of the 0.34s flight, ahead
    /// of a straight line, and is solid before the icons land.
    func testNewFolderPlateFadesInBeforeTheIconsLand() {
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealFraction, 0.45, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealX1, 0.22, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealY1, 0.7, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealX2, 0.3, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealY2, 1, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealOpacity(at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealOpacity(at: -0.2), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealOpacity(at: 0.45), 1, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealOpacity(at: 1), 1, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealOpacity(at: 1.4), 1, accuracy: 0.001)

        let early = LauncherLayout.folderMergePlateRevealOpacity(at: 0.1)
        XCTAssertGreaterThan(early, 0.5)
        XCTAssertLessThan(early, 0.75)
        XCTAssertGreaterThan(
            LauncherLayout.folderMergePlateRevealOpacity(at: 0.2),
            0.2 / LauncherLayout.folderMergePlateRevealFraction
        )
        XCTAssertGreaterThan(LauncherLayout.folderMergePlateRevealOpacity(at: 0.3), 0.9)
        let opening = LauncherLayout.folderMergePlateRevealOpacity(at: 0.15)
        let settling = 1 - LauncherLayout.folderMergePlateRevealOpacity(at: 0.3)
        XCTAssertGreaterThan(opening, settling * 4)

        var previous: CGFloat = -0.001
        for step in 0...20 {
            let opacity = LauncherLayout.folderMergePlateRevealOpacity(at: CGFloat(step) / 20)
            if previous < 1 {
                XCTAssertGreaterThan(opacity, previous)
            } else {
                XCTAssertEqual(opacity, 1, accuracy: 0.001)
            }
            XCTAssertLessThanOrEqual(opacity, 1)
            previous = opacity
        }

        let flight = LauncherLayout.folderChromeTravelDuration
        let duration = LauncherLayout.folderMergePlateRevealDuration(flight: flight)
        XCTAssertEqual(duration, flight * 0.45, accuracy: 0.000_1)
        XCTAssertGreaterThan(duration, 0.1)
        XCTAssertLessThan(duration, flight)
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealDuration(flight: 0), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealDuration(flight: -0.2), 0, accuracy: 0.001)

        let scale = LauncherLayout.folderMergePlateRevealScaleStart
        XCTAssertGreaterThan(scale, 0.7)
        XCTAssertLessThan(scale, 0.9)
        let center = CGPoint(x: 48, y: 69)
        let shift = LauncherLayout.folderMergePlateRevealTranslation(iconCenter: center)
        XCTAssertEqual(shift.x, center.x * (1 - scale), accuracy: 0.001)
        XCTAssertEqual(shift.y, center.y * (1 - scale), accuracy: 0.001)
        XCTAssertGreaterThan(shift.x, 1)
        XCTAssertGreaterThan(shift.y, 1)
        XCTAssertEqual(center.x * scale + shift.x, center.x, accuracy: 0.001)
        XCTAssertEqual(center.y * scale + shift.y, center.y, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.folderMergePlateRevealTranslation(iconCenter: .zero), .zero)
        XCTAssertEqual(
            LauncherLayout.folderMergePlateRevealTranslation(iconCenter: CGPoint(x: CGFloat.nan, y: 4)),
            .zero
        )
        XCTAssertEqual(
            LauncherLayout.folderMergePlateRevealTranslation(iconCenter: CGPoint(x: 10, y: CGFloat.nan)),
            .zero
        )
        let negative = CGPoint(x: -8, y: 20)
        let negativeShift = LauncherLayout.folderMergePlateRevealTranslation(iconCenter: negative)
        XCTAssertEqual(negativeShift.x, negative.x * (1 - scale), accuracy: 0.001)
        XCTAssertEqual(negative.y * scale + negativeShift.y, negative.y, accuracy: 0.001)
    }

    /// Dropping into a folder that already exists lands the new icon in the
    /// next empty preview slot. Two icons already on the plate means the
    /// third cell, not the second. A full plate of nine does not grow.
    /// Same 0.34s clock. Reduced motion, a bad frame, and a hop under a
    /// point do not travel.
    func testFolderIncomingPreviewLandingUsesTheNextEmptySlot() throws {
        XCTAssertEqual(LauncherLayout.folderIncomingPreviewSlotIndex(glyphsBefore: 0, glyphsAfter: 1), 0)
        XCTAssertEqual(LauncherLayout.folderIncomingPreviewSlotIndex(glyphsBefore: 2, glyphsAfter: 3), 2)
        XCTAssertEqual(LauncherLayout.folderIncomingPreviewSlotIndex(glyphsBefore: 8, glyphsAfter: 9), 8)
        XCTAssertNil(LauncherLayout.folderIncomingPreviewSlotIndex(glyphsBefore: 9, glyphsAfter: 9))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewSlotIndex(glyphsBefore: 9, glyphsAfter: 10))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewSlotIndex(glyphsBefore: 3, glyphsAfter: 3))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewSlotIndex(glyphsBefore: 3, glyphsAfter: 5))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewSlotIndex(glyphsBefore: -1, glyphsAfter: 0))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewSlotIndex(glyphsBefore: 1, glyphsAfter: 0))

        let well = CGRect(x: 10, y: 20, width: 64, height: 64)
        let three = LauncherLayout.folderPreviewGlyphFrames(well: well, count: 3)
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(three[2], CGRect(x: 51, y: 63, width: 16, height: 16))
        XCTAssertNotEqual(three[2], three[1])

        let incoming = CGRect(x: 280, y: 180, width: 48, height: 48)
        let landing = LauncherLayout.folderIncomingPreviewLanding(
            incoming: incoming,
            destination: three[2],
            reducesMotion: false
        )
        XCTAssertEqual(landing?.source, incoming)
        XCTAssertEqual(landing?.destination, three[2])
        let duration = try XCTUnwrap(landing?.duration)
        XCTAssertEqual(duration, 0.34, accuracy: 0.001)
        XCTAssertEqual(duration, LauncherLayout.folderChromeTravelDuration, accuracy: 0.001)
        let created = LauncherLayout.folderMergePreviewLandings(
            resident: CGRect(x: 100, y: 200, width: 64, height: 64),
            incoming: incoming,
            destinations: Array(three.prefix(2)),
            reducesMotion: false
        )
        XCTAssertEqual(duration, try XCTUnwrap(created.first?.duration), accuracy: 0.001)

        let nine = LauncherLayout.folderPreviewGlyphFrames(well: well, count: 9)
        XCTAssertEqual(nine[8], CGRect(x: 51, y: 27, width: 16, height: 16))
        let lastSlot = LauncherLayout.folderIncomingPreviewLanding(
            incoming: incoming,
            destination: nine[8],
            reducesMotion: false
        )
        XCTAssertEqual(lastSlot?.destination, nine[8])
        XCTAssertNotEqual(lastSlot?.destination, nine[0])

        XCTAssertNil(LauncherLayout.folderIncomingPreviewLanding(
            incoming: incoming,
            destination: three[2],
            reducesMotion: true
        ))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewLanding(
            incoming: .zero,
            destination: three[2],
            reducesMotion: false
        ))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewLanding(
            incoming: incoming,
            destination: .zero,
            reducesMotion: false
        ))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewLanding(
            incoming: CGRect(x: CGFloat.nan, y: 0, width: 48, height: 48),
            destination: three[2],
            reducesMotion: false
        ))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewLanding(
            incoming: three[2].offsetBy(dx: 0.2, dy: 0),
            destination: three[2],
            reducesMotion: false
        ))
    }

    /// A full plate has no empty slot, so the dropped icon shrinks into the
    /// middle of the plate instead of the whole cell. Same 0.34s clock.
    /// The fade is the whole-cell dissolve: still bright halfway through the
    /// shrink, gone as it settles. The square stays centered and is not one
    /// of the nine glyphs. Reduced motion, a bad frame, and a hop under a
    /// point do not travel.
    func testFolderIncomingPreviewCenterLandingShrinksIntoAFullPlate() throws {
        XCTAssertEqual(LauncherLayout.folderPreviewPlateCenterInsetFraction, 0.36, accuracy: 0.001)
        XCTAssertNil(LauncherLayout.folderIncomingPreviewSlotIndex(glyphsBefore: 9, glyphsAfter: 9))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewSlotIndex(glyphsBefore: 9, glyphsAfter: 10))

        let well = CGRect(x: 10, y: 20, width: 64, height: 64)
        let center = try XCTUnwrap(LauncherLayout.folderPreviewPlateCenterFrame(well: well))
        XCTAssertEqual(center, CGRect(x: 33, y: 43, width: 18, height: 18))
        XCTAssertEqual(center.midX, well.midX, accuracy: 0.001)
        XCTAssertEqual(center.midY, well.midY, accuracy: 0.001)
        XCTAssertLessThan(center.width, well.width * 0.5)
        XCTAssertLessThan(center.height, well.height * 0.5)
        XCTAssertTrue(well.contains(center))

        let nine = LauncherLayout.folderPreviewGlyphFrames(well: well, count: 9)
        XCTAssertEqual(nine.count, 9)
        XCTAssertFalse(nine.contains(center))

        let wide = CGRect(x: 0, y: 0, width: 100, height: 40)
        let wideCenter = try XCTUnwrap(LauncherLayout.folderPreviewPlateCenterFrame(well: wide))
        XCTAssertEqual(wideCenter, CGRect(x: 36, y: 14, width: 28, height: 12))
        XCTAssertEqual(wideCenter.midX, wide.midX, accuracy: 0.001)
        XCTAssertEqual(wideCenter.midY, wide.midY, accuracy: 0.001)

        let incoming = CGRect(x: 280, y: 180, width: 48, height: 48)
        let landing = LauncherLayout.folderIncomingPreviewCenterLanding(
            incoming: incoming,
            well: well,
            reducesMotion: false
        )
        XCTAssertEqual(landing?.source, incoming)
        XCTAssertEqual(landing?.destination, center)
        let duration = try XCTUnwrap(landing?.duration)
        XCTAssertEqual(duration, 0.34, accuracy: 0.001)
        XCTAssertEqual(duration, LauncherLayout.folderChromeTravelDuration, accuracy: 0.001)
        // The shrink keeps this clock. The fade is the whole-cell dissolve,
        // so halfway through the shrink the icon is still bright.
        XCTAssertGreaterThan(LauncherLayout.wholeCellMergeFlightOpacity(at: 0.5), 0.8)
        XCTAssertLessThan(LauncherLayout.wholeCellMergeFlightOpacity(at: 0.9), 0.4)
        let slotLanding = LauncherLayout.folderIncomingPreviewLanding(
            incoming: incoming,
            destination: nine[8],
            reducesMotion: false
        )
        XCTAssertEqual(duration, try XCTUnwrap(slotLanding?.duration), accuracy: 0.001)
        XCTAssertNotEqual(landing?.destination, slotLanding?.destination)

        XCTAssertNil(LauncherLayout.folderIncomingPreviewCenterLanding(
            incoming: incoming,
            well: well,
            reducesMotion: true
        ))
        XCTAssertNil(LauncherLayout.folderPreviewPlateCenterFrame(well: .zero))
        XCTAssertNil(LauncherLayout.folderPreviewPlateCenterFrame(
            well: CGRect(x: 0, y: 0, width: 0.4, height: 40)
        ))
        XCTAssertNil(LauncherLayout.folderPreviewPlateCenterFrame(
            well: CGRect(x: CGFloat.nan, y: 0, width: 64, height: 64)
        ))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewCenterLanding(
            incoming: .zero,
            well: well,
            reducesMotion: false
        ))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewCenterLanding(
            incoming: CGRect(x: CGFloat.nan, y: 0, width: 48, height: 48),
            well: well,
            reducesMotion: false
        ))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewCenterLanding(
            incoming: incoming,
            well: .zero,
            reducesMotion: false
        ))
        XCTAssertNil(LauncherLayout.folderIncomingPreviewCenterLanding(
            incoming: center.offsetBy(dx: 0.2, dy: 0),
            well: well,
            reducesMotion: false
        ))
    }

    /// A merge that cannot measure a preview slot still flies onto the whole
    /// cell. Opacity used to share that flight's ease-out, so the icon was
    /// already faint before it arrived. It now stays readable through the
    /// first half and dissolves only as the flight settles.
    func testWholeCellMergeStaysVisibleUntilTheIconReachesTheCell() {
        XCTAssertEqual(LauncherLayout.wholeCellMergeFadeX1, 0.55, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFadeY1, 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFadeX2, 0.82, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFadeY2, 0.28, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFlightOpacity(at: 0), 1, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFlightOpacity(at: 1), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFlightOpacity(at: -0.2), 1, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFlightOpacity(at: 1.4), 0, accuracy: 0.001)

        let early = LauncherLayout.wholeCellMergeFlightOpacity(at: 0.3)
        let halfway = LauncherLayout.wholeCellMergeFlightOpacity(at: 0.5)
        let settling = LauncherLayout.wholeCellMergeFlightOpacity(at: 0.85)
        XCTAssertGreaterThan(early, 0.9)
        XCTAssertGreaterThan(halfway, 0.8)
        XCTAssertLessThan(settling, 0.5)
        XCTAssertGreaterThan(settling, 0.3)
        let earlyDrop = LauncherLayout.wholeCellMergeFlightOpacity(at: 0.1)
            - LauncherLayout.wholeCellMergeFlightOpacity(at: 0.3)
        let lateDrop = LauncherLayout.wholeCellMergeFlightOpacity(at: 0.7)
            - LauncherLayout.wholeCellMergeFlightOpacity(at: 0.9)
        XCTAssertGreaterThan(lateDrop, earlyDrop * 4)
        XCTAssertLessThan(earlyDrop, 0.08)
    }

    /// A whole-cell merge flies the lifted cell, and the drag image's shadow
    /// is not in that picture. The shadow fades on the same early clock as a
    /// drop into a cell, and is gone while the icon is still readable. The
    /// icon itself dissolves later.
    func testWholeCellMergeDropsTheLiftShadowWhileTheIconStaysVisible() {
        let gone = LauncherLayout.dropLandingShadowFadeFraction
        XCTAssertEqual(LauncherLayout.dropLandingShadowOpacity(at: gone), 0, accuracy: 0.001)
        XCTAssertGreaterThan(LauncherLayout.wholeCellMergeFlightOpacity(at: gone), 0.8)
        XCTAssertGreaterThan(LauncherLayout.wholeCellMergeFlightOpacity(at: 0.3), 0.9)
        XCTAssertLessThan(
            LauncherLayout.dropLandingShadowOpacity(at: 0.3),
            LauncherLayout.dragLiftShadowOpacity * 0.15
        )
        XCTAssertEqual(
            LauncherLayout.dropLandingShadowFadeDuration(
                flight: LauncherLayout.folderChromeTravelDuration
            ),
            LauncherLayout.folderChromeTravelDuration * gone,
            accuracy: 0.000_1
        )
    }

    /// The icon dropped onto a folder was lifted. Its preview flyer fades the
    /// drag shadow on the same early clock as a drop into a cell, and the
    /// shadow is gone while the icon is still in the air. The icon that was
    /// already on the grid was not lifted, so it does not grow a shadow.
    /// Reduced motion never lifted.
    func testIncomingMergeFadesTheLiftShadowAndTheResidentDoesNot() {
        XCTAssertTrue(LauncherLayout.shouldFadeIncomingMergeShadow(
            isIncoming: true, reducesMotion: false
        ))
        XCTAssertFalse(LauncherLayout.shouldFadeIncomingMergeShadow(
            isIncoming: false, reducesMotion: false
        ))
        XCTAssertFalse(LauncherLayout.shouldFadeIncomingMergeShadow(
            isIncoming: true, reducesMotion: true
        ))
        XCTAssertFalse(LauncherLayout.shouldFadeIncomingMergeShadow(
            isIncoming: false, reducesMotion: true
        ))

        let gone = LauncherLayout.dropLandingShadowFadeFraction
        XCTAssertEqual(LauncherLayout.dropLandingShadowOpacity(at: gone), 0, accuracy: 0.001)
        XCTAssertLessThan(gone, 1)
        let flight = LauncherLayout.folderPreviewGlyphFlightDuration
        XCTAssertEqual(
            LauncherLayout.dropLandingShadowFadeDuration(flight: flight),
            flight * gone,
            accuracy: 0.000_1
        )
        XCTAssertLessThan(
            LauncherLayout.dropLandingShadowFadeDuration(flight: flight),
            flight
        )
    }

    /// A whole-cell merge used to fade the new folder in at 60% of the flight.
    /// The icon is still about four fifths visible then, so the folder stacked
    /// on it. The folder now stays hidden until the icon has started to
    /// dissolve, then takes only the opacity the icon gives up, and is solid
    /// when the icon is gone. The two layers never add up to more than one.
    func testWholeCellMergeFolderWaitsUntilTheIconStartsDissolving() {
        XCTAssertEqual(LauncherLayout.wholeCellMergeFolderRevealIconOpacity, 0.78, accuracy: 0.001)
        XCTAssertGreaterThan(LauncherLayout.wholeCellMergeFlightOpacity(at: 0.6), 0.8)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFolderRevealOpacity(at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFolderRevealOpacity(at: 0.5), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFolderRevealOpacity(at: 0.6), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFolderRevealOpacity(at: -0.2), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFolderRevealOpacity(at: 1), 1, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFolderRevealOpacity(at: 1.4), 1, accuracy: 0.001)

        let fraction = LauncherLayout.wholeCellMergeFolderRevealFraction()
        XCTAssertGreaterThan(fraction, 0.6)
        XCTAssertLessThan(fraction, 0.75)
        XCTAssertLessThanOrEqual(
            LauncherLayout.wholeCellMergeFlightOpacity(at: fraction),
            LauncherLayout.wholeCellMergeFolderRevealIconOpacity + 0.001
        )
        XCTAssertEqual(
            LauncherLayout.wholeCellMergeFolderRevealOpacity(at: fraction - 0.02),
            0,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(LauncherLayout.wholeCellMergeFolderRevealOpacity(at: fraction + 0.05), 0.02)

        let iconAtSettle = LauncherLayout.wholeCellMergeFlightOpacity(at: 0.9)
        let folderAtSettle = LauncherLayout.wholeCellMergeFolderRevealOpacity(at: 0.9)
        XCTAssertLessThan(iconAtSettle, 0.4)
        XCTAssertGreaterThan(folderAtSettle, 0.5)
        XCTAssertGreaterThan(LauncherLayout.wholeCellMergeFolderRevealOpacity(at: 0.85), 0.35)
        XCTAssertLessThan(LauncherLayout.wholeCellMergeFolderRevealOpacity(at: 0.85), 0.55)

        var previous: CGFloat = 0
        for step in 0...20 {
            let time = CGFloat(step) / 20
            let icon = LauncherLayout.wholeCellMergeFlightOpacity(at: time)
            let folder = LauncherLayout.wholeCellMergeFolderRevealOpacity(at: time)
            XCTAssertGreaterThanOrEqual(folder + 0.000_1, previous)
            XCTAssertLessThanOrEqual(icon + folder, 1.001)
            XCTAssertGreaterThanOrEqual(
                icon + folder + 0.001,
                LauncherLayout.wholeCellMergeFolderRevealIconOpacity
            )
            previous = folder
        }
    }

    /// The whole-cell folder used to spring from 0.86 for about 0.68s, so it
    /// was still moving after the icon had dissolved. The scale now follows
    /// the fade: it stays at the start size while the folder is hidden, and
    /// it is full size when the icon is gone.
    func testWholeCellMergeFolderScaleLandsWithTheFade() {
        XCTAssertEqual(LauncherLayout.wholeCellMergeFolderScaleStart, 0.94, accuracy: 0.001)
        XCTAssertGreaterThan(LauncherLayout.wholeCellMergeFolderScaleStart, 0.9)
        XCTAssertLessThan(LauncherLayout.wholeCellMergeFolderScaleStart, 1)
        XCTAssertEqual(
            LauncherLayout.wholeCellMergeFolderScale(at: 0),
            LauncherLayout.wholeCellMergeFolderScaleStart,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LauncherLayout.wholeCellMergeFolderScale(at: 0.6),
            LauncherLayout.wholeCellMergeFolderScaleStart,
            accuracy: 0.001
        )
        XCTAssertEqual(LauncherLayout.wholeCellMergeFolderScale(at: 1), 1, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.wholeCellMergeFolderScale(at: 1.4), 1, accuracy: 0.001)
        let settling = LauncherLayout.wholeCellMergeFolderScale(at: 0.9)
        let start = LauncherLayout.wholeCellMergeFolderScaleStart
        let reveal = LauncherLayout.wholeCellMergeFolderRevealOpacity(at: 0.9)
        XCTAssertEqual(settling, start + (1 - start) * reveal, accuracy: 0.001)
        XCTAssertGreaterThan(settling, start)
        XCTAssertLessThan(settling, 1)
        var previous = start
        for step in 0...20 {
            let scale = LauncherLayout.wholeCellMergeFolderScale(at: CGFloat(step) / 20)
            XCTAssertGreaterThanOrEqual(scale + 0.000_1, previous)
            previous = scale
        }
    }

    /// A whole-cell merge used to inset the cell by 18% on every side, so the
    /// picture shrank into the geometric middle. The icon sits 14 points
    /// above that middle. The same shrink now stays on the icon.
    func testWholeCellMergeShrinksTowardTheIconNotTheCellCenter() {
        let cell = CGRect(x: 40, y: 80, width: 158, height: 129)
        XCTAssertEqual(LauncherLayout.iconCenterLift, 14, accuracy: 0.001)
        let icon = LauncherLayout.iconFrame(in: cell)
        XCTAssertEqual(icon.width, LauncherLayout.iconPointSize(in: cell.size), accuracy: 0.001)
        XCTAssertEqual(icon.height, icon.width, accuracy: 0.001)
        XCTAssertEqual(icon.midX, cell.midX, accuracy: 0.001)
        XCTAssertEqual(icon.midY, cell.midY + LauncherLayout.iconCenterLift, accuracy: 0.001)
        XCTAssertGreaterThan(icon.minY, cell.minY)
        XCTAssertLessThan(icon.maxY, cell.maxY)

        let dest = LauncherLayout.wholeCellMergeDestination(in: cell)
        let centered = cell.insetBy(
            dx: cell.width * LauncherLayout.wholeCellMergeInsetFraction,
            dy: cell.height * LauncherLayout.wholeCellMergeInsetFraction
        )
        XCTAssertEqual(LauncherLayout.wholeCellMergeInsetFraction, 0.18, accuracy: 0.001)
        XCTAssertEqual(dest.width, centered.width, accuracy: 0.001)
        XCTAssertEqual(dest.height, centered.height, accuracy: 0.001)
        XCTAssertLessThan(dest.width, cell.width * 0.7)
        XCTAssertEqual(dest.midX, cell.midX, accuracy: 0.001)
        XCTAssertEqual(dest.minX, centered.minX, accuracy: 0.001)
        XCTAssertGreaterThan(dest.midY, centered.midY + 4)
        XCTAssertLessThan(dest.midY, icon.midY)

        let fx = (icon.midX - cell.minX) / cell.width
        let fy = (icon.midY - cell.minY) / cell.height
        let landed = CGPoint(
            x: dest.minX + fx * dest.width,
            y: dest.minY + fy * dest.height
        )
        XCTAssertEqual(landed.x, icon.midX, accuracy: 0.001)
        XCTAssertEqual(landed.y, icon.midY, accuracy: 0.001)

        let above = cell.maxY - dest.maxY
        let below = dest.minY - cell.minY
        XCTAssertGreaterThan(below, above + 8)
        XCTAssertGreaterThan(above, 0)
        XCTAssertLessThan(dest.maxY, cell.maxY)

        let shorter = CGRect(x: 0, y: 0, width: 120, height: 105)
        let shortIcon = LauncherLayout.iconFrame(in: shorter)
        XCTAssertEqual(shortIcon.midY, shorter.midY + 14, accuracy: 0.001)
        XCTAssertGreaterThan(
            LauncherLayout.wholeCellMergeDestination(in: shorter).midY,
            shorter.midY
        )

        XCTAssertEqual(LauncherLayout.iconFrame(in: .zero), .zero)
        XCTAssertEqual(LauncherLayout.wholeCellMergeDestination(in: .zero), .zero)
        let degenerate = CGRect(x: 10, y: 10, width: 0.2, height: 40)
        XCTAssertEqual(LauncherLayout.wholeCellMergeDestination(in: degenerate), degenerate)
    }

    /// A merge used to start on the resting cell, while the drag image was
    /// the lifted picture. The whole-cell flight now leaves from that picture.
    /// A preview flight leaves from the icon inside it, not the smaller icon.
    /// Reduced motion never lifted, so both stay on the resting frames.
    func testMergeFlightLeavesFromTheLiftedDragPicture() {
        let cell = CGRect(x: 40, y: 80, width: 158, height: 129)
        let lifted = LauncherLayout.dropLandingStartFrame(cell: cell, reducesMotion: false)
        XCTAssertEqual(
            LauncherLayout.mergeFlightSourceFrame(cell: cell, reducesMotion: false),
            lifted
        )
        XCTAssertGreaterThan(lifted.width, cell.width)
        XCTAssertEqual(
            LauncherLayout.mergeFlightSourceFrame(cell: cell, reducesMotion: true),
            cell
        )
        XCTAssertEqual(LauncherLayout.mergeFlightSourceFrame(cell: .zero, reducesMotion: false), .zero)

        let icon = LauncherLayout.iconFrame(in: cell)
        let carried = LauncherLayout.iconFrameInLiftedDrag(
            icon: icon,
            cell: cell,
            reducesMotion: false
        )
        let sx = lifted.width / cell.width
        let sy = lifted.height / cell.height
        XCTAssertEqual(sx, LauncherLayout.dragLiftScale, accuracy: 0.001)
        XCTAssertEqual(sy, LauncherLayout.dragLiftScale, accuracy: 0.001)
        XCTAssertEqual(carried.width, icon.width * sx, accuracy: 0.001)
        XCTAssertEqual(carried.height, icon.height * sy, accuracy: 0.001)
        XCTAssertGreaterThan(carried.width, icon.width)
        let carriedCenter = CGPoint(
            x: lifted.minX + (icon.midX - cell.minX) * sx,
            y: lifted.minY + (icon.midY - cell.minY) * sy
        )
        XCTAssertEqual(carried.midX, carriedCenter.x, accuracy: 0.001)
        XCTAssertEqual(carried.midY, carriedCenter.y, accuracy: 0.001)
        XCTAssertGreaterThan(carried.midY, icon.midY)

        XCTAssertEqual(
            LauncherLayout.iconFrameInLiftedDrag(icon: icon, cell: cell, reducesMotion: true),
            icon
        )
        XCTAssertEqual(
            LauncherLayout.iconFrameInLiftedDrag(icon: .zero, cell: cell, reducesMotion: false),
            .zero
        )
        XCTAssertEqual(
            LauncherLayout.iconFrameInLiftedDrag(icon: icon, cell: .zero, reducesMotion: false),
            icon
        )
        let broken = CGRect(x: CGFloat.nan, y: 0, width: 64, height: 64)
        let returned = LauncherLayout.iconFrameInLiftedDrag(icon: broken, cell: cell, reducesMotion: false)
        // NaN is not equal to itself, so compare the parts a bad icon must keep.
        XCTAssertTrue(returned.origin.x.isNaN)
        XCTAssertEqual(returned.origin.y, broken.origin.y)
        XCTAssertEqual(returned.size, broken.size)
    }

    /// Letting go of a reorder flies from the lifted drag picture into the
    /// cell. The start frame is the scaled cell inside the drag image, not
    /// the smaller cell, so removing the drag image does not pop. Same 0.34s
    /// clock as the folder flights. Reduced motion, a bad frame, and a hop
    /// under a point do not travel.
    func testDropLandingFliesFromTheLiftedPictureIntoTheCell() throws {
        let cell = CGRect(x: 0, y: 0, width: 100, height: 100)
        let lifted = LauncherLayout.dropLandingStartFrame(cell: cell, reducesMotion: false)
        let scaled = 100 * LauncherLayout.dragLiftScale
        XCTAssertEqual(lifted.width, scaled, accuracy: 0.001)
        XCTAssertEqual(lifted.height, scaled, accuracy: 0.001)
        // The shadow sits below the icon, so the picture in the drag image
        // is 2pt above the cell's center. The flight has to leave from there.
        XCTAssertEqual(lifted.midX, cell.midX, accuracy: 0.001)
        XCTAssertEqual(lifted.midY, cell.midY + 2, accuracy: 0.001)
        XCTAssertGreaterThan(lifted.width, cell.width)
        XCTAssertEqual(
            LauncherLayout.dropLandingStartFrame(cell: cell, reducesMotion: true),
            cell
        )
        let bad = CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)
        let returnedBad = LauncherLayout.dropLandingStartFrame(cell: bad, reducesMotion: false)
        // NaN is not equal to itself, so compare the parts a bad cell must keep.
        XCTAssertTrue(returnedBad.origin.x.isNaN)
        XCTAssertEqual(returnedBad.origin.y, bad.origin.y)
        XCTAssertEqual(returnedBad.size, bad.size)
        XCTAssertEqual(LauncherLayout.dropLandingStartFrame(cell: .zero, reducesMotion: false), .zero)

        let destination = CGRect(x: 180, y: 40, width: 100, height: 100)
        let flight = LauncherLayout.dropLandingFlight(from: lifted, to: destination, reducesMotion: false)
        XCTAssertEqual(flight?.source, lifted)
        XCTAssertEqual(flight?.destination, destination)
        let duration = try XCTUnwrap(flight?.duration)
        XCTAssertEqual(duration, 0.34, accuracy: 0.001)
        XCTAssertEqual(duration, LauncherLayout.folderChromeTravelDuration, accuracy: 0.001)
        XCTAssertEqual(duration, LauncherLayout.dropLandingFlightDuration, accuracy: 0.001)

        XCTAssertNil(LauncherLayout.dropLandingFlight(from: lifted, to: destination, reducesMotion: true))
        XCTAssertNil(LauncherLayout.dropLandingFlight(from: .zero, to: destination, reducesMotion: false))
        XCTAssertNil(LauncherLayout.dropLandingFlight(
            from: CGRect(x: CGFloat.nan, y: 0, width: 106, height: 106),
            to: destination,
            reducesMotion: false
        ))
        XCTAssertNil(LauncherLayout.dropLandingFlight(from: lifted, to: .zero, reducesMotion: false))
        XCTAssertNil(LauncherLayout.dropLandingFlight(
            from: destination.offsetBy(dx: 0.2, dy: 0),
            to: destination,
            reducesMotion: false
        ))
        // Letting go on the same slot still travels. The picture in hand is
        // the lifted cell, and the slot is the smaller one.
        let sameSlot = LauncherLayout.dropLandingFlight(from: lifted, to: cell, reducesMotion: false)
        XCTAssertEqual(sameSlot?.source, lifted)
        XCTAssertEqual(sameSlot?.destination, cell)
        XCTAssertNotEqual(sameSlot?.source.size, cell.size)

        XCTAssertTrue(LauncherLayout.shouldPlayDropLanding(
            reducesMotion: false, isDismissing: false, isVisible: true
        ))
        XCTAssertFalse(LauncherLayout.shouldPlayDropLanding(
            reducesMotion: true, isDismissing: false, isVisible: true
        ))
        XCTAssertFalse(LauncherLayout.shouldPlayDropLanding(
            reducesMotion: false, isDismissing: true, isVisible: true
        ))
        XCTAssertFalse(LauncherLayout.shouldPlayDropLanding(
            reducesMotion: false, isDismissing: false, isVisible: false
        ))
        XCTAssertEqual(
            LauncherLayout.shouldHoldDropLanding(isDismissing: true, isVisible: true),
            LauncherLayout.shouldHoldMergeFlight(isDismissing: true, isVisible: true)
        )
        XCTAssertEqual(
            LauncherLayout.shouldAdvanceDropLanding(isDismissing: false, isVisible: true),
            LauncherLayout.shouldAdvanceMergeFlight(isDismissing: false, isVisible: true)
        )
        XCTAssertEqual(
            LauncherLayout.shouldSnapInFlightDropLanding(isDismissing: false, isVisible: true),
            LauncherLayout.shouldSnapInFlightMergeFlight(isDismissing: false, isVisible: true)
        )
    }

    /// The lift shadow lives in the drag image. The flyer is the cell, so the
    /// shadow used to vanish when that image left. It now fades over the early
    /// part of the 0.34s flight, ahead of a straight line, and is gone before
    /// the icon lands. A bad clock keeps the lift shadow.
    func testDropLandingShadowFadesBeforeTheIconLands() {
        XCTAssertEqual(LauncherLayout.dropLandingShadowFadeFraction, 0.45, accuracy: 0.001)
        XCTAssertEqual(
            LauncherLayout.dropLandingShadowOpacity(at: 0),
            LauncherLayout.dragLiftShadowOpacity,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LauncherLayout.dropLandingShadowOpacity(at: -0.2),
            LauncherLayout.dragLiftShadowOpacity,
            accuracy: 0.001
        )
        XCTAssertEqual(LauncherLayout.dropLandingShadowOpacity(at: 0.45), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.dropLandingShadowOpacity(at: 1), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.dropLandingShadowOpacity(at: 1.4), 0, accuracy: 0.001)
        XCTAssertEqual(
            LauncherLayout.dropLandingShadowOpacity(at: .nan),
            LauncherLayout.dragLiftShadowOpacity,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LauncherLayout.dropLandingShadowOpacity(at: .infinity),
            LauncherLayout.dragLiftShadowOpacity,
            accuracy: 0.001
        )

        let early = LauncherLayout.dropLandingShadowOpacity(at: 0.1)
        let linear = LauncherLayout.dragLiftShadowOpacity * (1 - 0.1 / 0.45)
        XCTAssertGreaterThan(early, 0)
        XCTAssertLessThan(early, linear)
        XCTAssertLessThan(early, LauncherLayout.dragLiftShadowOpacity * 0.5)
        XCTAssertLessThan(
            LauncherLayout.dropLandingShadowOpacity(at: 0.2),
            LauncherLayout.dragLiftShadowOpacity * 0.25
        )
        XCTAssertLessThan(LauncherLayout.dropLandingShadowOpacity(at: 0.3), 0.02)

        var previous = LauncherLayout.dragLiftShadowOpacity + 1
        for step in 0...20 {
            let opacity = LauncherLayout.dropLandingShadowOpacity(at: CGFloat(step) / 20)
            if previous > 0 {
                XCTAssertLessThan(opacity, previous)
            } else {
                XCTAssertEqual(opacity, 0, accuracy: 0.001)
            }
            XCTAssertGreaterThanOrEqual(opacity, 0)
            previous = opacity
        }

        let flight = LauncherLayout.dropLandingFlightDuration
        let duration = LauncherLayout.dropLandingShadowFadeDuration(flight: flight)
        XCTAssertEqual(duration, flight * 0.45, accuracy: 0.000_1)
        XCTAssertGreaterThan(duration, 0.1)
        XCTAssertLessThan(duration, flight)
        XCTAssertEqual(LauncherLayout.dropLandingShadowFadeDuration(flight: 0), 0, accuracy: 0.001)
        XCTAssertEqual(LauncherLayout.dropLandingShadowFadeDuration(flight: -0.2), 0, accuracy: 0.001)
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

    func testReorderHoldsPresentationUntilLayoutFramesAreUsable() {
        XCTAssertTrue(
            LauncherLayout.shouldHoldReorderPresentationUntilFramesReady(
                animated: true,
                framesUsable: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldHoldReorderPresentationUntilFramesReady(
                animated: true,
                framesUsable: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.shouldHoldReorderPresentationUntilFramesReady(
                animated: false,
                framesUsable: false
            )
        )
        let cell = CGRect(x: 0, y: 0, width: 80, height: 90)
        let gap = CGRect(x: 100, y: 0, width: 80, height: 90)
        XCTAssertTrue(
            LauncherLayout.reorderFramesUsable(slot: 1, itemIndex: 0, fromFrame: cell, toFrame: gap)
        )
        XCTAssertFalse(
            LauncherLayout.reorderFramesUsable(
                slot: 1,
                itemIndex: 0,
                fromFrame: .zero,
                toFrame: gap
            )
        )
        XCTAssertFalse(
            LauncherLayout.reorderFramesUsable(
                slot: 1,
                itemIndex: 0,
                fromFrame: cell,
                toFrame: cell
            )
        )
        XCTAssertTrue(
            LauncherLayout.reorderFramesUsable(slot: 2, itemIndex: 2, fromFrame: .zero, toFrame: .zero),
            "Stationary slots do not need a gap frame"
        )
    }

    func testReorderSpringKeepsMotionContinuousWhenGapChanges() {
        var motion = (position: CGSize.zero, velocity: CGSize.zero)
        for _ in 0..<6 {
            motion = LauncherLayout.reorderSpringStep(
                position: motion.position, velocity: motion.velocity,
                target: CGSize(width: 90, height: 0), elapsed: 1.0 / 60.0
            )
        }
        XCTAssertGreaterThan(motion.position.width, 0)
        XCTAssertLessThan(motion.position.width, 90)
        XCTAssertGreaterThan(motion.velocity.width, 0)

        let retargeted = LauncherLayout.reorderSpringStep(
            position: motion.position, velocity: motion.velocity,
            target: CGSize(width: -90, height: 0), elapsed: 0
        )
        XCTAssertEqual(retargeted.position.width, motion.position.width, accuracy: 0.001)
        XCTAssertEqual(retargeted.velocity.width, motion.velocity.width, accuracy: 0.001)

        motion = retargeted
        for _ in 0..<40 {
            motion = LauncherLayout.reorderSpringStep(
                position: motion.position, velocity: motion.velocity,
                target: CGSize(width: -90, height: 0), elapsed: 1.0 / 60.0
            )
        }
        XCTAssertEqual(motion.position.width, -90, accuracy: 0.5)
        XCTAssertEqual(motion.velocity.width, 0, accuracy: 2)
    }

    func testReorderSpringUsesElapsedTimeAcrossFrameRates() {
        let start = (position: CGSize(width: 12, height: -8), velocity: CGSize(width: 180, height: -90))
        let target = CGSize(width: 90, height: 60)
        var reference = start
        for _ in 0..<12 {
            reference = LauncherLayout.reorderSpringStep(
                position: reference.position, velocity: reference.velocity,
                target: target, elapsed: 1.0 / 60.0
            )
        }
        // The same 200ms must produce the same frame, including after a delayed tick.
        for frames in [4, 2, 1] {
            var motion = start
            for _ in 0..<frames {
                motion = LauncherLayout.reorderSpringStep(
                    position: motion.position, velocity: motion.velocity,
                    target: target, elapsed: 0.2 / Double(frames)
                )
            }
            XCTAssertEqual(motion.position.width, reference.position.width, accuracy: 0.001)
            XCTAssertEqual(motion.position.height, reference.position.height, accuracy: 0.001)
            XCTAssertEqual(motion.velocity.width, reference.velocity.width, accuracy: 0.001)
            XCTAssertEqual(motion.velocity.height, reference.velocity.height, accuracy: 0.001)
        }
    }

    /// Neighbors used to wait out a timer interval, then jump. The spring
    /// integrates the time until the frame about to draw. A clock behind
    /// the last frame does not rewind that mark.
    func testReorderSlideKeepsTheTimeUntilTheFrameAboutToDraw() {
        XCTAssertEqual(LauncherLayout.reorderSlideElapsed(now: 10, lastTick: 10), 0, accuracy: 0.000_001)
        XCTAssertEqual(
            LauncherLayout.reorderSlideElapsed(now: 10 + 1.0 / 120.0, lastTick: 10),
            1.0 / 120.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(LauncherLayout.reorderSlideElapsed(now: 9.9, lastTick: 10), 0, accuracy: 0.000_001)
        XCTAssertEqual(LauncherLayout.reorderSlideElapsed(now: .nan, lastTick: 10), 0, accuracy: 0.000_001)
        XCTAssertEqual(LauncherLayout.reorderSlideElapsed(now: 10, lastTick: .infinity), 0, accuracy: 0.000_001)
        let start = CGSize(width: 12, height: -4)
        let stayed = LauncherLayout.reorderSpringStep(
            position: start,
            velocity: CGSize(width: 40, height: 0),
            target: CGSize(width: 90, height: 0),
            elapsed: LauncherLayout.reorderSlideElapsed(now: 1, lastTick: 2)
        )
        XCTAssertEqual(stayed.position.width, start.width, accuracy: 0.000_001)
        XCTAssertEqual(stayed.position.height, start.height, accuracy: 0.000_001)
        XCTAssertEqual(stayed.velocity.width, 40, accuracy: 0.000_001)
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
        XCTAssertEqual(
            LauncherLayout.resolvedFolderName(draft: "   ", previous: "工具"),
            "工具"
        )
        XCTAssertEqual(
            LauncherLayout.resolvedFolderName(draft: " 新名 ", previous: "工具"),
            "新名"
        )
        XCTAssertTrue(LauncherLayout.folderTitleSelectsAllOnBeginEditing)
        XCTAssertTrue(LauncherLayout.aliasSelectsAllOnBeginEditing)
        XCTAssertFalse(
            LauncherLayout.folderTitleShouldBeginEditingFromPointer(clickCount: 1)
        )
        XCTAssertTrue(
            LauncherLayout.folderTitleShouldBeginEditingFromPointer(clickCount: 2)
        )
        XCTAssertTrue(
            LauncherLayout.folderTitleShouldBeginEditingFromPointer(clickCount: 3)
        )
        XCTAssertTrue(
            LauncherLayout.folderTitleShouldCancelEditingOnOutsideClick(
                isEditing: true,
                clickIsOnTitle: false
            )
        )
        XCTAssertFalse(
            LauncherLayout.folderTitleShouldCancelEditingOnOutsideClick(
                isEditing: true,
                clickIsOnTitle: true
            )
        )
        XCTAssertFalse(
            LauncherLayout.folderTitleShouldCancelEditingOnOutsideClick(
                isEditing: false,
                clickIsOnTitle: false
            )
        )
        XCTAssertTrue(LauncherLayout.folderTitleFocusesFirstMemberAfterEndingEdit)
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

    func testEmptyChromeKindSearchNoMatchesUsesGridNotStatusOnly() {
        XCTAssertEqual(
            LauncherLayout.emptyChromeKind(
                isSearching: true,
                presentedIsEmpty: true,
                catalogIsEmpty: false,
                isCatalogLoading: false,
                catalogScanCancelled: false
            ),
            .searchNoMatches
        )
        XCTAssertNil(
            LauncherLayout.emptyChromeKind(
                isSearching: true,
                presentedIsEmpty: false,
                catalogIsEmpty: false,
                isCatalogLoading: false,
                catalogScanCancelled: false
            )
        )
        XCTAssertEqual(
            LauncherLayout.emptyChromeKind(
                isSearching: false,
                presentedIsEmpty: true,
                catalogIsEmpty: true,
                isCatalogLoading: false,
                catalogScanCancelled: false
            ),
            .catalogUnavailable
        )
        XCTAssertEqual(
            LauncherLayout.emptyChromeKind(
                isSearching: false,
                presentedIsEmpty: true,
                catalogIsEmpty: true,
                isCatalogLoading: false,
                catalogScanCancelled: true
            ),
            .catalogCancelled
        )
        XCTAssertNil(
            LauncherLayout.emptyChromeKind(
                isSearching: false,
                presentedIsEmpty: true,
                catalogIsEmpty: true,
                isCatalogLoading: true,
                catalogScanCancelled: false
            ),
            "loading uses skeleton/status, not empty chrome"
        )
        // Searching with empty catalog still prefers catalog empty chrome.
        XCTAssertEqual(
            LauncherLayout.emptyChromeKind(
                isSearching: true,
                presentedIsEmpty: true,
                catalogIsEmpty: true,
                isCatalogLoading: false,
                catalogScanCancelled: false
            ),
            .catalogUnavailable
        )
    }

    func testSearchFolderMemberHitShowsContainingFolderChrome() {
        let memberID = UUID()
        let topID = UUID()
        let folderID = UUID()
        let member = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Member.app"),
            bundleIdentifier: "com.example.member",
            displayName: "Member",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let top = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Top.app"),
            bundleIdentifier: "com.example.top",
            displayName: "Top",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let state = LayoutState(
            orderedEntries: [.folder(folderID), .app(topID)],
            folders: [
                folderID: LauncherFolder(id: folderID, name: "工具", itemIDs: [memberID])
            ],
            appKeys: [
                memberID: member.deduplicationKey,
                topID: top.deduplicationKey
            ]
        )
        XCTAssertEqual(
            LauncherLayout.containingFolderName(forAppID: memberID, in: state),
            "工具"
        )
        XCTAssertNil(LauncherLayout.containingFolderName(forAppID: topID, in: state))
        XCTAssertEqual(
            LauncherLayout.searchHitTitle(displayName: "Member", containingFolderName: "工具"),
            "Member\n工具"
        )
        XCTAssertEqual(
            LauncherLayout.searchHitTitle(displayName: "Top", containingFolderName: nil),
            "Top"
        )
        XCTAssertEqual(
            LauncherLayout.searchHitTitle(displayName: "Top", containingFolderName: "  "),
            "Top"
        )
        XCTAssertEqual(
            LauncherLayout.searchHitAccessibilityLabel(
                displayName: "Member",
                containingFolderName: "工具"
            ),
            "Member，工具"
        )
        // Still discoverable via searchHits / filter
        let hits = AppSearchIndex(candidates: [member, top]).filter(
            LauncherLayout.searchHits(in: state, catalog: [member, top]),
            query: "mem"
        )
        XCTAssertEqual(hits, [.app(member)])
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

    func testSearchPrefersTopLevelAppsOverFolderMembersAtEqualRank() {
        let topID = UUID()
        let memberID = UUID()
        let folderID = UUID()
        // Member listed before top-level in hits (folder comes first in layout).
        let alpine = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Alpine.app"),
            bundleIdentifier: "com.example.alpine",
            displayName: "Alpine",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let alpha = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Alpha.app"),
            bundleIdentifier: "com.example.alpha",
            displayName: "Alpha",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let state = LayoutState(
            orderedEntries: [.folder(folderID), .app(topID)],
            folders: [
                folderID: LauncherFolder(id: folderID, name: "Misc", itemIDs: [memberID])
            ],
            appKeys: [
                memberID: alpine.deduplicationKey,
                topID: alpha.deduplicationKey
            ]
        )
        let catalog = [alpine, alpha]
        let hits = LauncherLayout.searchHits(in: state, catalog: catalog)
        XCTAssertEqual(hits, [
            .folder(folderID, "Misc"),
            .app(alpine),
            .app(alpha)
        ])
        let topKeys = LauncherLayout.topLevelAppDeduplicationKeys(in: state)
        XCTAssertEqual(topKeys, [alpha.deduplicationKey])
        let index = AppSearchIndex(candidates: catalog)
        // Both prefix-match "al" at the same rank; without preference Alpine
        // (earlier in hits) would win — with preference Alpha (top-level) wins.
        XCTAssertEqual(
            index.filter(hits, query: "al", topLevelKeys: topKeys),
            [.app(alpha), .app(alpine)]
        )
        // Empty topLevelKeys keeps hit order (regression for callers).
        XCTAssertEqual(
            index.filter(hits, query: "al", topLevelKeys: []),
            [.app(alpine), .app(alpha)]
        )
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





    func testRearrangeTopLevelByNameAndKindPreservesFolderMembership() {
        let sysA = UUID()
        let sysB = UUID()
        let third = UUID()
        let folderID = UUID()
        let member = UUID()
        let calendar = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
            bundleIdentifier: "com.apple.iCal",
            displayName: "日历",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let notes = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/System/Applications/Notes.app"),
            bundleIdentifier: "com.apple.Notes",
            displayName: "备忘录",
            sourcePriority: 0,
            discoveredAt: .now
        )
        let zebra = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Zebra.app"),
            bundleIdentifier: "com.example.Zebra",
            displayName: "Zebra",
            sourcePriority: 1,
            discoveredAt: .now
        )
        let memberApp = AppCandidate(
            canonicalURL: URL(fileURLWithPath: "/Applications/Member.app"),
            bundleIdentifier: "com.example.Member",
            displayName: "Member",
            sourcePriority: 1,
            discoveredAt: .now
        )
        let catalog = [calendar, notes, zebra, memberApp]
        var state = LayoutState(
            orderedEntries: [.app(third), .folder(folderID), .app(sysB), .app(sysA)],
            folders: [
                folderID: LauncherFolder(id: folderID, name: "工具", itemIDs: [member])
            ],
            appKeys: [
                sysA: calendar.deduplicationKey,
                sysB: notes.deduplicationKey,
                third: zebra.deduplicationKey,
                member: memberApp.deduplicationKey
            ],
            appAliases: [zebra.deduplicationKey: "阿斑马"]
        )

        let byName = LauncherLayout.rearrangeTopLevelEntries(in: state, catalog: catalog, sort: .byName)
        XCTAssertEqual(byName.folders[folderID]?.itemIDs, [member], "folder membership must not change")
        XCTAssertEqual(Set(byName.orderedEntries.map(\.id)), Set(state.orderedEntries.map(\.id)))
        let names: [String] = byName.orderedEntries.map { entry in
            switch entry {
            case .folder(let id):
                return byName.folders[id]?.name ?? ""
            case .app(let id):
                let key = byName.appKeys[id]!
                return byName.appAliases[key] ?? catalog.first(where: { $0.deduplicationKey == key })!.displayName
            }
        }
        XCTAssertEqual(
            names,
            names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        )

        let byKind = LauncherLayout.rearrangeTopLevelEntries(in: state, catalog: catalog, sort: .byKind)
        XCTAssertEqual(byKind.folders[folderID]?.itemIDs, [member])
        guard case .app(let firstID) = byKind.orderedEntries[0],
              case .app(let secondID) = byKind.orderedEntries[1] else {
            return XCTFail("byKind should lead with two system apps")
        }
        let firstKeys = [firstID, secondID].compactMap { byKind.appKeys[$0] }
        XCTAssertEqual(Set(firstKeys), Set([calendar.deduplicationKey, notes.deduplicationKey]))
        XCTAssertEqual(LauncherLayout.gridRearrangeToastMessage(sort: .byName), "已按名称重新排列")
        XCTAssertEqual(LauncherLayout.gridRearrangeToastMessage(sort: .byKind), "已按类型重新排列")
    }


    func testGridRearrangeConfirmAlertCancelIsFirstButton() {
        XCTAssertTrue(LauncherLayout.GridRearrangeConfirmAlert.cancelIsFirstButton)
        XCTAssertFalse(LauncherLayout.GridRearrangeConfirmAlert.messageTextKey.isEmpty)
        XCTAssertFalse(
            LauncherLayout.GridRearrangeConfirmAlert.informativeTextKey(sort: .byName).isEmpty
        )
        XCTAssertFalse(
            LauncherLayout.GridRearrangeConfirmAlert.informativeTextKey(sort: .byKind).isEmpty
        )
        XCTAssertEqual(LauncherLayout.GridRearrangeConfirmAlert.cancelButtonTitleKey, "取消")
        XCTAssertFalse(LauncherLayout.GridRearrangeConfirmAlert.confirmButtonTitleKey.isEmpty)
        XCTAssertEqual(LauncherLayout.settingsFeedbackAccessibilityLabelKey, "设置反馈")
    }

    func testLayoutRestoreAndImportConfirmAlertsCancelIsFirstButton() {
        XCTAssertTrue(LauncherLayout.LayoutRestoreBackupConfirmAlert.cancelIsFirstButton)
        XCTAssertFalse(LauncherLayout.LayoutRestoreBackupConfirmAlert.messageTextKey.isEmpty)
        XCTAssertFalse(LauncherLayout.LayoutRestoreBackupConfirmAlert.informativeTextKey.isEmpty)
        XCTAssertEqual(LauncherLayout.LayoutRestoreBackupConfirmAlert.cancelButtonTitleKey, "取消")
        XCTAssertFalse(LauncherLayout.LayoutRestoreBackupConfirmAlert.confirmButtonTitleKey.isEmpty)

        XCTAssertTrue(LauncherLayout.LayoutImportConfirmAlert.cancelIsFirstButton)
        XCTAssertFalse(LauncherLayout.LayoutImportConfirmAlert.messageTextKey.isEmpty)
        XCTAssertFalse(LauncherLayout.LayoutImportConfirmAlert.informativeTextKey.isEmpty)
        XCTAssertEqual(LauncherLayout.LayoutImportConfirmAlert.cancelButtonTitleKey, "取消")
        XCTAssertFalse(LauncherLayout.LayoutImportConfirmAlert.confirmButtonTitleKey.isEmpty)
    }


    func testTileAccessibilityHelpExplainsIncompleteScanReadonly() {
        XCTAssertEqual(
            LauncherLayout.tileAccessibilityHelp(
                isFolder: false,
                layoutEditingEnabled: true,
                layoutEditingExplanation: nil
            ),
            "按下以打开应用"
        )
        XCTAssertEqual(
            LauncherLayout.tileAccessibilityHelp(
                isFolder: true,
                layoutEditingEnabled: true,
                layoutEditingExplanation: "ignored"
            ),
            "按下以打开文件夹"
        )
        let blocked = LauncherLayout.tileAccessibilityHelp(
            isFolder: false,
            layoutEditingEnabled: false,
            layoutEditingExplanation: "应用扫描不完整，暂时无法整理；请重新扫描"
        )
        XCTAssertTrue(blocked.contains("按下以打开应用"))
        XCTAssertTrue(blocked.contains("应用扫描不完整"))
        XCTAssertEqual(
            LauncherLayout.layoutCollectionAccessibilityHelp(
                layoutEditingEnabled: false,
                layoutEditingExplanation: "应用扫描不完整，暂时无法整理；请重新扫描",
                editableHelp: "拖动应用以整理布局"
            ),
            "应用扫描不完整，暂时无法整理；请重新扫描"
        )
        XCTAssertEqual(
            LauncherLayout.layoutCollectionAccessibilityHelp(
                layoutEditingEnabled: true,
                layoutEditingExplanation: nil,
                editableHelp: "拖动应用以整理布局"
            ),
            "拖动应用以整理布局"
        )
        XCTAssertEqual(LauncherLayout.readOnlyStatusAccessibilityLabelKey, "整理状态")
    }

    func testSelectAllOnCurrentPageOnlyDoesNotIncludeOtherPages() {
        let page0 = (0..<LauncherLayout.pageCapacity).map { _ in UUID() }
        let page1 = (0..<3).map { _ in UUID() }
        let entries = (page0 + page1).map { LauncherEntry.app($0) }
        let ids = LauncherLayout.itemIDs(onPage: 0, from: entries)
        XCTAssertEqual(ids, page0)
        XCTAssertEqual(LauncherLayout.itemIDs(onPage: 1, from: entries), page1)
        XCTAssertEqual(LauncherLayout.itemIDs(onPage: 2, from: entries), [])

        let selected = LauncherItemSelection.selectingAll(ids: ids)
        XCTAssertEqual(selected.orderedIDs, page0)
        XCTAssertEqual(selected.rangeAnchorID, page0.first)
        XCTAssertEqual(LauncherItemSelection.selectingAll(ids: []).orderedIDs, [])
    }

    func testShiftClickRangeSelectionPreservesAnchorWithoutPaging() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let presented = [a, b, c, d]

        var selection = LauncherItemSelection.applying(kind: .replace, itemID: b, to: .empty)
        XCTAssertEqual(selection.orderedIDs, [b])
        XCTAssertEqual(selection.rangeAnchorID, b)

        selection = LauncherItemSelection.applyingRange(
            to: d,
            presentedOrder: presented,
            current: selection
        )
        XCTAssertEqual(selection.orderedIDs, [b, c, d])
        XCTAssertEqual(selection.rangeAnchorID, b, "anchor stays so a later Shift-click can retarget")

        selection = LauncherItemSelection.applyingRange(
            to: a,
            presentedOrder: presented,
            current: selection
        )
        XCTAssertEqual(selection.orderedIDs, [a, b])
        XCTAssertEqual(selection.rangeAnchorID, b)

        // Unknown id falls back to replace
        let outsider = UUID()
        selection = LauncherItemSelection.applyingRange(
            to: outsider,
            presentedOrder: presented,
            current: selection
        )
        XCTAssertEqual(selection.orderedIDs, [outsider])
        XCTAssertEqual(selection.rangeAnchorID, outsider)

        // Toggle updates anchor
        selection = LauncherItemSelection.applying(kind: .toggle, itemID: a, to: selection)
        XCTAssertEqual(selection.rangeAnchorID, a)
        XCTAssertTrue(selection.contains(a))
        XCTAssertTrue(selection.contains(outsider))
    }

    func testBatchHideAndCreateFolderFromSelection() throws {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let folderID = UUID()
        let state = LayoutState(
            orderedEntries: [.app(a), .app(b), .folder(folderID), .app(c)],
            folders: [
                folderID: LauncherFolder(id: folderID, name: "F", itemIDs: [UUID()])
            ],
            appKeys: [
                a: "a.bundle",
                b: "b.bundle",
                c: "c.bundle"
            ]
        )
        let selection = LauncherItemSelection(orderedIDs: [a, folderID, b, c])
        XCTAssertEqual(
            LauncherLayout.appKeysForBatchHide(selection: selection, in: state),
            ["a.bundle", "b.bundle", "c.bundle"]
        )
        XCTAssertEqual(
            LauncherLayout.topLevelAppIDsForBatchFolder(selection: selection, in: state),
            [a, b, c]
        )

        let hidden = LauncherLayout.hideApplications(withKeys: ["a.bundle", "c.bundle"], in: state)
        XCTAssertFalse(hidden.orderedEntries.contains(.app(a)))
        XCTAssertFalse(hidden.orderedEntries.contains(.app(c)))
        XCTAssertTrue(hidden.orderedEntries.contains(.app(b)))
        XCTAssertEqual(hidden.hiddenAppKeys, Set(["a.bundle", "c.bundle"]))

        let folded = try LauncherLayout.createFolderFromTopLevelApps(
            orderedAppIDs: [a, c, b],
            in: state,
            name: "工具"
        ).get()
        XCTAssertEqual(folded.state.folders[folded.folderID]?.name, "工具")
        XCTAssertEqual(folded.state.folders[folded.folderID]?.itemIDs, [a, c, b])
        XCTAssertFalse(folded.state.orderedEntries.contains(.app(a)))
        XCTAssertFalse(folded.state.orderedEntries.contains(.app(b)))
        XCTAssertFalse(folded.state.orderedEntries.contains(.app(c)))
        XCTAssertTrue(folded.state.orderedEntries.contains(.folder(folded.folderID)))
        // Folder lands at earliest former index (a was first).
        XCTAssertEqual(folded.state.orderedEntries.first, .folder(folded.folderID))

        XCTAssertEqual(
            LauncherLayout.hideSelectedApplicationsToastMessage(count: 3),
            "已隐藏 3 个应用"
        )

        // Need ≥2 apps
        XCTAssertThrowsError(
            try LauncherLayout.createFolderFromTopLevelApps(
                orderedAppIDs: [a],
                in: state,
                name: "X"
            ).get()
        )
    }

    func testBatchCreateFolderFromSelectionDropOntoAppSamePageOnly() throws {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let target = UUID()
        let otherPage = UUID()
        var fillers: [UUID] = []
        // page 0: a, b, c, target, fillers...; otherPage on page 1
        while 4 + fillers.count < LauncherLayout.pageCapacity {
            fillers.append(UUID())
        }
        var ordered: [LauncherEntry] = [.app(a), .app(b), .app(c), .app(target)]
        ordered.append(contentsOf: fillers.map { .app($0) })
        ordered.append(.app(otherPage))
        var appKeys: [UUID: String] = [
            a: "a.bundle",
            b: "b.bundle",
            c: "c.bundle",
            target: "target.bundle",
            otherPage: "other.bundle"
        ]
        for (index, id) in fillers.enumerated() {
            appKeys[id] = "filler.\(index)"
        }
        let state = LayoutState(orderedEntries: ordered, appKeys: appKeys)

        let selection = LauncherItemSelection(orderedIDs: [a, c, otherPage, b])
        XCTAssertTrue(
            LauncherLayout.shouldBatchCreateFolderFromSelection(
                selection: selection,
                draggedID: a,
                targetAppID: target,
                in: state
            )
        )
        let apps = LauncherLayout.topLevelAppIDsForBatchCreateFolder(
            selection: selection,
            targetAppID: target,
            in: state
        )
        XCTAssertEqual(apps, [target, a, c, b], "target first; same-page selection; skip other page")
        XCTAssertFalse(apps.contains(otherPage))

        let created = try LauncherLayout.createFolderFromTopLevelApps(
            orderedAppIDs: apps,
            in: state,
            name: "新建文件夹"
        ).get()
        XCTAssertEqual(created.state.folders[created.folderID]?.itemIDs, [target, a, c, b])
        XCTAssertTrue(created.state.orderedEntries.contains(.folder(created.folderID)))
        XCTAssertFalse(created.state.orderedEntries.contains(.app(a)))
        XCTAssertFalse(created.state.orderedEntries.contains(.app(target)))
        XCTAssertTrue(created.state.orderedEntries.contains(.app(otherPage)))

        // Single selected app → must NOT batch (preserve single-item merge-to-folder).
        let single = LauncherItemSelection(orderedIDs: [a])
        XCTAssertFalse(
            LauncherLayout.shouldBatchCreateFolderFromSelection(
                selection: single,
                draggedID: a,
                targetAppID: target,
                in: state
            )
        )
        let singleMerge = try LauncherLayout.applyDrop(
            LayoutDrop(source: .topLevel(a), destination: .merge(.topLevel(target))),
            to: state
        ).get()
        let newFolderID = singleMerge.folders.keys.first { state.folders[$0] == nil }!
        XCTAssertEqual(Set(singleMerge.folders[newFolderID]!.itemIDs), Set([target, a]))
        XCTAssertTrue(singleMerge.orderedEntries.contains(.app(b)))

        // Drop onto existing folder must not take create-folder batch path.
        let folderID = UUID()
        let withFolder = LayoutState(
            orderedEntries: [.app(a), .app(b), .folder(folderID)],
            folders: [folderID: LauncherFolder(id: folderID, name: "F", itemIDs: [UUID()])],
            appKeys: [a: "a.bundle", b: "b.bundle"]
        )
        XCTAssertFalse(
            LauncherLayout.shouldBatchCreateFolderFromSelection(
                selection: LauncherItemSelection(orderedIDs: [a, b]),
                draggedID: a,
                targetAppID: folderID,
                in: withFolder
            )
        )
    }

    func testBatchMoveSelectionIntoExistingFolderSamePageOnly() throws {
        let folderID = UUID()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let otherPage = UUID()
        var fillers: [UUID] = []
        // page 0: a, b, c, folder, then fillers to fill the page
        while 4 + fillers.count < LauncherLayout.pageCapacity {
            fillers.append(UUID())
        }
        var ordered: [LauncherEntry] = [.app(a), .app(b), .app(c), .folder(folderID)]
        ordered.append(contentsOf: fillers.map { .app($0) })
        ordered.append(.app(otherPage))
        var appKeys: [UUID: String] = [
            a: "a.bundle",
            b: "b.bundle",
            c: "c.bundle",
            otherPage: "other.bundle"
        ]
        for (index, id) in fillers.enumerated() {
            appKeys[id] = "filler.\(index)"
        }
        let member = UUID()
        appKeys[member] = "member.bundle"

        let state = LayoutState(
            orderedEntries: ordered,
            folders: [
                folderID: LauncherFolder(id: folderID, name: "工具", itemIDs: [member])
            ],
            appKeys: appKeys
        )

        let selection = LauncherItemSelection(orderedIDs: [a, c, otherPage, b])
        XCTAssertTrue(
            LauncherLayout.shouldBatchMoveSelectionIntoFolder(
                selection: selection,
                draggedID: a,
                folderID: folderID,
                in: state
            )
        )
        let samePage = LauncherLayout.topLevelAppIDsForBatchMoveIntoFolder(
            selection: selection,
            folderID: folderID,
            in: state
        )
        XCTAssertEqual(samePage, [a, c, b], "other-page selection must not batch-move")
        XCTAssertFalse(samePage.contains(otherPage))

        let moved = try LauncherLayout.moveTopLevelApps(
            samePage,
            intoFolder: folderID,
            in: state
        ).get()
        XCTAssertEqual(Array(moved.folders[folderID]!.itemIDs.suffix(3)), [a, c, b])
        XCTAssertFalse(moved.orderedEntries.contains(.app(a)))
        XCTAssertFalse(moved.orderedEntries.contains(.app(b)))
        XCTAssertFalse(moved.orderedEntries.contains(.app(c)))
        XCTAssertTrue(moved.orderedEntries.contains(.folder(folderID)))
        XCTAssertTrue(moved.orderedEntries.contains(.app(otherPage)), "off-page app stays")

        // Single-item selection must not take the batch path (preserve single drag).
        let single = LauncherItemSelection(orderedIDs: [a])
        XCTAssertFalse(
            LauncherLayout.shouldBatchMoveSelectionIntoFolder(
                selection: single,
                draggedID: a,
                folderID: folderID,
                in: state
            )
        )
        // Dragging an unselected icon while others are selected → no batch.
        let others = LauncherItemSelection(orderedIDs: [b, c])
        XCTAssertFalse(
            LauncherLayout.shouldBatchMoveSelectionIntoFolder(
                selection: others,
                draggedID: a,
                folderID: folderID,
                in: state
            )
        )

        // Single applyDrop onto existing folder still works (regression).
        let addOne = try LauncherLayout.applyDrop(
            LayoutDrop(source: .topLevel(a), destination: .merge(.topLevel(folderID))),
            to: state
        ).get()
        XCTAssertTrue(addOne.folders[folderID]?.itemIDs.contains(a) == true)
        XCTAssertFalse(addOne.orderedEntries.contains(.app(a)))
        XCTAssertTrue(addOne.orderedEntries.contains(.app(b)))
    }

    func testPrunedItemSelectionAfterHideUninstallAndFolderDissolve() {
        let appA = UUID()
        let appB = UUID()
        let appC = UUID()
        let appD = UUID()
        let folderID = UUID()
        // Folder must start with 2+ members: dissolveIfNeeded runs whenever
        // itemIDs.count <= 1, including after an unrelated hide.
        var state = LayoutState(
            orderedEntries: [.app(appA), .folder(folderID), .app(appC)],
            folders: [
                folderID: LauncherFolder(id: folderID, name: "Utilities", itemIDs: [appB, appD])
            ],
            appKeys: [
                appA: "a.bundle",
                appB: "b.bundle",
                appC: "c.bundle",
                appD: "d.bundle"
            ]
        )

        let present = LauncherLayout.presentSelectableItemIDs(in: state)
        XCTAssertEqual(present, Set([appA, folderID, appC, appB, appD]))

        var selection = LauncherItemSelection(orderedIDs: [appA, folderID, appB, appC, appD])
        selection = LauncherLayout.prunedItemSelection(selection, in: state)
        XCTAssertEqual(Set(selection.orderedIDs), Set([appA, folderID, appB, appC, appD]))

        // Hide top-level A — folder keeps 2 members, so it stays.
        state = LauncherLayout.hideApplication(withKey: "a.bundle", in: state)
        selection = LauncherLayout.prunedItemSelection(
            LauncherItemSelection(orderedIDs: [appA, folderID, appB, appC, appD]),
            in: state
        )
        XCTAssertFalse(selection.contains(appA))
        XCTAssertTrue(selection.contains(folderID))
        XCTAssertTrue(selection.contains(appB))
        XCTAssertTrue(selection.contains(appD))
        XCTAssertTrue(selection.contains(appC))
        XCTAssertTrue(state.folders[folderID] != nil)

        // Forget B — folder drops to one member and dissolves into D.
        state = LauncherLayout.forgetUninstalledApplication(withKey: "b.bundle", in: state)
        XCTAssertNil(state.folders[folderID], "folder with one remaining member must dissolve")
        XCTAssertTrue(
            state.orderedEntries.contains(.app(appD)),
            "remaining member becomes top-level after dissolve"
        )
        let afterForget = LauncherLayout.prunedItemSelection(
            LauncherItemSelection(orderedIDs: [folderID, appB, appC, appD]),
            in: state
        )
        XCTAssertFalse(afterForget.contains(appB))
        XCTAssertFalse(afterForget.contains(folderID), "dissolved folder id must leave selection")
        XCTAssertTrue(afterForget.contains(appC))
        XCTAssertTrue(afterForget.contains(appD), "dissolved remaining member stays selectable")
        XCTAssertEqual(
            LauncherLayout.presentSelectableItemIDs(in: state),
            Set([appC, appD])
        )
    }

    func testLauncherItemSelectionReplaceToggleAndPrune() {
        let a = UUID()
        let b = UUID()
        let c = UUID()

        var selection = LauncherItemSelection.empty
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.count, 0)

        selection = LauncherItemSelection.applying(kind: .replace, itemID: a, to: selection)
        XCTAssertEqual(selection.orderedIDs, [a])
        XCTAssertTrue(selection.contains(a))

        selection = LauncherItemSelection.applying(kind: .toggle, itemID: b, to: selection)
        XCTAssertEqual(selection.orderedIDs, [a, b])

        selection = LauncherItemSelection.applying(kind: .toggle, itemID: a, to: selection)
        XCTAssertEqual(selection.orderedIDs, [b])
        XCTAssertFalse(selection.contains(a))

        selection = LauncherItemSelection.applying(kind: .toggle, itemID: a, to: selection)
        XCTAssertEqual(selection.orderedIDs, [b, a])

        selection = LauncherItemSelection.applying(kind: .replace, itemID: c, to: selection)
        XCTAssertEqual(selection.orderedIDs, [c])

        selection.toggle(a)
        selection.toggle(b)
        XCTAssertEqual(Set(selection.orderedIDs), Set([c, a, b]))
        selection.removeAbsent(from: Set([a, b]))
        XCTAssertEqual(Set(selection.orderedIDs), Set([a, b]))
        XCTAssertFalse(selection.contains(c))

        selection.clear()
        XCTAssertTrue(selection.isEmpty)

        // Dedupes on init
        let duped = LauncherItemSelection(orderedIDs: [a, a, b, a])
        XCTAssertEqual(duped.orderedIDs, [a, b])
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

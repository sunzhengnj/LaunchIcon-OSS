import Foundation
import CoreServices
import Darwin

/// Watches standard Applications folders with the public FSEvents API.
/// New installs, deletions, and replacements coalesce into one callback.
public final class ApplicationDirectoryWatcher: @unchecked Sendable {
    /// FSEvents latency and the Dispatch debounce share this window so a burst
    /// of installs, deletes, or renames becomes one callback.
    public static let defaultEventCoalescingInterval: TimeInterval = 0.8

    private var stream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    private let onChange: @Sendable () -> Void
    private let onRootChanged: @Sendable () -> Void
    private let eventCoalescingInterval: TimeInterval
    private var watchedDirectoryPaths: [String] = []
    private var rebindingRootPaths: Set<String> = []
    private var rootChangePending = false
    public private(set) var watchesAllRoots = false

    public init(
        onChange: @escaping @Sendable () -> Void,
        onRootChanged: @escaping @Sendable () -> Void = {},
        eventCoalescingInterval: TimeInterval = ApplicationDirectoryWatcher.defaultEventCoalescingInterval
    ) {
        self.onChange = onChange
        self.onRootChanged = onRootChanged
        self.eventCoalescingInterval = eventCoalescingInterval
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start(roots: [URL] = AppCatalogScanner.standardRoots) -> Bool {
        stop()
        let existingRoots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        let coversAllRoots = existingRoots.count == roots.count
        let linkedRoots = existingRoots.filter {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil
        }
        let missingRoots = roots.filter { !FileManager.default.fileExists(atPath: $0.path) }
        let rebindingRoots = linkedRoots + missingRoots
        watchedDirectoryPaths = existingRoots.map { Self.canonicalPath($0.path) }
        rebindingRootPaths = Set(rebindingRoots.map { Self.canonicalEventPath($0.path) })
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = Array(Set(watchedDirectoryPaths + rebindingRoots.compactMap {
            Self.nearestExistingDirectory($0.deletingLastPathComponent().path)
        })) as CFArray
        guard CFArrayGetCount(paths) > 0 else { return false }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf
                | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )
        stream = FSEventStreamCreate(
            nil,
            { _, info, eventCount, eventPaths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<ApplicationDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let eventPathArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                let paths = (0..<CFArrayGetCount(eventPathArray)).compactMap { index -> String? in
                    guard let value = CFArrayGetValueAtIndex(eventPathArray, index) else { return nil }
                    return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
                }
                let rootChanged = (0..<eventCount).contains {
                    eventFlags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                }
                watcher.handleEvents(at: paths, rootChanged: rootChanged)
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            eventCoalescingInterval,
            flags
        )
        guard let stream else { return false }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            stop()
            return false
        }
        watchesAllRoots = coversAllRoots
        return true
    }

    public func stop() {
        watchesAllRoots = false
        debounceWork?.cancel()
        debounceWork = nil
        rootChangePending = false
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Visible for Core tests so debounce can be exercised without a live FSEvents burst.
    func handleEvents(at paths: [String], rootChanged rootWasMoved: Bool) {
        // FSEvents and test callers may pass /var/... while start() stored
        // realpath /private/var/.... Compare both the raw and canonical forms
        // so a rename/move event is not dropped.
        let eventPaths = paths.flatMap { path -> [String] in
            let canonical = Self.canonicalPath(path)
            return canonical == path ? [path] : [path, canonical]
        }
        let rootChanged = rootWasMoved || eventPaths.contains { path in
            rebindingRootPaths.contains { root in root == path || root.hasPrefix(path + "/") }
        }
        let changed = eventPaths.contains { path in
            watchedDirectoryPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        guard rootChanged || changed else { return }
        rootChangePending = rootChangePending || rootChanged
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let rootChanged = self.rootChangePending
            self.rootChangePending = false
            self.onChange()
            if rootChanged { self.onRootChanged() }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + eventCoalescingInterval, execute: work)
    }

    private static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url.path }
        return (canonicalPath(parent.path) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    private static func nearestExistingDirectory(_ path: String) -> String? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory = ObjCBool(false)
        while !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                || !isDirectory.boolValue {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return nil }
            url = parent
        }
        return canonicalPath(url.path)
    }

    private static func canonicalEventPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return (canonicalPath(url.deletingLastPathComponent().path) as NSString)
            .appendingPathComponent(url.lastPathComponent)
    }
}

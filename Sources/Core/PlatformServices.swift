import AppKit
import Carbon.HIToolbox
import Darwin
import UniformTypeIdentifiers

public protocol AppIconProviding: Sendable {
    func icon(for applicationURL: URL) -> NSImage
}

public struct WorkspaceIconProvider: AppIconProviding {
    public init() {}

    public func icon(for applicationURL: URL) -> NSImage {
        WorkspaceIconCache.shared.icon(for: applicationURL)
    }
}

private final class IconLoadFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: CheckedContinuation<NSImage, any Error>] = [:]
    private var operation: Operation?
    private var cancelled = false
    private var completed = false

    var acceptsWaiters: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && !completed
    }

    func addWaiter(
        id: UUID,
        continuation: CheckedContinuation<NSImage, any Error>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !completed else { return false }
        continuations[id] = continuation
        return true
    }

    func start(
        on queue: OperationQueue,
        load: @escaping @Sendable () -> NSImage,
        onCompletion: @escaping @Sendable (IconLoadFlight) -> Void
    ) {
        let operation = BlockOperation()
        operation.addExecutionBlock { [self] in
            guard !isCancelled else { return }
            complete(with: load(), onCompletion: onCompletion)
        }

        lock.lock()
        guard !cancelled, !completed, !continuations.isEmpty else {
            lock.unlock()
            return
        }
        self.operation = operation
        lock.unlock()
        queue.addOperation(operation)
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancelWaiter(
        id: UUID,
        onEmpty: @escaping @Sendable (IconLoadFlight) -> Void
    ) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: id)
        // Workspace icon reads already in progress cannot be force-cancelled; keep the flight cacheable/rejoinable.
        let shouldCancelFlight = continuations.isEmpty && !completed && operation?.isExecuting != true
        let operationToCancel: Operation?
        if shouldCancelFlight {
            cancelled = true
            operationToCancel = operation
            operation = nil
        } else {
            operationToCancel = nil
        }
        lock.unlock()

        continuation?.resume(throwing: CancellationError())
        if shouldCancelFlight {
            operationToCancel?.cancel()
            onEmpty(self)
        }
    }

    private func complete(
        with image: NSImage,
        onCompletion: @escaping @Sendable (IconLoadFlight) -> Void
    ) {
        lock.lock()
        guard !cancelled, !completed else {
            lock.unlock()
            return
        }
        completed = true
        operation = nil
        let pendingContinuations = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()

        onCompletion(self)
        pendingContinuations.forEach { $0.resume(returning: image) }
    }
}

private final class IconLoadWaiter: @unchecked Sendable {
    enum Attachment {
        case attached
        case cancelled
        case unavailable
    }

    private let lock = NSLock()
    private let id = UUID()
    private var flight: IconLoadFlight?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(
        to flight: IconLoadFlight,
        continuation: CheckedContinuation<NSImage, any Error>
    ) -> Attachment {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return .cancelled
        }
        guard flight.addWaiter(id: id, continuation: continuation) else {
            lock.unlock()
            return .unavailable
        }
        self.flight = flight
        lock.unlock()
        return .attached
    }

    func cancel(onEmpty: @escaping @Sendable (IconLoadFlight) -> Void) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let flight = self.flight
        self.flight = nil
        lock.unlock()

        flight?.cancelWaiter(id: id, onEmpty: onEmpty)
    }
}

/// Process-local icon cache. `NSWorkspace.icon(forFile:)` is too slow to call
/// on every collection-view configure; Launchpad-style grids reuse the same images.
public final class WorkspaceIconCache: @unchecked Sendable {
    public static let shared = WorkspaceIconCache()
    private static let pointSize = NSSize(width: 84, height: 84)
    private static let pixelSize = 168
    private static let iconCost = pixelSize * pixelSize * 4
    private static let placeholderImage = rasterizedIcon(NSWorkspace.shared.icon(for: .applicationBundle))

    private let storage = NSCache<NSString, NSImage>()
    private let iconQueue: OperationQueue
    private let iconLoader: (URL) -> NSImage
    private let iconLoadsLock = NSLock()
    private var iconLoads: [String: IconLoadFlight] = [:]

    public convenience init() {
        let queue = OperationQueue()
        queue.name = "LaunchIcon.IconLoading"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        self.init(iconQueue: queue) { url in
            autoreleasepool {
                Self.rasterizedIcon(NSWorkspace.shared.icon(forFile: url.path))
            }
        }
    }

    init(iconQueue: OperationQueue, iconLoader: @escaping (URL) -> NSImage) {
        self.iconQueue = iconQueue
        self.iconLoader = iconLoader
        storage.countLimit = 256
        storage.totalCostLimit = 24 * 1_024 * 1_024
    }

    public static var placeholder: NSImage {
        placeholderImage
    }

    public func cachedIcon(for applicationURL: URL) -> NSImage? {
        storage.object(forKey: applicationURL.path as NSString)
    }

    public func cachedIcon(for candidate: AppCandidate) -> NSImage? {
        storage.object(forKey: Self.key(for: candidate))
    }

    public func prefetchIcons(for candidates: [AppCandidate]) async throws {
        let batchSize = 20
        var batchStart = 0
        while batchStart < candidates.count {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + batchSize, candidates.count)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for candidate in candidates[batchStart..<batchEnd] {
                    group.addTask {
                        _ = try await self.loadIcon(for: candidate)
                    }
                }
                try await group.waitForAll()
            }
            batchStart = batchEnd
        }
    }

    public func icon(for applicationURL: URL) -> NSImage {
        icon(for: applicationURL, key: applicationURL.path as NSString)
    }

    public func icon(for candidate: AppCandidate) -> NSImage {
        icon(for: candidate.canonicalURL, key: Self.key(for: candidate))
    }

    private func icon(for applicationURL: URL, key: NSString) -> NSImage {
        if let cached = storage.object(forKey: key) {
            return cached
        }
        let image = iconLoader(applicationURL)
        storage.setObject(image, forKey: key, cost: Self.iconCost)
        return image
    }

    private func icon(for applicationURL: URL, key: String) -> NSImage {
        icon(for: applicationURL, key: key as NSString)
    }

    public func loadIcon(for applicationURL: URL) async throws -> NSImage {
        try Task.checkCancellation()
        if let cached = cachedIcon(for: applicationURL) {
            return cached
        }
        return try await loadIcon(for: applicationURL, key: applicationURL.path as NSString)
    }

    public func loadIcon(for candidate: AppCandidate) async throws -> NSImage {
        try Task.checkCancellation()
        if let cached = cachedIcon(for: candidate) {
            return cached
        }
        return try await loadIcon(for: candidate.canonicalURL, key: Self.key(for: candidate))
    }

    public func loadIcons(for candidates: [AppCandidate]) async throws -> [NSImage] {
        let batchSize = 4
        var images: [NSImage] = []
        images.reserveCapacity(candidates.count)

        for batchStart in stride(from: 0, to: candidates.count, by: batchSize) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + batchSize, candidates.count)
            let batch = Array(candidates[batchStart..<batchEnd])
            let loadedBatch = try await withThrowingTaskGroup(of: (Int, NSImage).self) { group in
                for (index, candidate) in batch.enumerated() {
                    group.addTask {
                        (index, try await self.loadIcon(for: candidate))
                    }
                }

                var orderedImages = Array<NSImage?>(repeating: nil, count: batch.count)
                for try await (index, image) in group {
                    orderedImages[index] = image
                }
                return orderedImages.compactMap { $0 }
            }
            images.append(contentsOf: loadedBatch)
        }

        return images
    }

    private func loadIcon(for applicationURL: URL, key: NSString) async throws -> NSImage {
        let waiter = IconLoadWaiter()
        let keyString = key as String
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, any Error>) in
                registerIconLoad(
                    for: applicationURL,
                    key: key,
                    waiter: waiter,
                    continuation: continuation
                )
            }
        } onCancel: {
            waiter.cancel { [weak self] flight in
                self?.removeIconLoad(for: keyString, ifMatches: flight)
            }
        }
    }

    private func registerIconLoad(
        for applicationURL: URL,
        key: NSString,
        waiter: IconLoadWaiter,
        continuation: CheckedContinuation<NSImage, any Error>
    ) {
        while true {
            if waiter.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            if let image = storage.object(forKey: key) {
                continuation.resume(returning: image)
                return
            }

            let keyString = key as String
            let (flight, shouldStart) = acquireIconLoad(for: keyString)
            switch waiter.attach(to: flight, continuation: continuation) {
            case .attached:
                guard shouldStart else { return }
                flight.start(on: iconQueue) { [self] in
                    icon(for: applicationURL, key: keyString)
                } onCompletion: { [weak self] completedFlight in
                    self?.removeIconLoad(for: keyString, ifMatches: completedFlight)
                }
                return
            case .cancelled:
                if shouldStart {
                    removeIconLoad(for: keyString, ifMatches: flight)
                }
                return
            case .unavailable:
                removeIconLoad(for: keyString, ifMatches: flight)
            }
        }
    }

    private func acquireIconLoad(for key: String) -> (flight: IconLoadFlight, shouldStart: Bool) {
        iconLoadsLock.lock()
        defer { iconLoadsLock.unlock() }
        if let flight = iconLoads[key], flight.acceptsWaiters {
            return (flight, false)
        }
        let flight = IconLoadFlight()
        iconLoads[key] = flight
        return (flight, true)
    }

    private func removeIconLoad(for key: String, ifMatches flight: IconLoadFlight) {
        iconLoadsLock.lock()
        defer { iconLoadsLock.unlock() }
        if iconLoads[key] === flight {
            iconLoads[key] = nil
        }
    }

    private static func key(for candidate: AppCandidate) -> NSString {
        let version = candidate.modificationDate
            .map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "unknown"
        return "\(candidate.canonicalURL.path)\u{0}\(version)" as NSString
    }

    private static func rasterizedIcon(_ source: NSImage) -> NSImage {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return source
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        representation.size = pointSize

        let image = NSImage(size: pointSize)
        image.addRepresentation(representation)
        return image
    }
}

public protocol AppLaunching: Sendable {
    /// Finder-style open. Must not wait for the target app to finish launching.
    func openImmediately(_ applicationURL: URL) throws -> WorkspaceAppLauncher.ImmediateOpenResult
    func launch(_ applicationURL: URL) async throws
}

public enum WorkspaceLaunchError: LocalizedError, Equatable, Sendable {
    case requestRejected(URL)
    /// Kept for callers that still surface a late Launch Services failure.
    /// The Finder-style path no longer uses a fixed wall-clock timeout.
    case timedOut(URL)

    public var errorDescription: String? {
        switch self {
        case .requestRejected:
            return "系统未接受打开应用的请求。"
        case .timedOut:
            return "系统未能完成启动请求；应用可能仍在启动或已被拒绝。"
        }
    }
}

public struct WorkspaceAppLauncher: AppLaunching {
    public enum ImmediateOpenResult: Equatable, Sendable {
        case activated
        case opened
    }

    /// Invoked off the caller thread after `/usr/bin/open` exits. Status 0 is
    /// success; any other status means Launch Services rejected the request
    /// after spawn returned.
    public typealias OpenProcessFinishedHandler = @Sendable (URL, Int32) -> Void

    private let immediateOpen: @Sendable (URL) throws -> ImmediateOpenResult

    public init(onOpenProcessFinished: OpenProcessFinishedHandler? = nil) {
        self.init(immediateOpen: { url in
            try Self.systemImmediateOpen(url, onOpenProcessFinished: onOpenProcessFinished)
        })
    }

    init(immediateOpen: @escaping @Sendable (URL) throws -> ImmediateOpenResult) {
        self.immediateOpen = immediateOpen
    }

    /// Opens via `/usr/bin/open` (same as Finder / shell). Spawns `open` and
    /// returns after `run()` — does **not** `waitUntilExit` on the caller
    /// thread. Waiting on the main runloop deadlocks Launch Services for some
    /// apps (Devin). Must not call `Bundle(url:)` or `NSWorkspace.open` /
    /// `openApplication` on this hot path — those AppKit/LaunchServices entry
    /// points can raise ObjC exceptions that HIServices swallows, aborting the
    /// Swift opener after "Launch requested" with no catch, no pending clear,
    /// and no target process (seen with Devin / Windsurf on preview.73–74).
    /// A non-zero `open` exit is reported later via `onOpenProcessFinished`.
    public func openImmediately(_ applicationURL: URL) throws -> ImmediateOpenResult {
        try immediateOpen(applicationURL)
    }

    public func launch(_ applicationURL: URL) async throws {
        _ = try openImmediately(applicationURL)
    }

    private static func systemImmediateOpen(
        _ applicationURL: URL,
        onOpenProcessFinished: OpenProcessFinishedHandler?
    ) throws -> ImmediateOpenResult {
        // Absolute file URL only — do not touch Bundle or NSWorkspace here.
        guard applicationURL.isFileURL else {
            throw WorkspaceLaunchError.requestRejected(applicationURL)
        }
        let url = applicationURL.standardizedFileURL
        let path = url.path
        guard !path.isEmpty, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
            throw WorkspaceLaunchError.requestRejected(applicationURL)
        }
        // Fixture-style bundles and other Mac apps that cannot run make
        // `/usr/bin/open` exit 1 ("executable is missing" or "incorrect
        // executable format"). A fifo with the execute bit is worse: `open`
        // does not return, including when the plist is missing or unreadable
        // and the bundle filename is that fifo. Rejecting here keeps the
        // click on the synchronous failure path (toast, no hide). A runnable
        // file under `Contents/MacOS`, `Contents`, or the bundle root, and
        // real apps with no Contents/Info.plist, still spawn.
        if LauncherLayout.shouldRejectOpenBeforeSpawn(executable: openBundleExecutable(at: url)) {
            throw WorkspaceLaunchError.requestRejected(applicationURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // `Process` is not thread-safe, so do not `waitUntilExit` on another
        // queue. The termination handler is the supported exit callback, and
        // it runs off the caller. Retain until that handler: dropping `Process`
        // immediately (Store spike passes no callback) can reap `/usr/bin/open`
        // before Launch Services accepts the request.
        let callback = onOpenProcessFinished
        let lifetime = OpenProcessLifetime(process)
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            callback?(url, status)
            lifetime.release()
        }
        do {
            try process.run()
            return .opened
        } catch {
            process.terminationHandler = nil
            lifetime.release()
            throw WorkspaceLaunchError.requestRejected(applicationURL)
        }
    }

    /// Reads `Contents/Info.plist` with `NSDictionary` only. `Bundle(url:)` is
    /// intentionally not used; see `LauncherLayout.OpenBundleExecutable`.
    public static func openBundleExecutable(at url: URL) -> LauncherLayout.OpenBundleExecutable {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let infoPath = infoURL.path
        // No node at all, including a dangling symlink. `open` still receives
        // the bundle. The one exception is a bundle-name fifo (or socket or
        // device): Launch Services blocks in `open()` while recording the
        // executable format, and killing the client does not unblock it.
        guard FileManager.default.fileExists(atPath: infoPath) else {
            if case .named(.notRegularFile) = bundleNameFallback(at: url) {
                return .named(.notRegularFile)
            }
            return .notMacInfoPlist
        }
        // Present, but not a property list `open` can read: an empty file, a
        // corrupt file, a directory, a fifo, a socket, or a device. `open`
        // then uses the bundle filename and the same three-directory search.
        // Stat first. `NSDictionary` happens to return nil for a fifo, but
        // the file open must not be how that fact is learned.
        if regularFileSize(at: infoPath) == nil {
            return bundleNameFallback(at: url)
        }
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            return bundleNameFallback(at: url)
        }
        if let raw = info["CFBundleExecutable"] {
            if let name = nonEmptyExecutableString(raw) {
                // `/usr/bin/open` uses this string as the filename and does not
                // trim. A name of spaces is launchable when that file exists.
                // `""` is not a filename. A non-string is not either. Neither
                // consults `NSExecutable`; both use the bundle filename.
                // An explicit different string does not fall back when missing.
                return resolvedExecutable(named: name, in: url)
            }
            return bundleNameFallback(at: url)
        }
        // The key itself is absent. A non-empty `NSExecutable` is the filename
        // and does not fall through to the bundle name when that file is gone.
        // An empty or non-string `NSExecutable` is ignored.
        if let legacy = nonEmptyExecutableString(info["NSExecutable"]) {
            return resolvedExecutable(named: legacy, in: url)
        }
        return bundleNameFallback(at: url)
    }

    /// `/usr/bin/open` uses the bundle filename when the plist has no
    /// executable name, and also when a plist node exists but is not a
    /// property list. The filename drops only the last extension:
    /// `Foo.bar.app` loads `Foo.bar`, `My App.app` loads `My App`.
    /// `CFBundleName` is not the fallback. A non-regular file is returned
    /// as itself so the caller does not spawn `open` onto a fifo. Anything
    /// else that cannot run is `.absent`.
    private static func bundleNameFallback(at url: URL) -> LauncherLayout.OpenBundleExecutable {
        let bundleName = url.deletingPathExtension().lastPathComponent
        guard !bundleName.isEmpty else { return .absent }
        let resolved = resolvedExecutable(named: bundleName, in: url)
        switch resolved {
        case .named(.executableFile), .named(.notRegularFile):
            return resolved
        default:
            return .absent
        }
    }

    private static func nonEmptyExecutableString(_ raw: Any?) -> String? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Search order proved against `/usr/bin/open`: `Contents/MacOS/<name>`,
    /// then `Contents/<name>`, then `<bundle>/<name>`. `.` and `..` and empty
    /// slash components are normalized. The first path that exists wins, so a
    /// bad file in `MacOS` hides a good file at the bundle root. An absolute
    /// name ignores those directories. A lexical path outside the bundle is
    /// not launched, even when the file is runnable. `fstatat` follows the
    /// final symlink and does not open it, so a fifo cannot block this check.
    private static func resolvedExecutable(
        named name: String,
        in bundle: URL
    ) -> LauncherLayout.OpenBundleExecutable {
        let bundleURL = bundle.standardizedFileURL
        var bundlePath = bundleURL.path
        if bundlePath.count > 1, bundlePath.hasSuffix("/") {
            bundlePath.removeLast()
        }
        if name.hasPrefix("/") {
            let path = lexicalExecutablePath(base: "/", name: name)
            guard namedMacOSExecutable(at: path) != .missing else { return .named(.missing) }
            return .absolute
        }
        let bases = [
            bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .path,
            bundleURL.appendingPathComponent("Contents", isDirectory: true).path,
            bundlePath
        ]
        for base in bases {
            let path = lexicalExecutablePath(base: base, name: name)
            let kind = namedMacOSExecutable(at: path)
            guard kind != .missing else { continue }
            guard pathStaysInBundle(candidate: path, bundlePath: bundlePath) else {
                return .outsideBundle
            }
            return .named(kind)
        }
        return .named(.missing)
    }

    /// POSIX lexical join. Does not touch the filesystem and does not resolve
    /// symlinks: `open` follows a symlink stored inside the bundle, and the
    /// path it starts from is this string.
    private static func lexicalExecutablePath(base: String, name: String) -> String {
        var parts: [String] = []
        if !name.hasPrefix("/") {
            parts = base.split(separator: "/").map(String.init)
        }
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(component))
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func pathStaysInBundle(candidate: String, bundlePath: String) -> Bool {
        if bundlePath == "/" { return candidate.hasPrefix("/") }
        if candidate == bundlePath { return true }
        return candidate.hasPrefix(bundlePath + "/")
    }

    /// `fileExists` alone treats a directory, a mode-644 placeholder, an empty
    /// file, and a fifo as launchable. The first two make `/usr/bin/open` exit
    /// 1. An empty file does too ("incorrect executable format"). A fifo with
    /// the execute bit does not return. Follow symlinks the same way Launch
    /// Services does. Do not call `Bundle`, and do not open the file: opening
    /// a fifo blocks.
    private static func namedMacOSExecutable(at path: String) -> LauncherLayout.OpenBundleExecutable.NamedFile {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        if isDirectory.boolValue {
            return .directory
        }
        // A directory is "executable" in the POSIX sense. That check is only
        // meaningful after the directory case above.
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .notExecutable
        }
        switch regularFileSize(at: path) {
        case let size? where size > 0:
            return .executableFile
        case .some:
            return .emptyFile
        case .none:
            return .notRegularFile
        }
    }

    /// Size of a regular file, following symlinks. `nil` when the path is not
    /// a regular file. `fstatat` does not open the file, so a fifo cannot block.
    /// The C `stat` function is not used: Swift's `stat` struct hides it.
    private static func regularFileSize(at path: String) -> Int64? {
        var followed = Darwin.stat()
        let result = path.withCString { fstatat(AT_FDCWD, $0, &followed, 0) }
        guard result == 0, (followed.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(followed.st_size)
    }
}

/// Keeps one `/usr/bin/open` `Process` alive until its termination handler runs.
private final class OpenProcessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    init(_ process: Process) {
        self.process = process
    }

    func release() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

public protocol GlobalHotKeyRegistering: AnyObject {
    func registerOptionSpace(onPressed: @escaping @Sendable () -> Void) -> Result<Void, HotKeyRegistrationError>
    func unregister()
}

public enum HotKeyRegistrationError: Error, Equatable {
    case registrationFailed(OSStatus)
}

public final class CarbonGlobalHotKeyService: GlobalHotKeyRegistering {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onPressed: (@Sendable () -> Void)?
    private var registeredShortcut: LauncherShortcut?
    private var nextIdentifier: UInt32 = 1

    public init() {}

    deinit { unregister() }

    public func registerOptionSpace(onPressed: @escaping @Sendable () -> Void) -> Result<Void, HotKeyRegistrationError> {
        register(.optionSpace, onPressed: onPressed)
    }

    public func register(
        _ shortcut: LauncherShortcut,
        onPressed: @escaping @Sendable () -> Void
    ) -> Result<Void, HotKeyRegistrationError> {
        if registeredShortcut == shortcut {
            self.onPressed = onPressed
            return .success(())
        }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        if handler == nil {
            let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            let handlerStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData in
                    guard let userData else { return noErr }
                    let service = Unmanaged<CarbonGlobalHotKeyService>.fromOpaque(userData).takeUnretainedValue()
                    service.onPressed?()
                    return noErr
                },
                1,
                &eventType,
                userData,
                &handler
            )
            guard handlerStatus == noErr else { return .failure(.registrationFailed(handlerStatus)) }
        }

        let identifier = EventHotKeyID(signature: OSType(0x4C49434E), id: nextIdentifier)
        nextIdentifier &+= 1
        var replacement: EventHotKeyRef?
        let modifiers: UInt32
        switch shortcut {
        case .optionSpace: modifiers = UInt32(optionKey)
        case .optionShiftSpace: modifiers = UInt32(optionKey | shiftKey)
        case .controlShiftSpace: modifiers = UInt32(controlKey | shiftKey)
        }
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &replacement
        )
        guard hotKeyStatus == noErr else {
            return .failure(.registrationFailed(hotKeyStatus))
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        registeredShortcut = shortcut
        self.onPressed = onPressed
        return .success(())
    }

    public func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        onPressed = nil
        registeredShortcut = nil
    }
}

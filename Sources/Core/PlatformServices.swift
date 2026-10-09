import AppKit
import Carbon.HIToolbox
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
    func launch(_ applicationURL: URL) async throws
}

public enum WorkspaceLaunchError: LocalizedError, Equatable, Sendable {
    case requestRejected(URL)
    case timedOut(URL)

    public var errorDescription: String? {
        switch self {
        case .requestRejected:
            return "系统未接受打开应用的请求。"
        case .timedOut:
            return "系统未在 10 秒内回应启动请求；应用可能仍在启动。"
        }
    }
}

private final class WorkspaceLaunchFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

public struct WorkspaceAppLauncher: AppLaunching {
    public init() {}

    public func launch(_ applicationURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let flight = WorkspaceLaunchFlight(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                flight.finish(.failure(WorkspaceLaunchError.timedOut(applicationURL)))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: applicationURL.path),
                      let executableURL = Bundle(url: applicationURL)?.executableURL,
                      fileManager.isExecutableFile(atPath: executableURL.path),
                      NSWorkspace.shared.open(applicationURL) else {
                    flight.finish(.failure(WorkspaceLaunchError.requestRejected(applicationURL)))
                    return
                }
                flight.finish(.success(()))
            }
        }
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

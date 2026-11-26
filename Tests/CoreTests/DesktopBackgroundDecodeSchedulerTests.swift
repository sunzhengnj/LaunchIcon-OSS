import CoreGraphics
import Foundation
import XCTest
@testable import LaunchIconCore

private final class BlockingWallpaperDecoder: @unchecked Sendable {
    private final class Gate {
        let started: XCTestExpectation
        let release = DispatchSemaphore(value: 0)

        init(_ name: String) {
            started = XCTestExpectation(description: "decode started: \(name)")
        }
    }

    private let lock = NSLock()
    private let gates: [String: Gate]
    private let failures: Set<String>
    private let image: CGImage
    private var names: [String] = []
    private var active = 0
    private var peak = 0

    init(_ names: [String], failures: Set<String> = []) {
        gates = Dictionary(uniqueKeysWithValues: names.map { ($0, Gate($0)) })
        self.failures = failures
        image = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    var startedNames: [String] { lock.withLock { names } }
    var maximumActive: Int { lock.withLock { peak } }
    func started(_ name: String) -> XCTestExpectation { gates[name]!.started }
    func release(_ name: String) { gates[name]!.release.signal() }
    func releaseAll() { for gate in gates.values { gate.release.signal() } }

    func decode(_ request: DesktopBackgroundDecodeScheduler.Request) -> CGImage? {
        let name = request.url.lastPathComponent
        guard let gate = gates[name] else {
            XCTFail("Unexpected decode: \(name)")
            return nil
        }
        lock.withLock {
            names.append(name)
            active += 1
            peak = max(peak, active)
        }
        defer {
            lock.withLock { active -= 1 }
        }
        gate.started.fulfill()
        guard gate.release.wait(timeout: .now() + 10) == .success else {
            XCTFail("Decoder gate was not released: \(name)")
            return nil
        }
        return failures.contains(name) ? nil : image
    }
}

// Observe the real production finish closure AFTER it returns on MainActor.
// Only the executor wrapper is injected; scheduling state/decisions stay in Core.
@MainActor
private final class WallpaperCompletionBarrier {
    let firstProcessed = XCTestExpectation(description: "first scheduler completion processed")
    private var processed = 0

    nonisolated func enqueue(_ finish: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            finish()
            self.processed += 1
            if self.processed == 1 { self.firstProcessed.fulfill() }
        }
    }
}

@MainActor
private final class WallpaperDeliveries {
    var tickets: [UUID] = []
    var hasImages: [Bool] = []

    func record(_ ticket: UUID, image: CGImage?) {
        tickets.append(ticket)
        hasImages.append(image != nil)
    }
}

// A small lifetime fixture, not a substitute scheduler or an AppKit root test.
@MainActor
private final class WallpaperRequestOwner {
    private let scheduler: DesktopBackgroundDecodeScheduler
    private var ticket: UUID?

    init(_ scheduler: DesktopBackgroundDecodeScheduler) { self.scheduler = scheduler }

    func submit(_ request: DesktopBackgroundDecodeScheduler.Request,
                probe: BlockingWallpaperDecoder, onCompletion: @escaping @MainActor @Sendable () -> Void) {
        ticket = scheduler.submit(request, decode: { probe.decode($0) }) { [weak self] _, _ in
            guard self != nil else { return }
            onCompletion()
        }
    }

    isolated deinit {
        if let ticket { scheduler.cancel(ticket) }
    }
}

final class DesktopBackgroundDecodeSchedulerTests: XCTestCase, @unchecked Sendable {
    private func request(_ name: String) -> DesktopBackgroundDecodeScheduler.Request {
        .init(url: URL(fileURLWithPath: "/wallpaper-test/\(name)"),
              maximumPixelSize: 1, appearanceIdentity: "light")
    }

    @MainActor
    func testBlockedAOnlyDecodesLatestCAndDeliversItOnce() async {
        let scheduler = DesktopBackgroundDecodeScheduler()
        let probe = BlockingWallpaperDecoder(["A", "B", "C"])
        defer { probe.releaseAll() }
        let deliveries = WallpaperDeliveries()
        let done = expectation(description: "C delivered")
        _ = scheduler.submit(request("A"), decode: { probe.decode($0) }) { ticket, image in
            deliveries.record(ticket, image: image)
        }
        await fulfillment(of: [probe.started("A")], timeout: 3)
        _ = scheduler.submit(request("B"), decode: { probe.decode($0) }) { _, _ in XCTFail("B delivered") }
        let c = scheduler.submit(request("C"), decode: { probe.decode($0) }) { ticket, image in
            deliveries.record(ticket, image: image)
            done.fulfill()
        }
        probe.release("A")
        await fulfillment(of: [probe.started("C")], timeout: 3)
        XCTAssertEqual(probe.startedNames, ["A", "C"])
        probe.release("C")
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(probe.maximumActive, 1)
        XCTAssertEqual(deliveries.tickets, [c])
        XCTAssertEqual(deliveries.hasImages, [true])
    }

    @MainActor
    func testCancelPendingDoesNotDecodeItOrResurrectAAndAllowsD() async {
        let barrier = WallpaperCompletionBarrier()
        let scheduler = DesktopBackgroundDecodeScheduler(enqueueCompletion: { barrier.enqueue($0) })
        let probe = BlockingWallpaperDecoder(["A", "B", "C", "D"])
        defer { probe.releaseAll() }
        let done = expectation(description: "D delivered")
        _ = scheduler.submit(request("A"), decode: { probe.decode($0) }) { _, _ in XCTFail("A resurrected") }
        await fulfillment(of: [probe.started("A")], timeout: 3)
        _ = scheduler.submit(request("B"), decode: { probe.decode($0) }) { _, _ in XCTFail("B delivered") }
        let c = scheduler.submit(request("C"), decode: { probe.decode($0) }) { _, _ in XCTFail("C delivered") }
        scheduler.cancel(c)
        scheduler.cancel(c)
        // A's MainActor state transition must finish BEFORE D can overwrite pending.
        // If cancel(C) is broken, C is already active here and D cannot hide it.
        probe.release("A")
        await fulfillment(of: [barrier.firstProcessed], timeout: 3)
        _ = scheduler.submit(request("D"), decode: { probe.decode($0) }) { _, _ in done.fulfill() }
        probe.release("D")
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(probe.startedNames, ["A", "D"])
        XCTAssertEqual(probe.maximumActive, 1)
    }

    @MainActor
    func testCancelActiveRetainsBusySlotAndCoalescesItsSuccessors() async {
        let scheduler = DesktopBackgroundDecodeScheduler()
        let probe = BlockingWallpaperDecoder(["A", "B", "C"])
        defer { probe.releaseAll() }
        let done = expectation(description: "C delivered")
        let a = scheduler.submit(request("A"), decode: { probe.decode($0) }) { _, _ in XCTFail("A delivered") }
        await fulfillment(of: [probe.started("A")], timeout: 3)
        scheduler.cancel(a)
        scheduler.cancel(a)
        _ = scheduler.submit(request("B"), decode: { probe.decode($0) }) { _, _ in XCTFail("B delivered") }
        _ = scheduler.submit(request("C"), decode: { probe.decode($0) }) { _, _ in done.fulfill() }
        scheduler.cancel(a)
        probe.release("A")
        await fulfillment(of: [probe.started("C")], timeout: 3)
        XCTAssertEqual(probe.startedNames, ["A", "C"])
        probe.release("C")
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(probe.maximumActive, 1)
    }

    @MainActor
    func testNilFailureCanSynchronouslySubmitRetryFromCallback() async {
        let scheduler = DesktopBackgroundDecodeScheduler()
        let probe = BlockingWallpaperDecoder(["A", "B"], failures: ["A"])
        defer { probe.releaseAll() }
        let deliveries = WallpaperDeliveries()
        let done = expectation(description: "retry delivered")
        _ = scheduler.submit(request("A"), decode: { probe.decode($0) }) { [weak scheduler] ticket, image in
            deliveries.record(ticket, image: image)
            guard let scheduler else { XCTFail("scheduler disappeared"); return }
            let retry = DesktopBackgroundDecodeScheduler.Request(
                url: URL(fileURLWithPath: "/wallpaper-test/B"), maximumPixelSize: 1, appearanceIdentity: "light")
            _ = scheduler.submit(retry, decode: { probe.decode($0) }) { ticket, image in
                deliveries.record(ticket, image: image)
                done.fulfill()
            }
        }
        probe.release("A")
        await fulfillment(of: [probe.started("B")], timeout: 3)
        probe.release("B")
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(probe.startedNames, ["A", "B"])
        XCTAssertEqual(deliveries.hasImages, [false, true])
        XCTAssertEqual(Set(deliveries.tickets).count, 2)
        XCTAssertEqual(probe.maximumActive, 1)
    }

    @MainActor
    func testObsoleteNilFailureDoesNotInvokeFailureCallback() async {
        let scheduler = DesktopBackgroundDecodeScheduler()
        let probe = BlockingWallpaperDecoder(["A", "C"], failures: ["A"])
        defer { probe.releaseAll() }
        let done = expectation(description: "C delivered")
        _ = scheduler.submit(request("A"), decode: { probe.decode($0) }) { _, _ in XCTFail("obsolete failure delivered") }
        await fulfillment(of: [probe.started("A")], timeout: 3)
        _ = scheduler.submit(request("C"), decode: { probe.decode($0) }) { _, image in
            XCTAssertNotNil(image)
            done.fulfill()
        }
        probe.release("A")
        probe.release("C")
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(probe.startedNames, ["A", "C"])
    }

    @MainActor
    func testCompletedOrUnknownTicketCancellationDoesNotCancelNextRequest() async {
        let scheduler = DesktopBackgroundDecodeScheduler()
        let probe = BlockingWallpaperDecoder(["A", "B"])
        defer { probe.releaseAll() }
        let first = expectation(description: "A delivered")
        let second = expectation(description: "B delivered")
        let a = scheduler.submit(request("A"), decode: { probe.decode($0) }) { _, _ in first.fulfill() }
        probe.release("A")
        await fulfillment(of: [first], timeout: 3)
        _ = scheduler.submit(request("B"), decode: { probe.decode($0) }) { _, _ in second.fulfill() }
        scheduler.cancel(a)
        scheduler.cancel(a)
        scheduler.cancel(UUID())
        probe.release("B")
        await fulfillment(of: [second], timeout: 3)
        XCTAssertEqual(probe.startedNames, ["A", "B"])
    }

    @MainActor
    func testSchedulerDeinitReleasesCallbacksAndNeverPromotesPending() async {
        let barrier = WallpaperCompletionBarrier()
        var scheduler: DesktopBackgroundDecodeScheduler? = DesktopBackgroundDecodeScheduler(
            enqueueCompletion: { barrier.enqueue($0) })
        weak var weakScheduler = scheduler
        let probe = BlockingWallpaperDecoder(["A", "C"])
        defer { probe.releaseAll() }
        var owner: WallpaperDeliveries? = WallpaperDeliveries()
        weak var weakOwner = owner
        _ = scheduler!.submit(request("A"), decode: { probe.decode($0) }) { [owner] ticket, image in
            owner?.record(ticket, image: image)
            XCTFail("Destroyed scheduler delivered")
        }
        await fulfillment(of: [probe.started("A")], timeout: 3)
        _ = scheduler!.submit(request("C"), decode: { probe.decode($0) }) { [owner] ticket, image in
            owner?.record(ticket, image: image)
            XCTFail("Destroyed scheduler delivered")
        }
        owner = nil
        scheduler = nil
        XCTAssertNil(weakScheduler)
        XCTAssertNil(weakOwner)
        probe.release("A")
        await fulfillment(of: [barrier.firstProcessed], timeout: 3)
        XCTAssertEqual(probe.startedNames, ["A"])
    }

    @MainActor
    func testWeakOwnerDeinitCancelsPendingWithoutResurrectingOldActive() async {
        let barrier = WallpaperCompletionBarrier()
        let scheduler = DesktopBackgroundDecodeScheduler(enqueueCompletion: { barrier.enqueue($0) })
        let probe = BlockingWallpaperDecoder(["A", "C", "D"])
        defer { probe.releaseAll() }
        var owner: WallpaperRequestOwner? = WallpaperRequestOwner(scheduler)
        weak var weakOwner = owner
        owner!.submit(request("A"), probe: probe) { XCTFail("Owner received A callback") }
        await fulfillment(of: [probe.started("A")], timeout: 3)
        owner!.submit(request("C"), probe: probe) { XCTFail("Owner received C callback") }
        owner = nil
        XCTAssertNil(weakOwner)
        let done = expectation(description: "new owner D delivered")
        probe.release("A")
        await fulfillment(of: [barrier.firstProcessed], timeout: 3)
        _ = scheduler.submit(request("D"), decode: { probe.decode($0) }) { _, _ in done.fulfill() }
        probe.release("D")
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(probe.startedNames, ["A", "D"])
        XCTAssertEqual(probe.maximumActive, 1)
    }

    @MainActor
    func testBurstOnlyRunsFirstAndLastRequest() async {
        let scheduler = DesktopBackgroundDecodeScheduler()
        let names = (0..<64).map { "burst-\($0)" }
        let probe = BlockingWallpaperDecoder(["A"] + names)
        defer { probe.releaseAll() }
        let done = expectation(description: "latest burst delivered")
        _ = scheduler.submit(request("A"), decode: { probe.decode($0) }) { _, _ in XCTFail("A delivered") }
        await fulfillment(of: [probe.started("A")], timeout: 3)
        for name in names.dropLast() {
            _ = scheduler.submit(request(name), decode: { probe.decode($0) }) { _, _ in XCTFail("intermediate delivered") }
        }
        let last = names.last!
        _ = scheduler.submit(request(last), decode: { probe.decode($0) }) { _, _ in done.fulfill() }
        probe.release("A")
        await fulfillment(of: [probe.started(last)], timeout: 3)
        XCTAssertEqual(probe.startedNames, ["A", last])
        probe.release(last)
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(probe.maximumActive, 1)
    }
}

import CoreGraphics
import Foundation

/// WALLPAPER-LATEST-ONLY-01: one physical decode, one replaceable pending request.
/// Callers submit synchronously on MainActor; only promotion creates work.
@MainActor
public final class DesktopBackgroundDecodeScheduler {
    public static let shared = DesktopBackgroundDecodeScheduler()

    public struct Request: Sendable {
        public let url: URL
        public let maximumPixelSize: Int
        public let appearanceIdentity: String

        public init(url: URL, maximumPixelSize: Int, appearanceIdentity: String) {
            self.url = url
            self.maximumPixelSize = maximumPixelSize
            self.appearanceIdentity = appearanceIdentity
        }
    }

    public typealias Decoder = @Sendable (Request) -> CGImage?
    public typealias Completion = @MainActor @Sendable (UUID, CGImage?) -> Void

    private struct Job {
        let ticket: UUID
        let request: Request
        let decode: Decoder
        let completion: Completion
    }

    private struct Active {
        let ticket: UUID
        var completion: Completion?
    }

    typealias Finish = @MainActor @Sendable () -> Void
    typealias CompletionEnqueuer = @Sendable (@escaping Finish) -> Void

    private let enqueueCompletion: CompletionEnqueuer
    private let queue: OperationQueue
    private var active: Active?
    private var pending: Job?

    public convenience init() {
        self.init(enqueueCompletion: { finish in
            Task { @MainActor in finish() }
        })
    }

    // Internal executor dependency lets tests acknowledge the real finish closure
    // after it returns, without exposing scheduling state or a public drain API.
    init(enqueueCompletion: @escaping CompletionEnqueuer) {
        self.enqueueCompletion = enqueueCompletion
        queue = OperationQueue()
        queue.name = "LaunchIcon.WallpaperDecoding"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
    }

    /// Superseded requests never deliver, including a superseded nil result.
    @discardableResult
    public func submit(_ request: Request, decode: @escaping Decoder,
                       completion: @escaping Completion) -> UUID {
        let job = Job(ticket: UUID(), request: request, decode: decode, completion: completion)
        if active != nil {
            active?.completion = nil
            pending = job
        } else {
            start(job)
        }
        return job.ticket
    }

    /// Cancellation revokes delivery, not a synchronous decoder already in flight.
    /// Keep the busy slot until finish; cancelling pending must not revive active.
    public func cancel(_ ticket: UUID) {
        if pending?.ticket == ticket {
            pending = nil
        } else if active?.ticket == ticket {
            active?.completion = nil
        }
    }

    private func start(_ job: Job) {
        precondition(active == nil)
        active = Active(ticket: job.ticket, completion: job.completion)
        // Do not capture Job: its UI completion belongs only to the coordinator.
        // A worker must not retain the coordinator or prevent pending from releasing.
        let ticket = job.ticket
        let request = job.request
        let decode = job.decode
        let enqueueCompletion = self.enqueueCompletion
        queue.addOperation { [weak self] in
            let image = decode(request)
            enqueueCompletion { [weak self] in
                self?.finish(ticket, image: image)
            }
        }
    }

    private func finish(_ ticket: UUID, image: CGImage?) {
        guard let completed = active, completed.ticket == ticket else { return }
        active = nil
        if let next = pending {
            pending = nil
            start(next)
        } else {
            // State is idle before a callback may synchronously submit a retry.
            completed.completion?(ticket, image)
        }
    }
}

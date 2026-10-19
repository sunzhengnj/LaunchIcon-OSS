import AppKit
import LaunchIconCore

/// Polls `NSEvent.mouseLocation` (no Accessibility permission) and edge-fires
/// when the pointer enters the configured screen corner. Same corner as a
/// system Mission Control hot corner may trigger both; see Settings help.
/// Main-thread only (wired from DirectAppDelegate `@MainActor` paths). Not
/// `@MainActor`-isolated as a type so it can be stored on the app delegate.
final class HotCornerMonitor: @unchecked Sendable {
    private var timer: Timer?
    private var configured: LauncherHotCorner = .off
    private var previousHit: LauncherHotCorner?
    private var onTriggered: (() -> Void)?

    /// Poll interval — responsive without spinning the CPU.
    private static let pollInterval: TimeInterval = 0.05

    func update(corner: LauncherHotCorner, onTriggered: @escaping () -> Void) {
        self.onTriggered = onTriggered
        guard corner.isEnabled else {
            stop()
            return
        }
        if timer != nil, configured == corner {
            return
        }
        configured = corner
        // Seed so an already-parked cursor does not fire until leave + re-enter.
        previousHit = currentHit()
        startTimerIfNeeded()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        configured = .off
        previousHit = nil
        onTriggered = nil
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        timer.tolerance = Self.pollInterval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard configured.isEnabled else { return }
        let hit = currentHit()
        let shouldFire = LauncherLayout.shouldFireHotCorner(
            configured: configured,
            previousHit: previousHit,
            currentHit: hit
        )
        previousHit = hit
        guard shouldFire else { return }
        onTriggered?()
    }

    private func currentHit() -> LauncherHotCorner? {
        let point = NSEvent.mouseLocation
        let frames = NSScreen.screens.map(\.frame)
        return LauncherLayout.hotCorner(at: point, screenFrames: frames)
    }
}

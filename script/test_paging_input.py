#!/usr/bin/env python3
"""Exercise production paging input with controlled phases and axes.

The event shim supplies phases without posting input or opening a window.
Discrete wheel decisions are outside this precise-scroll regression.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/Direct/LauncherWindowController.swift').read_text()
layout = (root / 'Sources/Core/LauncherLayout.swift').read_text()


def extract(text: str, signature: str) -> str:
    start = text.index(signature)
    end = text.index('\n    }', start) + len('\n    }')
    return text[start:end].replace('private func', 'func', 1)


handle = extract(source, '    func handlePagingScroll(').replace('NSEvent', 'PageScrollEvent')
dominant = extract(source, '    static func dominantScrollDelta(').replace('NSEvent', 'PageScrollEvent')
methods = [extract(source, f'    private func {name}(') for name in
           ('beginGesture', 'updateGesture', 'finishGesture', 'resetGesture')]
turn = extract(layout, '    public static func shouldTurnPage(').replace('public static', 'static', 1)
swift = '''import AppKit

enum ScrollPhase { case none, began, changed, ended, cancelled
    var isEmpty: Bool { self == .none }
}
struct PageScrollEvent {
    let scrollingDeltaX: CGFloat
    let scrollingDeltaY: CGFloat
    let timestamp: TimeInterval
    let phase: ScrollPhase
    let momentumPhase: ScrollPhase = .none
    let hasPreciseScrollingDeltas = true
    var deltaX: CGFloat { scrollingDeltaX }
    var deltaY: CGFloat { scrollingDeltaY }
}
enum LauncherLayout {
    static let pageTurnDistanceFraction: CGFloat = 0.18
    static let pageAnimationDuration: TimeInterval = 0.28
    static func shouldAcceptPagingGesture(isDismissing: Bool) -> Bool { !isDismissing }
    static func discreteScrollTurn(accumulatedDelta: CGFloat, incomingDelta: CGFloat,
        now: TimeInterval, lastScroll: TimeInterval?, lastTurn: TimeInterval,
        quietPeriod: TimeInterval) -> (accumulatedDelta: CGFloat, direction: Int?, holdDelay: TimeInterval?) {
        (0, nil, nil)
    }
''' + turn + '''
}
@MainActor final class PagingHarness {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
    var isDismissing: () -> Bool = { false }
    var accumulatedDelta: CGFloat = 0
    var lastTimestamp: TimeInterval?
    var lastVelocity: CGFloat = 0
    var preciseScrollUsesHorizontalAxis: Bool?
    var accumulatedDiscreteDelta: CGFloat = 0
    var lastDiscreteScrollTimestamp: TimeInterval?
    var lastDiscretePageTurnTimestamp: TimeInterval = -.infinity
    var heldDiscreteToken = 0
    var dragChangedHandler: ((CGFloat) -> Void)?
    var dragEndedHandler: ((Int?) -> Void)?
''' + dominant + '''
    func cancelPagingInput() {}
    func deliverDiscretePageTurn(_ direction: Int, at timestamp: TimeInterval) {}
''' + handle + '\n' + '\n'.join(methods) + '''
}
@MainActor func check(_ ok: Bool, _ name: String) -> Bool {
    print("\\(ok ? "PASS" : "FAIL"): \\(name)")
    return ok
}
var passed = true
let ended = PagingHarness()
var endedDirections: [Int?] = []
ended.dragEndedHandler = { endedDirections.append($0) }
ended.handlePagingScroll(PageScrollEvent(scrollingDeltaX: -240, scrollingDeltaY: 0, timestamp: 10, phase: .changed))
ended.handlePagingScroll(PageScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 0, timestamp: 10.1, phase: .ended))
passed = check(endedDirections.count == 1 && endedDirections[0] == 1 && ended.lastTimestamp == nil,
    "zero-delta ended event commits a dragged page") && passed
let cancelled = PagingHarness()
var cancelledDirections: [Int?] = []
cancelled.dragEndedHandler = { cancelledDirections.append($0) }
cancelled.handlePagingScroll(PageScrollEvent(scrollingDeltaX: -20, scrollingDeltaY: 0, timestamp: 20, phase: .changed))
cancelled.handlePagingScroll(PageScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 0, timestamp: 20.1, phase: .cancelled))
passed = check(cancelledDirections.count == 1 && cancelledDirections[0] == nil && cancelled.lastTimestamp == nil,
    "zero-delta cancelled event settles a short drag") && passed
let nonzero = PagingHarness()
var nonzeroDirections: [Int?] = []
nonzero.dragEndedHandler = { nonzeroDirections.append($0) }
nonzero.handlePagingScroll(PageScrollEvent(scrollingDeltaX: -240, scrollingDeltaY: 0, timestamp: 30, phase: .ended))
passed = check(nonzeroDirections.count == 1 && nonzeroDirections[0] == 1 && nonzero.lastTimestamp == nil,
    "nonzero ended event still commits normally") && passed
let idle = PagingHarness()
var idleEndCount = 0
idle.dragEndedHandler = { _ in idleEndCount += 1 }
idle.handlePagingScroll(PageScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 0, timestamp: 40, phase: .began))
idle.handlePagingScroll(PageScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 0, timestamp: 40.1, phase: .ended))
passed = check(idleEndCount == 0 && idle.lastTimestamp == nil,
    "zero-delta begin and end do not invent a page gesture") && passed
let diagonal = PagingHarness()
var diagonalOffsets: [CGFloat] = []
diagonal.dragChangedHandler = { diagonalOffsets.append($0) }
diagonal.handlePagingScroll(PageScrollEvent(scrollingDeltaX: -12, scrollingDeltaY: 11,
    timestamp: 50, phase: .began))
diagonal.handlePagingScroll(PageScrollEvent(scrollingDeltaX: -11, scrollingDeltaY: 12,
    timestamp: 50.01, phase: .changed))
passed = check(diagonalOffsets.count == 2 && diagonalOffsets[0] == -12
    && diagonalOffsets[1] == -23,
    "diagonal finger drag keeps its initial axis instead of reversing the page") && passed
diagonal.handlePagingScroll(PageScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 0,
    timestamp: 50.02, phase: .ended))
diagonal.handlePagingScroll(PageScrollEvent(scrollingDeltaX: 2, scrollingDeltaY: -30,
    timestamp: 51, phase: .began))
passed = check(diagonalOffsets.last == -30,
    "a new gesture can choose the vertical axis after a horizontal one") && passed
exit(passed ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix='LaunchIcon-PagingInput-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(path / 'main.swift'),
                    '-o', str(path / 'probe')], check=True)
    sys.exit(subprocess.run([str(path / 'probe')], check=False).returncode)

#!/usr/bin/env python3
"""Execute production page animation and queue methods without a window.

Checks coordinates against real AppKit anchors, one easing clock, and queued
page-dot ordering. This does not claim rendered frame-rate/UI validation.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'Sources/Direct/LauncherWindowController.swift').read_text()
start = source.index('    private func animateViewFrameFromPresentation(')
end = source.index('\n    }', start) + len('\n    }')
fade_start = source.index('    private func fadeViewOpacityFromPresentation(')
fade_end = source.index('\n    }', fade_start) + len('\n    }')
fade = source[fade_start:fade_end].replace('private func', 'func', 1)
method = source[start:end].replace('private func', 'func', 1)
transition_start = source.index('    private func transitionToPage(')
transition_end = source.index('\n    }', transition_start) + len('\n    }')
transition = source[transition_start:transition_end].replace('private func', 'func', 1)
show_start = source.index('    private func showPage(')
show_end = source.index('\n    }', show_start) + len('\n    }')
show = source[show_start:show_end].replace('private func', 'func', 1)
complete_start = source.index('    private func completePageTransition(')
complete_end = source.index('\n    }', complete_start) + len('\n    }')
complete = source[complete_start:complete_end].replace('private func', 'func', 1)
run_queued_start = source.index('    private func runQueuedPage()')
run_queued_end = source.index('\n    }', run_queued_start) + len('\n    }')
run_queued = source[run_queued_start:run_queued_end].replace('private func', 'func', 1)
unpark_start = source.index('    func unpark()')
unpark_end = source.index('\n    }', unpark_start) + len('\n    }')
unpark = source[unpark_start:unpark_end]
swift = '''import AppKit
import QuartzCore
enum LauncherLayout {
    static func pagingControlPage(currentPage: Int, inFlightPage: Int?, queuedPage: Int?) -> Int {
        queuedPage ?? inFlightPage ?? currentPage
    }
}
@MainActor final class Harness {
''' + fade + '\n' + method + '''
}
@MainActor final class AppGridTileView: NSView {}
@MainActor final class QueueIndicator {
    var selectedPage = 0
    var activeAnimationTarget: Int?
    // Mirrors the real indicator's configure side effect: it stops the clock.
    func configure(pageCount: Int, selectedPage: Int) {
        self.selectedPage = selectedPage
        activeAnimationTarget = nil
    }
}
@MainActor final class TransitionHarness {
    var transitionTargetPage: Int?
    var pageTurnGridSlot: Int?
    var pageTurnFocusedTile: AppGridTileView?
    var activeHost = NSView()
    var stagingHost = NSView()
    var stagingPage: Int?
    var openedFolderID: Int?
    var isSearching = false
    var pageCount = 3
    var currentPage = 0
    var queuedPage: Int?
    let pageIndicator = QueueIndicator()
    let window: NSWindow? = nil
    let activeCollectionView = 0
    let gridViewport = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    var isPagingGesture = false
    var isPageTransitioning = false
    var positions: [(CGFloat, CGFloat?, CGFloat, CGFloat?, Bool, Bool)] = []
    func focusedGridSlot(in index: Int) -> Int? { nil }
    func prepareStagingPage(_ page: Int) {}
    func updatePagingControls() {}
    func discardInProgressPageGestures() {}
    func layoutCollectionViews() {}
    func updateGridAccessibilityChildren(for collectionView: Int) {}
    func rebuildKeyViewLoop() {}
    func pageTurnStillOwnsFocus() -> Bool { false }
    func focusLeftOnDepartingPage() -> Bool { false }
    func applyGridFocusAfterPageTurn(from slot: Int) {}
    func moveFocusOffDepartedGridTile() {}
    func pageTravelDistance(for width: CGFloat, discrete: Bool) -> CGFloat { width }
    func positionPages(activeX: CGFloat, stagingX: CGFloat?, activeAlpha: CGFloat = 1,
                       stagingAlpha: CGFloat? = nil, animated: Bool = false,
                       finishPage: Int? = nil, discreteSlide: Bool = false,
                       stagingStartsFromModel: Bool = false) {
        positions.append((activeX, stagingX, activeAlpha, stagingAlpha, animated, stagingStartsFromModel))
        if animated { pageIndicator.activeAnimationTarget = finishPage }
    }
''' + transition + '''
''' + show + '''
''' + complete + '''
''' + run_queued + '''
}
@MainActor final class ParkedHost: NSView {
''' + unpark + '''
}
var failures = 0
@MainActor func check(_ ok: Bool, _ name: String) {
    print("\\(ok ? "PASS" : "FAIL"): \\(name)")
    if !ok { failures += 1 }
}
let parent = NSView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
parent.wantsLayer = true
for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5)] {
    let host = NSScrollView(frame: NSRect(x: 180, y: 24, width: 800, height: 500))
    host.wantsLayer = true
    parent.addSubview(host)
    let layer = host.layer!
    layer.anchorPoint = anchor
    let fromPosition = layer.position
    let destination = host.frame.offsetBy(dx: -280, dy: 0)
    let timing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    Harness().animateViewFrameFromPresentation(host, to: destination, duration: 0.28,
                                               timingFunction: timing, key: "probe")
    CATransaction.commit()
    let group = layer.animation(forKey: "probe") as! CAAnimationGroup
    let position = group.animations!.first as! CABasicAnimation
    check((position.fromValue as! NSValue).pointValue == fromPosition,
          "slide starts at actual layer position anchor=\\(anchor)")
    check((position.toValue as! NSValue).pointValue == layer.position,
          "slide arrives at model position anchor=\\(anchor)")
    check(group.animations!.allSatisfy { $0.timingFunction == nil },
          "position and size share only the group easing clock anchor=\\(anchor)")
    host.removeFromSuperview()
}
let parked = ParkedHost()
parked.alphaValue = 0.3
parked.isHidden = true
parked.unpark()
check(!parked.isHidden && abs(parked.alphaValue - 0.3) < 0.001,
      "unparking preserves in-flight opacity instead of flashing fully opaque")
for direction in [-1, 1] {
    let transition = TransitionHarness()
    transition.transitionToPage(1, direction: direction, discrete: true)
    check(transition.positions.count == 2 && transition.positions.first!.0 == 0
          && transition.positions.first!.1 == CGFloat(direction) * 800
          && transition.positions.first!.3 == 1 && !transition.positions.first!.4 && transition.positions.last!.5,
          "discrete incoming page starts opaque on correct side direction=\\(direction)")
    check(transition.positions.last!.2 == 1 && transition.positions.last!.3 == 1,
          "both adjacent hosts stay opaque during page slide direction=\\(direction)")
}
let drag = TransitionHarness()
drag.isPagingGesture = true
drag.transitionToPage(1, direction: 1, discrete: false)
check(drag.positions.count == 1 && drag.positions[0].4 && !drag.positions[0].5,
      "releasing finger preserves current drag position")
let queued = TransitionHarness()
queued.showPage(1)
queued.showPage(2)
check(queued.queuedPage == 2 && queued.pageIndicator.activeAnimationTarget == 1
      && queued.pageIndicator.selectedPage == 0,
      "queued turn does not jump or cancel the dot animation for the page still sliding")
queued.completePageTransition(to: 1)
check(queued.pageIndicator.selectedPage == 1 && queued.pageIndicator.activeAnimationTarget == 2,
      "first page lands its own dot before the queued page begins animating")
final class StaleLayer: CALayer {
    var snapshot: StaleLayer?
    override func presentation() -> Self? { snapshot as? Self }
}
let seeded = NSView(frame: NSRect(x: -288, y: 0, width: 800, height: 500))
let stale = StaleLayer()
let old = StaleLayer()
stale.snapshot = old
seeded.layer = stale
seeded.wantsLayer = true
old.position = CGPoint(x: 800, y: 0)
old.opacity = 1
stale.opacity = 0
let seededPosition = stale.position
for usePresentation in [false, true] {
    seeded.frame = NSRect(x: -288, y: 0, width: 800, height: 500)
    stale.opacity = 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    Harness().animateViewFrameFromPresentation(seeded, to: NSRect(x: 0, y: 0, width: 800, height: 500),
        duration: 0.28, timingFunction: CAMediaTimingFunction(name: .easeOut), key: "stale",
        fromPresentation: usePresentation)
    Harness().fadeViewOpacityFromPresentation(seeded, to: 1, duration: 0.28,
        timingFunction: CAMediaTimingFunction(name: .easeOut), key: "fade", fromPresentation: usePresentation)
    CATransaction.commit()
    let animation = stale.animation(forKey: "stale") as! CAAnimationGroup
    let position = animation.animations!.first as! CABasicAnimation
    let opacity = stale.animation(forKey: "fade") as! CABasicAnimation
    check((position.fromValue as! NSValue).pointValue == (usePresentation ? old.position : seededPosition),
          "seed uses model while continuation uses presentation: \\(usePresentation)")
    check((opacity.fromValue as! NSNumber).floatValue == (usePresentation ? 1 : 0),
          "seed keeps transparent model instead of stale presentation: \\(usePresentation)")
}
exit(failures == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix='LaunchIcon-PageGeometry-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(path / 'main.swift'), '-o', str(path / 'probe')], check=True)
    sys.exit(subprocess.run([str(path / 'probe')], check=False).returncode)

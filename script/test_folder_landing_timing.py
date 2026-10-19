#!/usr/bin/env python3
"""Check real QuartzCore landing durations without opening an app or window.

Extract the production animation builder and token/cleanup methods; stub view
lookup and record the cleanup deadline. Exercise production main-queue callbacks
and token/hold cleanup with the real Core policies. This checks animation construction and interruption contracts, not
rendered motion quality.
An optional source path allows checking the previous implementation.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "Sources/Direct/LauncherWindowController.swift"
source = source_path.read_text()
start=source.index('    private func playFolderLandingAnimation(')
end=source.index('\n    /// Remember this tile', start)
method=source[start:end].replace('    private func playFolderLandingAnimation(', '    func playFolderLandingAnimation(', 1)
tracking_start = source.index('    private func beginTrackedFolderLanding(')
tracking_end = source.index('    private func finishFolderLandingLater(', tracking_start)
cleanup_start = source.index('    private func finishFolderLandingIfAllowed(')
# Drop-landing flights sit next. They are not part of the folder spring.
cleanup_end = source.index('    private func beginPendingDropLanding(', cleanup_start)
timer_end = source.index('    /// Final opacity', tracking_end)
timer_method = source[tracking_end:timer_end].replace(
    'private func finishFolderLandingLater(', 'private func performScheduledCleanup(', 1)
methods = method + source[tracking_start:tracking_end] + timer_method + source[cleanup_start:cleanup_end]
header='''import Foundation
import QuartzCore
final class TestView { var wantsLayer = true; var layer: CALayer? = CALayer() }
struct TestItem { let view = TestView() }
struct TestWindow { var isVisible = true }
@MainActor final class Harness {
    let item = TestItem()
    var prefersReducedMotion = false
    var folderLandingGeneration = 0
    struct HeldFolderLanding { weak var layer: CALayer?; var generation: Int }
    var heldFolderLandings: [HeldFolderLanding] = []
    var folderLandingWaitsForLauncher = false
    var isDismissing = false
    var window: TestWindow? = TestWindow()
    var onDiagnosticEvent: ((String) -> Void)?
    var deadlines: [Double] = []
    func materializedFolderItem(_ id: UUID) -> TestItem? { item }
    func launcherIsDismissing() -> Bool { isDismissing }
    func commitFolderLandingVisual(on layer: CALayer) {
        layer.removeAnimation(forKey: "folder-created-opacity")
        layer.removeAnimation(forKey: "folder-created")
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
    }
    func finish(_ generation: Int) { finishFolderLandingIfAllowed(on: item.view.layer!, generation: generation) }
    func finishFolderLandingLater(on layer: CALayer, generation: Int, after delay: Double) {
        deadlines.append(delay)
        performScheduledCleanup(on: layer, generation: generation, after: delay)
    }
'''
footer='''
}
var failures = 0
for delay in [0.204, 0.0] {
    let harness = Harness()
    harness.playFolderLandingAnimation(UUID(), after: delay)
    let spring = harness.item.view.layer!.animation(forKey: "folder-created")!
    let fade = harness.item.view.layer!.animation(forKey: "folder-created-opacity")
    let lastEnd = delay + max(spring.duration, fade?.duration ?? 0)
    let cleanup = harness.deadlines.last!
    if harness.deadlines.count != 1 || cleanup < lastEnd - 0.000001 {
        print("FAIL: delay=\\(delay), cleanup=\\(cleanup), lastAnimationEnd=\\(lastEnd)")
        failures += 1
    } else { print("PASS: delay=\\(delay), cleanup=\\(cleanup), lastAnimationEnd=\\(lastEnd)") }
    if spring.fillMode != .backwards || !CATransform3DIsIdentity(harness.item.view.layer!.transform) {
        print("FAIL: spring fill delay=\\(delay) fill=\\(spring.fillMode.rawValue)")
        failures += 1
    } else { print("PASS: spring holds 0.86 until attached delay=\\(delay)") }
}
let reduced = Harness()
reduced.prefersReducedMotion = true
reduced.playFolderLandingAnimation(UUID(), after: 0.204)
let reducedFade = reduced.item.view.layer!.animation(forKey: "folder-created")
if !reduced.deadlines.isEmpty
    || reducedFade != nil
    || reduced.item.view.layer!.opacity != 1
    || !CATransform3DIsIdentity(reduced.item.view.layer!.transform) {
    print("FAIL: reduced motion still half-fades deadlines=\(reduced.deadlines) fade=\(reducedFade != nil) opacity=\(reduced.item.view.layer!.opacity)")
    failures += 1
} else { print("PASS: reduced motion snaps new folder without half-fade") }

let dissolve = Harness()
dissolve.playFolderLandingAnimation(UUID(), after: 0.22, dissolveFadeDuration: 0.34)
let dissolveFade = dissolve.item.view.layer!.animation(forKey: "folder-created-opacity") as? CAKeyframeAnimation
let dissolveValues = (dissolveFade?.values as? [NSNumber]) ?? []
let dissolveScale = dissolve.item.view.layer!.animation(forKey: "folder-created") as? CAKeyframeAnimation
let scaleValues = (dissolveScale?.values as? [NSNumber]) ?? []
let cleanup = dissolve.deadlines.last ?? -1
let sixty = dissolveValues.isEmpty ? -1 : Int((0.6 * Double(dissolveValues.count - 1)).rounded())
let first = dissolveValues.first?.doubleValue ?? -1
let last = dissolveValues.last?.doubleValue ?? -1
let atSixty = (sixty >= 0 && sixty < dissolveValues.count) ? dissolveValues[sixty].doubleValue : -1
let scaleStart = Double(LauncherLayout.wholeCellMergeFolderScaleStart)
let scaleFirst = scaleValues.first?.doubleValue ?? -1
let scaleLast = scaleValues.last?.doubleValue ?? -1
let scaleAtSixty = (sixty >= 0 && sixty < scaleValues.count) ? scaleValues[sixty].doubleValue : -1
if dissolveFade?.duration != 0.34
    || first != 0
    || abs(last - 1) > 0.001
    || atSixty != 0
    || dissolve.item.view.layer!.animation(forKey: "folder-created") is CASpringAnimation
    || dissolveScale?.duration != 0.34
    || abs(scaleFirst - scaleStart) > 0.001
    || abs(scaleAtSixty - scaleStart) > 0.001
    || abs(scaleLast - 1) > 0.001
    || abs(cleanup - 0.34) > 0.000001 {
    print("FAIL: whole-cell scale first=\\(scaleFirst) sixty=\\(scaleAtSixty) last=\\(scaleLast) cleanup=\\(cleanup)")
    failures += 1
} else {
    print("PASS: whole-cell folder scale lands with the fade and ignores the extra delay")
}
@MainActor func check(_ condition: Bool, _ label: String) {
    print("\\(condition ? "PASS" : "FAIL"): \\(label)")
    if !condition { failures += 1 }
}
let held = Harness()
held.playFolderLandingAnimation(UUID(), after: 0.204)
let heldLayer = held.item.view.layer!
let heldToken = heldLayer.value(forKey: "folderLandingToken") as! Int
held.isDismissing = true
heldLayer.opacity = 0.4
heldLayer.transform = CATransform3DMakeScale(0.94, 0.94, 1)
held.finish(heldToken)
check(heldLayer.animationKeys()?.isEmpty != false && heldLayer.opacity == 0.4
      && abs(heldLayer.transform.m11 - 0.94) < 0.000001
      && held.folderLandingWaitsForLauncher && held.heldFolderLandings.count == 1
      && heldLayer.value(forKey: "folderLandingToken") as? Int == heldToken,
      "visible dismissal pins model fallback and retains token")
held.isDismissing = false
held.finish(heldToken)
check(heldLayer.opacity == 1 && CATransform3DIsIdentity(heldLayer.transform)
      && heldLayer.value(forKey: "folderLandingToken") == nil
      && !held.folderLandingWaitsForLauncher && held.heldFolderLandings.isEmpty,
      "resume commits held landing and removes tracking")
let hidden = Harness()
hidden.playFolderLandingAnimation(UUID(), after: 0.204)
hidden.window?.isVisible = false
hidden.isDismissing = true
hidden.finish(hidden.folderLandingGeneration)
check(hidden.item.view.layer!.opacity == 1
      && hidden.item.view.layer!.animationKeys()?.isEmpty != false
      && hidden.heldFolderLandings.isEmpty && !hidden.folderLandingWaitsForLauncher,
      "hidden launcher commits without leaving a held landing")
let stale = Harness()
stale.playFolderLandingAnimation(UUID(), after: 0.204)
let oldToken = stale.folderLandingGeneration
stale.playFolderLandingAnimation(UUID(), after: 0.204)
let newToken = stale.folderLandingGeneration
stale.finish(oldToken)
check(stale.item.view.layer!.value(forKey: "folderLandingToken") as? Int == newToken
      && stale.item.view.layer!.animation(forKey: "folder-created") != nil
      && stale.heldFolderLandings.count == 1,
      "old completion leaves replacement animation and token intact")
stale.finish(newToken)
check(stale.item.view.layer!.value(forKey: "folderLandingToken") == nil
      && stale.heldFolderLandings.isEmpty,
      "replacement completion clears its own token")
let live = Harness()
live.playFolderLandingAnimation(UUID(), after: 0.204)
let pinned = Harness()
pinned.playFolderLandingAnimation(UUID(), after: 0.204)
pinned.isDismissing = true
let replacement = Harness()
replacement.playFolderLandingAnimation(UUID(), after: 0.204)
replacement.playFolderLandingAnimation(UUID(), after: 0.6)
let replacementToken = replacement.folderLandingGeneration
RunLoop.main.run(until: Date().addingTimeInterval(0.55))
check(live.item.view.layer!.value(forKey: "folderLandingToken") != nil,
      "main-queue cleanup does not end delayed landing at fade deadline")
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
check(live.item.view.layer!.value(forKey: "folderLandingToken") == nil
      && live.item.view.layer!.opacity == 1 && live.heldFolderLandings.isEmpty,
      "main-queue completion commits final state")
check(pinned.folderLandingWaitsForLauncher && pinned.heldFolderLandings.count == 1
      && pinned.item.view.layer!.value(forKey: "folderLandingToken") != nil,
      "main-queue completion holds while dismissal remains visible")
check(replacement.item.view.layer!.value(forKey: "folderLandingToken") as? Int == replacementToken
      && replacement.heldFolderLandings.count == 1,
      "replacement remains pending after old completion deadline")
RunLoop.main.run(until: Date().addingTimeInterval(0.35))
check(replacement.item.view.layer!.value(forKey: "folderLandingToken") == nil
      && replacement.heldFolderLandings.isEmpty,
      "scheduled replacement completion clears its own landing")
exit(failures == 0 ? 0 : 1)
'''
def plate_model_shares_the_fade_transaction(text: str) -> str | None:
    """The open plate is the model. Opacity and scale must be attached
    before that model is committed, or the full plate flashes first."""
    start = text.index("    private func playMergePreviewLanding(")
    end = text.index("    private func playIncomingFolderPreviewLanding(", start)
    body = text[start:end]
    add_fade = body.index('layer.add(fade, forKey: "folder-merge-plate")')
    add_scale = body.index('layer.add(grow, forKey: "folder-merge-plate-scale")')
    opacity = body.rindex("layer.opacity = 1", 0, add_fade)
    transform = body.rindex("layer.transform = CATransform3DIdentity", 0, add_fade)
    begin = body.rindex("CATransaction.begin()", 0, min(opacity, transform))
    commit = body.index("CATransaction.commit()", add_scale)
    if "CATransaction.commit()" in body[begin:add_scale]:
        return "plate model commits before the scale animation is attached"
    if not (begin < opacity < add_fade and begin < transform < add_fade and add_scale < commit):
        return "plate opacity, fade, and scale are not one transaction"
    if "item.view.layer?.opacity = 1" in body:
        return "plate opacity is still written before the fade transaction"
    return None

def shadow_model_shares_the_fade_transaction(text: str) -> str | None:
    """The lift shadow ends at 0. That model write has to share the fade
    transaction, or the commit frame drops the shadow."""
    start = text.index("    private func fadeLiftShadow(")
    end = text.index("    private func topLevelSourceIndex(", start)
    body = text[start:end]
    add = body.index('layer.add(fade, forKey: "lift-shadow")')
    opacity = body.rindex("layer.shadowOpacity = 0", 0, add)
    begin = body.rindex("CATransaction.begin()", 0, opacity)
    commit = body.index("CATransaction.commit()", add)
    if "CATransaction.commit()" in body[begin:add]:
        return "lift shadow commits before the fade is attached"
    if not (begin < opacity < add < commit):
        return "lift shadow model and fade are not one transaction"
    return None

plate_problem = plate_model_shares_the_fade_transaction(source)
if plate_problem:
    print("FAIL:", plate_problem)
    sys.exit(1)
print("PASS: merge plate model shares the fade transaction")
def reduced_merge_fade_shares_the_transaction(text: str) -> str | None:
    """Reduced-motion merge flyer snaps off (no 0.12s half-fade)."""
    start = text.index("    private func playMergeAnimation(")
    end = text.index("    private func materializedFolderItem(", start)
    body = text[start:end]
    branch = body.index("if prefersReducedMotion {")
    reduced = body[branch:body.index("\n            return\n", branch)]
    if "animator().alphaValue" in reduced:
        return "reduced merge still writes opacity through animator()"
    if 'add(fade, forKey: "merge-reduced-fade")' in reduced:
        return "reduced merge must not add merge-reduced-fade half-fade"
    if "duration = 0.12" in reduced:
        return "reduced merge must not keep 0.12s half-fade duration"
    if "shouldSnapMergeFlyerForReducedMotion" not in reduced:
        return "reduced merge must consult Core snap gate"
    if "mergeReducedFadeDuration" not in reduced:
        return "reduced merge must consult Core duration policy"
    if "opacity = 0" not in reduced:
        return "reduced merge snap must park opacity 0"
    if "finishFlightOnLandingTurn" not in reduced:
        return "reduced merge snap must finishFlightOnLandingTurn remove"
    return None

shadow_problem = shadow_model_shares_the_fade_transaction(source)
if shadow_problem:
    print("FAIL:", shadow_problem)
    sys.exit(1)
print("PASS: lift shadow model shares the fade transaction")
def whole_cell_merge_fade_shares_the_transaction(text: str) -> str | None:
    """The flying icon ends at opacity 0. That model write has to share the
    late-dissolve fade, or the commit frame hides the icon in the air."""
    start = text.index("    private func playMergeAnimation(")
    end = text.index("    private func materializedFolderItem(", start)
    body = text[start:end]
    branch = body.index("if prefersReducedMotion {")
    after = body.index("\n            return\n", branch)
    flight = body[after:]
    if "animator().alphaValue" in flight:
        return "whole-cell merge fade still writes opacity through animator()"
    add = flight.index('layer?.add(fade, forKey: "merge-flight-fade")')
    opacity = flight.rindex("layer?.opacity = 0", 0, add)
    begin = flight.rindex("CATransaction.begin()", 0, opacity)
    commit = flight.index("CATransaction.commit()", add)
    if "CATransaction.commit()" in flight[begin:add]:
        return "whole-cell merge fade commits before the fade is attached"
    if "fillMode = .backwards" not in flight[:add]:
        return "whole-cell merge fade does not hold the opacity on screen"
    if "presentation()?.opacity" not in flight[:add]:
        return "whole-cell merge fade does not start from the opacity on screen"
    if "wholeCellMergeFadeTiming()" not in flight[:add]:
        return "whole-cell merge fade dropped the late dissolve"
    if "mergeFlightDuration" not in flight[begin:add] and "fade.duration = mergeFlightDuration" not in flight[:add]:
        return "whole-cell merge fade duration changed"
    if not (begin < opacity < add < commit):
        return "whole-cell merge fade model and fade are not one transaction"
    return None

reduced_merge_problem = reduced_merge_fade_shares_the_transaction(source)
if reduced_merge_problem:
    print("FAIL:", reduced_merge_problem)
    sys.exit(1)
print("PASS: reduced merge flyer snaps (no half-fade)")
def center_merge_fade_shares_the_transaction(text: str) -> str | None:
    """An icon shrinking into a full plate ends at opacity 0. That model
    write has to share the late-dissolve fade, or the commit frame hides it."""
    start = text.index("    private func playIncomingFolderPreviewCenterLanding(")
    end = text.index("    private func pinMergePreviewFlyers(", start)
    body = text[start:end]
    if "animator().alphaValue" in body:
        return "center merge fade still writes opacity through animator()"
    add = body.index('layer?.add(fade, forKey: "merge-center-fade")')
    opacity = body.rindex("layer?.opacity = 0", 0, add)
    begin = body.rindex("CATransaction.begin()", 0, opacity)
    commit = body.index("CATransaction.commit()", add)
    if "CATransaction.commit()" in body[begin:add]:
        return "center merge fade commits before the fade is attached"
    if "fillMode = .backwards" not in body[:add]:
        return "center merge fade does not hold the opacity on screen"
    if "presentation()?.opacity" not in body[:add]:
        return "center merge fade does not start from the opacity on screen"
    if "wholeCellMergeFadeTiming()" not in body[:add]:
        return "center merge fade dropped the late dissolve"
    if "fade.duration = duration" not in body[:add]:
        return "center merge fade duration changed"
    if not (begin < opacity < add < commit):
        return "center merge fade model and fade are not one transaction"
    return None

whole_cell_problem = whole_cell_merge_fade_shares_the_transaction(source)
if whole_cell_problem:
    print("FAIL:", whole_cell_problem)
    sys.exit(1)
print("PASS: whole-cell merge fade shares the model transaction")
def glyph_sink_fade_shares_the_transaction(text: str) -> str | None:
    """Icons with no preview slot sink into the plate and end at opacity 0.
    That model write has to share the late-dissolve fade, or the commit
    frame hides them on the way in."""
    start = text.index("    private func startPreviewGlyphFlightAnimation(")
    end = text.index("    private func fadeOverflowIconsDuringPreviewFlight(", start)
    body = text[start:end]
    branch = body.index("if !fadeWithFlight {")
    sink = body[branch:]
    if "animator().alphaValue = 0" in sink:
        return "glyph sink fade still writes opacity through animator()"
    add = sink.index('layer?.add(fade, forKey: "glyph-sink-fade")')
    opacity = sink.rindex("layer?.opacity = 0", 0, add)
    begin = sink.rindex("CATransaction.begin()", 0, opacity)
    commit = sink.index("CATransaction.commit()", add)
    if "CATransaction.commit()" in sink[begin:add]:
        return "glyph sink fade commits before the fade is attached"
    if "fillMode = .backwards" not in sink[:add]:
        return "glyph sink fade does not hold the opacity on screen"
    if "presentation()?.opacity" not in sink[:add]:
        return "glyph sink fade does not start from the opacity on screen"
    if "wholeCellMergeFadeTiming()" not in sink[:add]:
        return "glyph sink fade dropped the late dissolve"
    if "fade.duration = duration" not in sink[:add]:
        return "glyph sink fade duration changed"
    if not (begin < opacity < add < commit):
        return "glyph sink fade model and fade are not one transaction"
    return None

center_problem = center_merge_fade_shares_the_transaction(source)
if center_problem:
    print("FAIL:", center_problem)
    sys.exit(1)
print("PASS: center merge fade shares the model transaction")
def glyph_rise_fade_shares_the_transaction(text: str) -> str | None:
    """Opening brings a sunk icon back and ends at opacity 1. That model
    write has to share the flight fade, or the commit frame shows it solid."""
    start = text.index("    private func startPreviewGlyphFlightAnimation(")
    end = text.index("    private func fadeOverflowIconsDuringPreviewFlight(", start)
    body = text[start:end]
    branch = body.index("if fadeWithFlight {")
    stop = body.index("if !fadeWithFlight {")
    rise = body[branch:stop]
    if "animator().alphaValue" in rise:
        return "glyph rise fade still writes opacity through animator()"
    add = rise.index('layer?.add(fade, forKey: "glyph-rise-fade")')
    opacity = rise.rindex("layer?.opacity = 1", 0, add)
    begin = rise.rindex("CATransaction.begin()", 0, opacity)
    commit = rise.index("CATransaction.commit()", add)
    if "CATransaction.commit()" in rise[begin:add]:
        return "glyph rise fade commits before the fade is attached"
    if "fillMode = .backwards" not in rise[:add]:
        return "glyph rise fade does not hold the opacity on screen"
    if "presentation()?.opacity" not in rise[:add]:
        return "glyph rise fade does not start from the opacity on screen"
    if "folderChromeTiming(tracksIcon: true)" not in rise[:add]:
        return "glyph rise fade dropped the flight ease"
    if "wholeCellMergeFadeTiming()" in rise:
        return "glyph rise fade uses the late dissolve"
    if "fade.duration = duration" not in rise[:add]:
        return "glyph rise fade duration changed"
    if not (begin < opacity < add < commit):
        return "glyph rise fade model and fade are not one transaction"
    return None

sink_problem = glyph_sink_fade_shares_the_transaction(source)
if sink_problem:
    print("FAIL:", sink_problem)
    sys.exit(1)
print("PASS: glyph sink fade shares the model transaction")
rise_problem = glyph_rise_fade_shares_the_transaction(source)
if rise_problem:
    print("FAIL:", rise_problem)
    sys.exit(1)
print("PASS: glyph rise fade shares the model transaction")
def overflow_open_fade_shares_the_transaction(text: str) -> str | None:
    """Icons past the nine preview glyphs fade in on open. Model ends at 1;
    animator() used to write that before the fade attached and flash them on.
    Hold presentation opacity with fillMode backwards in one transaction."""
    start = text.index("    private func fadeOverflowIconsDuringPreviewFlight(")
    end = text.index("    private func commitFolderPreviewGlyphFlight(", start)
    body = text[start:end]
    if "animator().alphaValue" in body:
        return "overflow open fade still writes opacity through animator()"
    add = body.index(
        'layer?.add(fade, forKey: LauncherLayout.folderOverflowOpenFadeAnimationKey)'
    )
    opacity = body.rindex("layer?.opacity = 1", 0, add)
    begin = body.rindex("CATransaction.begin()", 0, opacity)
    commit = body.index("CATransaction.commit()", add)
    if "CATransaction.commit()" in body[begin:add]:
        return "overflow open fade commits before the fade is attached"
    if "fillMode = .backwards" not in body[:add]:
        return "overflow open fade does not hold the opacity on screen"
    if "presentation()?.opacity" not in body[:add]:
        return "overflow open fade does not start from the opacity on screen"
    if "wholeCellMergeFadeTiming()" not in body[:add]:
        return "overflow open fade dropped the late dissolve"
    if "fade.duration = duration" not in body[:add]:
        return "overflow open fade duration changed"
    if not (begin < opacity < add < commit):
        return "overflow open fade model and fade are not one transaction"
    return None

overflow_problem = overflow_open_fade_shares_the_transaction(source)
if overflow_problem:
    print("FAIL:", overflow_problem)
    sys.exit(1)
print("PASS: overflow open fade shares the model transaction")
def search_chrome_fade_shares_the_transaction(text: str) -> str | None:
    """Search/grid crossfade must not flash via animator().alphaValue."""
    helper_start = text.index("    private func fadeViewOpacityFromPresentation(")
    helper_end = text.index("    /// Search and the grid fade across each other.", helper_start)
    helper = text[helper_start:helper_end]
    if "fillMode = .backwards" not in helper:
        return "presentation opacity helper missing fillMode backwards"
    if "presentation()?.opacity" not in helper:
        return "presentation opacity helper does not read presentation opacity"
    start = text.index("    private func updateSearchChrome(searching: Bool) {")
    end = text.index("    private func currentPresentedItems()", start)
    body = text[start:end]
    if "animator().alphaValue" in body:
        return "search chrome fade still writes opacity through animator()"
    if "fadeViewOpacityFromPresentation" not in body:
        return "search chrome fade does not use presentation-backed opacity helper"
    if "LauncherLayout.searchChromeFadeAnimationKey" not in body:
        return "search chrome fade dropped its animation key"
    return None

def page_host_fade_shares_the_transaction(text: str) -> str | None:
    """Page turn host opacity and frame must hold presentation until attached."""
    start = text.index("    private func positionPages(")
    end = text.index("    private func layoutCollectionViews()", start)
    body = text[start:end]
    if "animator().alphaValue" in body:
        return "page host fade still writes opacity through animator()"
    if "animator().frame" in body:
        return "page host slide still writes frame through animator()"
    if "fadeViewOpacityFromPresentation" not in body:
        return "page host fade does not use presentation-backed opacity helper"
    if "animateViewFrameFromPresentation" not in body:
        return "page host slide does not use presentation-backed frame helper"
    if "LauncherLayout.pageHostFadeAnimationKey" not in body:
        return "page host fade dropped its animation key"
    if "LauncherLayout.pageHostSlideAnimationKey" not in body:
        return "page host slide dropped its animation key"
    if "fillMode = .backwards" not in body and "fillMode = .backwards" not in text[
        text.index("    private func animateViewFrameFromPresentation("):
        text.index("    /// Search and the grid fade across each other.", text.index("animateViewFrameFromPresentation"))
    ]:
        # Helper itself must hold presentation; checked below via helper body.
        pass
    helper_start = text.index("    private func animateViewFrameFromPresentation(")
    helper_end = text.index("    /// Search and the grid fade across each other.", helper_start)
    helper = text[helper_start:helper_end]
    if "fillMode = .backwards" not in helper:
        return "frame slide helper missing fillMode backwards"
    if 'keyPath: "position"' not in helper:
        return "frame slide helper does not animate position from presentation"
    if 'keyPath: "bounds.size"' not in helper:
        return "frame slide helper does not animate size from presentation"
    if "CAAnimationGroup" not in helper:
        return "frame slide helper does not group position and size"
    return None

search_problem = search_chrome_fade_shares_the_transaction(source)
if search_problem:
    print("FAIL:", search_problem)
    sys.exit(1)
print("PASS: search chrome fade shares the model transaction")
page_problem = page_host_fade_shares_the_transaction(source)
if page_problem:
    print("FAIL:", page_problem)
    sys.exit(1)
print("PASS: page host fade shares the model transaction")
def toast_fade_shares_the_transaction(text: str) -> str | None:
    """Toast show/hide must fade from presentation, not animator().alphaValue."""
    start = text.index("    private func presentToast(")
    end = text.index("    func hideToast(animated: Bool)", start)
    present = text[start:end]
    if "animator().alphaValue" in present:
        return "toast show still writes opacity through animator()"
    if "fadeViewOpacityFromPresentation" not in present:
        return "toast show does not use presentation-backed opacity helper"
    if "LauncherLayout.toastFadeAnimationKey" not in present:
        return "toast show dropped its animation key"
    hide_start = text.index("    private func performToastHide(animated: Bool)")
    hide_end = text.index("    private func snapInFlightToastFadeForMotionChange()", hide_start)
    hide = text[hide_start:hide_end]
    if "animator().alphaValue" in hide:
        return "toast hide still writes opacity through animator()"
    if "fadeViewOpacityFromPresentation" not in hide:
        return "toast hide does not use presentation-backed opacity helper"
    if "LauncherLayout.toastFadeAnimationKey" not in hide:
        return "toast hide dropped its animation key"
    if "LauncherLayout.toastFadeDuration" not in hide:
        return "toast hide duration is no longer the shared constant"
    return None

toast_problem = toast_fade_shares_the_transaction(source)
if toast_problem:
    print("FAIL:", toast_problem)
    sys.exit(1)
print("PASS: toast fade shares the model transaction")
def launch_press_holds_presentation_transform(text: str) -> str | None:
    """Launch-press pulse must start from on-screen transform with fillMode backwards.
    Reduced motion snaps to identity first (no scale pulse)."""
    start = text.index("    private func playLaunchFeedback() {")
    end = text.index("    func snapLaunchFeedbackForMotionChange()", start)
    body = text[start:end]
    if "shouldSnapLaunchPressForReducedMotion" not in body:
        return "launch press missing reduced-motion snap gate"
    if 'animation.fromValue = NSValue(caTransform3D: CATransform3DIdentity)' in body:
        return "launch press still forces identity as fromValue"
    # Full-motion path after snap early-return
    pulse = body
    if "shouldPlayLaunchFeedback" in body:
        pulse = body[body.index("shouldPlayLaunchFeedback"):]
    if "presentation()?.transform" not in pulse:
        return "launch press does not start from presentation transform"
    if "fillMode = .backwards" not in pulse:
        return "launch press does not hold presentation until attached"
    if "LauncherLayout.launchFeedbackAnimationKey" not in body:
        return "launch press dropped its animation key"
    if "CATransaction.setDisableActions(true)" not in body:
        return "launch press model write is not in a disabled-actions transaction"
    if "layer.transform = CATransform3DIdentity" not in body:
        return "launch press no longer parks the model at identity"
    if "launchPressPulseHalfDuration" not in pulse:
        return "full-motion launch press must use Core pulse duration"
    return None

launch_problem = launch_press_holds_presentation_transform(source)
if launch_problem:
    print("FAIL:", launch_problem)
    sys.exit(1)
print("PASS: launch press holds presentation transform")
def reorder_holds_presentation_until_frames_ready(text: str) -> str | None:
    """Neighbors must not snap-then-ease when reorder layout frames are empty."""
    start = text.index("    private func applyReorderSlots(")
    end = text.index("    private func restoreDragSourceTile()", start)
    body = text[start:end]
    if "shouldHoldReorderPresentationUntilFramesReady" not in body:
        return "applyReorderSlots does not hold presentation until frames are ready"
    if "reorderFramesUsable" not in body:
        return "applyReorderSlots does not gate on reorderFramesUsable"
    # Must not call setReorderTranslation with animated:false solely because ready is false.
    if "animated: animated && ready" in body:
        return "applyReorderSlots still snaps when ready is false (animated && ready)"
    set_start = text.index("    func setReorderTranslation(_ translation: CGSize, animated: Bool) {")
    set_end = text.index("    fileprivate func receiveReorderSlideFrame", set_start)
    setter = text[set_start:set_end]
    if "Hold presentation until the display-link spring is attached" not in setter:
        return "setReorderTranslation no longer documents hold-until-spring-attached"
    if "retarget only" not in setter.lower() and "Presented position stays put" not in setter:
        return "setReorderTranslation lost retarget-without-snap path"
    return None

reorder_problem = reorder_holds_presentation_until_frames_ready(source)
if reorder_problem:
    print("FAIL:", reorder_problem)
    sys.exit(1)
print("PASS: reorder holds presentation until frames ready")

def search_section_centers_short_rows(direct: str, core: str) -> str | None:
    """Short search rows use Core inset math so one result sits under the field."""
    if "searchSectionHorizontalInset" not in core:
        return "Core missing searchSectionHorizontalInset"
    start = direct.index("    private func layoutSearchCollection(")
    end = direct.index("    private func reloadVisibleCollections(", start)
    body = direct[start:end]
    if "searchSectionHorizontalInset" not in body:
        return "layoutSearchCollection does not use Core searchSectionHorizontalInset"
    if "floor((width - rowWidth) / 2)" in body:
        return "layoutSearchCollection still inlines short-row inset math"
    return None

core_source = (root / "Sources/Core/LauncherLayout.swift").read_text()
search_problem = search_section_centers_short_rows(source, core_source)
if search_problem:
    print(f"FAIL: {search_problem}")
    raise SystemExit(1)
print("PASS: search section centers short rows via Core")

def page_indicator_fades_visibility_from_presentation(direct: str, core: str) -> str | None:
    """Dots fade out/in with fillMode backwards when search hides the indicator."""
    if "pageIndicatorFadeAnimationKey" not in core:
        return "Core missing pageIndicatorFadeAnimationKey"
    if "shouldAnimatePageIndicatorVisibility" not in core:
        return "Core missing shouldAnimatePageIndicatorVisibility"
    if "pageIndicatorShouldShow" not in core:
        return "Core missing pageIndicatorShouldShow"
    start = direct.index("    /// Rebuild page dots. When `animatedVisibility` is true")
    end = direct.index("    /// Stop on the weight already drawn.", start)
    body = direct[start:end]
    if "fillMode = .backwards" not in body:
        return "page indicator visibility fade missing fillMode backwards"
    if "pageIndicatorFadeAnimationKey" not in body:
        return "page indicator visibility fade missing animation key"
    if "searchTransitionDuration" not in body:
        return "page indicator visibility fade does not share search chrome duration"
    if "animatedVisibility" not in body:
        return "configure dropped animatedVisibility"
    # updatePagination must request the animated path for search.
    pag = direct[direct.index("    private func updatePagination("):direct.index("    private func updateGridMetrics(")]
    if "shouldAnimatePageIndicatorVisibility" not in pag:
        return "updatePagination does not animate page indicator visibility"
    return None

indicator_problem = page_indicator_fades_visibility_from_presentation(source, core_source)
if indicator_problem:
    print(f"FAIL: {indicator_problem}")
    raise SystemExit(1)
print("PASS: page indicator fades visibility from presentation")

def flyer_flights_hold_presentation_frame(direct: str, core: str) -> str | None:
    """Merge/drop/scatter flyers must not snap via animator().frame."""
    if "flyerSlideAnimationKey" not in core:
        return "Core missing flyerSlideAnimationKey"
    if "runFlyerFrameAnimations" not in direct:
        return "Direct missing runFlyerFrameAnimations"
    # Product flight sites must not call animator().frame anymore.
    product_lines = []
    for line in direct.splitlines():
        code = line.split("//", 1)[0]
        if "animator().frame" in code:
            product_lines.append(line.strip())
    if product_lines:
        return f"product still uses animator().frame: {product_lines[0]}"
    for needle in (
        "commitFolderDissolveScatter",
        "commitFolderPreviewGlyphFlight",
        "commitMergePreviewLanding",
        "commitDropLanding",
    ):
        if needle not in direct:
            return f"missing flight commit {needle}"
    # Dissolve path must call the presentation flyer helper.
    start = direct.index("Folder dissolve scatter:")
    end = direct.index("    private func tileForPresentedItem(", start)
    body = direct[start:end]
    if "runFlyerFrameAnimations" not in body:
        return "dissolve scatter still not using runFlyerFrameAnimations"
    return None

flyer_problem = flyer_flights_hold_presentation_frame(source, core_source)
if flyer_problem:
    print(f"FAIL: {flyer_problem}")
    raise SystemExit(1)
print("PASS: flyer flights hold presentation frame")

def page_arrows_fade_presence_from_presentation(direct: str, core: str) -> str | None:
    """Page arrows fade like page dots when search hides them."""
    if "pageArrowPresenceAnimationKey" not in core:
        return "Core missing pageArrowPresenceAnimationKey"
    if "shouldAnimatePageArrowVisibility" not in core:
        return "Core missing shouldAnimatePageArrowVisibility"
    if "pageArrowShouldShow" not in core:
        return "Core missing pageArrowShouldShow"
    pag_start = direct.index("    private func updatePagingControls(")
    pag_end = direct.index("    /// Previous/next disappear on the first and last page.", pag_start)
    pag = direct[pag_start:pag_end]
    if "setPagingAvailable" not in pag:
        return "updatePagingControls does not call setPagingAvailable"
    if "isHidden =" in pag and "setPagingAvailable" in pag:
        # direct isHidden assignment would snap; setPagingAvailable owns hide.
        for line in pag.splitlines():
            code = line.split("//", 1)[0]
            if "isHidden =" in code and "PageButton" in code:
                return "updatePagingControls still snaps arrow isHidden"
    arrow_start = direct.index("    func setPagingAvailable(_ available: Bool, animated: Bool)")
    arrow_end = direct.index("    func settleHoverFadeForDismissal()", arrow_start)
    body = direct[arrow_start:arrow_end]
    if "animatePresence" not in body:
        return "setPagingAvailable does not animate presence"
    presence_start = direct.index("    private func animatePresence(")
    presence_end = direct.index("    private func setAlphaWithoutAnimation(", presence_start)
    presence = direct[presence_start:presence_end]
    if "fillMode = .backwards" not in presence:
        return "page arrow presence fade missing fillMode backwards"
    if "pageArrowPresenceAnimationKey" not in presence:
        return "page arrow presence fade missing animation key"
    if "searchTransitionDuration" not in presence:
        return "page arrow presence fade does not share search chrome duration"
    return None

arrow_problem = page_arrows_fade_presence_from_presentation(source, core_source)
if arrow_problem:
    print(f"FAIL: {arrow_problem}")
    raise SystemExit(1)
print("PASS: page arrows fade presence from presentation")

def footer_hints_fade_from_presentation(direct: str, core: str) -> str | None:
    """Footer drag/nav hints and folder chrome fade with search clock."""
    if "footerHintFadeAnimationKey" not in core:
        return "Core missing footerHintFadeAnimationKey"
    if "footerDragHintShouldShow" not in core:
        return "Core missing footerDragHintShouldShow"
    if "footerChromeShouldShow" not in core:
        return "Core missing footerChromeShouldShow"
    start = direct.index("    private func updateFooterHint(")
    end = direct.index("    private var isPaging: Bool", start)
    body = direct[start:end]
    if "setFooterChromeVisible" not in body:
        return "updateFooterHint does not fade footer chrome"
    if "setFooterLabelVisible" not in body:
        return "updateFooterHint does not fade drag hint"
    if "setFooterNavigationText" not in body:
        return "updateFooterHint does not crossfade navigation hint"
    if "footerControls.isHidden = openedFolderID" in body:
        return "updateFooterHint still snaps footerControls.isHidden"
    if "dragHintLabel.isHidden = true" in body and "setFooterLabelVisible" in body:
        # snap assignment in the orchestrator is a regression
        for line in body.splitlines():
            code = line.split("//", 1)[0]
            if "dragHintLabel.isHidden =" in code:
                return "updateFooterHint still snaps dragHintLabel.isHidden"
    if "fadeViewOpacityFromPresentation" not in body:
        return "footer hint helpers missing presentation opacity fade"
    if "footerHintFadeAnimationKey" not in body:
        return "footer hint fade missing animation key"
    if "searchTransitionDuration" not in body:
        return "footer hint fade does not share search chrome duration"
    if "footerNavigationShouldClearOpacityBeforeUnhide" not in core:
        return "Core missing footerNavigationShouldClearOpacityBeforeUnhide"
    if "footerNavigationShouldClearOpacityBeforeUnhide" not in body:
        return "setFooterNavigationText missing opacity-before-unhide gate"
    # Hidden text-change must clear opacity before unhide (not alpha 1 then dip).
    nav_start = body.index("    private func setFooterNavigationText(")
    nav = body[nav_start:]
    clear_gate = nav.find("footerNavigationShouldClearOpacityBeforeUnhide")
    if clear_gate < 0:
        return "setFooterNavigationText missing clear-opacity gate call"
    branch = nav[clear_gate:clear_gate + 900]
    if "alphaValue = 0" not in branch:
        return "hidden nav text-change must set alphaValue = 0 before unhide"
    zero_at = branch.find("alphaValue = 0")
    unhide_at = branch.find("isHidden = false", zero_at)
    if unhide_at < 0 or unhide_at < zero_at:
        return "hidden nav text-change must unhide after clearing opacity"
    # Must not unhide at alpha 1 before a text-swap fade.
    bad = "alphaValue = 1" in branch[:zero_at] and "isHidden = false" in branch[:zero_at]
    if bad:
        return "hidden nav text-change still unhides at alpha 1 before fade"
    return None

footer_problem = footer_hints_fade_from_presentation(source, core_source)
if footer_problem:
    print(f"FAIL: {footer_problem}")
    raise SystemExit(1)
print("PASS: footer hints fade from presentation")


def folder_dimmer_backdrop_veil_holds_presentation(direct: str, core: str) -> str | None:
    """Dimmer/backdrop: park-at-from before reveal; close parks opacity 0 while hidden."""
    if "folderCloseVeilUsesLateDissolve" not in core:
        return "Core missing folderCloseVeilUsesLateDissolve"
    if "folderCloseVeilTiming" not in direct:
        return "Direct missing folderCloseVeilTiming"
    open_start = direct.index("    func animateOpen(collapse:")
    open_end = direct.index("    func animateClose(", open_start)
    open_body = direct[open_start:open_end]
    if "dimmerFade" not in open_body or "fillMode = .backwards" not in open_body:
        return "animateOpen dimmer fade missing fillMode.backwards"
    if open_body.count("fillMode = .backwards") < 2:
        return "animateOpen missing enough fillMode.backwards (panel+dimmer)"
    # Residual-flash polish: park from-picture before isHidden = false.
    hide_at = open_body.find("isHidden = false")
    if hide_at < 0:
        return "animateOpen missing isHidden = false reveal"
    before_reveal = open_body[:hide_at]
    if "fromDimmerOpacity" not in before_reveal:
        return "animateOpen must park dimmer at fromDimmerOpacity before reveal"
    if "fromOpacity" not in before_reveal or "fromTransform" not in before_reveal:
        return "animateOpen must park panel at from opacity/transform before reveal"
    if before_reveal.rfind("opacity = 1") > before_reveal.rfind("fromDimmerOpacity"):
        # Allow later phase after reveal; the *last* opacity=1 before reveal is bad.
        last_full = before_reveal.rfind("dimmerLayer?.opacity = 1")
        last_from = before_reveal.rfind("fromDimmerOpacity")
        if last_full > last_from:
            return "animateOpen must not set dimmer opacity=1 before reveal"
    if open_body.count("CATransaction.commit()") < 2:
        return "animateOpen should park+reveal then animate in separate transactions"
    close_start = direct.index("    func animateClose(")
    close_end = direct.index("    private func collapsedPanelTransform(", close_start)
    close_body = direct[close_start:close_end]
    if "dimmerFade" not in close_body:
        return "animateClose missing dimmerFade"
    if "folderCloseVeilTiming" not in close_body:
        return "animateClose dimmer missing late-veil timing"
    if "fillMode = .backwards" not in close_body:
        return "animateClose missing fillMode.backwards"
    dimmer_fade_at = close_body.index("let dimmerFade = CABasicAnimation")
    dimmer_chunk = close_body[dimmer_fade_at:dimmer_fade_at + 500]
    if "fillMode = .backwards" not in dimmer_chunk:
        return "animateClose dimmerFade missing fillMode.backwards"
    # Close land / immediate: park opacity 0 while hidden (no bright restore flash).
    if "dimmerLayer.opacity = 0" not in close_body and "dimmer.layer?.opacity = 0" not in close_body:
        return "animateClose must park dimmer opacity 0 after hide"
    if "panelLayer.opacity = 0" not in close_body and "panel.layer?.opacity = 0" not in close_body:
        return "animateClose must park panel opacity 0 after hide"
    # Immediate path: isHidden = true before restoring transform/opacity.
    imm = close_body.split("if immediately")[1].split("let collapse = collapse")[0]
    if imm.find("isHidden = true") < 0:
        return "immediate close missing isHidden = true"
    if imm.find("isHidden = true") > imm.find("opacity = 0"):
        return "immediate close must hide before parking opacity 0"
    bd_start = direct.index("    private func animateFolderBackdrop(")
    bd_end = direct.index("    private func openFolder(", bd_start)
    bd = direct[bd_start:bd_end]
    if "folderBackdropOpacity" not in bd:
        return "animateFolderBackdrop missing opacity animation"
    if "fillMode = .backwards" not in bd:
        return "animateFolderBackdrop missing fillMode.backwards"
    if "folderCloseVeilTiming" not in bd:
        return "animateFolderBackdrop missing late-veil timing on close"
    if "presentation()" not in bd and "presented" not in bd:
        return "animateFolderBackdrop must read presentation before rewrite"
    set_start = direct.index("    private func setFolderBackdrop(")
    set_end = direct.index("    private func resetFolderBackdrop(", set_start)
    set_body = direct[set_start:set_end]
    if "finishFolderBackdropOpen(backdrop)" not in set_body:
        return "setFolderBackdrop(immediately, open) must snap via finishFolderBackdropOpen"
    if "if open" not in set_body:
        return "setFolderBackdrop immediately must branch on open vs close"
    return None

veil_problem = folder_dimmer_backdrop_veil_holds_presentation(source, core_source)
if veil_problem:
    print(f"FAIL: {veil_problem}")
    raise SystemExit(1)
print("PASS: folder dimmer/backdrop veil holds presentation (audit clean)")

def folder_title_waits_for_chrome_including_fade(direct: str, core: str) -> str | None:
    """Title AX/pointer stay down through open/close fade, not only scale."""
    if "folderTitlePointerEditingAvailable" not in core:
        return "Core missing folderTitlePointerEditingAvailable"
    if "folderTitleAccessibilityHidden" not in core:
        return "Core missing folderTitleAccessibilityHidden"
    if "folderOpenFade" not in core or "folderCloseFade" not in core:
        return "Core blocking keys omit folder open/close fade"
    if "folderTitleAccessibilityHidden" not in direct:
        return "FolderTitleField does not use Core accessibility policy"
    if "folderTitlePointerEditingAvailable" not in direct:
        return "FolderOverlay does not use Core pointer-editing policy"
    if "panelTransformInFlight" in direct:
        return "Direct still uses scale-only panelTransformInFlight"
    if "panelChromeInFlight" not in direct:
        return "Direct missing panelChromeInFlight (fade+scale)"
    if "folderPanelChromeInFlight" not in direct and "folderTitleBlockingChromeAnimationKeys" not in direct:
        return "hitTest does not consult Core panel chrome flight policy"
    if "folderTitleKeyboardFocusAvailable" not in core:
        return "Core missing folderTitleKeyboardFocusAvailable"
    if "folderTitleKeyboardFocusAvailable" not in direct:
        return "FolderTitleField does not gate keyboard focus on chrome"
    if "currentEditor() != nil" not in direct:
        return "FolderTitleField missing currentEditor checks"
    return None


def folder_title_edit_underline_fades_from_presentation(direct: str, core: str) -> str | None:
    """Begin/end edit fades the hairline from presentation (no hard snap)."""
    if "folderTitleEditUnderlineFadeAnimationKey" not in core:
        return "Core missing folderTitleEditUnderlineFadeAnimationKey"
    if "folderTitleEditUnderlineFadeDuration" not in core:
        return "Core missing folderTitleEditUnderlineFadeDuration"
    if "shouldAnimateFolderTitleEditUnderline" not in core:
        return "Core missing shouldAnimateFolderTitleEditUnderline"
    if "folderTitleEditUnderlineAlpha" not in core:
        return "Core missing folderTitleEditUnderlineAlpha"
    start = direct.index("private final class FolderTitleField:")
    end = direct.index("@MainActor\nprivate final class FolderOverlayView:", start)
    body = direct[start:end]
    if "editUnderlineLayer" not in body:
        return "FolderTitleField missing editUnderlineLayer"
    if "setEditUnderlineVisible" not in body:
        return "FolderTitleField missing setEditUnderlineVisible"
    if "textDidBeginEditing" not in body or "textDidEndEditing" not in body:
        return "FolderTitleField must drive underline from begin/end editing"
    if "shouldAnimateFolderTitleEditUnderline" not in body:
        return "FolderTitleField missing underline fade gate"
    if "fade.fillMode = .backwards" not in body:
        return "title edit underline must use fillMode.backwards"
    if 'keyPath: "opacity"' not in body:
        return "title edit underline must animate opacity"
    # No hard stroke in draw while editing.
    if "NSBezierPath" in body and "setStroke" in body:
        return "FolderTitleField must not hard-stroke underline in draw"
    return None


title_problem = folder_title_waits_for_chrome_including_fade(source, core_source)
if title_problem:
    print(f"FAIL: {title_problem}")
    raise SystemExit(1)
print("PASS: folder title waits for chrome including fade")

underline_problem = folder_title_edit_underline_fades_from_presentation(source, core_source)
if underline_problem:
    print(f"FAIL: {underline_problem}")
    raise SystemExit(1)
print("PASS: folder title edit underline fades from presentation")


def alias_rename_edit_underline_fades_from_presentation(direct: str, core: str) -> str | None:
    """Alias alert field uses the same presentation underline fade as folder title."""
    if "aliasEditUnderlineFadeAnimationKey" not in core:
        return "Core missing aliasEditUnderlineFadeAnimationKey"
    if "aliasEditUnderlineFadeDuration" not in core:
        return "Core missing aliasEditUnderlineFadeDuration"
    start = direct.index("private final class AliasNameField:")
    end = direct.index("@MainActor\nprivate final class FolderTitleField:", start)
    body = direct[start:end]
    if "editUnderlineLayer" not in body:
        return "AliasNameField missing editUnderlineLayer"
    if "setEditUnderlineVisible" not in body:
        return "AliasNameField missing setEditUnderlineVisible"
    if "textDidBeginEditing" not in body or "textDidEndEditing" not in body:
        return "AliasNameField must drive underline from begin/end editing"
    if "aliasEditUnderlineFadeAnimationKey" not in body:
        return "AliasNameField missing alias underline animation key"
    if "fade.fillMode = .backwards" not in body:
        return "alias edit underline must use fillMode.backwards"
    if "shouldAnimateFolderTitleEditUnderline" not in body:
        return "AliasNameField must reuse underline fade gate"
    if "isBezeled = false" not in body or "focusRingType = .none" not in body:
        return "AliasNameField should drop system bezel/focus ring for quiet underline"
    return None


alias_underline_problem = alias_rename_edit_underline_fades_from_presentation(source, core_source)
if alias_underline_problem:
    print(f"FAIL: {alias_underline_problem}")
    raise SystemExit(1)
print("PASS: alias rename edit underline fades from presentation")


def alias_selects_all_on_begin(direct: str, core: str) -> str | None:
    """Alias rename selects the whole string when editing begins (folder-title parity)."""
    if "aliasSelectsAllOnBeginEditing" not in core:
        return "Core missing aliasSelectsAllOnBeginEditing"
    start = direct.index("private final class AliasNameField:")
    end = direct.index("@MainActor\nprivate final class FolderTitleField:", start)
    body = direct[start:end]
    if "selectAllAliasTextIfNeeded" not in body:
        return "AliasNameField missing selectAllAliasTextIfNeeded"
    if "aliasSelectsAllOnBeginEditing" not in body:
        return "AliasNameField must consult aliasSelectsAllOnBeginEditing"
    if "textDidBeginEditing" not in body:
        return "AliasNameField missing textDidBeginEditing"
    # selectAll must be invoked from begin-editing, not only defined
    begin = body[
        body.index("override func textDidBeginEditing"):
        body.index("override func textDidEndEditing")
    ]
    if "selectAllAliasTextIfNeeded()" not in begin:
        return "textDidBeginEditing must call selectAllAliasTextIfNeeded"
    if "editor.selectAll(nil)" not in body:
        return "selectAllAliasTextIfNeeded must call editor.selectAll"
    return None


alias_select_problem = alias_selects_all_on_begin(source, core_source)
if alias_select_problem:
    print(f"FAIL: {alias_select_problem}")
    raise SystemExit(1)
print("PASS: alias selects all on begin editing")



def folder_title_selects_all_on_begin(direct: str, core: str) -> str | None:
    if "folderTitleSelectsAllOnBeginEditing" not in core:
        return "Core missing folderTitleSelectsAllOnBeginEditing"
    if "resolvedFolderName" not in core:
        return "Core missing resolvedFolderName"
    if "selectAllTitleTextIfNeeded" not in direct:
        return "Direct missing selectAllTitleTextIfNeeded"
    # Folder overlay's begin-editing (not the search field's audit hook).
    start = direct.index("    func controlTextDidBeginEditing(_ obj: Notification) {\n        titleBeforeEdit")
    end = direct.index("    func controlTextDidEndEditing(_ obj: Notification) {\n        titleField.needsDisplay", start)
    begin = direct[start:end]
    if "selectAllTitleTextIfNeeded()" not in begin:
        return "title controlTextDidBeginEditing does not select-all"
    if "resolvedFolderName" not in direct:
        return "Direct end-edit missing resolvedFolderName fallback"
    return None

title_edit_problem = folder_title_selects_all_on_begin(source, core_source)
if title_edit_problem:
    print(f"FAIL: {title_edit_problem}")
    raise SystemExit(1)
print("PASS: folder title selects all on begin editing")

def folder_title_double_click_to_edit(direct: str, core: str) -> str | None:
    if "folderTitleShouldBeginEditingFromPointer" not in core:
        return "Core missing folderTitleShouldBeginEditingFromPointer"
    if "folderTitleShouldBeginEditingFromPointer" not in direct:
        return "FolderTitleField missing double-click gate"
    start = direct.index("@MainActor\nprivate final class FolderTitleField:")
    end = direct.index("\n@MainActor\nprivate final class FolderOverlayView:", start)
    body = direct[start:end]
    if "override func mouseDown(with event: NSEvent)" not in body:
        return "FolderTitleField missing mouseDown override"
    if "clickCount" not in body:
        return "FolderTitleField mouseDown ignores clickCount"
    # Escape cancel / Return commit should prefer a member tile.
    if "folderTitleFocusesFirstMemberAfterEndingEdit" not in core:
        return "Core missing folderTitleFocusesFirstMemberAfterEndingEdit"
    if "refocusAfterTitleEditingEnds" not in direct:
        return "FolderOverlay missing refocusAfterTitleEditingEnds"
    cancel = direct[direct.index("    func cancelTitleEditingIfActive("):direct.index("    func abandonTitleEditingForResignKey(")]
    if "refocusAfterTitleEditingEnds()" not in cancel:
        return "cancelTitleEditingIfActive must call refocusAfterTitleEditingEnds"
    # Return commit must share the same first-member handoff (not collectionView-only).
    # Scope to FolderOverlayView — LWC also has a search-field doCommandBy.
    overlay = direct[direct.index("@MainActor\nprivate final class FolderOverlayView:"):]
    ctrl_start = "    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {"
    ctrl_end = "\n    func control(_ control: NSControl, textShouldEndEditing"
    ctrl = overlay[overlay.index(ctrl_start):overlay.index(ctrl_end, overlay.index(ctrl_start))]
    if "insertNewline" not in ctrl:
        return "title doCommandBy missing insertNewline"
    if "refocusAfterTitleEditingEnds()" not in ctrl:
        return "Return commit must call refocusAfterTitleEditingEnds"
    helper_start = "    private func refocusAfterTitleEditingEnds()"
    helper_end = "\n    /// True when `view` is the title field"
    helper = direct[direct.index(helper_start):direct.index(helper_end, direct.index(helper_start))]
    if "orderedAppTiles.first" not in helper:
        return "refocusAfterTitleEditingEnds does not focus first member"
    if "folderTitleFocusesFirstMemberAfterEndingEdit" not in helper:
        return "refocusAfterTitleEditingEnds ignores Core policy"
    return None

dbl_problem = folder_title_double_click_to_edit(source, core_source)
if dbl_problem:
    print(f"FAIL: {dbl_problem}")
    raise SystemExit(1)
print("PASS: folder title double-click to edit")


def folder_title_cancel_on_outside_click(direct: str, core: str) -> str | None:
    if "folderTitleShouldCancelEditingOnOutsideClick" not in core:
        return "Core missing folderTitleShouldCancelEditingOnOutsideClick"
    if "cancelFolderTitleEditingIfClickOutsideTitle" not in direct:
        return "Direct missing cancelFolderTitleEditingIfClickOutsideTitle"
    if "isCloseButtonHit" not in direct:
        return "Direct missing isCloseButtonHit (close must commit, not cancel)"
    if "folderTitleShouldCancelEditingOnOutsideClick" not in direct:
        return "Direct missing Core outside-click gate"
    # Panel leftMouseDown must ask root to cancel before super.
    panel_start = direct.index("override func sendEvent(_ event: NSEvent)")
    panel = direct[panel_start:panel_start + 2800]
    if "cancelFolderTitleEditingIfClickOutsideTitle" not in panel:
        return "LauncherPanel.sendEvent missing outside-title cancel"
    if "leftMouseDown" not in panel:
        return "LauncherPanel.sendEvent missing leftMouseDown cancel path"
    # close() must abort editor after commit so closeFolder cancel is a no-op.
    close_start = direct.rindex("    @objc private func close() {")
    close_end = direct.index("\n}", close_start)  # end of FolderOverlayView class follows soon
    # Prefer the method body: first blank-line-less closing at indent of method
    close_body = direct[close_start:close_start + 900]
    if "isDiscardingTitleEdit" not in close_body or "abortEditing" not in close_body:
        return "FolderOverlay close() must abort editor after commit"
    if "onRename?" not in close_body:
        return "FolderOverlay close() missing onRename commit"
    # closeFolder still cancels when editor somehow remains (dimmer path).
    cf = direct[direct.index("    private func closeFolder("):direct.index("    private func closeFolder(") + 900]
    if "cancelTitleEditingIfActive(refocus: false)" not in cf:
        return "closeFolder missing cancelTitleEditingIfActive(refocus: false)"
    return None

outside_problem = folder_title_cancel_on_outside_click(source, core_source)
if outside_problem:
    print(f"FAIL: {outside_problem}")
    raise SystemExit(1)
print("PASS: folder title cancel on outside click")


def folder_member_focus_fill_waits_for_panel_chrome(direct: str, core: str) -> str | None:
    """Member keyboard-focus fill stays idle while open/close chrome travels."""
    if "folderPanelChromeInFlight" not in core:
        return "Core missing folderPanelChromeInFlight"
    if "folderPanelChromeInFlight:" not in direct:
        return "tileChromeFillAlpha call site missing folderPanelChromeInFlight"
    if "focusOpenedFolderMemberAfterChromeLands" not in direct:
        return "Direct missing deferred member focus after open chrome"
    if "onChromeOpenLanded" not in direct:
        return "Direct missing onChromeOpenLanded"
    if "refreshFocusChrome" not in direct:
        return "Direct missing refreshFocusChrome"
    if "folderOpenFocusHandoff" not in core:
        return "Core missing folderOpenFocusHandoff"
    if "folderOpenFocusHandoff" not in direct:
        return "Direct missing folderOpenFocusHandoff wiring"
    if "FolderOpenFocusOwner" not in core:
        return "Core missing FolderOpenFocusOwner"
    start = direct.index("    private func focusOpenedFolderMemberAfterChromeLands()")
    end = direct.index("    private func closeFolder(", start)
    body = direct[start:end]
    if "otherOverlayChrome" not in body:
        return "focus owner must classify otherOverlayChrome"
    if "folderOpenFocusOwner" not in body:
        return "focusOpenedFolderMemberAfterChromeLands missing owner classify"
    if "case .focusFirstMember" not in body:
        return "focusOpenedFolderMemberAfterChromeLands missing focusFirstMember path"
    if "case .refreshMemberChrome" not in body:
        return "focusOpenedFolderMemberAfterChromeLands missing refreshMemberChrome path"
    # Non-empty: first member only (no `?? keyViews.first` steal). Empty folder
    # may focus title via Core `folderOpenEmptyFocusesTitle` — not an empty CV.
    if "?? keyViews.first" in body:
        return "focus handoff must not fall back to title/close when no member tile"
    if "folderOpenEmptyFocusesTitle" not in body:
        return "empty folder open land must consult folderOpenEmptyFocusesTitle"
    if "focusTitleField" not in body:
        return "empty folder open land must focusTitleField"
    if "refreshFocusChrome()" not in body:
        return "focusFirstMember path should refresh chrome after land"
    return None


def folder_member_focus_fill_fades_from_presentation(direct: str, core: str) -> str | None:
    """Tab between members retargets the 8% fill from presentation, not a hard snap."""
    if "tileChromeFillFadeAnimationKey" not in core:
        return "Core missing tileChromeFillFadeAnimationKey"
    if "tileChromeFillFadeDuration" not in core:
        return "Core missing tileChromeFillFadeDuration"
    if "shouldAnimateTileChromeFocusFill" not in core:
        return "Core missing shouldAnimateTileChromeFocusFill"
    if "shouldAnimateTileChromeFocusFill" not in direct:
        return "Direct missing shouldAnimateTileChromeFocusFill gate"
    if "tileChromeFillFadeAnimationKey" not in direct:
        return "Direct missing tile chrome fill animation key"
    if "presentedChromeFillAlpha" not in direct:
        return "Direct missing presentedChromeFillAlpha"
    marker = "private func updateDropTargetAppearance(focused: Bool? = nil)"
    if marker not in direct:
        return "Direct missing updateDropTargetAppearance"
    start = direct.index(marker)
    end = direct.index("private func presentedChromeFillAlpha", start)
    body = direct[start:end]
    if "fade.fillMode = .backwards" not in body:
        return "focus fill fade must use fillMode.backwards"
    if 'keyPath: "backgroundColor"' not in body:
        return "focus fill must animate backgroundColor"
    return None


focus_problem = folder_member_focus_fill_waits_for_panel_chrome(source, core_source)
if focus_problem:
    print(f"FAIL: {focus_problem}")
    raise SystemExit(1)
print("PASS: folder member focus fill waits for panel chrome")

fill_fade_problem = folder_member_focus_fill_fades_from_presentation(source, core_source)
if fill_fade_problem:
    print(f"FAIL: {fill_fade_problem}")
    raise SystemExit(1)
print("PASS: folder member focus fill fades from presentation")


def folder_close_defers_grid_focus_until_chrome_lands(direct: str, core: str) -> str | None:
    """Grid focus after close waits for onChromeCloseLanded (mirror open)."""
    if "folderCloseShouldRestoreGridFocusOnChromeLand" not in core:
        return "Core missing folderCloseShouldRestoreGridFocusOnChromeLand"
    if "pendingFolderCloseFocusRestoreID" not in direct:
        return "Direct missing pendingFolderCloseFocusRestoreID"
    if "finishFolderCloseChromeLand" not in direct:
        return "Direct missing finishFolderCloseChromeLand"
    if "folderCloseShouldRestoreGridFocusOnChromeLand" not in direct:
        return "Direct missing Core close-restore gate"
    # closeFolder parks; must not call focusGridEntry inline.
    start = direct.index("    private func closeFolder(")
    end = direct.index("    private func finishFolderCloseChromeLand()", start)
    close_body = direct[start:end]
    if "pendingFolderCloseFocusPreviousEntries" not in close_body:
        return "closeFolder must park pendingFolderCloseFocusPreviousEntries"
    if "pendingFolderCloseFocusRestoreID = closingFolderID" not in close_body:
        return "closeFolder must park pendingFolderCloseFocusRestoreID"
    if "focusGridEntry(" in close_body:
        return "closeFolder must not focusGridEntry before chrome lands"
    # Land path restores + refreshes.
    land_start = direct.index("    private func finishFolderCloseChromeLand()")
    land_end = direct.index("\n    /// Focus a grid entry", land_start)
    land = direct[land_start:land_end]
    if "focusMainGridEntry(" not in land and "focusGridEntry(restoreID)" not in land:
        return "finishFolderCloseChromeLand missing focusMainGridEntry"
    if "folderCloseGridFocusID" not in land:
        return "finishFolderCloseChromeLand must resolve via folderCloseGridFocusID"
    if "refreshFocusChrome()" not in land:
        return "finishFolderCloseChromeLand missing refreshFocusChrome"
    if "releaseBorrowedPreviewPlate()" not in land:
        return "finishFolderCloseChromeLand must still release preview plate"
    # Callback wired.
    assign = direct.index("folderOverlay.onChromeCloseLanded =")
    if "finishFolderCloseChromeLand()" not in direct[assign:assign + 200]:
        return "onChromeCloseLanded must call finishFolderCloseChromeLand"
    # Open cancels a pending restore.
    open_start = direct.index("    private func openFolder(_ id: UUID)")
    open_head = direct[open_start:open_start + 800]
    if "pendingFolderCloseFocusRestoreID = nil" not in open_head:
        return "openFolder must clear pending close focus restore"
    return None

close_focus_problem = folder_close_defers_grid_focus_until_chrome_lands(source, core_source)
if close_focus_problem:
    print(f"FAIL: {close_focus_problem}")
    raise SystemExit(1)
print("PASS: folder close defers grid focus until chrome lands")


def folder_overlay_refuses_keyboard_while_closing(direct: str, core: str) -> str | None:
    if "folderOverlayKeyboardFocusAvailable" not in core:
        return "Core missing folderOverlayKeyboardFocusAvailable"
    if "folderOverlayKeyViewsShouldIncludeControls" not in core:
        return "Core missing folderOverlayKeyViewsShouldIncludeControls"
    if "folderOverlayKeyboardFocusAvailable" not in direct:
        return "Direct missing folderOverlayKeyboardFocusAvailable wiring"
    if "breakKeyViewLoop" not in direct:
        return "Direct missing breakKeyViewLoop"
    tile_idx = direct.find("tile.keyboardFocusAvailable")
    if tile_idx < 0:
        return "folder tiles missing keyboardFocusAvailable assign"
    tile_wire = direct[tile_idx:tile_idx + 400]
    if "panelChromeInFlight" not in tile_wire:
        return "folder tile keyboard gate must use panelChromeInFlight"
    close_idx = direct.find("closeButton.keyboardFocusAvailable")
    if close_idx < 0:
        return "close button missing keyboardFocusAvailable"
    close_wire = direct[close_idx:close_idx + 400]
    if "panelChromeInFlight" not in close_wire:
        return "close button keyboard gate must use panelChromeInFlight"
    marker = "    var keyViews: [NSView] {"
    idx = direct.find("// Closing: omit overlay controls")
    if idx < 0:
        return "folder keyViews missing closing omit comment"
    kv_start = direct.rfind(marker, 0, idx)
    kv_end = direct.index("    func breakKeyViewLoop()", kv_start)
    kv = direct[kv_start:kv_end]
    if "folderOverlayKeyViewsShouldIncludeControls" not in kv:
        return "folder keyViews must gate on folderOverlayKeyViewsShouldIncludeControls"
    if "return []" not in kv:
        return "closing keyViews must return []"
    rb_start = direct.index("    private func rebuildKeyViewLoop()")
    rb = direct[rb_start:rb_start + 1600]
    if "breakKeyViewLoop()" not in rb or "isAnimatingClose" not in rb:
        return "rebuildKeyViewLoop must breakKeyViewLoop while closing"
    land = direct[
        direct.index("private func focusOpenedFolderMemberAfterChromeLands()"):
        direct.index("private func folderOpenFocusOwner")
    ]
    if "rebuildKeyViewLoop()" not in land:
        return "open land handoff must rebuildKeyViewLoop before focusFirstMember"
    return None

overlay_kb_problem = folder_overlay_refuses_keyboard_while_closing(source, core_source)
if overlay_kb_problem:
    print(f"FAIL: {overlay_kb_problem}")
    raise SystemExit(1)
print("PASS: folder overlay refuses keyboard while closing")


def chrome_reveal_clears_opacity_before_unhide(direct: str) -> str | None:
    """Toast/footer/page chrome must not unhide at alpha 1 then clear."""
    # Toast: opacity 0 and isHidden = false share one transaction before fade.
    toast_start = direct.index("    private func presentToast(")
    toast_end = direct.index("    func hideToast(animated:", toast_start)
    toast = direct[toast_start:toast_end]
    if "toastShouldClearOpacityBeforeUnhide" not in toast:
        return "presentToast missing toastShouldClearOpacityBeforeUnhide"
    if "toastShouldRestoreOpacityWhenAlreadyShown" not in toast:
        return "presentToast missing toastShouldRestoreOpacityWhenAlreadyShown"
    if "toastView.alphaValue = 0" not in toast or "toastView.isHidden = false" not in toast:
        return "presentToast missing opacity-0-before-unhide"
    # isHidden = false must not appear before alphaValue = 0 in the animated path.
    alpha_at = toast.find("toastView.alphaValue = 0")
    unhide_at = toast.find("toastView.isHidden = false")
    if unhide_at < alpha_at:
        return "presentToast unhides before clearing opacity"
    footer_start = direct.index("    private func setFooterChromeVisible(")
    footer_end = direct.index("    private func setFooterLabelVisible(", footer_start)
    footer = direct[footer_start:footer_end]
    if "Clear opacity\n        // before revealing" not in footer and "Clear opacity before revealing" not in footer:
        # comment may be split
        if "does not flash the full footer" not in footer:
            return "setFooterChromeVisible missing opacity-before-unhide comment/policy"
    # Reveal branch: alphaValue = 0 before isHidden = false when animating.
    reveal = footer[footer.find("if shouldAnimate"):]
    a0 = reveal.find("footerControls.alphaValue = 0")
    uh = reveal.find("footerControls.isHidden = false")
    if a0 < 0 or uh < 0 or uh < a0:
        return "setFooterChromeVisible animated reveal unhides before opacity 0"
    return None

chrome_problem = chrome_reveal_clears_opacity_before_unhide(source)
if chrome_problem:
    print(f"FAIL: {chrome_problem}")
    raise SystemExit(1)
print("PASS: chrome reveal clears opacity before unhide")

def search_chrome_clears_opacity_before_unhide(direct: str) -> str | None:
    """Search/grid crossfade must not unhide a host that still has alpha 1."""
    start = direct.index("    private func updateSearchChrome(searching: Bool)")
    end = direct.index("    private func currentPresentedItems(", start)
    body = direct[start:end]
    if "incomingWasHidden" not in body:
        return "updateSearchChrome missing incomingWasHidden guard"
    if "landSearchChrome restores the hidden host" not in body:
        return "updateSearchChrome missing opacity-before-unhide comment"
    # Clear before unhide: alphaValue = 0 appears before isHidden = false for incoming.
    clear = body.find("incoming.alphaValue = 0")
    unhide = body.find("incoming.isHidden = false")
    if clear < 0 or unhide < 0 or unhide < clear:
        return "updateSearchChrome unhides incoming before clearing opacity"
    return None

search_problem = search_chrome_clears_opacity_before_unhide(source)
if search_problem:
    print(f"FAIL: {search_problem}")
    raise SystemExit(1)
print("PASS: search chrome clears opacity before unhide")

def status_chrome_fades_from_presentation(direct: str, core: str) -> str | None:
    if "statusChromeFadeAnimationKey" not in core:
        return "Core missing statusChromeFadeAnimationKey"
    if "setStatusChromeVisible" not in direct:
        return "Direct missing setStatusChromeVisible"
    if "setStatusChromeVisible(scanSkeleton" not in direct:
        return "scanSkeleton not wired to status chrome fade"
    if "setEmptyStateChrome(" not in direct and "setStatusChromeVisible(emptyStateView" not in direct:
        return "emptyStateView not wired to status chrome fade"
    if "setStatusChromeMessage(" not in direct:
        return "Direct missing setStatusChromeMessage (search empty copy crossfade)"
    if "setStatusChromeLabeledText(" not in direct:
        return "Direct missing setStatusChromeLabeledText"
    if "statusChromeShouldCrossfadeText" not in core:
        return "Core missing statusChromeShouldCrossfadeText"
    if "statusChromeShouldCrossfadeText" not in direct:
        return "status chrome labeled text missing Core crossfade gate"
    labeled = direct[
        direct.index("private func setStatusChromeLabeledText("):
        direct.index("private func setStatusChromeVisible(")
    ]
    if "fadeViewOpacityFromPresentation" not in labeled:
        return "status labeled text crossfade missing presentation fade"
    if "messageLabel.stringValue = statusMessage" in direct:
        return "catalog status still snaps messageLabel.stringValue before show"
    ro_start = direct.index("    private func updateReadOnlyStatus(")
    ro_end = direct.index("\n    func setReducesMotion(", ro_start)
    ro = direct[ro_start:ro_end]
    if "setStatusChromeLabeledText" not in ro:
        return "readOnlyStatusLabel not wired to labeled text crossfade"
    if "setStatusChromeVisible(" in ro:
        return "readOnlyStatusLabel still uses setStatusChromeVisible directly"
    if "statusChromeLabeledTextToShow" not in ro:
        return "read-only status missing empty-copy → hide helper"
    labeled = direct[
        direct.index("private func setStatusChromeLabeledText("):
        direct.index("private func setStatusChromeVisible(")
    ]
    if "animated: animated" not in labeled:
        return "labeled text crossfade must pass animated into Core gate"
    if "statusChromeShouldCrossfadeText" not in core:
        return "Core missing statusChromeShouldCrossfadeText"
    # animated parameter must be part of the Core signature (not only defaulted away).
    core_fn = core[core.index("func statusChromeShouldCrossfadeText("):core.index("func statusChromeShouldCrossfadeText(") + 350]
    if "animated: Bool" not in core_fn:
        return "Core crossfade gate missing animated parameter"
    if "statusChromeShouldClearOpacityBeforeUnhide" not in core:
        return "Core missing statusChromeShouldClearOpacityBeforeUnhide"
    if "statusChromeShouldRestoreOpacityWhenAlreadyShown" not in core:
        return "Core missing statusChromeShouldRestoreOpacityWhenAlreadyShown"
    visible_fn = direct[
        direct.index("private func setStatusChromeVisible("):
        direct.index("private func landSearchChrome(")
    ]
    if "statusChromeShouldClearOpacityBeforeUnhide" not in visible_fn:
        return "setStatusChromeVisible missing clear-before-unhide Core gate"
    if "statusChromeShouldRestoreOpacityWhenAlreadyShown" not in visible_fn:
        return "setStatusChromeVisible missing interrupted-hide restore gate"
    # Reveal: opacity 0 before isHidden = false
    clear_at = visible_fn.find("view.alphaValue = 0")
    unhide_at = visible_fn.find("view.isHidden = false")
    if clear_at < 0 or unhide_at < 0 or unhide_at < clear_at:
        return "setStatusChromeVisible reveal unhides before clearing opacity"
    if "setEmptyStateChrome(" not in direct:
        return "Direct missing setEmptyStateChrome"
    empty = direct[
        direct.index("private func setEmptyStateChrome("):
        direct.index("private func setStatusChromeMessage(")
    ]
    if "statusChromeShouldCrossfadeText" not in empty:
        return "empty state copy missing crossfade gate"
    catalog = direct[
        direct.index("let showScanSkeleton"):
        direct.index("setStatusChromeVisible(scanSkeleton")
    ]
    if "emptyStateTitle.stringValue" in catalog:
        return "catalog refresh still snaps emptyStateTitle before setEmptyStateChrome"
    # Footer drag-hint / chrome reveal already clears opacity before unhide.
    footer = direct[direct.index("private func setFooterLabelVisible("):direct.index("private func setFooterNavigationText(")]
    if "alphaValue = 0" not in footer or "isHidden = false" not in footer:
        return "footer drag-hint reveal missing opacity-before-unhide"
    return None

status_problem = status_chrome_fades_from_presentation(source, core_source)
if status_problem:
    print(f"FAIL: {status_problem}")
    raise SystemExit(1)
print("PASS: status chrome fades from presentation")


def search_count_label_fades_with_status_chrome(direct: str, core: str) -> str | None:
    if "searchAdjacentChromeShouldShow" not in core:
        return "Core missing searchAdjacentChromeShouldShow"
    if "searchCountLabelKind" not in core:
        return "Core missing searchCountLabelKind"
    if "updateSearchAdjacentChrome" not in direct:
        return "Direct missing updateSearchAdjacentChrome"
    if "card.addSubview(countLabel)" not in direct:
        return "countLabel not in view hierarchy"
    helper = direct[
        direct.index("private func updateSearchAdjacentChrome("):
        direct.index("private func setStatusChromeMessage(")
    ]
    if "searchAdjacentChromeShouldShow" not in helper:
        return "adjacent chrome helper missing Core gate"
    if "setStatusChromeVisible(" not in helper or "settingsButton" not in helper:
        return "adjacent chrome must fade settingsButton with folder chrome"
    if "setStatusChromeVisible(" not in helper or "searchChrome" not in helper:
        return "adjacent chrome must fade searchChrome with folder chrome"
    if "private let searchChrome" not in direct:
        return "searchChrome must be a stored property for folder quieting"
    if "openedFolderID != nil" not in helper:
        return "adjacent chrome helper missing folderOpen source"
    if "folderOverlay.isAnimatingClose" not in helper:
        return "adjacent chrome helper missing folderClosing source"
    if "folderOpen: folderOpen" not in helper or "folderClosing: folderClosing" not in helper:
        return "adjacent chrome helper must pass folderOpen/folderClosing into Core"
    if "个结果" not in helper or "个项目" not in helper:
        return "count helper missing results/items formats"
    if "case nil:" not in helper:
        return "count helper must hide when kind is nil"
    open_fn = direct[direct.index("private func openFolder(_ id: UUID)"):direct.index("private func openFolder(_ id: UUID)") + 1200]
    if "updateSearchAdjacentChrome()" not in open_fn:
        return "openFolder must refresh search-adjacent chrome"
    close_fn = direct[direct.index("private func closeFolder("):direct.index("private func finishFolderCloseChromeLand()")]
    if "updateSearchAdjacentChrome()" not in close_fn:
        return "closeFolder must refresh search-adjacent chrome while closing"
    land = direct[direct.index("private func finishFolderCloseChromeLand()"):direct.index("private func finishFolderCloseChromeLand()") + 600]
    if "updateSearchAdjacentChrome()" not in land:
        return "finishFolderCloseChromeLand must restore search-adjacent chrome"
    if "private let clearButton" in direct or "clearButton =" in direct:
        return "dead clearButton must be removed (NSSearchField has cancel)"
    if "searchFieldDidEndSearching" not in direct:
        return "system cancel must use searchFieldDidEndSearching"
    if "cancelButtonCell" not in direct:
        return "system cancel button missing accessibility wiring"
    if "countLabel.trailingAnchor.constraint(equalTo: searchChrome.leadingAnchor" not in direct:
        return "countLabel missing trailing-to-searchChrome constraint"
    return None

count_problem = search_count_label_fades_with_status_chrome(source, core_source)
if count_problem:
    print(f"FAIL: {count_problem}")
    raise SystemExit(1)
print("PASS: search count label fades with status chrome")


def recovery_buttons_use_status_chrome_fade(direct: str, core: str) -> str | None:
    start = direct.index("    private func updateRecoveryButtons(")
    end = direct.index("    func setLayoutEditingEnabled(", start)
    body = direct[start:end]
    if "setStatusChromeVisible" not in body:
        return "updateRecoveryButtons missing setStatusChromeVisible"
    for name in (
        "cachedCatalogButton",
        "emptyStateCachedButton",
        "rescanButton",
        "readOnlyCachedButton",
    ):
        if name not in body:
            return f"updateRecoveryButtons missing {name}"
        if f"{name}.isHidden =" in body:
            return f"updateRecoveryButtons still snaps {name}.isHidden"
    # Empty-state host + recovery buttons share setStatusChromeVisible park-before-unhide.
    if "statusChromeShouldClearOpacityBeforeUnhide" not in core:
        return "Core missing statusChromeShouldClearOpacityBeforeUnhide (empty/recovery reveal)"
    if "statusChromeShouldRestoreOpacityWhenAlreadyShown" not in core:
        return "Core missing statusChromeShouldRestoreOpacityWhenAlreadyShown"
    visible_fn = direct[
        direct.index("private func setStatusChromeVisible("):
        direct.index("private func landSearchChrome(")
    ]
    if "statusChromeShouldClearOpacityBeforeUnhide" not in visible_fn:
        return "empty/recovery reveal missing clear-before-unhide"
    if "statusChromeShouldRestoreOpacityWhenAlreadyShown" not in visible_fn:
        return "empty/recovery reveal missing interrupted-hide restore"
    land_start = direct.index("    private func landSearchChrome(")
    land_end = direct.index("    private func setSearchChromePointer(", land_start)
    land = direct[land_start:land_end]
    opacity = land.find("incoming.alphaValue = 1")
    unhide = land.find("incoming.isHidden = false")
    if opacity < 0 or unhide < 0 or unhide < opacity:
        return "landSearchChrome unhides incoming before setting opacity"
    return None

recovery_problem = recovery_buttons_use_status_chrome_fade(source, core_source)
if recovery_problem:
    print(f"FAIL: {recovery_problem}")
    raise SystemExit(1)
print("PASS: recovery buttons use status chrome fade")


def footer_restores_interrupted_fade(direct: str) -> str | None:
    if "restoreInterruptedFooterFade" not in direct:
        return "missing restoreInterruptedFooterFade"
    for fn, end in (("private func setFooterChromeVisible(", "private func setFooterLabelVisible("),
                    ("private func setFooterLabelVisible(", "private func setFooterNavigationText(")):
        body = direct[direct.index(fn):direct.index(end)]
        if "restoreInterruptedFooterFade" not in body:
            return f"{fn} must restore interrupted fade from presentation"
    helper = direct[direct.index("private func restoreInterruptedFooterFade("):]
    helper = helper[:helper.index("\n    }\n")]
    if "fadeViewOpacityFromPresentation" not in helper:
        return "restore helper must fade from presentation"
    return None

footer_restore_problem = footer_restores_interrupted_fade(source)
if footer_restore_problem:
    print(f"FAIL: {footer_restore_problem}")
    raise SystemExit(1)
print("PASS: footer restores interrupted fade from presentation")




def folder_open_defers_reveal_until_animate_open(direct: str) -> str | None:
    """show(folder) must not paint resting open chrome before animateOpen."""
    start = direct.index("    func show(folder: LauncherFolder, items: [PresentedItem])")
    end = direct.index("    /// A previously scrolled folder must not open", start)
    show_body = direct[start:end]
    for line in show_body.splitlines():
        code = line.split("//", 1)[0]
        if "isHidden = false" in code:
            return "show(folder) still reveals overlay before animateOpen"
    open_start = direct.index("    func animateOpen(collapse: LauncherLayout.FolderChromeCollapse)")
    open_end = direct.index("    func animateClose(", open_start)
    open_body = direct[open_start:open_end]
    if "isHidden = false" not in open_body:
        return "animateOpen does not reveal overlay with open chrome"
    if "fillMode = .backwards" not in open_body:
        return "animateOpen missing fillMode.backwards"
    return None

reveal_problem = folder_open_defers_reveal_until_animate_open(source)
if reveal_problem:
    print(f"FAIL: {reveal_problem}")
    raise SystemExit(1)
print("PASS: folder open defers reveal until animateOpen")


def folder_open_dismisses_visible_toast(direct: str, core: str) -> str | None:
    """A toast still on screen fades out when a folder starts opening."""
    if "shouldDismissToastWhenOpeningFolder" not in core:
        return "Core missing shouldDismissToastWhenOpeningFolder"
    if "shouldDismissToastWhenOpeningFolder" not in direct:
        return "Direct missing shouldDismissToastWhenOpeningFolder gate"
    start = direct.index("    private func openFolder(_ id: UUID)")
    end = direct.index("\n    private func ", start + 10)
    # openFolder is long — bound by next private func after a reasonable span
    # Prefer closing at setFolderBackdrop / animateOpen neighborhood via hideToast call
    body = direct[start:start + 2500]
    if "hideToast(animated: true)" not in body:
        return "openFolder must hideToast(animated:) when dismissing toast"
    if "isToastVisible: !toastView.isHidden" not in body:
        return "openFolder must pass toast visibility from toastView.isHidden"
    if "settleInterruptedPaging()" not in body:
        return "openFolder toast dismiss must stay after settleInterruptedPaging"
    # Ensure dismiss runs before animateOpen so veil and toast do not race oddly
    hide_at = body.find("hideToast(animated: true)")
    open_at = body.find("animateOpen")
    if hide_at < 0 or open_at < 0 or hide_at > open_at:
        return "toast dismiss must run before folder animateOpen"
    return None


toast_folder_problem = folder_open_dismisses_visible_toast(source, core_source)
if toast_folder_problem:
    print(f"FAIL: {toast_folder_problem}")
    raise SystemExit(1)
print("PASS: folder open dismisses visible toast")


def folder_chrome_defers_new_toast(direct: str, core: str) -> str | None:
    """New toasts wait until folder open/close chrome is quiet."""
    if "shouldPresentToastWhileFolderChromeQuiet" not in core:
        return "Core missing shouldPresentToastWhileFolderChromeQuiet"
    if "shouldPresentToastWhileFolderChromeQuiet" not in direct:
        return "Direct shouldPresentToastNow missing folder chrome quiet gate"
    start = direct.index("    private func shouldPresentToastNow()")
    end = direct.index("\n    ", start + 20)
    # bound the function body
    end = direct.index("\n    /// Shows a toast that was requested", start)
    body = direct[start:end]
    if "folderOpen: openedFolderID != nil" not in body:
        return "shouldPresentToastNow must pass openedFolderID"
    if "folderClosing: folderOverlay.isAnimatingClose" not in body:
        return "shouldPresentToastNow must pass isAnimatingClose"
    land = direct[
        direct.index("    private func finishFolderCloseChromeLand()"):
        direct.index("    private func finishFolderCloseChromeLand()") + 900
    ]
    if "applyDeferredToast()" not in land:
        return "finishFolderCloseChromeLand must applyDeferredToast after veil lands"
    # apply after updateSearchAdjacentChrome (folder quiet for adjacent too)
    adj = land.find("updateSearchAdjacentChrome()")
    toast = land.find("applyDeferredToast()")
    if adj < 0 or toast < 0 or toast < adj:
        return "applyDeferredToast must run after updateSearchAdjacentChrome on close land"
    return None


defer_toast_problem = folder_chrome_defers_new_toast(source, core_source)
if defer_toast_problem:
    print(f"FAIL: {defer_toast_problem}")
    raise SystemExit(1)
print("PASS: folder chrome defers new toast")



def settings_a11y_keyboard(core: str) -> str | None:
    st = open("Sources/Direct/SettingsWindowController.swift").read()
    for need in ("class SettingsWindow: NSWindow", "cancelOperation", "settingsEscapeClosesWindow",
                 "initialFirstResponder", "settingsMessageShouldAnnounce", "announcementRequested",
                 "settingsShouldMoveFocusAfterRestore", "makeFirstResponder(rescanButton)",
                 "恢复所选应用"):
        if need not in st:
            return f"settings missing {need}"
    if "SettingsWindow(" not in st:
        return "controller must build SettingsWindow"
    for need in ("settingsMessageShouldAnnounce", "settingsShouldMoveFocusAfterRestore", "settingsEscapeClosesWindow"):
        if need not in core:
            return f"Core missing {need}"
    return None

settings_problem = settings_a11y_keyboard(core_source)
if settings_problem:
    print(f"FAIL: {settings_problem}")
    raise SystemExit(1)
print("PASS: settings a11y labels + keyboard (Esc close, focus, announce)")


with tempfile.TemporaryDirectory(prefix="LaunchIcon-LandingTiming-") as directory:
    harness = Path(directory) / "main.swift"
    harness.write_text(header + methods + footer)
    executable = Path(directory) / "LandingTiming"
    core_sources = sorted((root / "Sources/Core").glob("*.swift"))
    subprocess.run(["swiftc", "-swift-version", "6", *map(str, core_sources),
                    str(harness), "-o", str(executable)], check=True)
    result = subprocess.run([str(executable)], check=False)
    sys.exit(result.returncode)

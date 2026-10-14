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
    func commitFolderLandingVisual(on layer: CALayer) {}
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
let reducedFade = reduced.item.view.layer!.animation(forKey: "folder-created") as? CABasicAnimation
let reducedFrom = (reducedFade?.fromValue as? NSNumber)?.doubleValue ?? -1
if reduced.deadlines != [0.12]
    || reducedFade?.keyPath != "opacity"
    || reducedFade?.fillMode != .backwards
    || reducedFrom != 0
    || reduced.item.view.layer!.opacity != 1 {
    print("FAIL: reduced motion from=\\(reducedFrom) fill=\\(reducedFade?.fillMode.rawValue ?? "nil") opacity=\\(reduced.item.view.layer!.opacity)")
    failures += 1
} else { print("PASS: reduced motion fades from hidden without a solid model") }
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
    """Reduced-motion whole-cell merge ends at opacity 0. That model write
    has to share the fade transaction, or the commit frame hides the icon."""
    start = text.index("    private func playMergeAnimation(")
    end = text.index("    private func materializedFolderItem(", start)
    body = text[start:end]
    branch = body.index("if prefersReducedMotion {")
    reduced = body[branch:body.index("\n            return\n", branch)]
    if "animator().alphaValue" in reduced:
        return "reduced merge fade still writes opacity through animator()"
    add = reduced.index('layer?.add(fade, forKey: "merge-reduced-fade")')
    opacity = reduced.rindex("layer?.opacity = 0", 0, add)
    begin = reduced.rindex("CATransaction.begin()", 0, opacity)
    commit = reduced.index("CATransaction.commit()", add)
    if "CATransaction.commit()" in reduced[begin:add]:
        return "reduced merge fade commits before the fade is attached"
    if "fillMode = .backwards" not in reduced:
        return "reduced merge fade does not hold the opacity on screen"
    if "presentation()?.opacity" not in reduced[:add]:
        return "reduced merge fade does not start from the opacity on screen"
    if not (begin < opacity < add < commit):
        return "reduced merge fade model and fade are not one transaction"
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
print("PASS: reduced merge fade shares the model transaction")
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

with tempfile.TemporaryDirectory(prefix="LaunchIcon-LandingTiming-") as directory:
    harness = Path(directory) / "main.swift"
    harness.write_text(header + methods + footer)
    executable = Path(directory) / "LandingTiming"
    core_sources = sorted((root / "Sources/Core").glob("*.swift"))
    subprocess.run(["swiftc", "-swift-version", "6", *map(str, core_sources),
                    str(harness), "-o", str(executable)], check=True)
    result = subprocess.run([str(executable)], check=False)
    sys.exit(result.returncode)

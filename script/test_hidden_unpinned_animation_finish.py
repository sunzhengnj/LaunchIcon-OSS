#!/usr/bin/env python3
"""Guard: a hidden window finishes an unpinned search, toast, launch, folder, or reorder animation.

Hide can run after the window is already ordered out. The hold path never
pins, so the wait flag stays false while the named animation is still
attached. applyDeferred finishes that one. Lookup reads an existing layer
and does not create one. Opening Settings does not grow a second copy.
Does not retune paging.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = "".join(p.read_text() for p in [root / "Sources/Direct/LauncherWindowController.swift", *sorted((root / "Sources/Direct").glob("LauncherWindowController+*.swift"))])
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


def body(source, signature, end_signature):
    start = source.index(signature)
    end = source.index(end_signature, start + len(signature))
    return source[start:end]


need("shouldFinishUnpinnedHiddenAnimation" in core, "Core missing shared hidden-animation gate")
need(
    "testUnpinnedHiddenAnimationFinishesOnlyWhenStillAttached" in tests,
    "Core test missing hidden-animation finish",
)
dissolved = body(
    core,
    "public static func shouldFinishUnpinnedDissolvedGridFade(",
    "public static func shouldHoldPageSlide(",
)
need(
    "shouldFinishUnpinnedHiddenAnimation" in dissolved,
    "dissolved-grid fade must use the shared hidden-animation gate",
)

sites = (
    (
        "search",
        "func applyDeferredSearchChrome()",
        "private func searchChromeFadeAnimationIsAttached()",
        "private func searchChromeFadeAnimationIsAttached()",
        "private func snapInFlightSearchChromeFadeForMotionChange()",
        "searchChromeFadeAnimationKey",
        "landSearchChrome()",
    ),
    (
        "toast",
        "func applyDeferredToastFade()",
        "func applyDeferredToast(",
        "private func toastFadeAnimationIsAttached()",
        "private func toastFadeKeys(",
        "toastFadeAnimationKey",
        "heldToastFade",
    ),
    (
        "launch",
        "func applyDeferredLaunchFeedback()",
        "func settlePageButtonHoverForDismissal()",
        "private func launchFeedbackAnimationIsAttached()",
        "func settlePageButtonHoverForDismissal()",
        "launchFeedbackAnimationKey",
        "CATransform3DIdentity",
    ),
)

prep = body(
    direct,
    "func prepareChromeForOpeningSettings()",
    "func cancelIconLoadsForSettingsWhileLauncherHidden()",
)
# The controller wrapper shares this name and sits above prepareChrome.
# Slice from the settings function itself.
prep_at = direct.index("private func prepareChromeForOpeningSettings()")
prep = direct[prep_at:direct.index("func cancelIconLoadsForSettingsWhileLauncherHidden()", prep_at)]

for label, apply_sig, apply_end, lookup_sig, lookup_end, key, finish_token in sites:
    apply = body(direct, apply_sig, apply_end)
    lookup = body(direct, lookup_sig, lookup_end)
    need("shouldFinishUnpinnedHiddenAnimation" in apply, f"{label} applyDeferred must ask the shared gate")
    need(key in lookup, f"{label} lookup must use the named key")
    need("wantsLayer = true" not in lookup, f"{label} lookup must not create a layer")
    need("view.layer?" in lookup or "tile.layer?" in lookup or "toastView.layer?" in lookup,
         f"{label} lookup must read an existing layer")
    need(finish_token in apply or finish_token in body(direct, apply_sig, lookup_end),
         f"{label} must finish the animation")
    for piece, name in ((apply, f"{label} applyDeferred"), (lookup, f"{label} lookup")):
        need(
            "showPage(" not in piece
            and "transitionToPage(" not in piece
            and "completePageTransition(" not in piece,
            f"{name} must not retune paging",
        )
    need(lookup_sig not in prep, f"prepareChrome must not look up the {label} animation")

need("shouldFinishUnpinnedHiddenAnimation" not in prep, "prepareChrome must not finish hidden animations")
need("showPage(" not in prep and "transitionToPage(" not in prep and "completePageTransition(" not in prep,
     "prepareChrome must not retune paging")

# FOLDER-CHROME-FINISH-WHEN-HIDDEN-01: an opening panel or a moving backdrop
# lands when the window is already hidden. A settled open folder is not closed.
need("FOLDER-CHROME-FINISH-WHEN-HIDDEN-01" in core, "Core missing folder-chrome marker")
need("func unpinnedFolderChromeFinish(" in core, "Core missing folder-chrome finish")
need("testUnpinnedFolderChromeFinishWhenHidden" in tests, "Core test missing folder-chrome finish")
chrome_policy = body(
    core,
    "public static func unpinnedFolderChromeFinish(",
    "public static func shouldHoldSearchChromeAnimation(",
)
need("return .commitOpen" in chrome_policy, "opening panel must land open")
need("return .commitCloseVisual" in chrome_policy, "unflagged close must hide without landing")
need("return .backdropOnly" in chrome_policy, "backdrop must be able to finish alone")
need("return .none" in chrome_policy, "settled chrome must be left alone")
need("closeFolder" not in chrome_policy and "currentPage" not in chrome_policy,
     "folder-chrome policy must not close the folder or change the page")
need("showPage(" not in chrome_policy and "transitionToPage(" not in chrome_policy
     and "completePageTransition(" not in chrome_policy,
     "folder-chrome policy must not retune paging")
# Closing keys win over opening keys, and a visible window returns first.
close_at = chrome_policy.index("if panelClosing")
open_at = chrome_policy.index("if panelOpening")
visible_at = chrome_policy.index("if isVisible || alreadyWaiting || isAnimatingClose")
need(visible_at < close_at < open_at, "hidden close must be decided before an open landing")

chrome_apply = body(direct, "func applyDeferredFolderChrome()", "private func unpinnedFolderChromeFinish()")
need("unpinnedFolderChromeFinish()" in chrome_apply, "applyDeferred must ask the folder-chrome gate")
need("case .commitOpen:" in chrome_apply, "applyDeferred must land an opening panel")
need("case .backdropOnly:" in chrome_apply, "applyDeferred must land a backdrop alone")
need("discardInFlightCloseChromeWithoutLanding()" in chrome_apply,
     "applyDeferred must hide an unflagged close without its landing callback")
need("closeFolder(" not in chrome_apply, "applyDeferred must not close the folder")
need("currentPage" not in chrome_apply, "applyDeferred must not change the page")
need("showPage(" not in chrome_apply and "transitionToPage(" not in chrome_apply
     and "completePageTransition(" not in chrome_apply,
     "applyDeferred folder chrome must not retune paging")
chrome_lookup = body(direct, "func inFlightPanelChrome()", "func freezeChromeForDismissal()")
need("wantsLayer = true" not in chrome_lookup, "panel lookup must not create a layer")
need("panel.layer?" in chrome_lookup and "dimmer.layer?" in chrome_lookup,
     "panel lookup must read an existing layer")
need("folderOpenFade" in chrome_lookup and "folderCloseFade" in chrome_lookup,
     "panel lookup must use the named keys")
chrome_discard = body(
    direct,
    "func discardInFlightCloseChromeWithoutLanding()",
    "private func pinPresentedPanelCorner()",
)
need("onChromeCloseLanded" not in chrome_discard, "hidden close must not run the landing callback")
need("closeFolder(" not in chrome_discard and "currentPage" not in chrome_discard,
     "hidden close must not close the folder or change the page")
need("unpinnedFolderChromeFinish" not in prep, "prepareChrome must not finish hidden folder chrome")
need("inFlightPanelChrome" not in prep, "prepareChrome must not look up folder chrome")

# REORDER-SLIDE-FINISH-WHEN-HIDDEN-01: ordered-out grids report no visible items.
need("REORDER-SLIDE-FINISH-WHEN-HIDDEN-01" in core, "Core missing reorder marker")
need("func shouldVisitReorderSlidesOutsideVisibleItems(" in core, "Core missing reorder visit gate")
need("func shouldFinishReorderSlideOnHiddenWindow(" in core, "Core missing reorder finish gate")
need("testUnpinnedReorderSlideFinishesWhenHidden" in tests, "Core test missing reorder finish")
reorder_settle = body(
    direct,
    "func settleReorderSlideForDismissal()",
    "func pinInFlightReorderSlides()",
)
need("shouldVisitReorderSlidesOutsideVisibleItems" in reorder_settle,
     "hidden reorder settle must walk cells the collection view no longer calls visible")
need("finishReorderSlideForHiddenWindow" in reorder_settle, "hidden reorder settle must stop the clock")
need("releaseHeldReorderSlides" in reorder_settle, "a visible window must still release only held slides")
need("showPage(" not in reorder_settle and "transitionToPage(" not in reorder_settle
     and "completePageTransition(" not in reorder_settle,
     "reorder settle must not retune paging")
reorder_clear = body(direct, "func clearReorderSlide(", "func reorderSlideTiles(")
need("reorderSlideTiles(in:" in reorder_clear, "clear must use the hidden-window tile walk")
need("showPage(" not in reorder_clear and "transitionToPage(" not in reorder_clear
     and "completePageTransition(" not in reorder_clear,
     "reorder clear must not retune paging")
reorder_walk = body(
    direct,
    "func reorderSlideTiles(",
    "func landInFlightReorderSlideForMotionChange()",
)
need("shouldVisitReorderSlidesOutsideVisibleItems" in reorder_walk, "walk must ask the visit gate")
need("wantsLayer" not in reorder_walk, "reorder walk must not create a layer")
need("visibleItems()" in reorder_walk, "a visible window must still use visible items")
need("showPage(" not in reorder_walk and "transitionToPage(" not in reorder_walk
     and "completePageTransition(" not in reorder_walk,
     "reorder walk must not retune paging")
need("shouldFinishReorderSlideOnHiddenWindow" not in prep, "prepareChrome must not finish hidden reorder slides")
need("finishReorderSlideForHiddenWindow" not in prep, "prepareChrome must not walk hidden reorder slides")

# CHROME-OPACITY-FADE-FINISH-WHEN-HIDDEN-01 / PAGE-INDICATOR-FADE-FINISH-WHEN-HIDDEN-01
# Page-dot visibility, footer hints, and status chrome are not deferred slots.
# A hidden window lands the opacity already stored on the model. A text swap
# that is still clear keeps its completion. Dot weight and page turns stay put.
need("CHROME-OPACITY-FADE-FINISH-WHEN-HIDDEN-01" in core, "Core missing chrome-opacity marker")
need("func unpinnedOpacityFadeLanding(" in core, "Core missing chrome-opacity landing")
need("testUnpinnedOpacityFadeLandsWhenHidden" in tests, "Core test missing chrome-opacity landing")
landing = body(
    core,
    "public static func unpinnedOpacityFadeLanding(",
    "public static func shouldFinishUnpinnedDissolvedGridFade(",
)
need("shouldFinishUnpinnedHiddenAnimation" in landing, "chrome landing must use the shared gate")
need("return .hiddenParked" in landing, "a clear model must be able to park hidden")
need("return .leave" in landing, "a visible window or a text dip must be left alone")
need("return .shown" in landing, "a shown model must land visible")
need("showPage(" not in landing and "transitionToPage(" not in landing
     and "completePageTransition(" not in landing and "visualWeight" not in landing,
     "chrome landing must not retune paging or dot weight")

apply_state = body(direct, "func applyDeferredVisualState()", "private func applyDeferredVisualSlot(")
need("finishUnpinnedHiddenChromeFades()" in apply_state, "applyDeferred must finish hidden chrome fades")
need("showPage(" not in apply_state and "transitionToPage(" not in apply_state
     and "completePageTransition(" not in apply_state,
     "applyDeferred must not retune paging")

chrome = body(
    direct,
    "private func finishUnpinnedHiddenChromeFades()",
    "private func applyDeferredVisualSlot(",
)
need("finishUnpinnedHiddenFade(windowVisible:" in chrome, "chrome finish must land page dots")
need("parkHiddenWhenClear: true" in chrome, "single-purpose fades must park when clear")
need("parkHiddenWhenClear: false" in chrome, "text swaps must keep a clear-model completion")
need("navigationHintLabel" in chrome, "navigation hint is the text-swap exception")
need("pageIndicatorFadeAnimationKey" in chrome or "finishUnpinnedHiddenFade" in chrome,
     "page dots must use their own fade key")
need("wantsLayer =" not in chrome, "chrome finish must not create a layer")
need("pinWeightAnimation" not in chrome and "animateSelection" not in chrome
     and "startWeightAnimation" not in chrome,
     "chrome finish must not move page-dot weight")
need("showPage(" not in chrome and "transitionToPage(" not in chrome
     and "completePageTransition(" not in chrome,
     "chrome finish must not retune paging")
need("finishUnpinnedHiddenChromeFades" not in prep, "prepareChrome must not finish hidden chrome fades")
need("finishUnpinnedHiddenFade" not in prep, "prepareChrome must not finish the page-dot fade")
need("finishUnpinnedTileChromeFills" in chrome, "chrome finish must land tile focus fills")
need("finishUnpinnedHiddenTitleUnderline" in chrome, "chrome finish must land the folder-title underline")
need("tileChromeFillFadeAnimationKey" not in prep and "folderTitleEditUnderlineFadeAnimationKey" not in prep,
     "prepareChrome must not finish the tile fill or the title underline")

tile_fill = body(
    direct,
    "func finishUnpinnedHiddenChromeFill(windowVisible:",
    "func setOpenFlightContentHidden(",
)
need("unpinnedTileChromeFillLanding" in tile_fill, "tile fill must ask the landing gate")
need("tileChromeFillFadeAnimationKey" in tile_fill, "tile fill must remove its named fade")
need("layer.backgroundColor = nil" in tile_fill, "a clear tile fill must drop the white well")
need("wantsLayer" not in tile_fill, "tile fill lookup must not create a layer")
need("showPage(" not in tile_fill and "transitionToPage(" not in tile_fill
     and "completePageTransition(" not in tile_fill,
     "tile fill finish must not retune paging")

underline = body(
    direct,
    "func finishUnpinnedHiddenEditUnderline(windowVisible:",
    "override var acceptsFirstResponder: Bool {",
)
need("shouldFinishUnpinnedHiddenAnimation" in underline, "title underline must use the shared gate")
need("folderTitleEditUnderlineFadeAnimationKey" in underline, "title underline must remove its named fade")
need("wantsLayer" not in underline, "title underline finish must not create a layer")
need("closeFolder(" not in underline and "currentPage" not in underline,
     "title underline finish must not close the folder or change the page")
need("showPage(" not in underline and "transitionToPage(" not in underline
     and "completePageTransition(" not in underline,
     "title underline finish must not retune paging")
need("TILE-CHROME-FILL-FINISH-WHEN-HIDDEN-01" in core, "Core missing tile-fill marker")
need("func unpinnedTileChromeFillLanding(" in core, "Core missing tile-fill landing")
need("testUnpinnedTileChromeFillLandsWhenHidden" in tests, "Core test missing tile-fill landing")
need("FOLDER-TITLE-UNDERLINE-FINISH-WHEN-HIDDEN-01" in direct, "Direct missing title-underline marker")

# LAUNCHER-PRESENCE-FINISH-WHEN-HIDDEN-01: instant hide leaves the model fully
# shown. A hidden window never pinned launcherFade / launcherRise.
need("LAUNCHER-PRESENCE-FINISH-WHEN-HIDDEN-01" in core, "Core missing presence marker")
need("func unpinnedLauncherPresenceLanding(" in core, "Core missing presence landing")
need("testUnpinnedLauncherPresenceLandsRestingShownWhenHidden" in tests, "Core test missing presence landing")
presence = body(
    core,
    "public static func unpinnedLauncherPresenceLanding(",
    "public static func shouldDropInFlightDragLift(",
)
need("shouldFinishUnpinnedHiddenAnimation" in presence, "presence landing must use the shared gate")
need("return .restingShown" in presence, "an attached fade must rest fully shown")
need("return .leave" in presence, "a visible window must keep playing")
need("showPage(" not in presence and "transitionToPage(" not in presence
     and "completePageTransition(" not in presence,
     "presence landing must not retune paging")
presence_apply = body(
    direct,
    "private func finishUnpinnedLauncherPresence(windowVisible:",
    "func refreshDesktopBackgroundForPictureChange()",
)
need("unpinnedLauncherPresenceLanding" in presence_apply, "presence finish must ask the landing gate")
need("launcherPresenceFadeAnimationKey" in presence_apply, "presence finish must remove the fade")
need("launcherPresenceRiseAnimationKey" in presence_apply, "presence finish must remove the rise")
need("CATransform3DIdentity" in presence_apply, "presence finish must rest the card")
need("wantsLayer" not in presence_apply, "presence finish must not create a layer")
need("showPage(" not in presence_apply and "transitionToPage(" not in presence_apply
     and "completePageTransition(" not in presence_apply,
     "presence finish must not retune paging")
need("finishUnpinnedLauncherPresence(windowVisible:" in chrome, "applyDeferred chrome pass must finish presence")
need("finishUnpinnedLauncherPresence" not in prep, "prepareChrome must not finish hidden presence")

# PREVIEW-PLATE-CLOCK-FINISH-WHEN-HIDDEN-01: the close cleared the open folder,
# so the panel commit does not see this display link.
need("PREVIEW-PLATE-CLOCK-FINISH-WHEN-HIDDEN-01" in core, "Core missing plate-clock marker")
need("func unpinnedPreviewPlateFinish(" in core, "Core missing plate-clock finish")
need("testUnpinnedPreviewPlateClockLandsWhenHidden" in tests, "Core test missing plate-clock finish")
plate = body(
    core,
    "public static func unpinnedPreviewPlateFinish(",
    "public static func folderChromeTravelProgress(",
)
need("return .landReturning" in plate, "a returning plate must land solid")
need("return .landYielding" in plate, "a yielding plate must hide")
need("return .leave" in plate, "a visible window must keep the clock")
need("closeFolder(" not in plate and "currentPage" not in plate,
     "plate finish must not close the folder or change the page")
need("showPage(" not in plate and "transitionToPage(" not in plate
     and "completePageTransition(" not in plate,
     "plate finish must not retune paging")
plate_apply = body(
    direct,
    "private func finishUnpinnedPreviewPlateClock(windowVisible:",
    "private func stopPreviewPlateReturnTicker()",
)
need("unpinnedPreviewPlateFinish" in plate_apply, "plate finish must ask the gate")
need("releaseBorrowedPreviewPlate()" in plate_apply, "returning must draw the plate solid")
need("finishPreviewPlateYield(" in plate_apply, "yielding must hide the plate")
need("closeFolder(" not in plate_apply and "currentPage" not in plate_apply,
     "plate finish must not close the folder or change the page")
need("showPage(" not in plate_apply and "transitionToPage(" not in plate_apply
     and "completePageTransition(" not in plate_apply,
     "plate finish must not retune paging")
need("finishUnpinnedPreviewPlateClock(windowVisible:" in chrome, "applyDeferred chrome pass must finish the plate clock")
need("finishUnpinnedPreviewPlateClock" not in prep, "prepareChrome must not finish the hidden plate clock")

# FOLDER-LANDING-FINISH-WHEN-HIDDEN-01 /
# MERGE-PLATE-AND-OVERFLOW-FINISH-WHEN-HIDDEN-01.
# A dropped token leaves folder-created attached. A nil plate pointer
# leaves the merge-plate fade. Overflow only drops its named fade.
need("FOLDER-LANDING-FINISH-WHEN-HIDDEN-01" in core, "Core missing folder-landing marker")
need("MERGE-PLATE-AND-OVERFLOW-FINISH-WHEN-HIDDEN-01" in core, "Core missing merge-plate marker")
need("func unpinnedTileFlightFinish(" in core, "Core missing tile-flight finish")
need("testUnpinnedTileFlightFinishesWhenHidden" in tests, "Core test missing tile-flight finish")
need('public static let folderCreatedAnimationKey = "folder-created"' in core, "folder-created key drifted")
need('public static let folderCreatedOpacityAnimationKey = "folder-created-opacity"' in core, "folder-created opacity key drifted")
need('public static let folderMergePlateAnimationKey = "folder-merge-plate"' in core, "merge-plate key drifted")
need('public static let folderMergePlateScaleAnimationKey = "folder-merge-plate-scale"' in core, "merge-plate scale key drifted")
flight = body(
    core,
    "public static func unpinnedTileFlightFinish(",
    "public static func shouldFinishUnpinnedDissolvedGridFade(",
)
need("shouldFinishUnpinnedHiddenAnimation" in flight, "tile flight must use the shared gate")
need("return .commitShown" in flight, "a hidden landing or plate must show")
need("return .removeNamedFade" in flight, "overflow must only drop the named fade")
need("return .leave" in flight, "a visible window must keep playing")
need("closeFolder(" not in flight and "currentPage" not in flight,
     "tile flight policy must not close the folder or change the page")
need("showPage(" not in flight and "transitionToPage(" not in flight
     and "completePageTransition(" not in flight,
     "tile flight policy must not retune paging")
need('layer.add(scale, forKey: "folder-created")' in direct, "folder-created must still be added under its key")
need('layer.add(reveal, forKey: "folder-created-opacity")' in direct, "folder-created opacity must still be added under its key")
need('layer.add(fade, forKey: "folder-merge-plate")' in direct, "merge plate must still be added under its key")
need('layer.add(grow, forKey: "folder-merge-plate-scale")' in direct, "merge plate scale must still be added under its key")
flights = body(
    direct,
    "private func finishUnpinnedHiddenFolderTileFlights(windowVisible:",
    "private func applyDeferredVisualSlot(",
)
need("unpinnedTileFlightFinish" in flights, "tile flight finish must ask the gate")
need("folderCreatedAnimationKey" in flights, "folder landing must remove the scale key")
need("folderCreatedOpacityAnimationKey" in flights, "folder landing must remove the opacity key")
need("folderMergePlateAnimationKey" in flights, "merge plate must remove the fade key")
need("folderMergePlateScaleAnimationKey" in flights, "merge plate must remove the scale key")
need("folderOverflowOpenFadeAnimationKey" in flights, "overflow must remove its named fade")
need('setValue(nil, forKey: "folderLandingToken")' in flights, "folder landing must clear the token so the later timer no-ops")
need("forgetTrackedFolderLanding" in flights, "folder landing must drop the held entry")
need("layer.opacity = 1" in flights and "CATransform3DIdentity" in flights,
     "a landing or plate must land fully shown")
need("wantsLayer" not in flights, "tile flight finish must not create a layer")
need("closeFolder(" not in flights and "currentPage" not in flights,
     "tile flight finish must not close the folder or change the page")
need("showPage(" not in flights and "transitionToPage(" not in flights
     and "completePageTransition(" not in flights,
     "tile flight finish must not retune paging")
overflow = body(
    direct,
    "private func finishUnpinnedOverflowOpenFade(on view:",
    "private func applyDeferredVisualSlot(",
)
need("removeNamedFade" in overflow, "overflow finish must remove the named fade only")
need("opacity = 1" not in overflow, "overflow finish must not rewrite alpha")
need("CATransform3DIdentity" not in overflow, "overflow finish must not rewrite the transform")
need("finishUnpinnedHiddenFolderTileFlights(windowVisible:" in chrome,
     "applyDeferred chrome pass must finish leftover tile flights")
need("finishUnpinnedHiddenFolderTileFlights" not in prep, "prepareChrome must not finish hidden tile flights")
need("unpinnedTileFlightFinish" not in prep, "prepareChrome must not grow a tile-flight gate")

# PAGE-ARROW-PRESENCE-FINISH-WHEN-HIDDEN-01. The fade-out completion hides
# the button. A hide after orderOut never pins, so that completion can still
# run after the next show. A clear model hides now. A shown model only drops
# the named fade. Pinning during a visible dismiss also drops the completion.
need("PAGE-ARROW-PRESENCE-FINISH-WHEN-HIDDEN-01" in core, "Core missing page-arrow presence marker")
need("func unpinnedPageArrowPresenceLanding(" in core, "Core missing page-arrow presence landing")
need("testUnpinnedPageArrowPresenceLandsWhenHidden" in tests, "Core test missing page-arrow presence landing")
arrow = body(
    core,
    "public static func unpinnedPageArrowPresenceLanding(",
    "public static func shouldFinishUnpinnedDissolvedGridFade(",
)
need("shouldFinishUnpinnedHiddenAnimation" in arrow, "page-arrow presence must use the shared gate")
need("return .hideUnavailable" in arrow, "a clear model must hide the arrow")
need("return .dropOpacity" in arrow, "a shown model must only drop the fade")
need("return .leave" in arrow, "a visible window must keep playing")
need("showPage(" not in arrow and "transitionToPage(" not in arrow
     and "completePageTransition(" not in arrow and "visualWeight" not in arrow
     and "movePage(" not in arrow,
     "page-arrow presence policy must not retune paging")
arrow_apply = body(
    direct,
    "private func finishUnpinnedPageArrowPresence()",
    "private var holdingHoverFade:",
)
need("unpinnedPageArrowPresenceLanding" in arrow_apply, "page-arrow finish must ask the landing gate")
need("pageArrowPresenceAnimationKey" in arrow_apply, "page-arrow finish must remove the named fade")
need("presenceGeneration &+= 1" in arrow_apply, "page-arrow finish must drop the hide completion")
need("isHidden = true" in arrow_apply, "a clear model must hide the arrow")
need("wantsLayer" not in arrow_apply, "page-arrow finish must not create a layer")
need("showPage(" not in arrow_apply and "transitionToPage(" not in arrow_apply
     and "completePageTransition(" not in arrow_apply and "movePage(" not in arrow_apply,
     "page-arrow finish must not retune paging")
need("finishUnpinnedPageArrowPresence()" in direct, "hidden hover settle must finish page-arrow presence")
pin = body(direct, "private func pinHoverFade()", "private func animatePresence(")
need("presenceGeneration &+= 1" in pin, "pinning the arrow must drop the presence completion")
need("showPage(" not in pin and "transitionToPage(" not in pin
     and "completePageTransition(" not in pin and "movePage(" not in pin,
     "pinning the arrow must not retune paging")
need("unpinnedPageArrowPresenceLanding" not in prep, "prepareChrome must not finish page-arrow presence")
need("finishUnpinnedPageArrowPresence" not in prep, "prepareChrome must not finish page-arrow presence")

dots = body(direct, "func finishUnpinnedHiddenFade(windowVisible:", "func pinWeightAnimation(")
need("pageIndicatorFadeAnimationKey" in dots, "page dots must remove their named fade")
need("parkHiddenWhenClear: true" in dots, "page dots park a clear model")
need("wantsLayer" not in dots, "page-dot lookup must not create a layer")
need("rebuildSlots" not in dots, "page-dot finish must not rebuild the strip")
need("pinWeightAnimation" not in dots and "visualWeight" not in dots
     and "animateSelection" not in dots,
     "page-dot finish must not move weight")
need("showPage(" not in dots and "transitionToPage(" not in dots
     and "completePageTransition(" not in dots,
     "page-dot finish must not retune paging")

# HIDE-SETTLE-REGISTRY-01: hide settles and hidden chrome finishes walk Core
# order lists instead of a handwritten call sequence.
need("enum DismissalSettleSlot" in core, "Core missing DismissalSettleSlot")
need("dismissalSettleOrder" in core, "Core missing dismissalSettleOrder")
need("enum HiddenChromeFinishSlot" in core, "Core missing HiddenChromeFinishSlot")
need("hiddenChromeFinishOrder" in core, "Core missing hiddenChromeFinishOrder")
need("testDismissalSettleOrderMatchesHistoricalRegistry" in tests, "Core test missing dismissal settle order")
need("testHiddenChromeFinishOrderMatchesHistoricalRegistry" in tests, "Core test missing hidden chrome finish order")
settle_helper = body(direct, "func settleInFlightVisualsForDismissal()", "func settleToastFadeForDismissal()")
need("for slot in LauncherLayout.dismissalSettleOrder" in settle_helper, "hide settle must walk the Core registry")
need("applyDismissalSettleSlot(" in settle_helper, "hide settle must dispatch through the registry")
for token in (
    "settleReorderSlideForDismissal()",
    "settleFolderLandingForDismissal()",
    "settleMergeFlightForDismissal()",
    "settleDropLandingForDismissal()",
    "settleFolderChromeForDismissal()",
    "settleSearchChromeForDismissal()",
    "settleDissolvedGridFadeForDismissal()",
    "settleLaunchFeedbackForDismissal()",
    "settlePageButtonHoverForDismissal()",
    "settleToastFadeForDismissal()",
):
    need(token in settle_helper, f"hide settle registry missing {token}")
need("showPage(" not in settle_helper and "transitionToPage(" not in settle_helper
     and "completePageTransition(" not in settle_helper,
     "hide settle registry must not retune paging")
need("for slot in LauncherLayout.hiddenChromeFinishOrder" in chrome,
     "hidden chrome finish must walk the Core registry")
need("finishUnpinnedHiddenChromeSlot(" in chrome, "hidden chrome finish must dispatch through the registry")

# HIDDEN-FINISH-REGISTRY-01 stage 1: register opacity fades at layer.add,
# keep the explicit landers, drain leftovers afterwards.
need("HIDDEN-FINISH-REGISTRY-01" in core, "Core missing hidden-finish registry marker")
need("enum HiddenFinishPolicy" in core, "Core missing HiddenFinishPolicy")
need("func hiddenFinishStage1Policy(" in core, "Core missing stage-1 policy gate")
need("func hiddenFinishLanding(" in core, "Core missing stage-1 landing helper")
need("testHiddenFinishStage1PolicyCoversOnlyOpacityFadeKeys" in tests,
     "Core test missing stage-1 policy coverage")
need("toastFadeAnimationKey" in body(
    tests,
    "func testHiddenFinishStage1PolicyCoversOnlyOpacityFadeKeys()",
    "func testUnpinnedTileChromeFillLandsWhenHidden()",
), "stage-1 policy test must reject toast fades")
need("class HiddenFinishTable" in direct, "Direct missing add-time hidden-finish table")
need("weak var view: NSView?" in direct and "weak var layer: CALayer?" in direct,
     "hidden-finish records must not retain views or layers")
need("onHiddenFinishRegister" in direct and "onHiddenFinishUnregister" in direct,
     "page indicator must register through the controller-owned table")
need("hiddenFinishTable.register" in direct, "controller must own the hidden-finish table")
need("onFadeAdded?(view, key)" in body(
    direct,
    "private func fadeViewOpacityFromPresentation(",
    "private func fadeStage1OpacityFromPresentation(",
), "fade helper must stay probe-safe and only invoke an optional add callback")
need("registerStage1HiddenFinish(on: view, key: key)" in body(
    direct,
    "private func fadeStage1OpacityFromPresentation(",
    "func animateViewFrameFromPresentation(",
), "stage-1 opacity wrapper must register at layer.add")
need(direct.count("fadeStage1OpacityFromPresentation(") >= 10,
     "stage-1 wrapper must be used at footer/status add sites")
need("fadeStage1OpacityFromPresentation(" not in body(
    direct,
    "func applyDeferredToastFade()",
    "func applyDeferredToast(",
), "toast must not register as a stage-1 opacity fade")
need("onHiddenFinishRegister?(" in body(
    direct,
    "private func animateVisibility(",
    "private func setOpacityWithoutAnimation(",
) and "layer.add(fade, forKey: LauncherLayout.pageIndicatorFadeAnimationKey)" in body(
    direct,
    "private func animateVisibility(",
    "private func setOpacityWithoutAnimation(",
), "page-indicator visibility fade must register at layer.add")
need("finishRegisteredStage1OpacityFades(windowVisible: visible)" in chrome,
     "hidden chrome finish must drain registered opacity leftovers")
need("for slot in LauncherLayout.hiddenChromeFinishOrder" in chrome
     and chrome.index("for slot in LauncherLayout.hiddenChromeFinishOrder")
     < chrome.index("finishRegisteredStage1OpacityFades(windowVisible: visible)"),
     "explicit hidden chrome landers must run before the leftover drain")
need("pageIndicator.finishUnpinnedHiddenFade(windowVisible:" in body(
    direct,
    "private func finishRegisteredStage1OpacityFades(",
    "private func finishUnpinnedTileChromeFills(",
), "opacity leftover drain must reuse the page-indicator lander")
need("applyUnpinnedOpacityFade(" in body(
    direct,
    "private func finishRegisteredStage1OpacityFades(",
    "private func finishUnpinnedTileChromeFills(",
), "opacity leftover drain must reuse the existing opacity lander")
need("func shouldUnregisterHiddenFinishRecord(" in core,
     "Core missing finished hidden-finish unregister policy")
need("shouldUnregisterHiddenFinishRecord(animationStillAttached:" in body(
    direct,
    "private func finishRegisteredStage1OpacityFades(",
    "private func finishUnpinnedTileChromeFills(",
), "leftover drain must drop finished records, including after the page-indicator lander")
need("unregister(view: record.view, layer: layer, key: key)" in body(
    direct,
    "private func finishRegisteredStage1OpacityFades(",
    "private func finishUnpinnedTileChromeFills(",
), "leftover drain must unregister by layer when the view is already gone")
need("func unregister(view: NSView?, layer: CALayer?, key: String)" in direct,
     "hidden-finish table must unregister a view-less finished record by layer")
need("wantsLayer" not in body(
    direct,
    "private func finishRegisteredStage1OpacityFades(",
    "private func finishUnpinnedTileChromeFills(",
), "leftover drain must not create a layer")
need("showPage(" not in body(
    direct,
    "private func finishRegisteredStage1OpacityFades(",
    "private func finishUnpinnedTileChromeFills(",
) and "transitionToPage(" not in body(
    direct,
    "private func finishRegisteredStage1OpacityFades(",
    "private func finishUnpinnedTileChromeFills(",
) and "completePageTransition(" not in body(
    direct,
    "private func finishRegisteredStage1OpacityFades(",
    "private func finishUnpinnedTileChromeFills(",
), "leftover drain must not retune paging")
need("closeFolder(" not in body(
    direct,
    "private func finishRegisteredStage1OpacityFades(",
    "private func finishUnpinnedTileChromeFills(",
) and "currentPage" not in body(
    direct,
    "private func finishRegisteredStage1OpacityFades(",
    "private func finishUnpinnedTileChromeFills(",
), "leftover drain must not close a folder or change the page")

# REALIZED-GRID-TILES-WEAK-SET-01: no full view-tree walk.
realized = body(direct, "func realizedGridTiles() -> [AppGridTileView]", "private func finishAttachedLaunchFeedback()")
need("AppGridTileView.realizedTiles" in realized, "realizedGridTiles must read the weak tile set")
need("isDescendant(of:" in realized, "realizedGridTiles must stay scoped to the four collections")
need("func walk(" not in realized and "for subview in view.subviews" not in realized,
     "realizedGridTiles must not walk the view tree")
need("activeCollectionView" in realized and "stagingCollectionView" in realized
     and "searchCollectionView" in realized and "folderOverlay.collectionView" in realized,
     "realizedGridTiles must still cover the four collection roots")
need("NSHashTable<AppGridTileView>.weakObjects()" in direct, "tiles must register in a weak set")
need("viewDidMoveToSuperview()" in direct, "tiles must register when they gain a superview")
need("showPage(" not in realized and "transitionToPage(" not in realized
     and "completePageTransition(" not in realized,
     "realizedGridTiles must not retune paging")

if failures:
    for item in failures:
        print("FAIL:", item)
    sys.exit(1)
print("PASS: hidden window finishes unpinned search, toast, launch, folder chrome, reorder slides, chrome opacity fades, tile focus fills, the folder-title underline, launcher presence, the preview-plate clock, folder landings, merge plates, overflow fades, and page-arrow presence")
print("PASS: hide-settle registry and realizedGridTiles weak set")

#!/usr/bin/env python3
"""Static guard for secondary-display layout refresh (DISPLAY-SECONDARY-LAYOUT-01)."""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = "".join(p.read_text() for p in [ROOT / "Sources/Direct/LauncherWindowController.swift", *sorted((ROOT / "Sources/Direct").glob("LauncherWindowController+*.swift"))])
CORE = (ROOT / "Sources/Core/LauncherLayout.swift").read_text()
TESTS = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
fail = []

def need(cond, msg):
    if not cond:
        fail.append(msg)

def method_body(src, signature):
    start = src.index(signature)
    rest = src[start + len(signature):]
    nxt = re.search(r"\n    (?:@[A-Za-z]+(?:\([^)]*\))? )*(?:private |override |func )", rest)
    end = start + len(signature) + (nxt.start() if nxt else len(rest))
    return src[start:end]

# Core helpers exist
for name in (
    "launcherWindowFrame",
    "shouldInvalidateGridViewportCacheOnScreenChange",
    "shouldUpdateGridMetrics",
    "shouldReloadDesktopBackgroundImage",
    "desktopBackgroundMaximumPixelSize",
    "desktopBackgroundLayerContentsScale",
    "shouldInstallDecodedDesktopBackground",
    "shouldRefreshVisibleScreenGeometry",
    "shouldDeferVisibleScreenGeometry",
    "shouldApplyDeferredVisibleScreenGeometry",
    "shouldDropDeferredVisibleScreenGeometry",
    "shouldScheduleDeferredVisibleScreenGeometryApply",
    "shouldPauseDeferredVisibleScreenGeometryApply",
    "shouldHoldVisibleScreenGeometryForMissingScreen",
    "shouldInstallHeldDesktopBackgroundOnAppearance",
    "shouldForgetFailedDesktopBackgroundRequest",
    "shouldRetryDesktopBackgroundAfterFailedDecode",
    "shouldStartDesktopBackgroundDecodeRetry",
    "desktopBackgroundAppearanceIdentity",
    "desktopBackgroundAppearanceIndices",
    "desktopBackgroundImageIndex",
    "desktopBackgroundDescriptorThumbnailPath",
    "desktopBackgroundImageURLToDecode",
    "desktopBackgroundAppearanceVariantURL",
    "shouldUseDesktopBackgroundAppearanceVariant",
    "shouldRefreshDesktopBackgroundForPictureChange",
):
    need(f"public static func {name}" in CORE, f"Core missing {name}")

need("testSecondaryDisplayLayoutInvalidatesViewportAndWallpaper" in TESTS, "Core test missing")
need("testDesktopBackgroundUsesAppearanceFrame" in TESTS, "Core appearance-frame test missing")
need("testDesktopBackgroundDescriptorUsesThumbnail" in TESTS, "Core madesktop thumbnail test missing")

# DISPLAY-TARGET-01 still intact
m = re.search(r"func launcherScreen\(for window: NSWindow, appearing: Bool\).*?\n    \}\n", SRC, re.S)
body = m.group(0) if m else ""
need(bool(body), "missing launcherScreen")
need("guard displayTarget != .active else { return fallback }" in body, "DISPLAY-TARGET-01 active fallback")
need("guard appearing else { return window.screen ?? fallback }" in body, "DISPLAY-TARGET-01 visible no-jump")

# show() wiring
need("let screen = launcherScreen(for: window, appearing: appearing)" in SRC, "show() screen resolve")
need("let targetFrame = Self.frame(for: screen?.frame" in SRC, "show() uses target screen.frame")
need("contentView.setFrameSize(contentSize)" in SRC, "show() syncs contentView size")
need("applyScreenGeometryForPresentation()" in SRC, "show() forces geometry refresh")
need("shouldInvalidateGridViewportCacheOnScreenChange" in SRC, "show() uses Core screen-change gate")

# layout + wallpaper
need("shouldUpdateGridMetrics(" in SRC, "layout() uses Core metrics gate")
need("viewportMetricsDirty" in SRC, "geometry dirty flag")
need("lastDesktopBackgroundScreenSize" in SRC, "wallpaper tracks screen size")
need("lastDesktopBackgroundBackingScale" in SRC, "wallpaper tracks backing scale")
need("shouldReloadDesktopBackgroundImage(" in SRC, "wallpaper uses Core reload gate")
need("desktopBackgroundMaximumPixelSize(" in SRC, "thumbnail uses pixel size, not points")
need("shouldInstallDecodedDesktopBackground(" in SRC, "decode completion checks screen size and scale")
need("previousBackingScale: lastPresentedBackingScale" in SRC, "show() invalidates viewport when scale changes")
need("deferredDesktopBackgroundBackingScale" in SRC, "deferred wallpaper remembers its scale")
need("WALLPAPER-SCALE-STALE-01" in SRC, "scale stale-apply tag")
need("WALLPAPER-LAYER-SCALE-01" in SRC, "layer contentsScale tag")
need("desktopBackgroundLayerContentsScale(backingScale:" in SRC, "install uses Core layer scale")
need("contentsScale = 1" not in SRC, "wallpaper layer must not hardcode 1x contentsScale")
need("VISIBLE-SCREEN-GEOMETRY-01" in SRC, "visible screen geometry tag")
need("func refreshVisibleScreenGeometry()" in SRC, "visible screen refresh method")
need("didChangeScreenParametersNotification" in SRC, "listens for display reconfiguration")
need("shouldRefreshVisibleScreenGeometry(" in SRC, "refresh gate is Core")
need("shouldDeferVisibleScreenGeometry(" in SRC, "paging deferral gate is Core")
need("deferScreenGeometryRefreshUntilPagingEnds()" in SRC, "paging defers the refresh")
need("scheduleDeferredScreenGeometryRefreshIfIdle()" in SRC, "layout applies a deferred refresh")
need("VISIBLE-SCREEN-GEOMETRY-DEFER-APPLY-01" in SRC, "deferred apply tag")
need("armDeferredScreenGeometryRetry()" in SRC, "paging deferral arms a retry outside layout")
need("shouldApplyDeferredVisibleScreenGeometry(" in CORE, "Core apply gate")
need("shouldDropDeferredVisibleScreenGeometry(" in CORE, "Core drop gate")
need("shouldScheduleDeferredVisibleScreenGeometryApply(" in CORE, "Core schedule gate")
need("shouldPauseDeferredVisibleScreenGeometryApply(" in CORE, "Core pause gate")
need("pauseDeferredScreenGeometryApplyUntilNextNotification()" in SRC,
     "missing screen pauses layout retries")
need("resumeDeferredScreenGeometryApplyScheduling()" in SRC,
     "the next display notification resumes scheduling")
need("deferredVisibleScreenGeometryRetryDelay" in SRC, "retry uses the Core interval")
need("hasDeferredScreenGeometryRefresh" in SRC, "root exposes the deferred flag")
need("clearDeferredScreenGeometryRefresh()" in SRC, "apply and drop clear the flag")
refresh_at = SRC.index("func refreshVisibleScreenGeometry()")
refresh_body = SRC[refresh_at:SRC.index("func clearSelectionBeforeOpeningSettings()", refresh_at)]
need("window.screen" in refresh_body, "visible refresh stays on the window's screen")
for banned in ("showPage(", "movePage(", "transitionToPage(", "completePageTransition(", "scrollToPage"):
    need(banned not in refresh_body, f"visible screen refresh must not page ({banned})")
schedule_at = SRC.index("func scheduleDeferredScreenGeometryRefreshIfIdle()")
schedule_body = SRC[schedule_at:SRC.index("var blocksScreenGeometryRefresh", schedule_at)]
for banned in ("showPage(", "movePage(", "transitionToPage(", "completePageTransition("):
    need(banned not in schedule_body, f"deferred screen refresh must not page ({banned})")
need("screenGeometryRefreshDeferred = false" not in schedule_body,
     "layout must not drop a held screen refresh before refresh runs")
need("shouldScheduleDeferredVisibleScreenGeometryApply(" in schedule_body,
     "layout schedules through the Core gate")
need("shouldPauseDeferredVisibleScreenGeometryApply(" in refresh_body,
     "a missing screen keeps the held refresh without spinning")
need("shouldHoldVisibleScreenGeometryForMissingScreen(" in refresh_body,
     "a fresh change with no screen is held, not dropped")
need("deferScreenGeometryRefreshUntilPagingEnds()" in refresh_body,
     "holding a missing screen sets the deferred mark")
need("armMissingScreenGeometryFollowUpIfNeeded()" in refresh_body,
     "a missing screen looks once more on the next turn")
need("missingScreenFollowUpIsRunning" in SRC,
     "the follow-up does not arm another look")
need("WALLPAPER-APPEARANCE-01" in SRC, "appearance wallpaper tag")
need("lastDesktopBackgroundAppearance" in SRC, "wallpaper tracks light/dark")
need("deferredDesktopBackgroundAppearance" in SRC, "deferred wallpaper remembers appearance")
need("previousAppearance: lastDesktopBackgroundAppearance" in SRC, "reload compares appearance")
need("requestedAppearance: requestedAppearance" in SRC, "decode completion checks appearance")
need("desktopBackgroundImageIndex(" in SRC, "thumbnail uses the appearance frame")
need("apple_desktop:apr" in SRC, "reads the appearance frame map")
need("apple_desktop:solar" in SRC, "reads the solar appearance fallback")
need("CreateThumbnailAtIndex(source, 0" not in SRC, "wallpaper thumbnail must not always decode frame 0")
need("viewDidChangeEffectiveAppearance" in SRC, "appearance change re-reads the desktop picture")
need("activeSpaceDidChangeNotification" in SRC, "Space change re-reads the desktop picture")
need("refreshDesktopBackgroundForPictureChange" in SRC, "picture change refresh exists")
need("WALLPAPER-MADESKTOP-01" in SRC, "madesktop wallpaper tag")
need("desktopBackgroundImageURLForDecode(" in SRC, "madesktop resolves before ImageIO")
need("desktopBackgroundImageURLToDecode(" in SRC, "madesktop thumbnail path goes through Core")
need("desktopBackgroundAppearanceVariantURL(" in SRC, "madesktop appearance still goes through Core")
need("shouldUseDesktopBackgroundAppearanceVariant(" in SRC, "appearance still is used only when it exists")
thumb_fn = SRC.split("private func desktopBackgroundThumbnail(", 1)[1].split("\nprivate func ", 1)[0]
need("desktopBackgroundImageURLForDecode(" in thumb_fn, "thumbnail decode resolves a madesktop descriptor")
need("CreateThumbnailAtIndex(source, 0" not in thumb_fn, "resolved thumbnail still picks an appearance frame")
need("shouldRefreshDesktopBackgroundForPictureChange(" in SRC, "picture change refresh is gated")
picture = method_body(SRC, "func refreshDesktopBackgroundForPictureChange()")
for banned in ("showPage(", "movePage(", "transitionToPage(", "completePageTransition(", "setFrame("):
    need(banned not in picture, f"picture refresh must not page or resize ({banned})")
need("desktopPictureFollowUpGeneration" in picture, "a late URL read does not stack")
need("WALLPAPER-DEFERRED-ON-APPEAR-01" in SRC, "held wallpaper on appear tag")
need("holdsDeferredDesktopBackground" in SRC, "root exposes a held wallpaper")
need("WALLPAPER-DECODE-EMPTY-01" in SRC, "failed wallpaper decode tag")
need("forgetFailedDesktopBackgroundRequest()" in SRC, "failed decode forgets the request")
need("retryDesktopBackgroundDecodeAfterFailure()" in SRC, "failed decode retries once")
need("retryingFailedDecode" in SRC, "automatic retry does not reset its own flag")
retry_fn = method_body(SRC, "private func retryDesktopBackgroundDecodeAfterFailure()")
need("shouldStartDesktopBackgroundDecodeRetry" in retry_fn, "retry starts through the Core gate")
need("WALLPAPER-RETRY-SKIP-01" in retry_fn, "retry-skip tag")
flag_at = retry_fn.find("desktopBackgroundDecodeRetried = true")
gate_at = retry_fn.find("shouldStartDesktopBackgroundDecodeRetry")
need(flag_at > gate_at >= 0, "retry flag is set only after the start gate")
need("guard let image else { return }" in SRC, "nil thumbnail is not installed")
install_at = SRC.index("private func installDesktopBackground")
install_body = SRC[install_at:SRC.index("override func layout()", install_at)]
need("guard let image else { return }" in install_body, "install refuses a nil thumbnail")
need("contents = image" in install_body, "install still paints a decoded thumbnail")

show_body = method_body(SRC, "func show(animated: Bool = true)")
appear_else = show_body.split("} else {", 1)
need(len(appear_else) == 2, "show() has an appearing branch and an already-visible branch")
need("shouldInstallHeldDesktopBackgroundOnAppearance(" in appear_else[0],
     "appearing show installs a wallpaper decoded during the fade")
need("applyDeferredDesktopBackground()" in appear_else[0],
     "appearing show applies the held wallpaper")
need("applyDeferredDesktopBackground()" in appear_else[1],
     "fade-cancel show still applies the held wallpaper")

for signature in (
    "private func showPage(_ page: Int)",
    "private func transitionToPage(_ targetPage: Int, direction: Int, discrete: Bool)",
    "private func completePageTransition(to targetPage: Int)",
):
    body = method_body(SRC, signature)
    need("armDeferredScreenGeometryRetry" not in body, f"{signature} must not arm the screen retry")
    need("armMissingScreenGeometryFollowUpIfNeeded" not in body, f"{signature} must not arm the nil-screen follow-up")
    need("deferredVisibleScreenGeometryRetryDelay" not in body, f"{signature} must not poll screen geometry")
    need("refreshVisibleScreenGeometry" not in body, f"{signature} must not refresh screen geometry")
    need("refreshDesktopBackgroundForPictureChange" not in body, f"{signature} must not re-read the desktop picture")
    need("desktopBackgroundImageURLForDecode" not in body, f"{signature} must not resolve a wallpaper descriptor")
    need("forgetFailedDesktopBackgroundRequest" not in body, f"{signature} must not forget a wallpaper request")
    need("retryDesktopBackgroundDecodeAfterFailure" not in body, f"{signature} must not retry a wallpaper decode")
need("func applyScreenGeometryForPresentation()" in SRC, "root applyScreenGeometry method")
need("resetPagingEdgeChromeAfterScreenGeometry" in SRC, "geometry clears edge chrome")
need("resetPointerChromeAfterScreenGeometry" in SRC, "page arrows reset pointer chrome")
need("DISPLAY-SECONDARY-EDGE-CHROME-01" in SRC, "edge chrome fix tag")
need("hasVerticalScroller = false" in SRC, "page hosts keep vertical scroller off")

need("lastViewportSize = .zero" in SRC and "viewportMetricsDirty = true" in SRC, "invalidate clears cache")

# Must not break paging red line from geometry helper
apply = ""
if "func applyScreenGeometryForPresentation()" in SRC:
    i = SRC.index("func applyScreenGeometryForPresentation()")
    apply = SRC[i:i+400]
for banned in ("showPage(", "movePage(", "transitionToPage(", "scrollToPage", "animator()"):
    need(banned not in apply, f"geometry apply must not page ({banned})")

# frame(for:) delegates to Core
need("LauncherLayout.launcherWindowFrame(for: screenFrame, testSize: testSize)" in SRC, "frame(for:) uses Core")

if fail:
    print("FAIL: secondary display layout\n  " + "\n  ".join(fail))
    sys.exit(1)
print("PASS: secondary display layout wiring")

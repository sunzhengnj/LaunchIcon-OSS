#!/usr/bin/env python3
"""DRAG-EDGE-AUTO-PAGE-AXIS-01 + NATURAL-SCROLLING-PASS-THROUGH-01 guards."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
prefs = (root / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


need("DRAG-EDGE-AUTO-PAGE-AXIS-01" in core, "Core drag-edge axis marker")
need("enum PagingArrowEdgeLayout" in core, "PagingArrowEdgeLayout missing")
need("case leadingTrailing" in core and "case topBottom" in core, "edge layout cases")
need("func pagingArrowEdgeLayout(" in core, "pagingArrowEdgeLayout helper")
need("NATURAL-SCROLLING-PASS-THROUGH-01" in direct or
     "pagingScrollDeltaPreservingNaturalScrolling" in core,
     "Natural Scrolling helper missing")
need("func pagingScrollDeltaPreservingNaturalScrolling(" in core, "pass-through helper")
need("testPagingArrowEdgeLayoutFollowsPageFlipAxis" in tests, "edge layout XCT")
need("testPagingScrollDeltaPreservesNaturalScrolling" in tests, "natural scroll XCT")
need("func installPagingArrowEdgeConstraints()" in direct, "Direct install method")
need("installPagingArrowEdgeConstraints()" in direct, "install must be called")
need("pagingArrowEdgeConstraints" in direct, "constraint storage")
need("pageFlipDirection: LauncherPageFlipDirection = .horizontal" in prefs,
     "horizontal default red line")
need("pageFlipLocksHorizontalAxis" in core, "gesture axis lock intact")
need("pagingGridViewportSideGutter" in core, "viewport side gutter helper")
need("DRAG-EDGE-VIEWPORT-INSET-01" in core or "pagingGridViewportSideGutter" in core,
     "viewport inset marker")
need("gridViewportSideGutterConstraints" in direct, "Direct stores side gutter constraints")
need("pagingGridViewportSideGutter" in direct, "Direct applies side gutter")
# Horizontal default keeps 96; vertical collapses — encoded in Core helper body.
need("direction.isHorizontal ? 96 : 0" in core, "H=96 V=0 gutter formula")

# LauncherRootView.setPageFlipDirection must reinstall edge constraints.
# Controller also has a thin forwarder — match the body that owns symbols.
idx = 0
root_body = ""
while True:
    start = direct.find("func setPageFlipDirection(_ direction: LauncherPageFlipDirection) {", idx)
    if start < 0:
        break
    body = direct[start:start + 900]
    if "applyPagingArrowSymbols()" in body:
        root_body = body
        break
    idx = start + 10
need(bool(root_body), "LauncherRootView setPageFlipDirection missing")
need("installPagingArrowEdgeConstraints()" in root_body,
     "setPageFlipDirection must reinstall arrow edges")
need("applyPagingArrowSymbols()" in root_body, "symbols stay axis-aware")

# Vertical top/bottom anchors present in Direct.
need("previousPageButton.topAnchor.constraint(equalTo: gridViewport.topAnchor)" in direct,
     "vertical previous arrow must pin top")
need("nextPageButton.bottomAnchor.constraint(equalTo: gridViewport.bottomAnchor)" in direct,
     "vertical next arrow must pin bottom")


need("pagingGridViewportEndInset" in core, "viewport end inset helper")
need("DRAG-EDGE-VIEWPORT-END-INSET-01" in core, "end inset marker")
need("gridViewportTopConstraint" in direct and "gridViewportBottomConstraint" in direct,
     "Direct stores top/bottom end-inset constraints")
need("pagingGridViewportEndInset" in direct, "Direct applies end inset")
need("testPagingGridViewportEndInsetLightWhenVertical" in tests, "end inset XCT")
# Horizontal keeps 28/18; vertical adds 48 (light, < 96 arrow band).
need("return (top: 28, bottom: 18)" in core, "H end inset 28/18")
need("28 + 48" in core and "18 + 48" in core, "V light +48 end inset")

# Natural Scrolling: Direct must use pass-through helper; must not flip by inverted flag alone.
need("pagingScrollDeltaPreservingNaturalScrolling" in direct,
     "Direct scroll path must call pass-through helper")
# Ban a naive double-invert pattern in dominantScrollDelta body.
dom = direct.find("func dominantScrollDelta(from event: NSEvent) -> CGFloat {")
need(dom > 0, "dominantScrollDelta missing")
dom_body = direct[dom:dom + 1200]
need("isDirectionInvertedFromDevice" in dom_body,
     "dominantScrollDelta must acknowledge inverted flag (via helper)")
need("deviceDelta: -" not in dom_body and "*= -1" not in dom_body,
     "must not manually negate scroll deltas")

# No Sparkle / check-for-updates in blank menu path for this slice.
need("import Sparkle" not in direct and "SPUUpdater" not in direct,
     "must not introduce Sparkle")
need("检查更新" not in direct, "blank menu must not add 检查更新 without channel")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: drag-edge auto-page axis + natural scrolling pass-through")

#!/usr/bin/env python3
"""DOCK-DRAG-FILE-01: real apps leave as a file link. Paging stays put."""
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


def body(text, start, end):
    i = text.index(start)
    return text[i : text.index(end, i + len(start))]


need("enum LayoutDragOutsideOffer" in core, "Core offer type missing")
need("func layoutDragOutsideOffer(" in core, "Core offer function missing")
need("func shouldTemporarilyRevealDock(" in core, "Dock reveal policy missing")
need("func shouldRevealDockForDragLocation(" in core, "edge reveal policy missing")
need("func launcherTextRejectsFileURLDrop(" in core, "text-drop policy missing")
need("func layoutDragPasteboardIncludesFileURL(" in core, "late file-URL policy missing")
file_url = body(core, "func layoutDragPasteboardIncludesFileURL(", "private static func pointerIsInExternalDragDockZone")
need("screenFrame: CGRect" in file_url, "file-URL policy must take screenFrame")
need("pointerIsInExternalDragDockLinkZone(" in file_url, "file-URL policy must use the derived Dock link zone")
need("iconLayout" in file_url, "file-URL policy must take icon layout to cap the Dock band")
need("externalDragDockLinkInsets(" in file_url, "file-URL policy must derive the Dock band from layout")
need("externalDragOutsideAppDockBand" not in core, "magic 48 pt Dock band must not remain")
need("func externalDragDockLinkInsets(" in core, "layout-derived Dock insets helper missing")
need("enum ExternalDragDockEdge" in core, "Dock edge type missing")
need("func externalDragDockEdge(" in core, "Dock edge inference missing")
need("var dockEdge: ExternalDragDockEdge" in core, "icon layout must carry the Dock edge")
need("pageTurnPlates" in file_url, "file-URL policy must yield to the page-turn plate")
need("enum ExternalDragFileURLPasteboardAction" in core, "file-URL attach/withdraw action missing")
need("func externalDragFileURLPasteboardAction(" in core, "file-URL attach/withdraw policy missing")
need("if draggingOutsideApplication { return true }" not in file_url, "outside-app mask at drag start must not attach immediately")
need("testLayoutDragFileURLWaitsUntilPointerLeavesWindow" in tests, "late file-URL test missing")
need("testLayoutDragFileURLArmsOnFullscreenDockEdge" in tests, "fullscreen Dock-edge file-URL test missing")
need("testLayoutDragFileURLArmsWhenDragIsAlreadyOutsideTheApp" in tests, "outside-app file-URL test missing")
need("testLayoutDragFileURLArmsInDerivedDockBandIncludingMovedTo" in tests, "derived Dock-band file-URL test missing")
need("testExternalDragDockLinkInsetsCapBelowLastIconRow" in tests, "Dock-band inset cap test missing")
need("testExternalDragDockEdgeOpensOnlyTheActualDockSide" in tests, "Dock-edge file-URL test missing")
need("testExternalDragDockEdgeIsInferredFromVisibleFrame" in tests, "Dock-edge inference test missing")
need("testLayoutDragFileURLYieldsToThePageTurnPlateUntilThePointerLeavesTheApp" in tests, "page-turn plate yield test missing")
need("testExternalDragFileURLPasteboardActionWithdrawsWhenLeavingTheBand" in tests, "file-URL withdraw test missing")
need("screenFrame:" in tests[tests.index("testLayoutDragFileURLArmsOnFullscreenDockEdge"):tests.index("testLayoutDragFileURLArmsOnFullscreenDockEdge")+800], "fullscreen test must pass screenFrame")
need("func shouldRestoreDockHideAfterExternalDrag(" in core, "Dock restore policy missing")
need("testLayoutDragOutsideOfferLinksRealAppsOnly" in tests, "Core test missing")
need("testLayoutDragDockRevealWaitsForScreenEdge" in tests, "edge reveal test missing")

offer = body(core, "public enum LayoutDragOutsideOffer", "Multi-select「在访达中显示」")
for banned in ("showPage", "transitionToPage", "completePageTransition", "pageDrag", "handlePagingScroll"):
    need(banned not in offer, f"dock offer must not name paging ({banned})")

need("layoutDragOutsideOffer(for: candidate, isFolder: false)" in direct, "Direct must ask Core before attaching a file")
need("forType: .fileURL" in direct, "pasteboard must carry a public file URL")
need("layoutDragPasteboardIncludesFileURL(" in direct, "Direct must ask Core before a late file URL")
need("offerExternalDragFileLinkIfNeeded" in direct, "file URL must be attached from the drag session")
offer_fn = body(direct, "func offerExternalDragFileLinkIfNeeded(", "/// DOCK-REVEAL-EDGE-01")
need("layoutDragPasteboardIncludesFileURL(" in offer_fn, "file URL attach must still ask Core")
need("externalDragFileURLPasteboardAction(" in offer_fn, "file URL attach/withdraw must ask Core")
need("externalDragFileURLAttached = true" in offer_fn, "file URL attach must set the flag")
need("externalDragFileURLAttached = false" in offer_fn, "leaving the band must clear the attach flag")
need("setData(nil, forType: .fileURL)" in offer_fn, "leaving the band must remove only the file URL")
need("declareTypes(" not in offer_fn, "withdraw must not declareTypes, which clears the pasteboard")
need("clearContents(" not in offer_fn, "withdraw must not clear the layout-item payload")
need("iconLayout: currentExternalDragIconLayout()" in offer_fn, "file URL attach must pass the visible icon layout")
need("pageTurnPlates: currentExternalDragPageTurnPlates()" in offer_fn, "file URL attach must pass the page-turn plates")
need("return externalDragFileURLAttached" in offer_fn, "outside mask must offer .link only after the file URL is attached")
need("return true" not in offer_fn, "outside mask must not offer an empty .link")
need("screenFrame: screen" in direct, "Direct must pass screenFrame into the late file-URL policy")
need("func currentExternalDragDockPlacement(" in direct, "Direct must infer the Dock edge from the screen")
need("func dockOrientationFallback(" in direct, "auto-hide Dock must fall back to the orientation preference")
need("func currentExternalDragPageTurnPlates(" in direct, "Direct must pass visible page-arrow plates")
need("externalDragDockEdge(" in direct, "Direct must ask Core for the Dock edge")
plates = body(direct, "func currentExternalDragPageTurnPlates(", "func offerExternalDragFileLinkIfNeeded(")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    need(banned not in plates, f"page-turn plates must not page ({banned})")
placement = body(direct, "func currentExternalDragDockPlacement(", "static func dockOrientationFallback(")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    need(banned not in placement, f"Dock edge placement must not page ({banned})")
need("onExternalAppDragActive?(true)" not in direct, "drag start must not reveal the Dock")
need("shouldRevealDockForDragLocation(" in direct, "reveal must follow the pointer")
need("onExternalAppDragActive?(false)" in direct, "drag end must restore Dock hiding")
need("launcherTextRejectsFileURLDrop(" in direct, "text fields must ask Core before a file drop")
need("class LauncherSearchField" in direct, "search field must be the rejecting subclass")
need("class AliasNameField: LauncherTextDropField" in direct, "alias field must reject file drops")
need("attachFieldEditorBridgeIfNeeded" in direct, "alias editor must reject file drops")
title = body(
    direct,
    "@MainActor\nprivate final class FolderTitleField:",
    "@MainActor\nfinal class FolderOverlayView:",
)
need("class FolderTitleField: NSTextField" in title, "folder title stays an NSTextField for the readiness fixture")
need("launcherTextRejectsFileURLDrop" in title, "folder title must reject file drops inline")

mask = body(
    direct,
    "sourceOperationMaskFor context: NSDraggingContext",
    "override func draggingSession(_ session: NSDraggingSession, endedAt",
)
need("context == .outsideApplication" in mask, "outside context missing")
need("dragSessionFileLinkHandler?(session, true)" in mask, "outside mask must attach the file URL in that call")
need("offersAppLink ? .link : NSDragOperation()" in mask, "outside offer must be a link, never a move")
need("still offers `.link`" not in mask, "outside mask comment must not claim an empty mask still offers .link")
need("return .move" in mask, "in-app drags stay layout moves")
for banned in ("showPage", "movePage", "handlePagingScroll", "finishPageDrag", ".hideDock", ".hideMenuBar"):
    need(banned not in mask, f"drag mask must not touch paging or presentation ({banned})")

dock = body(direct, "func setExternalAppDragActive", "func hide(animated: Bool = true)")
need("subtract(.hideDock)" in dock, "drag must lift only Dock hiding")
need("formUnion(.hideDock)" in dock, "drag end must restore Dock hiding")
need("shouldRestoreDockHideAfterExternalDrag" in dock, "restore must use the Core gate")
need(".hideMenuBar" not in dock, "menu bar must stay hidden during the drag")
for banned in ("showPage", "movePage", "handlePagingScroll", "transitionToPage"):
    need(banned not in dock, f"dock reveal must not page ({banned})")

reveal = body(direct, "func updateExternalDragDockReveal", "func endExternalDragDockReveal")
need("shouldRevealDockForDragLocation" in reveal, "move handler must ask Core")
need("showPage" not in reveal and "movePage" not in reveal and "transitionToPage" not in reveal, "edge reveal must not page")
moved = body(direct, "movedTo screenPoint: NSPoint", "override func draggingExited")
need("dragSessionFileLinkHandler?(session, false)" in moved, "in-window moves must not take the outside-app arm")
need("draggingOutsideApplication: draggingOutsideApplication" in direct, "Direct must pass the outside flag into Core")
begin = body(direct, "func beginItemDrag", "func endDropHighlightForDismissal")
need("externalDragOutsideOffer = outsideOffer" in begin, "drag must remember the offer without revealing")
need("onExternalAppDragActive?" not in begin, "beginItemDrag must not touch Dock hiding")
need("forType: .fileURL" not in begin, "in-window drag start must not attach a file URL")
need("setString(" not in begin, "beginItemDrag must not write the pasteboard string")

need("public static let pageColumns = 7" in core, "live grid columns changed")
need("private func showPage(" in direct, "showPage missing")

if failures:
    print("FAIL: dock drag file")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: dock drag file")

# DOCK-REVEAL-RESET-ON-HIDE-01
direct = "".join(p.read_text(encoding="utf-8") for p in [root / "Sources/Direct/LauncherWindowController.swift", *sorted((root / "Sources/Direct").glob("LauncherWindowController+*.swift"))])
if "cancelExternalDragDockRevealBecauseLauncherIsDismissing" not in direct:
    print("FAIL: hide must reset external Dock reveal")
    raise SystemExit(1)
if "DOCK-REVEAL-RESET-ON-HIDE-01" not in direct:
    print("FAIL: DOCK-REVEAL-RESET-ON-HIDE-01 marker")
    raise SystemExit(1)
print("PASS: dock reveal resets on hide")

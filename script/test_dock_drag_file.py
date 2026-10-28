#!/usr/bin/env python3
"""DOCK-DRAG-FILE-01: real apps leave as a file link. Paging stays put."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
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
need("testLayoutDragFileURLWaitsUntilPointerLeavesWindow" in tests, "late file-URL test missing")
need("func shouldRestoreDockHideAfterExternalDrag(" in core, "Dock restore policy missing")
need("testLayoutDragOutsideOfferLinksRealAppsOnly" in tests, "Core test missing")
need("testLayoutDragDockRevealWaitsForScreenEdge" in tests, "edge reveal test missing")

offer = body(core, "public enum LayoutDragOutsideOffer", "Multi-select「在访达中显示」")
for banned in ("showPage", "transitionToPage", "completePageTransition", "pageDrag", "handlePagingScroll"):
    need(banned not in offer, f"dock offer must not name paging ({banned})")

need("layoutDragOutsideOffer(for: candidate, isFolder: false)" in direct, "Direct must ask Core before attaching a file")
need("forType: .fileURL" in direct, "pasteboard must carry a public file URL")
need("layoutDragPasteboardIncludesFileURL(" in direct, "Direct must ask Core before a late file URL")
need("offerExternalDragFileLinkIfPointerLeftWindow" in direct, "file URL must be attached from the drag session")
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
    "@MainActor\nprivate final class FolderOverlayView:",
)
need("class FolderTitleField: NSTextField" in title, "folder title stays an NSTextField for the readiness fixture")
need("launcherTextRejectsFileURLDrop" in title, "folder title must reject file drops inline")

mask = body(
    direct,
    "sourceOperationMaskFor context: NSDraggingContext",
    "override func draggingSession(_ session: NSDraggingSession, endedAt",
)
need("context == .outsideApplication" in mask, "outside context missing")
need("offersAppLink ? .link : NSDragOperation()" in mask, "outside offer must be a link, never a move")
need("return .move" in mask, "in-app drags stay layout moves")
for banned in ("showPage", "movePage", "handlePagingScroll", "finishPageDrag", ".hideDock", ".hideMenuBar"):
    need(banned not in mask, f"drag mask must not touch paging or presentation ({banned})")

dock = body(direct, "private func setExternalAppDragActive", "func hide(animated: Bool = true)")
need("subtract(.hideDock)" in dock, "drag must lift only Dock hiding")
need("formUnion(.hideDock)" in dock, "drag end must restore Dock hiding")
need("shouldRestoreDockHideAfterExternalDrag" in dock, "restore must use the Core gate")
need(".hideMenuBar" not in dock, "menu bar must stay hidden during the drag")
for banned in ("showPage", "movePage", "handlePagingScroll", "transitionToPage"):
    need(banned not in dock, f"dock reveal must not page ({banned})")

reveal = body(direct, "private func updateExternalDragDockReveal", "private func endExternalDragDockReveal")
need("shouldRevealDockForDragLocation" in reveal, "move handler must ask Core")
need("showPage" not in reveal and "movePage" not in reveal and "transitionToPage" not in reveal, "edge reveal must not page")
begin = body(direct, "private func beginItemDrag", "private func prefetchIcons")
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

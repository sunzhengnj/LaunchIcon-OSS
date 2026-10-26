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
need("func shouldRestoreDockHideAfterExternalDrag(" in core, "Dock restore policy missing")
need("testLayoutDragOutsideOfferLinksRealAppsOnly" in tests, "Core test missing")

offer = body(core, "public enum LayoutDragOutsideOffer", "Multi-select「在访达中显示」")
for banned in ("showPage", "transitionToPage", "completePageTransition", "pageDrag", "handlePagingScroll"):
    need(banned not in offer, f"dock offer must not name paging ({banned})")

need("layoutDragOutsideOffer(for: candidate, isFolder: false)" in direct, "Direct must ask Core before attaching a file")
need("forType: .fileURL" in direct, "pasteboard must carry a public file URL")
need("onExternalAppDragActive?(true)" in direct, "drag start must reveal the Dock")
need("onExternalAppDragActive?(false)" in direct, "drag end must restore Dock hiding")

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

need("public static let pageColumns = 7" in core, "live grid columns changed")
need("private func showPage(" in direct, "showPage missing")

if failures:
    print("FAIL: dock drag file")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: dock drag file")

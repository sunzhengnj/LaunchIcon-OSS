#!/usr/bin/env python3
"""Guard: GRID-KEY-WALK-01 — arrow walk stays inside one grid and does not page."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
layout = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


def body(text, start, end):
    i = text.index(start)
    return text[i : text.index(end, i + len(start))]


neighbor = body(layout, "func gridKeyboardNeighborSlot(", "func focusSlot(")
need("GridKeyboardDirection" in layout, "direction enum missing")
need("func gridKeyboardDirection(forKeyCode" in layout, "key-code map missing")
need("case 116" not in neighbor and "case 121" not in neighbor, "neighbor must not treat Page Up/Down as steps")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "pageDrag"):
    need(banned not in neighbor, f"neighbor math must not name paging ({banned})")

step = body(direct, "func stepGridKeyboard(", "func focusPresentedItem(")
for banned in ("showPage", "movePage", "transitionToPage", "completePageTransition"):
    need(banned not in step, f"step helper must not call paging ({banned})")
need("direction == .left || direction == .right" in step, "main-grid left/right must decline")
need("return false" in step, "declined step must fall through to existing paging")
need("folderDisplayColumns" in step, "folder walk must use the folder column count")
need("pageColumns" in step, "search and main grid use pageColumns")
need("onGridKeyboardStep" in direct, "tile callback missing")
need("gridKeyboardDirection(forKeyCode:" in direct, "tile must ask Core which arrows walk")

# Tile keyDown still pages left/right and Page Up/Down when the walk declines.
tile = body(direct, "override func keyDown(with event: NSEvent) {\n        // NSView.keyDown", "override func insertTab")
need("onPage?(-1)" in tile and "onPage?(1)" in tile, "tile paging fallback missing")
need("case 123, 116:" in tile and "case 124, 121:" in tile, "page keys changed")

need("private func showPage(" in direct, "showPage missing")
need("testGridKeyboardNeighborStaysInsideTheGrid" in tests, "Core test missing")

if failures:
    print("FAIL: grid keyboard neighbor")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: grid keyboard neighbor")

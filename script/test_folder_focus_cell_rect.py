#!/usr/bin/env python3
"""FOLDER-FOCUS-CELL-RECT-01: key-view scroll asks for the whole folder or search cell."""
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


need("func scrollRectRevealingFocusedCell(" in core, "Core cell rect missing")
need("testScrollRectRevealingFocusedCellUsesTheWholeCell" in tests, "Core cell rect test missing")

rect = body(core, "public static func scrollRectRevealingFocusedCell(", "public static func visiblePageIndices(")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    need(banned not in rect, f"cell rect must not page ({banned})")
need("return cellBounds" in rect, "a real cell must reveal its whole bounds")

tile = body(direct, "override func scrollToVisible(_ rect: NSRect)", "override func becomeFirstResponder()")
need("onFocus != nil" in tile, "only a scrolling list replaces the rect")
need("scrollRectRevealingFocusedCell" in tile, "the tile must ask Core")
need("super.scrollToVisible(rect)" in tile, "the main grid keeps the system rect")
need("super.scrollToVisible(revealing)" in tile, "the scrolling cell must ask for the Core rect")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    need(banned not in tile, f"tile scroll must not page ({banned})")

if failures:
    print("FAIL: folder focus cell rect")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: folder focus cell rect")

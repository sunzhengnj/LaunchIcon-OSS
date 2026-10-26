#!/usr/bin/env python3
"""REORGANIZE-CLEAR-SELECTION-01: blank reorganize clears multi-select (no paging)."""
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")

def fail(m):
    print("FAIL:", m); sys.exit(1)

if "shouldClearSelectionAfterReorganize" not in core:
    fail("Core helper missing")
if "testShouldClearSelectionAfterReorganizeWhenNonEmpty" not in tests:
    fail("Core test missing")
if "REORGANIZE-CLEAR-SELECTION-01" not in direct:
    fail("Direct tag missing")
fn = "private func commitReorganizedLayout(_ next: LayoutState, toast: String)"
if fn not in direct:
    fail("commitReorganizedLayout missing")
chunk = direct[direct.index(fn):direct.index(fn)+500]
if "shouldClearSelectionAfterReorganize" not in chunk:
    fail("commitReorganizedLayout must clear via Core helper")
if "announce: false" not in chunk:
    fail("must refresh chrome announce:false")
for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
    if bad in chunk:
        fail(f"paging {bad}")
print("PASS: reorganize clear selection")

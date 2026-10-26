#!/usr/bin/env python3
"""BLANK-CLICK-CLEAR-SELECTION-01: wallpaper click clears multi-select before dismiss."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

if "shouldClearSelectionInsteadOfDismiss" not in core:
    fail("Core missing shouldClearSelectionInsteadOfDismiss")
if "shouldClearSelectionInsteadOfDismiss" not in direct:
    fail("Direct shouldDismiss must call shouldClearSelectionInsteadOfDismiss")
if "BLANK-CLICK-CLEAR-SELECTION-01" not in direct:
    fail("Direct missing BLANK-CLICK-CLEAR-SELECTION-01 tag")
# Must clear then refresh chrome (VO announce path), and return false (no dismiss).
needle = "itemSelection.clear()"
# Find the block near the tag
tag_idx = direct.find("BLANK-CLICK-CLEAR-SELECTION-01")
if tag_idx < 0:
    fail("tag missing")
window = direct[tag_idx : tag_idx + 500]
if "itemSelection.clear()" not in window:
    fail("clear selection missing near tag")
if "refreshItemSelectionChrome()" not in window:
    fail("refreshItemSelectionChrome missing near tag")
if "return false" not in window:
    fail("must return false so dismiss does not fire")
# Do not touch paging hosts
for bad in ("pageAnimationDuration", "transitionToPage", "movePage("):
    if bad in window:
        fail(f"paging symbol {bad} near blank-click clear — refuse")
print("PASS: blank click clear selection")

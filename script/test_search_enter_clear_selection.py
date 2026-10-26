#!/usr/bin/env python3
"""SEARCH-ENTER-CLEAR-SELECTION-01: clear multi-select when entering search."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

if "shouldClearSelectionWhenEnteringSearch" not in core:
    fail("Core missing shouldClearSelectionWhenEnteringSearch")
if "lastKnownSearching" not in direct:
    fail("Direct missing lastKnownSearching tracker")
tag = "SEARCH-ENTER-CLEAR-SELECTION-01: grid multi-select"
idx = direct.find(tag)
if idx < 0:
    fail("Direct missing refreshPresentation tag")
window = direct[idx : idx + 800]
if "shouldClearSelectionWhenEnteringSearch" not in window:
    fail("Direct must call Core helper near tag")
if "itemSelection.clear()" not in window:
    fail("must clear selection")
if "announceSelectionChangeIfNeeded()" not in window:
    fail("must announce clear for VO parity")
for bad in ("pageAnimationDuration", "transitionToPage", "movePage("):
    if bad in window:
        fail(f"paging symbol {bad} near search-enter clear")
print("PASS: search enter clear selection")

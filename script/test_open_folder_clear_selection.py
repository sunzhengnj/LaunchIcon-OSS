#!/usr/bin/env python3
"""OPEN-FOLDER-CLEAR-SELECTION-01: opening a folder clears multi-select."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

if "shouldClearSelectionWhenOpeningFolder" not in core:
    fail("Core missing shouldClearSelectionWhenOpeningFolder")
if "OPEN-FOLDER-CLEAR-SELECTION-01" not in direct:
    fail("Direct missing OPEN-FOLDER-CLEAR-SELECTION-01 tag")
open_idx = direct.find("private func openFolder(_ id: UUID)")
if open_idx < 0:
    fail("openFolder missing")
open_window = direct[open_idx : open_idx + 1400]
if "clearItemSelectionWhenOpeningFolder()" not in open_window:
    fail("openFolder must call clearItemSelectionWhenOpeningFolder")
fn_idx = direct.find("func clearItemSelectionWhenOpeningFolder()")
if fn_idx < 0:
    fail("helper missing")
window = direct[fn_idx : fn_idx + 400]
if "shouldClearSelectionWhenOpeningFolder" not in window:
    fail("helper must call Core gate")
if "itemSelection.clear()" not in window:
    fail("clear missing in helper")
if "refreshItemSelectionChrome()" not in window:
    fail("refreshItemSelectionChrome missing in helper")
for bad in ("pageAnimationDuration", "transitionToPage", "movePage("):
    if bad in window:
        fail(f"paging symbol {bad} near open-folder clear — refuse")
print("PASS: open folder clear selection")

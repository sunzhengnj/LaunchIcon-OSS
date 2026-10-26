#!/usr/bin/env python3
"""CLOSE-FOLDER-CLEAR-SELECTION-01: closing a folder clears multi-select."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

if "shouldClearSelectionWhenClosingFolder" not in core:
    fail("Core missing shouldClearSelectionWhenClosingFolder")
if "CLOSE-FOLDER-CLEAR-SELECTION-01" not in direct:
    fail("Direct missing CLOSE-FOLDER-CLEAR-SELECTION-01 tag")
close_idx = direct.find("private func closeFolder(")
if close_idx < 0:
    fail("closeFolder missing")
# Bound to finishFolderCloseChromeLand or next large span
close_window = direct[close_idx : close_idx + 3500]
if "clearItemSelectionWhenClosingFolder()" not in close_window:
    fail("closeFolder must call clearItemSelectionWhenClosingFolder")
fn_idx = direct.find("func clearItemSelectionWhenClosingFolder()")
if fn_idx < 0:
    fail("helper missing")
window = direct[fn_idx : fn_idx + 400]
if "shouldClearSelectionWhenClosingFolder" not in window:
    fail("helper must call Core gate")
if "itemSelection.clear()" not in window:
    fail("clear missing in helper")
if "refreshItemSelectionChrome(announce: false)" not in window:
    fail("must refresh with announce:false under close veil")
for bad in ("pageAnimationDuration", "transitionToPage", "movePage("):
    if bad in window:
        fail(f"paging symbol {bad} near close-folder clear — refuse")
print("PASS: close folder clear selection")

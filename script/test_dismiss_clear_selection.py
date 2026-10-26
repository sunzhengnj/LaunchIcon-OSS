#!/usr/bin/env python3
"""DISMISS-CLEAR-SELECTION-01: hide clears multi-select before fade."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

if "shouldClearSelectionOnDismiss" not in core:
    fail("Core missing shouldClearSelectionOnDismiss")
if "func clearItemSelectionForDismiss()" not in direct:
    fail("Direct missing clearItemSelectionForDismiss")
# hide() must call the root helper early
hide_idx = direct.find("func hide(animated: Bool = true)")
if hide_idx < 0:
    fail("hide() missing")
hide_window = direct[hide_idx : hide_idx + 600]
if "clearItemSelectionForDismiss()" not in hide_window:
    fail("hide() must call clearItemSelectionForDismiss")
# Helper body (not the hide() comment) must clear + refresh announce:false
fn_idx = direct.find("func clearItemSelectionForDismiss()")
if fn_idx < 0:
    fail("helper missing")
window = direct[fn_idx : fn_idx + 400]
if "shouldClearSelectionOnDismiss" not in window:
    fail("helper must call Core gate")
if "itemSelection.clear()" not in window:
    fail("clear missing in helper")
if "refreshItemSelectionChrome(announce: false)" not in window:
    fail("must refresh with announce:false")
if "DISMISS-CLEAR-SELECTION-01" not in direct[fn_idx - 200 : fn_idx + 50]:
    fail("DISMISS-CLEAR-SELECTION-01 tag missing near helper")
for bad in ("pageAnimationDuration", "transitionToPage", "movePage("):
    if bad in window:
        fail(f"paging symbol {bad} near dismiss clear — refuse")
print("PASS: dismiss clear selection")

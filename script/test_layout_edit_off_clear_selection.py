#!/usr/bin/env python3
"""LAYOUT-EDIT-OFF-CLEAR-SELECTION-01: disabling layout editing clears multi-select."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

if "shouldClearSelectionWhenLayoutEditingDisabled" not in core:
    fail("Core missing shouldClearSelectionWhenLayoutEditingDisabled")
if "LAYOUT-EDIT-OFF-CLEAR-SELECTION-01" not in direct:
    fail("Direct missing LAYOUT-EDIT-OFF-CLEAR-SELECTION-01 tag")
fn_idx = direct.find("func setLayoutEditingEnabled(_ enabled: Bool")
if fn_idx < 0:
    fail("setLayoutEditingEnabled missing")
window = direct[fn_idx : fn_idx + 900]
if "shouldClearSelectionWhenLayoutEditingDisabled" not in window:
    fail("setLayoutEditingEnabled must call Core gate")
if "itemSelection.clear()" not in window:
    fail("clear missing in setLayoutEditingEnabled")
if "refreshItemSelectionChrome(announce: false)" not in window:
    fail("must refresh with announce:false")
# Clear must run before assigning isLayoutEditingEnabled = enabled
clear_at = window.find("itemSelection.clear()")
assign_at = window.find("isLayoutEditingEnabled = enabled")
if clear_at < 0 or assign_at < 0 or clear_at > assign_at:
    fail("clear must run before isLayoutEditingEnabled assignment")
for bad in ("pageAnimationDuration", "transitionToPage", "movePage("):
    if bad in window:
        fail(f"paging symbol {bad} near layout-edit-off clear — refuse")
print("PASS: layout edit off clear selection")

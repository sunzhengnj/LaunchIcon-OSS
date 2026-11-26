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
# BLANK-CLICK-TOAST-01: toast peel before dismiss; toast chrome ignored.
if "BLANK-CLICK-TOAST-01" not in direct:
    fail("Direct missing BLANK-CLICK-TOAST-01 tag")
if "shouldDismissToastOnBlankClick" not in core:
    fail("Core missing shouldDismissToastOnBlankClick")
if "shouldDismissToastOnBlankClick" not in direct:
    fail("Direct shouldDismiss must call shouldDismissToastOnBlankClick")
sd = direct.find("func shouldDismiss(at point:")
sd_body = direct[sd:sd + 2200] if sd >= 0 else ""
if "view === toastView" not in sd_body:
    fail("shouldDismiss must ignore toastView hits")
if "shouldDismissToastOnBlankClick" not in sd_body or "hideToast(animated: true)" not in sd_body:
    fail("blank click must hideToast when toast visible")
# toast peel must precede selection clear inside shouldDismiss
if sd_body.find("shouldDismissToastOnBlankClick") > sd_body.find("BLANK-CLICK-CLEAR-SELECTION-01"):
    fail("BLANK-CLICK-TOAST peel must precede CLEAR-SELECTION")
print("PASS: blank click clear selection + toast")

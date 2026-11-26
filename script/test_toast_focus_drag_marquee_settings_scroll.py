#!/usr/bin/env python3
"""SEARCH-FOCUS/DRAG/MARQUEE toast dismiss + SETTINGS-TAB-SCROLL-TO-TOP."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

for needle in (
    "shouldDismissToastWhenFocusingSearch",
    "shouldDismissToastWhenBeginningDrag",
    "shouldDismissToastWhenActivatingMarquee",
    "SEARCH-FOCUS-DISMISS-TOAST-01",
    "DRAG-BEGIN-DISMISS-TOAST-01",
    "MARQUEE-ACTIVATE-DISMISS-TOAST-01",
):
    if needle not in core and needle not in direct:
        fail(f"missing {needle}")

fs = direct.find("func focusSearch()")
if "shouldDismissToastWhenFocusingSearch" not in direct[fs:fs+700]:
    fail("focusSearch must dismiss toast")

drag = direct.find("DRAG-BEGIN-DISMISS-TOAST-01")
if drag < 0 or "shouldDismissToastWhenBeginningDrag" not in direct[drag:drag+400]:
    fail("beginItemDrag must dismiss toast")

mq = direct.find("MARQUEE-ACTIVATE-DISMISS-TOAST-01")
if mq < 0 or "shouldDismissToastWhenActivatingMarquee" not in direct[mq:mq+400]:
    fail("marquee activate must dismiss toast")

if "SETTINGS-TAB-SCROLL-TO-TOP-01" not in settings:
    fail("settings missing SETTINGS-TAB-SCROLL-TO-TOP-01")
if "scrollOriginForTabSelectReset" not in prefs:
    fail("Core missing scrollOriginForTabSelectReset")
if "scrollSelectedSettingsTabToTop" not in settings:
    fail("settings missing scrollSelectedSettingsTabToTop")
# must not touch paging
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in direct[fs:fs+700] or bad in settings[settings.find("scrollSelectedSettingsTabToTop"):settings.find("scrollSelectedSettingsTabToTop")+500]:
        fail(f"paging red line {bad}")
print("PASS: toast focus/drag/marquee + settings tab scroll top")

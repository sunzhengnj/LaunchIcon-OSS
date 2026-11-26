#!/usr/bin/env python3
"""BLANK-MENU-IGNORE-TOAST / PINCH-RESET-ON-HIDE / SETTINGS-OPEN toast+folder."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = "".join(p.read_text(encoding="utf-8") for p in [ROOT / "Sources/Direct/LauncherWindowController.swift", *sorted((ROOT / "Sources/Direct").glob("LauncherWindowController+*.swift"))])

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

# BLANK-MENU-IGNORE-TOAST-01
if "BLANK-MENU-IGNORE-TOAST-01" not in direct:
    fail("missing BLANK-MENU-IGNORE-TOAST-01")
bam = direct.find("func blankAreaContextMenu(at")
body = direct[bam:bam + 1200]
if "view === toastView" not in body:
    fail("blankAreaContextMenu must ignore toastView")

# PINCH-DISMISS-RESET-ON-HIDE-01
if "PINCH-DISMISS-RESET-ON-HIDE-01" not in direct:
    fail("missing PINCH-DISMISS-RESET-ON-HIDE-01")
if "resetPinchDismissBecauseLauncherIsDismissing" not in direct:
    fail("missing resetPinchDismissBecauseLauncherIsDismissing")
hide = direct.find("func hide(animated: Bool = true)")
hide_body = direct[hide:hide + 4000]
if "resetPinchDismissBecauseLauncherIsDismissing" not in hide_body:
    fail("hide must reset pinch dismiss")
reset = direct.find("func resetPinchDismissBecauseLauncherIsDismissing")
reset_body = direct[reset:reset + 300]
if "pinchDismissAccumulated = 0" not in reset_body or "pinchDismissTriggered = false" not in reset_body:
    fail("reset must clear pinch accumulators")

# SETTINGS-OPEN-DISMISS-TOAST-01 / SETTINGS-OPEN-CLOSE-FOLDER-01
for needle in (
    "SETTINGS-OPEN-DISMISS-TOAST-01",
    "SETTINGS-OPEN-CLOSE-FOLDER-01",
    "shouldDismissToastWhenOpeningSettings",
    "shouldCloseFolderWhenOpeningSettings",
    "prepareChromeForOpeningSettings",
):
    if needle not in core and needle not in direct:
        fail(f"missing {needle}")
if "shouldDismissToastWhenOpeningSettings" not in core:
    fail("Core missing shouldDismissToastWhenOpeningSettings")
if "shouldCloseFolderWhenOpeningSettings" not in core:
    fail("Core missing shouldCloseFolderWhenOpeningSettings")
prep = direct.find("func prepareChromeForOpeningSettings")
prep_body = direct[prep:direct.find("\n    @objc private func openSettings()", prep)]
if "hideToast(animated: false)" not in prep_body:
    fail("prepare must hideToast without animation")
if "closeFolder(immediately: true)" not in prep_body:
    fail("prepare must closeFolder immediately")
# clearSelectionBeforeOpeningSettings must call prepare
clear = direct.find("func clearSelectionBeforeOpeningSettings()")
# RootView version is the second; find prepare call near SETTINGS-OPEN tags
idx = direct.find("SETTINGS-OPEN-DISMISS-TOAST-01 / SETTINGS-OPEN-CLOSE-FOLDER-01")
window = direct[idx:idx + 500]
if "prepareChromeForOpeningSettings()" not in window and "prepareChromeForOpeningSettings()" not in direct[clear:clear+500]:
    # RootView clearSelection
    rv = direct.find("prepareChromeForOpeningSettings()")
    if rv < 0:
        fail("clearSelectionBeforeOpeningSettings must call prepareChromeForOpeningSettings")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in hide_body[0:2500] or bad in prep_body:
        fail(f"paging red line {bad}")
print("PASS: settings-open chrome + pinch reset + blank-menu toast")

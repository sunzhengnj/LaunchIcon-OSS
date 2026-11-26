#!/usr/bin/env python3
"""WINDOW-DID-CHANGE-SCREEN / WALLPAPER-LIVE / DISPLAY-TARGET-VISIBLE / SETTINGS-HIDDEN-LAYOUT."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
app = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

for token in (
    "WALLPAPER-DECODE-LIVE-SCREEN-01",
    "shouldDiscardDecodedDesktopBackgroundForLiveScreen",
    "WINDOW-DID-CHANGE-SCREEN-01",
    "shouldRefreshGeometryOnWindowScreenChange",
    "DISPLAY-TARGET-APPLY-WHILE-VISIBLE-01",
    "shouldApplyDisplayTargetWhileVisible",
    "SETTINGS-HIDDEN-REFRESH-ON-LAYOUT-01",
    "shouldRefreshSettingsHiddenAppsOnLayoutChange",
):
    if token not in core:
        fail(f"Core missing {token}")

for token in (
    "WALLPAPER-DECODE-LIVE-SCREEN-01",
    "shouldDiscardDecodedDesktopBackgroundForLiveScreen",
    "WINDOW-DID-CHANGE-SCREEN-01",
    "launcherWindowDidChangeScreen",
    "NSWindow.didChangeScreenNotification",
    "DISPLAY-TARGET-APPLY-WHILE-VISIBLE-01",
    "relocateVisibleLauncherToDisplayTarget",
    "SETTINGS-HIDDEN-REFRESH-ON-LAYOUT-01",
    "onHiddenApplicationsChanged",
):
    if token not in direct:
        fail(f"Direct missing {token}")

if "SETTINGS-HIDDEN-REFRESH-ON-LAYOUT-01" not in app:
    fail("AppDelegate missing SETTINGS-HIDDEN-REFRESH-ON-LAYOUT-01")
if "onHiddenApplicationsChanged" not in app:
    fail("AppDelegate must wire onHiddenApplicationsChanged")
if "shouldRefreshSettingsHiddenAppsOnLayoutChange" not in app:
    fail("AppDelegate must gate settings hidden refresh")

rel_at = direct.find("func relocateVisibleLauncherToDisplayTarget")
if rel_at < 0:
    fail("relocate helper missing")
rel = direct[rel_at:rel_at + 1200]
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in rel:
        fail(f"paging red line {bad} in relocate")

print("PASS: display screen change + wallpaper live + display-target visible + settings hidden layout")

#!/usr/bin/env python3
"""SETTINGS-CLEAR-SELECTION-01: opening Settings drops multi-select."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
app = (root / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")
fails = []

def need(cond, msg):
    if not cond:
        fails.append(msg)

need("shouldClearSelectionWhenOpeningSettings" in core, "Core gate")
need("SETTINGS-CLEAR-SELECTION-01" in direct, "Direct slice marker")
need("clearSelectionBeforeOpeningSettings" in direct, "Direct helper")
need("clearSelectionBeforeOpeningSettings" in app, "AppDelegate showSettings")
need(
    "shouldClearSelectionWhenOpeningSettings" in direct
    and "refreshItemSelectionChrome(announce: false)" in direct,
    "root clears without VO spam",
)
need("panel.settingsHandler" in direct and "clearSelectionBeforeOpeningSettings" in direct, "panel path")

if fails:
    print("FAIL: settings clear selection")
    for f in fails:
        print("-", f)
    sys.exit(1)
print("PASS: settings clear selection")

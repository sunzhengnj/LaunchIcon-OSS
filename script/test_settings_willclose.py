#!/usr/bin/env python3
"""SETTINGS-WILLCLOSE-01: settings close always notifies launcher restore."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
direct = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")
delegate = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

if "SETTINGS-WILLCLOSE-01" not in direct:
    fail("missing slice tag")
# Real assignment (not a comment mentioning the string).
if re.search(r'^\s*window\.delegate\s*=\s*self\b', direct, re.M):
    fail("do not assign window.delegate = self (SDK type error); use willCloseNotification")
if "NSWindow.willCloseNotification" not in direct:
    fail("must observe willCloseNotification")
if "handleSettingsWindowWillClose" not in direct:
    fail("missing shared close handler")
if "didHandleSettingsWindowWillClose" not in direct:
    fail("missing duplicate-close guard")
if "didHandleSettingsWindowWillClose = false" not in direct:
    fail("must reset guard on show()")
if "onWindowWillClose" not in direct:
    fail("missing onWindowWillClose callback")
if "settingsWindowWillClose" not in delegate:
    fail("DirectAppDelegate must restore launcher on settings close")
for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
    if bad in direct:
        fail(f"paging symbol {bad} in SettingsWindowController — refuse")

print("PASS: settings willClose harden")

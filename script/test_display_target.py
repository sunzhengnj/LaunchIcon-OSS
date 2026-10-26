#!/usr/bin/env python3
"""Static guard for the multi-display target preference (DISPLAY-TARGET-01)."""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text()
DELEGATE = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text()
SETTINGS = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text()
fail = []
m = re.search(r"private func launcherScreen\(for window: NSWindow, appearing: Bool\).*?\n    \}\n", SRC, re.S)
body = m.group(0) if m else ""
if not body:
    fail.append("missing launcherScreen")
if "guard displayTarget != .active else { return fallback }" not in body:
    fail.append("default .active must keep NSScreen.main ?? window.screen")
if "let fallback = NSScreen.main ?? window.screen" not in body:
    fail.append("fallback changed")
if "guard appearing else { return window.screen ?? fallback }" not in body:
    fail.append("visible launcher must not jump screens")
for t in ("reloadData", "scrollToPage", "setPage", "currentPage", "animator()"):
    if t in body:
        fail.append(f"launcherScreen uses {t}")
if "let screen = launcherScreen(for: window, appearing: appearing)" not in SRC:
    fail.append("show() not wired")
if DELEGATE.count("setDisplayTarget(") != 2:
    fail.append("delegate must apply at launch and on change")
for t in ("displayTargetPopup.selectItem(", "proposed.displayTarget =", 'makeFormRow(title: L("显示于"), control: displayTargetPopup)'):
    if t not in SETTINGS:
        fail.append(f"settings missing {t}")
if fail:
    print("FAIL: display target\n  " + "\n  ".join(fail))
    sys.exit(1)
print("PASS: display target wiring")

#!/usr/bin/env python3
"""PINCH-TO-DISMISS-01: Settings pinch-to-dismiss; no paging animation."""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")
delegate = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
strings = json.loads((ROOT / "Resources/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for needle in (
    "enum PinchDismissCopy",
    "enum PinchDismissPolicy",
    "pinchInThreshold",
    'prefix + "pinchToDismiss"',
    "pinchToDismiss: Bool = true",
):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")

if "testPinchToDismissDefaultsAndPolicy" not in tests:
    fail("Core test missing")

for needle in (
    "pinchDismissCheckbox",
    "settings-pinch-dismiss",
    "proposed.pinchToDismiss",
):
    if needle not in settings:
        fail(f"Settings missing {needle!r}")

hm = re.search(r"height:\s*(\d+)", settings)
# SETTINGS-FORM-DENSITY-01: shorter window after collapsing button walls; still fits pinch row.
if not hm or int(hm.group(1)) < 860:
    fail("Settings window height must be >= 860 for pinch row")

if "showPage(" in settings or "pageTransition" in settings or "pageAnimation" in settings:
    fail("settings must not touch paging")

if delegate.count("setPinchToDismissEnabled(") != 2:
    fail("DirectAppDelegate must apply pinch at boot and on settings change")

for needle in (
    "func setPinchToDismissEnabled",
    "func handlePinchMagnify",
    "onPinchDismissRequested",
    "PinchDismissPolicy.shouldDismiss",
    "event.type == .magnify",
):
    if needle not in direct:
        fail(f"Direct missing {needle!r}")

start = direct.find("    func handlePinchMagnify(_ event: NSEvent) -> Bool {")
if start < 0:
    fail("handlePinchMagnify missing")
body = "\n".join(direct[start:].splitlines()[:80])
for bad in ("showPage(", "transitionToPage(", "animatePage", "movePage("):
    if bad in body:
        fail(f"handlePinchMagnify must not call {bad} (paging red line)")
edit_at = body.find("folderOverlay.isEditingTitle")
policy_at = body.find("PinchDismissPolicy.shouldDismiss")
phase_at = body.find("let phase = event.phase")
editing_prefix = body[:phase_at] if phase_at > 0 else ""
if edit_at < 0 or "searchField.currentEditor()" not in editing_prefix or "isPromptingForAlias" not in editing_prefix:
    fail("pinch must ignore folder title, search, and alias editing")
if "pinchDismissAccumulated = 0" not in editing_prefix or "return true" not in editing_prefix:
    fail("editing pinch must reset and stay consumed")
if policy_at < 0 or edit_at > policy_at or "isEditingText:" not in body:
    fail("editing check must reach PinchDismissPolicy before dismiss")
if "isEditingText" not in prefs or "isEditingText: true" not in tests:
    fail("Core policy must refuse dismiss while editing text")

for key in (
    "双指捏合收起",
    "启动器打开时双指捏合可收起；不影响翻页手势。关闭后捏合无效",
):
    if key not in strings:
        fail(f"xcstrings missing {key!r}")

print("PASS: pinch-to-dismiss wired")

#!/usr/bin/env python3
"""SETTINGS-SCREEN-FIT-OFFSCREEN-01: a closed Settings window stays on its screen."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")
layout = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "func settingsFitScreenChoice(" not in layout:
    fail("Core missing settingsFitScreenChoice")
if "enum SettingsFitScreenChoice" not in layout:
    fail("Core missing SettingsFitScreenChoice")
if "preferFrameIntersection" not in layout:
    fail("first appearance must be able to skip the frame intersection")
if "testSettingsFitScreenChoiceKeepsTheScreenUnderAClosedWindow" not in tests:
    fail("Core test missing")

if "SETTINGS-SCREEN-FIT-OFFSCREEN-01" not in settings:
    fail("missing SETTINGS-SCREEN-FIT-OFFSCREEN-01")
if "window.screen ?? NSScreen.main" in settings:
    fail("fit still coalesces a nil screen onto the main display")
if "func screenForSettingsFit(" not in settings:
    fail("missing screenForSettingsFit")
if "preferFrameIntersection: !initial" not in settings:
    fail("reopen must prefer the screen under the frame")
if "case .candidate(let index):" not in settings:
    fail("fit must use the candidate screen Core picked")
if "case .main:" not in settings:
    fail("first appearance may still use the main screen")

# The parameter-notification hold stays. A nil screen there must not fit.
start = settings.find("func settingsScreenParametersDidChange")
end = settings.find("func settingsWindowDidResize")
screen_body = settings[start:end] if start >= 0 and end > start else ""
if "shouldHoldSettingsScreenFitForMissingScreen" not in screen_body:
    fail("parameter change must still hold a nil screen")
if screen_body.find("shouldHoldSettingsScreenFitForMissingScreen") > screen_body.find(
    "fitSettingsWindowToVisibleScreen"
):
    fail("nil screen must be held before any settings fit")
if "NSScreen.main" in screen_body:
    fail("parameter change must not fall back to the main screen")
if "showPage" in settings or "transitionToPage" in settings or "completePageTransition" in settings:
    fail("settings fit must not touch paging")

print("PASS: settings screen fit")

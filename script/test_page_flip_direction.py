#!/usr/bin/env python3
"""PAGE-FLIP-DIRECTION-01: horizontal default; settings + axis helpers; no OSS."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
layout = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")
delegate = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for needle in (
    "PAGE-FLIP-DIRECTION-01",
    "enum LauncherPageFlipDirection",
    "case horizontal",
    "case vertical",
    'pageFlipDirection: LauncherPageFlipDirection = .horizontal',
    'prefix + "pageFlipDirection"',
    "enum PageFlipDirectionCopy",
):
    if needle not in prefs:
        fail(f"Core prefs missing {needle!r}")

for needle in (
    "pageFlipFrameOffset",
    "pageFlipExtent",
    "pageFlipLocksHorizontalAxis",
    "escReturnWithVerticalPagingKey",
):
    if needle not in layout:
        fail(f"Core layout missing {needle!r}")

# Horizontal path must still use pageFlipFrameOffset / default horizontal.
if "pageFlipDirection: LauncherPageFlipDirection = .horizontal" not in prefs:
    fail("default must be horizontal")

if "testPageFlipDirectionDefaultsHorizontal" not in tests:
    fail("Core XCT missing")

for needle in (
    "settings-page-flip-direction",
    "pageFlipDirectionPopup",
    "proposed.pageFlipDirection",
    "PageFlipDirectionCopy.label",
):
    if needle not in settings:
        fail(f"Settings missing {needle!r}")

if delegate.count("setPageFlipDirection(") != 2:
    fail("DirectAppDelegate must apply page flip at boot and on settings change")

for needle in (
    "func setPageFlipDirection",
    "pageAxisOffset",
    "prefersHorizontalPagingAxis",
    "setPagingAxis(horizontal:",
    "setPagingSymbol",
):
    if needle not in direct:
        fail(f"Direct missing {needle!r}")

# Red line: horizontal offset helper must zero the cross axis.
if "direction.isHorizontal ? CGPoint(x: d, y: 0)" not in layout and \
   "CGPoint(x: d, y: 0)" not in layout:
    fail("horizontal pageFlipFrameOffset must keep dy == 0")

# Gesture lock preserves historical tie-break for horizontal preference.
if "abs(dx) >= abs(dy)" not in layout:
    fail("horizontal axis lock must keep abs(dx) >= abs(dy)")

if "showPage(" in settings or "pageTransition" in settings:
    fail("settings must not drive page transitions")

print("PASS: page flip direction")

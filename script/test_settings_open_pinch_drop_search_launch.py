#!/usr/bin/env python3
"""PINCH-RESET / DROP / SEARCH-HL / LAUNCH-HL clear on settings open."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for token in (
    "PINCH-RESET-ON-SETTINGS-OPEN-01",
    "shouldResetPinchDismissWhenOpeningSettings",
    "DROP-HIGHLIGHT-CLEAR-ON-SETTINGS-OPEN-01",
    "shouldClearDropHighlightWhenOpeningSettings",
    "SEARCH-KEYBOARD-HIGHLIGHT-CLEAR-ON-SETTINGS-OPEN-01",
    "shouldClearSearchKeyboardHighlightWhenOpeningSettings",
    "LAUNCH-HIGHLIGHT-CLEAR-ON-SETTINGS-OPEN-01",
    "shouldClearLaunchHighlightWhenOpeningSettings",
):
    if token not in core:
        fail(f"Core missing {token}")

if "testSettingsOpenResetsPinchClearsDropSearchAndLaunchHighlight" not in tests:
    fail("Core test missing")

prep_i = direct.find("func prepareChromeForOpeningSettings")
prep = direct[prep_i:direct.find("\n    @objc private func openSettings()", prep_i)]
for token in (
    "case .resetPinchDismiss:",
    "resetPinchDismissBecauseLauncherIsDismissing",
    "case .clearDropHighlight:",
    "clearDropHighlightIfAllowed",
    "case .clearSearchKeyboardHighlight:",
    "clearSearchKeyboardHighlightBecauseLauncherIsDismissing",
):
    if token not in prep:
        fail(f"prepareChrome missing {token}")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in prep:
        fail(f"paging red line {bad} in prepareChrome")

# WC launch clear (first clearSelectionBeforeOpeningSettings forwarder)
wc = direct.find("func clearSelectionBeforeOpeningSettings()")
chunk = direct[wc:wc + 700]
if "shouldClearLaunchHighlightWhenOpeningSettings" not in chunk:
    fail("WC clearSelectionBeforeOpeningSettings must clear launch highlight")
if "setLaunchPending(nil" not in chunk:
    fail("WC must call setLaunchPending(nil)")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in chunk:
        fail(f"paging red line {bad} in WC clearSelection")

print("PASS: settings-open pinch/drop/search-hl/launch-hl")

#!/usr/bin/env python3
"""Settings-open: invalidate deferred rearrange, clear sampling/toast, reset Dock reveal, cancel pending page input."""
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
    "DEFERRED-GRID-REARRANGE-INVALIDATE-ON-SETTINGS-OPEN-01",
    "shouldInvalidateDeferredGridRearrangeWhenOpeningSettings",
    "ICON-SAMPLING-CLEAR-ON-SETTINGS-OPEN-01",
    "REARRANGE-PROGRESS-TOAST-CLEAR-ON-SETTINGS-OPEN-01",
    "shouldClearIconSamplingWhenOpeningSettings",
    "DOCK-REVEAL-RESET-ON-SETTINGS-OPEN-01",
    "shouldResetExternalDragDockRevealWhenOpeningSettings",
    "PENDING-PAGE-INPUT-CANCEL-ON-SETTINGS-OPEN-01",
    "shouldCancelPendingPageInputWhenOpeningSettings",
):
    if token not in core:
        fail(f"Core missing {token}")

if "testSettingsOpenRearrangeSamplingDockPageInputGates" not in tests:
    fail("Core test missing")

prep_i = direct.find("func prepareChromeForOpeningSettings()")
if prep_i < 0:
    fail("prepareChromeForOpeningSettings missing")
prep_end = direct.find("\n    @objc private func openSettings()", prep_i)
if prep_end < 0:
    fail("prepareChromeForOpeningSettings has no following openSettings")
prep = direct[prep_i:prep_end]
for token in (
    "DEFERRED-GRID-REARRANGE-INVALIDATE-ON-SETTINGS-OPEN-01",
    "invalidateDeferredGridRearrange",
    "ICON-SAMPLING-CLEAR-ON-SETTINGS-OPEN-01",
    "REARRANGE-PROGRESS-TOAST-CLEAR-ON-SETTINGS-OPEN-01",
    "clearIconSamplingBecauseLauncherIsDismissing",
    "DOCK-REVEAL-RESET-ON-SETTINGS-OPEN-01",
    "cancelExternalDragDockRevealBecauseLauncherIsDismissing",
    "PENDING-PAGE-INPUT-CANCEL-ON-SETTINGS-OPEN-01",
    "cancelPendingPageInput",
):
    if token not in prep:
        fail(f"prepareChrome missing {token}")

for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    for ln in prep.splitlines():
        if bad in ln and not ln.strip().startswith("//"):
            fail(f"paging red line {bad} in prepareChrome: {ln.strip()}")

print("PASS: settings-open rearrange/sampling/dock/page-input")

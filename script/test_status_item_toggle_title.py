#!/usr/bin/env python3
"""Guard: status-item toggle title refreshes on dismiss arm / cancel (no stale 隐藏 mid-fade)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
delegate = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("statusItemToggleTitle" in core, "Core missing statusItemToggleTitle")
need("shouldRefreshStatusItemToggleTitleOnDismissArm" in core, "Core missing dismiss-arm refresh gate")
need("shouldRefreshStatusItemToggleTitleOnDismissCancel" in core, "Core missing dismiss-cancel refresh gate")
need("testStatusItemToggleTitleRefreshGatesDuringDismissFade" in tests, "Core test missing")

need("shouldRefreshStatusItemToggleTitleOnDismissArm" in direct, "hide must refresh on dismiss arm")
need("shouldRefreshStatusItemToggleTitleOnDismissCancel" in direct, "show must refresh on dismiss cancel")
need("wasDismissing" in direct, "show must capture wasDismissing before clearing")

hide = direct[direct.index("func hide(animated:"):direct.index("func toggleVisibility()")]
arm_at = hide.find("dismissArmed = true")
refresh_at = hide.find("shouldRefreshStatusItemToggleTitleOnDismissArm")
need(arm_at >= 0 and refresh_at > arm_at, "dismiss-arm refresh must follow dismissArmed = true")
need("onVisibilityChanged?()" in hide[arm_at:arm_at + 500], "dismiss arm must publish onVisibilityChanged")

show = direct[direct.index("func show(animated:"):direct.index("func hide(animated:")]
need("wasDismissing = isDismissing" in show, "show must snapshot isDismissing before clear")
need("shouldRefreshStatusItemToggleTitleOnDismissCancel" in show, "show must use cancel refresh gate")

need("refreshStatusItemToggleTitle" in delegate, "AppDelegate must refresh titles")
need("statusItemToggleTitle" in delegate, "AppDelegate must use Core title policy")
need("menuWillOpen" in delegate, "menuWillOpen must still refresh")
need("onVisibilityChanged" in delegate, "visibility changes must refresh title")

# No paging
for label, chunk in (
    ("Core status title", core[core.index("statusItemToggleTitle"):core.index("statusItemToggleTitle")+500]),
    ("hide arm", hide[arm_at:arm_at + 400]),
):
    need("showPage(" not in chunk and "pageTransition" not in chunk and "pageAnimationDuration" not in chunk,
         f"{label} must not retune paging")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: status-item toggle title refresh on dismiss arm/cancel")

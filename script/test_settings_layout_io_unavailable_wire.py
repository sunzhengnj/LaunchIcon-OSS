#!/usr/bin/env python3
"""SETTINGS-LAYOUT-IO-UNAVAILABLE-WIRE-01: Settings uses Core unavailable + login approval copy."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "enum LayoutIOOutcomeCopy" not in core:
    fail("Core missing LayoutIOOutcomeCopy")
if "loginNeedsApprovalKey" not in prefs:
    fail("Core missing loginNeedsApprovalKey")

for needle in (
    "LayoutIOOutcomeCopy.exportUnavailable",
    "LayoutIOOutcomeCopy.importUnavailable",
    "LayoutIOOutcomeCopy.restoreUnavailable",
    "SettingsBehaviorTogglesCopy.loginNeedsApproval",
):
    if needle not in settings:
        fail(f"Settings missing {needle!r}")

for bad in (
    'L("当前无法导出布局")',
    'L("当前无法导入布局")',
    'L("当前无法恢复备份")',
    'L("请在系统设置的登录项中允许 LaunchIcon。")',
):
    if bad in settings:
        fail(f"Settings still hardcodes {bad}")

# Launchpad import dialog chrome stays Direct-owned (user still deciding).
for keep in (
    'L("从启动台导入…")',
    'L("从启动台导入布局？")',
):
    if keep not in settings:
        fail(f"Launchpad import chrome unexpectedly removed: {keep}")

if "showPage(" in settings or "pageTransition" in settings:
    fail("settings must not touch paging")

print("PASS: settings layout I/O unavailable + login approval wired to Core")

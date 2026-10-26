#!/usr/bin/env python3
"""SETTINGS-HIDDEN-APPS-CHROME-COPY-01: Settings hidden-apps chrome in Core."""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
strings = json.loads((ROOT / "Resources/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for needle in (
    "enum SettingsHiddenAppsChromeCopy",
    "emptyPopupTitleKey",
    "restoreButtonTitleKey",
    "restoreUnavailableKey",
    "restoredNamedFormatKey",
):
    if needle not in core:
        fail(f"Core missing {needle!r}")

if "testSettingsHiddenAppsChromeCopy" not in tests:
    fail("Core test missing")

for needle in (
    "SettingsHiddenAppsChromeCopy.rowTitle",
    "SettingsHiddenAppsChromeCopy.emptyPopupTitle",
    "SettingsHiddenAppsChromeCopy.restoreButtonTitleKey",
    "SettingsHiddenAppsChromeCopy.restoreAccessibilityLabel",
    "SettingsHiddenAppsChromeCopy.restoreUnavailable",
    "SettingsHiddenAppsChromeCopy.restoredNamed",
    "settings-restore-hidden",
):
    if needle not in settings:
        fail(f"Settings missing {needle!r}")

for bad in (
    'title: L("恢复")',
    'title: L("隐藏的应用")',
    'L("没有隐藏的应用")',
    'L("恢复所选应用")',
    'L("把隐藏的应用放回启动器")',
    'L("当前无法恢复该应用，请等待扫描完成后重试。")',
    'L("已恢复应用")',
    'L("已恢复“%@”")',
):
    if bad in settings:
        fail(f"Settings still hardcodes {bad}")

if "showPage(" in settings or "pageTransition" in settings:
    fail("settings must not touch paging")

for key in (
    "隐藏的应用",
    "没有隐藏的应用",
    "恢复",
    "恢复所选应用",
    "把隐藏的应用放回启动器",
    "当前无法恢复该应用，请等待扫描完成后重试。",
    "已恢复应用",
    "已恢复“%@”",
):
    if key not in strings:
        fail(f"xcstrings missing {key!r}")

print("PASS: settings hidden apps chrome copy wired")

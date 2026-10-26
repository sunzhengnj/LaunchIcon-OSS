#!/usr/bin/env python3
"""SETTINGS-SECTION-CHROME-01: Settings window/section/version chrome in Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "SETTINGS-SECTION-CHROME-01" not in prefs:
    fail("Core missing slice tag")
if "enum SettingsSectionChromeCopy" not in prefs:
    fail("missing SettingsSectionChromeCopy")

for needle in (
    'windowTitleKey = "LaunchIcon 设置"',
    'pageTitleKey = "通用"',
    'appearanceSectionKey = "外观与呼出"',
    'behaviorSectionKey = "行为"',
    'appsSectionKey = "应用管理"',
    'maintenanceSectionKey = "维护"',
    'unknownVersionKey = "未知"',
    'sourceFormatKey = "源码 %@"',
    'developmentBuildKey = "开发构建"',
    'versionFormatKey = "版本 %@ (%@) · %@"',
    'fullCommitFormatKey = "完整源码提交：%@"',
):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")

for helper in (
    "SettingsSectionChromeCopy.windowTitle",
    "SettingsSectionChromeCopy.pageTitle",
    "SettingsSectionChromeCopy.appearanceSectionTitle",
    "SettingsSectionChromeCopy.behaviorSectionTitle",
    "SettingsSectionChromeCopy.appsSectionTitle",
    "SettingsSectionChromeCopy.maintenanceSectionTitle",
    "SettingsSectionChromeCopy.unknownVersion",
    "SettingsSectionChromeCopy.sourceLabel",
    "SettingsSectionChromeCopy.developmentBuild",
    "SettingsSectionChromeCopy.versionLine",
    "SettingsSectionChromeCopy.fullCommitHelp",
):
    if helper not in settings:
        fail(f"Settings missing {helper}")

for bad in (
    'L("LaunchIcon 设置")',
    'L("通用")',
    'L("外观与呼出")',
    'L("行为")',
    'L("应用管理")',
    'L("维护")',
    'L("未知")',
    'L("源码 %@")',
    'L("开发构建")',
    'L("版本 %@ (%@) · %@")',
    'L("完整源码提交：%@")',
):
    if bad in settings:
        fail(f"Settings still has {bad}")

print("PASS: settings section chrome owned by Core")

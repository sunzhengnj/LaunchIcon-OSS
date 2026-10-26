#!/usr/bin/env python3
"""SETTINGS-DISPLAY-FEEDBACK-01: display-target help + settings feedback in Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "SETTINGS-DISPLAY-FEEDBACK-01" not in prefs:
    fail("Core missing slice tag")
if "enum DisplayTargetCopy" not in prefs or "enum SettingsFeedbackCopy" not in prefs:
    fail("missing DisplayTargetCopy / SettingsFeedbackCopy")

for needle in (
    'labelKey = "显示于"',
    "连接多台显示器时，选择启动器出现在哪台显示器上",
    'appliedKey = "设置已应用"',
    'rescanningKey = "正在重新扫描"',
):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")

for helper in (
    "DisplayTargetCopy.label",
    "DisplayTargetCopy.accessibilityHelp",
    "SettingsFeedbackCopy.applied",
    "SettingsFeedbackCopy.rescanning",
):
    if helper not in settings:
        fail(f"Settings missing {helper}")

for bad in (
    'L("显示于")',
    'L("连接多台显示器时，选择启动器出现在哪台显示器上；下次打开启动器时生效")',
    'L("设置已应用")',
    'L("正在重新扫描")',
):
    if bad in settings:
        fail(f"Settings still has {bad}")

print("PASS: settings display/feedback copy owned by Core")

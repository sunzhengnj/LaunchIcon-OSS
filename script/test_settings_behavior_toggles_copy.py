#!/usr/bin/env python3
"""SETTINGS-BEHAVIOR-TOGGLES-COPY-01: behavior toggle chrome in Core; AX ids."""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
strings = json.loads((ROOT / "Resources/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for needle in (
    "enum SettingsBehaviorTogglesCopy",
    "hideAfterLaunchTitleKey",
    "reducesMotionTitleKey",
    "loginTitleKey",
    "loginNeedsApprovalKey",
):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")

if "testSettingsBehaviorTogglesCopy" not in tests:
    fail("Core test missing")

for needle in (
    "SettingsBehaviorTogglesCopy.hideAfterLaunchTitle",
    "SettingsBehaviorTogglesCopy.reducesMotionTitle",
    "SettingsBehaviorTogglesCopy.loginTitle",
    "settings-hide-after-launch",
    "settings-reduces-motion",
    "settings-login-item",
    "settings-open-login-settings",
    "SettingsBehaviorTogglesCopy.loginNeedsApproval",
):
    if needle not in settings:
        fail(f"Settings missing {needle!r}")

for bad in (
    'checkboxWithTitle: L("启动应用后自动收起")',
    'checkboxWithTitle: L("减少动态效果")',
    'checkboxWithTitle: L("开机登录")',
    'title: L("打开系统登录项设置…")',
):
    if bad in settings:
        fail(f"Settings still hardcodes {bad}")

if "showPage(" in settings or "pageTransition" in settings:
    fail("settings must not touch paging")

for key in (
    "启动应用后自动收起",
    "减少动态效果",
    "开机登录",
    "打开系统登录项设置…",
    "开机登录设置已更新",
    "请在系统设置的登录项中允许 LaunchIcon。",
):
    if key not in strings:
        fail(f"xcstrings missing {key!r}")

print("PASS: settings behavior toggles copy wired")

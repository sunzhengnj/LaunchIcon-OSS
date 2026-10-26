#!/usr/bin/env python3
"""SETTINGS-APPEARANCE-CHROME-COPY-01: appearance chrome in Core; AX ids."""
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
    "enum SettingsAppearanceChromeCopy",
    "statusItemTitleKey",
    "hideNamesRowTitleKey",
    "shortcutLabelKey",
):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")

if "testSettingsAppearanceChromeCopy" not in tests:
    fail("Core test missing")

for needle in (
    "SettingsAppearanceChromeCopy.statusItemTitle",
    "SettingsAppearanceChromeCopy.hideNamesRowTitle",
    "SettingsAppearanceChromeCopy.shortcutLabel",
    "settings-status-item",
    "settings-hide-app-names",
    "settings-hide-folder-names",
):
    if needle not in settings:
        fail(f"Settings missing {needle!r}")

for bad in (
    'checkboxWithTitle: L("显示菜单栏图标")',
    'checkboxWithTitle: L("应用")',
    'checkboxWithTitle: L("文件夹")',
    'title: L("隐藏名称")',
    'L("呼出快捷键")',
    'L("呼出触发角")',
):
    if bad in settings:
        fail(f"Settings still hardcodes {bad}")

if "showPage(" in settings or "pageTransition" in settings:
    fail("settings must not touch paging")

if "左键切换启动器" not in prefs or "Option" not in prefs:
    fail("statusItemHelp must document left/right/Option click")

for key in ("显示菜单栏图标", "隐藏名称", "呼出快捷键", "呼出触发角", "隐藏应用名称",
            "左键切换启动器，右键打开菜单，按住 Option 再左键打开设置。关闭后仍可用快捷键呼出；从启动器顶部设置按钮或按 Command-逗号可再次打开设置"):
    if key not in strings:
        fail(f"xcstrings missing {key!r}")

print("PASS: settings appearance chrome copy wired")

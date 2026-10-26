#!/usr/bin/env python3
"""SETTINGS-REARRANGE-BUTTONS-COPY-01: name/kind/category Settings chrome in Core."""
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
    "settingsButtonTitleKey",
    "settingsAccessibilityHelpKey",
    'case .byName: return "按名称排列"',
    'case .byKind: return "按类型排列"',
):
    if needle not in core:
        fail(f"Core GridRearrangeSort missing {needle!r}")

cat = core[core.index("enum CategoryRearrangeCopy"): core.index("enum CategoryRearrangeCopy") + 900]
for needle in (
    'settingsButtonTitleKey = "按分类排列"',
    "settingsAccessibilityHelpKey",
):
    if needle not in cat:
        fail(f"CategoryRearrangeCopy missing {needle!r}")

if "testSettingsRearrangeButtonsCopy" not in tests:
    fail("Core test missing")

for needle in (
    "GridRearrangeSort.byName.settingsButtonTitleKey",
    "GridRearrangeSort.byKind.settingsButtonTitleKey",
    "CategoryRearrangeCopy.settingsButtonTitleKey",
    "GridRearrangeSort.byName.settingsAccessibilityHelpKey",
    "GridRearrangeSort.byKind.settingsAccessibilityHelpKey",
    "CategoryRearrangeCopy.settingsAccessibilityHelpKey",
    "settings-rearrange-by-name",
    "settings-rearrange-by-kind",
    "settings-rearrange-by-category",
):
    if needle not in settings:
        fail(f"Settings missing {needle!r}")

for bad in (
    'title: L("按名称排列")',
    'title: L("按类型排列")',
    'title: L("按分类排列")',
    'setAccessibilityLabel(L("按名称排列"))',
    'setAccessibilityLabel(L("按类型排列"))',
    'setAccessibilityLabel(L("按分类排列"))',
    'setAccessibilityHelp(L("按显示名称重新排列主屏幕图标；文件夹内应用不变"))',
    'setAccessibilityHelp(L("系统应用在前，其余按名称；文件夹内应用不变"))',
    'setAccessibilityHelp(L("按应用分类分组，组内按名称；文件夹内应用不变"))',
):
    if bad in settings:
        fail(f"Settings still hardcodes {bad}")

if "showPage(" in settings or "pageTransition" in settings:
    fail("settings must not touch paging")

for key in ("按名称排列", "按类型排列", "按分类排列",
            "按显示名称重新排列主屏幕图标；文件夹内应用不变",
            "系统应用在前，其余按名称；文件夹内应用不变",
            "按应用分类分组，组内按名称；文件夹内应用不变"):
    if key not in strings:
        fail(f"xcstrings missing {key!r}")

print("PASS: settings rearrange buttons copy wired")

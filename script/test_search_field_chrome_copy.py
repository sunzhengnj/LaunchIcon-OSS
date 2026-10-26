#!/usr/bin/env python3
"""SEARCH-FIELD-CHROME-01: search/count/settings chrome owned by Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
layout = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "SEARCH-FIELD-CHROME-01" not in layout:
    fail("Core missing slice tag")
if "enum SearchFieldChromeCopy" not in layout:
    fail("missing SearchFieldChromeCopy")

for needle in (
    'searchPlaceholderKey = "搜索应用"',
    'searchHelpKey = "按应用名称或 Bundle ID 搜索"',
    'clearSearchKey = "清除搜索"',
    'clearSearchHelpKey = "清除搜索并返回应用网格"',
    'escReturnKey = "Esc 返回"',
    'escReturnWithPagingKey = "← → 翻页 · Esc 返回"',
    'resultsFormatKey = "%d 个结果"',
    'itemsFormatKey = "%d 个项目"',
    'settingsKey = "设置"',
    'settingsHelpKey = "打开 LaunchIcon 设置"',
    "CatalogEmptyChromeCopy.searchNoMatchesDefaultDetailKey",
    "func footerNavigationText",
):
    if needle not in layout:
        fail(f"Core missing {needle!r}")

for helper in (
    "LauncherLayout.SearchFieldChromeCopy.searchPlaceholder",
    "LauncherLayout.SearchFieldChromeCopy.searchAccessibilityLabel",
    "LauncherLayout.SearchFieldChromeCopy.searchHelp",
    "LauncherLayout.SearchFieldChromeCopy.clearSearchLabel",
    "LauncherLayout.SearchFieldChromeCopy.clearSearchHelp",
    "LauncherLayout.SearchFieldChromeCopy.escClearSearch",
    "LauncherLayout.SearchFieldChromeCopy.footerNavigationText",
    "LauncherLayout.SearchFieldChromeCopy.resultsCountText",
    "LauncherLayout.SearchFieldChromeCopy.resultsAccessibilityLabel",
    "LauncherLayout.SearchFieldChromeCopy.selectedAccessibilityLabel",
    "LauncherLayout.SearchFieldChromeCopy.itemsCountText",
    "LauncherLayout.SearchFieldChromeCopy.itemsAccessibilityLabel",
    "LauncherLayout.SearchFieldChromeCopy.settingsLabel",
    "LauncherLayout.SearchFieldChromeCopy.settingsHelp",
):
    if helper not in direct:
        fail(f"Direct missing {helper}")

for bad in (
    'L("搜索应用")',
    'L("按应用名称或 Bundle ID 搜索")',
    'L("清除搜索")',
    'L("清除搜索并返回应用网格")',
    'L("Esc 清除搜索")',
    'L("Esc 返回")',
    'L("← → 翻页 · Esc 返回")',
    'L("%d 个结果")',
    'L("搜索结果数量")',
    'L("已选数量")',
    'L("%d 个项目")',
    'L("应用数量")',
    'L("打开 LaunchIcon 设置")',
):
    if bad in direct:
        fail(f"Direct still has {bad}")

# Settings gear label may still appear as menu title 设置… — only ban bare L("设置") on gear sites.
# After wire, accessibilityDescription / toolTip / setAccessibilityLabel should use Core.
if 'accessibilityDescription: L("设置")' in direct:
    fail("settings gear still uses L(设置)")
if 'toolTip = L("设置")' in direct:
    fail("settings toolTip still L")

print("PASS: search-field chrome owned by Core")

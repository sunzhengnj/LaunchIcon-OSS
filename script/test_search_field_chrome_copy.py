#!/usr/bin/env python3
"""SEARCH-FIELD-CHROME-01: search/count/settings chrome owned by Core."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
layout = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "SEARCH-FIELD-CHROME-01" not in layout and "SEARCH-FIELD-CHROME-02" not in layout:
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

# SEARCH-FIELD-CHROME-02 sizes
w = re.search(r"searchFieldWidth:\s*CGFloat\s*=\s*(\d+)", layout)
h = re.search(r"searchFieldHeight:\s*CGFloat\s*=\s*(\d+)", layout)
r = re.search(r"searchFieldCornerRadius:\s*CGFloat\s*=\s*(\d+)", layout)
if not w or int(w.group(1)) != 360:
    fail(f"searchFieldWidth expected 360, got {w.group(1) if w else None}")
if not h or int(h.group(1)) != 36:
    fail(f"searchFieldHeight expected 36, got {h.group(1) if h else None}")
if not r or int(r.group(1)) != 18:
    fail(f"searchFieldCornerRadius expected 18, got {r.group(1) if r else None}")
if "searchSettingsButtonSize" not in layout:
    fail("missing searchSettingsButtonSize")
if "LauncherLayout.searchSettingsButtonSize" not in direct:
    fail("Direct must use searchSettingsButtonSize")


# SEARCH-FIELD-CHROME-03: vertical center cell
for needle in (
    "SEARCH-FIELD-CHROME-03",
    "private final class LauncherSearchFieldCell: NSSearchFieldCell",
    'searchField.cell = LauncherSearchFieldCell(textCell: "")',
    "override func drawingRect(forBounds rect: NSRect) -> NSRect",
    "override func titleRect(forBounds rect: NSRect) -> NSRect",
    "override func searchButtonRect(forBounds rect: NSRect) -> NSRect",
    "override func cancelButtonRect(forBounds rect: NSRect) -> NSRect",
):
    if needle not in direct:
        fail(f"Direct missing {needle!r}")

# SEARCH-FIELD-CELL-EDITABLE-01: the replacement cell must stay an editable text cell.
install = direct.index('searchField.cell = LauncherSearchFieldCell(textCell: "")')
after = direct[install:install + 900]
for needle in ("SEARCH-FIELD-CELL-EDITABLE-01", "cell.isEditable = true", "cell.isSelectable = true", "cell.isScrollable = true"):
    if needle not in after:
        fail(f"replacement search cell missing {needle!r}")

# SEARCH-FIELD-TEXT-CENTER-01: drawing rect and field editor clip share one centered line.
cell_s = direct.index("private final class LauncherSearchFieldCell")
cell = direct[cell_s:direct.index("private final class LauncherSearchField: NSSearchField", cell_s)]
for needle in ("SEARCH-FIELD-TEXT-CENTER-01", "singleLineHeight", "centerFieldEditorClip", "override func select(", "override func edit("):
    if needle not in cell:
        fail(f"search cell missing {needle!r}")

print("PASS: search-field chrome owned by Core")

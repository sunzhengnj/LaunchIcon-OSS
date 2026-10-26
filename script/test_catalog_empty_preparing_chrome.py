#!/usr/bin/env python3
"""CATALOG-EMPTY-PREPARING-CHROME-01: empty/preparing chrome copy lives in Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "CATALOG-EMPTY-PREPARING-CHROME-01" not in core:
    fail("Core missing slice tag")
if "enum CatalogEmptyChromeCopy" not in core:
    fail("missing CatalogEmptyChromeCopy")

for needle in (
    'preparingMessageKey = "正在准备应用…"',
    'catalogUnavailableTitleKey = "未找到可用的应用"',
    'catalogUnavailableDetailKey = "请确认应用位于 Applications 文件夹，然后重新扫描。"',
    'catalogCancelledTitleKey = "扫描已取消"',
    'catalogCancelledDetailKey = "应用扫描已取消，请重新扫描。"',
    'searchNoMatchesTitleKey = "未找到匹配的应用"',
    'searchNoMatchesDefaultDetailKey = "按 Esc 清除搜索"',
    'reloadButtonTitleKey = "重新扫描"',
    'useCachedButtonTitleKey = "使用上次应用列表"',
    'useCachedHelpKey = "使用本机上次完整扫描的应用列表；整理功能暂不可用"',
    'rescanRestoreHelpKey = "重新扫描应用并恢复可整理的列表"',
    "func content(",
):
    if needle not in core:
        fail(f"Core missing {needle!r}")

# Must not touch paging in the new enum block
idx = core.index("enum CatalogEmptyChromeCopy")
chunk = core[idx:idx + 2500]
for bad in ("showPage", "pageTransition", "pageAnimation", "scrollToPage"):
    if bad in chunk:
        fail(f"CatalogEmptyChromeCopy must not touch paging ({bad})")

for helper in (
    "CatalogEmptyChromeCopy.preparingMessage",
    "CatalogEmptyChromeCopy.content(",
    "CatalogEmptyChromeCopy.reloadButtonTitle",
    "CatalogEmptyChromeCopy.useCachedButtonTitle",
    "CatalogEmptyChromeCopy.useCachedHelp",
    "CatalogEmptyChromeCopy.rescanRestoreHelp",
    "CatalogEmptyChromeCopy.defaultReloadHelp",
):
    if helper not in direct:
        fail(f"Direct missing {helper}")

for bad in (
    'L("正在准备应用…")',
    'L("未找到可用的应用")',
    'L("请确认应用位于 Applications 文件夹，然后重新扫描。")',
    'L("扫描已取消")',
    'L("应用扫描已取消，请重新扫描。")',
    'L("未找到匹配的应用")',
    'L("按 Esc 清除搜索")',
    'L("重新扫描标准 Applications 文件夹")',
    'L("重新扫描应用")',
    'L("使用上次应用列表")',
    'L("使用本机上次完整扫描的应用列表；整理功能暂不可用")',
    'L("重新扫描应用并恢复可整理的列表")',
    'L("重新扫描")',
):
    if bad in direct:
        fail(f"Direct still has {bad}")

print("PASS: catalog empty/preparing chrome owned by Core")

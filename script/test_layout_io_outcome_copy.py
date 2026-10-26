#!/usr/bin/env python3
"""LAYOUT-IO-OUTCOME-COPY-01: export/import/Launchpad/restore outcomes live in Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
delegate = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "LAYOUT-IO-OUTCOME-COPY-01" not in core:
    fail("Core missing slice tag")
if "enum LayoutIOOutcomeCopy" not in core:
    fail("missing LayoutIOOutcomeCopy")

keys = [
    'exportSucceededKey = "布局已导出"',
    'exportUnsupportedSchemaKey = "布局版本不受支持，无法导出"',
    'exportFailedKey = "导出布局失败"',
    'exportUnavailableKey = "当前无法导出布局"',
    'importUnsupportedSchemaKey = "布局版本不受支持，无法导入"',
    'importUnreadableFileKey = "无法读取布局文件"',
    'importUnavailableKey = "当前无法导入布局"',
    'layoutEditingBlockedKey = "暂时无法整理，请查看主界面提示"',
    'layoutUpdatedToastKey = "布局已更新"',
    'launchpadEmptyKey = "启动台数据库里没有应用"',
    'launchpadUnreadableKey = "无法读取启动台数据库"',
    'launchpadDefaultFolderNameKey = "文件夹"',
    'restoreNoBackupKey = "没有可用备份"',
    'restoreUnsupportedSchemaKey = "备份版本不受支持，无法恢复"',
    'restoreUnreadableKey = "无法读取备份"',
    'restoreUnavailableKey = "当前无法恢复备份"',
]
for k in keys:
    if k not in core:
        fail(f"Core missing {k!r}")

# Direct must not keep Chinese outcome literals in these helpers
chunks = {
    "exportLayout": direct[direct.index("func exportLayout(to"):direct.index("func exportLayout(to")+700],
    "importLayout": direct[direct.index("func importLayout(from"):direct.index("func importLayout(from")+900],
    "importLaunchpadLayout": direct[direct.index("func importLaunchpadLayout(from"):direct.index("func importLaunchpadLayout(from")+900],
    "restoreLastLayoutBackup": direct[direct.index("func restoreLastLayoutBackup"):direct.index("func restoreLastLayoutBackup")+1100],
    "applyImportedLayout": direct[direct.index("func applyImportedLayout"):direct.index("func applyImportedLayout")+700],
}
for name, chunk in chunks.items():
    if "LAYOUT-IO-OUTCOME-COPY-01" not in chunk and name != "importLayout":
        # importLayout tag is in the catch block; also accept LayoutIOOutcomeCopy
        if "LayoutIOOutcomeCopy" not in chunk:
            fail(f"{name} missing Core wiring")
    if "LayoutIOOutcomeCopy" not in chunk:
        fail(f"{name} must call LayoutIOOutcomeCopy")
    for bad in (
        'L("布局已导出")',
        'L("布局版本不受支持，无法导出")',
        'L("导出布局失败")',
        'L("布局版本不受支持，无法导入")',
        'L("无法读取布局文件")',
        'L("暂时无法整理，请查看主界面提示")',
        'L("启动台数据库里没有应用")',
        'L("无法读取启动台数据库")',
        'L("当前无法导入布局")',
        'L("没有可用备份")',
        'L("备份版本不受支持，无法恢复")',
        'L("无法读取备份")',
        'L("布局已更新")',
        'L("文件夹")',
    ):
        if bad in chunk:
            fail(f"{name} still has {bad}")
    for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
        if bad in chunk:
            fail(f"paging symbol {bad} in {name}")

# Delegate unavailable fallbacks
if "LayoutIOOutcomeCopy.exportUnavailable" not in delegate:
    fail("delegate exportUnavailable missing")
if "LayoutIOOutcomeCopy.importUnavailable" not in delegate:
    fail("delegate importUnavailable missing")
if "LayoutIOOutcomeCopy.restoreUnavailable" not in delegate:
    fail("delegate restoreUnavailable missing")
for bad in (
    'L("当前无法导出布局")',
    'L("当前无法导入布局")',
    'L("当前无法恢复备份")',
):
    if bad in delegate:
        fail(f"delegate still has {bad}")

print("PASS: layout I/O outcome copy owned by Core")

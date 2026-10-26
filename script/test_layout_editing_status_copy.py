#!/usr/bin/env python3
"""LAYOUT-EDITING-STATUS-COPY-01: layout-editing/scan status copy lives in Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "LAYOUT-EDITING-STATUS-COPY-01" not in core:
    fail("Core missing slice tag")
if "enum LayoutEditingStatusCopy" not in core:
    fail("missing LayoutEditingStatusCopy")

for needle in (
    'scanningExplanationKey = "正在扫描应用，暂时无法整理"',
    'scanCancelledExplanationKey = "应用扫描已取消，请重新扫描"',
    'cachedCatalogExplanationKey = "正在显示上次应用列表；重新扫描后可整理"',
    'layoutUnreadableExplanationKey = "布局文件无法读取，暂时无法整理；原文件已保留"',
    'incompleteScanExplanationKey = "应用扫描不完整，暂时无法整理；请重新扫描"',
    'defaultBlockedExplanationKey = "应用列表正在加载或不完整，暂时无法整理"',
    'rescanSucceededKey = "重新扫描完成"',
    'rearrangeUnavailableKey = "当前无法重新排列"',
):
    if needle not in core:
        fail(f"Core missing {needle!r}")

for helper in (
    "LayoutEditingStatusCopy.scanningExplanation",
    "LayoutEditingStatusCopy.scanCancelledExplanation",
    "LayoutEditingStatusCopy.cachedCatalogExplanation",
    "LayoutEditingStatusCopy.layoutUnreadableExplanation",
    "LayoutEditingStatusCopy.incompleteScanExplanation",
    "LayoutEditingStatusCopy.defaultBlockedExplanation",
):
    if helper not in direct:
        fail(f"Direct missing {helper}")

if "LayoutEditingStatusCopy.rescanSucceeded" not in settings:
    fail("Settings missing rescanSucceeded")
if "LayoutEditingStatusCopy.rearrangeUnavailable" not in settings:
    fail("Settings missing rearrangeUnavailable")
if settings.count("LayoutIOOutcomeCopy.layoutEditingBlocked") < 2:
    fail("Settings should reuse layoutEditingBlocked for rearrange failures")

for bad in (
    'L("正在扫描应用，暂时无法整理")',
    'L("应用扫描已取消，请重新扫描")',
    'L("正在显示上次应用列表；重新扫描后可整理")',
    'L("布局文件无法读取，暂时无法整理；原文件已保留")',
    'L("应用扫描不完整，暂时无法整理；请重新扫描")',
    'L("应用列表正在加载或不完整，暂时无法整理")',
    'L("重新扫描完成")',
    'L("当前无法重新排列")',
    'L("暂时无法整理，请查看主界面提示")',
):
    if bad in direct or bad in settings:
        fail(f"still has {bad}")

print("PASS: layout editing status copy owned by Core")

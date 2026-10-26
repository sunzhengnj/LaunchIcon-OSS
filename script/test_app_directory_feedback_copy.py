#!/usr/bin/env python3
"""APP-DIRECTORY-FEEDBACK-01: additional app-directory Settings copy in Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "APP-DIRECTORY-FEEDBACK-01" not in prefs:
    fail("Core missing slice tag")
if "enum AppDirectoryCopy" not in prefs:
    fail("missing AppDirectoryCopy")

for needle in (
    'menuTitleKey = "应用目录…"',
    'menuTitleCountedFormatKey = "应用目录（%ld）…"',
    'addFolderTitleKey = "添加文件夹…"',
    'removeHeaderKey = "选择以移除："',
    'panelPromptKey = "添加"',
    'alreadyCoveredKey = "该文件夹已在扫描范围内，或不能作为应用目录"',
    'addedFormatKey = "已添加应用目录：%@"',
    'removedFormatKey = "已移除应用目录：%@"',
    "在默认的 Applications 文件夹之外",
):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")

for helper in (
    "AppDirectoryCopy.menuTitle",
    "AppDirectoryCopy.addFolderTitle",
    "AppDirectoryCopy.removeHeader",
    "AppDirectoryCopy.panelPrompt",
    "AppDirectoryCopy.accessibilityLabel",
    "AppDirectoryCopy.accessibilityHelp",
    "AppDirectoryCopy.alreadyCovered",
    "AppDirectoryCopy.addedMessage",
    "AppDirectoryCopy.removedMessage",
):
    if helper not in settings:
        fail(f"Settings missing {helper}")

for bad in (
    'L("应用目录…")',
    'L("应用目录（%ld）…")',
    'L("添加文件夹…")',
    'L("选择以移除：")',
    'L("添加")',
    'L("该文件夹已在扫描范围内，或不能作为应用目录")',
    'L("已添加应用目录：%@")',
    'L("已移除应用目录：%@")',
    'L("在默认的 Applications 文件夹之外，再扫描你添加的文件夹（例如外置磁盘）")',
):
    if bad in settings:
        fail(f"Settings still has {bad}")

print("PASS: app-directory feedback owned by Core")

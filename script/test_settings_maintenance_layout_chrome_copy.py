#!/usr/bin/env python3
"""SETTINGS-MAINTENANCE-LAYOUT-CHROME-COPY-01: maintenance + layout I/O chrome in Core."""
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
    "enum SettingsMaintenanceChromeCopy",
    "enum SettingsLayoutIOChromeCopy",
    "rescanButtonTitleKey",
    "leftoversCancelTitleKey",
    "exportButtonTitleKey",
    "restoreBackupUnavailableToolTipKey",
):
    if needle not in core:
        fail(f"Core missing {needle!r}")

if "testSettingsMaintenanceLayoutChromeCopy" not in tests:
    fail("Core test missing")

for needle in (
    "SettingsMaintenanceChromeCopy.rescanButtonTitle",
    "SettingsMaintenanceChromeCopy.leftoversButtonTitle",
    "SettingsMaintenanceChromeCopy.leftoversCancelTitle",
    "SettingsLayoutIOChromeCopy.exportButtonTitleKey",
    "SettingsLayoutIOChromeCopy.importButtonTitleKey",
    "SettingsLayoutIOChromeCopy.restoreBackupButtonTitleKey",
    "SettingsLayoutIOChromeCopy.restoreBackupToolTip",
    "settings-cleanup-leftovers",
    "settings-export-layout",
    "settings-restore-layout-backup",
):
    if needle not in settings:
        fail(f"Settings missing {needle!r}")

# Launchpad import chrome intentionally stays Direct-owned for now.
for bad in (
    'title: L("重新扫描")',
    'title: L("残留文件…")',
    'title: L("导出布局…")',
    'title: L("导入布局…")',
    'title: L("恢复上次备份")',
    'L("取消查找")',
    'L("尚无自动备份（修改布局后会生成）")',
):
    if bad in settings:
        fail(f"Settings still hardcodes {bad}")

if "showPage(" in settings or "pageTransition" in settings:
    fail("settings must not touch paging")

for key in (
    "重新扫描",
    "重新扫描 Applications 文件夹",
    "残留文件…",
    "残留文件",
    "取消查找",
    "导出布局…",
    "导入布局…",
    "恢复上次备份",
    "尚无自动备份（修改布局后会生成）",
):
    if key not in strings:
        fail(f"xcstrings missing {key!r}")

print("PASS: settings maintenance + layout I/O chrome copy wired")

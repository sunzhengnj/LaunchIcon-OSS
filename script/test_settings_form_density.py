#!/usr/bin/env python3
"""SETTINGS-FORM-DENSITY-01: Settings uses form rows + popups, not button walls."""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
strings = json.loads((ROOT / "Resources/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for needle in (
    "rearrangeRowTitleKey",
    "layoutRowTitleKey",
    "layoutMenuTitleKey",
    "scanRowTitleKey",
    "rearrangeMenuTitleKey",
    'rearrangeRowTitleKey = "重新排列"',
    'layoutMenuTitleKey = "导出与导入…"',
):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")

if "testSettingsFormDensityCopy" not in tests:
    fail("Core test missing")

for needle in (
    "rearrangePopup",
    "layoutIOPopup",
    "settings-rearrange-by-name",
    "settings-rearrange-by-color",
    "settings-export-layout",
    "settings-import-launchpad",
    "settings-restore-layout-backup",
    "SettingsSectionChromeCopy.rearrangeRowTitle",
    "SettingsSectionChromeCopy.layoutMenuTitle",
    "SettingsSectionChromeCopy.scanRowTitle",
    "restoreLayoutBackupMenuItem",
    "bezelStyle = .flexiblePush",
):
    if needle not in settings:
        fail(f"Settings missing {needle!r}")

# No wall of six rearrange NSButtons.
for bad in (
    "rearrangeByNameButton",
    "rearrangeByKindButton",
    "rearrangeByDateAddedButton",
    "rearrangeDateRow",
):
    if bad in settings:
        fail(f"Settings still has dense control {bad!r}")

hm = re.search(r"height:\s*(\d+)", settings)
wm = re.search(r"width:\s*(\d+)", settings)
if not hm or int(hm.group(1)) > 950:
    fail("Settings height should shrink after density pass (<= 950)")
if not wm or int(wm.group(1)) < 520:
    fail("Settings width should be >= 520 for form labels")

if "showPage(" in settings or "pageTransition" in settings:
    fail("settings must not touch paging")

for key in ("重新排列", "选取排序…", "布局", "导出与导入…", "扫描与清理"):
    if key not in strings:
        fail(f"xcstrings missing {key!r}")

print("PASS: settings form density")

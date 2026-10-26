#!/usr/bin/env python3
"""MENU-CHROME-TITLES-01: app/status menu titles live in Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
delegate = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "MENU-CHROME-TITLES-01" not in core:
    fail("Core missing slice tag")
if "enum MenuChromeCopy" not in core:
    fail("missing MenuChromeCopy")

for needle in (
    'settingsTitleKey = "设置…"',
    'quitAppTitleKey = "退出 LaunchIcon"',
    'quitTitleKey = "退出"',
    'editMenuTitleKey = "编辑"',
    'selectAllTitleKey = "全选"',
    'pasteTitleKey = "粘贴"',
    "CatalogEmptyChromeCopy.reloadButtonTitle",
):
    if needle not in core:
        fail(f"Core missing {needle!r}")

idx = core.index("enum MenuChromeCopy")
chunk = core[idx:idx + 1800]
for bad in ("showPage", "pageTransition", "pageAnimation"):
    if bad in chunk:
        fail(f"MenuChromeCopy must not touch paging ({bad})")

for helper in (
    "MenuChromeCopy.settingsTitle",
    "MenuChromeCopy.quitAppTitle",
    "MenuChromeCopy.quitTitle",
    "MenuChromeCopy.editMenuTitle",
    "MenuChromeCopy.selectAllTitle",
    "MenuChromeCopy.pasteTitle",
    "MenuChromeCopy.reloadCatalogTitle",
    "statusItemToggleTitle(isVisible: false, isDismissing: false)",
):
    if helper not in delegate:
        fail(f"delegate missing {helper}")

for bad in (
    'L("设置…")',
    'L("退出 LaunchIcon")',
    'L("退出")',
    'L("编辑")',
    'L("全选")',
    'L("粘贴")',
    'L("重新扫描")',
    'L("显示 LaunchIcon")',
):
    if bad in delegate:
        fail(f"delegate still has {bad}")

print("PASS: menu chrome titles owned by Core")

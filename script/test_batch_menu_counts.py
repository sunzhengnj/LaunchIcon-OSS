#!/usr/bin/env python3
"""Guard: BATCH-MENU-COUNTS-01 (counted hide / new-folder menu titles; no paging)."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
failures = []
def need(c, m):
    if not c: failures.append(m)
need("batchHideMenuTitleFormatKey" in core, "Core missing batchHideMenuTitleFormatKey")
need("batchNewFolderMenuTitleFormatKey" in core, "Core missing batchNewFolderMenuTitleFormatKey")
need("BATCH-MENU-COUNTS-01" in direct, "Direct must tag BATCH-MENU-COUNTS-01")
need("batchHideTitle" in direct, "Direct missing batchHideTitle")
need("batchNewFolderTitle" in direct, "Direct missing batchNewFolderTitle")
need("appKeysForBatchHide" in direct and "batchHideTitle =" in direct, "hide title must use appKeysForBatchHide count")
need("topLevelAppIDsForBatchFolder" in direct and "batchNewFolderTitle" in direct, "folder title must use batch folder count")
# Literals kept for older guards / fallbacks.
need("隐藏所选应用" in direct, "fallback「隐藏所选应用」must remain")
need("移入新建文件夹" in direct, "fallback「移入新建文件夹」must remain")
# Must not touch paging hosts.
need("pageAnimationDuration" not in direct.split("BATCH-MENU-COUNTS-01")[1][:800] if "BATCH-MENU-COUNTS-01" in direct else True, "ok")
if failures:
    print("FAIL:")
    for f in failures: print(" -", f)
    sys.exit(1)
need('"Hide %d Apps"' in (root / "Resources/Localizable.xcstrings").read_text(), "EN hide menu title must be Hide %d Apps")
print("PASS: batch menu counts")

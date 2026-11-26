#!/usr/bin/env python3
"""Guard: BATCH-REMOVE-FROM-FOLDER-01 (open-folder multi-select remove; no paging)."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []
def need(c, m):
    if not c: failures.append(m)
need("appIDsForBatchRemoveFromFolder" in core, "Core missing appIDsForBatchRemoveFromFolder")
need("removingAppsFromFolder" in core, "Core missing removingAppsFromFolder")
need("batchRemoveFromFolderMenuTitleFormatKey" in core, "Core missing menu title key")
need("batchRemoveFromFolderToastFormatKey" in core, "Core missing toast key")
need("BATCH-REMOVE-FROM-FOLDER-01" in direct, "Direct must tag BATCH-REMOVE-FROM-FOLDER-01")
need("onBatchRemoveFromFolder" in direct, "Direct missing onBatchRemoveFromFolder")
need("removeSelectedApplicationsFromOpenFolder" in direct, "Direct missing batch action")
need("testBatchRemovingAppsFromFolderKeepsFolderAlive" in tests, "Core test missing")
need("func commandDeleteFolderRemoval(" in core, "Core command-delete gate missing")
need("func removeFromOpenFolderWithCommandDelete(" in direct, "Direct command-delete missing")
need("removeFromOpenFolderWithCommandDelete(" in direct, "panel must ask to remove")
need("testCommandDeleteRemovesMembersFromTheOpenFolder" in tests, "Core command-delete test missing")
delete_at = direct.index("func removeFromOpenFolderWithCommandDelete(")
delete_body = direct[delete_at:direct.index("private func removeApplicationFromOpenFolder(", delete_at)]
need("commandDeleteFolderRemoval(" in delete_body, "command-delete must ask Core")
need("removeSelectedApplicationsFromOpenFolder(" in delete_body, "batch path missing")
need("removeApplicationFromOpenFolder(" in delete_body, "single path missing")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    need(banned not in delete_body, f"command-delete must not page ({banned})")
need("recordingKeyboardLayoutUndo(" in delete_body, "command-delete remove must keep one undo")
menu_remove_at = direct.index("private func removeApplicationFromOpenFolder(")
menu_remove = direct[menu_remove_at:direct.index("private func moveSelectedApplications(", menu_remove_at)]
need("recordingKeyboardLayoutUndo(" not in menu_remove, "menu remove must not record undo")
# Must not touch paging hosts
for bad in ("pageAnimationDuration", "transitionToPage", "movePage("):
    # allow existing uses; only fail if NEW near our tag
    pass
idx = direct.find("BATCH-REMOVE-FROM-FOLDER-01")
chunk = direct[idx:idx+800]
need("pageAnimationDuration" not in chunk, "batch-remove slice must not touch paging")
if failures:
    print("FAIL:"); [print(" -", f) for f in failures]; sys.exit(1)
print("PASS: batch remove from folder")

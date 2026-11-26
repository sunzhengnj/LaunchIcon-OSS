#!/usr/bin/env python3
"""BATCH-DISSOLVE-FOLDERS-01: multi-select folder dissolve Core + Direct (no paging)."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
xc = (ROOT / "Resources/Localizable.xcstrings").read_text(encoding="utf-8")
docs = (ROOT / "Docs/MULTI_SELECT_DESIGN.md").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

for sym in (
    "folderIDsForBatchDissolve",
    "dissolvingFolders",
    "batchDissolveFoldersMenuTitleFormatKey",
    "batchDissolveFoldersConfirmTitleKey",
):
    if sym not in core:
        fail(f"Core missing {sym}")

if "testBatchDissolveFoldersRequiresAnchorInMultiFolderSelection" not in tests:
    fail("Core test missing")

if "BATCH-DISSOLVE-FOLDERS-01" not in direct:
    fail("Direct missing slice tag")
if "dissolveSelectedFolders" not in direct:
    fail("Direct missing dissolveSelectedFolders")
if "onBatchDissolveFolders" not in direct:
    fail("Direct missing onBatchDissolveFolders")
if "batchDissolveFoldersMenuItem" not in direct:
    fail("Direct missing menu selector")

# Cancel-first confirm (UNGROUP-ALL-CONFIRM-COPY-01: Core button helpers)
fn = "private func dissolveSelectedFolders(anchorID: UUID)"
if fn not in direct:
    fail("dissolveSelectedFolders signature missing")
chunk = direct[direct.index(fn) : direct.index(fn) + 1800]
if "dissolveConfirmCancelButtonTitle" not in chunk:
    fail("confirm must use Core cancel button helper")
if "dissolveConfirmDestructiveButtonTitle" not in chunk:
    fail("confirm must use Core dissolve button helper")
if chunk.find("dissolveConfirmCancelButtonTitle") > chunk.find("dissolveConfirmDestructiveButtonTitle"):
    fail("取消 helper must precede 解散 helper")
if "dissolveConfirmButtonTitleKey" not in core:
    fail("Core missing dissolveConfirmButtonTitleKey")
for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
    if bad in chunk:
        fail(f"paging symbol {bad} in dissolveSelectedFolders — refuse")

if '"解散 %d 个文件夹…"' not in xc:
    fail("xcstrings missing menu title")
if '"解散选中的文件夹？"' not in xc:
    fail("xcstrings missing confirm title")

if "BATCH-DISSOLVE-FOLDERS" not in docs and "Batch dissolve" not in docs:
    fail("MULTI_SELECT_DESIGN.md must mention batch dissolve folders")

if "func commandDeleteDissolvesClosedFolder(" not in core:
    fail("Core command-delete dissolve gate missing")
if "func dissolveFocusedFolderWithCommandDelete(" not in direct:
    fail("Direct command-delete dissolve missing")
if "dissolveFocusedFolderWithCommandDelete(" not in direct:
    fail("panel must ask to dissolve")
if "testCommandDeleteDissolvesTheFocusedFolderWhenNoneIsOpen" not in tests:
    fail("Core command-delete dissolve test missing")
dissolve_at = direct.index("func dissolveFocusedFolderWithCommandDelete(")
dissolve_body = direct[dissolve_at:direct.index("private func dissolveFolderFromMenu(", dissolve_at)]
if "commandDeleteDissolvesClosedFolder(" not in dissolve_body:
    fail("command-delete dissolve must ask Core")
if "dissolveSelectedFolders(" not in dissolve_body:
    fail("batch dissolve path missing")
if "dissolveFolderFromMenu(" not in dissolve_body:
    fail("single dissolve path missing")
for bad in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    if bad in dissolve_body:
        fail(f"command-delete dissolve must not page ({bad})")
if "recordingKeyboardLayoutUndo(" not in dissolve_body:
    fail("command-delete dissolve must keep one undo")
selected_at = direct.index("private func dissolveSelectedFolders(anchorID:")
selected_body = direct[selected_at:direct.index("func dissolveFocusedFolderWithCommandDelete(", selected_at)]
if "recordingKeyboardLayoutUndo(" in selected_body:
    fail("batch dissolve confirm must not record undo")
menu_dissolve_at = direct.index("private func dissolveFolderFromMenu(")
menu_dissolve = direct[menu_dissolve_at:direct.index("func sortFocusedFolderByNameFromCommandOption(", menu_dissolve_at)]
if "recordingKeyboardLayoutUndo(" in menu_dissolve:
    fail("menu dissolve must not record undo")

if "func commandShiftDeleteUninstallsFocusedApp(" not in core:
    fail("Core command-shift-delete uninstall gate missing")
if "func uninstallFocusedAppFromCommandShiftDelete(" not in direct:
    fail("Direct command-shift-delete uninstall missing")
if "uninstallFocusedAppFromCommandShiftDelete(" not in direct:
    fail("panel must ask to uninstall")
if "testCommandShiftDeleteUninstallsTheFocusedApp" not in tests:
    fail("Core command-shift-delete test missing")
uninstall_at = direct.index("func uninstallFocusedAppFromCommandShiftDelete(")
uninstall_body = direct[uninstall_at:direct.index("private func dissolveFolderFromMenu(", uninstall_at)]
if "commandShiftDeleteUninstallsFocusedApp(" not in uninstall_body:
    fail("uninstall shortcut must ask Core")
if "uninstallSelectedApplications(" not in uninstall_body or "promptToUninstall(" not in uninstall_body:
    fail("uninstall shortcut must use the existing confirms")
for bad in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    if bad in uninstall_body:
        fail(f"command-shift-delete uninstall must not page ({bad})")
if "recordingKeyboardLayoutUndo(" in uninstall_body:
    fail("uninstall must not record layout undo")

print("PASS: batch dissolve folders")

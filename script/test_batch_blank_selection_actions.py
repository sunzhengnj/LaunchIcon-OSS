#!/usr/bin/env python3
"""BLANK-BATCH-SELECTION-ACTIONS-01: blank menu hide / new-folder for multi-select."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
core = (root / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
fails = []

def need(cond, msg):
    if not cond:
        fails.append(msg)

need("appKeysForBatchHide" in core, "Core appKeysForBatchHide")
need("topLevelAppIDsForBatchFolder" in core, "Core topLevelAppIDsForBatchFolder")
need("batchHideMenuTitleFormatKey" in core, "Core hide title format")
need("batchNewFolderMenuTitleFormatKey" in core, "Core folder title format")

need("hideSelectedApplicationsFromBlankAreaMenu" in direct, "blank hide action")
need("moveSelectionToNewFolderFromBlankAreaMenu" in direct, "blank new-folder action")
need("BLANK-BATCH-SELECTION-ACTIONS-01" in direct, "slice marker in blank menu")
need(
    "appKeysForBatchHide(" in direct
    and "hideSelectedApplicationsFromBlankAreaMenu" in direct,
    "blank menu wires hide count",
)
need(
    "topLevelAppIDsForBatchFolder(" in direct
    and "moveSelectionToNewFolderFromBlankAreaMenu" in direct,
    "blank menu wires new-folder count",
)
# Action methods must not sit in the hidden-apps hid window (between
# appendHiddenApplicationsSubmenu and openSettingsFromBlankAreaMenu).
hid_start = direct.find("private func appendHiddenApplicationsSubmenu")
hid_end = direct.find("@objc private func openSettingsFromBlankAreaMenu")
need(hid_start > 0 and hid_end > hid_start, "hid window markers")
hid = direct[hid_start:hid_end]
# Menu builder may reference selectors; action *bodies* must stay outside.
need("@objc private func hideSelectedApplicationsFromBlankAreaMenu" not in hid, "hide action outside hid window")
need("@objc private func moveSelectionToNewFolderFromBlankAreaMenu" not in hid, "folder action outside hid window")
# Reuse existing hide / new-folder implementations (no second commit path).
need(
    "hideSelectedApplications(anchorFocusID:" in direct
    and "moveSelectionToNewFolder()" in direct,
    "actions forward to existing helpers",
)
need("func commandShiftNCreatesFolder(" in core, "Core shortcut gate missing")
need("createFolderFromSelectionShortcut(" in direct, "Direct shortcut missing")
need("testCommandShiftNCreatesAFolderFromTheSelection" in tests, "Core shortcut test missing")
shortcut_at = direct.index("func createFolderFromSelectionShortcut(")
shortcut = direct[shortcut_at : direct.index("private func moveSelectionToNewFolder()", shortcut_at)]
need("commandShiftNCreatesFolder(" in shortcut, "shortcut must ask Core")
need("moveSelectionToNewFolder()" in shortcut, "shortcut must use the existing folder action")
need("recordingKeyboardLayoutUndo(" in shortcut, "new-folder shortcut must keep one undo")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    need(banned not in shortcut, f"shortcut must not page ({banned})")
shared_new = direct[
    direct.index("private func moveSelectionToNewFolder()") : direct.index("private func uninstallDecision(")
]
need("commitLayout(" in shared_new, "new-folder still commits")
need("recordingKeyboardLayoutUndo(" not in shared_new, "blank menu new-folder must not record undo")

need("func commandShiftMMovesSelectionIntoFolder(" in core, "Core move-into-folder gate missing")
need("func moveIntoFolderRequest(" in core, "Core move-into-folder request missing")
need("func moveSelectionIntoFolderFromCommandShiftM(" in direct, "Direct move-into-folder shortcut missing")
need("moveSelectionIntoFolderFromCommandShiftM(" in direct, "panel must ask to move into the folder")
need("testCommandShiftMMovesSelectedAppsIntoTheFolder" in tests, "Core move-into-folder test missing")
move_into = direct[
    direct.index("func moveSelectionIntoFolderFromCommandShiftM(") : direct.index("func createFolderFromSelectionShortcut(")
]
need("commandShiftMMovesSelectionIntoFolder(" in move_into, "move-into-folder must ask Core")
need("moveIntoFolderRequest(" in move_into, "move-into-folder must use the request")
need("moveSelectedApplications(" in move_into, "a batch must use the existing move")
need("moveApplication(" in move_into, "one app must use the existing move")
need("return true" in move_into, "move-into-folder must consume the key")
need("recordingKeyboardLayoutUndo(" in move_into, "move-into-folder shortcut must keep one undo")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage"):
    need(banned not in move_into, f"move-into-folder must not page ({banned})")
menu_move = direct[
    direct.index("private func moveApplication(") : direct.index("func removeFromOpenFolderWithCommandDelete(")
]
need("recordingKeyboardLayoutUndo(" not in menu_move, "menu move-into-folder must not record undo")
batch_menu_move = direct[
    direct.index("private func moveSelectedApplications(") : direct.index("func moveSelectionIntoFolderFromCommandShiftM(")
]
need("commitLayout(" in batch_menu_move, "menu batch move still commits")
need("recordingKeyboardLayoutUndo(" not in batch_menu_move, "menu batch move-into-folder must not record undo")

if fails:
    print("FAIL: blank batch selection actions")
    for f in fails:
        print("-", f)
    sys.exit(1)
print("PASS: blank batch selection actions")

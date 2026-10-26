#!/usr/bin/env python3
"""BLANK-BATCH-SELECTION-ACTIONS-01: blank menu hide / new-folder for multi-select."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
core = (root / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
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

if fails:
    print("FAIL: blank batch selection actions")
    for f in fails:
        print("-", f)
    sys.exit(1)
print("PASS: blank batch selection actions")

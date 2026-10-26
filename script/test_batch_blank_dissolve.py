#!/usr/bin/env python3
"""BLANK-BATCH-DISSOLVE-01: blank menu dissolve ≥2 selected folders."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
core = (root / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
fails = []

def need(cond, msg):
    if not cond:
        fails.append(msg)

need("folderIDsForBatchDissolve" in core, "Core folderIDsForBatchDissolve")
need("batchDissolveFoldersMenuTitleFormatKey" in core, "Core dissolve title format")
need("BLANK-BATCH-DISSOLVE-01" in direct, "slice marker")
need("dissolveSelectedFoldersFromBlankAreaMenu" in direct, "blank dissolve action")
need("BLANK-BATCH-DISSOLVE-SEP-01" in direct, "separator slice marker")
need("dissolveSelectedFolders(anchorID: foldAnchor)" in direct, "reuses dissolveSelectedFolders")
need("folderIDsForBatchDissolve(" in direct, "gates on Core dissolve IDs")
# Action body outside hidden-apps hid window (same markers as reveal guard).
hid_start = direct.find("private func appendHiddenApplicationsSubmenu")
hid_end = direct.find("@objc private func openSettingsFromBlankAreaMenu")
need(hid_start > 0 and hid_end > hid_start, "hid window markers")
hid = direct[hid_start:hid_end]
need("@objc private func dissolveSelectedFoldersFromBlankAreaMenu" not in hid,
     "dissolve action outside hid")
# No paging symbols in the blank dissolve action body.
fn = "@objc private func dissolveSelectedFoldersFromBlankAreaMenu()"
need(fn in direct, "action signature")
chunk = direct[direct.index(fn): direct.index(fn) + 500]
for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
    need(bad not in chunk, f"paging symbol {bad} in blank dissolve action")

if fails:
    print("FAIL: blank batch dissolve")
    for f in fails:
        print("-", f)
    sys.exit(1)
print("PASS: blank batch dissolve")

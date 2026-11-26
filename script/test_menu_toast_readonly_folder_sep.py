#!/usr/bin/env python3
"""APP-MENU-READONLY-REVEAL / FOLDER-MENU-SEP / SEARCH+ICON toast dismiss."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

for needle in (
    "shouldOfferRevealInFinderInAppMenu",
    "shouldSeparateFolderRenameFromSorts",
    "shouldDismissToastWhenBeginningSearch",
    "shouldDismissToastWhenOpeningIconMenu",
    "APP-MENU-READONLY-REVEAL-01",
    "FOLDER-MENU-SEP-AFTER-RENAME-01",
    "SEARCH-BEGIN-DISMISS-TOAST-01",
    "ICON-MENU-DISMISS-TOAST-01",
):
    if needle not in core and needle not in direct:
        fail(f"missing {needle}")

# Reveal gated by layout editing
if "shouldOfferRevealInFinderInAppMenu" not in direct:
    fail("Direct must gate reveal with shouldOfferRevealInFinderInAppMenu")

# Folder sep between rename and sorts
folder_menu = direct.find("FOLDER-MENU-SEP-AFTER-RENAME-01")
if folder_menu < 0:
    fail("folder sep tag missing")
window = direct[folder_menu:folder_menu + 500]
if "shouldSeparateFolderRenameFromSorts" not in window:
    fail("folder menu must call shouldSeparateFolderRenameFromSorts")

# beginSearch peels toast
bs = direct.find("func beginSearch(with event:")
bs_body = direct[bs:bs + 1200]
if "shouldDismissToastWhenBeginningSearch" not in bs_body:
    fail("beginSearch must dismiss toast")

# icon + blank menu peel toast
if direct.count("shouldDismissToastWhenOpeningIconMenu") < 2:
    fail("icon menu and blank menu should both dismiss toast")

for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in bs_body:
        fail(f"paging in beginSearch: {bad}")
print("PASS: menu toast / readonly reveal / folder sep")

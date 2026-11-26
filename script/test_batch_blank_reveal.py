#!/usr/bin/env python3
"""BLANK-BATCH-REVEAL-01: blank menu reveal selected apps in Finder."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
core = (root / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
fails = []

def need(cond, msg):
    if not cond:
        fails.append(msg)

need("revealInFinderURLs" in core, "Core revealInFinderURLs")
need("batchRevealMenuTitleFormatKey" in core, "Core reveal title format")
need("BLANK-BATCH-REVEAL-01" in direct, "slice marker")
need("revealSelectedInFinderFromBlankAreaMenu" in direct, "blank reveal action")
need("onRevealInFinderRequested?(urls)" in direct, "forwards to reveal host")
need("itemSelection.clear()" in direct, "clears selection before Finder")
# Action body outside hidden-apps hid window.
hid_start = direct.find("private func appendHiddenApplicationsSubmenu")
hid_end = direct.find("@objc private func openSettingsFromBlankAreaMenu")
need(hid_start > 0 and hid_end > hid_start, "hid window markers")
hid = direct[hid_start:hid_end]
need("@objc private func revealSelectedInFinderFromBlankAreaMenu" not in hid, "reveal action outside hid")
need("func commandShiftReturnRevealsSelection(" in core, "Core command-shift-return reveal missing")
need("func revealSelectionInFinderFromCommandShiftReturn(" in direct, "Direct command-shift-return reveal missing")
need("revealSelectionInFinderFromCommandShiftReturn(" in direct, "panel must ask to reveal the selection")
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
need("testCommandShiftReturnRevealsTheSelection" in tests, "Core command-shift-return test missing")
reveal_key = direct[direct.index("func revealSelectionInFinderFromCommandShiftReturn("):direct.index("@objc private func revealSelectedInFinderFromBlankAreaMenu()")]
need("commandShiftReturnRevealsSelection(" in reveal_key, "reveal shortcut must ask Core")
need("revealSelectedInFinderFromBlankAreaMenu()" in reveal_key, "reveal shortcut must use the blank-area action")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in reveal_key, f"reveal shortcut must not page ({banned})")

if fails:
    print("FAIL: blank batch reveal")
    for f in fails:
        print("-", f)
    sys.exit(1)
print("PASS: blank batch reveal")

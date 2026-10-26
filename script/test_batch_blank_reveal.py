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

if fails:
    print("FAIL: blank batch reveal")
    for f in fails:
        print("-", f)
    sys.exit(1)
print("PASS: blank batch reveal")

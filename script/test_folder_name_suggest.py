#!/usr/bin/env python3
"""Guard: new folders take a shared category name (menu + drag merge); drop geometry untouched."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("testSuggestedFolderNameKeyUsesSharedCategoryOnly" in tests, "Core suggestion test missing")
start = direct.index("let newFolderName: String = {")
block = direct[start:direct.index("}()", start)]
need("batchIntoFolder == nil" in block, "moving into an existing folder keeps its name")
need("layoutState.folders[targetAppID] == nil" in block, "dropping on a folder must not rename it")
need("LauncherLayout.suggestedFolderNameKey(" in block and "emptyFolderDisplayName" in block, "suggestion with Core empty-name fallback")
for banned in ("showPage", "currentPage", "pageTransition", "scrollToPage", "queueDropLanding"):
    need(banned not in block, f"name suggestion must not touch paging/drop animation ({banned})")
need(direct.count("newFolderName: newFolderName") == 1 and "name: newFolderName" in direct,
     "both create-folder drop paths use the suggestion")
need('newFolderName: L("新建文件夹")' not in direct, "drop path must not hard-code the folder name")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: folder name suggestion")

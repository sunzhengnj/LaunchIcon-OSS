#!/usr/bin/env python3
"""Guard: open-folder「移出文件夹」never dissolves the open folder and never pages."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("testRemovingAppFromFolderKeepsFolderAlive" in tests, "Core test missing")
need("removeFromFolderMinimumMembers = 3" in core, "folder must keep >=2 members")
start = direct.index("private func removeApplicationFromOpenFolder(")
block = direct[start:direct.index("\n    }\n", start)]
need("isLayoutEditingEnabled" in block and "acceptsIconContextMenuAction()" in block, "lock + menu guard")
need("openedFolderID == folderID" in block, "only for the folder on screen")
for banned in ("showPage", "currentPage", "pageTransition", "scrollToPage", "closeFolder(", "focusMainGridEntry"):
    need(banned not in block, f"remove-from-folder must not page/close ({banned})")
need("collectionView === folderOverlay.collectionView" in direct, "only wired in the folder overlay")
need("hasRemoveFromFolder = onRemoveFromFolder != nil && !batchHide" in direct, "single item only")
need("onRemoveFromFolder = nil" in direct, "cleared on reuse")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: folder remove member")

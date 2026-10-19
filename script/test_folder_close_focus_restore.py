#!/usr/bin/env python3
"""Guard: close-folder focus restore (Esc/dimmer → folder tile; dissolve → neighbor)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("folderCloseGridFocusID" in core, "Core missing folderCloseGridFocusID")
need("testFolderCloseGridFocusPrefersFolderThenDissolvedNeighbor" in tests, "Core test missing")
need("pendingFolderCloseFocusPreviousEntries" in direct, "must park previous entries on close")
need("focusMainGridEntry" in direct, "must focus main grid (not search divert)")
need("folderCloseGridFocusID" in direct, "land/dissolve must resolve via Core")

land = direct[direct.index("func finishFolderCloseChromeLand"):direct.index("func focusedOpenFolderMember")]
need("focusMainGridEntry" in land, "finish land must use focusMainGridEntry")
need("folderCloseGridFocusID" in land, "finish land must use folderCloseGridFocusID")
need("pendingFolderCloseFocusPreviousEntries" in land, "land must consume previous snapshot")

esc = direct[direct.index("func handleEscape() -> Bool"):direct.index("var highlightedLaunchKey")]
need("closeFolder()" in esc, "Esc must closeFolder (default restoreFocus true)")

need("folderOpenEmptyFocusesTitle" in direct, "must not regress empty-title focus")
need("folderTitleEndFocusTarget" in direct, "must not regress title-end empty focus")
need("finishFolderBackdropOpen" in direct or "animateOpen" in direct, "dimmer/open path present")

for label, chunk in (
    ("Core close focus", core[core.index("folderCloseGridFocusID"):core.index("folderCloseGridFocusID")+500]),
    ("finish land", land),
):
    need("showPage(" not in chunk and "pageTransition" not in chunk and "pageAnimationDuration" not in chunk,
         f"{label} must not retune paging")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: folder close focus restore (grid tile / dissolved neighbor)")

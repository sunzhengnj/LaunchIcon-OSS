#!/usr/bin/env python3
"""Guard: MULTI-DRAG-BADGE-01 (count pill on multi-select drag image; no paging)."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []
def need(cond, msg):
    if not cond: failures.append(msg)
need("func multiDragBadgeCount(" in core, "Core missing multiDragBadgeCount")
need("MULTI-DRAG-BADGE-01" in core, "Core must tag MULTI-DRAG-BADGE-01")
need("testMultiDragBadgeCountRequiresMultiTopLevelSelection" in tests, "Core badge test missing")
need("multiDragBadgeImage(" in direct, "Direct missing multiDragBadgeImage")
need("multiDragBadgeCount(" in direct, "Direct must call multiDragBadgeCount")
need("systemBlue" in direct[direct.index("multiDragBadgeImage"):direct.index("multiDragBadgeImage")+1200],
     "badge should use systemBlue pill")
start = core.index("func multiDragBadgeCount(")
chunk = core[start:start+700]
need("showPage" not in chunk and "pageTransition" not in chunk, "badge helper must not touch paging")
if failures:
    print("FAIL:"); [print(" -", f) for f in failures]; sys.exit(1)
print("PASS: multi-drag badge")

#!/usr/bin/env python3
"""Guard: MULTI-DRAG-COMPANIONS-01 (hide other selected tiles during multi-drag; no paging)."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
failures=[]
def need(c,m):
    if not c: failures.append(m)
need("hideMultiDragCompanionTiles(" in direct, "Direct missing hideMultiDragCompanionTiles")
need("restoreMultiDragCompanionTiles(" in direct, "Direct missing restoreMultiDragCompanionTiles")
need("MULTI-DRAG-COMPANIONS-01" in direct, "Direct must tag COMPANIONS-01")
need("multiDragHiddenCompanionTiles" in direct, "Direct must track hidden companion tiles")
# restore path must call companions restore
idx = direct.index("private func restoreDragSourceTile()")
chunk = direct[idx:idx+350]
need("restoreMultiDragCompanionTiles()" in chunk, "restoreDragSourceTile must restore companions")
# hide call near beginDraggingSession for multi
need("hideMultiDragCompanionTiles(except:" in direct, "drag start must hide companions when badged")
if failures:
    print("FAIL:"); [print(" -",f) for f in failures]; sys.exit(1)
print("PASS: multi-drag companions")

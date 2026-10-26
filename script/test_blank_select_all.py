#!/usr/bin/env python3
"""Guard: BLANK-SELECT-ALL-01 (blank menu select-all / clear; no paging)."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
failures=[]
def need(c,m):
    if not c: failures.append(m)
need("blankAreaSelectAllMenuTitleKey" in core, "Core missing select-all title key")
need("blankAreaClearSelectionMenuTitleKey" in core, "Core missing clear-selection title key")
need("BLANK-SELECT-ALL-01" in direct, "Direct must tag BLANK-SELECT-ALL-01")
need("selectAllFromBlankAreaMenu" in direct, "Direct missing selectAllFromBlankAreaMenu")
need("clearSelectionFromBlankAreaMenu" in direct, "Direct missing clearSelectionFromBlankAreaMenu")
idx = direct.index("BLANK-SELECT-ALL-01")
chunk = direct[idx:idx+900]
need("selectAllItemsOnCurrentPage" in chunk or "selectAllFromBlankAreaMenu" in direct, "must call select-all")
need("pageAnimationDuration" not in chunk, "must not touch paging")
if failures:
    print("FAIL:"); [print(" -",f) for f in failures]; sys.exit(1)
print("PASS: blank select-all")

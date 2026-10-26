#!/usr/bin/env python3
"""Guard: SELECTED-COUNT-LABEL-01 (count label shows selection; no paging)."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures=[]
def need(c,m):
    if not c: failures.append(m)
need("case selected" in core, "Core SearchCountLabelKind missing .selected")
need("selectionCount: Int" in core, "Core searchCountLabelKind must take selectionCount")
need("selectedCountLabelFormatKey" in core, "Core missing format key")
need("SELECTED-COUNT-LABEL-01" in direct, "Direct must tag SELECTED-COUNT-LABEL-01")
need("case .selected:" in direct, "Direct must handle .selected")
need("selectionCount: itemSelection.count" in direct, "Direct must pass selection count")
need("updateSearchAdjacentChrome(animated: false)" in direct, "selection refresh must update count label")
need("selectionCount: 3" in tests, "Core tests must cover selectionCount")
if failures:
    print("FAIL:"); [print(" -",f) for f in failures]; sys.exit(1)
print("PASS: selected count label")

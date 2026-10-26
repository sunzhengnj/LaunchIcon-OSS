#!/usr/bin/env python3
"""BATCH-BLANK-SELECTED-EDGE-01: blank menu moves multi-select to edge (no paging)."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
xc = (ROOT / "Resources/Localizable.xcstrings").read_text(encoding="utf-8")
docs = (ROOT / "Docs/MULTI_SELECT_DESIGN.md").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

for sym in (
    "topLevelEntryIDsInSelection",
    "movingSelectedTopLevelEntriesToEdge",
    "blankSelectedMovedToStartMenuTitleKey",
    "blankSelectedMovedToEndToastFormatKey",
):
    if sym not in core:
        fail(f"Core missing {sym}")

if "testMovingSelectedTopLevelEntriesToEdgePreservesRelativeOrder" not in tests:
    fail("Core test missing")

if "BATCH-BLANK-SELECTED-EDGE-01" not in direct:
    fail("Direct missing slice tag")
if "moveSelectedEntriesToEdgeFromBlankAreaMenu" not in direct:
    fail("Direct missing action")
if "moveSelectedEntriesToStartFromBlankAreaMenu" not in direct:
    fail("Direct missing start selector")

fn = "private func moveSelectedEntriesToEdgeFromBlankAreaMenu(atStart: Bool)"
if fn not in direct:
    fail("action signature missing")
chunk = direct[direct.index(fn) : direct.index(fn) + 900]
for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
    if bad in chunk:
        fail(f"paging symbol {bad} in blank selected edge — refuse")

if '"所选项目移到最前"' not in xc:
    fail("xcstrings missing start title")
if "BATCH-BLANK-SELECTED-EDGE" not in docs:
    fail("MULTI_SELECT_DESIGN.md must mention blank selected edge")

print("PASS: batch blank selected edge")

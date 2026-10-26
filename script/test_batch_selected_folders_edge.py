#!/usr/bin/env python3
"""BATCH-SELECTED-FOLDERS-EDGE-01: multi-select folders → front/back (no paging)."""
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
    "movingSelectedFoldersToEdge",
    "selectedFoldersMovedToStartMenuTitleKey",
    "selectedFoldersMovedToEndToastFormatKey",
):
    if sym not in core:
        fail(f"Core missing {sym}")

if "testMovingSelectedFoldersToEdgePreservesRelativeOrder" not in tests:
    fail("Core test missing")

if "BATCH-SELECTED-FOLDERS-EDGE-01" not in direct:
    fail("Direct missing slice tag")
if "moveSelectedFoldersToEdge" not in direct:
    fail("Direct missing moveSelectedFoldersToEdge")
if "onBatchMoveSelectedFoldersToStart" not in direct:
    fail("Direct missing start callback")
if "batchMoveSelectedFoldersToStartMenuItem" not in direct:
    fail("Direct missing menu selector")

# Edge-no-op: callbacks omitted when Core would return nil (already at edge).
if "movingSelectedFoldersToEdge(" not in direct:
    fail("Direct must consult movingSelectedFoldersToEdge when wiring menu")
if direct.count("atStart: true, in: self.layoutState") < 1:
    fail("Direct must gate start callback on Core nil-check")
if direct.count("atStart: false, in: self.layoutState") < 1:
    fail("Direct must gate end callback on Core nil-check")

fn = "private func moveSelectedFoldersToEdge(anchorID: UUID, atStart: Bool)"
if fn not in direct:
    fail("action signature missing")
chunk = direct[direct.index(fn) : direct.index(fn) + 900]
for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
    if bad in chunk:
        fail(f"paging symbol {bad} in moveSelectedFoldersToEdge — refuse")

if '"所选文件夹移到最前"' not in xc:
    fail("xcstrings missing start title")
if '"已将 %d 个文件夹移到最后"' not in xc:
    fail("xcstrings missing end toast")

if "BATCH-SELECTED-FOLDERS-EDGE" not in docs:
    fail("MULTI_SELECT_DESIGN.md must mention batch selected folders edge")

print("PASS: batch selected folders edge")

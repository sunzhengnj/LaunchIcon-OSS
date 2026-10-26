#!/usr/bin/env python3
"""BATCH-SELECTED-APPS-EDGE-01: multi-select apps → front/back (no paging)."""
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
    "appIDsForBatchEdgeMove",
    "movingSelectedAppsToEdge",
    "selectedAppsMovedToStartMenuTitleKey",
    "selectedAppsMovedToEndToastFormatKey",
):
    if sym not in core:
        fail(f"Core missing {sym}")

if "testMovingSelectedAppsToEdgePreservesRelativeOrder" not in tests:
    fail("Core test missing")

if "BATCH-SELECTED-APPS-EDGE-01" not in direct:
    fail("Direct missing slice tag")
if "moveSelectedAppsToEdge" not in direct:
    fail("Direct missing moveSelectedAppsToEdge")
if "onBatchMoveSelectedAppsToStart" not in direct:
    fail("Direct missing start callback")
if "batchMoveSelectedAppsToStartMenuItem" not in direct:
    fail("Direct missing menu selector")

if "movingSelectedAppsToEdge(" not in direct:
    fail("Direct must consult movingSelectedAppsToEdge when wiring menu")
if direct.count("appIDs: edgeAppIDs, atStart: true") < 1:
    fail("Direct must gate start callback on Core nil-check")
if direct.count("appIDs: edgeAppIDs, atStart: false") < 1:
    fail("Direct must gate end callback on Core nil-check")

fn = "private func moveSelectedAppsToEdge(anchorID: UUID, atStart: Bool)"
if fn not in direct:
    fail("action signature missing")
chunk = direct[direct.index(fn) : direct.index(fn) + 900]
for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
    if bad in chunk:
        fail(f"paging symbol {bad} in moveSelectedAppsToEdge — refuse")

if '"所选应用移到最前"' not in xc:
    fail("xcstrings missing start title")
if '"已将 %d 个应用移到最后"' not in xc:
    fail("xcstrings missing end toast")

if "BATCH-SELECTED-APPS-EDGE" not in docs:
    fail("MULTI_SELECT_DESIGN.md must mention batch selected apps edge")

print("PASS: batch selected apps edge")

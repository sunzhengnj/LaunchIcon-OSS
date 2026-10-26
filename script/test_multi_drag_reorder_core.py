#!/usr/bin/env python3
"""Guard: MULTI-DRAG-REORDER-CORE-01 + WIRE-01 (same-page Direct; no paging)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
docs = (root / "Docs/MULTI_SELECT_DESIGN.md").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("func reorderingTopLevelSelection(" in core, "Core missing reorderingTopLevelSelection")
need("MULTI-DRAG-REORDER-CORE-01" in core, "Core must tag MULTI-DRAG-REORDER-CORE-01")
need("testReorderingTopLevelSelectionMovesBlockPreservingGridOrder" in tests,
     "Core tests missing reorderingTopLevelSelection coverage")
need("reorderingTopLevelSelection" in docs, "Design doc must name reorderingTopLevelSelection")
need("MULTI-DRAG-REORDER-WIRE-01" in docs or "WIRE-01" in docs,
     "Design doc must document MULTI-DRAG-REORDER-WIRE-01")

# Direct must call Core for same-page multi-drag reorder.
need("reorderingTopLevelSelection(" in direct,
     "Direct must call reorderingTopLevelSelection for multi-drag reorder")
need("shouldBatchReorderSelection(" in direct,
     "Direct must gate multi-drag via shouldBatchReorderSelection")
need("MULTI-DRAG-REORDER-WIRE-01" in core or "topLevelIDsForBatchReorder" in core,
     "Core must expose topLevelIDsForBatchReorder / WIRE-01")
need("testTopLevelIDsForBatchReorderSamePageOnly" in tests,
     "Core test for same-page batch reorder ids missing")

# The Core helper body must not mention paging APIs.
need("func topLevelIDsForBatchReorder(" in core, "Core missing topLevelIDsForBatchReorder")
need("func shouldBatchReorderSelection(" in core, "Core missing shouldBatchReorderSelection")
start = core.index("func reorderingTopLevelSelection(")
chunk = core[start:start + 1800]
need("showPage" not in chunk and "pageTransition" not in chunk and "movePage" not in chunk
     and "transitionToPage" not in chunk,
     "reorderingTopLevelSelection must not touch paging")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: multi-drag reorder Core guard")

#!/usr/bin/env python3
"""WHEEL-PAGE-WHILE-ITEM-DRAG-01: discrete movePage while icon drag airborne."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
failures = []
def need(c, m):
    if not c: failures.append(m)
need("enum WheelPageWhileItemDragging" in core, "Core helper")
need("WHEEL-PAGE-WHILE-ITEM-DRAG-01" in core, "marker")
need("testWheelPageWhileItemDraggingIsDiscreteAndAxisAgnostic" in tests, "XCT")
need("isItemDraggingForWheelPaging" in direct, "CV flag")
need("discretePageWhileItemDraggingHandler" in direct, "discrete handler")
need("WheelPageWhileItemDragging.pageTurnDirection" in direct, "uses Core")
need("movePage(by: direction)" in direct, "wires movePage")
# Must not drive finger-follow while item-dragging.
start = direct.find("if isItemDraggingForWheelPaging()")
need(start > 0, "branch present")
body = direct[start:start+500]
need("cancelPagingInput()" in body, "cancel gesture state")
need("discretePageWhileItemDraggingHandler" in body, "discrete call")
need("updateGesture" not in body and "beginGesture" not in body, "no finger-follow")
need("pageFlipLocksHorizontalAxis" in core, "axis lock intact")
if failures:
    for f in failures: print("FAIL:", f)
    sys.exit(1)
print("PASS: wheel page while item drag")

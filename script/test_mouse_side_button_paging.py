#!/usr/bin/env python3
"""MOUSE-SIDE-BUTTON-PAGING-01: Back/Forward buttons page; gesture red line intact."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
prefs = (root / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("enum MouseSideButtonPaging" in core, "Core MouseSideButtonPaging missing")
need("backButtonNumber = 3" in core and "forwardButtonNumber = 4" in core, "button numbers")
need("func pageTurnDirection(" in core, "Core decision helper")
need("testMouseSideButtonPagingMapsBackForwardButtons" in tests, "Core test missing")
need("handleMouseSideButtonPaging" in direct, "Direct handler missing")
need("otherMouseDown" in direct and "handleMouseSideButtonPaging(event)" in direct,
     "window must consume otherMouseDown via handler")
need("MouseSideButtonPaging.pageTurnDirection" in direct, "Direct must use Core decision")
need("movePage(by: direction)" in direct, "side button must reuse movePage")
need("pageFlipLocksHorizontalAxis" in core, "gesture axis lock must remain")
need("pageFlipDirection: LauncherPageFlipDirection = .horizontal" in prefs, "horizontal default intact")
start = direct.find("func handleMouseSideButtonPaging(_ event: NSEvent) -> Bool {")
need(start > 0, "handler signature")
body = direct[start:direct.find("\n    }\n", start)]
for banned in ("preciseScrollUsesHorizontalAxis", "beginGesture", "updateGesture",
               "dominantScrollDelta", "finishGesture"):
    need(banned not in body, f"side-button path must not touch gesture state ({banned})")
if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: mouse side-button paging")

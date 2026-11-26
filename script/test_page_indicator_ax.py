#!/usr/bin/env python3
"""Guard: page dots stay reachable in the accessibility tree."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
ui = (root / "Tests/UITests/LauncherDragUITests.swift").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


need("AX-PAGE-INDICATOR-DOTS-01" in direct, "page-indicator AX marker missing")
idx = direct.index("AX-PAGE-INDICATOR-DOTS-01")
chunk = direct[idx:idx + 800]
need("setAccessibilityElement(false)" in chunk, "the strip must not be a swallowing group")
need("setAccessibilityRole(.group)" not in chunk, "the strip must not declare itself a named group")
need("dot.setAccessibilityIdentifier(pageLabel)" in direct, "dots must keep identifiers")
need('String(format: L("第 %d 页"), page + 1)' in direct, "dot label format changed")

need("private func pageDot(page: Int, in app: XCUIApplication)" in ui, "pageDot helper missing")
need("private func goToPage(_ page: Int, in app: XCUIApplication" in ui, "goToPage helper missing")
need('app.buttons[String(format: "第 %d 页", page)]' in ui, "pageDot must use the cheap buttons subscript")
need('app.buttons["第 2 页"]' not in ui, "tests must not look up 第 2 页 by identifier only")
need('app.buttons["第 1 页"]' not in ui, "tests must not look up 第 1 页 by identifier only")
need("label == %@ OR identifier == %@" not in ui, "do not use a hanging label-or-identifier predicate")
need("goToPage(2, in: app)" in ui, "search-clear / navigation tests must use goToPage")
need('app.buttons["下一页"]' in ui, "goToPage must be able to fall back to 下一页")

if failures:
    print("FAIL: page indicator ax")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: page indicator ax")

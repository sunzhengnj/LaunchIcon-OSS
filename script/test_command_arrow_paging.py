#!/usr/bin/env python3
"""KEYBOARD-COMMAND-ARROW-PAGING-01: ⌘←/→ (+ ⌘↑/↓ when vertical)."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
prefs = (root / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
failures = []
def need(c, m):
    if not c: failures.append(m)
need("enum CommandArrowPaging" in core, "Core CommandArrowPaging")
need("KEYBOARD-COMMAND-ARROW-PAGING-01" in core or "CommandArrowPaging" in core, "marker")
need("testCommandArrowPagingLaunchpadParity" in tests, "XCT")
need("handleCommandArrowPaging" in direct, "Direct handler")
need("handleCommandArrowPaging(event)" in direct, "performKeyEquivalent wires handler")
need("func commandUpClosesOpenFolder(" in core, "Core missing command-up close")
need("func closeFolderFromCommandUp(" in direct, "Direct missing command-up close")
need("closeFolderFromCommandUp(keyCode:" in direct, "panel does not ask to close the folder")
need("testCommandUpClosesAnOpenFolder" in tests, "Core command-up test missing")
close = direct.split("func closeFolderFromCommandUp(")[1].split("func handleCommandArrowPaging(")[0]
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    need(banned not in close, f"command-up close must not page ({banned})")
need("closeFolder()" in close, "must reuse the existing folder close")
need("func commandDownOpensFocusedFolder(" in core, "Core missing command-down open")
need("func openFocusedFolderFromCommandDown(" in direct, "Direct missing command-down open")
need("openFocusedFolderFromCommandDown(keyCode:" in direct, "panel does not ask to open the folder")
need("testCommandDownOpensTheFocusedFolder" in tests, "Core command-down test missing")
open_folder = direct.split("func openFocusedFolderFromCommandDown(")[1].split("func handleCommandArrowPaging(")[0]
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    need(banned not in open_folder, f"command-down open must not page ({banned})")
need("openFolder(" in open_folder, "must reuse the existing folder open")
need("pageFlipDirection: LauncherPageFlipDirection = .horizontal" in prefs, "H default")
need("pageFlipLocksHorizontalAxis" in core, "gesture lock intact")
if failures:
    for f in failures: print("FAIL:", f)
    sys.exit(1)
print("PASS: command-arrow paging")

#!/usr/bin/env python3
"""Guard MULTI-SELECT-MENU-STALE-01: selection-dependent context-menu items are
rebuilt right before a tile menu is shown (cmd/shift-click only flips isSelected)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
d = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("private func applySelectionDependentContextMenu(" in d, "missing applySelectionDependentContextMenu")
need("var onWillPresentContextMenu: (() -> Void)?" in d, "tile missing onWillPresentContextMenu")
need("onWillPresentContextMenu = nil" in d, "tile reuse must clear onWillPresentContextMenu")
i = d.index("    override func rightMouseDown(with event: NSEvent) {\n        onWillPresentContextMenu?()")
need(i > 0, "rightMouseDown must refresh before reading menu")
need("override func accessibilityPerformShowMenu() -> Bool {\n        onWillPresentContextMenu?()" in d,
     "VoiceOver show-menu must refresh")
j = d.index("private func applySelectionDependentContextMenu(")
body = d[j:d.index("\n    }\n", j)]
need("showPage" not in body and "movePage" not in body and "reloadData" not in body,
     "menu refresh must not page or reload")
k = d.index("tile.onWillPresentContextMenu = {")
hook = d[k:k + 500]
need("applySelectionDependentContextMenu(" in hook and "tile.refreshContextMenu()" in hook,
     "hook must re-apply selection items and rebuild the menu")

if failures:
    print("FAIL")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS script/test_multi_select_menu_refresh.py")

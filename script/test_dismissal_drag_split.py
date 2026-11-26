#!/usr/bin/env python3
"""Dismissal lives in an extension; paging and item-drag stay with their types in the main file."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = root / "Sources/Direct"
main = (direct / "LauncherWindowController.swift").read_text()
dismissal = (direct / "LauncherWindowController+Dismissal.swift").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


need(not (direct / "LauncherWindowController+Drag.swift").exists(), "item-drag stay-in-file: +Drag.swift should not exist")
need("extension LauncherWindowController" in dismissal, "dismissal extension missing")
need("func show(animated" in dismissal and "func hide(animated" in dismissal, "show/hide must live in the dismissal extension")
need("func toggleVisibility" in dismissal, "toggleVisibility must live in the dismissal extension")
need("func setExternalAppDragActive" in dismissal, "external-drag dock hide must live in the dismissal extension")
need("func show(animated" not in main and "func hide(animated" not in main, "show/hide must leave the main file")
need("func beginItemDrag" in main and "func applyDrop" in main, "item drag/drop must stay with LauncherRootView in the main file")
need("offerExternalDragFileLinkIfNeeded" in main, "Dock file-link offer must stay in the main file")

for name in (
    "private func showPage(_ page: Int)",
    "private func transitionToPage(",
    "private func completePageTransition(",
    "private func updatePageDrag(",
    "private func finishPageDrag(",
):
    need(name in main, f"{name} must stay in LauncherWindowController.swift")
    need(name not in dismissal, f"{name} must not move")

if failures:
    print("FAIL: dismissal/drag split")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: dismissal/drag split")

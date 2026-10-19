#!/usr/bin/env python3
"""Guard: hide-app toast + focus handoff after context-menu hide."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("hideApplicationToastMessageFormatKey" in core, "Core missing hide toast format key")
need("hideApplicationToastHelpKey" in core, "Core missing hide toast help")
need("focusItemIDAfterHiding" in core, "Core missing focus handoff after hide")
need("hideApplicationToastMessageFormatKey" in direct, "Direct must show hide toast")
need("hideApplicationToastHelpKey" in direct, "Direct must attach restore help")
need("focusItemIDAfterHiding" in direct, "Direct must hand off keyboard after hide")
need("hideApplication(candidate, focusID: representedID, in: collectionView)" in direct,
     "hide menu action must pass focusID + collection")
# No paging edits in this slice
body = direct[direct.index("private func hideApplication("):]
body = body[: body.index("private func uninstallDecision")]
need("showPage" not in body and "pageTransition" not in body, "hideApplication must not touch paging")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: hide application toast + focus handoff")

#!/usr/bin/env python3
"""Guard: search folder-member hits show containing-folder chrome (no paging)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("containingFolderName(forAppID" in core, "Core missing containingFolderName")
need("searchHitTitle" in core, "Core missing searchHitTitle")
need("searchHitAccessibilityLabel" in core, "Core missing searchHitAccessibilityLabel")
need("testSearchFolderMemberHitShowsContainingFolderChrome" in tests, "Core test missing")
need("searchFolderContext" in direct, "Direct tile missing searchFolderContext")
need("searchCollectionView" in direct and "containingFolderName" in direct,
     "Direct must pass folder context only for search collection")
# HARD: no paging in the new helpers
for name in ("containingFolderName", "searchHitTitle", "searchHitAccessibilityLabel"):
    idx = core.index("func " + name) if ("func " + name) in core else core.index(name + "(")
    chunk = core[idx:idx+500]
    need("showPage" not in chunk and "pageTransition" not in chunk and "pageAnimation" not in chunk,
         f"{name} must not touch paging")
# configure path for search must not page
idx = direct.index("let searchFolder")
chunk = direct[idx:idx+900]
need("showPage" not in chunk and "pageTransition" not in chunk,
     "search folder chrome wiring must not touch paging")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: search folder-member chrome")

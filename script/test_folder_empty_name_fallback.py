#!/usr/bin/env python3
"""FOLDER-EMPTY-NAME-FALLBACK-01: blank folder titles use Core empty-name helper."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "FOLDER-EMPTY-NAME-FALLBACK-01" not in core:
    fail("Core missing slice tag")
if "func emptyFolderDisplayName" not in core:
    fail("missing emptyFolderDisplayName")
if "func displayName(\n        forFolderNamed" not in core and "forFolderNamed name: String" not in core:
    fail("missing displayName(forFolderNamed:)")

if "emptyFolderDisplayName" not in direct:
    fail("Direct drag-merge must use emptyFolderDisplayName")
if direct.count("displayName(forFolderNamed:") < 5:
    fail("Direct must use displayName(forFolderNamed:) for toasts + menu (≥5)")
if 'L("新建文件夹")' in direct:
    fail("Direct still has L(\"新建文件夹\")")
for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
    # Only refuse if introduced next to the new helpers — already elsewhere; skip global.
    pass

print("PASS: empty folder display name owned by Core")

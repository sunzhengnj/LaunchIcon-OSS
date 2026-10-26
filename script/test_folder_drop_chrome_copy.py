#!/usr/bin/env python3
"""FOLDER-DROP-CHROME-COPY-01: nest-reject / drop-target / folder-members chrome in Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for needle in (
    "FOLDER-DROP-CHROME-COPY-01",
    "enum FolderDropChromeCopy",
    "nestRejectToastKey",
    "dropOnFolderHelpKey",
    "dropToMergeHelpKey",
    "folderMembersLabelKey",
):
    if needle not in core:
        fail(f"Core missing {needle!r}")

if "testFolderDropChromeCopy" not in tests:
    fail("Core test missing")

for needle in (
    "FolderDropChromeCopy.nestRejectToast",
    "FolderDropChromeCopy.dropTargetHelp",
    "FolderDropChromeCopy.folderMembersLabel",
    "tileAccessibilityHelp(",
):
    if needle not in direct:
        fail(f"Direct missing {needle!r}")

for bad in (
    'L("不能将文件夹放入另一个文件夹")',
    'L("拖放到此文件夹")',
    'L("拖放到此以合并")',
    'L("文件夹中的应用")',
    'L("按下以打开文件夹")',
    'L("按下以打开应用")',
):
    if bad in direct:
        fail(f"Direct still hardcodes {bad}")

chunk = core[core.index("FOLDER-DROP-CHROME-COPY-01"): core.index("FOLDER-DROP-CHROME-COPY-01") + 800]
if "showPage(" in chunk or "pageTransition" in chunk:
    fail("FolderDropChromeCopy must not retune paging")

print("PASS: folder drop chrome copy wired")

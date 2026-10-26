#!/usr/bin/env python3
"""BATCH-DISSOLVE-FOLDERS-01: multi-select folder dissolve Core + Direct (no paging)."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
xc = (ROOT / "Resources/Localizable.xcstrings").read_text(encoding="utf-8")
docs = (ROOT / "Docs/MULTI_SELECT_DESIGN.md").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

for sym in (
    "folderIDsForBatchDissolve",
    "dissolvingFolders",
    "batchDissolveFoldersMenuTitleFormatKey",
    "batchDissolveFoldersConfirmTitleKey",
):
    if sym not in core:
        fail(f"Core missing {sym}")

if "testBatchDissolveFoldersRequiresAnchorInMultiFolderSelection" not in tests:
    fail("Core test missing")

if "BATCH-DISSOLVE-FOLDERS-01" not in direct:
    fail("Direct missing slice tag")
if "dissolveSelectedFolders" not in direct:
    fail("Direct missing dissolveSelectedFolders")
if "onBatchDissolveFolders" not in direct:
    fail("Direct missing onBatchDissolveFolders")
if "batchDissolveFoldersMenuItem" not in direct:
    fail("Direct missing menu selector")

# Cancel-first confirm (UNGROUP-ALL-CONFIRM-COPY-01: Core button helpers)
fn = "private func dissolveSelectedFolders(anchorID: UUID)"
if fn not in direct:
    fail("dissolveSelectedFolders signature missing")
chunk = direct[direct.index(fn) : direct.index(fn) + 1800]
if "dissolveConfirmCancelButtonTitle" not in chunk:
    fail("confirm must use Core cancel button helper")
if "dissolveConfirmDestructiveButtonTitle" not in chunk:
    fail("confirm must use Core dissolve button helper")
if chunk.find("dissolveConfirmCancelButtonTitle") > chunk.find("dissolveConfirmDestructiveButtonTitle"):
    fail("取消 helper must precede 解散 helper")
if "dissolveConfirmButtonTitleKey" not in core:
    fail("Core missing dissolveConfirmButtonTitleKey")
for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
    if bad in chunk:
        fail(f"paging symbol {bad} in dissolveSelectedFolders — refuse")

if '"解散 %d 个文件夹…"' not in xc:
    fail("xcstrings missing menu title")
if '"解散选中的文件夹？"' not in xc:
    fail("xcstrings missing confirm title")

if "BATCH-DISSOLVE-FOLDERS" not in docs and "Batch dissolve" not in docs:
    fail("MULTI_SELECT_DESIGN.md must mention batch dissolve folders")

print("PASS: batch dissolve folders")

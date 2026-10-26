#!/usr/bin/env python3
"""Guard: UNGROUP-ALL-CONFIRM-COPY-01 — ungroup-all confirm copy in Core."""
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

need("UNGROUP-ALL-CONFIRM-COPY-01" in core, "Core marker")
need("ungroupAllFoldersConfirmTitleKey" in core, "Core title key")
need("dissolveConfirmButtonTitleKey" in core, "Core dissolve button key")
need("func ungroupAllFoldersConfirmTitle(" in core, "Core title helper")
need("func dissolveConfirmCancelButtonTitle(" in core, "Core cancel helper")
need(
    "ungroupAllFoldersConfirmInfoFormatKey" in core
    and "batchDissolveFoldersConfirmInfoFormatKey" in core,
    "info format shared with batch dissolve",
)

start = direct.index("@objc private func ungroupAllFoldersFromMenu()")
end = direct.index("@objc private func moveFoldersToStartFromMenu()")
ua = direct[start:end]
need("UNGROUP-ALL-CONFIRM-COPY-01" in ua, "Direct marker")
need("ungroupAllFoldersConfirmTitle(" in ua, "Direct title")
need("ungroupAllFoldersConfirmInformativeText(" in ua, "Direct informative")
need("dissolveConfirmCancelButtonTitle(" in ua, "Direct cancel")
need("dissolveConfirmDestructiveButtonTitle(" in ua, "Direct dissolve")
need('L("解散所有文件夹？")' not in ua, "no title literal")
need('L("%d 个文件夹里的应用会放回' not in ua, "no info literal")
need('L("取消")' not in ua, "no cancel literal")
need('L("解散")' not in ua, "no dissolve literal")

# Batch dissolve also uses shared button helpers
fn = "private func dissolveSelectedFolders(anchorID: UUID)"
chunk = direct[direct.index(fn) : direct.index(fn) + 1800]
need("dissolveConfirmCancelButtonTitle(" in chunk, "batch dissolve cancel helper")
need("dissolveConfirmDestructiveButtonTitle(" in chunk, "batch dissolve destructive helper")

need("testUngroupAllFoldersConfirmCopy" in tests, "Core test")
need((root / "script/test_paging_input.py").exists(), "paging guard")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: ungroup-all confirm copy")

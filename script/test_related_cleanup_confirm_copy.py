#!/usr/bin/env python3
"""Guard: RELATED-CLEANUP-CONFIRM-COPY-01 — related checklist confirm copy in Core."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/AppRelatedFileScanner.swift").read_text()
direct = (root / "Sources/Direct/UninstallCoordinator.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("RELATED-CLEANUP-CONFIRM-COPY-01" in core, "Core marker")
need("relatedCleanupConfirmTitleFormatKey" in core, "Core title key")
need("func relatedCleanupConfirmTitle(" in core, "Core title helper")
need("func relatedCleanupReviewMessage(" in core, "Core review helper")

start = direct.index("static func confirmRelatedFileDeletion")
end = direct.index("static func uninstallDecision")
confirm = direct[start:end]
need("RELATED-CLEANUP-CONFIRM-COPY-01" in confirm, "Direct marker")
need("relatedCleanupConfirmTitle(" in confirm, "Direct title")
need("relatedCleanupReviewMessage(" in confirm, "Direct review")
need("confirmCancelButtonTitle(" in confirm, "Direct cancel button")
need("confirmDestructiveButtonTitle(" in confirm, "Direct trash button")
need('L("选择要清理的' not in confirm, "no title literal")
need('L("取消")' not in confirm, "no cancel literal")
need('L("移到废纸篓")' not in confirm, "no trash literal")
need("testRelatedCleanupConfirmCopy" in tests, "Core test")
need((root / "script/test_paging_input.py").exists(), "paging guard")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: related cleanup confirm copy")

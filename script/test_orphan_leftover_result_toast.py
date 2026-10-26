#!/usr/bin/env python3
"""Guard: ORPHAN-LEFTOVER-RESULT-TOAST-01 — orphan outcome toasts live in Core."""
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

need("ORPHAN-LEFTOVER-RESULT-TOAST-01" in core, "Core marker")
need("catalogUnavailableKey" in core and "changedBeforeTrashKey" in core, "Core abort keys")
need("successFormatKey" in core and "cancelledPartialFormatKey" in core, "Core success/cancel keys")
need("partialFailFormatKey" in core and "trashOutcomeMessage" in core, "Core partial helpers")

start = direct.index("static func cleanUpOrphanLeftovers")
end = direct.index("static func hasOtherInstalledCopy")
orphan = direct[start:end]
need("ORPHAN-LEFTOVER-RESULT-TOAST-01" in orphan, "Direct marker")
need("AppOrphanLeftoverScanner.catalogUnavailable(" in orphan, "Direct catalogUnavailable")
need("AppOrphanLeftoverScanner.changedBeforeTrash(" in orphan, "Direct changedBeforeTrash")
need("AppOrphanLeftoverScanner.cancelledPartialMessage(" in orphan, "Direct cancelledPartial")
need("AppOrphanLeftoverScanner.trashOutcomeMessage(" in orphan, "Direct trashOutcome")
need('L("无法确认应用安装状态' not in orphan, "no catalog literal")
need('L("应用或残留文件已变化' not in orphan, "no changed literal")
need('L("已取消；已移走' not in orphan, "no cancelled-partial literal")
need('L("已把 %d 项残留文件' not in orphan, "no success literal")
need('L("已移走 %d 项，%d 项失败' not in orphan, "no partial literal")
need("testOrphanLeftoverResultToasts" in tests, "Core test")
need((root / "script/test_paging_input.py").exists(), "paging input guard must remain")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: orphan leftover result toast")

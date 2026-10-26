#!/usr/bin/env python3
"""Guard: ORPHAN-LEFTOVER-CONFIRM-COPY-01 — orphan checklist confirm copy lives in Core."""
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

need("confirmTitleKey" in core and "confirmInformativeKey" in core, "Core confirm keys")
need("ORPHAN-LEFTOVER-CONFIRM-COPY-01" in core, "Core marker")
need("func confirmTitle(" in core and "func confirmInformativeText(" in core, "Core helpers")

start = direct.index("static func cleanUpOrphanLeftovers")
# End at next top-level static after orphans, or EOF-ish.
end = direct.index("static func hasOtherInstalledCopy")
orphan = direct[start:end]
need("ORPHAN-LEFTOVER-CONFIRM-COPY-01" in orphan, "Direct marker")
need("AppOrphanLeftoverScanner.confirmTitle(" in orphan, "Direct title helper")
need("AppOrphanLeftoverScanner.confirmInformativeText(" in orphan, "Direct informative helper")
need("AppBatchUninstallPlan.confirmCancelButtonTitle(" in orphan, "Direct cancel button helper")
need("AppBatchUninstallPlan.confirmDestructiveButtonTitle(" in orphan, "Direct trash button helper")
need('L("清理已卸载应用的残留文件")' not in orphan, "no title literal")
need('L("这些项目可能属于已卸载的应用' not in orphan, "no informative literal")
need('L("取消")' not in orphan, "no cancel literal in orphan path")
need('L("移到废纸篓")' not in orphan, "no trash literal in orphan path")
need("testOrphanLeftoverConfirmCopy" in tests, "Core test")
need((root / "script/test_paging_input.py").exists(), "paging input guard must remain")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: orphan leftover confirm copy")

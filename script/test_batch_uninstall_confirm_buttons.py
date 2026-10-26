#!/usr/bin/env python3
"""Guard: BATCH-UNINSTALL-CONFIRM-BUTTONS-01 — Core owns batch confirm button titles."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/AppUninstallEligibility.swift").read_text()
direct = (root / "Sources/Direct/UninstallCoordinator.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("cancelButtonTitleKey" in core and "trashButtonTitleKey" in core, "Core keys")
need("quitAndTrashButtonTitleKey" in core, "Core quit+trash key")
need("func confirmCancelButtonTitle" in core, "Core cancel helper")
need("func confirmDestructiveButtonTitle" in core, "Core destructive helper")
need("BATCH-UNINSTALL-CONFIRM-BUTTONS-01" in core, "Core marker")
need("confirmCancelButtonTitle(localize:" in direct, "Direct uses cancel helper")
need("confirmDestructiveButtonTitle(anyRunning:" in direct, "Direct uses destructive helper")
need("BATCH-UNINSTALL-CONFIRM-BUTTONS-01" in direct, "Direct marker")
# Scope to promptToBatchUninstall: no hardcoded cancel/trash literals in batch confirm
start = direct.index("static func promptToBatchUninstall")
body = direct[start:start + 2500]
need('L("取消")' not in body, "Direct must not hardcode Cancel in batch confirm")
need('L("移到废纸篓")' not in body, "Direct must not hardcode trash in batch confirm")
need('L("退出并移到废纸篓")' not in body, "Direct must not hardcode quit+trash in batch confirm")
need("testBatchUninstallConfirmButtonTitles" in tests, "Core test")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: batch uninstall confirm buttons")

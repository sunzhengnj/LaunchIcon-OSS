#!/usr/bin/env python3
"""Guard: BATCH-UNINSTALL-CONFIRM-COPY-01 — Core owns confirm informative text."""
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

need("func confirmInformativeText" in core, "Core helper")
need("userDataDisclaimerKey" in core and "quitBeforeTrashKey" in core, "Core keys")
need("BATCH-UNINSTALL-CONFIRM-COPY-01" in core, "Core marker")
need("confirmInformativeText(localize:" in direct, "Direct uses Core helper")
need("BATCH-UNINSTALL-CONFIRM-COPY-01" in direct, "Direct marker")
# Direct must not rebuild blocked names/reasons inline in promptToBatchUninstall
batch_start = direct.index("static func promptToBatchUninstall")
# to end of function roughly: next toast after trash loop or closing of static func
batch_chunk = direct[batch_start:batch_start + 2500]
need("blockedNameList" not in batch_chunk, "Direct must not assemble blockedNameList in prompt")
need("blockedReasonSummary" not in batch_chunk, "Direct must not assemble blockedReasonSummary in prompt")
need("testBatchUninstallConfirmInformativeTextIncludesReasons" in tests, "Core test")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: batch uninstall confirm copy")

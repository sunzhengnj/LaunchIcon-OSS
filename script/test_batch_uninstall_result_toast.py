#!/usr/bin/env python3
"""Guard: BATCH-UNINSTALL-RESULT-TOAST-01 — Core owns batch result toast."""
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

need("enum BatchResultToast" in core, "Core enum")
need("func resultToast(succeeded:" in core or "static func resultToast" in core, "Core factory")
need("BATCH-UNINSTALL-RESULT-TOAST-01" in core, "Core marker")
need("resultToast(" in direct and "succeeded:" in direct and "failed:" in direct, "Direct uses Core factory")
need("BATCH-UNINSTALL-RESULT-TOAST-01" in direct, "Direct marker")
# Direct prompt must not hardcode the three toast format strings anymore
start = direct.index("static func promptToBatchUninstall")
# find end-ish: last part of function
chunk = direct[start:]
# After result toast wiring, the Chinese literals for success/partial should not appear in batch path
# (allFailed key may still appear in single-app path elsewhere in file — scope to prompt function)
# Approximate end: closing brace before file end — use from start to 9000 chars covering toast section
body = direct[start:start + 9000]
need('L("已卸载 %d 个应用")' not in body, "Direct must not hardcode success toast in batch")
need('L("已卸载 %d 个应用，%d 个失败")' not in body, "Direct must not hardcode partial toast in batch")
need("testBatchUninstallResultToastVariants" in tests, "Core test")
need("unprocessed" in core, "resultToast aware of unprocessed (REMAINING-01)")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: batch uninstall result toast")

#!/usr/bin/env python3
"""Guard: BATCH-UNINSTALL-PROGRESS-TOAST-01 — Core owns in-loop progress toast."""
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

need("progressToastFormatKey" in core, "Core key")
need("func progressToastMessage" in core, "Core helper")
need("BATCH-UNINSTALL-PROGRESS-TOAST-01" in core, "Core marker")
need("progressToastMessage(" in direct and "index:" in direct, "Direct uses helper")
need('L("正在卸载 %d / %d…")' not in direct, "Direct must not hardcode progress format")
need("testBatchUninstallProgressToastMessage" in tests, "Core test")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: batch uninstall progress toast")

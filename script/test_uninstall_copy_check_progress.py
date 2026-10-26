#!/usr/bin/env python3
"""Guard: UNINSTALL-COPY-CHECK-PROGRESS-01 — Core owns copy-check progress toast."""
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

need("enum AppUninstallCopyCheckProgress" in core, "Core enum")
need("UNINSTALL-COPY-CHECK-PROGRESS-01" in core, "Core marker")
need("AppUninstallCopyCheckProgress.messageKey" in direct, "Direct uses key")
need("UNINSTALL-COPY-CHECK-PROGRESS-01" in direct, "Direct marker")
start = direct.index("static func promptToUninstall")
end = direct.index("static func cleanUpOrphanLeftovers")
prompt = direct[start:end]
need('L("正在检查应用副本…")' not in prompt, "Direct must not hardcode copy-check literal")
need("testUninstallCopyCheckProgressMessageKey" in tests, "Core test")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: uninstall copy-check progress")

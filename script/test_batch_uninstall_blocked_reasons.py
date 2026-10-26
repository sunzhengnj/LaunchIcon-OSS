#!/usr/bin/env python3
"""Guard: BATCH-UNINSTALL-BLOCKED-REASONS-01 — confirm shows reason × count."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/AppUninstallEligibility.swift").read_text()
direct = (root / "Sources/Direct/UninstallCoordinator.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
strings = (root / "Resources/Localizable.xcstrings").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


need("blockedReasonCountFormatKey" in core, "Core format key")
need("func blockedReasonSummary" in core, "Core helper")
need("BATCH-UNINSTALL-BLOCKED-REASONS-01" in core or "BATCH-UNINSTALL-BLOCKED-REASONS-01" in direct, "slice marker")
# CONFIRM-COPY-01 moved assembly into Core; Direct must call confirmInformativeText.
need(
    "blockedReasonSummary(localize:" in direct or "confirmInformativeText(localize:" in direct,
    "Direct wires summary (direct or via confirmInformativeText)",
)
need("testBatchUninstallBlockedReasonSummaryGroupsCounts" in tests, "Core test")
need('"%@ ×%d"' in strings, "xcstrings key")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: batch uninstall blocked reasons")

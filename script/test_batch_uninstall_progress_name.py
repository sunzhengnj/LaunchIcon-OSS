#!/usr/bin/env python3
"""Guard: BATCH-UNINSTALL-PROGRESS-NAME-01 — progress toast includes app name."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/AppUninstallEligibility.swift").read_text()
direct = (root / "Sources/Direct/UninstallCoordinator.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
xc = (root / "Resources/Localizable.xcstrings").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("progressToastWithNameFormatKey" in core, "Core named format key")
need("BATCH-UNINSTALL-PROGRESS-NAME-01" in core, "Core marker")
need("appName:" in core and "progressToastMessage" in core, "Core overload")
need("progressToastMessage(" in direct and "appName:" in direct, "Direct passes appName")
need("BATCH-UNINSTALL-PROGRESS-NAME-01" in direct, "Direct marker")
need("host.displayName(for: candidate)" in direct, "Direct uses displayName")
need("正在卸载 %d / %d：%@" in xc, "xcstrings zh key")
need("Uninstalling %d of %d: %@" in xc, "xcstrings en")
need("progressToastWithNameFormatKey" in tests, "Core test covers named form")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: batch uninstall progress name")

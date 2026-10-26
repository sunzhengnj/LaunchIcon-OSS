#!/usr/bin/env python3
"""Guard: UNINSTALL-SINGLE-CONFIRM-COPY-01 — single-app confirm copy lives in Core."""
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

need("enum AppUninstallSingleConfirmCopy" in core, "Core enum")
need("UNINSTALL-SINGLE-CONFIRM-COPY-01" in core, "Core marker")
need("titleFormatKey" in core and "idleBodyKey" in core and "runningBodyKey" in core, "Core keys")
need("otherCopyKnownKey" in core and "otherCopyUnknownKey" in core, "Core other-copy keys")
need("func informativeText(" in core, "Core informativeText")

start = direct.index("static func promptToUninstall")
end = direct.index("static func cleanUpOrphanLeftovers")
prompt = direct[start:end]
need("UNINSTALL-SINGLE-CONFIRM-COPY-01" in prompt, "Direct marker")
need("AppUninstallSingleConfirmCopy.title(" in prompt, "Direct title helper")
need("AppUninstallSingleConfirmCopy.informativeText(" in prompt, "Direct informative helper")
need('L("卸载' not in prompt, "Direct must not hardcode confirm title")
need('L("应用将被移到废纸篓' not in prompt, "Direct must not hardcode idle body")
need('L("该应用正在运行' not in prompt, "Direct must not hardcode running body")
need('L("发现同一应用的其他副本' not in prompt, "Direct must not hardcode other-copy known")
need('L("无法确认是否有其他副本' not in prompt, "Direct must not hardcode other-copy unknown")
need("testUninstallSingleConfirmCopyTitleAndBody" in tests, "Core test")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: uninstall single confirm copy")

#!/usr/bin/env python3
"""Guard: UNINSTALL-RELATED-RESULT-TOAST-01 — related success/partial toasts in Core."""
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

need("relatedSuccessFormatKey" in core, "Core related success key")
need("partialRelatedFormatKey" in core, "Core partial key")
need("successToastMessage" in core and "partialRelatedToast" in core, "Core helpers")
need("relatedLabelKey" in core, "Core failure labels")
need("UNINSTALL-RELATED-RESULT-TOAST-01" in core, "Core marker")

start = direct.index("static func promptToUninstall")
end = direct.index("static func cleanUpOrphanLeftovers")
prompt = direct[start:end]
need("UNINSTALL-RELATED-RESULT-TOAST-01" in prompt, "Direct marker")
need("successToastMessage(localize:" in prompt, "Direct success helper")
need("partialRelatedToast(localize:" in prompt, "Direct partial helper")
need('L("已移到废纸篓（含' not in prompt, "no related-success literal")
need('L("应用已移到废纸篓；' not in prompt, "no partial literal")
need('L("没有权限")' not in prompt, "no permission label literal in prompt")
need("relatedSuccessFormatKey" in tests, "Core test covers keys")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: uninstall related result toast")

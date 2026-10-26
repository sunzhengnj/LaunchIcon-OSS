#!/usr/bin/env python3
"""Guard: UNINSTALL-SINGLE-CONFIRM-CHROME-01 — single-app confirm uses Core chrome."""
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

need("enum AppUninstallTrashProgress" in core, "Core trash progress enum")
need('messageKey = "正在移到废纸篓…"' in core or "messageKey = \"正在移到废纸篓…\"" in core, "Core trash key")
need("UNINSTALL-SINGLE-CONFIRM-CHROME-01" in core, "Core marker")

start = direct.index("static func promptToUninstall")
end = direct.index("static func cleanUpOrphanLeftovers")
prompt = direct[start:end]
need("UNINSTALL-SINGLE-CONFIRM-CHROME-01" in prompt, "Direct marker")
need("confirmCancelButtonTitle(localize:" in prompt, "Direct cancel helper")
need("confirmDestructiveButtonTitle(" in prompt, "Direct destructive helper")
need("AppUninstallTrashProgress.messageKey" in prompt, "Direct trash progress key")
need('L("取消")' not in prompt, "Direct must not hardcode Cancel in single confirm")
need('L("移到废纸篓")' not in prompt, "Direct must not hardcode trash in single confirm")
need('L("退出并移到废纸篓")' not in prompt, "Direct must not hardcode quit+trash in single confirm")
need('L("正在移到废纸篓…")' not in prompt, "Direct must not hardcode trash progress literal")
need("testUninstallTrashProgressMessageKey" in tests, "Core test")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: uninstall single confirm chrome")

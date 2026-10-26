#!/usr/bin/env python3
"""Guard: UNINSTALL-OUTCOME-TOASTS-01 — single-app abort/failure toasts in Core."""
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

need("enum AppUninstallOutcomeToast" in core, "Core enum")
need("UNINSTALL-OUTCOME-TOASTS-01" in core, "Core marker")
need("appChangedKey" in core and "stillRunningKey" in core and "copiesChangedKey" in core, "Core keys")
need("permissionDeniedKey" in core and "bundleFailedMessage" in core, "Core failure helper")

start = direct.index("static func promptToUninstall")
end = direct.index("static func cleanUpOrphanLeftovers")
prompt = direct[start:end]
need("UNINSTALL-OUTCOME-TOASTS-01" in prompt, "Direct marker")
need("AppUninstallOutcomeToast.appChanged" in prompt, "Direct appChanged")
need("AppUninstallOutcomeToast.stillRunning" in prompt, "Direct stillRunning")
need("AppUninstallOutcomeToast.copiesChanged" in prompt, "Direct copiesChanged")
need("AppUninstallOutcomeToast.bundleFailedMessage" in prompt, "Direct bundleFailed helper")
need('L("应用已变化，请重新尝试卸载")' not in prompt, "no appChanged literal")
need('L("应用仍在运行，未移到废纸篓；请退出后重试")' not in prompt, "no stillRunning literal")
need('L("应用副本状态已变化，未移除应用或用户数据；请重新尝试")' not in prompt, "no copiesChanged literal")
need('L("没有权限移到废纸篓；应用和用户数据均未改动")' not in prompt, "no permission literal")
need('L("无法移到废纸篓；应用和用户数据均未改动")' not in prompt, "no trashFailed literal")
need("testUninstallOutcomeToastKeysAndBundleFailedMapping" in tests, "Core test")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: uninstall outcome toasts")

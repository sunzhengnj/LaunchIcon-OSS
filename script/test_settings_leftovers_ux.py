#!/usr/bin/env python3
"""Guard: settings leftovers cancel + progress + cancelled/empty copy."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/AppRelatedFileScanner.swift").read_text()
coord = (root / "Sources/Direct/UninstallCoordinator.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
failures = []

def need(c, m):
    if not c:
        failures.append(m)

need("cancelledMessageKey" in core, "Core cancelled message missing")
need("scanningProgressMessageKey" in core and "trashingProgressMessageKey" in core, "Core progress keys missing")
need("仅匹配已卸载应用" in core or "user-library" in core.lower() or "未发现可清理的残留文件（" in core,
     "noneFound copy should explain scope")
need("progress:" in coord and "cleanUpOrphanLeftovers" in coord, "coordinator must accept progress")
need("cancelledMessageKey" in coord, "coordinator must return cancelled copy")
need("trashingProgressMessageKey" in coord, "coordinator must report trash progress")
need("取消查找" in settings or "SettingsMaintenanceChromeCopy.leftoversCancelTitle" in settings, "settings must offer cancel while running")
need("running.cancel()" in settings, "settings must cancel leftoversTask on second click")
need("AppOrphanLeftoverScanner.cancelledMessageKey" in settings, "settings must show cancelled copy")
need("onCleanUpLeftovers" in settings and "progress" in (root / "Sources/Direct/DirectAppDelegate.swift").read_text(),
     "settings/delegate must pass progress")
# Paging untouched
need((root / "script/test_paging_input.py").exists(), "paging input guard must remain")
need((root / "script/test_page_host_geometry.py").exists(), "page geometry guard must remain")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: settings leftovers UX cancel/progress/empty-state")

#!/usr/bin/env python3
"""Guard: batch uninstall Direct wiring (menu + coordinator + no paging)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/AppUninstallEligibility.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
coord = (root / "Sources/Direct/UninstallCoordinator.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
docs = (root / "Docs/MULTI_SELECT_DESIGN.md").read_text()
xc = (root / "Resources/Localizable.xcstrings").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("struct AppBatchUninstallPlan" in core, "Core missing AppBatchUninstallPlan")
need("menuTitleFormatKey" in core and "confirmTitleFormatKey" in core, "Core missing batch menu/confirm keys")
need("testBatchUninstallPlanSkipsFoldersBlockedAndDuplicateApps" in tests, "Core tests missing batch plan")
need("promptToBatchUninstall" in coord, "Coordinator missing promptToBatchUninstall")
need("onBatchUninstallSelection" in direct, "Direct tile missing onBatchUninstallSelection")
need("uninstallSelectedApplications" in direct, "Direct missing uninstallSelectedApplications")
need("卸载 %d 个应用…" in direct or "AppBatchUninstallPlan.menuTitleFormatKey" in direct,
     "Direct menu must use batch title key")
need("AppBatchUninstallPlan.plan(" in direct, "Direct must build AppBatchUninstallPlan")
need('"卸载 %d 个应用…"' in xc, "xcstrings missing batch menu title")
need('"要将 %d 个应用移到废纸篓吗？"' in xc, "xcstrings missing batch confirm")
need('"已卸载 %d 个应用"' in xc, "xcstrings missing batch success toast")
need("BATCH-UNINSTALL" in docs or "AppBatchUninstallPlan" in docs, "Design doc must mention batch uninstall")
need("Direct wiring" in docs or "promptToBatchUninstall" in docs or "已接线" in docs
     or "wired" in docs.lower(), "Design doc should note Direct status")

# HARD: batch root method must not touch paging APIs
key = "private func uninstallSelectedApplications("
need(key in direct, "missing uninstallSelectedApplications signature")
start = direct.index(key)
chunk = direct[start:start + 1800]
need("showPage" not in chunk and "pageTransition" not in chunk and "movePage" not in chunk,
     "uninstallSelectedApplications must not touch paging")
need("!isPaging" in chunk or "guard" in chunk and "isPaging" in chunk,
     "uninstallSelectedApplications must refuse while paging")

# HARD: coordinator batch path must not call related-file confirm
batch_start = coord.index("static func promptToBatchUninstall")
batch_chunk = coord[batch_start:batch_start + 9000]  # REASONS-01 lengthened confirm body
need("confirmRelatedFileDeletion" not in batch_chunk,
     "batch uninstall must not open related-file sheets")
need("related: []" in batch_chunk or "related:[]" in batch_chunk.replace(" ", ""),
     "batch trash must pass empty related list")

if failures:
    print("FAIL")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS script/test_batch_uninstall_wire.py")

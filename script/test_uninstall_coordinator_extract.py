#!/usr/bin/env python3
"""Guard: uninstall helpers live in UninstallCoordinator / views, not LWC."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
lwc = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
coord = (root / "Sources/Direct/UninstallCoordinator.swift").read_text()
views = (root / "Sources/Direct/UninstallRelatedFilesViews.swift").read_text()
failures = []

def need(c, m):
    if not c:
        failures.append(m)

need("enum UninstallCoordinator" in coord, "UninstallCoordinator enum missing")
need("static func quitRunningApplications" in coord, "quit must be on coordinator")
need("static func forceQuitRunningApplications" in coord, "forceQuit must be on coordinator")
need("static func confirmRelatedFileDeletion" in coord, "confirmRelatedFileDeletion must be on coordinator")
need("static func runningApplications" in coord, "runningApplications must be on coordinator")
need("final class UninstallRelatedFilesListView" in views, "list view must live in views file")
need("final class UninstallRelatedFilesToggleView" in views, "toggle view must live in views file")
need("private func quitRunningApplications" not in lwc, "LWC must not keep quitRunningApplications")
need("private func confirmRelatedFileDeletion" not in lwc, "LWC must not keep confirmRelatedFileDeletion")
need("class UninstallRelatedFilesListView" not in lwc, "LWC must not keep list view class")
need("quitRunningApplications" in coord, "coordinator must keep quitRunningApplications")
need("confirmRelatedFileDeletion" in coord, "coordinator must keep confirmRelatedFileDeletion")

need("static func promptToUninstall" in coord, "promptToUninstall must live on coordinator")
need("static func cleanUpOrphanLeftovers" in coord, "cleanUpOrphanLeftovers must live on coordinator")
need("protocol UninstallHost" in coord, "UninstallHost protocol missing")
need("await UninstallCoordinator.promptToUninstall" in lwc, "LWC must forward promptToUninstall")
need("await UninstallCoordinator.cleanUpOrphanLeftovers" in lwc, "LWC must forward cleanUpOrphanLeftovers")
need("private func promptToUninstall(_ candidate: AppCandidate) async {" in lwc
      and "正在移到废纸篓" not in lwc.split("private func promptToUninstall(_ candidate: AppCandidate) async {",1)[1][:400],
      "LWC promptToUninstall must be a thin forwarder")
# Body of prompt should not remain in LWC
need("正在检查应用副本" not in lwc, "prompt body must leave LWC")
need("orphanCleanupAvailable" not in lwc, "orphan body must leave LWC")
need("正在检查应用副本" in coord and "orphanCleanupAvailable" in coord, "moved bodies must be in coordinator")

# Paging untouched
need((root / "script/test_paging_input.py").exists(), "paging input guard must remain")
need((root / "script/test_page_host_geometry.py").exists(), "page geometry guard must remain")
need("showPage" in lwc and "handlePagingScroll" in lwc, "paging methods must remain in LWC")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: uninstall coordinator extract guards")

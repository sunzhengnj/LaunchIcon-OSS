#!/usr/bin/env python3
"""Guard: uninstall Trash I/O must leave the main actor and recheck identity."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/AppUninstallEligibility.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
coord = (root / "Sources/Direct/UninstallCoordinator.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

def case_cancelled(text):
    return "case cancelled" in text

need("expectedIdentity" in core and "isCancelled" in core, "Core perform must accept expectedIdentity + isCancelled")
need("identityMismatch" in core and case_cancelled(core), "Core failure reasons must include identityMismatch/cancelled")
need("AppUninstallPathIdentity" in core and "capturePathIdentity" in core, "Core path identity helpers missing")
need("expectedIdentities" in core, "trashRelated must accept expectedIdentities")
need("Final identity gate" in core, "Core must document final identity gate")

# Flows live on UninstallCoordinator; LWC only forwards.
idx_prompt = coord.index("static func promptToUninstall")
idx_orphan = coord.index("static func cleanUpOrphanLeftovers")
need(idx_prompt < idx_orphan, "expected promptToUninstall before cleanUpOrphanLeftovers in coordinator")
prompt = coord[idx_prompt:idx_orphan]
orphan = coord[idx_orphan:idx_orphan + 12000]
need("await UninstallCoordinator.promptToUninstall" in direct, "LWC must forward prompt")
need("await UninstallCoordinator.cleanUpOrphanLeftovers" in direct, "LWC must forward orphan cleanup")

need("Task.detached" in prompt and "AppUninstallExecutor.perform(" in prompt, "promptToUninstall must Task.detached perform")
need("expectedIdentity:" in prompt and "candidate:" in prompt, "promptToUninstall must pass identity into perform")
need("正在移到废纸篓" in prompt, "promptToUninstall should show trash progress toast")
sync_hits = [line for line in prompt.splitlines() if "AppUninstallExecutor.perform(" in line]
need(len(sync_hits) == 1, f"expected one perform call in prompt, found {len(sync_hits)}")
need(prompt.index("Task.detached") < prompt.index("AppUninstallExecutor.perform("), "perform must follow Task.detached")

need("Task.detached" in orphan and "AppUninstallExecutor.trashRelated(" in orphan, "orphan cleanup must Task.detached trashRelated")
need("expectedIdentities:" in orphan and "capturePathIdentities" in orphan, "orphan cleanup must snapshot path identities")
need(orphan.index("Task.detached") < orphan.index("AppUninstallExecutor.trashRelated("),
     "trashRelated must follow Task.detached — got detached@%s trash@%s" % (
         orphan.index("Task.detached") if "Task.detached" in orphan else -1,
         orphan.index("AppUninstallExecutor.trashRelated(") if "AppUninstallExecutor.trashRelated(" in orphan else -1,
     ))


need("expectedRelatedIdentities" in core, "perform must accept expectedRelatedIdentities")
need("expectedRelatedIdentities:" in prompt, "promptToUninstall must pass related path identities into perform")
need("capturePathIdentities" in prompt, "promptToUninstall must snapshot related path identities before trash")
need("relatedCleanupSelectionStillValid" in prompt, "promptToUninstall must refuse when related selection changed")
need("recheckingProgressMessageKey" in prompt or "正在确认相关文件" in prompt,
     "promptToUninstall must show related recheck progress")
need("cancelledMessageKey" in prompt or "已取消相关文件清理" in prompt,
     "promptToUninstall must surface related cancel copy")
scanner = (root / "Sources/Core/AppRelatedFileScanner.swift").read_text()
need("relatedCleanupSelectionStillValid" in scanner, "Core related selection validity helper missing")
need("scanningProgressMessageKey" in scanner and "recheckingProgressMessageKey" in scanner,
     "Core related progress keys missing")

# Paging guards must remain untouched by this slice.
paging = (root / "script/test_paging_input.py").read_text()
geometry = (root / "script/test_page_host_geometry.py").read_text()
need("handlePagingScroll" in paging or "finishGesture" in paging, "paging input guard must remain")
need("page" in geometry.lower(), "page host geometry guard must remain")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: uninstall trash off main thread + identity recheck guards")

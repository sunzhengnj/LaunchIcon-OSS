#!/usr/bin/env python3
"""Guard: related cleanup defaults off + dialog a11y/keyboard policies."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/AppRelatedFileScanner.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
coord = (root / "Sources/Direct/UninstallCoordinator.swift").read_text()
views = (root / "Sources/Direct/UninstallRelatedFilesViews.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("relatedCleanupDefaultSelected = false" in core, "Core must default related cleanup selection off")
need("relatedCleanupReviewMessageKey" in core and "默认不选" in core, "Core review message must say 默认不选")
need(
    "AppRelatedFileScanner.relatedCleanupDefaultSelected" in coord
    or "AppRelatedFileScanner.relatedCleanupDefaultSelected" in views,
    "Direct must use Core defaultSelected policy",
)
need("relatedCleanupReviewMessageKey" in coord, "confirmRelatedFileDeletion must use Core review message")
idx = coord.index("static func confirmRelatedFileDeletion")
body = coord[idx : idx + 1600]
need("默认全选" not in body, "confirmRelatedFileDeletion must not say 默认全选")
need("relatedCleanupDefaultSelected" in body, "confirmRelatedFileDeletion must pass Core defaultSelected")
need(
    "defaultSelected: Bool = AppRelatedFileScanner.relatedCleanupDefaultSelected" in views,
    "UninstallRelatedFilesListView default must follow Core policy",
)
need(
    "defaultSelected: Bool = true" not in views and "defaultSelected: Bool = true" not in direct,
    "list view must not default to true",
)
need("confirmRelatedFileDeletion" in coord, "coordinator must keep confirmRelatedFileDeletion")

need("relatedCleanupAlertCancelIsFirstButton" in core, "Core must document Cancel-first alert policy")
need("relatedCleanupRestoresLauncherFocusAfterSheet" in core, "Core must restore launcher focus after sheet")
need("relatedCleanupListAccessibilityLabelKey" in core, "Core missing list AX label key")
need("relatedCleanupTrashAccessibilityHelp" in core, "Core missing trash AX help")
need("relatedFilesToggleAccessibilityHelp" in core, "Core missing toggle AX help")
need("relatedCleanupSelectAllAccessibilityLabelKey" in views, "list view must VoiceOver-label 全选")
need("relatedCleanupItemAccessibilityHelp" in views, "checklist checkboxes need AX help")
need("wireKeyViewLoop" in views, "checklist must wire Tab order")
need("applyToggleAccessibilityHelp" in views, "related toggle needs AX help when disabled")
need("restoreFocusAfterUninstallSheet" in coord, "coordinator must restore focus after sheets")
need("relatedCleanupRestoresLauncherFocusAfterSheet" in coord, "coordinator must gate focus restore")
need("noteUninstallSheetFocus" in direct, "Direct must note tile focus before uninstall sheet")
need("restoreFocusAfterUninstallSheet" in direct, "Direct must implement focus restore")

cancel = 'L("取消")'
trash = 'L("移到废纸篓")'
confirm = coord[coord.index("static func confirmRelatedFileDeletion") : coord.index("static func uninstallDecision")]
need(confirm.index(cancel) < confirm.index(trash), "confirmRelated: Cancel before Trash")
need(
    "precondition(AppRelatedFileScanner.relatedCleanupAlertCancelIsFirstButton)" in confirm,
    "confirmRelated must precondition Cancel-first",
)

prompt = coord[coord.index("static func promptToUninstall") : coord.index("static func cleanUpOrphanLeftovers")]
need(prompt.index(cancel) < prompt.index("trashTitle"), "promptToUninstall: Cancel before Trash")
need(
    "precondition(AppRelatedFileScanner.relatedCleanupAlertCancelIsFirstButton)" in prompt,
    "promptToUninstall must precondition Cancel-first",
)
need("restoreFocusAfterUninstallSheet" in prompt, "promptToUninstall defer must restore focus")

orphan = coord[coord.index("static func cleanUpOrphanLeftovers") :]
orphan = orphan[: orphan.index("static func hasOtherInstalledCopy")]
need(orphan.index(cancel) < orphan.index(trash), "orphan: Cancel before Trash")
need("restoreFocusAfterUninstallSheet" in orphan, "orphan defer must restore focus")

eligibility = (root / "Sources/Core/AppUninstallEligibility.swift").read_text()
need("enum AppUninstallForceQuitAlert" in eligibility, "Core missing AppUninstallForceQuitAlert")
need("cancelIsFirstButton = true" in eligibility, "force-quit must Cancel-first")
need("confirmAccessibilityHelpKey" in eligibility, "force-quit missing confirm AX help key")
need("cancelAccessibilityHelpKey" in eligibility, "force-quit missing cancel AX help key")
need("confirmForceQuitBeforeUninstall" in coord, "coordinator missing force-quit helper")
force_fn = coord[coord.index("static func confirmForceQuitBeforeUninstall"):]
force_fn = force_fn[: force_fn.index("static func uninstallDecision")]
need("precondition(AppUninstallForceQuitAlert.cancelIsFirstButton)" in force_fn,
     "force-quit helper must precondition Cancel-first")
need("setAccessibilityHelp" in force_fn and "confirmAccessibilityHelpKey" in force_fn,
     "force-quit confirm button needs AX help")
need("setAccessibilityHelp" in force_fn and "cancelAccessibilityHelpKey" in force_fn,
     "force-quit cancel button needs AX help")
need(force_fn.index("cancelButtonTitleKey") < force_fn.index("confirmButtonTitleKey"),
     "force-quit: Cancel button added before confirm")
need("confirmForceQuitBeforeUninstall()" in prompt, "promptToUninstall must use force-quit helper")
quit_block = prompt[prompt.index("if !quitOK") : prompt.index("forceQuitRunningApplications")]
need("confirmForceQuitBeforeUninstall()" in quit_block, "quit-fail path must call force-quit helper")
need("强制退出并卸载" not in quit_block, "prompt must not inline force-quit button title")

need("enum AppUninstallQuitProgress" in eligibility, "Core missing quit progress keys")
need("quittingMessageKey" in eligibility, "Core missing quittingMessageKey")
need("toastShouldAnnounce" in (root / "Sources/Core/LauncherLayout.swift").read_text(),
     "Core missing toastShouldAnnounce")
need("lastAnnouncedToastMessage" in direct, "Direct must dedupe toast VoiceOver announcements")
need("toastShouldAnnounce" in direct, "presentToast must gate announcements")
need("AppUninstallQuitProgress.quittingMessageKey" in coord, "polite quit must show progress toast")
need("clearMatchingProgressToast(host, quittingMessage)" in coord, "quit progress toast must clear after wait")
quit_wait = coord[coord.index("AppUninstallQuitProgress.quittingMessageKey"):]
quit_wait = quit_wait[: quit_wait.index("guard confirmForceQuitBeforeUninstall()")]
need("cancelledMessageKey" in quit_wait, "cancelled quit wait must announce cancel toast")

need((root / "script/test_uninstall_trash_off_main.py").exists(), "trash-off-main guard must remain")
need((root / "script/test_paging_input.py").exists(), "paging input guard must remain")
need((root / "script/test_page_host_geometry.py").exists(), "page geometry guard must remain")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: related cleanup defaults off + dialog a11y/keyboard")

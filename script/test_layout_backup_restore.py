#!/usr/bin/env python3
"""Guard: user-visible layout export/import/restore-last-backup — no paging."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
store = (root / "Sources/Core/LayoutStore.swift").read_text()
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
delegate = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("func loadBackup()" in store, "LayoutStore missing loadBackup")
need("func export(" in store, "LayoutStore missing export")
need("func importLayout(from" in store, "LayoutStore missing importLayout")
need("hasBackupFile" in store, "LayoutStore missing hasBackupFile")
need("nonisolated let backupURL" in store, "backupURL should stay nonisolated for Settings probe")
need("testLayoutStoreExportImportRoundTripDoesNotTouchLiveFiles" in tests, "Core export/import test missing")
need("XCTAssertEqual(backup, first)" in tests or "loadBackup()" in tests, "Core loadBackup assertion missing")

need(
    (
        "导出布局" in settings and "导入布局" in settings and "恢复上次备份" in settings
    )
    or (
        "SettingsLayoutIOChromeCopy.exportButtonTitleKey" in settings
        and "SettingsLayoutIOChromeCopy.importButtonTitleKey" in settings
        and "SettingsLayoutIOChromeCopy.restoreBackupButtonTitleKey" in settings
    ),
    "Settings missing export/import/restore controls",
)
need("onExportLayout" in settings and "onImportLayout" in settings and "onRestoreLayoutBackup" in settings,
     "Settings missing layout backup callbacks")
need("layoutBackupAvailable" in settings, "Settings missing backup availability probe")
# SETTINGS-SECTION-CHROME-01: section title owned by Core.
need(
    "SettingsSectionChromeCopy.maintenanceSectionTitle" in settings,
    "backup controls should live under 维护 (Core-owned)",
)
# layout backup row must be in 维护 section with actions
maint = settings.index("SettingsSectionChromeCopy.maintenanceSectionTitle")
block = settings[max(0, maint - 800):maint + 200]
need("layoutBackupRow" in block or "exportLayoutButton" in block,
     "export/import/restore should be in 维护 section build")
need("settings-export-layout" in settings and "settings-import-layout" in settings
     and "settings-restore-layout-backup" in settings, "a11y ids for layout backup")

need("func applyImportedLayout" in direct, "rootView missing applyImportedLayout")
need("func exportLayout(to" in direct, "WC missing exportLayout")
need("func importLayout(from" in direct, "WC missing importLayout")
need("func restoreLastLayoutBackup" in direct, "WC missing restoreLastLayoutBackup")
need("func layoutBackupAvailable" in direct, "WC missing layoutBackupAvailable")

# applyImportedLayout must clear multi-select, commit, not page
idx = direct.index("func applyImportedLayout")
chunk = direct[idx:idx + 700]
need("itemSelection.clear()" in chunk, "import/restore should clear multi-select")
need("commitLayout(reconciled)" in chunk or "commitLayout(" in chunk, "import/restore must commitLayout")
need("LauncherLayout.reconcile" in chunk, "import/restore must reconcile with catalog")
need("showPage" not in chunk and "pageTransition" not in chunk and "movePage" not in chunk,
     "applyImportedLayout must not touch paging")

need("onExportLayout" in delegate and "onImportLayout" in delegate
     and "onRestoreLayoutBackup" in delegate and "layoutBackupAvailable" in delegate,
     "AppDelegate must wire layout backup callbacks")

# rearrange + multi-select still present
need("rearrangeTopLevelGrid" in direct and "onRearrangeTopLevel" in settings,
     "must not regress rearrange")
need("itemSelection" in direct and "prunedItemSelection" in direct,
     "must not regress multi-select prune")

need("showPage" not in settings and "pageTransition" not in settings,
     "settings must not touch paging")


need("LayoutRestoreBackupConfirmAlert" in core, "Core missing restore-backup confirm")
need("LayoutImportConfirmAlert" in core, "Core missing import-layout confirm")
need("cancelIsFirstButton = true" in core[core.index("LayoutRestoreBackupConfirmAlert"):core.index("LayoutRestoreBackupConfirmAlert")+350],
     "restore confirm must be Cancel-first")
need("cancelIsFirstButton = true" in core[core.index("LayoutImportConfirmAlert"):core.index("LayoutImportConfirmAlert")+350],
     "import confirm must be Cancel-first")
need("confirmLayoutRestoreBackup" in settings, "Settings must confirm before restore backup")
need("confirmLayoutImport" in settings, "Settings must confirm before import")
need("testLayoutRestoreAndImportConfirmAlertsCancelIsFirstButton" in tests, "Core restore/import confirm test missing")

# Restore confirm before async restore; import confirm after open panel OK.
rst = settings[settings.index("func restoreLayoutBackup"):settings.index("func rearrangeByName")]
need("confirmLayoutRestoreBackup()" in rst, "restore must gate on confirm")
need("showPage" not in rst and "pageTransition" not in rst, "restore path must not page")
imp = settings[settings.index("func importLayout"):settings.index("func restoreLayoutBackup")]
need("confirmLayoutImport()" in imp, "import must gate on confirm after open panel")
# Helper bodies (not the call sites) must use Cancel-first / second-button apply.
for name in ("confirmLayoutRestoreBackup", "confirmLayoutImport", "confirmGridRearrange"):
    start = settings.index(f"func {name}")
    nxt = settings.find("\n    private func ", start + 10)
    if nxt < 0:
        nxt = settings.find("\n    @objc", start + 10)
    body = settings[start:nxt if nxt > start else start + 1400]
    need("alertSecondButtonReturn" in body, f"{name} must apply on second button")
    need("cancelIsFirstButton" in body, f"{name} must precondition Cancel-first")
    need("showPage" not in body and "pageTransition" not in body, f"{name} must not touch paging")

# Import variants (LAYOUT-IMPORT-CONFIRM-WIRE-01): unchanged files are a no-op,
# risky files need a second Cancel-first confirm before applyImportedLayout.
wc_imp = direct[direct.index("func importLayout(from"):direct.index("func restoreLastLayoutBackup")]
need(wc_imp.index("layoutImportConfirmation(for: imported)") < wc_imp.index("applyImportedLayout(imported)"),
     "import variant must be decided before applying")
need("confirmation == .unchanged" in wc_imp and "needsSecondConfirm" in wc_imp, "import variants must be handled")
risky = direct[direct.index("private func confirmRiskyLayoutImport"):]
risky = risky[:risky.index("\n    }\n")]
need("cancelIsFirstButton" in risky and "alertSecondButtonReturn" in risky, "risky import confirm must be Cancel-first")
need("testLayoutImportConfirmationAgainstLiveCatalog" in tests, "import variant Core test missing")
# Success line lists what changed (first 3 clauses), judged before applying.
need(wc_imp.index("layoutImportChangeSummary(for: imported)") < wc_imp.index("applyImportedLayout(imported)"),
     "change summary must be taken from the pre-import grid")
need("Self.importedLayoutMessage(changeSummary)" in wc_imp, "import success must report the change summary")
need("testLayoutChangeSummaryDetailsOrderAndTruncation" in tests, "change-summary details Core test missing")
# Risky confirm previews the same summary (LAYOUT-IMPORT-CONFIRM-PREVIEW-01).
need(wc_imp.index("layoutImportChangeSummary(for: imported)") < wc_imp.index("confirmRiskyLayoutImport(confirmation, preview: changeSummary)"),
     "risky confirm must preview the change summary")
need("LayoutChangeSummary.importPreviewFormatKey" in risky, "risky confirm must show the preview line")
wc_restore = direct[direct.index("func restoreLastLayoutBackup"):]
wc_restore = wc_restore[:wc_restore.index("\n    }\n")]
need(wc_restore.index("layoutImportChangeSummary(for: backup)") < wc_restore.index("applyImportedLayout(backup)"),
     "restore summary must be taken before applying")
need("LayoutChangeSummary.restoredWithDetailsFormatKey" in wc_restore, "restore success must report the change summary")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: layout backup/restore export-import")

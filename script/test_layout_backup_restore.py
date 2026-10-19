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

need("导出布局" in settings and "导入布局" in settings and "恢复上次备份" in settings,
     "Settings missing export/import/restore controls")
need("onExportLayout" in settings and "onImportLayout" in settings and "onRestoreLayoutBackup" in settings,
     "Settings missing layout backup callbacks")
need("layoutBackupAvailable" in settings, "Settings missing backup availability probe")
need('title: L("维护")' in settings, "backup controls should live under 维护")
# layout backup row must be in 维护 section with actions
maint = settings.index('title: L("维护")')
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

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: layout backup/restore export-import")

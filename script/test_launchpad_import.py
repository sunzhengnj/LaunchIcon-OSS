#!/usr/bin/env python3
"""Guard: native Launchpad layout import is read-only and lives in a built Core file."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
store = (root / "Sources/Core/LayoutStore.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
pbx = (root / "LaunchIcon.xcodeproj/project.pbxproj").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("import SQLite3" in store, "Core must import SQLite3 (autolinks libsqlite3)")
need("LayoutStore.swift in Sources" in pbx, "LayoutStore.swift must be in the Core build phase")
importer = store.split("// MARK: - Native Launchpad layout import", 1)
need(len(importer) == 2, "importer section missing")
body = importer[1] if len(importer) == 2 else ""
need("enum LaunchpadLayoutImporter" in body and "struct LaunchpadLayoutSnapshot" in body, "types missing")
need("SQLITE_OPEN_READONLY" in body, "database must be opened read-only")
need("SQLITE_OPEN_READWRITE" not in body and "SQLITE_OPEN_CREATE" not in body, "must never open for writing")
for word in ("INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "CREATE"):
    need(not re.search(rf'"[^"]*\b{word}\b', body), f"importer SQL must not {word}")
need("com.apple.dock.launchpad/db/db" in body, "default database path missing")
need("testLaunchpadImportReadsSyntheticDatabaseInOrder" in tests, "SQLite test missing")
need("testLaunchpadImportMapsOntoInstalledAppsAndKeepsTheRest" in tests, "mapping test missing")

# Direct wiring (LAUNCHPAD-IMPORT-01)
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
delegate = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
need('"settings-import-launchpad"' in settings, "Settings button a11y id missing")
need("onImportLaunchpadLayout" in settings and "onImportLaunchpadLayout" in delegate, "callback not wired")
c = settings.split("private func confirmLaunchpadImport", 1)
need(len(c) == 2 and "cancelIsFirstButton" in c[1][:900]
     and c[1].index("cancelButtonTitleKey") < c[1].index('L("导入")'), "Launchpad confirm must be cancel-first")
w = direct.split("func importLaunchpadLayout(from", 1)
wb = w[1][:1200] if len(w) == 2 else ""
need("Task.detached" in wb, "database read must run off the main thread")
need("confirmThenApplyImportedLayout" in wb, "must share the JSON import confirm/backup path")
j = direct.split("func importLayout(from", 1)
need(len(j) == 2 and "confirmThenApplyImportedLayout" in j[1][:2500], "JSON import must use the shared path")
need("showPage" not in wb and "pageTransition" not in wb, "Launchpad import must not touch paging")

if failures:
    print("FAIL: launchpad import")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: launchpad import (read-only SQLite + Settings wiring)")

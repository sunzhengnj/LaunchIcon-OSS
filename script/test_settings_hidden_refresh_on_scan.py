#!/usr/bin/env python3
"""SETTINGS-HIDDEN-REFRESH-ON-SCAN-01: catalog reload refreshes Settings hidden list."""
import pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
delegate = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
checks = [
    ("refresh is callable", "func refreshHiddenApplicationsFromLauncher()" in settings
     and "private func refreshHiddenApplicationsFromLauncher()" not in settings),
    ("provider used", "hiddenApplicationsProvider" in settings),
    ("becomeKey still refreshes", "settingsWindowDidBecomeKey" in settings
     and "refreshHiddenApplicationsFromLauncher()" in settings),
    ("catalog finish refreshes", "onCatalogReloadFinished" in delegate
     and "refreshHiddenApplicationsFromLauncher()" in delegate[
         delegate.index("onCatalogReloadFinished"):
         delegate.index("onCatalogReloadFinished") + 500]),
]
bad = [n for n, ok in checks if not ok]
if bad:
    print("FAIL:", ", ".join(bad)); sys.exit(1)
print("PASS: settings hidden refresh on scan")

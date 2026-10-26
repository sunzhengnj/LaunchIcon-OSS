#!/usr/bin/env python3
"""Guard: CUSTOM-ROOT-COUNT-LIMIT-01 — max user app folders."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
scanner = (root / "Sources/Core/AppCatalogScanner.swift").read_text()
prefs = (root / "Sources/Core/LauncherPreferences.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
fail = []
def need(c, m):
    if not c: fail.append(m)
need("maxAdditionalAppDirectories" in scanner, "scanner missing max count")
need("maxAdditionalAppDirectories" in scanner[scanner.index("for raw in additionalPaths"):scanner.index("for raw in additionalPaths")+400],
     "catalogRoots must enforce max count")
need("limitReachedKey" in prefs, "copy missing")
need("limitReached" in settings, "Settings must surface limit")
need("maxAdditionalAppDirectories" in settings and "isEnabled = false" in settings,
     "Settings Add item must disable at cap")
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
need("sanitizedAdditionalAppDirectories" in direct, "Direct setAdditional must sanitize")
need("testCatalogRootsCapsAdditionalDirectoryCount" in tests, "Core test missing")
need("sanitizedAdditionalAppDirectories" in scanner, "prefs sanitizer missing")
if fail:
    print("FAIL:"); [print(x) for x in fail]; sys.exit(1)
print("PASS: custom-root count limit")

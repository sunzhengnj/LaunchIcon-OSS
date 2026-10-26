#!/usr/bin/env python3
"""Guard: Settings warns when macOS already uses the chosen hot corner (read-only)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
prefs = (root / "Sources/Core/LauncherPreferences.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

for key in ("wvous-tl-corner", "wvous-tr-corner", "wvous-bl-corner", "wvous-br-corner"):
    need(f'"{key}"' in prefs, f"Core missing Dock key {key}")
need("func systemConflictActionTitleKey(dockValue:" in prefs, "Core conflict helper missing")
need("systemConflictMessageFormatKey" in prefs, "message key missing")
need("testHotCornerDetectsSystemDockCornerConflict" in tests, "Core test missing")
need("systemHotCornerConflictMessage(for:" in settings, "Settings must compute conflict message")
need('UserDefaults(suiteName: "com.apple.dock")' in settings, "Settings must read Dock prefs")
need("cornerChanged" in settings, "warning only when the corner changes")
# read-only: never write Dock prefs
need(".set(" not in settings.split("systemHotCornerConflictMessage(for corner")[1].split("\n    }\n")[0],
     "conflict check must not write Dock prefs")

if failures:
    print("FAIL: hot corner conflict")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: hot corner conflict warning (read-only Dock prefs)")

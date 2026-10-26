#!/usr/bin/env python3
"""Guard: SELECTION-A11Y-ANNOUNCE-01 (VO selection count; no paging; marquee deferred)."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
strings = (root / "Resources/Localizable.xcstrings").read_text()
failures = []
def need(c, m):
    if not c: failures.append(m)
need("selectionAnnouncementKind" in core, "Core missing selectionAnnouncementKind")
need("selectionClearedAnnouncementKey" in core, "Core missing cleared key")
need("SELECTION-A11Y-ANNOUNCE-01" in direct, "Direct must tag slice")
need("announceSelectionChangeIfNeeded" in direct, "Direct missing announce helper")
need("refreshItemSelectionChrome(announce: false)" in direct, "marquee must suppress per-frame announce")
need("announcementRequested" in direct and "selectedCountLabelFormatKey" in direct, "must post VO announcement")
need("testSelectionAnnouncementKindChangesAndClears" in tests, "Core test missing")
need('"已清除选择"' in strings and '"Selection Cleared"' in strings, "xcstrings missing")
chunk = direct.split("SELECTION-A11Y-ANNOUNCE-01")[1][:1500] if "SELECTION-A11Y-ANNOUNCE-01" in direct else ""
need("pageAnimationDuration" not in chunk, "must not touch paging")
if failures:
    print("FAIL:")
    for f in failures: print(" -", f)
    sys.exit(1)
print("PASS: selection a11y announce")

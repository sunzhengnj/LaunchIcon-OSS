#!/usr/bin/env python3
"""Guard: grid row/column preference is Core math only. Paging stays on 7×5."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
prefs = (root / "Sources/Core/LauncherPreferences.swift").read_text()
layout = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
design = (root / "Docs/GRID_GEOMETRY_CONFIG.md").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


def body(text, start, end):
    i = text.index(start)
    return text[i : text.index(end, i + len(start))]


pref = body(prefs, "public struct GridGeometryPreference", "public struct LauncherPreferences")
need("columnBounds = 5...10" in pref and "rowBounds = 3...8" in pref, "bounds missing")
need("defaultColumns = 7" in pref and "defaultRows = 5" in pref, "default must stay 7×5")
need("func preservedPageIndex(" in pref, "slot-preserving page map missing")
need("self.init(columns: columns, rows: rows)" in pref, "decode must clamp through init")
for banned in ("showPage", "transitionToPage", "completePageTransition", "pageDrag"):
    need(banned not in pref, f"preference type must not name paging ({banned})")

need("public static let pageColumns = 7" in layout, "live columns changed")
need("public static let pageRows = 5" in layout, "live rows changed")
need("public static let pageCapacity = pageColumns * pageRows" in layout, "live capacity changed")
need("GridGeometryPreference" not in layout, "layout must keep using its own constants")
need("GridGeometryPreference" not in direct, "Direct must not read the preference yet")
need("GridGeometryPreference" not in settings, "Settings must not offer the control yet")
need('prefix + "gridColumns"' in prefs and 'prefix + "gridRows"' in prefs, "preference keys missing")
need("func storedGridGeometry(" in prefs, "missing-key policy missing")
need("guard let columns, let rows else { return .standard }" in prefs, "one key must stay 7×5")
for name in ("gridColumns", "gridRows", "gridGeometry"):
    need(name not in direct, f"Direct must not apply {name}")
    need(name not in settings, f"Settings must not offer {name}")
need("private func showPage(" in direct, "showPage missing")
need("testGridGeometryPreferenceClampsAndMatchesSevenByFive" in tests, "Core test missing")
need("testGridGeometryPreferencePersistsOnlyAsAClampedPair" in tests, "persist test missing")
need("showPage" in design and "pageCapacity" in design, "design must name the paging red line")
need("preservedPageIndex" in design, "design must say how a later apply keeps the slot")

if failures:
    print("FAIL: grid geometry config")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: grid geometry config")

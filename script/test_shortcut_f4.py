#!/usr/bin/env python3
"""Guard: SHORTCUT-F4-01 — optional F4 hotkey; default stays Option-Space."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
prefs = (root / "Sources/Core/LauncherPreferences.swift").read_text()
platform = (root / "Sources/Core/PlatformServices.swift").read_text()
direct = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


def body(text, start, end):
    i = text.index(start)
    return text[i : text.index(end, i + len(start))]


enum = body(prefs, "enum LauncherShortcut", "enum LauncherHotCorner")
need("case f4" in enum, "f4 case missing")
need(enum.index("case controlShiftSpace") < enum.index("case f4"), "f4 must stay last")
need('"F4"' in enum, "title must be F4")
need("shortcut: LauncherShortcut = .optionSpace" in prefs, "default must stay optionSpace")
need("?? .optionSpace" in prefs, "unknown raw value must still fall back")

chord = body(platform, "static func carbonChord(", "public final class CarbonGlobalHotKeyService")
need(chord.count("kVK_Space") == 3, "space chords must stay on kVK_Space")
need("kVK_F4" in chord and "modifiers: 0" in chord, "f4 must be bare kVK_F4")
need("showPage" not in chord, "chord helper must not name paging")

register = body(platform, "public func register(", "public func unregister()")
need("chord.keyCode" in register and "chord.modifiers" in register, "register must use carbonChord")
need("kVK_Space" not in register, "register must not hardcode space")
need("showPage" not in register, "register must not name paging")

equivalent = body(direct, "func menuKeyEquivalent(", "func menuModifiers(")
need("NSF4FunctionKey" in equivalent and '" "' in equivalent, "menu equivalent missing")
need("showPage" not in equivalent, "menu equivalent must not name paging")
modifiers = body(direct, "func menuModifiers(", "func configureHotCornerMonitor")
need("case .f4: []" in modifiers, "f4 menu mask must be empty")

status = body(direct, "func configureStatusItem()", "func statusItemButtonActivated")
need("menuKeyEquivalent(for: preferences.shortcut)" in status, "status item must not hardcode space")
apply = body(direct, "func applyPreferences(", "func showSettings(")
need("keyEquivalent = menuKeyEquivalent(for: proposed.shortcut)" in apply, "apply must set the character")
need("keyEquivalentModifierMask = menuModifiers(for: proposed.shortcut)" in apply, "apply must still set the mask")

need("testShortcutF4IsOptionalBareFunctionKey" in tests, "Core test missing")

if failures:
    print("FAIL: shortcut f4")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: shortcut f4")

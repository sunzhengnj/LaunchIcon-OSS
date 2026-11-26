#!/usr/bin/env python3
"""HOTKEY-STATUS-SUPPRESS / MARQUEE+DRAG cancel on settings / SEARCH-HL clear on folder."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = "".join(p.read_text(encoding="utf-8") for p in [ROOT / "Sources/Direct/LauncherWindowController.swift", *sorted((ROOT / "Sources/Direct").glob("LauncherWindowController+*.swift"))])
delegate = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for token in (
    "HOTKEY-STATUS-SUPPRESS-WHEN-SETTINGS-OR-MODAL-01",
    "shouldAcceptHotkeyPresenceToggle",
    "MARQUEE-CANCEL-ON-SETTINGS-OPEN-01",
    "shouldCancelMarqueeWhenOpeningSettings",
    "DRAG-CANCEL-ON-SETTINGS-OPEN-01",
    "shouldCancelItemDragWhenOpeningSettings",
    "SEARCH-KEYBOARD-HIGHLIGHT-CLEAR-ON-OPEN-FOLDER-01",
    "shouldClearSearchKeyboardHighlightWhenOpeningFolder",
):
    if token not in core:
        fail(f"Core missing {token}")

for token in (
    "testHotkeyPresenceToggleSharesSettingsOrModalGate",
    "testSettingsOpenCancelsMarqueeAndItemDrag",
    "testOpenFolderClearsSearchKeyboardHighlight",
):
    if token not in tests:
        fail(f"Core test missing {token}")

# Hotkey / status toggle
tog = direct[direct.find("func toggleVisibility"):direct.find("func toggleVisibility") + 900]
if "shouldAcceptHotkeyPresenceToggle" not in tog:
    fail("toggleVisibility must consult shouldAcceptHotkeyPresenceToggle")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in tog:
        fail(f"paging red line {bad} in toggleVisibility")
if "toggleVisibility(settingsIsKey:" not in delegate:
    fail("AppDelegate must pass settingsIsKey into toggleVisibility")

# Settings open chrome
prep_i = direct.find("func prepareChromeForOpeningSettings")
prep = direct[prep_i:direct.find("\n    @objc private func openSettings()", prep_i)]
if "settingsOpenChromeActions" not in prep or "case .cancelMarquee:" not in prep:
    fail("settings open must cancel marquee")
if "cancelMarquee(keepSelection: true)" not in prep:
    fail("settings open must call cancelMarquee")
if "case .cancelItemDrag:" not in prep or "cancelInProgressItemDragIfNeeded()" not in prep:
    fail("settings open must cancel item drag")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in prep:
        fail(f"paging red line {bad} in prepareChromeForOpeningSettings")

# openFolder highlight clear
of = direct[direct.find("private func openFolder(_ id: UUID)"):direct.find("private func openFolder(_ id: UUID)") + 1800]
if "shouldClearSearchKeyboardHighlightWhenOpeningFolder" not in of:
    fail("openFolder must clear search keyboard highlight")
if "searchKeyboardHighlightID = nil" not in of:
    fail("openFolder must nil searchKeyboardHighlightID")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in of:
        fail(f"paging red line {bad} in openFolder")

print("PASS: hotkey suppress + settings marquee/drag cancel + folder clears search highlight")

#!/usr/bin/env python3
"""HOT-CORNER-SUPPRESS / SELECT-ALL-EMPTY / SEARCH-HIGHLIGHT-SCROLL / PRESENCE-UNINSTALL."""
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
    "HOT-CORNER-SUPPRESS-WHEN-SETTINGS-OR-MODAL-01",
    "shouldAcceptHotCornerPresenceToggle",
    "SELECT-ALL-EMPTY-NO-CONSUME-01",
    "shouldConsumeSelectAllShortcut",
    "SEARCH-KEYBOARD-HIGHLIGHT-SCROLL-ON-SYNC-01",
    "shouldScrollSearchKeyboardHighlightOnSync",
    "PRESENCE-GESTURE-SUPPRESS-UNINSTALL-PROMPT-01",
    "shouldTreatAsPresenceGestureEditing",
    "isPromptingForUninstall: Bool = false",
):
    if token not in core:
        fail(f"Core missing {token}")

for token in (
    "testHotCornerSuppressesWhenSettingsOrModal",
    "testSelectAllShortcutConsumesOnlyWhenItemsPresent",
    "testShouldScrollSearchKeyboardHighlightOnSync",
    "testPresenceGestureTreatsUninstallPromptAsEditing",
):
    if token not in tests:
        fail(f"Core test missing {token}")

# Hot corner Direct + AppDelegate
hot = direct[direct.find("func respondToHotCornerTrigger"):direct.find("func respondToHotCornerTrigger") + 900]
if "shouldAcceptHotCornerPresenceToggle" not in hot:
    fail("respondToHotCornerTrigger must consult shouldAcceptHotCornerPresenceToggle")
if "isPromptingForUninstall" not in hot or "settingsIsKey" not in hot:
    fail("hot corner must read uninstall + settingsIsKey")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in hot:
        fail(f"paging red line {bad} in hot corner")
if "settingsIsKey" not in delegate or "respondToHotCornerTrigger(settingsIsKey:" not in delegate:
    fail("AppDelegate must pass settingsIsKey into hot corner")

# Select-all empty
sel = direct[direct.find("func selectAllItemsOnCurrentPage"):direct.find("func selectAllItemsOnCurrentPage") + 900]
if "shouldConsumeSelectAllShortcut" not in sel:
    fail("selectAll must consult shouldConsumeSelectAllShortcut")
if "return false" not in sel:
    fail("selectAll empty must return false")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in sel:
        fail(f"paging red line {bad} in selectAll")

# Search highlight scroll on sync
sync = direct[direct.find("private func syncSearchKeyboardHighlight"):direct.find("private func syncSearchKeyboardHighlight") + 900]
if "shouldScrollSearchKeyboardHighlightOnSync" not in sync:
    fail("syncSearchKeyboardHighlight must consult scroll-on-sync")
if "scrollSearchKeyboardHighlightIntoViewIfNeeded" not in sync:
    fail("sync must scroll highlight into view")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in sync:
        fail(f"paging red line {bad} in syncSearchKeyboardHighlight")

# Pinch + marquee uninstall
pinch = direct[direct.find("func handlePinchMagnify"):direct.find("func handlePinchMagnify") + 1200]
if "shouldTreatAsPresenceGestureEditing" not in pinch:
    fail("pinch must use shouldTreatAsPresenceGestureEditing")
if "isPromptingForUninstall" not in pinch:
    fail("pinch must pass isPromptingForUninstall")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in pinch:
        fail(f"paging red line {bad} in pinch")

arm = direct[direct.find("LauncherMarquee.canArm("):direct.find("LauncherMarquee.canArm(") + 800]
if "isPromptingForUninstall" not in arm:
    fail("marquee canArm must pass isPromptingForUninstall")

print("PASS: hotcorner suppress + select-all empty + search scroll sync + presence uninstall")

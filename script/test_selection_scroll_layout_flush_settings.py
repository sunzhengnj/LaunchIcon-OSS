#!/usr/bin/env python3
"""SHIFT/CMD/MARQUEE selection scroll-into-view + LAYOUT-FLUSH on settings open."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for token in (
    "SHIFT-SELECT-SCROLL-INTO-VIEW-01",
    "shouldScrollSelectionIntoViewAfterShiftSelect",
    "CMD-TOGGLE-SCROLL-INTO-VIEW-01",
    "shouldScrollSelectionIntoViewAfterCommandToggle",
    "MARQUEE-END-SCROLL-INTO-VIEW-01",
    "shouldScrollSelectionIntoViewAfterMarquee",
    "LAYOUT-FLUSH-ON-SETTINGS-OPEN-01",
    "shouldFlushLayoutWhenOpeningSettings",
):
    if token not in core:
        fail(f"Core missing {token}")

if "testSelectionScrollAndLayoutFlushOnSettingsGates" not in tests:
    fail("Core test missing")

if "CMD-TOGGLE-SCROLL-INTO-VIEW-01" not in direct:
    fail("Direct missing cmd-toggle scroll")
if "SHIFT-SELECT-SCROLL-INTO-VIEW-01" not in direct:
    fail("Direct missing shift-select scroll")
if "MARQUEE-END-SCROLL-INTO-VIEW-01" not in direct:
    fail("Direct missing marquee-end scroll")
if "LAYOUT-FLUSH-ON-SETTINGS-OPEN-01" not in direct:
    fail("Direct missing layout flush on settings")

# Marquee end must not page
mq = direct[direct.find("func endMarquee"):direct.find("func endMarquee") + 1600]
if "shouldScrollSelectionIntoViewAfterMarquee" not in mq:
    fail("endMarquee must consult marquee scroll gate")
if "scrollSelectedItemIntoViewIfNeeded" not in mq:
    fail("endMarquee must scroll selection")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in mq:
        fail(f"paging red line {bad} in endMarquee")

# WC settings flush
wc = direct.find("func clearSelectionBeforeOpeningSettings()")
chunk = direct[wc:wc + 1600]
if "shouldFlushLayoutWhenOpeningSettings" not in chunk:
    fail("WC clearSelectionBeforeOpeningSettings must flush layout")
if "flushPendingLayoutSave" not in chunk:
    fail("WC must call flushPendingLayoutSave")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in chunk:
        fail(f"paging red line {bad} in WC clearSelection")

# Selection handlers region
if direct.count("scrollSelectedItemIntoViewIfNeeded(id: representedID)") < 2:
    fail("shift and cmd paths must both scroll representedID")

print("PASS: selection scroll + layout flush on settings")

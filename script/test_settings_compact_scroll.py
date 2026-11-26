#!/usr/bin/env python3
"""SETTINGS-COMPACT-SCROLL-02: Settings scrolls; window stays inside visibleFrame."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for needle in (
    "SETTINGS-COMPACT-SCROLL-02",
    "SettingsWindowChrome",
    "NSScrollView",
    "SettingsDocumentView",
    "fitSettingsWindowToVisibleScreen",
    "refreshSettingsDocumentSize",
    "defaultContentHeight",
    "minimumContentHeight",
    "autohidesScrollers = false",
    "scrollerStyle = .legacy",
    "visibleFrame.insetBy",
    "contentRect(forFrameRect:",
    ".resizable",
    "contentMinSize",
    "contentMaxSize",
):
    if needle not in settings:
        fail(f"missing {needle!r}")

hm = re.search(r"defaultContentHeight:\s*CGFloat\s*=\s*(\d+)", settings)
if not hm or int(hm.group(1)) > 760 or int(hm.group(1)) < 520:
    fail(f"default height should be 520-760, got {hm.group(1) if hm else None}")

mm = re.search(r"minimumContentHeight:\s*CGFloat\s*=\s*(\d+)", settings)
if not mm or int(mm.group(1)) > 520 or int(mm.group(1)) < 400:
    fail(f"minimum height should be 400-520, got {mm.group(1) if mm else None}")

# Keep density popups + AX ids
for needle in (
    "rearrangePopup",
    "layoutIOPopup",
    "settings-rearrange",
    "settings-layout-io",
    "settings-pinch-dismiss",
    "settings-reopen-page",
    "rowHeight",
):
    if needle not in settings:
        fail(f"must keep {needle!r}")

if "showPage(" in settings or "pageTransition" in settings or "pageAnimation" in settings:
    fail("settings must not touch paging")

# Must not pin document height to the clip view.
if re.search(r"document\.heightAnchor\.constraint\(equalTo:\s*scrollView\.contentView\.heightAnchor", settings):
    fail("document height must not equal clip height")

print("PASS: settings compact scroll")

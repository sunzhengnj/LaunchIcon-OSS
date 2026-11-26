#!/usr/bin/env python3
"""SETTINGS-TAB-CHROME-01: Settings uses NSTabView panes; AX ids preserved."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
layout = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for needle in (
    "SETTINGS-TAB-CHROME-01",
    "NSTabView",
    "tabViewType = .topTabsBezelBorder",
    "makeTabScrollPane",
    "SettingsSectionChromeCopy.appearanceSectionTitle",
    "SettingsSectionChromeCopy.behaviorSectionTitle",
    "SettingsSectionChromeCopy.appsSectionTitle",
    "SettingsSectionChromeCopy.maintenanceSectionTitle",
    "SETTINGS-COMPACT-SCROLL-02",
    "SettingsWindowChrome",
    "NSScrollView",
    "SettingsDocumentView",
    "refreshSettingsDocumentSize",
):
    if needle not in settings:
        fail(f"missing {needle!r}")

# Section chrome keys stay in Core
for needle in (
    'appearanceSectionKey = "外观与呼出"',
    'behaviorSectionKey = "行为"',
    'appsSectionKey = "应用管理"',
    'maintenanceSectionKey = "维护"',
    'pageTitleKey = "通用"',
):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")

for ax in (
    "settings-hot-corner",
    "settings-display-target",
    "settings-background-dim",
    "settings-background-blur",
    "settings-status-item",
    "settings-hide-app-names",
    "settings-hide-folder-names",
    "settings-grid-columns",
    "settings-grid-rows",
    "settings-hide-after-launch",
    "settings-reduces-motion",
    "settings-pinch-dismiss",
    "settings-reopen-page",
    "settings-login-item",
    "settings-open-login-settings",
    "settings-restore-hidden",
    "settings-restore-all-hidden",
    "settings-rearrange",
    "settings-cleanup-leftovers",
    "settings-app-directories",
    "settings-layout-io",
    "settings-export-layout",
    "settings-import-layout",
    "settings-restore-layout-backup",
    "settings-import-launchpad",
):
    if ax not in settings and ax not in prefs:
        fail(f"AX id missing {ax!r}")

for needle in (
    'columnsPopupIdentifier = "settings-grid-columns"',
    'rowsPopupIdentifier = "settings-grid-rows"',
):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")
if "GridGeometryCopy.columnsPopupIdentifier" not in settings or "GridGeometryCopy.rowsPopupIdentifier" not in settings:
    fail("Settings grid popups must use GridGeometryCopy identifiers")
if "gridColumnLabel.setAccessibilityElement(false)" not in settings or "gridRowLabel.setAccessibilityElement(false)" not in settings:
    fail("visible 列/行 captions must be hidden from AX (popups already have labels)")

hm = re.search(r"defaultContentHeight:\s*CGFloat\s*=\s*(\d+)", settings)
wm = re.search(r"contentWidth:\s*CGFloat\s*=\s*(\d+)", settings)
if not hm or not (520 <= int(hm.group(1)) <= 760):
    fail(f"defaultContentHeight out of range: {hm.group(1) if hm else None}")
if not wm or int(wm.group(1)) < 520:
    fail(f"contentWidth too narrow: {wm.group(1) if wm else None}")

if "showPage(" in settings or "pageTransition" in settings or "pageAnimation" in settings:
    fail("settings must not touch paging")


for needle in (
    "SETTINGS-TAB-SCROLL-03",
    "SETTINGS-TAB-SCROLL-04",
    "layoutSelectedSettingsTab",
    "autoresizingMask = [.width, .height]",
    "NSTabViewDelegate",
    "private var settingsScrollPanes:",
    "for pane in settingsScrollPanes",
    "settingsScrollPanes.append((",
    "tabView.delegate = self",
    "func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?)",
    "settingsWindowDidResize",
    "NSWindow.didResizeNotification",
):
    if needle not in settings:
        fail(f"missing {needle!r}")

for needle in (
    "SETTINGS-TAB-LAYOUT-ON-SHOW-01",
    "func relayoutSettingsChrome()",
    "settingsTabView",
    "SettingsScrollDocument.selectedPaneFrameIsUsable",
    "SettingsScrollDocument.documentHeight",
    "laidOutContentHeight: content.bounds.height",
    "enum SettingsScrollDocument",
):
    if needle == "enum SettingsScrollDocument":
        if needle not in prefs:
            fail(f"Core missing {needle!r}")
        continue
    if needle not in settings:
        fail(f"missing {needle!r}")


def body_between(src: str, start: str, end: str) -> str:
    start_at = src.find(start)
    if start_at < 0:
        fail(f"missing start {start!r}")
    end_at = src.find(end, start_at + len(start))
    if end_at < 0:
        fail(f"missing end {end!r} after {start!r}")
    return src[start_at:end_at]


resize_body = body_between(
    settings,
    "func settingsWindowDidResize",
    "private func relayoutSettingsChrome()",
)
show_body = body_between(
    settings,
    "func show(preferences:",
    "func presentShortcutRegistrationError",
)
screen_body = body_between(
    settings,
    "func settingsScreenParametersDidChange",
    "func settingsWindowDidResize",
)
select_body = body_between(
    settings,
    "func tabView(_ tabView: NSTabView, didSelect",
    "private func buildContent",
)
for label, chunk in (
    ("resize", resize_body),
    ("show", show_body),
    ("screen", screen_body),
    ("didSelect", select_body),
):
    if "relayoutSettingsChrome()" not in chunk:
        fail(f"{label} must lay out the selected tab via relayoutSettingsChrome()")

layout_body = body_between(
    settings,
    "private func layoutSelectedSettingsTab",
    "func tabView(_ tabView: NSTabView, didSelect",
)
if "selectedPaneFrameIsUsable(targetFrame)" not in layout_body:
    fail("selected pane must refuse a 1pt placeholder frame")
if "targetFrame.height > 0" in layout_body:
    fail("height > 0 still accepts the 1pt placeholder")

# SETTINGS-SCREEN-NIL-HOLD-01: a parameter change with no window.screen must
# not fit against NSScreen.main. The first appearance still may.
if "SETTINGS-SCREEN-NIL-HOLD-01" not in settings:
    fail("missing SETTINGS-SCREEN-NIL-HOLD-01")
if "func shouldHoldSettingsScreenFitForMissingScreen" not in layout:
    fail("Core missing shouldHoldSettingsScreenFitForMissingScreen")
hold_at = screen_body.find("shouldHoldSettingsScreenFitForMissingScreen")
fit_at = screen_body.find("fitSettingsWindowToVisibleScreen")
if hold_at < 0 or fit_at < 0 or hold_at > fit_at:
    fail("nil screen must be held before any settings fit")
if "NSScreen.main" in screen_body:
    fail("parameter change must not fall back to the main screen")
if "armSettingsMissingScreenFollowUpIfNeeded()" not in screen_body:
    fail("nil screen must look once more")
if "settingsMissingScreenFollowUpIsRunning" not in screen_body:
    fail("the settings follow-up must not arm another look")
close_body = body_between(
    settings,
    "func handleSettingsWindowWillClose()",
    "func settingsWindowDidBecomeKey",
)
if "cancelSettingsMissingScreenFollowUp()" not in close_body:
    fail("closing settings must cancel a pending screen fit")
# SETTINGS-SCREEN-FIT-OFFSCREEN-01: a closed window has no screen. The old
# `window.screen ?? NSScreen.main` pulled it onto the main display on every open.
if "window.screen ?? NSScreen.main" in settings:
    fail("a closed settings window must not treat a nil screen as the main screen")
if "settingsFitScreenChoice(" not in settings:
    fail("settings fit must ask Core which screen owns the frame")
if "preferFrameIntersection: !initial" not in settings:
    fail("reopen keeps the screen under the frame; first appearance may use the main screen")

print("PASS: settings tab chrome")

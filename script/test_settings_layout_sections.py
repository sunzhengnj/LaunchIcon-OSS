#!/usr/bin/env python3
"""Guard: settings window sectioned card layout (no paging)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

for title in ("外观与呼出", "行为", "应用管理", "维护"):
    need(title in settings, f"missing section title {title}")

need("SettingsChrome" in settings, "missing SettingsChrome metrics")
need("rowHeight" in settings, "missing consistent rowHeight")
need("makeCard" in settings and "SettingsCardView" in settings, "missing card grouping")
need("makeFormRow" in settings, "missing form row (label leading / control trailing)")
need("makeInsetSeparator" in settings, "missing subtle row separators")
need("makeSectionHeader" in settings, "missing section header helper")
need("let hiddenRow" in settings, "hidden apps row must remain")
need("hiddenApplicationsPopup" in settings and "restoreHiddenApplicationButton" in settings,
     "hidden apps picker + restore must remain")
idx = settings.index("let hiddenRow")
block = settings[idx:idx+400]
need("隐藏的应用" in block or "makeFormRow" in block, "hidden row should use form layout")
need("let actions = NSStackView()" in settings, "maintenance actions stack")
need("rearrangePopup" in settings and "layoutIOPopup" in settings,
     "SETTINGS-FORM-DENSITY-01: rearrange + layout I/O must be popups")
need("settings-rearrange" in settings and "settings-layout-io" in settings,
     "SETTINGS-FORM-DENSITY-01: popup AX ids")
aidx = settings.index("let actions = NSStackView()")
ablock = settings[aidx:aidx+500]
need("rescanButton" in ablock and "leftoversButton" in ablock,
     "rescan + leftovers must share maintenance action row")
for need_s in ("SettingsWindow", "cancelOperation", "initialFirstResponder",
               "settingsMessageShouldAnnounce", "makeFirstResponder(rescanButton)",
               "settings-cleanup-leftovers"):
    need(need_s in settings, f"a11y/behavior missing: {need_s}")
need("showPage" not in settings and "pageTransition" not in settings and "pageAnimation" not in settings,
     "settings must not touch paging")

# SETTINGS-REARRANGE-AX-IDS-01: stable AX ids for Settings rearrange / restore buttons
for ax_id in (
    "settings-rearrange-by-name",
    "settings-rearrange-by-kind",
    "settings-rearrange-by-category",
    "settings-rearrange-by-color",
    "settings-rearrange-by-date-added",
    "settings-rearrange-by-last-opened",
    "settings-restore-hidden",
    "settings-restore-all-hidden",
    "settings-restore-layout-backup",
):
    need(ax_id in settings, f"missing AX id {ax_id}")

# 全部恢复 (A2): one Core change, hidden unless ≥2 hidden apps, no paging.
need("restoreAllHiddenApplicationsButton" in settings
     and "settingsShowsRestoreAllHidden(" in settings, "restore-all button must follow the ≥2 rule")
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
ra = direct[direct.index("func restoreAllHiddenApplications() -> Int? {\n        guard"):]
ra = ra[:ra.index("\n    }\n")]
need("LauncherLayout.restoringAllHiddenApplications(" in ra and ra.count("commitLayout(") == 1,
     "restore-all must be a single commit through Core")
for banned in ("showPage", "currentPage", "scrollToPage"):
    need(banned not in ra, f"restore-all must not page ({banned})")

# Hidden list stays live while Settings is open (A2).
need("name: NSWindow.didBecomeKeyNotification" in settings, "settings must refresh hidden list on becoming key")
need(settings.count("refreshHiddenApplicationsFromLauncher()") >= 4, "refresh on key + after import + after backup restore")
need("latest != hiddenApplications" in settings, "unchanged list must keep popup selection")
appdel = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
need("controller.hiddenApplicationsProvider = {" in appdel, "app delegate must wire the hidden-list provider")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: settings sectioned layout")

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

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: settings sectioned layout")

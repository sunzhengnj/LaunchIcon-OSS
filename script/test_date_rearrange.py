#!/usr/bin/env python3
"""Static guard for SETTINGS-DATE-SORT-01 (Settings 按添加时间/按上次打开时间排列)."""
import pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
w = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
delegate = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()

checks = [
    ("core enum", "enum AppDateRearrangeKind" in core),
    ("core sort", "static func rearrangeTopLevelEntriesByDate(" in core),
    ("settings button key", "settingsButtonTitleKey" in core
     and "AppDateRearrangeKind.dateAdded.settingsButtonTitleKey" in settings
     and "AppDateRearrangeKind.lastOpened.settingsButtonTitleKey" in settings),
    ("settings ax ids", "settings-rearrange-by-date-added" in settings
     and "settings-rearrange-by-last-opened" in settings),
    ("settings callback", "var onRearrangeByDate: ((AppDateRearrangeKind) async -> Bool)?" in settings),
    ("root date API", "func rearrangeTopLevelGridByDate(_ kind: AppDateRearrangeKind) -> Bool" in w),
    ("offmain dates", "LauncherLayout.applicationDates(" in w and "isSamplingAppDates" in w),
    ("hide drops date sort", "shouldApplyDeferredGridRearrange" in w
     and "invalidateDeferredGridRearrange" in w),
    ("wc forwarder", "rootView.rearrangeTopLevelGridByDate(kind)" in w
     and "rearrangeTopLevelGridByDateAwaitingCompletion(kind)" in w),
    ("delegate wire", "onRearrangeByDate" in delegate
     and "rearrangeTopLevelGridByDateAwaitingCompletion(kind)" in delegate),
]

# Settings Cancel-first applyDateRearrange
s = settings.find("private func applyDateRearrange")
assert s >= 0, "missing applyDateRearrange"
body = settings[s:settings.find("\n    private func applyRearrange(", s)]
checks += [
    ("settings cancel-first", "cancelIsFirstButton" in body and "alertSecondButtonReturn" in body),
    ("settings kind informative", "kind.informativeTextKey" in body),
    ("settings toast", "kind.toastKey" in body),
    ("settings no paging", all(k not in body for k in ("currentPage", "scrollToPage", "setPage", "animatePage"))),
]

# Apply step — no paging. Dates themselves are read off the main actor.
s = w.find("private func applyTopLevelDateRearrange(")
assert s >= 0, "missing applyTopLevelDateRearrange"
body = w[s:w.find("\n    }\n", s) + 6]
checks += [
    ("date commit", "commitLayout(next)" in body),
    ("date selection cleared", "itemSelection.clear()" in body),
    ("date injected", "dates[$0.deduplicationKey]" in body),
    ("date no paging", all(k not in body for k in ("currentPage", "scrollToPage", "setPage", "animatePage"))),
    ("editing guard", "isLayoutEditingEnabled" in body),
]

# Blank-area still wired
checks += [
    ("blank menu date", "for kind in AppDateRearrangeKind.allCases" in w),
]

bad = [n for n, ok in checks if not ok]
if bad:
    print("FAIL:", ", ".join(bad)); sys.exit(1)
print("PASS: date rearrange")

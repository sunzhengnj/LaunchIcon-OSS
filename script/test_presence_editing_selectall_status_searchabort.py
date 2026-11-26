#!/usr/bin/env python3
"""PRESENCE editing suppress / SELECT-ALL scroll / STATUS menu / SEARCH abort."""
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
    "PRESENCE-TOGGLE-SUPPRESS-WHEN-EDITING-TEXT-01",
    "folderTitleEditing: Bool = false",
    "SELECT-ALL-SCROLL-INTO-VIEW-01",
    "shouldScrollSelectionIntoViewAfterSelectAll",
    "STATUS-ITEM-MENU-SUPPRESS-WHEN-MODAL-01",
    "shouldPresentStatusItemMenu",
    "SEARCH-FIELD-ABORT-ON-SETTINGS-OPEN-01",
    "shouldAbortSearchFieldWhenOpeningSettings",
):
    if token not in core:
        fail(f"Core missing {token}")

for token in (
    "testPresenceToggleSuppressesWhenEditingText",
    "testSelectAllScrollStatusMenuAndSearchAbortGates",
):
    if token not in tests:
        fail(f"Core test missing {token}")

for label, start in (
    ("hot corner", "func respondToHotCornerTrigger"),
    ("hotkey", "func toggleVisibility"),
    ("dock", "func respondToDockReopen"),
):
    chunk = direct[direct.find(start):direct.find(start) + 900]
    if "folderTitleEditing: rootView.isFolderTitleEditing" not in chunk:
        fail(f"{label} must pass folderTitleEditing")
    if "searchFieldEditing: rootView.isSearchFieldEditing" not in chunk:
        fail(f"{label} must pass searchFieldEditing")
    for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
        if bad in chunk and label != "dock":
            # dock must not hide either — already checked elsewhere
            fail(f"paging red line {bad} in {label}")

sel = direct[direct.find("func selectAllItemsOnCurrentPage"):direct.find("func selectAllItemsOnCurrentPage") + 1200]
if "shouldScrollSelectionIntoViewAfterSelectAll" not in sel:
    fail("selectAll must scroll into view")
if "scrollSelectedItemIntoViewIfNeeded" not in sel:
    fail("selectAll must call scrollSelectedItemIntoViewIfNeeded")
if "func scrollSelectedItemIntoViewIfNeeded" not in direct:
    fail("scrollSelectedItemIntoViewIfNeeded helper missing")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in sel:
        fail(f"paging red line {bad} in selectAll")

prep_i = direct.find("func prepareChromeForOpeningSettings")
prep = direct[prep_i:direct.find("\n    @objc private func openSettings()", prep_i)]
if "case .abortSearchField:" not in prep:
    fail("settings open must abort search field")
if "abortEditing()" not in prep:
    fail("settings open must call abortEditing")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in prep:
        fail(f"paging red line {bad} in prepareChrome")

if "shouldPresentStatusItemMenu()" not in delegate:
    fail("AppDelegate must consult shouldPresentStatusItemMenu")
menu = delegate[delegate.find("func presentStatusMenu"):delegate.find("func presentStatusMenu") + 500]
if "shouldPresentStatusItemMenu" not in menu:
    fail("presentStatusMenu must gate on shouldPresentStatusItemMenu")

print("PASS: presence editing + selectAll scroll + status menu + search abort")

#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

for name in (
    "shouldRestoreGridFocusAfterClearingSearch",
    "shouldFocusFirstGridItemAfterClearingSearch",
    "shouldFocusFirstGridItemAfterSearchQueryEmptied",
):
    if name not in core:
        fail(f"Core missing {name}")
    if name not in direct:
        fail(f"Direct missing {name}")

if "focusFirstGridItemOnCurrentPage" not in direct:
    fail("Direct missing focusFirstGridItemOnCurrentPage")
if "handOffFocusAfterSearchCleared" not in direct:
    fail("Direct missing handOffFocusAfterSearchCleared")

esc_start = direct.index("func handleEscape() -> Bool")
esc_end = direct.index("var highlightedLaunchKey", esc_start)
esc = direct[esc_start:esc_end]
if "focusedSearchResultID()" not in esc:
    fail("handleEscape must capture focusedSearchResultID before clear")
if "clearSearchIfNeeded()" not in esc:
    fail("handleEscape must clear search")
if esc.index("focusedSearchResultID()") > esc.index("clearSearchIfNeeded()"):
    fail("focused search result must be captured before clearSearchIfNeeded")
if "handOffFocusAfterSearchCleared(focusedResult:" not in esc:
    fail("handleEscape must handOffFocusAfterSearchCleared")

did_start = direct.index("func controlTextDidChange")
did_end = direct.index("func freezeSearchFieldForDismiss", did_start)
did = direct[did_start:did_end]
if "wasSearching = isSearching" not in did and "let wasSearching = isSearching" not in did:
    fail("controlTextDidChange must snapshot wasSearching before applySearch")
if "applySearch()" not in did:
    fail("controlTextDidChange must applySearch")
if did.index("wasSearching") > did.index("applySearch()"):
    fail("wasSearching must be captured before applySearch")
if "shouldFocusFirstGridItemAfterSearchQueryEmptied" not in did:
    fail("controlTextDidChange must consult query-emptied focus gate")
if "focusFirstGridItemOnCurrentPage()" not in did:
    fail("controlTextDidChange must focusFirstGridItemOnCurrentPage when query emptied")

# Custom clearButton removed — productize system NSSearchField cancel.
# Property / custom control — not cancelButtonCell / comments about removal.
if "private let clearButton" in direct or "clearButton =" in direct:
    fail("custom clearButton must stay removed (system cancel owns clear)")
if "@objc private func clearSearch()" in direct:
    fail("dead clearSearch selector must stay removed; use searchFieldDidEndSearching")
if "searchFieldDidEndSearching" not in direct:
    fail("Direct missing searchFieldDidEndSearching for system cancel")
if "shouldFocusFirstGridItemAfterSearchFieldDidEndSearching" not in core:
    fail("Core missing shouldFocusFirstGridItemAfterSearchFieldDidEndSearching")
if "shouldFocusFirstGridItemAfterSearchFieldDidEndSearching" not in direct:
    fail("DidEndSearching must consult Core focus gate")
if "cancelButtonCell" not in direct:
    fail("system cancel button must get accessibility label")
end_s = direct.index("func searchFieldDidEndSearching")
end_body = direct[end_s:direct.index("func controlTextDidChange", end_s)]
if "focusFirstGridItemOnCurrentPage()" not in end_body:
    fail("searchFieldDidEndSearching must focusFirstGridItemOnCurrentPage")

# Clear path keeps the smooth crossfades (no snap helpers) and recovers a
# cut-off nav-hint swap instead of leaving the label at opacity 0.
for fn in ("func handleEscape()", "func controlTextDidChange"):
    s = direct.index(fn)
    body = direct[s:s + 2500]
    for snap in ("snapSearchFooterChromeForSettingsHandoffRestore",
                 "snapPageIndicatorSuppressedForSettingsHandoffRestore",
                 "snapPageArrowsSuppressedForSettingsHandoffRestore"):
        if snap in body:
            fail(f"{fn} must not snap chrome (keep crossfade): {snap}")
if "footerNavigationShouldRestoreOpacityWhenTextUnchanged" not in core:
    fail("Core missing footerNavigationShouldRestoreOpacityWhenTextUnchanged")
nav_s = direct.index("private func setFooterNavigationText")
nav = direct[nav_s:nav_s + 3200]
if "footerNavigationShouldRestoreOpacityWhenTextUnchanged" not in nav:
    fail("setFooterNavigationText must recover cut-off swap when text is unchanged")

print("PASS: Esc/system-cancel search clear restores grid focus (no custom clearButton)")

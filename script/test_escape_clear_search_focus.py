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

# SEARCH-CANCEL-IME-GUARD-01: cancel must not abort an IME composition over an
# empty committed query (same rule as the text-change clear path).
end_s = direct.index("func searchFieldDidEndSearching")
end_body = direct[end_s:direct.index("func controlTextDidChange", end_s)]
if "editingHasMarkedText:" not in end_body or "hasMarkedText()" not in end_body:
    fail("searchFieldDidEndSearching must pass IME marked state to searchCancelRequiresForcedEmpty")
if "searchCancelButtonShouldExitSearch" not in end_body:
    fail("searchFieldDidEndSearching must leave search when the cancel click already cleared the editor")
if "editingHasMarkedText" not in core:
    fail("Core searchCancelRequiresForcedEmpty must take editingHasMarkedText")
if "searchFieldShowsCancelButton" not in core or "SEARCH-CANCEL-VISIBLE-DURING-IME-01" not in core:
    fail("Core missing search cancel visibility during IME")
if "searchCancelButtonShouldExitSearch" not in core or "SEARCH-CANCEL-BUTTON-EXITS-SEARCH-01" not in core:
    fail("Core missing search cancel exit-while-searching")
cell_s = direct.index("private final class LauncherSearchFieldCell")
cell = direct[cell_s:direct.index("private final class LauncherSearchField: NSSearchField", cell_s)]
for needle in (
    "searchFieldShowsCancelButton",
    "override func draw(withFrame cellFrame: NSRect, in controlView: NSView)",
    "override func trackMouse(",
    "searchFieldDidEndSearching?",
):
    if needle not in cell:
        fail(f"search cell missing {needle}")
if "showPage(" in cell or "transitionToPage(" in cell or "completePageTransition(" in cell:
    fail("search cell must not retune paging")

# SEARCH-CANCEL-AX-DURING-IME-01 / SEARCH-CANCEL-AX-WHEN-COMMITTED-01:
# the painted × is in the accessibility children whenever it is visible
# and AppKit left it out, including a committed query. An idle empty
# field returns AppKit's array unchanged.
if "searchCancelAccessibilityShouldAppendSynthetic" not in core:
    fail("Core missing searchCancelAccessibilityShouldAppendSynthetic")
ax_s = cell.index("func accessibilityChildrenIncludingSyntheticCancel")
ax_body = cell[ax_s:cell.index("private func accessibilityChildrenAlreadyIncludeCancel", ax_s)]
if "return system" not in ax_body:
    fail("non-IME search accessibility children must return AppKit's array unchanged")
if "searchCancelAccessibilityShouldAppendSynthetic" not in ax_body:
    fail("synthetic cancel accessibility must ask the Core policy")
if "showPage(" in ax_body or "transitionToPage(" in ax_body or "completePageTransition(" in ax_body:
    fail("search cancel accessibility must not retune paging")
field_s = direct.index("private final class LauncherSearchField: NSSearchField")
field = direct[field_s:direct.index("private final class AliasFieldEditorBridge", field_s)]
if "accessibilityChildrenIncludingSyntheticCancel" not in field:
    fail("search field must share the cell's synthetic-cancel accessibility children")
if "activateSyntheticCancelFromAccessibility" not in cell or "searchFieldDidEndSearching?" not in cell:
    fail("accessibility press must use searchFieldDidEndSearching")

# SEARCH-CANCEL-AX-CHILDREN-CHANGED-DURING-IME-01: post layout-changed only
# when the synthetic × enters or leaves. Do not post on every keystroke.
if "searchCancelAccessibilityTreeUpdate" not in core:
    fail("Core missing searchCancelAccessibilityTreeUpdate")
notify_s = direct.index("private func postSearchCancelAccessibilityTreeChangeIfNeeded")
notify = direct[notify_s:notify_s + 900]
if "searchCancelAccessibilityTreeUpdate" not in notify or "layoutChanged" not in notify:
    fail("synthetic cancel tree change must ask Core and post layoutChanged")
if "showPage(" in notify or "transitionToPage(" in notify or "completePageTransition(" in notify:
    fail("search cancel accessibility notification must not retune paging")
if "postSearchCancelAccessibilityTreeChangeIfNeeded()" not in end_body:
    fail("searchFieldDidEndSearching must refresh the synthetic cancel accessibility tree")
change_s = direct.index("func controlTextDidChange", end_s)
change_body = direct[change_s:direct.index("func freezeSearchFieldForDismiss", change_s)]
if "postSearchCancelAccessibilityTreeChangeIfNeeded()" not in change_body:
    fail("controlTextDidChange must refresh the synthetic cancel accessibility tree")
note_s = direct.index("func noteSearchCompositionEnded")
note_body = direct[note_s:note_s + 280]
if "postSearchCancelAccessibilityTreeChangeIfNeeded()" not in note_body:
    fail("noteSearchCompositionEnded must refresh the synthetic cancel accessibility tree")

print("PASS: Esc/system-cancel search clear restores grid focus (no custom clearButton)")

# SEARCH-CANCEL-BUTTON-ABORTS-IME-01
if "searchCancelButtonRequiresForcedEmpty" not in open("Sources/Core/LauncherLayout.swift", encoding="utf-8").read():
    print("FAIL: missing searchCancelButtonRequiresForcedEmpty")
    raise SystemExit(1)
if "SEARCH-CANCEL-BUTTON-ABORTS-IME-01" not in open("Sources/Direct/LauncherWindowController.swift", encoding="utf-8").read():
    print("FAIL: cancel button must abort IME")
    raise SystemExit(1)
print("PASS: search cancel button aborts IME")

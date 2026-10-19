#!/usr/bin/env python3
"""Guard: search keyboard-open highlight while field stays first responder."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("searchKeyboardHighlightID(" in core, "Core missing searchKeyboardHighlightID")
need("searchKeyboardHighlightIDMoving(" in core, "Core missing searchKeyboardHighlightIDMoving")
need("tileShowsKeyboardFocusChrome(" in core, "Core missing tileShowsKeyboardFocusChrome")
need("testSearchKeyboardHighlightPinsFirstHitWithoutStealingFieldFocusPolicy" in tests, "Core test missing")
need("private var searchKeyboardHighlightID" in direct, "Direct missing highlight id")
need("isSearchKeyboardHighlighted" in direct, "Direct missing tile highlight flag")
need("syncSearchKeyboardHighlight(pinFirst: true)" in direct, "typing must pin first hit")
need("activateSearchKeyboardHighlightOrFirst" in direct, "Return must open highlight")
need("moveSearchKeyboardHighlight(by:" in direct, "arrow move must exist")
need("moveDown(_:)" in direct and "moveUp(_:)" in direct, "doCommandBy must handle arrows")

# Must not steal FR on typing path.
ct = direct[direct.index("func controlTextDidChange"):direct.index("func freezeSearchFieldForDismiss")]
need("focusFirstVisibleSearchResult" not in ct, "typing must not focusFirstVisibleSearchResult")
need("focusSearchResult(" not in ct, "typing must not focusSearchResult (steal FR)")
need("syncSearchKeyboardHighlight(pinFirst: true)" in ct, "controlTextDidChange pins first")
need("shouldFocusFirstGridItemAfterSearchQueryEmptied" in ct, "must keep Esc/empty→grid gate")
need("focusFirstGridItemOnCurrentPage()" in ct, "empty query must still focus grid first")

# Esc path unchanged: capture focusedSearchResultID before clear + handOff.
esc = direct[direct.index("func handleEscape() -> Bool"):direct.index("var highlightedLaunchKey")]
need("focusedSearchResultID()" in esc, "Esc must capture focusedSearchResultID")
need("handOffFocusAfterSearchCleared" in esc, "Esc must handOffFocusAfterSearchCleared")
need("clearSearchIfNeeded()" in esc, "Esc must clear search")

# No paging in highlight helpers / Core APIs.
for label, chunk in (
    ("Core highlight API", core[core.index("searchKeyboardHighlightID("):core.index("tileShowsKeyboardFocusChrome(") + 200]),
    ("Direct sync helper", direct[direct.index("func syncSearchKeyboardHighlight"):direct.index("func refreshItemSelectionChrome")]),
):
    need("showPage" not in chunk and "pageTransition" not in chunk and "movePage" not in chunk,
         f"{label} must not touch paging")


need("shouldHandOffSearchFieldTabToHit" in core, "Core missing Tab handoff gate")
need("searchFieldTabHandoffTargetID" in core, "Core missing Tab handoff target")
need("shouldReturnSearchHitBacktabToField" in core, "Core missing backtab-to-field gate")
need("testSearchFieldTabHandoffToHighlightAndBacktabToField" in tests, "Core Tab handoff test missing")
need("focusSearchKeyboardHighlightOrFirstHit" in direct, "Direct missing Tab handoff helper")
need("insertTab(_:)" in direct, "doCommandBy must handle insertTab")
need("shouldHandOffSearchFieldTabToHit" in direct, "Direct must consult Tab handoff gate")
need("shouldReturnSearchHitBacktabToField" in direct, "Direct must consult backtab-to-field")

# Tab handoff only on deliberate insertTab — not controlTextDidChange.
ct = direct[direct.index("func controlTextDidChange"):direct.index("func freezeSearchFieldForDismiss")]
need("focusSearchKeyboardHighlightOrFirstHit" not in ct, "typing must not Tab-handoff FR")
need("focusSearchResult(" not in ct, "typing must not steal FR via focusSearchResult")

cmd = direct[direct.index("func control(_ control: NSControl, textView: NSTextView, doCommandBy"):direct.index("func scrollSearchResults")]
need("insertTab" in cmd and "focusSearchKeyboardHighlightOrFirstHit" in cmd, "doCommandBy Tab → hit")
need("hasMarkedText" in cmd, "Tab/Return must respect IME marked text")

# Esc path still intact
esc = direct[direct.index("func handleEscape() -> Bool"):direct.index("var highlightedLaunchKey")]
need("handOffFocusAfterSearchCleared" in esc, "Esc→grid handoff must remain")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: search keyboard highlight (field stays FR; Esc→grid preserved; no paging)")

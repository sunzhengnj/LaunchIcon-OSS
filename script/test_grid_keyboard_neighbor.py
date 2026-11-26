#!/usr/bin/env python3
"""Guard: GRID-KEY-WALK-01 + KEYBOARD-HIGHLIGHT-CROSS-PAGE-01.

Neighbor math stays inside one grid (no paging). Direct step still must not
call movePage/showPage; main-grid U/D at edge decline so tile onPage pages.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
layout = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
ui = (root / "Tests/UITests/LauncherDragUITests.swift").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


def body(text, start, end):
    i = text.index(start)
    return text[i : text.index(end, i + len(start))]


neighbor = body(layout, "func gridKeyboardNeighborSlot(", "func gridKeyboardExtendsSelection(")
need("GridKeyboardDirection" in layout, "direction enum missing")
need("func gridKeyboardDirection(forKeyCode" in layout, "key-code map missing")
need("case 116" not in neighbor and "case 121" not in neighbor, "neighbor must not treat Page Up/Down as steps")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "pageDrag"):
    need(banned not in neighbor, f"neighbor math must not name paging ({banned})")

step = body(direct, "func stepGridKeyboard(", "func focusPresentedItem(")
for banned in ("showPage", "movePage", "transitionToPage", "completePageTransition"):
    need(banned not in step, f"step helper must not call paging ({banned})")
need("direction == .left || direction == .right" in step, "main-grid left/right must decline")
need("return false" in step, "declined step must fall through to existing paging")
need("folderDisplayColumns" in step, "folder walk must use the folder column count")
need("gridGeometry.columns" in step, "search and main grid use the live grid columns")
need("onGridKeyboardStep" in direct, "tile callback missing")
need("gridKeyboardDirection(forKeyCode:" in direct, "tile must ask Core which arrows walk")

# Tile keyDown still pages left/right and Page Up/Down when the walk declines.
tile = body(direct, "override func keyDown(with event: NSEvent) {\n        // NSView.keyDown", "override func insertTab")
need("onPage?(-1)" in tile and "onPage?(1)" in tile, "tile paging fallback missing")
need("case 123, 116, 126:" in tile and "case 124, 121, 125:" in tile,
     "page keys must include U/D for cross-page highlight (KEYBOARD-HIGHLIGHT-CROSS-PAGE-01)")
need("direction == .up || direction == .down" in step,
     "main-grid U/D edge must decline to page")

need("private func showPage(" in direct, "showPage missing")
need("testGridKeyboardNeighborStaysInsideTheGrid" in tests, "Core test missing")
need("testPageCountKeyboardNeighborAndSearchPlacementAtCompactAndWideGeometry" in tests, "compact/wide keyboard test missing")
need("from: 26, count: 36, columns: wide.columns, direction: .down" in tests, "10×8 short last-row down walk missing")
need("from: 1, count: 6, columns: compact.columns, direction: .down" in tests, "5×3 short last-row down walk missing")
need("searchKeyboardHighlightIDMoving" in tests, "search-field highlight walk must stay in Core tests")
need("folderCloseShouldRestoreGridFocusOnChromeLand" in tests, "folder-close focus restore policy missing from Core tests")
need("testArrowAtFolderEdgeStaysInsideAndKeepsMainPage" in ui, "UI folder-edge arrow case missing")
need("func gridKeyboardShiftStep(" in layout, "shift-arrow selection step missing")
need("func gridKeyboardExtendsSelection(" in layout, "shift-arrow modifier gate missing")
need("testGridKeyboardShiftExtendsSelectionWithoutPaging" in tests, "Core shift-arrow test missing")
need("onGridKeyboardShiftStep" in direct, "tile shift-arrow callback missing")
need("func gridKeyboardHomeEndSlot(" in layout, "Home/End slot missing")
need("onGridKeyboardHomeEnd" in direct, "tile Home/End callback missing")
need("func jumpGridKeyboardHomeEnd(" in direct, "Home/End jump missing")
need("testGridKeyboardHomeEndStaysOnTheCurrentPage" in tests, "Core Home/End test missing")
need("func gridKeyboardShiftHomeEnd(" in layout, "Shift-Home/End missing")
need("gridKeyboardShiftHomeEnd(" in direct, "Direct must extend on Shift-Home/End")
need("testGridKeyboardShiftHomeEndSelectsToTheEdge" in tests, "Core Shift-Home/End test missing")
home = body(direct, "func jumpGridKeyboardHomeEnd(", "func focusPresentedItem(")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "onPage"):
    need(banned not in home, f"Home/End jump must not page ({banned})")
need("extendSelectionByGridKeyboard" in direct, "Direct shift-arrow helper missing")
shift = body(layout, "func gridKeyboardShiftStep(", "func focusSlot(")
need("walksLeftRight" in shift, "shift step must decline main-grid left/right")
need("consumesKey" in shift, "shift step must say whether the key is consumed")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "pageDrag"):
    need(banned not in shift, f"shift step must not name paging ({banned})")
extend = body(direct, "func extendSelectionByGridKeyboard(", "/// Arrow step inside the collection")
for banned in ("showPage", "movePage", "transitionToPage", "completePageTransition"):
    need(banned not in extend, f"shift helper must not call paging ({banned})")
need("walksLeftRight: isFolder || isSearch" in extend, "folder and search must walk left/right")
show = body(direct, "private func showPage(", "@objc private func showPreviousPage(")
need("openedFolderID == nil, !isSearching" in show, "showPage guard changed")
need("gridKeyboard" not in show, "showPage must not grow a keyboard branch")

# ROOT-ARROW-FOCUS-01: horizontal Up/Down on the root view land on the first
# tile of the current page; never page, never open search.
need("rootVerticalArrowFocusesFirstGridItem" in layout, "Core root arrow focus gate missing")
need("testRootVerticalArrowFocusesFirstGridItemOnlyOnIdleHorizontalGrid" in tests, "Core root arrow focus test missing")
root_focus = body(direct, "private func focusFirstGridItemFromRootVerticalArrow()", "private func focusFirstGridItemOnCurrentPage()")
need("rootVerticalArrowFocusesFirstGridItem(" in root_focus, "root arrow focus must consult Core gate")
need("isPaging: isPaging" in root_focus, "root arrow focus must decline mid page transition")
for banned in ("movePage", "showPage", "transitionToPage", "completePageTransition", "beginSearch"):
    need(banned not in root_focus, f"root arrow focus must not call {banned}")

need("func commandZUndoesKeyboardLayout(" in layout, "Core command-z undo gate missing")
need("func recordingKeyboardLayoutUndo(" in layout, "Core layout undo record missing")
need("func applyingKeyboardLayoutUndo(" in layout, "Core layout undo apply missing")
need("var expected: LayoutState" in layout, "undo slot must remember the committed layout")
need("layoutMatchesKeyboardUndoExpected(" in layout, "undo apply must reject a stale layout")
need("func undoKeyboardLayoutChange(" in direct, "Direct command-z undo missing")
need("undoKeyboardLayoutChange(" in direct, "panel must ask to undo an arrow reorder")
need("testCommandZUndoesTheLastKeyboardLayoutChange" in tests, "Core command-z undo test missing")
need("testCommandZDiscardsAStaleKeyboardUndoAfterAnotherLayoutCommit" in tests, "Core stale undo test missing")
need("testCommandZOnlyUndoesTheLatestOfTwoKeyboardLayoutChanges" in tests, "Core latest-only undo test missing")
undo_record = body(direct, "func commitKeyboardLayoutChange(", "func undoKeyboardLayoutChange(")
need("recordingKeyboardLayoutUndo(" in undo_record, "arrow reorder must remember the previous layout")
need("preservesKeyboardUndo: true" in undo_record, "arrow reorder must keep the slot it just recorded")
need("commitLayout(" in undo_record, "arrow reorder must still commit")
undo_apply = body(direct, "func undoKeyboardLayoutChange(", "func nudgeTopLevelSelectionFromCommandOptionHorizontal(")
need("commandZUndoesKeyboardLayout(" in undo_apply, "command-z must ask Core")
need("applyingKeyboardLayoutUndo(" in undo_apply, "command-z must restore the saved layout")
need("keyboardLayoutUndo = nil" in undo_apply, "command-z must drop a stale slot")
need("return true" in undo_apply, "command-z must consume the key when it owns the chord")
need("commitLayout(" in undo_apply, "command-z must commit the restored layout")
need("preservesKeyboardUndo: Bool = false" in direct, "other layout commits must be able to drop the undo slot")
need("keyboardLayoutUndo = nil" in body(direct, "func commitLayout(", "if dropLandingView != nil {"), "non-keyboard commitLayout must clear the undo slot")
undo_panel = body(direct, "// GRID-COMMAND-Z-UNDO-01:", "// GRID-COMMAND-SHIFT-A-SELECT-ALL-01:")
need("undoKeyboardLayoutChange(" in undo_panel, "panel must call the undo")
need("return true" in undo_panel, "panel must consume command-z")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage"):
    need(banned not in undo_record, f"undo record must not page ({banned})")
    need(banned not in undo_apply, f"undo apply must not page ({banned})")
    need(banned not in undo_panel, f"undo panel must not page ({banned})")

need("func nudgingTopLevelSelectionOneStepOnItsPage(" in layout, "Core selection nudge missing")
need("func nudgeTopLevelSelectionFromCommandOptionHorizontal(" in direct, "Direct selection nudge missing")
need("nudgeTopLevelSelectionFromCommandOptionHorizontal(" in direct, "panel must ask to nudge a selection")
need("testCommandOptionHorizontalNudgeMovesATopLevelSelection" in tests, "Core selection nudge test missing")
selection_nudge = body(direct, "func nudgeTopLevelSelectionFromCommandOptionHorizontal(", "func nudgeFocusedEntryFromCommandOptionHorizontal(")
need("nudgingTopLevelSelectionOneStepOnItsPage(" in selection_nudge, "selection nudge must move the block")
need("itemSelection.count >= 2" in selection_nudge, "one icon must keep the single swap")
need("return true" in selection_nudge, "selection nudge must consume the key")
need("focusGridEntry(" in selection_nudge, "selection nudge must follow the focus")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage"):
    need(banned not in selection_nudge, f"selection nudge must not page ({banned})")

need("func commandOptionHorizontalNudgesFocusedEntry(" in layout, "Core horizontal nudge gate missing")
need("func nudgingFocusedEntryOneStepOnItsPage(" in layout, "Core same-page nudge missing")
need("func nudgeFocusedEntryFromCommandOptionHorizontal(" in direct, "Direct horizontal nudge missing")
need("nudgeFocusedEntryFromCommandOptionHorizontal(" in direct, "panel must ask to nudge")
need("testCommandOptionHorizontalNudgeSwapsOnTheSamePage" in tests, "Core horizontal nudge test missing")
nudge = body(direct, "func nudgeFocusedEntryFromCommandOptionHorizontal(", "/// BATCH-BLANK-SELECTED-EDGE-01")
need("commandOptionHorizontalNudgesFocusedEntry(" in nudge, "nudge shortcut must ask Core")
need("nudgingFocusedEntryOneStepOnItsPage(" in nudge, "nudge shortcut must use the same-page swap")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage"):
    need(banned not in nudge, f"horizontal nudge must not page ({banned})")

need("func movingTopLevelSelectionToEdge(" in layout, "Core selection edge move missing")
need("func moveTopLevelSelectionToEdgeFromCommandShiftHorizontal(" in direct, "Direct selection edge missing")
need("moveTopLevelSelectionToEdgeFromCommandShiftHorizontal(" in direct, "panel must ask to move a selection to the edge")
need("testCommandShiftHorizontalMovesATopLevelSelectionToTheEdge" in tests, "Core selection edge test missing")
selection_edge = body(direct, "func moveTopLevelSelectionToEdgeFromCommandShiftHorizontal(", "func moveFocusedEntryToEdgeFromCommandShiftHorizontal(")
need("movingTopLevelSelectionToEdge(" in selection_edge, "selection edge must move the block")
need("itemSelection.count >= 2" in selection_edge, "one icon must keep the single edge move")
need("return true" in selection_edge, "selection edge must consume the key")
need("focusGridEntry(" in selection_edge, "selection edge must follow the focus")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage"):
    need(banned not in selection_edge, f"selection edge must not page ({banned})")

need("func commandShiftHorizontalMovesFocusedEntryToEdge(" in layout, "Core horizontal edge gate missing")
need("func movingFocusedTopLevelEntryToEdge(" in layout, "Core focused-entry edge move missing")
need("func moveFocusedEntryToEdgeFromCommandShiftHorizontal(" in direct, "Direct horizontal edge missing")
need("moveFocusedEntryToEdgeFromCommandShiftHorizontal(" in direct, "panel must ask to move the focused entry")
need("testCommandShiftHorizontalMovesTheFocusedEntryToTheEdge" in tests, "Core horizontal edge test missing")
horizontal_edge = body(direct, "func moveFocusedEntryToEdgeFromCommandShiftHorizontal(", "/// BATCH-BLANK-SELECTED-EDGE-01")
need("commandShiftHorizontalMovesFocusedEntryToEdge(" in horizontal_edge, "horizontal edge must ask Core")
need("movingFocusedTopLevelEntryToEdge(" in horizontal_edge, "horizontal edge must move one entry")
need("return true" in horizontal_edge, "horizontal edge must consume the key")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage"):
    need(banned not in horizontal_edge, f"horizontal edge must not page ({banned})")

need("func movingTopLevelSelectionToAdjacentPage(" in layout, "Core selection adjacent-page move missing")
need("func moveTopLevelSelectionToAdjacentPageFromCommandOptionShiftHorizontal(" in direct, "Direct selection adjacent-page move missing")
need("moveTopLevelSelectionToAdjacentPageFromCommandOptionShiftHorizontal(" in direct, "panel must ask to move a selection to the adjacent page")
need("testCommandOptionShiftHorizontalMovesATopLevelSelectionToTheAdjacentPage" in tests, "Core selection adjacent-page test missing")
selection_page_move = body(direct, "func moveTopLevelSelectionToAdjacentPageFromCommandOptionShiftHorizontal(", "func moveFocusedEntryToAdjacentPageFromCommandOptionShiftHorizontal(")
need("movingTopLevelSelectionToAdjacentPage(" in selection_page_move, "selection adjacent-page move must move the block")
need("itemSelection.count >= 2" in selection_page_move, "one icon must keep the single page move")
need("return true" in selection_page_move, "selection adjacent-page move must consume the key")
need("focusGridEntry(" in selection_page_move, "selection adjacent-page move must follow the focus")
need("commitKeyboardLayoutChange(" in selection_page_move, "selection adjacent-page move must keep one undo")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage"):
    need(banned not in selection_page_move, f"selection adjacent-page move must not page ({banned})")

need("func movingFocusedEntryToAdjacentPage(" in layout, "Core adjacent-page move missing")
need("func moveFocusedEntryToAdjacentPageFromCommandOptionShiftHorizontal(" in direct, "Direct adjacent-page move missing")
need("moveFocusedEntryToAdjacentPageFromCommandOptionShiftHorizontal(" in direct, "panel must ask to move to the adjacent page")
need("testCommandOptionShiftHorizontalMovesTheFocusedEntryToTheAdjacentPage" in tests, "Core adjacent-page move test missing")
page_move = body(direct, "func moveFocusedEntryToAdjacentPageFromCommandOptionShiftHorizontal(", "func nudgeFolderMemberSelectionFromCommandOptionHorizontal(")
need("movingFocusedEntryToAdjacentPage(" in page_move, "adjacent-page move must move the entry")
need("selectedCount: itemSelection.count" in page_move, "a multi-select must stay put")
need("return true" in page_move, "adjacent-page move must consume the key")
need("focusGridEntry(" in page_move, "adjacent-page move must follow the focus")
need("commitKeyboardLayoutChange(" in page_move, "adjacent-page move must keep one undo")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage"):
    need(banned not in page_move, f"adjacent-page move must not page ({banned})")

need("func nudgingFolderMemberSelection(" in layout, "Core folder selection nudge missing")
need("func nudgeFolderMemberSelectionFromCommandOptionHorizontal(" in direct, "Direct folder selection nudge missing")
need("nudgeFolderMemberSelectionFromCommandOptionHorizontal(" in direct, "panel must ask to nudge a folder selection")
need("testCommandOptionHorizontalNudgeMovesAFolderSelection" in tests, "Core folder selection nudge test missing")
folder_selection = body(direct, "func nudgeFolderMemberSelectionFromCommandOptionHorizontal(", "func nudgeFocusedFolderMemberFromCommandOptionHorizontal(")
need("nudgingFolderMemberSelection(" in folder_selection, "folder selection nudge must move the run")
need("itemSelection.count >= 2" in folder_selection, "one member must keep the single swap")
need("return true" in folder_selection, "folder selection nudge must consume the key")
need("focusPresentedItem(id:" in folder_selection, "folder selection nudge must follow the member")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage", "focusGridEntry"):
    need(banned not in folder_selection, f"folder selection nudge must not page ({banned})")

need("func commandOptionHorizontalNudgesFocusedFolderMember(" in layout, "Core folder-member nudge gate missing")
need("func nudgingFocusedFolderMember(" in layout, "Core folder-member nudge missing")
need("func nudgeFocusedFolderMemberFromCommandOptionHorizontal(" in direct, "Direct folder-member nudge missing")
need("nudgeFocusedFolderMemberFromCommandOptionHorizontal(" in direct, "panel must ask to nudge a folder member")
need("testCommandOptionHorizontalNudgeSwapsAFolderMember" in tests, "Core folder-member nudge test missing")
folder_nudge = body(direct, "func nudgeFocusedFolderMemberFromCommandOptionHorizontal(", "/// BATCH-BLANK-SELECTED-EDGE-01")
need("commandOptionHorizontalNudgesFocusedFolderMember(" in folder_nudge, "folder nudge must ask Core")
need("nudgingFocusedFolderMember(" in folder_nudge, "folder nudge must swap members")
need("focusPresentedItem(id:" in folder_nudge, "folder nudge must keep the member focused")
need("return true" in folder_nudge, "folder nudge must consume the key")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage", "focusGridEntry"):
    need(banned not in folder_nudge, f"folder nudge must not page ({banned})")

need("func movingFolderMemberSelectionToEdge(" in layout, "Core folder selection edge missing")
need("func moveFolderMemberSelectionToEdgeFromCommandShiftHorizontal(" in direct, "Direct folder selection edge missing")
need("moveFolderMemberSelectionToEdgeFromCommandShiftHorizontal(" in direct, "panel must ask to move a folder selection")
need("testCommandShiftHorizontalMovesAFolderSelectionToTheEdge" in tests, "Core folder selection edge test missing")
folder_selection_edge = body(direct, "func moveFolderMemberSelectionToEdgeFromCommandShiftHorizontal(", "func moveFocusedFolderMemberToEdgeFromCommandShiftHorizontal(")
need("movingFolderMemberSelectionToEdge(" in folder_selection_edge, "folder selection edge must move the run")
need("itemSelection.count >= 2" in folder_selection_edge, "one member must keep the single edge move")
need("return true" in folder_selection_edge, "folder selection edge must consume the key")
need("focusPresentedItem(id:" in folder_selection_edge, "folder selection edge must follow the member")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage", "focusGridEntry"):
    need(banned not in folder_selection_edge, f"folder selection edge must not page ({banned})")

need("func commandShiftHorizontalMovesFocusedFolderMemberToEdge(" in layout, "Core folder-member edge gate missing")
need("func movingFocusedFolderMemberToEdge(" in layout, "Core folder-member edge move missing")
need("func moveFocusedFolderMemberToEdgeFromCommandShiftHorizontal(" in direct, "Direct folder-member edge missing")
need("moveFocusedFolderMemberToEdgeFromCommandShiftHorizontal(" in direct, "panel must ask to move a folder member")
need("testCommandShiftHorizontalMovesAFolderMemberToTheEdge" in tests, "Core folder-member edge test missing")
folder_edge = body(direct, "func moveFocusedFolderMemberToEdgeFromCommandShiftHorizontal(", "/// BATCH-BLANK-SELECTED-EDGE-01")
need("commandShiftHorizontalMovesFocusedFolderMemberToEdge(" in folder_edge, "folder edge must ask Core")
need("movingFocusedFolderMemberToEdge(" in folder_edge, "folder edge must move one member")
need("focusPresentedItem(id:" in folder_edge, "folder edge must keep the member focused")
need("return true" in folder_edge, "folder edge must consume the key")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage", "focusGridEntry"):
    need(banned not in folder_edge, f"folder edge must not page ({banned})")

need("func commandShiftVerticalMovesFocusedFolderMemberToEdge(" in layout, "Core folder vertical edge gate missing")
need("func movingFocusedFolderMembersToEdge(" in layout, "Core folder vertical edge move missing")
need("func moveFocusedFolderMemberToEdgeFromCommandShiftVertical(" in direct, "Direct folder vertical edge missing")
need("moveFocusedFolderMemberToEdgeFromCommandShiftVertical(" in direct, "panel must ask to move a folder member vertically")
need("testCommandShiftVerticalMovesAFolderMemberToTheEdge" in tests, "Core folder vertical edge test missing")
folder_vertical = body(direct, "func moveFocusedFolderMemberToEdgeFromCommandShiftVertical(", "/// BATCH-BLANK-SELECTED-EDGE-01")
need("commandShiftVerticalMovesFocusedFolderMemberToEdge(" in folder_vertical, "folder vertical edge must ask Core")
need("movingFocusedFolderMembersToEdge(" in folder_vertical, "folder vertical edge must move the member block")
need("focusPresentedItem(id:" in folder_vertical, "folder vertical edge must keep the member focused")
need("return true" in folder_vertical, "folder vertical edge must consume the key")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage", "focusGridEntry"):
    need(banned not in folder_vertical, f"folder vertical edge must not page ({banned})")

need("func nudgingFolderMemberSelectionByRow(" in layout, "Core folder selection row nudge missing")
need("func nudgeFolderMemberSelectionFromCommandOptionVertical(" in direct, "Direct folder selection row nudge missing")
need("nudgeFolderMemberSelectionFromCommandOptionVertical(" in direct, "panel must ask to nudge a folder selection by row")
need("testCommandOptionVerticalNudgeMovesAFolderSelectionByRow" in tests, "Core folder selection row nudge test missing")
folder_selection_row = body(direct, "func nudgeFolderMemberSelectionFromCommandOptionVertical(", "func nudgeFocusedFolderMemberFromCommandOptionVertical(")
need("nudgingFolderMemberSelectionByRow(" in folder_selection_row, "folder selection row nudge must move the run")
need("itemSelection.count >= 2" in folder_selection_row, "one member must keep the single row swap")
need("return true" in folder_selection_row, "folder selection row nudge must consume the key")
need("focusPresentedItem(id:" in folder_selection_row, "folder selection row nudge must follow the member")
need("folderDisplayColumns(forItemCount:" in folder_selection_row, "folder selection row nudge must use the folder column count")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage", "focusGridEntry"):
    need(banned not in folder_selection_row, f"folder selection row nudge must not page ({banned})")

need("func commandOptionVerticalNudgesFocusedFolderMember(" in layout, "Core folder row nudge gate missing")
need("func nudgingFocusedFolderMemberByRow(" in layout, "Core folder row nudge missing")
need("func nudgeFocusedFolderMemberFromCommandOptionVertical(" in direct, "Direct folder row nudge missing")
need("nudgeFocusedFolderMemberFromCommandOptionVertical(" in direct, "panel must ask to nudge a folder row")
need("testCommandOptionVerticalNudgeSwapsAFolderMemberByRow" in tests, "Core folder row nudge test missing")
folder_row = body(direct, "func nudgeFocusedFolderMemberFromCommandOptionVertical(", "/// BATCH-BLANK-SELECTED-EDGE-01")
need("commandOptionVerticalNudgesFocusedFolderMember(" in folder_row, "folder row nudge must ask Core")
need("nudgingFocusedFolderMemberByRow(" in folder_row, "folder row nudge must swap one row")
need("folderDisplayColumns(forItemCount:" in folder_row, "folder row nudge must use the folder column count")
need("focusPresentedItem(id:" in folder_row, "folder row nudge must keep the member focused")
need("return true" in folder_row, "folder row nudge must consume the key")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage", "focusGridEntry"):
    need(banned not in folder_row, f"folder row nudge must not page ({banned})")

if failures:
    print("FAIL: grid keyboard neighbor")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: grid keyboard neighbor")

#!/usr/bin/env python3
"""Guard: Core multi-select selection model + Command-click chrome (no paging)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
docs = (root / "Docs/MULTI_SELECT_DESIGN.md").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("struct LauncherItemSelection" in core, "Core missing LauncherItemSelection")
need("enum ClickKind" in core, "Core missing ClickKind")
need("case toggle" in core and "case replace" in core, "Core ClickKind must have replace/toggle")
need("removeAbsent(from" in core, "Core missing removeAbsent prune")
need("tileChromeSelectionAlpha" in core, "Core missing selection chrome alpha")
need("selected: Bool = false" in core, "tileChromeFillAlpha must take selected")
need("testLauncherItemSelectionReplaceToggleAndPrune" in tests, "Core tests missing selection model test")
need("tileChromeSelectionAlpha" in tests, "Core tests must assert selection alpha ordering")
need("LauncherItemSelection" in docs, "Design doc must name Core type")
need("private var itemSelection" in direct, "Direct must hold itemSelection")
need("onCommandToggleSelection" in direct, "Direct must wire Command-click toggle")
need(("modifierFlags.contains(.command)" in direct) or ("mods.contains(.command)" in direct),
     "Direct mouseUp must honour Command")
need("selected: isSelected" in direct, "Direct chrome must pass selected")
need("refreshItemSelectionChrome" in direct, "Direct must refresh selection chrome")

need("hideSelectedApplicationsToastMessageFormatKey" in core, "Core missing batch hide toast")
need("appKeysForBatchHide" in core, "Core missing appKeysForBatchHide")
need("topLevelAppIDsForBatchFolder" in core, "Core missing topLevelAppIDsForBatchFolder")
need("hideApplications(withKeys" in core, "Core missing hideApplications")
need("createFolderFromTopLevelApps" in core, "Core missing createFolderFromTopLevelApps")
need("隐藏所选应用" in direct, "Direct missing batch hide menu title")
need("移入新建文件夹" in direct, "Direct missing batch folder menu title")
need("hideSelectedApplications(anchorFocusID" in direct, "Direct missing batch hide action")
need("moveSelectionToNewFolder" in direct, "Direct missing batch folder action")
need("onBatchHideSelection" in direct and "onBatchMoveSelectionToFolder" in direct,
     "Direct tile missing batch menu callbacks")
need("testBatchHideAndCreateFolderFromSelection" in tests, "Core tests missing batch ops")

for name in ("hideSelectedApplications(", "moveSelectionToNewFolder("):
    key = "private func " + name
    start = direct.index(key)
    chunk = direct[start:start + 2200]
    need("showPage" not in chunk and "pageTransition" not in chunk and "movePage" not in chunk,
         f"{name} must not touch paging")

need("presentSelectableItemIDs" in core, "Core missing presentSelectableItemIDs")
need("prunedItemSelection" in core, "Core missing prunedItemSelection")
need("pruningAbsent(from" in core, "Core missing pruningAbsent")
need("prunedItemSelection(itemSelection, in: layoutState)" in direct,
     "Direct must prune on layout commit")
need(direct.count("prunedItemSelection(itemSelection, in: layoutState)") >= 2,
     "Direct must prune in commitLayout and setCatalog")
need("testPrunedItemSelectionAfterHideUninstallAndFolderDissolve" in tests,
     "Core tests missing hide/uninstall/dissolve prune")

# HARD: prune assignment lines must not touch paging
for i, line in enumerate(direct.splitlines()):
    if "prunedItemSelection(itemSelection" in line:
        need("showPage" not in line and "pageTransition" not in line and "movePage" not in line,
             f"prune line {i+1} must not touch paging")

need("applyingRange" in core, "Core missing Shift-click applyingRange")
need("rangeAnchorID" in core, "Core missing rangeAnchorID")
need("onShiftSelectRange" in direct, "Direct missing Shift-click callback")
need("mods.contains(.shift)" in direct or "modifierFlags.contains(.shift)" in direct,
     "Direct mouseUp must honour Shift")
need("testShiftClickRangeSelectionPreservesAnchorWithoutPaging" in tests,
     "Core tests missing Shift-click range")
# HARD: shift handler must not page
if "onShiftSelectRange = {" in direct:
    start = direct.index("onShiftSelectRange = {")
    chunk = direct[start:start+500]
    need("showPage" not in chunk and "movePage" not in chunk and "pageTransition" not in chunk,
         "Shift-click handler must not touch paging")

block = direct[direct.index("private func refreshItemSelectionChrome("):]
block = block[: block.index("private func visibleGridTiles(")]
need("showPage" not in block and "pageTransition" not in block and "movePage" not in block,
     "refreshItemSelectionChrome must not touch paging")

mouse = direct[direct.index("override func mouseUp(with event: NSEvent)"):]
mouse = mouse[: mouse.index("private func configureContextMenu(")]
need("showPage" not in mouse and "pageTransition" not in mouse,
     "tile mouseUp must not touch paging")

need("shouldBatchCreateFolderFromSelection" in core, "Core missing batch-create-folder gate")
need("topLevelAppIDsForBatchCreateFolder" in core, "Core missing batch-create-folder ids")
need("testBatchCreateFolderFromSelectionDropOntoAppSamePageOnly" in tests,
     "Core batch-create-folder test missing")
need("batchCreateFolderApps" in direct, "Direct missing batch create-folder drop branch")
bc = direct.index("let batchCreateFolderApps")
need("createFolderFromTopLevelApps" in direct[bc:bc + 2000],
     "Direct batch-create must call createFolderFromTopLevelApps")

need("moveTopLevelApps" in core, "Core missing moveTopLevelApps into folder")
need("shouldBatchMoveSelectionIntoFolder" in core, "Core missing batch-into-folder gate")
need("topLevelAppIDsForBatchMoveIntoFolder" in core, "Core missing same-page batch ids")
need("testBatchMoveSelectionIntoExistingFolderSamePageOnly" in tests,
     "Core batch-into-folder test missing")
need("batchIntoFolder" in direct or "moveTopLevelApps(" in direct,
     "Direct must call batch move into folder on drop")
# HARD: batch folder move wiring must not alter paging animation helpers
need("pageAnimationDuration" not in direct[direct.index("batchIntoFolder"):direct.index("batchIntoFolder")+1200]
     if "batchIntoFolder" in direct else True,
     "batch-into-folder block must not touch pageAnimationDuration")
drop_idx = direct.index("let batchIntoFolder")
drop_chunk = direct[drop_idx:drop_idx + 7500]
need("showPage" not in drop_chunk.split("commitLayout(next)")[0],
     "batch branch setup must not call showPage before commit")
need("batchCreateFolderApps" in drop_chunk, "applyDrop must consider batch create-folder")
need("itemSelection.clear()" in drop_chunk, "batch multi-select drop must clear selection")
need("batchIntoFolder != nil || batchCreateFolderApps != nil" in drop_chunk,
     "clear selection after either batch drop path")

need("selectingAll" in core, "Core missing selectingAll")
need("itemIDs(onPage" in core, "Core missing itemIDs(onPage:)")
need("testSelectAllOnCurrentPageOnlyDoesNotIncludeOtherPages" in tests, "Core select-all page test missing")
need("selectAllItemsOnCurrentPage" in direct, "Direct missing select-all handler")
need("selectAllHandler" in direct, "Panel missing selectAllHandler")
need('charactersIgnoringModifiers?.lowercased() == "a"' in direct, "Panel must handle Command-A")
idx = direct.index("func selectAllItemsOnCurrentPage")
chunk = direct[idx:idx + 900]
need("showPage" not in chunk and "pageTransition" not in chunk and "movePage" not in chunk
     and "transitionToPage" not in chunk,
     "selectAllItemsOnCurrentPage must not touch paging")
need("itemIDs(onPage: currentPage" in chunk, "select-all must use current page ids only")
esc = direct.index("func handleEscape()")
esc_chunk = direct[esc:esc + 900]
need("itemSelection.clear()" in esc_chunk, "Escape should clear multi-select when non-empty")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: multi-select selection model + Command-click chrome + Cmd-A page select-all")

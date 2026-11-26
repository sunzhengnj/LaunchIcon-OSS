#!/usr/bin/env python3
"""Guard: KEYBOARD-COMMAND-REGISTRY-01.

The first-wave Core registry (⌘Z, ⌘⌥ series, ⌘⌫ / ⌘⇧⌫) is in the Core
target, lists each command once, and Direct still tries the existing
handlers in that order. Keys and conflict priority stay the same.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
registry = (root / "Sources/Core/KeyboardCommand.swift").read_text()
layout = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
pbx = (root / "LaunchIcon.xcodeproj/project.pbxproj").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


need("KEYBOARD-COMMAND-REGISTRY-01" in registry, "registry product id missing")
need("public enum KeyboardCommand" in registry, "KeyboardCommand enum missing")
need("public struct KeyboardProbe" in registry, "KeyboardProbe missing")
need("public static let registeredKeyboardCommands" in registry, "registered table missing")
need("public static func resolveKeyboardCommand(" in registry, "resolveKeyboardCommand missing")
need("public static func matchingKeyboardCommands(" in registry, "matchingKeyboardCommands missing")

# pbx: file in the Core group and the Core sources phase
need(
    "A20000000000000000000028 /* KeyboardCommand.swift */" in pbx,
    "KeyboardCommand.swift file reference missing",
)
need(
    "A10000000000000000000028 /* KeyboardCommand.swift in Sources */" in pbx,
    "KeyboardCommand.swift build file missing",
)
core_group = re.search(
    r"A70000000000000000000003 /\* Core \*/ = \{isa = PBXGroup; children = \((.*?)\); path = Core;",
    pbx,
    re.S,
)
need(core_group is not None, "Core group missing")
need(
    core_group is not None and "KeyboardCommand.swift" in core_group.group(1),
    "KeyboardCommand.swift not in the Core group",
)
core_phase = re.search(
    r"A90000000000000000000001 /\* Sources \*/ = \{isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);",
    pbx,
    re.S,
)
need(core_phase is not None, "Core sources phase missing")
need(
    core_phase is not None and "KeyboardCommand.swift in Sources" in core_phase.group(1),
    "KeyboardCommand.swift not in the Core sources phase",
)

# Registered try-order, unique, wraps existing gates.
block = re.search(
    r"public static let registeredKeyboardCommands: \[KeyboardCommand\] = \[(.*?)\]",
    registry,
    re.S,
)
need(block is not None, "registeredKeyboardCommands list missing")
commands = re.findall(r"\.(\w+)", block.group(1) if block else "")
need(len(commands) == 52, f"expected 52 registered commands, got {len(commands)}: {commands}")
need(len(commands) == len(set(commands)), f"duplicate registry entries: {commands}")
need(
    commands
    == [
        "openSettings",
        "focusSearch",
        "dismissLauncher",
        "copyFocusedApp",
        "selectAllOnPage",
        "undoLayout",
        "selectEveryTopLevelEntry",
        "shiftMMovesSelectionIntoFolder",
        "shiftNCreatesFolder",
        "optionNSortsFocusedFolder",
        "optionNSortsOpenFolder",
        "optionCSortsFocusedFolder",
        "optionCSortsOpenFolder",
        "optionRRearrangesGridByName",
        "optionKRearrangesGridByKind",
        "optionKSortsOpenFolderByKind",
        "optionGRearrangesGridByCategory",
        "optionGSortsOpenFolderByCategory",
        "shiftCRearrangesGridByColor",
        "optionBTogglesBrowseAxis",
        "optionUUngroupsAllFolders",
        "shiftURestoresAllHidden",
        "reloadCatalog",
        "shiftHHidesFocusedApp",
        "removeFromOpenFolder",
        "dissolveClosedFolder",
        "uninstallApp",
        "shiftReturnRevealsSelection",
        "revealSearchHit",
        "revealFocusedTile",
        "shiftVerticalMovesFocusedFolderMember",
        "shiftVerticalSelectionEdge",
        "optionVerticalNudgesFocusedFolderMember",
        "optionVerticalMovesFoldersToEdge",
        "commandUpClosesOpenFolder",
        "commandDownOpensFocusedFolder",
        "optionShiftHorizontalMovesFocusedEntryToAdjacentPage",
        "optionHorizontalNudgesFocusedFolderMember",
        "shiftHorizontalMovesFocusedFolderMember",
        "optionHorizontalNudgesFocusedEntry",
        "shiftHorizontalMovesFocusedEntry",
        "commandArrowPaging",
        "escapeCancels",
        "spaceActivatesFocusedItem",
        "arrowExtendsSelection",
        "arrowWalksGrid",
        "shiftHomeEndExtendsSelection",
        "homeEndJumpsInGrid",
        "f2RenamesFocusedClosedFolder",
        "f2RenamesFocusedAppAlias",
        "pageUpDownScrollsOpenList",
        "pageUpDownPagesGrid",
    ],
    f"registry try-order drifted: {commands}",
)

for gate in (
    "func commandCommaOpensSettings(",
    "func commandEscapeCancelsOrDismisses(",
    "func spaceActivatesFocusedItem(",
    "func arrowExtendsSelection(",
    "func arrowWalksGrid(",
    "func commandShiftHomeEndExtendsSelection(",
    "func commandHomeEndJumpsInGrid(",
    "func f2RenamesFocusedClosedFolder(",
    "func f2RenamesFocusedAppAlias(",
    "func commandPageUpDownScrollsOpenList(",
    "func commandPageUpDownPagesGrid(",
    "func commandFFocusesSearch(",
    "func commandWDismissesLauncher(",
    "func commandCCopiesFocusedApp(",
    "func commandASelectsCurrentPageIcons(",
    "func commandZUndoesKeyboardLayout(",
    "func commandShiftASelectsEveryTopLevelEntry(",
    "func commandShiftMMovesSelectionIntoFolder(",
    "func commandShiftNCreatesFolder(",
    "func commandShiftCRearrangesGridByColor(",
    "func commandShiftVerticalMovesFocusedFolderMemberToEdge(",
    "func commandShiftVerticalSelectionEdge(",
    "func commandShiftHorizontalMovesFocusedFolderMemberToEdge(",
    "func commandShiftHorizontalMovesFocusedEntryToEdge(",
    "func commandDeleteFolderRemoval(",
    "func commandDeleteDissolvesClosedFolder(",
    "func commandShiftDeleteUninstallsFocusedApp(",
    "func commandOptionNSortsFocusedFolder(",
    "func commandOptionNSortsOpenFolder(",
    "func commandOptionCSortsFocusedFolderByColor(",
    "func commandOptionCSortsOpenFolderByColor(",
    "func commandOptionRRearrangesGridByName(",
    "func commandOptionKRearrangesGridByKind(",
    "func commandOptionKSortsOpenFolderByKind(",
    "func commandOptionGRearrangesGridByCategory(",
    "func commandOptionGSortsOpenFolderByCategory(",
    "func commandOptionBTogglesBrowseAxis(",
    "func commandOptionUUngroupsAllFolders(",
    "func commandShiftURestoresAllHiddenApplications(",
    "func commandRReloadsCatalog(",
    "func commandShiftHHidesFocusedApp(",
    "func commandShiftReturnRevealsSelection(",
    "func searchRevealShortcutMatches(",
    "func gridTileCommandReturnReveals(",
    "func commandUpClosesOpenFolder(",
    "func commandDownOpensFocusedFolder(",
    "func commandOptionVerticalMovesFoldersToEdge(",
    "func commandOptionHorizontalNudgesFocusedEntry(",
    "func commandOptionShiftHorizontalMovesFocusedEntryToAdjacentPage(",
    "func commandOptionHorizontalNudgesFocusedFolderMember(",
    "func commandOptionVerticalNudgesFocusedFolderMember(",
):
    need(gate in layout, f"existing gate missing: {gate}")
    call = gate[len("func "):]
    need(call in registry, f"registry does not wrap {call}")

# Direct still dispatches the first wave in the same relative order.
# Call sites in performKeyEquivalent, not the later helper declarations.
start = direct.index("override func performKeyEquivalent(with event: NSEvent) -> Bool {")
end = direct.index("override func keyDown(", start)
dispatch = direct[start:end]
handlers = [
    "undoKeyboardLayoutChange(",
    "sortFocusedFolderByNameFromCommandOption(",
    "sortOpenFolderByNameFromCommandOption(",
    "sortFocusedFolderByColorFromCommandOption(",
    "sortOpenFolderByColorFromCommandOption(",
    "rearrangeGridByNameFromCommandOption(",
    "rearrangeGridByKindFromCommandOption(",
    "sortOpenFolderByKindFromCommandOption(",
    "rearrangeGridByCategoryFromCommandOption(",
    "sortOpenFolderByCategoryFromCommandOption(",
    "toggleBrowseAxisFromCommandOptionB(",
    "ungroupAllFoldersFromCommandOptionU(",
    "removeFromOpenFolderWithCommandDelete(",
    "dissolveFocusedFolderWithCommandDelete(",
    "uninstallFocusedAppFromCommandShiftDelete(",
    "nudgeFolderMemberSelectionFromCommandOptionVertical(",
    "nudgeFocusedFolderMemberFromCommandOptionVertical(",
    "moveFoldersToEdgeFromCommandOptionVertical(",
    "moveTopLevelSelectionToAdjacentPageFromCommandOptionShiftHorizontal(",
    "moveFocusedEntryToAdjacentPageFromCommandOptionShiftHorizontal(",
    "nudgeFolderMemberSelectionFromCommandOptionHorizontal(",
    "nudgeFocusedFolderMemberFromCommandOptionHorizontal(",
    "nudgeTopLevelSelectionFromCommandOptionHorizontal(",
    "nudgeFocusedEntryFromCommandOptionHorizontal(",
]
positions = []
for name in handlers:
    idx = dispatch.find(name)
    need(idx >= 0, f"performKeyEquivalent no longer calls {name}")
    positions.append(idx)
need(positions == sorted(positions), "performKeyEquivalent first-wave try-order drifted")

need(
    "func testRegisteredKeyboardCommandsAreUniqueForTheSameChordAndContext" in tests,
    "uniqueness test missing",
)

# Direct computes flags / editingText once for the whole method.
flags_lets = [
    line
    for line in dispatch.splitlines()
    if "let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])" in line
]
edit_lets = [
    line
    for line in dispatch.splitlines()
    if "let editingText = firstResponder is NSTextView" in line
]
need(len(flags_lets) == 1, f"performKeyEquivalent should compute flags once, found {len(flags_lets)}")
need(len(edit_lets) == 1, f"performKeyEquivalent should compute editingText once, found {len(edit_lets)}")
need("KEYBOARD-COMMAND-REGISTRY-01" in dispatch, "flags-once comment missing from performKeyEquivalent")

need("func keyboardProbe(" in direct, "RootView keyboardProbe helper missing")

# ⌘F, ⌘W, ⌘C, ⌘A, and ⌘⇧A dispatch through resolve, then the original handlers.
# ⌘A still returns super when a text field or folder title editor is active.
# The deviceIndependentFlagsMask == .command check stays, so caps lock does
# not newly enable these chords.
f_block_start = dispatch.find("// LAUNCHER-COMMAND-F-SEARCH-01")
w_block_start = dispatch.find("// LAUNCHER-COMMAND-W-DISMISS-01")
c_block_start = dispatch.find("// LAUNCHER-COMMAND-C-COPY-01")
a_block_start = dispatch.find('event.charactersIgnoringModifiers?.lowercased() == "a"')
shift_a_start = dispatch.find("// GRID-COMMAND-SHIFT-A-SELECT-ALL-01")
z_start_check = dispatch.find("// GRID-COMMAND-Z-UNDO-01")
need(
    0 <= f_block_start < w_block_start < c_block_start < a_block_start < z_start_check < shift_a_start,
    "early shortcut order drifted",
)
f_block = dispatch[f_block_start:w_block_start]
w_block = dispatch[w_block_start:c_block_start]
c_block = dispatch[c_block_start:a_block_start]
a_block = dispatch[a_block_start:z_start_check]
shift_a_block = dispatch[shift_a_start:dispatch.find("// FOLDER-COMMAND-SHIFT-M-MOVE-01", shift_a_start)]
need("resolveKeyboardCommand(" in f_block, "⌘F must resolve through the registry")
need(".focusSearch" in f_block, "⌘F must switch on .focusSearch")
need("searchHandler?()" in f_block, "⌘F must still call searchHandler")
need("resolveKeyboardCommand(" in w_block, "⌘W must resolve through the registry")
need(".dismissLauncher" in w_block, "⌘W must switch on .dismissLauncher")
need("dismissHandler?()" in w_block, "⌘W must still call dismissHandler")
need("resolveKeyboardCommand(" in c_block, "⌘C must resolve through the registry")
need(".copyFocusedApp" in c_block, "⌘C must switch on .copyFocusedApp")
need("copyFocusedAppFileURL()" in c_block, "⌘C must still call the original copy helper")
need("resolveKeyboardCommand(" in a_block, "⌘A must resolve through the registry")
need(".selectAllOnPage" in a_block, "⌘A must switch on .selectAllOnPage")
need("selectAllHandler?()" in a_block, "⌘A must still call selectAllHandler")
need("firstResponder is NSTextView" in a_block, "⌘A must still yield to a text view")
need("firstResponder is NSTextField" in a_block, "⌘A must still yield to a text field")
need("folderTitleFieldEditorIsActive()" in a_block, "⌘A must still yield to folder title editing")
need("return super.performKeyEquivalent(with: event)" in a_block, "⌘A must still return super in a text field")
need("resolveKeyboardCommand(" in shift_a_block, "⌘⇧A must resolve through the registry")
need(".selectEveryTopLevelEntry" in shift_a_block, "⌘⇧A must switch on .selectEveryTopLevelEntry")
need("selectEveryTopLevelEntryFromCommandShiftA(" in shift_a_block, "⌘⇧A must still call the original handler")
need(".deviceIndependentFlagsMask) == .command" in f_block, "⌘F must keep the device-independent command-only check")
need(".deviceIndependentFlagsMask) == .command" in w_block, "⌘W must keep the device-independent command-only check")
need(".deviceIndependentFlagsMask) == .command" in c_block, "⌘C must keep the device-independent command-only check")

# ⌘Z and the ⌘⌫ series dispatch through resolve, then the original handlers.
# Call sites stay in the existing performKeyEquivalent order.
z_start = dispatch.find("// GRID-COMMAND-Z-UNDO-01")
z_end = dispatch.find("// GRID-COMMAND-SHIFT-A-SELECT-ALL-01", z_start)
need(z_start >= 0 and z_end > z_start, "⌘Z dispatch block missing")
z_block = dispatch[z_start:z_end]
need("resolveKeyboardCommand(" in z_block, "⌘Z must resolve through the registry")
need(".undoLayout" in z_block, "⌘Z must switch on .undoLayout")
need("undoKeyboardLayoutChange(" in z_block, "⌘Z must still call the original handler")

delete_start = dispatch.find("// FOLDER-COMMAND-DELETE-REMOVE-01")
delete_end = dispatch.find("if event.keyCode == 36 || event.keyCode == 76 {", delete_start)
need(delete_start >= 0 and delete_end > delete_start, "⌘⌫ dispatch block missing")
delete_block = dispatch[delete_start:delete_end]
need("resolveKeyboardCommand(" in delete_block, "⌘⌫ must resolve through the registry")
need("case .removeFromOpenFolder:" in delete_block, "⌘⌫ must switch on .removeFromOpenFolder")
need("case .dissolveClosedFolder:" in delete_block, "⌘⌫ must switch on .dissolveClosedFolder")
need("case .uninstallApp:" in delete_block, "⌘⇧⌫ must switch on .uninstallApp")
need("removeFromOpenFolderWithCommandDelete(" in delete_block, "remove must still call the original handler")
need("dissolveFocusedFolderWithCommandDelete(" in delete_block, "dissolve must still call the original handler")
need("uninstallFocusedAppFromCommandShiftDelete(" in delete_block, "uninstall must still call the original handler")

# Option letters and arrows also resolve, then call the original handlers.
# ⌘⇧C stays between option-G and option-B. ⌘⇧ arrow edges stay between
# the folder-member and top-level option nudges.
option_n = dispatch.find("case .optionNSortsFocusedFolder:")
option_u = dispatch.find("ungroupAllFoldersFromCommandOptionU(")
# Include the resolve call that sits just above the first case.
letters_from = dispatch.rfind("resolveKeyboardCommand(", 0, option_n if option_n >= 0 else 0)
need(option_n >= 0 and option_u > option_n and letters_from >= 0, "option letter dispatch block missing")
letters = dispatch[letters_from:option_u]
need("resolveKeyboardCommand(" in letters, "option letters must resolve through the registry")
for case in (
    "case .optionNSortsFocusedFolder:",
    "case .optionNSortsOpenFolder:",
    "case .optionCSortsFocusedFolder:",
    "case .optionCSortsOpenFolder:",
    "case .optionRRearrangesGridByName:",
    "case .optionKRearrangesGridByKind:",
    "case .optionKSortsOpenFolderByKind:",
    "case .optionGRearrangesGridByCategory:",
    "case .optionGSortsOpenFolderByCategory:",
    "case .optionBTogglesBrowseAxis:",
    "case .optionUUngroupsAllFolders:",
):
    need(case in letters, f"option letter switch missing {case}")
shift_c = dispatch.find("rearrangeGridByColorFromCommandShift(")
b_case = dispatch.find("case .optionBTogglesBrowseAxis:")
g_case = dispatch.find("case .optionGSortsOpenFolderByCategory:")
need(shift_c > g_case > 0, "⌘⇧C must stay after option-G")
need(b_case > shift_c, "⌘⇧C must stay before option-B")

vertical = dispatch[
    dispatch.find("// FOLDER-COMMAND-OPTION-VERTICAL-EDGE-01") : dispatch.find("// FOLDER-COMMAND-UP-CLOSE-01")
]
need("resolveKeyboardCommand(" in vertical, "option vertical must resolve through the registry")
need("case .optionVerticalNudgesFocusedFolderMember:" in vertical, "option vertical member case missing")
need("case .optionVerticalMovesFoldersToEdge:" in vertical, "option vertical folders-to-edge case missing")
need(
    vertical.find("nudgeFolderMemberSelectionFromCommandOptionVertical(")
    < vertical.find("nudgeFocusedFolderMemberFromCommandOptionVertical(")
    < vertical.find("moveFoldersToEdgeFromCommandOptionHorizontal(")
    if False
    else vertical.find("nudgeFolderMemberSelectionFromCommandOptionVertical(")
    < vertical.find("nudgeFocusedFolderMemberFromCommandOptionVertical(")
    < vertical.find("moveFoldersToEdgeFromCommandOptionVertical("),
    "option vertical handler order drifted",
)

horizontal = dispatch[
    dispatch.find("// GRID-COMMAND-OPTION-HORIZONTAL-NUDGE-01") : dispatch.find("// KEYBOARD-COMMAND-ARROW-PAGING-01")
]
need("resolveKeyboardCommand(" in horizontal, "option horizontal must resolve through the registry")
need(
    "case .optionShiftHorizontalMovesFocusedEntryToAdjacentPage:" in horizontal,
    "option-shift page-move case missing",
)
need("case .optionHorizontalNudgesFocusedFolderMember:" in horizontal, "option folder-member nudge case missing")
need("case .optionHorizontalNudgesFocusedEntry:" in horizontal, "option top-level nudge case missing")
need(
    horizontal.find("nudgeFocusedFolderMemberFromCommandOptionHorizontal(")
    < horizontal.find("moveFolderMemberSelectionToEdgeFromCommandShiftHorizontal(")
    < horizontal.find("nudgeTopLevelSelectionFromCommandOptionHorizontal("),
    "⌘⇧ folder-member edge must stay between option folder and top-level nudges",
)


need(
    "func testKeyboardCommandRegistryAllowMatrixForSearchRenameAndOpenFolder" in tests,
    "allow-matrix test missing",
)
need("KEYBOARD-COMMAND-REGISTRY-01" in tests, "test product id missing")

# ⌘⇧M / ⌘⇧N / ⌘⇧C and ⌘⇧ edges resolve, then the original handlers.
m_block = dispatch[dispatch.find("// FOLDER-COMMAND-SHIFT-M-MOVE-01"):dispatch.find("// FOLDER-COMMAND-SHIFT-N-01")]
n_block = dispatch[dispatch.find("// FOLDER-COMMAND-SHIFT-N-01"):dispatch.find("case .optionNSortsFocusedFolder:")]
need("resolveKeyboardCommand(" in m_block, "⌘⇧M must resolve through the registry")
need(".shiftMMovesSelectionIntoFolder" in m_block, "⌘⇧M must switch on .shiftMMovesSelectionIntoFolder")
need("moveSelectionIntoFolderFromCommandShiftM(" in m_block, "⌘⇧M must still call the original handler")
need("resolveKeyboardCommand(" in n_block, "⌘⇧N must resolve through the registry")
need(".shiftNCreatesFolder" in n_block, "⌘⇧N must switch on .shiftNCreatesFolder")
need("createFolderFromSelectionShortcut(" in n_block, "⌘⇧N must still call the original handler")
need(".shiftCRearrangesGridByColor" in dispatch, "⌘⇧C must switch on .shiftCRearrangesGridByColor")
need("rearrangeGridByColorFromCommandShift(" in dispatch, "⌘⇧C must still call the original handler")
need("case .shiftVerticalMovesFocusedFolderMember:" in dispatch, "⌘⇧ vertical folder-member case missing")
need("case .shiftVerticalSelectionEdge:" in dispatch, "⌘⇧ vertical selection case missing")
need(".shiftHorizontalMovesFocusedFolderMember" in dispatch, "⌘⇧ horizontal folder-member must resolve")
need(".shiftHorizontalMovesFocusedEntry" in dispatch, "⌘⇧ horizontal top-level must resolve")
need(
    "moveFolderMemberSelectionToEdgeFromCommandShiftHorizontal(" in dispatch
    and "moveFocusedFolderMemberToEdgeFromCommandShiftHorizontal(" in dispatch,
    "⌘⇧ folder-member edge must still call both handlers",
)
need(
    "moveTopLevelSelectionToEdgeFromCommandShiftHorizontal(" in dispatch
    and "moveFocusedEntryToEdgeFromCommandShiftHorizontal(" in dispatch,
    "⌘⇧ top-level edge must still call both handlers",
)

# ⌘⇧U / ⌘R / ⌘⇧H resolve, then the original handlers, still after option-U
# and before command-delete.
u_start = dispatch.find("// APP-COMMAND-SHIFT-U-UNHIDE-01")
u_end = dispatch.find("// FOLDER-COMMAND-DELETE-REMOVE-01")
need(u_start >= 0 and u_end > u_start, "⌘⇧U / ⌘R / ⌘⇧H dispatch block missing")
u_block = dispatch[u_start:u_end]
need("optionCommand == .shiftURestoresAllHidden" in u_block, "⌘⇧U must resolve through the registry")
need("restoreAllHiddenFromCommandShiftU(" in u_block, "⌘⇧U must still call the original handler")
need("optionCommand == .reloadCatalog" in u_block, "⌘R must resolve through the registry")
need("reloadCatalogFromCommandR(" in u_block, "⌘R must still call the original handler")
need("optionCommand == .shiftHHidesFocusedApp" in u_block, "⌘⇧H must resolve through the registry")
need("hideFocusedAppFromCommandShiftH(" in u_block, "⌘⇧H must still call the original handler")
need(
    dispatch.find("ungroupAllFoldersFromCommandOptionU(")
    < dispatch.find("restoreAllHiddenFromCommandShiftU(")
    < dispatch.find("reloadCatalogFromCommandR(")
    < dispatch.find("hideFocusedAppFromCommandShiftH(")
    < dispatch.find("// FOLDER-COMMAND-DELETE-REMOVE-01"),
    "⌘⇧U / ⌘R / ⌘⇧H must stay after option-U and before command-delete",
)

# ⌘, / ⌘⇧↩ / ⌘↑ / ⌘↓ resolve, then the original handlers, in place.
comma_block = dispatch[:dispatch.find("// LAUNCHER-COMMAND-F-SEARCH-01")]
need("resolveKeyboardCommand(" in comma_block, "⌘, must resolve through the registry")
need(".openSettings" in comma_block, "⌘, must switch on .openSettings")
need("settingsHandler?()" in comma_block, "⌘, must still call settingsHandler")
need(".deviceIndependentFlagsMask) == .command" in comma_block, "⌘, must keep the device-independent command-only check")

ret_block = dispatch[dispatch.find("// GRID-COMMAND-SHIFT-RETURN-REVEAL-01"):dispatch.find("// SELECTION-COMMAND-SHIFT-VERTICAL-EDGE-01")]
need(bool(ret_block.strip()), "⌘⇧↩ dispatch block missing")
need("resolveKeyboardCommand(" in ret_block, "⌘⇧↩ must resolve through the registry")
need(".shiftReturnRevealsSelection" in ret_block, "⌘⇧↩ must switch on .shiftReturnRevealsSelection")
need("revealSelectionInFinderFromCommandShiftReturn(" in ret_block, "⌘⇧↩ must still call the original handler")
need("searchRevealHandler?" in ret_block, "plain ⌘↩ search reveal must stay after ⌘⇧↩")
need("revealFocusedTileInFinder(" in ret_block, "plain ⌘↩ tile reveal must stay after ⌘⇧↩")
need("case .revealSearchHit:" in ret_block, "plain ⌘↩ search must switch on .revealSearchHit")
need("case .revealFocusedTile:" in ret_block, "plain ⌘↩ tile must switch on .revealFocusedTile")
need(
    ret_block.find("case .shiftReturnRevealsSelection:")
    < ret_block.find("case .revealSearchHit:")
    < ret_block.find("case .revealFocusedTile:"),
    "plain ⌘↩ must stay after ⌘⇧↩, and search must stay before the focused tile",
)

up_block = dispatch[dispatch.find("// FOLDER-COMMAND-UP-CLOSE-01"):dispatch.find("// GRID-COMMAND-OPTION-HORIZONTAL-NUDGE-01")]
need(bool(up_block.strip()), "⌘↑ / ⌘↓ dispatch block missing")
need("resolveKeyboardCommand(" in up_block, "⌘↑ / ⌘↓ must resolve through the registry")
need("case .commandUpClosesOpenFolder:" in up_block, "⌘↑ must switch on .commandUpClosesOpenFolder")
need("case .commandDownOpensFocusedFolder:" in up_block, "⌘↓ must switch on .commandDownOpensFocusedFolder")
need("closeFolderFromCommandUp(" in up_block, "⌘↑ must still call the original handler")
need("openFocusedFolderFromCommandDown(" in up_block, "⌘↓ must still call the original handler")
need(
    dispatch.find("// FOLDER-COMMAND-OPTION-VERTICAL-EDGE-01")
    < dispatch.find("// FOLDER-COMMAND-UP-CLOSE-01")
    < dispatch.find("// GRID-COMMAND-OPTION-HORIZONTAL-NUDGE-01"),
    "⌘↑ / ⌘↓ must stay after option vertical and before option horizontal",
)
need(
    dispatch.find("// FOLDER-COMMAND-DELETE-REMOVE-01")
    < dispatch.find("// GRID-COMMAND-SHIFT-RETURN-REVEAL-01")
    < dispatch.find("// SELECTION-COMMAND-SHIFT-VERTICAL-EDGE-01"),
    "⌘⇧↩ must stay after command-delete and before shift-vertical edges",
)
need("func testCommandCommaOpensSettings" in tests, "⌘, gate test missing")

# ⌘ arrow paging resolves, then the original handler, still last in performKeyEquivalent.
need("CommandArrowPaging.pageTurnDirection(" in registry, "registry does not wrap CommandArrowPaging.pageTurnDirection")
paging_start = dispatch.find("// KEYBOARD-COMMAND-ARROW-PAGING-01")
need(paging_start >= 0, "arrow paging dispatch missing")
paging_block = dispatch[paging_start:]
need("resolveKeyboardCommand(" in paging_block, "arrow paging must resolve through the registry")
need(".commandArrowPaging" in paging_block, "arrow paging must switch on .commandArrowPaging")
need("handleCommandArrowPaging(event)" in paging_block, "arrow paging must still call the original handler")
need(
    dispatch.find("// FOLDER-COMMAND-UP-CLOSE-01")
    < dispatch.find("// GRID-COMMAND-OPTION-HORIZONTAL-NUDGE-01")
    < dispatch.find("// KEYBOARD-COMMAND-ARROW-PAGING-01"),
    "arrow paging must stay after folder close/open and option horizontal",
)
need("movePage(" not in paging_block, "performKeyEquivalent must not call movePage directly")

# Esc / Space resolve in keyDown / sendEvent, then the original handlers.
need("func commandEscapeCancelsOrDismisses(" in layout, "existing gate missing: commandEscapeCancelsOrDismisses")
need("func spaceActivatesFocusedItem(" in layout, "existing gate missing: spaceActivatesFocusedItem")
need("commandEscapeCancelsOrDismisses(" in registry, "registry does not wrap commandEscapeCancelsOrDismisses")
need("spaceActivatesFocusedItem(" in registry, "registry does not wrap spaceActivatesFocusedItem")
need("func testCommandEscapeCancelsOrDismisses" in tests, "Escape gate test missing")
need("func testSpaceActivatesFocusedItem" in tests, "Space gate test missing")

send_start = direct.find("override func sendEvent(_ event: NSEvent)")
send_end = direct.find("private static func shouldDropInactivePointerEvent", send_start)
need(send_start >= 0 and send_end > send_start, "sendEvent block missing")
send = direct[send_start:send_end]
need("keyCode == 53" in send, "sendEvent must still watch Escape")
need("inputMethodHasMarkedText()" in send, "Escape must still deliver marked text first")
need("resolveKeyboardCommand(" in send, "Escape must resolve through the registry")
need(".escapeCancels" in send, "Escape must switch on .escapeCancels")
need("handleEscape()" in send, "Escape must still call the original handler")
need(
    send.find("inputMethodHasMarkedText()")
    < send.find("resolveKeyboardCommand(")
    < send.find("handleEscape()"),
    "marked text must stay before resolve, and resolve before handleEscape",
)

tile_start = direct.find("override func keyDown(with event: NSEvent) {", direct.find("final class AppGridTileView"))
# AppGridTileView keyDown: first keyDown after the class might be it; use revealInFinderFromCommandReturn as anchor
tile_start = direct.find("func revealInFinderFromCommandReturn(")
tile_end = direct.find("override func insertTab(", tile_start)
need(tile_start >= 0 and tile_end > tile_start, "tile keyDown block missing")
tile = direct[tile_start:tile_end]
need("resolveKeyboardCommand(" in tile, "Space must resolve through the registry")
need(".spaceActivatesFocusedItem" in tile, "Space must switch on .spaceActivatesFocusedItem")
need("onActivate?()" in tile, "Space must still call the original handler")
need("event.keyCode == 36 || event.keyCode == 76" in tile, "plain Return must stay on the open path")
need("showPage(" not in send and "transitionToPage(" not in send and "completePageTransition(" not in send,
     "Escape dispatch must not call the paging functions")
need("showPage(" not in tile and "transitionToPage(" not in tile and "completePageTransition(" not in tile,
     "Space dispatch must not call the paging functions")

# Plain / Shift arrows resolve in tile keyDown, then the original handlers.
# A declined walk / extend still falls through to the existing onPage path.
need("func arrowExtendsSelection(" in layout, "existing gate missing: arrowExtendsSelection")
need("func arrowWalksGrid(" in layout, "existing gate missing: arrowWalksGrid")
need("arrowExtendsSelection(" in registry, "registry does not wrap arrowExtendsSelection")
need("arrowWalksGrid(" in registry, "registry does not wrap arrowWalksGrid")
need("func testArrowExtendsSelectionAndWalksGrid" in tests, "arrow gate test missing")
need(
    "case .arrowExtendsSelection:" in tile
    and "onGridKeyboardShiftStep?(direction)" in tile,
    "Shift-arrow must resolve then call the original handler",
)
need(
    "case .arrowWalksGrid:" in tile
    and "onGridKeyboardStep?(direction)" in tile,
    "plain arrows must resolve then call the original handler",
)
need(
    tile.find("case .arrowExtendsSelection:")
    < tile.find("case .arrowWalksGrid:")
    < tile.find("onPage?(-1)"),
    "extend must stay before walk, and both must stay before paging fallback",
)
need("showPage(" not in tile and "transitionToPage(" not in tile and "completePageTransition(" not in tile and "movePage(" not in tile,
     "tile arrow dispatch must not call the paging functions")

# Home / End and Shift-Home / Shift-End resolve, then the original handler.
need("func commandShiftHomeEndExtendsSelection(" in layout, "existing gate missing: commandShiftHomeEndExtendsSelection")
need("func commandHomeEndJumpsInGrid(" in layout, "existing gate missing: commandHomeEndJumpsInGrid")
need("commandShiftHomeEndExtendsSelection(" in registry, "registry does not wrap commandShiftHomeEndExtendsSelection")
need("commandHomeEndJumpsInGrid(" in registry, "registry does not wrap commandHomeEndJumpsInGrid")
need("gridKeyboardHomeEndSlot(" in layout[layout.find("func commandHomeEndJumpsInGrid("):layout.find("func commandHomeEndJumpsInGrid(")+600],
     "Home/End registry gate must wrap gridKeyboardHomeEndSlot")
need("func testCommandHomeEndAndShiftHomeEndChords" in tests, "Home/End gate test missing")
need(".shiftHomeEndExtendsSelection" in tile, "Shift-Home/End must switch on .shiftHomeEndExtendsSelection")
need(".homeEndJumpsInGrid" in tile, "Home/End must switch on .homeEndJumpsInGrid")
need("onGridKeyboardHomeEnd?(" in tile, "Home/End must still call the original handler")
need(
    tile.find("case .arrowWalksGrid:")
    < tile.find(".shiftHomeEndExtendsSelection")
    < tile.find("onGridKeyboardHomeEnd?(")
    < tile.find("onRenameFocusedFolderFromF2?(")
    < tile.find("onPage?(-1)"),
    "Home/End must stay after arrow walks, before F2 and paging fallback",
)
need("showPage(" not in tile and "transitionToPage(" not in tile and "completePageTransition(" not in tile and "movePage(" not in tile,
     "Home/End dispatch must not call the paging functions")

# F2 folder rename then app alias, still the original combined handler.
need("func f2RenamesFocusedClosedFolder(" in layout, "existing gate missing: f2RenamesFocusedClosedFolder")
need("func f2RenamesFocusedAppAlias(" in layout, "existing gate missing: f2RenamesFocusedAppAlias")
need("f2RenamesFocusedClosedFolder(" in registry, "registry does not wrap f2RenamesFocusedClosedFolder")
need("f2RenamesFocusedAppAlias(" in registry, "registry does not wrap f2RenamesFocusedAppAlias")
need("func testF2RenamesFocusedFolderThenAppAliasChords" in tests, "F2 registry gate test missing")
need(".f2RenamesFocusedClosedFolder" in tile, "F2 folder must switch on .f2RenamesFocusedClosedFolder")
need(".f2RenamesFocusedAppAlias" in tile, "F2 app alias must switch on .f2RenamesFocusedAppAlias")
need("onRenameFocusedFolderFromF2?(" in tile, "F2 must still call the original handler")
need(
    tile.find("onGridKeyboardHomeEnd?(")
    < tile.find(".f2RenamesFocusedClosedFolder")
    < tile.find(".f2RenamesFocusedAppAlias")
    < tile.find("onRenameFocusedFolderFromF2?(")
    < tile.find("onPage?(-1)"),
    "F2 must stay after Home/End, before paging fallback, folder first",
)
need("showPage(" not in tile and "transitionToPage(" not in tile and "completePageTransition(" not in tile and "movePage(" not in tile,
     "F2 dispatch must not call the paging functions")

# Page Up/Down: scroll an open list first, then page the grid.
need("func commandPageUpDownScrollsOpenList(" in layout, "existing gate missing: commandPageUpDownScrollsOpenList")
need("func commandPageUpDownPagesGrid(" in layout, "existing gate missing: commandPageUpDownPagesGrid")
need("commandPageUpDownScrollsOpenList(" in registry, "registry does not wrap commandPageUpDownScrollsOpenList")
need("commandPageUpDownPagesGrid(" in registry, "registry does not wrap commandPageUpDownPagesGrid")
need("verticalPageKeyTarget(" in layout[layout.find("func commandPageUpDownScrollsOpenList("):layout.find("func commandPageUpDownScrollsOpenList(")+700],
     "Page Up/Down scroll gate must wrap verticalPageKeyTarget")
need("verticalPageKeyTarget(" in layout[layout.find("func commandPageUpDownPagesGrid("):layout.find("func commandPageUpDownPagesGrid(")+700],
     "Page Up/Down grid gate must wrap verticalPageKeyTarget")
need("func testPageUpDownScrollsOpenListOrPagesGrid" in tests, "Page Up/Down registry gate test missing")
need(".pageUpDownScrollsOpenList" in tile, "Page Up/Down must switch on .pageUpDownScrollsOpenList")
need(".pageUpDownPagesGrid" in tile, "Page Up/Down must switch on .pageUpDownPagesGrid")
need("launcherConsumesVerticalSearchPage(" in tile, "Page Up/Down must still try vertical list scroll first")
need("onPage?(-1)" in tile and "onPage?(1)" in tile, "Page Up/Down must still call the original paging handler")
need(
    tile.find("onRenameFocusedFolderFromF2?(")
    < tile.find(".pageUpDownScrollsOpenList")
    < tile.find(".pageUpDownPagesGrid")
    < tile.find("launcherConsumesVerticalSearchPage(")
    < tile.find("onPage?(-1)"),
    "Page Up/Down must stay after F2, try vertical scroll, then the original onPage path",
)
need("showPage(" not in tile and "transitionToPage(" not in tile and "completePageTransition(" not in tile and "movePage(" not in tile,
     "Page Up/Down dispatch must not call the paging functions")

# Root view, page dots, chrome, and paging-arrow buttons also resolve Page Up/Down.
# Left/Right stay on their existing paths. Type-to-search stays after those paths.
root_start = direct.find("override func keyDown(with event: NSEvent) {\n        guard !LauncherLayout.shouldConsumeLauncherKeyEquivalent")
root_search = direct.find("if beginSearch(with: event) { return }", root_start)
root_key = direct[root_start:root_search + len("if beginSearch(with: event) { return }")]
need(".pageUpDownScrollsOpenList" in root_key, "root Page Up/Down must switch on .pageUpDownScrollsOpenList")
need(".pageUpDownPagesGrid" in root_key, "root Page Up/Down must switch on .pageUpDownPagesGrid")
need("launcherConsumesVerticalSearchPage(" in root_key, "root Page Up/Down must still try vertical list scroll first")
need("movePage(by: -1)" in root_key and "movePage(by: 1)" in root_key, "root Page Up/Down must still call movePage")
need(root_key.find(".pageUpDownScrollsOpenList") < root_key.find("if beginSearch(with: event) { return }"),
     "root type-to-search must stay after Page Up/Down")
need("case 123, 116:" in root_key and "case 124, 121:" in root_key,
     "root Left/Right must stay on the existing movePage path")
need("showPage(" not in root_key and "transitionToPage(" not in root_key and "completePageTransition(" not in root_key,
     "root Page Up/Down dispatch must not call the paging functions")

def chrome_keydown(class_name, start_marker, end_marker, label, require_optional_on_page):
    # Match inside the named top-level class, never the first shared comment
    # elsewhere in the file. Missing declarations/markers must fail closed.
    declaration = re.search(r"(?m)^(?:private )?final class " + re.escape(class_name) + r":", direct)
    need(declaration is not None, f"{label} class missing")
    class_end = direct.find("\n}", declaration.end()) if declaration else -1
    class_source = direct[declaration.start():class_end + 2] if declaration and class_end >= 0 else ""
    i = class_source.find(start_marker)
    end = class_source.find(end_marker, i) if i >= 0 else -1
    need(i >= 0 and end >= 0, f"{label} keyDown markers missing")
    chunk = class_source[i:end] if i >= 0 and end >= 0 else ""
    need(".pageUpDownScrollsOpenList" in chunk, f"{label} must switch on .pageUpDownScrollsOpenList")
    need(".pageUpDownPagesGrid" in chunk, f"{label} must switch on .pageUpDownPagesGrid")
    need("launcherConsumesVerticalSearchPage(" in chunk, f"{label} must still try vertical list scroll first")
    if require_optional_on_page:
        need("onPage?(" in chunk, f"{label} must still call the original onPage handler")
    else:
        need("onPage(" in chunk, f"{label} must still call the original onPage handler")
    need("launcherPagingDirection(for: event)" in chunk, f"{label} Left/Right must stay on launcherPagingDirection")
    need("showPage(" not in chunk and "transitionToPage(" not in chunk and "completePageTransition(" not in chunk and "movePage(" not in chunk,
         f"{label} Page Up/Down dispatch must not call the paging functions")

chrome_keydown(
    "PageEllipsisButton",
    "        // Same keys as a page dot. Space still presses this jump.",
    "        if let onDelete, let deletion = launcherSearchDeletion(for: event), onDelete(deletion) { return }",
    "page ellipsis",
    True,
)
chrome_keydown(
    "PageDotButton",
    "        // Same keys as the grid tiles. Focus can sit on a dot after Tab;",
    "        if let onDelete, let deletion = launcherSearchDeletion(for: event), onDelete(deletion) { return }",
    "page dot",
    True,
)
chrome_keydown(
    "LauncherChromeButton",
    "        // Focus can sit on Settings after Tab. Left/Right still turn the page",
    "        if let onDelete, let deletion = launcherSearchDeletion(for: event), onDelete(deletion) { return }",
    "chrome button",
    False,
)
chrome_keydown(
    "PagingArrowButton",
    "        // KEYBOARD-COMMAND-REGISTRY-01: resolve Page Up/Down, then the\n        // original handlers. Left/Right stay on launcherPagingDirection.\n        switch LauncherLayout.resolveKeyboardCommand(launcherKeyboardProbe(from: event, in: self)) {",
    "        if let onDelete, let deletion = launcherSearchDeletion(for: event), onDelete(deletion) { return }",
    "paging arrow button",
    True,
)
need("func launcherKeyboardProbe(" in direct, "chrome/root probe helper missing")

if failures:
    print("FAIL: keyboard command registry")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: keyboard command registry")

#!/usr/bin/env python3
"""Guard: blank-area context menu 设置… / 整理布局 / 退出 (LaunchOS parity; never touches 切页)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
strings = (root / "Resources/Localizable.xcstrings").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


def body(text, start, end):
    i = text.index(start)
    return text[i : text.index(end, i + len(start))]


pol = body(core, "public static func showsBlankAreaContextMenu(", "public static func ungroupAllFolders(")
need("!isSearching && !folderOpen && !isDragging && !isPaging && !isDismissing" in pol, "menu policy must block all busy states")
ung = body(core, "public static func ungroupAllFolders(", "public static func movingFoldersToEdge(")
need("dissolveFolder(id, in: next)" in ung, "ungroup-all must reuse the in-place dissolve rule")
mov = body(core, "public static func movingFoldersToEdge(", "public static func topLevelFolderCount(")
need("atStart ? folders + apps : apps + folders" in mov, "folders-to-edge must be a stable partition")
need("testBlankAreaMenuReorganizeActions" in tests, "Core test missing")

rmd = body(direct, "override func rightMouseDown(with event: NSEvent) {\n        guard let menu = blankAreaContextMenu(", "private func blankAreaContextMenu(")
need("super.rightMouseDown(with: event)" in rmd, "non-blank clicks must fall through")
need("noteIconContextMenuTracking(menu)" in rmd and "noteIconContextMenuTracking(nil)" in rmd,
     "menu must be cancellable on dismiss")
menu = body(direct, "private func blankAreaContextMenu(", "@objc private func openSettingsFromBlankAreaMenu()")
need("isPaging: isPageTransitioning || isPagingGesture" in menu, "menu must stay out of in-flight paging")
need("view is AppGridTileView || view is NSControl || view === folderOverlay || view === pageIndicator" in menu,
     "tiles/controls/folder panel/page dots keep their own handling")
need("if isLayoutEditingEnabled {" in menu and "if folderCount > 0 {" in menu, "organize hidden when locked; folder items only with folders")
need("submenu.autoenablesItems = false" in menu, "disabled no-op items need autoenablesItems = false")
rr = body(direct, "private func rearrangeFromBlankAreaMenu(", "@objc private func openSettingsFromBlankAreaMenu()")
need("GridRearrangeConfirmAlert.cancelButtonTitleKey" in rr and "== .alertSecondButtonReturn" in rr, "rearrange confirm cancel-first")
need("_ = window?.makeFirstResponder(self)\n        rearrangeTopLevelGrid(sort: sort)" in rr, "clear focus before rearrange")
need("isPromptingForAlias = true" in rr, "rearrange confirm abandoned on dismiss")
need("testBlankAreaRearrangeWouldChange" in tests, "rearrange Core test missing")
cat = body(direct, "@objc private func rearrangeByCategoryFromBlankAreaMenu()", "@objc private func openSettingsFromBlankAreaMenu()")
need("GridRearrangeConfirmAlert.cancelButtonTitleKey" in cat and "== .alertSecondButtonReturn" in cat, "category confirm cancel-first")
need("_ = window?.makeFirstResponder(self)\n        rearrangeTopLevelGridByCategory()" in cat, "clear focus before category rearrange")
need("isPromptingForAlias = true" in cat, "category confirm abandoned on dismiss")
need("CategoryRearrangeCopy.menuItemAlwaysEnabled" in menu, "category item must not read Info.plist on every right-click")
dt = body(direct, "@objc private func rearrangeByDateFromBlankAreaMenu(", "private func appendHiddenApplicationsSubmenu(")
need("for kind in AppDateRearrangeKind.allCases" in menu and "byDate.representedObject = kind.rawValue" in menu, "date items wired per kind")
need("byDate.isEnabled = true" in menu, "date items must not read Spotlight on every right-click")
need("GridRearrangeConfirmAlert.cancelButtonTitleKey" in dt and "== .alertSecondButtonReturn" in dt, "date confirm cancel-first")
need("_ = window?.makeFirstResponder(self)\n        rearrangeTopLevelGridByDate(kind)" in dt, "clear focus before date rearrange")
need("isPromptingForAlias = true" in dt, "date confirm abandoned on dismiss")
need("testRearrangeTopLevelEntriesByDateNewestFirst" in tests, "date rearrange Core test missing")
acts = body(direct, "private func commitReorganizedLayout(", "private func moveFoldersToEdgeFromMenu(") + \
    body(direct, "private func moveFoldersToEdgeFromMenu(", "\n    }\n")
need("_ = window?.makeFirstResponder(self)" in acts and "commitLayout(next)" in acts,
     "clear tile focus before commit so reload cannot chase an icon to another page")
need("shouldClearSelectionAfterReorganize" in direct, "reorganize commit must clear multi-select")
ua = body(direct, "@objc private func ungroupAllFoldersFromMenu()", "@objc private func moveFoldersToStartFromMenu()")
need("isPromptingForAlias = true" in ua, "confirm alert must be abandoned on dismiss")
need("dissolveConfirmCancelButtonTitle" in ua and "dissolveConfirmDestructiveButtonTitle" in ua
     and ua.find("dissolveConfirmCancelButtonTitle") < ua.find("dissolveConfirmDestructiveButtonTitle")
     and "== .alertSecondButtonReturn" in ua, "ungroup-all confirm must be cancel-first (Return/Esc safe)")
need("ungroupAllFoldersConfirmTitle" in ua, "ungroup-all must use Core title helper")
need('L("解散所有文件夹？")' not in ua, "ungroup-all must not hardcode confirm title")

need("acceptsIconContextMenuAction()" in ua and "acceptsIconContextMenuAction()" in acts, "actions respect dismiss")
hid = body(direct, "private func appendHiddenApplicationsSubmenu(", "@objc private func openSettingsFromBlankAreaMenu()")
need("appendHiddenApplicationsSubmenu(to: menu)" in menu, "hidden-apps submenu wired inside the editing branch")
need("guard !hidden.isEmpty else { return }" in hid, "hidden-apps submenu only when something is hidden")
need("LauncherLayout.blankAreaHiddenAppsMenuEntries(hidden)" in hid, "hidden-apps list capped via Core")
need(hid.count("guard isLayoutEditingEnabled, acceptsIconContextMenuAction()") == 2, "restore actions respect lock + dismiss")
need(hid.count("_ = window?.makeFirstResponder(self)") == 2, "clear focus before restore reload")
need("testBlankAreaHiddenAppsMenuEntriesCapsAndFlagsOverflow" in tests, "hidden-apps Core test missing")

# BLANK-BROWSE-MODE-01: page-flip axis submenu (reuses prefs; no showPage).
need("BlankBrowseModeCopy.menuTitle" in menu, "browse mode submenu")
need("setPageFlipFromBlankAreaMenu" in direct, "browse mode action")
need("onPageFlipDirectionChangeRequested" in direct, "persist callback for browse mode")
prefs = (root / "Sources/Core/LauncherPreferences.swift").read_text()
need("enum BlankBrowseModeCopy" in prefs and 'menuTitleKey = "浏览模式"' in prefs, "BlankBrowseModeCopy")
delegate = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
need("onPageFlipDirectionChangeRequested" in delegate, "delegate wires browse mode")
act = body(direct, "@objc private func setPageFlipFromBlankAreaMenu(", "private func commitReorganizedLayout(")
need("setPageFlipDirection(direction)" in act, "browse action applies axis")
need("onPageFlipDirectionChangeRequested?(direction)" in act, "browse action asks host to persist")
for banned in ("showPage", "movePage", "transitionToPage", "currentPage"):
    need(banned not in act, f"browse mode must not turn pages ({banned})")

need("func commandOptionBTogglesBrowseAxis(" in core, "Core command-option-b browse axis missing")
need("var toggled: LauncherPageFlipDirection" in prefs, "page axis toggle missing")
need("func toggleBrowseAxisFromCommandOptionB(" in direct, "Direct command-option-b browse axis missing")
need("toggleBrowseAxisFromCommandOptionB(" in direct, "panel must ask to toggle the browse axis")
need("testCommandOptionBTogglesTheBrowseAxis" in tests, "Core command-option-b browse axis test missing")
browse_key = body(direct, "func toggleBrowseAxisFromCommandOptionB(", "private func commitReorganizedLayout(")
need("commandOptionBTogglesBrowseAxis(" in browse_key, "browse shortcut must ask Core")
need("pageFlipDirection.toggled" in browse_key, "browse shortcut must swap the axis")
need("setPageFlipDirection(next)" in browse_key, "browse shortcut must apply the axis")
need("onPageFlipDirectionChangeRequested?(next)" in browse_key, "browse shortcut must ask to persist")
for banned in ("showPage", "movePage", "transitionToPage", "currentPage"):
    need(banned not in browse_key, f"browse shortcut must not turn pages ({banned})")

for banned in ("showPage", "focusGridEntry", "PagingCollectionView", "scrollToPage", "currentPage", "playFolderDissolveScatter"):
    need(banned not in rmd + menu + acts + ua + dt, f"blank-area menu must not touch paging ({banned})")

need("func commandOptionRRearrangesGridByName(" in core, "Core command-option-r name arrange missing")
need("func rearrangeGridByNameFromCommandOption(" in direct, "Direct command-option-r name arrange missing")
need("rearrangeGridByNameFromCommandOption(" in direct, "panel must ask to arrange by name")
need("testCommandOptionRRearrangesTheGridByName" in tests, "Core command-option-r test missing")
name_key = body(direct, "func rearrangeGridByNameFromCommandOption(", "func rearrangeGridByKindFromCommandOption(")
need("commandOptionRRearrangesGridByName(" in name_key, "name arrange shortcut must ask Core")
need("rearrangeFromBlankAreaMenu(sort: .byName)" in name_key, "name arrange shortcut must use the blank-area confirm")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in name_key, f"name arrange shortcut must not page ({banned})")
need("func commandOptionKRearrangesGridByKind(" in core, "Core command-option-k kind arrange missing")
need("func rearrangeGridByKindFromCommandOption(" in direct, "Direct command-option-k kind arrange missing")
need("rearrangeGridByKindFromCommandOption(" in direct, "panel must ask to arrange by kind")
need("testCommandOptionKRearrangesTheGridByKind" in tests, "Core command-option-k test missing")
kind_key = body(direct, "func rearrangeGridByKindFromCommandOption(", "func rearrangeGridByCategoryFromCommandOption(")
need("commandOptionKRearrangesGridByKind(" in kind_key, "kind arrange shortcut must ask Core")
need("rearrangeFromBlankAreaMenu(sort: .byKind)" in kind_key, "kind arrange shortcut must use the blank-area confirm")
need("sortingFolderMembersByKind(" in kind_key, "open-folder kind sort must use the member sort")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in kind_key, f"kind arrange shortcut must not page ({banned})")
need("func commandOptionKSortsOpenFolderByKind(" in core, "Core open-folder kind sort gate missing")
need("func sortOpenFolderByKindFromCommandOption(" in direct, "Direct open-folder kind sort missing")
need("sortOpenFolderByKindFromCommandOption(" in direct, "panel must ask to sort the open folder by kind")
need("testCommandOptionKSortsTheOpenFolderByKind" in tests, "Core open-folder kind sort test missing")
open_kind = body(direct, "func sortOpenFolderByKindFromCommandOption(", "func rearrangeGridByCategoryFromCommandOption(")
need("commandOptionKSortsOpenFolderByKind(" in open_kind, "open-folder kind sort must ask Core")
need("sortingFolderMembersByKind(" in open_kind, "open-folder kind sort must reorder members")
need("return true" in open_kind, "open-folder kind sort must consume the key")
need("focusPresentedItem(id:" in open_kind, "open-folder kind sort must follow the member")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in open_kind, f"open-folder kind sort must not page ({banned})")
need("func commandOptionGRearrangesGridByCategory(" in core, "Core command-option-g category arrange missing")
need("func rearrangeGridByCategoryFromCommandOption(" in direct, "Direct command-option-g category arrange missing")
need("rearrangeGridByCategoryFromCommandOption(" in direct, "panel must ask to arrange by category")
need("testCommandOptionGRearrangesTheGridByCategory" in tests, "Core command-option-g test missing")
category_key = body(direct, "func rearrangeGridByCategoryFromCommandOption(", "@objc private func rearrangeByCategoryFromBlankAreaMenu()")
need("commandOptionGRearrangesGridByCategory(" in category_key, "category arrange shortcut must ask Core")
need("rearrangeByCategoryFromBlankAreaMenu()" in category_key, "category arrange shortcut must use the blank-area confirm")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in category_key, f"category arrange shortcut must not page ({banned})")
need("sortingFolderMembersByCategory(" in category_key, "open-folder category sort must reorder members")
need("func commandOptionGSortsOpenFolderByCategory(" in core, "Core open-folder category sort gate missing")
need("func sortOpenFolderByCategoryFromCommandOption(" in direct, "Direct open-folder category sort missing")
need("sortOpenFolderByCategoryFromCommandOption(" in direct, "panel must ask to sort the open folder by category")
need("testCommandOptionGSortsTheOpenFolderByCategory" in tests, "Core open-folder category sort test missing")
open_category = body(direct, "func sortOpenFolderByCategoryFromCommandOption(", "@objc private func rearrangeByCategoryFromBlankAreaMenu()")
need("commandOptionGSortsOpenFolderByCategory(" in open_category, "open-folder category sort must ask Core")
need("sortingFolderMembersByCategory(" in open_category, "open-folder category sort must reorder members")
need("return true" in open_category, "open-folder category sort must consume the key")
need("focusPresentedItem(id:" in open_category, "open-folder category sort must follow the member")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in open_category, f"open-folder category sort must not page ({banned})")
need("func commandShiftCRearrangesGridByColor(" in core, "Core command-shift-c color arrange missing")
need("func rearrangeGridByColorFromCommandShift(" in direct, "Direct command-shift-c color arrange missing")
need("rearrangeGridByColorFromCommandShift(" in direct, "panel must ask to arrange by color")
need("testCommandShiftCRearrangesTheGridByColor" in tests, "Core command-shift-c test missing")
color_key = body(direct, "func rearrangeGridByColorFromCommandShift(", "@objc private func rearrangeByColorFromBlankAreaMenu()")
need("commandShiftCRearrangesGridByColor(" in color_key, "color arrange shortcut must ask Core")
need("rearrangeByColorFromBlankAreaMenu()" in color_key, "color arrange shortcut must use the blank-area confirm")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in color_key, f"color arrange shortcut must not page ({banned})")
need("func commandShiftURestoresAllHiddenApplications(" in core, "Core command-shift-u restore missing")
need("func restoreAllHiddenFromCommandShiftU(" in direct, "Direct command-shift-u restore missing")
need("restoreAllHiddenFromCommandShiftU(" in direct, "panel must ask to restore hidden apps")
need("testCommandShiftURestoresAllHiddenApplications" in tests, "Core command-shift-u test missing")
unhide_key = body(direct, "func restoreAllHiddenFromCommandShiftU(", "@objc private func restoreAllHiddenApplicationsFromBlankAreaMenu()")
need("commandShiftURestoresAllHiddenApplications(" in unhide_key, "restore shortcut must ask Core")
need("restoreAllHiddenApplicationsFromBlankAreaMenu()" in unhide_key, "restore shortcut must use the blank-area action")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in unhide_key, f"restore shortcut must not page ({banned})")

need("func commandOptionUUngroupsAllFolders(" in core, "Core command-option-u ungroup missing")
need("func ungroupAllFoldersFromCommandOptionU(" in direct, "Direct command-option-u ungroup missing")
need("ungroupAllFoldersFromCommandOptionU(" in direct, "panel must ask to ungroup")
need("testCommandOptionUUngroupsAllFolders" in tests, "Core command-option-u ungroup test missing")
ungroup_key = body(direct, "func ungroupAllFoldersFromCommandOptionU(", "@objc private func ungroupAllFoldersFromMenu()")
need("commandOptionUUngroupsAllFolders(" in ungroup_key, "ungroup shortcut must ask Core")
need("ungroupAllFoldersFromMenu()" in ungroup_key, "ungroup shortcut must use the blank-area confirm")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in ungroup_key, f"ungroup shortcut must not page ({banned})")

need("func commandOptionVerticalMovesFoldersToEdge(" in core, "Core command-option folder edge missing")
need("func moveFoldersToEdgeFromCommandOptionVertical(" in direct, "Direct command-option folder edge missing")
need("moveFoldersToEdgeFromCommandOptionVertical(" in direct, "panel must ask to move folders")
need("testCommandOptionVerticalMovesFoldersToTheEdge" in tests, "Core command-option folder edge test missing")
folder_edge = body(direct, "func moveFoldersToEdgeFromCommandOptionVertical(", "@objc private func moveSelectedEntriesToStartFromBlankAreaMenu()")
need("commandOptionVerticalMovesFoldersToEdge(" in folder_edge, "folder edge shortcut must ask Core")
need("moveFoldersToEdgeFromMenu(" in folder_edge, "folder edge shortcut must use the blank-area action")
need("recordingKeyboardLayoutUndo(" in folder_edge, "folder edge shortcut must keep one undo")
need("testCommandZUndoesAKeyboardVerticalEdgeMove" in tests, "Core vertical-edge undo test missing")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in folder_edge, f"folder edge shortcut must not page ({banned})")

for key, en in (("浏览模式", "Browse Mode"), ("整理布局", "Organize Layout"), ("解散所有文件夹…", "Ungroup All Folders…"),
                ("文件夹移到最前", "Move Folders to Start"), ("文件夹移到最后", "Move Folders to End"),
                ("已解散 %d 个文件夹", "Ungrouped %d folders"), ("解散所有文件夹？", "Ungroup all folders?"),
                ("按名称排列…", "Sort by Name…"), ("按类型排列…", "Sort by Kind…"),
                ("按分类排列…", "Sort by Category…"), ("已按分类重新排列", "Arranged by category")):
    need(f'"{key}"' in strings and f'"{en}"' in strings, f"localization missing: {key}")

if failures:
    print("blank-area menu guard FAILED:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("blank-area menu guard OK")

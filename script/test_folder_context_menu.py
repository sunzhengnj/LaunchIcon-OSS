#!/usr/bin/env python3
"""Guard: folder context menu「重命名文件夹…」/「解散文件夹」/「按名称排列文件夹内应用」(LaunchOS parity; editable main grid only, no 切页)."""
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


dis = body(core, "public static func dissolveFolder(", "public static func focusIDAfterMenuDissolve(")
need("replaceSubrange(index...index" in dis, "dissolve must put members in the folder slot")
need("state.folders[folderID] = nil" in dis, "dissolve must drop the folder record")
foc = body(core, "public static func focusIDAfterMenuDissolve(", "dissolveFolderToastMessageFormatKey")
need(
    "pageIndex(containingEntryAt: index, capacity: capacity) == pageIndex(containingEntryAt: folderIndex, capacity: capacity)" in foc,
    "menu dissolve focus must stay on the folder's page",
)
need("capacity: Int = pageCapacity" in foc, "dissolve focus must honor live grid capacity")
need("testMenuDissolveFolderKeepsMembersInPlaceAndFocusOnPage" in tests, "Core test missing")

ds = body(direct, "case .folder(let folder, let preview):", "if pendingMergeAnimation")
need("collectionView !== searchCollectionView" in ds and "collectionView !== folderOverlay.collectionView" in ds,
     "folder menu only on the main grid")
need("isLayoutEditingEnabled" in ds, "folder menu hidden in read-only mode")
need("onRenameFolder: renameFolder, onDissolveFolder: dissolveFolder" in ds, "folder tile must receive menu callbacks")
need("self.onRenameFolder = isFolder ? onRenameFolder : nil" in direct, "app tiles must never get folder actions")

menu = body(direct, "private func configureFolderContextMenu(batchSelection: Bool) {", "@objc private func renameFolderMenuItem()")
need("guard !batchSelection" in menu, "multi-selection keeps its batch menu")
need('L("重命名文件夹…")' in menu and 'L("解散文件夹")' in menu, "menu titles missing")
need("configureFolderContextMenu(batchSelection: batchHide)" in direct, "configureContextMenu must route folders")

ren = body(direct, "private func promptForFolderName(", "private func dissolveFolderFromMenu(")
need("guard isLayoutEditingEnabled, acceptsIconContextMenuAction() else { return }" in ren, "rename respects lock/dismiss")
need("isPromptingForAlias = true" in ren, "rename alert must be abandoned on dismiss like the alias alert")
need("LauncherLayout.renameFolder(" in ren and "commitLayout(renamed)" in ren, "rename goes through Core + commitLayout")
need("folderOverlay" not in ren, "rename must not open folder chrome")

dfn = body(direct, "private func dissolveFolderFromMenu(", "/// Context menu「移到文件夹」")
need("guard isLayoutEditingEnabled, acceptsIconContextMenuAction() else { return }" in dfn, "dissolve respects lock/dismiss")
need("guard openedFolderID == nil, !isSearching" in dfn, "dissolve only from the main grid")
need("LauncherLayout.focusIDAfterMenuDissolve(" in dfn, "dissolve focus must use same-page policy")
need("capacity: gridGeometry.capacity" in dfn, "dissolve focus must pass live grid capacity")
for banned in ("showPage", "focusGridEntry", "PagingCollectionView", "scrollToPage", "playFolderDissolveScatter", "currentPage"):
    need(banned not in ren + dfn, f"folder menu must not touch paging/scatter ({banned})")

srt = body(core, "public static func sortingFolderMembersByName(", "private static func isSystemApplication(")
need("next.folders[folderID]?.itemIDs = sorted" in srt and "orderedEntries" not in srt,
     "folder sort reorders only that folder's members")
need("uniquingKeysWith" in srt, "folder sort must not trap on duplicate member ids")
need("testSortingFolderMembersByNameOnlyTouchesThatFolder" in tests, "folder sort Core test missing")
need("onSortFolderByName: sortFolder" in ds, "folder tile must receive the sort callback")
need("self.onSortFolderByName = isFolder ? onSortFolderByName : nil" in direct, "app tiles must never get folder sort")
need("L(LauncherLayout.sortFolderByNameMenuTitleKey)" in menu, "folder sort menu title missing")
sfn = body(direct, "private func sortFolderByNameFromMenu(", "private func dissolveFolderFromMenu(")
need("guard isLayoutEditingEnabled, acceptsIconContextMenuAction() else { return }" in sfn, "sort respects lock/dismiss")
need("LauncherLayout.sortingFolderMembersByName(" in sfn and "commitLayout(next)" in sfn, "sort goes through Core + commitLayout")
for banned in ("showPage", "focusGridEntry", "scrollToPage", "currentPage", "makeFirstResponder"):
    need(banned not in sfn, f"folder sort must not touch paging/focus ({banned})")
for key, en in (("按名称排列文件夹内应用", "Sort Apps in Folder by Name"),
                ("已按名称排列文件夹内应用", "Sorted apps in folder by name"),
                ("文件夹内应用已按名称排列", "Apps in this folder are already sorted by name")):
    need(f'"{key}"' in strings and f'"{en}"' in strings, f"localization missing: {key}")

for key, en in (("重命名文件夹…", "Rename Folder…"), ("解散文件夹", "Ungroup Folder"),
                ("已解散「%@」", "Ungrouped “%@”"), ("留空会保留原名称。", "Leave empty to keep the current name.")):
    need(f'"{key}"' in strings and f'"{en}"' in strings, f"localization missing: {key}")

need("func commandOptionNSortsFocusedFolder(" in core, "Core command-option-n sort gate missing")
need("func sortFocusedFolderByNameFromCommandOption(" in direct, "Direct command-option-n sort missing")
need("sortFocusedFolderByNameFromCommandOption(" in direct, "panel must ask to sort the folder")
need("testCommandOptionNSortsTheFocusedFolderByName" in tests, "Core command-option-n sort test missing")
sort_key = body(direct, "func sortFocusedFolderByNameFromCommandOption(", "/// Context menu「移到文件夹」")
need("commandOptionNSortsFocusedFolder(" in sort_key, "sort shortcut must ask Core")
need("sortFolderByNameFromMenu(" in sort_key, "sort shortcut must use the folder menu action")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in sort_key, f"folder sort shortcut must not page ({banned})")

need("func commandOptionNSortsOpenFolder(" in core, "Core open-folder name sort gate missing")
need("func sortOpenFolderByNameFromCommandOption(" in direct, "Direct open-folder name sort missing")
need("sortOpenFolderByNameFromCommandOption(" in direct, "panel must ask to sort the open folder")
need("testCommandOptionNSortsTheOpenFolderByName" in tests, "Core open-folder name sort test missing")
open_sort = body(direct, "func sortOpenFolderByNameFromCommandOption(", "func sortFocusedFolderByColorFromCommandOption(")
need("commandOptionNSortsOpenFolder(" in open_sort, "open-folder sort must ask Core")
need("sortingFolderMembersByName(" in open_sort, "open-folder sort must use the member sort")
need("return true" in open_sort, "open-folder sort must consume the key")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in open_sort, f"open-folder sort must not page ({banned})")

need("sortFolderByNameAccessibilityHelp" in direct, "Direct missing sortFolderByNameAccessibilityHelp")
need("sortFolderByColorAccessibilityHelp" in direct, "Direct missing sortFolderByColorAccessibilityHelp")
need('L("只调整这个文件夹内的顺序' not in direct, "Direct still hardcodes folder-sort name AX help")
need('L("只按图标颜色调整这个文件夹' not in direct, "Direct still hardcodes folder-sort color AX help")
need("sortFolderByNameAccessibilityHelpKey" in core, "Core missing folder-sort name AX help key")
need("sortFolderByColorAccessibilityHelpKey" in core, "Core missing folder-sort color AX help key")

need("func f2RenamesFocusedClosedFolder(" in core, "Core F2 rename gate missing")
need("func renameFocusedFolderFromF2(" in direct, "Direct F2 rename missing")
need("onRenameFocusedFolderFromF2" in direct, "tile F2 callback missing")
need("testF2RenamesTheFocusedClosedFolder" in tests, "Core F2 rename test missing")
f2 = body(direct, "func renameFocusedFolderFromF2(", "/// Context menu「移到文件夹」")
need("f2RenamesFocusedClosedFolder(" in f2, "F2 rename must ask Core")
need("promptForFolderName(" in f2, "F2 rename must use the folder menu action")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in f2, f"F2 rename must not page ({banned})")
need("func f2RenamesFocusedAppAlias(" in core, "Core F2 alias gate missing")
need("func renameFocusedAppAliasFromF2(" in direct, "Direct F2 alias rename missing")
need("renameFocusedAppAliasFromF2(" in direct, "tile must ask to rename an app alias")
need("testF2RenamesTheFocusedAppAlias" in tests, "Core F2 alias test missing")
alias_f2 = body(direct, "func renameFocusedAppAliasFromF2(", "/// Context menu「移到文件夹」")
need("f2RenamesFocusedAppAlias(" in alias_f2, "F2 alias rename must ask Core")
need("promptForAlias(" in alias_f2, "F2 alias rename must use the icon menu sheet")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "focusGridEntry", "currentPage"):
    need(banned not in alias_f2, f"F2 alias rename must not page ({banned})")
tile_key = body(direct, "override func keyDown(with event: NSEvent) {\n        // NSView.keyDown", "override func insertTab")
need("onRenameFocusedFolderFromF2?(" in tile_key, "tile keyDown must offer F2 rename")
need(
    tile_key.index("onRenameFocusedFolderFromF2?(") < tile_key.index("case 123, 116, 126:"),
    "F2 rename must run before the tile pages",
)

if failures:
    print("FAIL: folder context menu")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: folder context menu")

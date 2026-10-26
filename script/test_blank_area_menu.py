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
for banned in ("showPage", "focusGridEntry", "PagingCollectionView", "scrollToPage", "currentPage", "playFolderDissolveScatter"):
    need(banned not in rmd + menu + acts + ua + dt, f"blank-area menu must not touch paging ({banned})")

for key, en in (("整理布局", "Organize Layout"), ("解散所有文件夹…", "Ungroup All Folders…"),
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

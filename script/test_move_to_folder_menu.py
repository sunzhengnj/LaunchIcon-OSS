#!/usr/bin/env python3
"""Guard: app context menu「移到文件夹」(LaunchOS parity; top-level grid only, no 切页)."""
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


need("public struct FolderMenuTarget: Hashable, Sendable" in core, "Core FolderMenuTarget missing")
need("public static func moveToFolderMenuTargets(" in core, "Core menu target policy missing")
mv_start = core.index("public static func moveTopLevelApp(")
mv = core[mv_start : core.index("moveToFolderToastMessageFormatKey", mv_start)]
need(".failure(.nestedFolder)" in mv, "Core must refuse nesting folders")
need("destination: .merge(.topLevel(folderID))" in mv, "Core move must reuse the merge drop (append into folder)")
need("testMoveToFolderMenuTargetsAndMove" in tests, "Core test missing")

need("(isLayoutEditingEnabled && collectionView !== searchCollectionView)" in direct,
     "submenu targets only in editable grid (not search, not read-only)")

menu_start = direct.index("private func configureContextMenu() {")
menu = direct[menu_start : direct.index("menu = contextMenu", menu_start)]
need('L("移到文件夹")' in menu, "context menu must offer 移到文件夹")
need("if hasMoveToFolder, !batchHide || batchFolder {" in menu, "move-to-folder: single item or main-grid batch only")
need("item.representedObject = target.id.uuidString" in menu, "submenu items must carry folder ids")
need("LauncherLayout.displayName(forFolderNamed: target.name" in menu, "blank folder names need Core empty-name fallback")
need("self.onMoveToFolder = isFolder || moveToFolderTargets.isEmpty ? nil : onMoveToFolder" in direct,
     "folder tiles must never get the submenu")

root_start = direct.index("    private func moveApplication(\n")
root_fn = direct[root_start : direct.index("private func moveSelectionToNewFolder()", root_start)]
need("guard isLayoutEditingEnabled, acceptsIconContextMenuAction() else { return }" in root_fn,
     "move must respect editing lock and dismiss window")
need("guard openedFolderID == nil, !isSearching else { return }" in root_fn, "move only from the top-level grid")
need("commitLayout(next)" in root_fn, "move must go through commitLayout (prunes selection, persists)")
need("focusItemIDAfterHiding(" in root_fn and "restoreFocusAfterAlias(" in root_fn,
     "focus must stay on the current page (no jump to the folder)")
for banned in ("showPage", "focusGridEntry", "PagingCollectionView", "scrollToPage"):
    need(banned not in root_fn, f"move must not touch paging ({banned})")

batch_start = direct.index("    private func moveSelectedApplications(")
batch = direct[batch_start : direct.index("private func moveSelectionToNewFolder()", batch_start)]
need("LauncherLayout.moveTopLevelApps(" in batch, "batch move reuses Core moveTopLevelApps")
need("_ = window?.makeFirstResponder(self)\n        commitLayout(next)" in batch, "batch move clears focus before commit (no page chase)")
need("itemSelection.clear()" in batch, "batch move clears the selection")
need("LauncherLayout.batchMoveToFolderAppIDs(" in direct, "menu closure must decide batch vs single at click time")
need("testBatchMoveToFolderUsesWholeSelection" in tests, "batch Core test missing")
for key, en in (("已把 %d 个应用移到「%@」", "Moved %d apps to “%@”"),
                ("把所选应用放进已有的文件夹", "Puts the selected apps into an existing folder")):
    need(f'"{key}"' in strings and f'"{en}"' in strings, f"localization missing: {key}")

for key, en in (("移到文件夹", "Move to Folder"),
                ("把这个应用放进已有的文件夹", "Puts this app into an existing folder"),
                ("已移到「%@」", "Moved to “%@”")):
    need(f'"{key}"' in strings and f'"{en}"' in strings, f"localization missing: {key}")

if failures:
    print("FAIL: move to folder menu")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: move to folder context menu")

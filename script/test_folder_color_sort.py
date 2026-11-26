#!/usr/bin/env python3
"""Static guard for FOLDER-COLOR-SORT-01 (folder menu 按颜色排列文件夹内应用)."""
import pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
w = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
checks = [
    ("menu title", "L(LauncherLayout.sortFolderByColorMenuTitleKey)" in w),
    ("menu selector", "#selector(sortFolderByColorMenuItem)" in w),
    ("folder-only callback", "self.onSortFolderByColor = isFolder ? onSortFolderByColor : nil" in w),
    ("tile wiring", "onSortFolderByColor: sortFolderByColor" in w),
    ("name sort kept", "#selector(sortFolderByNameMenuItem)" in w),
]
s = w.find("private func sortFolderByColorFromMenu")
launch = w[s:w.find("\n    }\n", s)]
s = w.find("private func applyFolderColorSort")
body = launch + w[s:w.find("\n    }\n", s)]
checks += [
    ("offmain sampler", "IconColorSampler.shared.samples(for: members)" in launch),
    ("hide drops color sort", "shouldApplyDeferredGridRearrange" in launch),

    ("core call", "LauncherLayout.sortingFolderMembersByColor(" in body),
    ("not in folder/search", "openedFolderID == nil" in body and "!isSearching" in body),
    ("commit + toast", "commitLayout(next)" in body and "sortFolderByColorToastKey" in body),
    ("already sorted toast", "sortFolderAlreadyColorSortedToastKey" in body),
    ("no paging", all(k not in body for k in ("currentPage", "scrollToPage", "setPage", "animatePage"))),
]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
checks += [
    ("core color shortcut", "func commandOptionCSortsFocusedFolderByColor(" in core),
    ("direct color shortcut", "func sortFocusedFolderByColorFromCommandOption(" in w),
    ("panel color shortcut", "sortFocusedFolderByColorFromCommandOption(" in w),
    ("core color test", "testCommandOptionCSortsTheFocusedFolderByColor" in tests),
]
key_at = w.index("func sortFocusedFolderByColorFromCommandOption(")
key_body = w[key_at:w.index("/// Context menu「移到文件夹」", key_at)]
checks += [
    ("asks Core", "commandOptionCSortsFocusedFolderByColor(" in key_body),
    ("uses menu action", "sortFolderByColorFromMenu(" in key_body),
    ("shortcut does not page", all(
        bad not in key_body
        for bad in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage")
    )),
    ("core open color shortcut", "func commandOptionCSortsOpenFolderByColor(" in core),
    ("direct open color shortcut", "func sortOpenFolderByColorFromCommandOption(" in w),
    ("panel open color shortcut", "sortOpenFolderByColorFromCommandOption(" in w),
    ("core open color test", "testCommandOptionCSortsTheOpenFolderByColor" in tests),
]
open_at = w.index("func sortOpenFolderByColorFromCommandOption(")
open_body = w[open_at:w.index("func renameFocusedFolderFromF2(", open_at)]
checks += [
    ("open sort asks Core", "commandOptionCSortsOpenFolderByColor(" in open_body),
    ("open sort uses member color order", "sortingFolderMembersByColor(" in open_body),
    ("open sort samples off main", "IconColorSampler.shared.samples(for: members)" in open_body),
    ("open sort drops when hidden", "shouldApplyDeferredGridRearrange" in open_body),
    ("open sort stays on that folder", "openedFolderID == folderID" in open_body),
    ("open sort consumes the key", "return true" in open_body),
    ("open sort does not page", all(
        bad not in open_body
        for bad in ("showPage", "transitionToPage", "completePageTransition", "movePage", "currentPage", "focusGridEntry")
    )),
]
bad = [n for n, ok in checks if not ok]
if bad:
    print("FAIL:", ", ".join(bad)); sys.exit(1)
print("PASS: folder color sort")

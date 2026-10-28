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
bad = [n for n, ok in checks if not ok]
if bad:
    print("FAIL:", ", ".join(bad)); sys.exit(1)
print("PASS: folder color sort")

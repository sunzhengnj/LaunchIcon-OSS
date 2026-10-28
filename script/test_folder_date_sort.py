#!/usr/bin/env python3
"""Guard: folder context menu sorts members by date added / last opened (no paging)."""
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


sort = core[core.index("func sortingFolderMembersByDate("):]
need("next.folders[folderID]?.itemIDs = sorted" in sort, "date sort must write folder members")
need("orderedEntries" not in sort, "date sort must not touch top-level order")
need("date(candidate)" in sort, "date provider must run per member")
need("testSortingFolderMembersByDateReordersOnlyThatFolder" in tests, "Core test missing")
need("testApplicationDatesSkipsMissingBundles" in tests, "off-main date reader test missing")
dates = body(core, "public static func applicationDates(", "public static func rearrangeTopLevelEntriesByDate(")
need("Task.detached" in dates, "dates must be read off the main actor")

menu = body(direct, "private func configureFolderContextMenu(batchSelection: Bool) {", "@objc private func renameFolderMenuItem()")
need("kind.folderMenuTitleKey" in menu, "folder date menu title missing")
need("kind.folderAccessibilityHelp" in menu, "folder date AX help missing")
need("sortFolderByDateMenuItem" in menu, "folder date menu action missing")
need("onSortFolderByDate: sortFolderByDate" in direct, "folder tile must receive the date-sort callback")
need("self.onSortFolderByDate = isFolder ? onSortFolderByDate : nil" in direct, "app tiles must never get folder date sort")

fn = body(direct, "private func sortFolderByDateFromMenu(", "private func moveSelectedAppsToEdge(")
need("LauncherLayout.applicationDates(" in fn, "folder date sort must read dates off the main actor")
need("LauncherLayout.sortingFolderMembersByDate(" in fn, "folder date sort must go through Core")
need("commitLayout(next)" in fn, "folder date sort must commit")
need("isSamplingAppDates" in fn and "isSamplingIconColors" in fn, "date sort must not overlap color sampling")
need("shouldApplyDeferredGridRearrange" in fn, "folder date sort must not land after hide")
for banned in ("showPage", "focusGridEntry", "scrollToPage", "currentPage", "transitionToPage"):
    need(banned not in fn, f"folder date sort must not touch paging ({banned})")

for key, en in (
    ("按添加时间排列文件夹内应用", "Sort Apps in Folder by Date Added"),
    ("按上次打开时间排列文件夹内应用", "Sort Apps in Folder by Last Opened"),
    ("已按添加时间排列文件夹内应用", "Sorted apps in folder by date added"),
    ("已按上次打开时间排列文件夹内应用", "Sorted apps in folder by last opened"),
    ("文件夹内应用已按添加时间排列", "Apps in this folder are already sorted by date added"),
    ("文件夹内应用已按上次打开时间排列", "Apps in this folder are already sorted by last opened"),
    ("只按添加时间调整这个文件夹内的顺序，主屏幕不变", "Reorders only this folder by date added; the Home screen stays the same"),
    ("只按上次打开时间调整这个文件夹内的顺序，主屏幕不变", "Reorders only this folder by last opened; the Home screen stays the same"),
):
    need(f'"{key}"' in strings and f'"{en}"' in strings, f"localization missing: {key}")

if failures:
    print("FAIL: folder date sort")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: folder date sort")

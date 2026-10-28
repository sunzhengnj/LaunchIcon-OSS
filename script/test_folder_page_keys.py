#!/usr/bin/env python3
"""Guard: FOLDER-PAGE-KEYS-01 — Page Up/Down scrolls an open folder, not showPage."""
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


policy = body(layout, "enum VerticalPageKeyTarget", "func scrolledPageOffset(")
need("case folderScroll" in policy and "case searchScroll" in policy, "targets missing")
need("if folderOpen { return .folderScroll }" in policy, "open folder must win")
need("if searching { return .searchScroll }" in policy, "search scroll missing")
need("return nil" in policy, "main grid must stay on the existing page path")
for banned in ("showPage", "movePage", "transitionToPage"):
    need(banned not in policy, f"policy must not name paging ({banned})")

folder = body(direct, "func scrollOpenFolder(", "func movePage(by direction: Int)")
for banned in ("showPage", "movePage", "transitionToPage", "completePageTransition"):
    need(banned not in folder, f"folder scroll must not call paging ({banned})")
need("verticalPageKeyTarget(" in folder, "folder scroll must ask Core")
need("== .folderScroll" in folder, "folder scroll must require the folder target")
need("scrollMembers(byPage:" in folder, "folder scroll must use the member scroller")
need(
    "updateGridAccessibilityChildren(for: folderOverlay.collectionView)" in folder,
    "folder page scroll must refresh accessibility children",
)
need(
    "updateGridAccessibilityChildren(for: searchCollectionView)" in body(direct, "func scrollSearchResults(", "func scrollOpenFolder("),
    "search page scroll must refresh accessibility children",
)
need("focusPresentedItem" in folder, "off-screen folder tile must not keep the keyboard")
need("testFolderPageDownScrollsMembersWithoutTurningMainGrid" in ui, "UI folder page-down case missing")

members = body(direct, "func scrollMembers(byPage", "override init(frame frameRect: NSRect)")
need("scrolledPageOffset(" in members, "member scroller must use the shared offset")
for banned in ("showPage", "movePage", "transitionToPage"):
    need(banned not in members, f"member scroller must not name paging ({banned})")

need(
    "scrollOpenFolder(byPage: direction)" in direct
    and "scrollSearchResults(byPage: direction)" in direct,
    "panel and chrome must try the folder before search",
)
need(
    "collectionView === self.folderOverlay.collectionView" in direct,
    "folder tiles must route Page Up/Down to the folder scroller",
)
need("openedFolderID == nil" in body(direct, "func scrollSearchResults(", "func scrollOpenFolder("),
     "search scroll must still refuse an open folder")

show = body(direct, "private func showPage(_ page: Int)", "private func showPreviousPage()")
need(
    "guard openedFolderID == nil, !isSearching, pageCount > 0 else { return }" in show,
    "showPage early return changed",
)
need("testVerticalPageKeyTargetPrefersOpenFolderOverSearch" in tests, "Core test missing")

if failures:
    print("FAIL: folder page keys")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: folder page keys")

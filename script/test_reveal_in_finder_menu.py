#!/usr/bin/env python3
"""Guard: app context menu「在访达中显示」(LaunchOS parity; read-only, single+batch, no 切页)."""
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


need("public static func revealInFinderURL(for candidate: AppCandidate, isFolder: Bool) -> URL?" in core, "Core reveal policy missing")
need("func revealInFinderURLs(" in core, "Core batch revealInFinderURLs missing")
need("BATCH-REVEAL-FINDER-01" in core, "Core must tag BATCH-REVEAL-FINDER-01")
need("testRevealInFinderOnlyForAppBundles" in tests, "Core test missing")

menu_start = direct.index("private func configureContextMenu() {")
menu = direct[menu_start : direct.index("menu = contextMenu", menu_start)]
need('L("在访达中显示")' in menu, "context menu must offer 在访达中显示")
need("BATCH-REVEAL-FINDER-01" in menu or "hasReveal {" in menu, "reveal must offer single+batch")
need("revealInFinderURLs(" in direct, "Direct must call Core revealInFinderURLs for multi-select")
need("testRevealInFinderURLsForMultiSelectionSkipsFoldersAndDedupes" in tests, "Core batch reveal test missing")
need('"在访达中选中所选应用"' in (root / "Resources/Localizable.xcstrings").read_text(), "batch a11y string missing")
need("|| hasReveal || hasMoveToFolder" in menu and "else {" in menu, "read-only tiles with only reveal must still get a menu")

ctl_start = direct.index("private func revealInFinder(_ urls: [URL]) {")
ctl = direct[ctl_start : direct.index("private func launch(_ candidate: AppCandidate)", ctl_start)]
need("shouldAcceptPointerActivation(" in ctl, "reveal must ignore clicks during dismiss")
need("activateFileViewerSelecting(urls)" in ctl, "reveal must use NSWorkspace activateFileViewerSelecting(urls)")
need("hide(animated: true)" in ctl, "reveal must dismiss the launcher first")
need("showPage" not in ctl and "PagingCollectionView" not in ctl, "reveal must not touch paging")

need("revealInFinderURL(for: candidate, isFolder: false)" in direct, "data source must gate via Core policy")
need("self.onRevealInFinder = isFolder ? nil : onRevealInFinder" in direct, "folder tiles must never reveal")
need('"在访达中显示"' in strings and '"Show in Finder"' in strings, "localization missing")

if failures:
    print("FAIL: reveal in Finder")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: reveal in Finder context menu")

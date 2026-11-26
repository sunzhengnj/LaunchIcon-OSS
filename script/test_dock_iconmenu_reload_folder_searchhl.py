#!/usr/bin/env python3
"""DOCK-REOPEN-SUPPRESS / ICON-MENU-CANCEL / RELOAD-MODAL / FOLDER-CLOSE SEARCH-HL."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = "".join(p.read_text(encoding="utf-8") for p in [ROOT / "Sources/Direct/LauncherWindowController.swift", *sorted((ROOT / "Sources/Direct").glob("LauncherWindowController+*.swift"))])
delegate = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for token in (
    "DOCK-REOPEN-SUPPRESS-WHEN-SETTINGS-OR-MODAL-01",
    "shouldAcceptDockReopenShow",
    "ICON-MENU-CANCEL-ON-SETTINGS-OPEN-01",
    "shouldCancelIconContextMenuWhenOpeningSettings",
    "RELOAD-CATALOG-SUPPRESS-WHEN-MODAL-01",
    "shouldAcceptCatalogReload",
    "SEARCH-KEYBOARD-HIGHLIGHT-RESYNC-ON-CLOSE-FOLDER-01",
    "shouldResyncSearchKeyboardHighlightWhenClosingFolder",
):
    if token not in core:
        fail(f"Core missing {token}")

for token in (
    "testDockReopenSuppressesWhenSettingsOrModal",
    "testIconMenuCancelAndCatalogReloadModalGates",
    "testCloseFolderResyncsSearchKeyboardHighlightWhenSearching",
):
    if token not in tests:
        fail(f"Core test missing {token}")

dock = direct[direct.find("func respondToDockReopen"):direct.find("func respondToDockReopen") + 900]
if "shouldAcceptDockReopenShow" not in dock:
    fail("respondToDockReopen must consult shouldAcceptDockReopenShow")
for bad in ("showPage(", "transitionToPage(", "completePageTransition(", "hide("):
    if bad in dock:
        fail(f"paging/hide red line {bad} in respondToDockReopen")
if "respondToDockReopen(" not in delegate:
    fail("AppDelegate must call respondToDockReopen")

prep_i = direct.find("func prepareChromeForOpeningSettings")
prep = direct[prep_i:direct.find("\n    @objc private func openSettings()", prep_i)]
if "case .cancelIconContextMenu:" not in prep or "cancelIconContextMenuBecauseLauncherIsDismissing()" not in prep:
    fail("settings open must cancel icon context menu")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in prep:
        fail(f"paging red line {bad} in prepareChrome")

rel = direct[direct.find("func reloadCatalog()"):direct.find("func reloadCatalog()") + 700]
if "shouldAcceptCatalogReload" not in rel:
    fail("reloadCatalog must consult shouldAcceptCatalogReload")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in rel:
        fail(f"paging red line {bad} in reloadCatalog")

if "func commandRReloadsCatalog(" not in core:
    fail("Core command-r reload gate missing")
if "func reloadCatalogFromCommandR(" not in direct:
    fail("Direct command-r reload missing")
if "reloadCatalogFromCommandR(" not in direct:
    fail("panel must ask to reload")
if "testCommandRReloadsTheCatalog" not in tests:
    fail("Core command-r reload test missing")
reload_key_at = direct.index("func reloadCatalogFromCommandR(")
reload_key = direct[reload_key_at:direct.index("@objc private func reloadCatalog()", reload_key_at)]
if "commandRReloadsCatalog(" not in reload_key or "onReloadRequested?()" not in reload_key:
    fail("reload shortcut must ask Core and use the existing rescan request")
for bad in ("showPage(", "transitionToPage(", "completePageTransition(", "currentPage"):
    if bad in reload_key:
        fail(f"paging red line {bad} in reload shortcut")

cf = direct[direct.find("private func closeFolder("):direct.find("private func closeFolder(") + 3600]
if "shouldResyncSearchKeyboardHighlightWhenClosingFolder" not in cf:
    fail("closeFolder must resync search keyboard highlight")
if "syncSearchKeyboardHighlight" not in cf:
    fail("closeFolder must call syncSearchKeyboardHighlight")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in cf:
        fail(f"paging red line {bad} in closeFolder")

print("PASS: dock reopen + icon menu + reload modal + folder close search-hl")

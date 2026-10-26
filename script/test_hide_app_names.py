#!/usr/bin/env python3
"""Guard: "hide app names" preference wiring (HIDE-APP-NAMES). No paging, isHidden only."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
appdel = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
prefs = (root / "Sources/Core/LauncherPreferences.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need('prefix + "hidesAppNames"' in prefs and prefs.count('"hidesAppNames"') == 2, "store must load + save hidesAppNames")
need('prefix + "hidesFolderNames"' in prefs and prefs.count('"hidesFolderNames"') == 2, "store must load + save hidesFolderNames")
need("hidesAppNames: Bool = false" in prefs and "hidesFolderNames: Bool = false" in prefs, "defaults must stay off")
need(appdel.count("setHidesAppNames(") == 2 and appdel.count("setHidesFolderNames(") == 2,
     "app delegate applies on launch and on settings change")
need("folderNamesCheckbox.state = preferences.hidesFolderNames" in settings
     and "proposed.hidesFolderNames = folderNamesCheckbox.state == .on" in settings, "folder checkbox round-trip")
need("appNamesCheckbox.state = preferences.hidesAppNames" in settings
     and "proposed.hidesAppNames = appNamesCheckbox.state == .on" in settings, "settings checkbox round-trip")

setter = direct[direct.index("    func setHidesAppNames(_ hides: Bool) {\n        guard"):]
setter = setter[:setter.index("    private func pushNameVisibilityToTiles() {")]
push = direct[direct.index("    private func pushNameVisibilityToTiles() {"):]
setter += push[:push.index("\n    }\n")]
for banned in ("showPage", "currentPage", "scrollToPage", "reloadData", "reloadItems", "focusGridEntry",
               "makeFirstResponder", "commitLayout", "alphaValue", "animator"):
    need(banned not in setter, f"setHidesAppNames must not use {banned}")
need("tile.hidesTitleByPreference = hidesAppNames" in setter
     and "tile.hidesFolderTitleByPreference = hidesFolderNames" in setter, "setters must push to every tile")

apply_ = direct[direct.index("    private func applyTitleVisibility() {"):]
apply_ = apply_[:apply_.index("\n    }\n")]
need("LauncherLayout.tileTitleHidden(" in apply_ and "isFolder: isFolder" in apply_ and "titleLabel.isHidden" in apply_, "apply via Core policy + isHidden")
need("alphaValue" not in apply_ and "animator" not in apply_, "title visibility must not touch alpha / animate")
need("tile.isInSearchResults = collectionView === searchCollectionView" in direct
     and "tile.hidesFolderTitleByPreference = hidesFolderNames" in direct, "data source must configure each tile")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: hide app names wiring")

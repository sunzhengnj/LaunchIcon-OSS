#!/usr/bin/env python3
"""BLANK-BATCH-UNINSTALL-01: blank menu uninstall ≥2 selected eligible apps."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
core = (root / "Sources/Core/AppUninstallEligibility.swift").read_text(encoding="utf-8")
fails = []

def need(cond, msg):
    if not cond:
        fails.append(msg)

need("struct AppBatchUninstallPlan" in core, "Core AppBatchUninstallPlan")
need("BLANK-BATCH-UNINSTALL-01" in direct, "slice marker")
need("uninstallSelectedApplicationsFromBlankAreaMenu" in direct, "blank uninstall action")
need("uninstallSelectedApplications(anchorFocusID: anchor, in: activeCollectionView)" in direct,
     "reuses uninstallSelectedApplications via activeCollectionView")
need("AppBatchUninstallPlan.plan(" in direct, "gates on Core plan")
need("BLANK-BATCH-UNINSTALL-DISABLED-01" in direct, "disabled slice marker")
need("menu.autoenablesItems = false" in direct, "autoenablesItems false for disabled")
need("case .disabled(let explanationKey)" in direct, "disabled presentation handled")
need("case .hidden:" in direct and "case .enabled, .disabled:" in direct, "switch covers presentations")
# Action body outside hidden-apps hid window (same markers as dissolve/reveal).
hid_start = direct.find("private func appendHiddenApplicationsSubmenu")
hid_end = direct.find("@objc private func openSettingsFromBlankAreaMenu")
need(hid_start > 0 and hid_end > hid_start, "hid window markers")
hid = direct[hid_start:hid_end]
need("@objc private func uninstallSelectedApplicationsFromBlankAreaMenu" not in hid,
     "uninstall action outside hid")
fn = "@objc private func uninstallSelectedApplicationsFromBlankAreaMenu()"
need(fn in direct, "action signature")
chunk = direct[direct.index(fn): direct.index(fn) + 900]
for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
    need(bad not in chunk, f"paging symbol {bad} in blank uninstall action")
need("!isPaging" in chunk, "refuses while paging")
need("showToast(L(explanationKey))" in chunk, "disabled toasts explanation")

if fails:
    print("FAIL: blank batch uninstall")
    for f in fails:
        print("-", f)
    sys.exit(1)
print("PASS: blank batch uninstall")

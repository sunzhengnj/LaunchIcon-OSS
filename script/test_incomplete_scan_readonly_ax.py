#!/usr/bin/env python3
"""Guard: incomplete-scan readonly VoiceOver / help — no paging."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
elig = (root / "Sources/Core/AppUninstallEligibility.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("tileAccessibilityHelp(" in core, "Core missing tileAccessibilityHelp")
need("layoutCollectionAccessibilityHelp(" in core, "Core missing layoutCollectionAccessibilityHelp")
need("readOnlyStatusAccessibilityLabelKey" in core, "Core missing readOnly status AX label")
need("show uninstall disabled with an explanation" in elig or "VoiceOver and" in elig,
     "menuPresentation must document disabled-when-readonly")
need("return .hidden" not in elig[elig.index("func menuPresentation"):elig.index("func isSystemProtectedPath")],
     "menuPresentation must not hide uninstall when read-only")
need(".disabled(explanationKey: key)" in elig[elig.index("func menuPresentation"):elig.index("func isSystemProtectedPath")],
     "read-only must return disabled with explanation")
need("applyLayoutEditingAccessibilityHelp" in direct, "tiles must apply readonly AX help")
need("tileOpenAppBlockedFormatKey" in core, "blocked tile help must be a format key")
need("localize: { L($0) }" in direct, "tile help must localize each key")
need("L(LauncherLayout.tileAccessibilityHelp" not in direct, "do not look up the joined sentence")
need("refreshTileReadonlyAccessibilityHelp" in direct, "chrome update must refresh tile AX")
need("readOnlyStatusAccessibilityLabelKey" in direct, "readOnly status label AX")
need("uninstallItem.setAccessibilityHelp" in direct, "uninstall menu needs AX help when disabled")
need("testTileAccessibilityHelpExplainsIncompleteScanReadonly" in tests, "Core AX test missing")
need("testAppUninstallMenuPresentationDisablesWhenReadOnly" in tests, "menu presentation test must expect disabled")

for label, chunk in (
    ("tileAccessibilityHelp", core[core.index("tileAccessibilityHelp("):core.index("layoutCollectionAccessibilityHelp(")+200]),
    ("applyLayoutEditingChrome", direct[direct.index("func applyLayoutEditingChrome"):direct.index("func updateReadOnlyStatus")]),
):
    need("showPage" not in chunk and "pageTransition" not in chunk and "movePage" not in chunk,
         f"{label} must not touch paging")


need("hasUninstall" in direct, "context menu must keep uninstall when rename/hide cleared")
need("onUninstallApplication != nil" in direct[direct.index("func configureContextMenu"):direct.index("func configureContextMenu")+800]
     or "hasUninstall" in direct[direct.index("func configureContextMenu"):direct.index("func configureContextMenu")+500],
     "configureContextMenu must allow uninstall-only menu when read-only")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: incomplete-scan readonly AX")

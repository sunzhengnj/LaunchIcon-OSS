#!/usr/bin/env python3
"""TILE-ICON-RESTART / ICON-PREFETCH-RESTART / SEARCH-HIGHLIGHT-CLEAR / UNAVAILABLE-TOAST-DEDUP."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = "".join(p.read_text(encoding="utf-8") for p in [ROOT / "Sources/Direct/LauncherWindowController.swift", *sorted((ROOT / "Sources/Direct").glob("LauncherWindowController+*.swift"))])

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

for token in (
    "TILE-ICON-RESTART-AFTER-CANCEL-ON-SHOW-01",
    "shouldRestartCancelledTileIconLoad",
    "ICON-PREFETCH-RESTART-ON-SHOW-01",
    "shouldRestartIconPrefetchAfterAppearance",
    "SEARCH-KEYBOARD-HIGHLIGHT-CLEAR-ON-HIDE-01",
    "shouldClearSearchKeyboardHighlightOnHide",
    "UNAVAILABLE-ROOT-TOAST-DEDUP-01",
    "shouldAnnounceUnavailableRootsToast",
    "announcedUnavailableRootPaths",
):
    if token not in core:
        fail(f"Core missing {token}")

for token in (
    "TILE-ICON-RESTART-AFTER-CANCEL-ON-SHOW-01",
    "restartCancelledTileIconLoadsAfterAppearance",
    "restartIconLoadIfCancelledDuringDismissal",
    "iconLoadCancelledForDismissal",
    "configuredCandidate",
    "ICON-PREFETCH-RESTART-ON-SHOW-01",
    "restartIconPrefetchIfNeededAfterAppearance",
    "iconPrefetchCancelledForDismissal",
    "SEARCH-KEYBOARD-HIGHLIGHT-CLEAR-ON-HIDE-01",
    "clearSearchKeyboardHighlightBecauseLauncherIsDismissing",
    "UNAVAILABLE-ROOT-TOAST-DEDUP-01",
    "announcedUnavailableRootPaths",
    "shouldAnnounceUnavailableRootsToast",
):
    if token not in direct:
        fail(f"Direct missing {token}")

hide_at = direct.find("func hide(animated: Bool = true)")
if hide_at < 0:
    fail("hide missing")
window = direct[hide_at:hide_at + 4000]
if "clearSearchKeyboardHighlightBecauseLauncherIsDismissing" not in window:
    fail("hide must clear search keyboard highlight")
if "cancelIconPrefetchBecauseLauncherIsDismissing" not in window:
    fail("hide must cancel prefetch")
if "cancelTileIconLoadsBecauseLauncherIsDismissing" not in window:
    fail("hide must cancel tile icon loads")

prep_at = direct.find("func prepareForPresentation(clearsSearchQuery: Bool = true)")
if prep_at < 0:
    fail("prepareForPresentation missing")
prep = direct[prep_at:prep_at + 3500]
if "restartCancelledTileIconLoadsAfterAppearance" not in prep:
    fail("prepare must restart cancelled tile icon loads")
if "restartIconPrefetchIfNeededAfterAppearance" not in prep:
    fail("prepare must restart icon prefetch")

for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in window:
        fail(f"paging red line {bad} in hide window")
    if bad in prep:
        fail(f"paging red line {bad} in prepare window")

print("PASS: icon restart + prefetch restart + search highlight clear + unavailable toast dedupe")

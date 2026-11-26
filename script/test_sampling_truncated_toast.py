#!/usr/bin/env python3
"""SAMPLING-FLAG-CLEAR / REARRANGE-PROGRESS-TOAST-CLEAR / TRUNCATED-ROOT-TOAST-DEDUP."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = "".join(p.read_text(encoding="utf-8") for p in [ROOT / "Sources/Direct/LauncherWindowController.swift", *sorted((ROOT / "Sources/Direct").glob("LauncherWindowController+*.swift"))])

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

for token in (
    "TRUNCATED-ROOT-TOAST-DEDUP-01",
    "shouldAnnounceTruncatedRootsToast",
    "announcedTruncatedRootPaths",
    "SAMPLING-FLAG-CLEAR-ON-HIDE-01",
    "shouldClearIconSamplingFlagsOnHide",
    "REARRANGE-PROGRESS-TOAST-CLEAR-ON-HIDE-01",
    "REARRANGE-PROGRESS-TOAST-CLEAR-ON-SKIP-01",
    "shouldClearRearrangeProgressToast",
):
    if token not in core:
        fail(f"Core missing {token}")

for token in (
    "TRUNCATED-ROOT-TOAST-DEDUP-01",
    "announcedTruncatedRootPaths",
    "shouldAnnounceTruncatedRootsToast",
    "SAMPLING-FLAG-CLEAR-ON-HIDE-01",
    "clearIconSamplingBecauseLauncherIsDismissing",
    "REARRANGE-PROGRESS-TOAST-CLEAR-ON-HIDE-01",
    "REARRANGE-PROGRESS-TOAST-CLEAR-ON-SKIP-01",
    "clearRearrangeProgressToastsIfNeeded",
):
    if token not in direct:
        fail(f"Direct missing {token}")

hide_at = direct.find("func hide(animated: Bool = true)")
if hide_at < 0:
    fail("hide missing")
window = direct[hide_at:hide_at + 4500]
if "invalidateDeferredGridRearrange" not in window:
    fail("hide must invalidate deferred rearrange")
if "clearIconSamplingBecauseLauncherIsDismissing" not in window:
    fail("hide must clear sampling flags / progress toasts")

if direct.count("clearRearrangeProgressToastsIfNeeded()") < 5:
    fail("progress toast clear must run on hide and on each deferred-skip path")

for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in window:
        fail(f"paging red line {bad} in hide window")

print("PASS: sampling clear + rearrange progress toast clear + truncated toast dedupe")

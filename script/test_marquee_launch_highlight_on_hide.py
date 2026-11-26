#!/usr/bin/env python3
"""MARQUEE-CANCEL-ON-HIDE-01 + LAUNCH-HIGHLIGHT-CLEAR-ON-HIDE-01."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
direct = "".join(p.read_text(encoding="utf-8") for p in [ROOT / "Sources/Direct/LauncherWindowController.swift", *sorted((ROOT / "Sources/Direct").glob("LauncherWindowController+*.swift"))])

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

if "MARQUEE-CANCEL-ON-HIDE-01" not in direct:
    fail("missing MARQUEE-CANCEL-ON-HIDE-01")
if "cancelMarqueeBecauseLauncherIsDismissing" not in direct:
    fail("missing cancelMarqueeBecauseLauncherIsDismissing")
if "LAUNCH-HIGHLIGHT-CLEAR-ON-HIDE-01" not in direct:
    fail("missing LAUNCH-HIGHLIGHT-CLEAR-ON-HIDE-01")

hide_at = direct.find("func hide(animated: Bool = true)")
if hide_at < 0:
    fail("hide missing")
# WC hide body window (until next top-level func at same indent is hard; use 2500 chars)
window = direct[hide_at:hide_at + 3500]
if "cancelMarqueeBecauseLauncherIsDismissing" not in window:
    fail("hide must cancel marquee")
if "launchesInFlight.isEmpty" not in window:
    fail("hide must gate launch-highlight clear on empty in-flight")
if "setLaunchPending(nil" not in window:
    fail("hide must clear launch pending when idle")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in window:
        fail(f"paging red line {bad} in hide window")
print("PASS: marquee + launch-highlight on hide")

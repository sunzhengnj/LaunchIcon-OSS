#!/usr/bin/env python3
"""Guard: reduced-motion search↔grid crossfade snaps (no 0.12s half-fade)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


need("shouldSnapSearchChromeForReducedMotion" in core, "Core missing snap gate")
need("testSearchGridCrossfadeSnapsUnderReducedMotion" in tests, "Core test missing")

# searchChromeFade must consult the snap gate and zero duration when reduced.
fade_fn = core[
    core.index("public static func searchChromeFade(") : core.index(
        "public static func searchChromeOutgoingAcceptsClicks("
    )
]
need("shouldSnapSearchChromeForReducedMotion" in fade_fn, "searchChromeFade must consult snap gate")
need("searchTransitionDuration" in fade_fn, "full-motion must keep searchTransitionDuration")
need("duration: crossfade ? searchTransitionDuration : 0" in fade_fn, "reduced must use duration 0")

upd = direct[
    direct.index("private func updateSearchChrome(searching:") : direct.index(
        "private func currentPresentedItems("
    )
]
need("shouldSnapSearchChromeForReducedMotion" in upd, "updateSearchChrome must consult snap gate")
need("landSearchChrome()" in upd, "snap path must landSearchChrome")
# Snap branch before fade animations
snap_at = upd.find("shouldSnapSearchChromeForReducedMotion")
fade_add = upd.find("fadeViewOpacityFromPresentation")
need(snap_at >= 0 and fade_add > snap_at, "snap consult must precede fade animations")
# No literal reduced half-fade leftover in updateSearchChrome
need(
    "reduced ? 0.12" not in upd and "duration = 0.12" not in upd,
    "must not keep 0.12s reduced-motion half-fade in updateSearchChrome",
)
# Snap early-return lands without starting CABasicAnimation in that branch
early = upd[snap_at:fade_add]
need("landSearchChrome()" in early, "reduced snap must land before fade")
need("add(" not in early or "fadeViewOpacityFromPresentation" not in early, "snap must not start fade")

for label, chunk in (
    ("Core gate", core[core.index("shouldSnapSearchChromeForReducedMotion") : core.index("shouldSnapSearchChromeForReducedMotion") + 280]),
    ("updateSearchChrome", upd[:800]),
):
    need(
        "showPage(" not in chunk
        and "pageTransition" not in chunk
        and "pageAnimationDuration" not in chunk,
        f"{label} must not retune paging",
    )

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: reduced-motion search↔grid crossfade snap (no half-fade)")

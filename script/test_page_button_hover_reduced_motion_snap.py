#!/usr/bin/env python3
"""Guard: reduced-motion page-arrow hover opacity snaps only (no page-turn retune)."""
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


need("shouldSnapPageButtonHoverForReducedMotion" in core, "Core missing snap gate")
need("pageButtonHoverOpacityFadeDuration" in core, "Core missing duration policy")
need("testPageButtonHoverSnapsUnderReducedMotion" in tests, "Core test missing")

# shouldAnimate consults snap
anim = core[
    core.index("public static func shouldAnimatePageButtonHover(") : core.index(
        "public static let pageButtonHoverFadeDuration"
    )
]
need("shouldSnapPageButtonHoverForReducedMotion" in anim, "shouldAnimate must consult snap")

# PagingArrowButton.updateVisibility only
upd_start = direct.index("    private func updateVisibility(animated: Bool) {")
# next method installHoverPlate
upd_end = direct.index("    private func installHoverPlate()", upd_start)
upd = direct[upd_start:upd_end]
need("shouldSnapPageButtonHoverForReducedMotion" in upd, "updateVisibility must consult snap")
need("setAlphaWithoutAnimation" in upd, "snap must setAlphaWithoutAnimation")
snap_at = upd.index("shouldSnapPageButtonHoverForReducedMotion")
fade_at = upd.find("animateHoverOpacity")
need(fade_at > snap_at, "snap must precede animateHoverOpacity")
snap = upd[snap_at:fade_at]
need("animateHoverOpacity" not in snap, "snap branch must not animate hover")
need("pageButtonHoverOpacityFadeDuration" in upd, "full motion must use Core duration")
need(
    "pageButtonHoverOpacityFadeDuration(reducesMotion: false)" not in upd,
    "must not hardcode reducesMotion: false for hover duration",
)
need(
    "pageButtonHoverOpacityFadeDuration(reducesMotion: reduced)" in upd,
    "hover duration must pass real reduced",
)
need("duration > 0" in upd, "duration<=0 must snap without animation")

# HARD: this polish must not retune page-turn / swipe / indicator in the edited slices
forbidden = (
    "showPage(",
    "movePage(",
    "pageTransition",
    "pageAnimationDuration",
    "animatePage",
    "pageIndicator",
    "shouldAnimatePageIndicator",
)
for label, chunk in (
    ("Core snap", core[core.index("shouldSnapPageButtonHoverForReducedMotion"):][:400]),
    ("updateVisibility", upd),
):
    for bad in forbidden:
        need(bad not in chunk, f"{label} must not retune paging ({bad})")

# Presence path (setPagingAvailable animatePresence) must remain distinct / untouched keys
need("pageArrowPresenceAnimationKey" in direct, "arrow presence path must remain")
# PagingArrowButton.animatePresence — not any other animatePresence
pres = direct.index("    /// Presence fade shares the search chrome clock.")
pres_body = direct[pres : pres + 1200]
need("fade.duration = LauncherLayout.searchTransitionDuration" in pres_body,
     "presence fade clock must remain (not hover)")
need("pageButtonHoverOpacityFadeDuration" not in pres_body,
     "presence must not use hover duration policy")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: reduced-motion page-button hover snap (hover opacity only; no page-turn)")

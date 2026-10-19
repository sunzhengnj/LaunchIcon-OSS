#!/usr/bin/env python3
"""Guard: reduced-motion footer chrome / drag-hint presence snaps (opacity only; no 切页)."""
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


need("shouldSnapFooterChromeVisibilityForReducedMotion" in core, "Core missing snap gate")
need("testFooterChromeVisibilitySnapsUnderReducedMotion" in tests, "Core test missing")

gate = core[
    core.index("public static func shouldAnimatePagingChromeVisibility(") : core.index(
        "public static func footerDragHintShouldShow("
    )
]
need("shouldSnapFooterChromeVisibilityForReducedMotion" in gate, "visibility gate must consult snap")

# updateFooterHint drag-hint call
hint_start = direct.index("private func updateFooterHint() {")
hint_end = direct.index("private func setFooterChromeVisible(", hint_start)
hint = direct[hint_start:hint_end]
need("shouldAnimatePagingChromeVisibility(" in hint, "drag-hint must use visibility gate")
need("reducesMotion: reduce" in hint, "drag-hint must pass real reduce")
need(
    "currentlyShown: !dragHintLabel.isHidden,\n            reducesMotion: false" not in hint,
    "drag-hint must not hardcode reducesMotion: false",
)
need("holdsForLauncherFade: hold" in hint, "drag-hint must pass hold")

# setFooterChromeVisible
foot_start = direct.index("private func setFooterChromeVisible(")
# next private func after body
foot_rest = direct[foot_start + 80 :]
next_priv = foot_rest.find("\n    private func ")
foot = direct[foot_start : foot_start + 80 + (next_priv if next_priv > 0 else 2500)]
need("shouldSnapFooterChromeVisibilityForReducedMotion" in foot, "footer chrome must consult snap")
need("shouldAnimatePagingChromeVisibility(" in foot, "footer chrome must use visibility gate")
need("reducesMotion: reduced" in foot, "footer chrome must pass real reduced")
need(
    "currentlyShown: currentlyShown,\n            reducesMotion: false" not in foot,
    "footer chrome must not hardcode reducesMotion: false",
)

# HARD: this polish must not retune page-turn / swipe / indicator selection
# in the edited slices (presence/opacity of footer stack only).
forbidden = (
    "showPage(",
    "movePage(",
    "pageTransition",
    "pageAnimationDuration",
    "animateSelection",
    "setTransition(",
)
for label, chunk in (
    ("Core snap+gate", core[core.index("shouldSnapFooterChromeVisibilityForReducedMotion"):][:800]),
    ("updateFooterHint", hint),
    ("setFooterChromeVisible", foot),
):
    for bad in forbidden:
        need(bad not in chunk, f"{label} must not retune paging ({bad})")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: reduced-motion footer chrome visibility snap (presence/opacity only; no 切页)")

#!/usr/bin/env python3
"""Guard: reduced-motion drag-lift snaps to cell image (no scale/shadow travel)."""
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


need("shouldSnapDragLiftForReducedMotion" in core, "Core missing snap gate")
need("testDragLiftSnapsUnderReducedMotion" in tests, "Core test missing")

fn = core[
    core.index("public static func dragLiftPresentation(for") : core.index(
        "public static func insertionIndexAfterRemovingSource("
    )
]
need("shouldSnapDragLiftForReducedMotion" in fn, "dragLiftPresentation must consult snap")
need("return identity" in fn, "snap must return identity presentation")

drop = core[
    core.index("public static func shouldDropInFlightDragLift(") : core.index(
        "public static func shouldDropInFlightDragLift("
    )
    + 450
]
need("shouldSnapDragLiftForReducedMotion" in drop, "drop-in-flight must consult snap")

# Direct begin-drag path
need("shouldSnapDragLiftForReducedMotion" in direct, "Direct must consult snap gate")
need("snapLift" in direct, "Direct must use snapLift for showsLift")
# showsLift false when snap
need("!snapLift && presentation.shadowOpacity > 0" in direct, "showsLift must be false when snap")

# fadeLiftShadow must pass real reduced (not false) and consult snap
fade = direct[
    direct.index("private func fadeLiftShadow(on flyer:") : direct.index(
        "private func topLevelSourceIndex("
    )
]
need("shouldSnapDragLiftForReducedMotion" in fade, "fadeLiftShadow must consult snap")
need(
    "dragLiftPresentation(for: flyer.bounds.size, reducesMotion: false)" not in fade,
    "must not hardcode reducesMotion: false for dragLiftPresentation",
)
need("reducesMotion: reduced" in fade, "fadeLiftShadow must pass real reduced")
need("dropLandingShadowFadeDuration" in fade, "fadeLiftShadow must use shadow fade duration")


fade_chunk = direct[
    direct.index("private func fadeLiftShadow(on flyer:") : direct.index(
        "private func topLevelSourceIndex("
    )
]
for label, chunk in (("Core", fn[:500]), ("drop", drop), ("fadeLiftShadow", fade_chunk[:600])):
    need(
        "showPage(" not in chunk
        and "movePage(" not in chunk
        and "pageTransition" not in chunk
        and "pageAnimationDuration" not in chunk,
        f"{label} must not retune paging",
    )

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: reduced-motion drag-lift snap (no scale/shadow travel)")

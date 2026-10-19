#!/usr/bin/env python3
"""Guard: reduced-motion merge flyer snaps (no 0.12s half-fade)."""
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


need("shouldSnapMergeFlyerForReducedMotion" in core, "Core missing snap gate")
need("mergeReducedFadeDuration" in core, "Core missing duration policy")
need("testMergeFlyerSnapsUnderReducedMotion" in tests, "Core test missing")

dur = core[
    core.index("public static func mergeReducedFadeDuration(") : core.index(
        "public static func mergeReducedFadeDuration("
    )
    + 350
]
need("shouldSnapMergeFlyerForReducedMotion" in dur, "duration must consult snap")
need("return 0" in dur, "reduced must return 0")

merge = direct[
    direct.index("private func playMergeAnimation(") : direct.index(
        "private func materializedFolderItem("
    )
]
branch = merge.index("if prefersReducedMotion {")
reduced = merge[branch : merge.index("\n            return\n", branch)]
need("shouldSnapMergeFlyerForReducedMotion" in reduced, "playMerge must consult snap")
need("mergeReducedFadeDuration" in reduced, "playMerge must consult duration")
need('add(fade, forKey: "merge-reduced-fade")' not in reduced, "must not add merge-reduced-fade")
need("duration = 0.12" not in reduced, "must not keep 0.12 half-fade")
need("finishFlightOnLandingTurn" in reduced, "snap must remove via finishFlightOnLandingTurn")
need("opacity = 0" in reduced, "snap must park opacity 0")
need("merge-flight-fade" in merge, "full-motion merge-flight-fade must remain")

for label, chunk in (("Core", dur), ("reduced merge", reduced[:400])):
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
print("PASS: reduced-motion merge flyer snap (no half-fade)")

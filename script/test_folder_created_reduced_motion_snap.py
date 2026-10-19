#!/usr/bin/env python3
"""Guard: reduced-motion new-folder landing snaps (no 0.12s half-fade)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
timing = (root / "script/test_folder_landing_timing.py").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


need("shouldSnapFolderCreatedForReducedMotion" in core, "Core missing snap gate")
need("folderCreatedFadeDuration" in core, "Core missing duration policy")
need("testFolderCreatedSnapsUnderReducedMotion" in tests, "Core test missing")

dur = core[
    core.index("public static func folderCreatedFadeDuration(") : core.index(
        "public static func folderCreatedFadeDuration("
    )
    + 350
]
need("shouldSnapFolderCreatedForReducedMotion" in dur, "duration must consult snap")
need("return 0" in dur, "reduced must return 0")

landing = direct[
    direct.index("private func playFolderLandingAnimation(") : direct.index(
        "private func beginTrackedFolderLanding(on layer: CALayer) -> Int"
    )
]
reduced_at = landing.index("if prefersReducedMotion {")
# until full-motion revealDuration
end = landing.index("let revealDuration:", reduced_at)
reduced = landing[reduced_at:end]
need("shouldSnapFolderCreatedForReducedMotion" in reduced, "landing must consult snap")
need("commitFolderLandingVisual" in reduced, "snap must commitFolderLandingVisual")
need('add(animation, forKey: "folder-created")' not in reduced, "must not add folder-created fade")
need("duration = 0.12" not in reduced and "after: 0.12" not in reduced,
     "must not keep 0.12s reduced half-fade")
need("shouldAnimateReducedMotionFolderLanding" in reduced, "hold/reveal gate must remain")

need("snaps new folder without half-fade" in timing, "landing timing harness must expect snap")
need("deadlines != [0.12]" not in timing, "landing timing must not require 0.12 deadline")

for label, chunk in (("Core", dur), ("reduced landing", reduced[:500])):
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
print("PASS: reduced-motion folder-created snap (no half-fade)")

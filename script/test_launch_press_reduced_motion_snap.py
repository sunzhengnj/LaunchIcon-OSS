#!/usr/bin/env python3
"""Guard: reduced-motion launch-press scale snaps (no pulse / half-fade travel)."""
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


need("shouldSnapLaunchPressForReducedMotion" in core, "Core missing snap gate")
need("launchPressPulseHalfDuration" in core, "Core missing duration policy")
need("testLaunchPressSnapsUnderReducedMotion" in tests, "Core test missing")
need("shouldSnapLaunchPressForReducedMotion" in core[
    core.index("shouldPlayLaunchFeedback") : core.index("shouldPlayLaunchFeedback") + 280
], "shouldPlay must consult snap gate")

play = direct[
    direct.index("private func playLaunchFeedback()") : direct.index(
        "func snapLaunchFeedbackForMotionChange()"
    )
]
need("shouldSnapLaunchPressForReducedMotion" in play, "playLaunchFeedback must consult snap")
snap_at = play.index("shouldSnapLaunchPressForReducedMotion")
pulse_at = play.index("shouldPlayLaunchFeedback")
need(snap_at < pulse_at, "snap must precede full-motion pulse")
snap = play[snap_at:pulse_at]
need("CATransform3DIdentity" in snap, "snap must rest identity transform")
need("add(animation" not in snap, "snap must not add pulse animation")
need("autoreverses" not in snap, "snap must not autoreverse pulse")
need("launchPressPulseHalfDuration" in play[pulse_at:], "full motion must use Core duration")
need(
    "launchPressPulseHalfDuration(\n            reducesMotion: false" not in play
    and "reducesMotion: false" not in play.split("launchPressPulseHalfDuration")[-1][:80],
    "must not hardcode reducesMotion: false for pulse duration",
)
need("reducesMotion: reducesMotion" in play.split("launchPressPulseHalfDuration")[-1][:120]
     or "launchPressPulseHalfDuration(reducesMotion: reducesMotion)" in play,
     "pulse duration must pass real reducesMotion")

for label, chunk in (("Core", core[core.index("shouldSnapLaunchPressForReducedMotion"):][:300]), ("play", snap)):
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
print("PASS: reduced-motion launch-press snap (no pulse)")

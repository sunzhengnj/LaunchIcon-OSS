#!/usr/bin/env python3
"""Guard: reduced-motion drop-landing start/flight snaps (no flyer travel)."""
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


need("shouldSnapDropLandingForReducedMotion" in core, "Core missing snap gate")
need("dropLandingTravelDuration" in core, "Core missing duration policy")
need("testDropLandingSnapsUnderReducedMotion" in tests, "Core test missing")

flight = core[
    core.index("public static func dropLandingFlight(") : core.index(
        "public static func shouldPlayDropLanding("
    )
]
need("shouldSnapDropLandingForReducedMotion" in flight, "dropLandingFlight must consult snap")

play = core[
    core.index("public static func shouldPlayDropLanding(") : core.index(
        "public static func shouldHoldDropLanding("
    )
]
need("shouldSnapDropLandingForReducedMotion" in play, "shouldPlay must consult snap")

queue = direct[
    direct.index("private func queueDropLanding(") : direct.index(
        "private func queueCancelledDropLanding("
    )
]
need("shouldSnapDropLandingForReducedMotion" in queue, "queueDropLanding must consult snap")
need("reducesMotion: false" not in queue, "must not hardcode reducesMotion: false for start frame")
need("dropLandingStartFrame" in queue and "reducesMotion: reduced" in queue,
     "start frame must pass reduced")

start = direct[
    direct.index("private func startDropLandingFlight()") : direct.index(
        "private func dropLandingDestinationFrame("
    )
]
need("shouldSnapDropLandingForReducedMotion" in start, "startDropLandingFlight must consult snap")
need("commitDropLanding()" in start, "snap must commitDropLanding")

for label, chunk in (("Core flight", flight[:400]), ("queue", queue), ("start", start[:500])):
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
print("PASS: reduced-motion drop-landing snap (no flyer travel)")

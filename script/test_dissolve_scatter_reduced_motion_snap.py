#!/usr/bin/env python3
"""Guard: reduced-motion folder-dissolve scatter snaps (no flyer travel)."""
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


need("shouldSnapDissolveScatterForReducedMotion" in core, "Core missing snap gate")
need("dissolveScatterTravelDuration" in core, "Core missing duration policy")
need("testDissolveScatterSnapsUnderReducedMotion" in tests, "Core test missing")

flights = core[
    core.index("public static func folderDissolveFlights(") : core.index(
        "public static func folderDissolveChrome("
    )
]
need("shouldSnapDissolveScatterForReducedMotion" in flights, "folderDissolveFlights must consult snap")
need("return []" in flights, "snap must return no flights")

play = core[
    core.index("public static func shouldPlayFolderDissolveScatter(") : core.index(
        "public static func flightLandingCommitsOnThisTurn("
    )
]
need("shouldSnapDissolveScatterForReducedMotion" in play, "shouldPlay must consult snap")

seeds = direct[
    direct.index("private func folderDissolveScatterSeeds(") : direct.index(
        "private func playFolderDissolveScatter("
    )
]
need("shouldSnapDissolveScatterForReducedMotion" in seeds, "seeds must consult snap")

play_d = direct[
    direct.index("private func playFolderDissolveScatter(") : direct.index(
        "private func tileForPresentedItem("
    )
]
need("shouldSnapDissolveScatterForReducedMotion" in play_d, "play must consult snap")
need(
    "folderDissolveFlights(placements: placements, reducesMotion: false)" not in play_d,
    "must not hardcode reducesMotion: false for flights",
)
need("folderDissolveFlights(" in play_d and "reducesMotion: reduced" in play_d,
     "flights must pass reduced")
need("dissolveScatterTravelDuration" in play_d, "play must use travel duration")
need(
    "dissolveScatterTravelDuration(reducesMotion: false)" not in play_d,
    "must not hardcode reducesMotion: false for travel duration",
)
need(
    "dissolveScatterTravelDuration(reducesMotion: reduced)" in play_d,
    "travel duration must pass real reduced",
)

for label, chunk in (("Core", flights[:400]), ("play", play_d[:600])):
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
print("PASS: reduced-motion dissolve-scatter snap (no flyer travel)")

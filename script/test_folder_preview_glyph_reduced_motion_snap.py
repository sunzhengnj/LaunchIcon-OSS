#!/usr/bin/env python3
"""Guard: reduced-motion folder-preview glyph fly-in/return snaps (no flyer travel)."""
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


need("shouldSnapFolderPreviewGlyphForReducedMotion" in core, "Core missing snap gate")
need("folderPreviewGlyphTravelDuration" in core, "Core missing duration policy")
need("testFolderPreviewGlyphSnapsUnderReducedMotion" in tests, "Core test missing")

flights = core[
    core.index("public static func folderPreviewGlyphFlights(") : core.index(
        "public static func shouldPlayFolderPreviewGlyphFlight("
    )
]
need("shouldSnapFolderPreviewGlyphForReducedMotion" in flights, "folderPreviewGlyphFlights must consult snap")
need("return []" in flights, "snap must return no flights")

play = core[
    core.index("public static func shouldPlayFolderPreviewGlyphFlight(") : core.index(
        "public static func folderPreviewGlyphReturnFlights("
    )
]
need("shouldSnapFolderPreviewGlyphForReducedMotion" in play, "shouldPlay must consult snap")

fly = direct[
    direct.index("private func playFolderPreviewGlyphFlight(") : direct.index(
        "private func playFolderPreviewGlyphReturn("
    )
]
need("shouldSnapFolderPreviewGlyphForReducedMotion" in fly, "fly-in play must consult snap")
need("folderPreviewGlyphTravelDuration" in fly, "fly-in play must use travel duration")
need(
    "folderPreviewGlyphFlights(placements: placements, reducesMotion: false)" not in fly,
    "must not hardcode reducesMotion: false for fly-in flights",
)
need("reducesMotion: reduced" in fly, "fly-in flights must pass reduced")

ret = direct[
    direct.index("private func playFolderPreviewGlyphReturn(") : direct.index(
        "private func retargetPreviewGlyphFlight("
    )
]
need("shouldSnapFolderPreviewGlyphForReducedMotion" in ret, "return play must consult snap")
need("folderPreviewGlyphTravelDuration" in ret, "return play must use travel duration")
need(
    "folderPreviewGlyphReturnFlights(placements: placements, reducesMotion: false)" not in ret,
    "must not hardcode reducesMotion: false for return flights",
)
need("reducesMotion: reduced" in ret, "return flights must pass reduced")

for label, chunk in (("Core-flights", flights[:500]), ("fly-in", fly[:700]), ("return", ret[:700])):
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
print("PASS: reduced-motion folder-preview glyph snap (no flyer travel)")

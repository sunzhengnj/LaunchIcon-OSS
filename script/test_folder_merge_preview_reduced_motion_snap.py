#!/usr/bin/env python3
"""Guard: reduced-motion folder-merge preview landings snap (no flyer travel)."""
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


need("shouldSnapFolderMergePreviewForReducedMotion" in core, "Core missing snap gate")
need("folderMergePreviewTravelDuration" in core, "Core missing duration policy")
need("testFolderMergePreviewSnapsUnderReducedMotion" in tests, "Core test missing")

landings = core[
    core.index("public static func folderMergePreviewLandings(") : core.index(
        "public static let folderMergePlateRevealFraction"
    )
]
need("shouldSnapFolderMergePreviewForReducedMotion" in landings, "landings must consult snap")
need("return []" in landings, "snap must return no landings")

play = direct[
    direct.index("private func playMergePreviewLanding(") : direct.index(
        "private func playIncomingFolderPreviewLanding("
    )
]
need("shouldSnapFolderMergePreviewForReducedMotion" in play, "play must consult snap")
need("folderMergePreviewTravelDuration" in play, "play must use travel duration")
need(
    "destinations: Array(glyphFrames.prefix(2)),\n            reducesMotion: false" not in play,
    "must not hardcode reducesMotion: false for landings",
)
need(
    "destinations: Array(glyphFrames.prefix(2)),\n            reducesMotion: reduced" in play,
    "landings must pass reduced",
)

for label, chunk in (("Core-landings", landings[:500]), ("play", play[:700])):
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
print("PASS: reduced-motion folder-merge preview snap (no flyer travel)")

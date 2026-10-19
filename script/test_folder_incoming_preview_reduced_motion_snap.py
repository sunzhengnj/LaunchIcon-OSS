#!/usr/bin/env python3
"""Guard: reduced-motion folder incoming-preview landings snap (no flyer travel)."""
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


need("shouldSnapFolderIncomingPreviewForReducedMotion" in core, "Core missing snap gate")
need("folderIncomingPreviewTravelDuration" in core, "Core missing duration policy")
need("testFolderIncomingPreviewSnapsUnderReducedMotion" in tests, "Core test missing")

slot = core[
    core.index("public static func folderIncomingPreviewLanding(") : core.index(
        "public static let folderPreviewPlateCenterInsetFraction"
    )
]
need("shouldSnapFolderIncomingPreviewForReducedMotion" in slot, "slot landing must consult snap")
need("return nil" in slot, "snap must return nil")

center = core[
    core.index("public static func folderIncomingPreviewCenterLanding(") : core.index(
        "public static let wholeCellMergeFadeX1"
    )
]
need("shouldSnapFolderIncomingPreviewForReducedMotion" in center, "center landing must consult snap")
need("return nil" in center or "else { return nil }" in center, "center snap must return nil")

play_slot = direct[
    direct.index("private func playIncomingFolderPreviewLanding(") : direct.index(
        "private func playIncomingFolderPreviewCenterLanding("
    )
]
need("shouldSnapFolderIncomingPreviewForReducedMotion" in play_slot, "slot play must consult snap")
need("folderIncomingPreviewTravelDuration" in play_slot, "slot play must use travel duration")
need(
    "folderIncomingPreviewLanding(\n                incoming: incomingFrame,\n                destination: frames[slot],\n                reducesMotion: false"
    not in play_slot
    and "reducesMotion: false" not in play_slot.split("folderIncomingPreviewLanding")[1].split(")")[0]
    if "folderIncomingPreviewLanding" in play_slot
    else False,
    "must not hardcode reducesMotion: false for slot landing",
)
# Simpler hardcode check:
need(
    "destination: frames[slot],\n                reducesMotion: false" not in play_slot
    and "destination: frames[slot],\n                reducesMotion: reduced" in play_slot,
    "slot landing must pass reduced (not false)",
)

play_center = direct[
    direct.index("private func playIncomingFolderPreviewCenterLanding(") : direct.index(
        "private func pinMergePreviewFlyers("
    )
]
need("shouldSnapFolderIncomingPreviewForReducedMotion" in play_center, "center play must consult snap")
need("folderIncomingPreviewTravelDuration" in play_center, "center play must use travel duration")
need(
    "well: well,\n                reducesMotion: false" not in play_center
    and "well: well,\n                reducesMotion: reduced" in play_center,
    "center landing must pass reduced (not false)",
)

for label, chunk in (("Core-slot", slot[:500]), ("Core-center", center[:500]),
                     ("play-slot", play_slot[:700]), ("play-center", play_center[:700])):
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
print("PASS: reduced-motion folder incoming-preview snap (no flyer travel)")

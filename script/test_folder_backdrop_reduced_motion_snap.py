#!/usr/bin/env python3
"""Guard: reduced-motion folder backdrop open/close snaps (no half-fade; dimmer park intact)."""
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


need("shouldSnapFolderBackdropForReducedMotion" in core, "Core missing snap gate")
need("folderBackdropFadeDuration" in core, "Core missing duration policy")
need("testFolderBackdropSnapsUnderReducedMotion" in tests, "Core test missing")

dur = core[
    core.index("public static func folderBackdropFadeDuration(") : core.index(
        "public static func folderBackdropFadeDuration("
    )
    + 500
]
need("shouldSnapFolderBackdropForReducedMotion" in dur, "duration must consult snap gate")
need("return 0" in dur, "reduced must return duration 0")

set_fn = direct[
    direct.index("private func setFolderBackdrop(") : direct.index(
        "private func resetFolderBackdrop("
    )
]
need("shouldSnapFolderBackdropForReducedMotion" in set_fn, "setFolderBackdrop must consult snap")
need("finishFolderBackdropOpen(backdrop)" in set_fn, "open snap via finishFolderBackdropOpen")
# Reduced branch must land without calling animateFolderBackdrop
snap_at = set_fn.find("shouldSnapFolderBackdropForReducedMotion")
need(snap_at >= 0, "snap gate in setFolderBackdrop")
after_snap = set_fn[snap_at:]
# Early reduced path returns before animateFolderBackdrop
anim_at = after_snap.find("animateFolderBackdrop(")
need(anim_at > 0, "full-motion animateFolderBackdrop must remain")
reduced_chunk = after_snap[:anim_at]
need("finishFolderBackdropOpen" in reduced_chunk, "reduced open must finishFolderBackdropOpen")
need("resetFolderBackdrop(backdrop)" in reduced_chunk, "reduced close must resetFolderBackdrop")

anim = direct[
    direct.index("private func animateFolderBackdrop(") : direct.index(
        "private func openFolder("
    )
]
need("folderBackdropFadeDuration" in anim, "animate must use Core duration")
need("reduced ? 0.12" not in anim and "reduced ? 0.12 : 0.22" not in anim,
     "must not keep reduced ? 0.12 half-fade")
need("folderBackdropOpacity" in anim, "full-motion opacity fade must remain")
need("fillMode = .backwards" in anim, "full-motion fillMode.backwards must remain")

# Do not regress dimmer park-before-reveal on folder panel open.
open_fn = direct[direct.index("func animateOpen(collapse:"):direct.index("func animateClose(")]
reveal = open_fn.find("isHidden = false")
need(reveal > 0, "animateOpen reveal missing")
need("fromDimmerOpacity" in open_fn[:reveal], "folder dimmer park-before-reveal must remain")

for label, chunk in (
    ("Core", dur),
    ("setFolderBackdrop", set_fn[:600]),
):
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
print("PASS: reduced-motion folder backdrop snap (no half-fade; dimmer park intact)")

#!/usr/bin/env python3
"""Guard: reduced-motion folder panel chrome snaps (no half-fade; dimmer park intact)."""
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


need("shouldSnapFolderChromeForReducedMotion" in core, "Core missing snap gate")
need("folderChromeFadeDuration" in core, "Core missing duration policy")
need("folderChromeReducedDuration: TimeInterval = 0" in core, "reduced duration must be 0")
need("testFolderChromeSnapsUnderReducedMotion" in tests, "Core test missing")

collapse = core[
    core.index("public static func folderChromeCollapse(") : core.index(
        "public static func folderPanelCollapsedCornerRadius("
    )
]
need("shouldSnapFolderChromeForReducedMotion" in collapse, "collapse must consult snap gate")
need("folderChromeFadeDuration(reducesMotion: true)" in collapse, "collapse must use fade duration 0")

open_fn = direct[direct.index("func animateOpen(collapse:"):direct.index("func animateClose(")]
reveal = open_fn.find("isHidden = false")
need(reveal > 0, "animateOpen reveal missing")
need("fromDimmerOpacity" in open_fn[:reveal], "dimmer park-before-reveal must remain")
# Snap after park
need("duration <= 0" in open_fn, "animateOpen must snap when duration 0")
snap_at = open_fn.find("duration <= 0")
need(snap_at > reveal, "snap must run after park/reveal")
# Full-motion dimmer fade still present
need("dimmerFade" in open_fn and "fillMode = .backwards" in open_fn,
     "full-motion dimmer fade + fillMode.backwards must remain")

close_fn = direct[direct.index("func animateClose("):direct.index("private func collapsedPanelTransform(")]
need("shouldSnapFolderChromeForReducedMotion" in close_fn, "animateClose must consult snap gate")
need("immediately: true" in close_fn, "reduced close must snap immediately")

for label, chunk in (
    ("Core collapse", collapse[:500]),
    ("animateOpen", open_fn[:500]),
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
print("PASS: reduced-motion folder chrome snap (no half-fade; dimmer park intact)")

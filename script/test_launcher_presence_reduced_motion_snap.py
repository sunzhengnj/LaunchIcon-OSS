#!/usr/bin/env python3
"""Guard: reduced-motion launcher presence snaps (show/hide/hotkey/hot-corner; no half-fade)."""
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

need("shouldSnapLauncherPresenceForReducedMotion" in core, "Core missing snap gate")
need("launcherPresenceFadeDuration" in core, "Core missing duration policy")
need("testLauncherPresenceSnapsUnderReducedMotion" in tests, "Core test missing")

anim = direct[
    direct.index("func animateLauncherPresence(") : direct.index(
        "private func snapInFlightLauncherPresenceForMotionChange("
    )
]
need("shouldSnapLauncherPresenceForReducedMotion" in anim, "animate must consult snap gate")
need("launcherPresenceFadeDuration" in anim, "animate must use Core duration")
# No literal 0.12 reduced fade leftover
need("reduced ? 0.12" not in anim and "duration = reduced ? 0.12" not in anim,
     "must not keep 0.12s reduced-motion half-fade")
snap = anim[anim.index("shouldSnapLauncherPresenceForReducedMotion"):]
# Until full-motion timing setup
end = snap.find("let timing = CAMediaTimingFunction")
need(end > 0, "snap branch must precede full-motion timing")
snap_branch = snap[:end]
need("add(fade" not in snap_branch, "snap must not add fade animation")
need("CATransform3DIdentity" in snap_branch, "snap must rest card transform")
need("return duration" in snap_branch, "snap must return duration 0")

# Entry points
need("func respondToHotCornerTrigger()" in direct, "hot-corner must use show/hide → presence")
need("func toggleVisibility()" in direct, "hotkey toggle must use show/hide → presence")
show = direct[direct.index("func show(animated:"):direct.index("func hide(animated:")]
hide = direct[direct.index("func hide(animated:"):direct.index("func toggleVisibility()")]
need("animateLauncherPresence" in show, "show must call animateLauncherPresence")
need("animateLauncherPresence" in hide, "hide must call animateLauncherPresence")

for label, chunk in (("Core", core[core.index("shouldSnapLauncherPresenceForReducedMotion"):core.index("shouldSnapLauncherPresenceForReducedMotion")+350]), ("animate", snap_branch)):
    need("showPage(" not in chunk and "pageTransition" not in chunk and "pageAnimationDuration" not in chunk,
         f"{label} must not retune paging")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: reduced-motion launcher presence snap (no half-fade)")

#!/usr/bin/env python3
"""Guard: launcher show/hide presence continues from presentation; park before orderFront."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("launcherPresenceFadeFromOpacity" in core, "Core missing launcherPresenceFadeFromOpacity")
need("launcherPresenceFadeAnimationKey" in core, "Core missing fade key")
need("parkLauncherPresenceHiddenForAppear" in direct, "Direct missing park before appear")
need("parkLauncherPresenceHiddenForAppear()" in direct, "show() must call park before orderFront")

show = direct[direct.index("func show(animated:"):direct.index("func hide(animated:")]
park_at = show.find("parkLauncherPresenceHiddenForAppear()")
front_at = show.find("makeKeyAndOrderFront")
need(park_at >= 0 and front_at > park_at, "park must precede makeKeyAndOrderFront on appear")

anim = direct[direct.index("func animateLauncherPresence("):direct.index("private func snapInFlightLauncherPresenceForMotionChange(")]
need("launcherPresenceFadeFromOpacity" in anim, "animate must use Core from-opacity policy")
need("presentation()?.opacity" in anim or "presentedOpacity" in anim, "animate must read presentation opacity")
# Full-motion path: presentation read before removeAnimation (snap branch may
# remove earlier without a fade — that is intentional under reduced motion).
full = anim
if "let timing = CAMediaTimingFunction" in anim:
    full = anim[anim.index("let timing = CAMediaTimingFunction"):]
pres_at = full.find("presentation()?.opacity")
if "presentedOpacity: layer.presentation()" in full:
    pres_at = full.find("presentedOpacity: layer.presentation()")
rm_at = full.find("removeAnimation(forKey: LauncherLayout.launcherPresenceFadeAnimationKey)")
need(pres_at >= 0 and rm_at > pres_at, "must read presentation before removing launcherFade")
need("fillMode = .backwards" in anim, "presence fade must use fillMode.backwards")
need("launcherPresenceGeneration" in anim or "launcherPresenceGeneration" in direct,
     "presence generation stamp missing")
need("animator().alphaValue" not in anim, "presence must not use animator().alphaValue")

# Must not touch paging gesture paths in this slice — guard files remain.
need((root / "script/test_paging_input.py").exists(), "paging input guard must remain")
need((root / "script/test_page_host_geometry.py").exists(), "page host geometry guard must remain")

# Folder dimmer park-before-reveal must remain (do not regress).
folder_open = direct[direct.index("func animateOpen(collapse:"):direct.index("func animateClose(")]
need("fromDimmerOpacity" in folder_open[:folder_open.find("isHidden = false")],
     "folder dimmer park-before-reveal must remain")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)

# Reduced motion: snap (duration 0), no opacity half-fade.
need("shouldSnapLauncherPresenceForReducedMotion" in core, "Core missing reduced-motion presence snap gate")
need("launcherPresenceFadeDuration" in core, "Core missing presence fade duration policy")
need("testLauncherPresenceSnapsUnderReducedMotion" in (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(),
     "Core reduced-motion presence test missing")
anim = direct[direct.index("func animateLauncherPresence("):direct.index("private func snapInFlightLauncherPresenceForMotionChange(")]
need("shouldSnapLauncherPresenceForReducedMotion" in anim, "animateLauncherPresence must snap when reduced")
need("launcherPresenceFadeDuration" in anim, "animate must use Core duration (0 when reduced)")
# Snap branch must not add launcherFade animation when reduced
snap_branch = anim[anim.index("shouldSnapLauncherPresenceForReducedMotion"):anim.index("let timing")]
need("layer.add(fade" not in snap_branch and "add(fade" not in snap_branch,
     "reduced-motion snap must not add opacity fade animation")
need("return duration" in snap_branch or "return duration" in anim[:anim.index("let timing")+50],
     "snap branch must return duration (0)")
# Hot corner / hotkey still enter via show/hide → animateLauncherPresence
need("respondToHotCornerTrigger" in direct, "hot corner path must remain")
need("func toggleVisibility()" in direct, "hotkey toggle path must remain")
need("showPage(" not in anim and "pageTransition" not in anim and "pageAnimationDuration" not in anim,
     "presence animate must not retune paging")

print("PASS: launcher presence from presentation + reduced-motion snap")


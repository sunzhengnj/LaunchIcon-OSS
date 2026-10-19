#!/usr/bin/env python3
"""Guard: reduced-motion neighbor reorder slide snaps (no spring travel)."""
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


need("shouldSnapReorderSlideForReducedMotion" in core, "Core missing snap gate")
need("reorderSlideSpringDuration" in core, "Core missing duration policy")
need("testReorderSlideSnapsUnderReducedMotion" in tests, "Core test missing")

anim = core[
    core.index("public static func shouldAnimateReorderSlide(") : core.index(
        "public static func shouldHoldReorderPresentationUntilFramesReady("
    )
]
need("shouldSnapReorderSlideForReducedMotion" in anim, "shouldAnimate must consult snap")

set_fn = direct[
    direct.index("    func setReorderTranslation(_ translation: CGSize, animated: Bool) {") : direct.index(
        "    fileprivate func receiveReorderSlideFrame("
    )
]
need("shouldSnapReorderSlideForReducedMotion" in set_fn, "setReorderTranslation must consult snap")
need("reorderSlideSpringDuration" in set_fn, "setReorderTranslation must consult duration")
# Snap path stops clock and applies presentation without starting spring
need("reorderClock.stop()" in set_fn, "snap must stop reorder clock")
need("applyReorderSlidePresentation()" in set_fn, "snap must apply presentation")
# Must not start spring when snapReduced
need("!snapReduced" in set_fn or "snapReduced" in set_fn, "snapReduced gate present")
need("reorderClock.start" in set_fn, "full-motion spring start must remain")

# applyReorderSlots still uses shouldAnimateReorderSlide
slots = direct[
    direct.index("    private func applyReorderSlots(") : direct.index(
        "    private func restoreDragSourceTile()"
    )
]
need("shouldAnimateReorderSlide" in slots, "applyReorderSlots must use shouldAnimateReorderSlide")

for label, chunk in (
    ("Core", anim[:400]),
    ("setReorderTranslation", set_fn[:600]),
):
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
print("PASS: reduced-motion reorder slide snap (no spring travel)")

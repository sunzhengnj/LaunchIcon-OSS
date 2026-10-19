#!/usr/bin/env python3
"""Guard: reduced-motion dissolved-folder grid fade-in snaps (no half-fade)."""
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


need("shouldSnapDissolvedGridFadeForReducedMotion" in core, "Core missing snap gate")
need("dissolvedGridFadeDuration" in core, "Core missing duration policy")
need("testDissolvedGridFadeSnapsUnderReducedMotion" in tests, "Core test missing")

# Duration policy returns 0 when reduced
dur = core[
    core.index("public static func dissolvedGridFadeDuration(") : core.index(
        "public static func dissolvedGridFadeDuration("
    )
    + 450
]
need("shouldSnapDissolvedGridFadeForReducedMotion" in dur, "duration must consult snap gate")
need("return 0" in dur, "reduced must return duration 0")
need("return 0.22" in dur, "full motion must keep 0.22")

# Direct: no prefersReducedMotion ? 0.12 half-fade leftover
need(
    "prefersReducedMotion ? 0.12 : 0.22" not in direct,
    "must not keep prefersReducedMotion ? 0.12 : 0.22 half-fade",
)
need("shouldSnapDissolvedGridFadeForReducedMotion" in direct, "Direct must consult snap gate")
need("dissolvedGridFadeDuration" in direct, "Direct must use Core duration")

# Locate dissolved fade play block via finishDissolvedGridFade nearby with snap
idx = direct.index("if snapDissolvedGridFade")
chunk = direct[idx : idx + 900]
need("finishDissolvedGridFade()" in chunk, "snap must finishDissolvedGridFade")
need("fadeViewOpacityFromPresentation" in chunk, "full motion must still fade")
# Snap branch before fadeViewOpacity
snap_fin = chunk.index("finishDissolvedGridFade()")
fade_at = chunk.index("fadeViewOpacityFromPresentation")
need(snap_fin < fade_at, "snap finish must precede full-motion fade")

for label, piece in (
    ("Core", dur),
    ("Direct snap", chunk[:400]),
):
    need(
        "showPage(" not in piece
        and "pageTransition" not in piece
        and "pageAnimationDuration" not in piece,
        f"{label} must not retune paging",
    )

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: reduced-motion dissolved-grid fade snap (no half-fade)")

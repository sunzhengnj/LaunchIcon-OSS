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

# DISSOLVED-GRID-FADE-FINISH-WHEN-HIDDEN-01: a hidden window never pinned the
# named fade. Finish it from applyDeferred. Lookup reads an existing layer.
need("shouldFinishUnpinnedDissolvedGridFade" in core, "Core missing hidden-fade finish")
need("DISSOLVED-GRID-FADE-FINISH-WHEN-HIDDEN-01" in core, "Core missing hidden-fade marker")
need("testDissolvedGridFadeFinishesWhenHiddenWithoutWaitFlag" in tests, "Core test missing hidden-fade finish")
need("shouldFinishUnpinnedDissolvedGridFade" in direct, "Direct must finish an unpinned hidden fade")
need("dissolvedGridFadeAnimationIsAttached" in direct, "Direct must look up the named fade")
lookup = direct[direct.index("func dissolvedGridFadeAnimationIsAttached"):
                direct.index("func dissolvedGridFadeAnimationIsAttached") + 500]
need("wantsLayer = true" not in lookup, "fade lookup must not create a layer")
need("view.layer?" in lookup, "fade lookup must read an existing layer")
need("dissolvedGridFadeAnimationKey" in lookup, "fade lookup must use the named key")
need("showPage(" not in lookup and "transitionToPage(" not in lookup and "completePageTransition(" not in lookup,
     "fade lookup must not retune paging")
deferred = direct[direct.index("func applyDeferredDissolvedGridFade"):
                  direct.index("func dissolvedGridFadeAnimationIsAttached")]
need("shouldFinishUnpinnedDissolvedGridFade" in deferred, "applyDeferred must ask the hidden-fade gate")
need("showPage(" not in deferred and "transitionToPage(" not in deferred and "completePageTransition(" not in deferred,
     "applyDeferred dissolved fade must not retune paging")
prep = direct[direct.index("func prepareChromeForOpeningSettings()"):
              direct.index("func cancelIconLoadsForSettingsWhileLauncherHidden")]
need("shouldFinishUnpinnedDissolvedGridFade" not in prep, "prepareChrome must not finish the dissolved fade")
need("dissolvedGridFadeAnimationIsAttached" not in prep, "prepareChrome must not look up the dissolved fade")

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

#!/usr/bin/env python3
"""Settings handoff settles reorder slides and merge flights inside hide()."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = "".join(p.read_text(encoding="utf-8") for p in [ROOT / "Sources/Direct/LauncherWindowController.swift", *sorted((ROOT / "Sources/Direct").glob("LauncherWindowController+*.swift"))])


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "SETTINGS-HANDOFF-SETTLE-VIA-HIDE-01" not in core:
    fail("Core missing SETTINGS-HANDOFF-SETTLE-VIA-HIDE-01")

helper_i = direct.find("func settleInFlightVisualsForDismissal()")
if helper_i < 0:
    fail("missing settleInFlightVisualsForDismissal")
helper = direct[helper_i : helper_i + 4500]
for token in (
    "REORDER-SLIDE-SETTLE-ON-SETTINGS-OPEN-01",
    "settleReorderSlideForDismissal()",
    "MERGE-FLIGHT-SETTLE-ON-SETTINGS-OPEN-01",
    "settleMergeFlightForDismissal()",
    "FOLDER-CHROME-SETTLE-VIA-HIDE-01",
    "settleFolderChromeForDismissal()",
    "DISSOLVED-GRID-FADE-SETTLE-VIA-HIDE-01",
    "settleDissolvedGridFadeForDismissal()",
):
    if token not in helper:
        fail(f"shared settle helper missing {token}")

hide_i = direct.find("func hide(animated: Bool = true)")
hide_end = direct.find("\n    /// DOCK-REVEAL-EDGE-01", hide_i)
if hide_end < 0:
    hide_end = hide_i + 12000
hide = direct[hide_i:hide_end]
if "settleInFlightVisualsForDismissal()" not in hide:
    fail("hide() does not call the shared settle helper")
if "settleReorderSlideForDismissal()" in hide or "settleMergeFlightForDismissal()" in hide:
    fail("hide() still lists settle calls outside the helper")

prep_i = direct.find("func prepareChromeForOpeningSettings()")
prep_end = direct.find("\n    @objc private func openSettings()", prep_i)
prep = direct[prep_i:prep_end]
for token in (
    "settleReorderSlideForDismissal()",
    "settleMergeFlightForDismissal()",
    "settleFolderChromeForDismissal()",
    "settleDissolvedGridFadeForDismissal()",
):
    if token in prep:
        fail(f"prepareChrome still duplicates {token}")
if "SETTINGS-HANDOFF-SETTLE-VIA-HIDE-01" not in prep:
    fail("prepareChrome missing handoff comment")

if "func dismissalVisualResidue(" not in core:
    fail("Core missing dismissalVisualResidue")
residue = direct[direct.find("func reportDismissalVisualResidueForTest()"):]
residue = residue[: residue.find("#endif")]
for token in (
    "dismissalVisualResidue(",
    "dissolveScatterFlyerCount:",
    "dissolvedGridFadeStillHeld:",
    "folderChromeStillHeld:",
    "folderOverlayVisible:",
):
    if token not in residue:
        fail(f"dismissal residue report missing {token}")

for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    for ln in helper.splitlines() + prep.splitlines():
        if bad in ln and not ln.strip().startswith("//"):
            fail(f"paging red line {bad}: {ln.strip()}")

print("PASS: settings handoff reorder/merge settle via hide")

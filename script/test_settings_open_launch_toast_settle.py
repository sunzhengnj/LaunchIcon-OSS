#!/usr/bin/env python3
"""Settings handoff settles launch feedback and toast fade inside hide()."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


helper_i = direct.find("func settleInFlightVisualsForDismissal()")
helper = direct[helper_i : helper_i + 4500]
for token in (
    "LAUNCH-FEEDBACK-SETTLE-ON-SETTINGS-OPEN-01",
    "settleLaunchFeedbackForDismissal()",
    "TOAST-FADE-SETTLE-ON-SETTINGS-OPEN-01",
    "settleToastFadeForDismissal()",
):
    if token not in helper:
        fail(f"shared settle helper missing {token}")

prep_i = direct.find("func prepareChromeForOpeningSettings()")
prep_end = direct.find("\n    @objc private func openSettings()", prep_i)
prep = direct[prep_i:prep_end]
for token in (
    "settleLaunchFeedbackForDismissal()",
    "settleToastFadeForDismissal()",
):
    if token in prep:
        fail(f"prepareChrome still duplicates {token}")

for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    for ln in helper.splitlines():
        if bad in ln and not ln.strip().startswith("//"):
            fail(f"paging red line {bad}: {ln.strip()}")

print("PASS: settings handoff launch feedback / toast fade settle via hide")

#!/usr/bin/env python3
"""Guard: toast opacity-before-unhide + interrupted restore (status/footer/settings parity)."""
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

need("toastShouldClearOpacityBeforeUnhide" in core, "Core missing toastShouldClearOpacityBeforeUnhide")
need("toastShouldRestoreOpacityWhenAlreadyShown" in core, "Core missing toastShouldRestoreOpacityWhenAlreadyShown")
need("testToastClearAndRestoreOpacityParityWithStatus" in tests, "Core test missing")

start = direct.index("private func presentToast(")
end = direct.index("func hideToast(animated:", start)
body = direct[start:end]
need("toastShouldClearOpacityBeforeUnhide" in body, "presentToast must use clear-before-unhide gate")
need("toastShouldRestoreOpacityWhenAlreadyShown" in body, "presentToast must restore interrupted fade")
need("presentation()?.opacity" in body, "presentToast must read presentation opacity")
# Must not unconditionally snap to 0 when already shown
# Find restore branch exists alongside clear branch
need(body.count("fadeViewOpacityFromPresentation") >= 1, "presentToast must fade from presentation")

hide = direct[direct.index("private func performToastHide"):direct.index("private func snapInFlightToastFadeForMotionChange")]
need("Park alpha at 1 while hidden" in hide or ("isHidden = true" in hide and "alphaValue = 1" in hide),
     "hide completion must park opacity at 1 while hidden")

for label, chunk in (("presentToast", body), ("Core toast gates", core[core.index("toastShouldClearOpacityBeforeUnhide"):core.index("toastShouldClearOpacityBeforeUnhide")+500])):
    need("showPage(" not in chunk and "pageTransition" not in chunk and "pageAnimationDuration" not in chunk,
         f"{label} must not retune paging")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: toast fade parity (opacity-before-unhide + interrupted restore)")

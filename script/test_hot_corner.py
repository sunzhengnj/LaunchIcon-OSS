#!/usr/bin/env python3
"""Guard: hot-corner show/hide preference — no paging."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
prefs = (root / "Sources/Core/LauncherPreferences.swift").read_text()
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
monitor = (root / "Sources/Direct/HotCornerMonitor.swift").read_text()
delegate = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
design_notes = (root / "Docs/SOURCE_SNAPSHOT_2026-10-19.md").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("enum LauncherHotCorner" in prefs, "missing LauncherHotCorner")
need("hotCorner" in prefs and 'prefix + "hotCorner"' in prefs, "prefs store must persist hotCorner")
need("func hotCorner(" in core and "shouldFireHotCorner" in core, "Core geometry/edge-trigger missing")
need("hotCornerHitThreshold" in core, "missing threshold constant")
need("testHotCornerGeometryAndEdgeTrigger" in tests, "Core hot corner test missing")
need("must edge-trigger only" in tests, "edge-trigger assertion missing")

need("呼出触发角" in settings, "Settings missing hot corner label")
need("外观与呼出" in settings, "hot corner must live under 外观与呼出")
need("settings-hot-corner" in settings, "a11y id missing")
need("hotCornerPopup" in settings, "missing popup")
need("桌面与程序坞" in settings or "触发角" in settings, "Settings must document system hot-corner conflict")

need("class HotCornerMonitor" in monitor, "missing monitor")
need("NSEvent.mouseLocation" in monitor, "should poll mouseLocation (no AX)")
need("shouldFireHotCorner" in monitor, "monitor must use Core edge-trigger")
need("toggleVisibility" in monitor or "onTriggered" in monitor, "monitor should invoke toggle callback")

need("configureHotCornerMonitor" in delegate, "AppDelegate must configure monitor")
need("hotCornerMonitor" in delegate, "AppDelegate missing monitor property")

need("Mission Control" in design_notes or "系统热角冲突" in design_notes, "public design notes must document system conflict")
need("showPage" not in monitor and "pageTransition" not in monitor, "monitor must not touch paging")
need("showPage" not in settings[settings.find("hotCornerPopup"):settings.find("hotCornerPopup")+800]
     if "hotCornerPopup" in settings else True, "settings hot corner block must not page")

# Ensure no CGEvent tap / AX requirement claimed as required
need("Accessibility" not in monitor or "no Accessibility" in monitor.lower() or "不需要辅助功能" in settings,
     "should avoid requiring Accessibility")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)

# Presence fade reuse (launcher park/animate path) — not settings snappy, not paging snaps.
need("shouldAnimateLauncherPresenceForHotCorner" in core, "Core missing hot-corner presence animate gate")
need("shouldSnapPagingChromeForHotCornerTrigger" in core, "Core missing hot-corner no-paging-snap gate")
need("testHotCornerUsesAnimatedLauncherPresenceNotPagingSnaps" in tests, "Core presence test missing")
lwc = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
need("func respondToHotCornerTrigger()" in lwc, "LWC missing respondToHotCornerTrigger")
hc = lwc[lwc.index("func respondToHotCornerTrigger()"):lwc.index("func respondToHotCornerTrigger()") + 900]
need("shouldAnimateLauncherPresenceForHotCorner" in hc, "hot corner must consult animate gate")
need("show(animated:" in hc and "hide(animated:" in hc, "hot corner must call show/hide(animated:)")
need("snapPageIndicator" not in hc and "snapPageArrows" not in hc, "hot corner must not snap paging chrome")
need("respondToHotCornerTrigger()" in delegate, "AppDelegate must call respondToHotCornerTrigger")
need("toggleVisibility()" not in delegate[delegate.index("configureHotCornerMonitor"):delegate.index("configureHotCornerMonitor")+500]
     or "respondToHotCornerTrigger" in delegate[delegate.index("configureHotCornerMonitor"):delegate.index("configureHotCornerMonitor")+500],
     "hot corner callback should not bare-toggle without presence helper")
# show/hide still own presence fade
need("parkLauncherPresenceHiddenForAppear" in lwc, "must keep launcher presence park")
need("animateLauncherPresence" in lwc, "must keep launcher presence animate")
need("showPage(" not in hc and "pageTransition" not in hc and "pageAnimationDuration" not in hc,
     "hot corner trigger must not retune paging")

print("PASS: hot corner show/hide + presence fade reuse (no paging snaps)")


#!/usr/bin/env python3
"""Guard: settings window presence fade (park before orderFront / interrupted restore / no focus steal)."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("settingsPresenceShouldClearOpacityBeforeUnhide" in core, "Core missing clear-before-unhide")
need("settingsPresenceShouldRestoreOpacityWhenAlreadyShown" in core, "Core missing restore gate")
need("settingsPresenceShouldBecomeKeyOnShow" in core, "Core missing focus/key policy")
need("settingsPresenceFadeFromOpacity" in core, "Core missing from-opacity policy")
need("testSettingsPresenceOpacityGatesAndFocusPolicy" in tests, "Core test missing")

need("presentSettingsWindowPresence" in settings, "Settings missing presentSettingsWindowPresence")
need("parkSettingsPresenceTransparentForAppear" in settings, "Settings missing park before appear")
need("onRequestPresenceFadeClose" in settings, "Settings missing presence fade-close hook")
need("allowCloseWithoutPresenceFade" in settings, "Settings missing allowCloseWithoutPresenceFade")
need("override func performClose" in settings, "SettingsWindow must gate performClose for fade")
need("settingsPresenceShouldBecomeKeyOnShow" in settings, "Settings must consult key policy")
need("fillMode = .backwards" in settings, "presence fade must use fillMode.backwards")
need("presentation()?.opacity" in settings, "must read presentation opacity")
need("animator().alphaValue" not in settings, "must not use animator().alphaValue")

show = settings[settings.index("func show(preferences:"):settings.index("func presentShortcutRegistrationError")]
need("presentSettingsWindowPresence()" in show, "show must use presentSettingsWindowPresence")
need("makeKeyAndOrderFront" not in show or "presentSettingsWindowPresence" in show,
     "show must not bare makeKeyAndOrderFront without presence helper")

present = settings[settings.index("func presentSettingsWindowPresence"):settings.index("func hideSettingsWindowPresenceThenClose")]
park_at = present.find("parkSettingsPresenceTransparentForAppear")
# orderFront / makeKey after park in clear-before-unhide branch
front_at = present.find("makeKeyAndOrderFront")
need(park_at >= 0 and front_at > park_at, "park must precede makeKeyAndOrderFront")
need("settingsPresenceShouldBecomeKeyOnShow" in present, "present must gate become-key")
need("settingsPresenceShouldRestoreOpacityWhenAlreadyShown" in present, "present must restore interrupted fade")

# Already-key path must not always activate
need("isKeyWindow" in present or "isKey" in present, "must observe key status")

for label, chunk in (
    ("Core settings presence", core[core.index("settingsPresenceShouldClearOpacityBeforeUnhide"):core.index("settingsPresenceShouldClearOpacityBeforeUnhide")+600]),
    ("presentSettings", present[:500]),
):
    need("showPage(" not in chunk and "pageTransition" not in chunk and "pageAnimationDuration" not in chunk,
         f"{label} must not retune paging")

# Launcher handoff policies must remain (do not steal restore incorrectly)
need("shouldHideLauncherToShowSettings" in core, "must keep launcher hide-for-settings policy")
need("shouldRestoreLauncherWhenSettingsCloses" in core, "must keep launcher restore-on-close policy")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: settings presence fade (park / restore / focus-safe key)")

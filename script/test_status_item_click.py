#!/usr/bin/env python3
"""Guard: STATUS-ITEM-CLICK-01 + OPTION-SETTINGS — left toggles; right menu; Option+left Settings."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
delegate = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("STATUS-ITEM-CLICK-01" in core, "Core missing STATUS-ITEM-CLICK-01 marker")
need("StatusItemPointerKind" in core, "Core missing StatusItemPointerKind")
need("StatusItemButtonAction" in core, "Core missing StatusItemButtonAction")
need("statusItemButtonAction" in core, "Core missing statusItemButtonAction")
need("testStatusItemButtonActionPrimaryTogglesSecondaryShowsMenu" in tests, "Core test missing")

need("statusItemButtonActivated" in delegate, "Direct must handle button activation")
need("statusItemPointerKind" in delegate, "Direct must map NSEvent to pointer kind")
need("presentStatusMenu" in delegate, "Direct must pop status menu on secondary click")
need("statusMenu" in delegate, "Direct must keep statusMenu separate from item.menu")
need("sendAction(on: [.leftMouseUp, .rightMouseUp])" in delegate,
     "button must receive left and right mouse up")

cfg = delegate[delegate.index("private func configureStatusItem()"):
               delegate.index("private func statusItemButtonActivated")]
need("item.menu =" not in cfg and "item.menu=" not in cfg,
     "configureStatusItem must not assign item.menu (would steal left click)")
need("button?.action = #selector(statusItemButtonActivated" in cfg
     or "item.button?.action = #selector(statusItemButtonActivated" in cfg,
     "button action must be statusItemButtonActivated")


need("STATUS-ITEM-OPTION-SETTINGS-01" in core or "openSettings" in core, "Core missing Option→Settings action")
need("case .openSettings" in delegate or "openSettings()" in delegate, "Direct must open Settings on Option+primary")
need("optionDown" in core and "optionDown" in delegate, "optionDown must flow Core←Direct")

# No paging retune in the click path
chunk = delegate[delegate.index("statusItemButtonActivated"):
                 delegate.index("private func menuModifiers")]
need("showPage(" not in chunk and "pageTransition" not in chunk and "pageAnimationDuration" not in chunk,
     "status-item click path must not retune paging")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: STATUS-ITEM-CLICK-01 + OPTION-SETTINGS")

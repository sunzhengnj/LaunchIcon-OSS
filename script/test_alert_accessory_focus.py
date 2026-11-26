#!/usr/bin/env python3
"""ALERT-ACCESSORY-FOCUS-01: alias/folder rename alerts focus the name field."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

if "ALERT-ACCESSORY-FOCUS-01" not in direct:
    fail("missing slice tag")
if direct.count("makeFirstResponder(field)") < 2:
    fail("both alias and folder rename must makeFirstResponder(field)")
if "promptForAlias" not in direct or "promptForFolderName" not in direct:
    fail("prompt helpers missing")
# Ensure layout precedes makeFirstResponder in both sites (rough order check)
for fn in ("promptForAlias", "promptForFolderName"):
    i = direct.index(f"func {fn}")
    # ALIAS-FOLDER-PROMPT-COPY-01 lengthened the prompt bodies; keep the
    # layout/focus order check over a window large enough for Core wiring.
    chunk = direct[i:i+2400]
    if "alert.layout()" not in chunk:
        fail(f"{fn} must layout() before focus")
    if chunk.index("alert.layout()") > chunk.index("makeFirstResponder(field)"):
        fail(f"{fn}: layout must precede makeFirstResponder")
    for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
        if bad in chunk:
            fail(f"paging symbol {bad} in {fn} — refuse")

# ALERT-MODAL-KEY-01: the floating panel must not steal key from runModal alerts.
if "ALERT-MODAL-KEY-01" not in direct or "ALERT-MODAL-KEY-01" not in core:
    fail("missing ALERT-MODAL-KEY-01 slice tag")
if "func launcherPanelWorksWhenModal()" not in core:
    fail("Core must define launcherPanelWorksWhenModal")
if "func launcherPanelCanBecomeKey(otherApplicationModalWindow:" not in core:
    fail("Core must define launcherPanelCanBecomeKey")
if "override var worksWhenModal" not in direct:
    fail("LauncherPanel must override worksWhenModal")
if "launcherPanelWorksWhenModal()" not in direct:
    fail("LauncherPanel.worksWhenModal must consult Core policy")
if "launcherPanelCanBecomeKey(" not in direct:
    fail("LauncherPanel.canBecomeKey must consult Core policy")
if "NSApp.modalWindow" not in direct:
    fail("canBecomeKey must observe NSApp.modalWindow")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    start = core.index("func launcherPanelWorksWhenModal()")
    chunk = core[start:start+800]
    if bad in chunk:
        fail(f"paging symbol {bad} in ALERT-MODAL-KEY-01 — refuse")

delegate = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")
uninstall = (ROOT / "Sources/Direct/UninstallCoordinator.swift").read_text(encoding="utf-8")
# worksWhenModal=false must not be papered over by making Settings a sheet on
# the launcher, and must still cover uninstall runModal alerts.
if "shouldHideLauncherToShowSettings" not in delegate or ".hide(" not in delegate:
    fail("Settings must hide the launcher rather than sheet on the panel")
if "beginSheet" in delegate and "showSettings" in delegate[delegate.index("func showSettings"):delegate.index("func showSettings")+2500]:
    # only fail if showSettings itself begins a sheet on the launcher
    chunk = delegate[delegate.index("func showSettings"):delegate.index("func showSettings")+2500]
    if "beginSheet" in chunk:
        fail("showSettings must not begin a sheet on the launcher panel")
if "NSMenu.popUpContextMenu" not in direct:
    fail("icon context menus must stay popUpContextMenu (not runModal)")
if "runModal()" not in uninstall:
    fail("uninstall confirmation must stay application-modal (runModal)")

print("PASS: alert accessory focus")

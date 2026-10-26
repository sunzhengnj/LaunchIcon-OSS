#!/usr/bin/env python3
"""SETTINGS-BACKUP-ENABLE-AFTER-REARRANGE-01

After Settings rearrange, 「恢复上次备份」 must wait for LayoutStore's
debounced save before re-enabling — otherwise the button stays gray until
Settings is reopened even though layout-v1.backup.json already exists.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text()
wc = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text()
delegate = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text()

errors: list[str] = []

if "func awaitPendingLayoutPersist() async" not in wc:
    errors.append("WC missing awaitPendingLayoutPersist")
wc_tail = wc.split("func awaitPendingLayoutPersist() async", 1)[1][:300]
if "await finishPendingLayoutSaves()" not in wc_tail:
    errors.append("awaitPendingLayoutPersist must call finishPendingLayoutSaves")

if "var onAwaitLayoutPersist" not in settings:
    errors.append("Settings missing onAwaitLayoutPersist")
if "func refreshLayoutBackupControlsAfterPersist()" not in settings:
    errors.append("Settings missing refreshLayoutBackupControlsAfterPersist helper")
if "await onAwaitLayoutPersist?()" not in settings:
    errors.append("helper must await onAwaitLayoutPersist")

# Success paths must call the after-persist helper (not a bare immediate refresh).
checks = [
    ("name/kind", r"if onRearrangeTopLevel\(sort\) \{.{0,400}?\} else"),
    ("category", r"if onRearrangeByCategory\(\) \{.{0,400}?\} else"),
    ("date", r"let ok = await onRearrangeByDate\(kind\).{0,500}?\} else"),
    ("color", r"let ok = await onRearrangeByColor\(\).{0,500}?\} else"),
]
for label, pattern in checks:
    m = re.search(pattern, settings, re.S)
    if not m:
        errors.append(f"{label}: rearrange success block not found")
        continue
    block = m.group(0)
    if "refreshLayoutBackupControlsAfterPersist()" not in block:
        errors.append(f"{label}: must call refreshLayoutBackupControlsAfterPersist()")
    # Strip the after-persist call; a leftover bare refresh on the success arm is the race.
    stripped = block.replace("refreshLayoutBackupControlsAfterPersist()", "")
    if "refreshLayoutBackupControls()" in stripped:
        errors.append(f"{label}: still calls bare refreshLayoutBackupControls() on success")

if "onAwaitLayoutPersist =" not in delegate:
    errors.append("AppDelegate must wire onAwaitLayoutPersist")
if "awaitPendingLayoutPersist" not in delegate:
    errors.append("AppDelegate wire must call awaitPendingLayoutPersist")

if errors:
    print("FAIL SETTINGS-BACKUP-ENABLE-AFTER-REARRANGE-01")
    for e in errors:
        print(" -", e)
    sys.exit(1)
print("OK SETTINGS-BACKUP-ENABLE-AFTER-REARRANGE-01")

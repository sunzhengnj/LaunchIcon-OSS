#!/usr/bin/env python3
"""Static guard for the session-only new-app dot (NEW-APP-BADGE-01)."""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text()
CORE = (ROOT / "Sources/Core/LauncherLayout.swift").read_text()
fail = []

def body(name):
    m = re.search(r"func " + re.escape(name) + r"\(.*?\n    \}\n", SRC, re.S)
    if not m:
        fail.append(f"missing func {name}")
        return ""
    return m.group(0)

for token in ("static func newlyAddedAppKeys(", "static func showsNewAppBadge("):
    if token not in CORE:
        fail.append(f"core missing {token}")
for token in (
    "rootView.markNewApps(LauncherLayout.newlyAddedAppKeys(previous: base, reconciled: layout))",
    "rootView.clearNewApp(key)",
    "tile.isNewAppKey = {",
    "LauncherLayout.showsNewAppBadge(",
):
    if token not in SRC:
        fail.append(f"wiring missing {token}")
banned = ("reloadData", "reloadItems", "scrollToPage", "setPage", "currentPage", "alphaValue", "frame =", "invalidateLayout", "animator()")
for name in ("markNewApps", "clearNewApp", "refreshNewAppBadges", "setTitleText", "refreshNewAppBadge"):
    b = body(name)
    for t in banned:
        if t in b:
            fail.append(f"{name} uses banned {t}")
if "refreshNewAppBadges" in body("clearNewApp"):
    fail.append("clearNewApp must not walk tiles on the launch click stack")
if 'titleLabel.stringValue = L("正在启动…")' in SRC:
    fail.append("launch title must go through setTitleText")
if fail:
    print("FAIL: new app badge\n  " + "\n  ".join(fail))
    sys.exit(1)
print("PASS: new app badge wiring")

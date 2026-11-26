#!/usr/bin/env python3
"""SETTINGS-CLEAR-SELECTION-01 / SETTINGS-OPEN-DEDUPE-CALLS-01.

Opening Settings drops multi-select once, from showSettings(). Gear, blank
menu, ⌘,, and the root callback only forward onSettingsRequested.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
app = (root / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")
fails = []


def need(cond, msg):
    if not cond:
        fails.append(msg)


def block(src: str, signature: str) -> str:
    i = src.find(signature)
    if i < 0:
        fails.append(f"missing {signature}")
        return ""
    j = src.find("{", i)
    depth = 0
    for k in range(j, len(src)):
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                return src[j : k + 1]
    fails.append(f"unbalanced {signature}")
    return ""


def call_count(src: str, name: str) -> int:
    count = 0
    start = 0
    while True:
        i = src.find(name, start)
        if i < 0:
            return count
        if not src[max(0, i - 5) : i].endswith("func "):
            count += 1
        start = i + len(name)


need("shouldClearSelectionWhenOpeningSettings" in core, "Core gate")
need("SETTINGS-CLEAR-SELECTION-01" in direct, "Direct slice marker")
need("SETTINGS-OPEN-DEDUPE-CALLS-01" in direct, "dedupe marker")
need("clearSelectionBeforeOpeningSettings" in direct, "Direct helper")
need(call_count(app, "clearSelectionBeforeOpeningSettings()") == 1, "showSettings clears once")

need(
    "shouldClearSelectionWhenOpeningSettings" in direct
    and "refreshItemSelectionChrome(announce: false)" in direct,
    "root clears without VO spam",
)

for signature in (
    "panel.settingsHandler = {",
    "rootView.onSettingsRequested = {",
    "@objc private func openSettings()",
    "func openSettingsFromBlankAreaMenu()",
):
    body = block(direct, signature)
    need("clearSelectionBeforeOpeningSettings" not in body, f"{signature} must not clear")
    need("onSettingsRequested" in body, f"{signature} must forward settings")

need(
    call_count(direct, "clearSelectionBeforeOpeningSettings()") == 1,
    "Direct calls clearSelection once (window → root)",
)
window_clear = block(direct, "func clearSelectionBeforeOpeningSettings()")
need(
    "rootView.clearSelectionBeforeOpeningSettings()" in window_clear,
    "window clear forwards to root",
)

if fails:
    print("FAIL: settings clear selection")
    for item in fails:
        print("-", item)
    sys.exit(1)
print("PASS: settings clear selection once")

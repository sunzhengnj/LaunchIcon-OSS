#!/usr/bin/env python3
"""KEYBOARD-HIGHLIGHT-CROSS-PAGE-01: main-grid U/D at edge pages via tile onPage."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


def body(text, start, end):
    i = text.index(start)
    return text[i : text.index(end, i + len(start))]


need("KEYBOARD-HIGHLIGHT-CROSS-PAGE-01" in direct, "cross-page marker")
step = body(direct, "func stepGridKeyboard(", "func focusPresentedItem(")
for banned in ("showPage", "movePage", "transitionToPage", "completePageTransition"):
    need(banned not in step, f"step must not call paging ({banned})")
need("direction == .up || direction == .down" in step, "U/D edge decline missing")
need("return false" in step, "must decline so tile pages")

tile = body(direct, "override func keyDown(with event: NSEvent) {\n        // NSView.keyDown",
            "override func insertTab")
need("case 123, 116, 126:" in tile, "Up must page when walk declines")
need("case 124, 121, 125:" in tile, "Down must page when walk declines")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: keyboard highlight cross-page")

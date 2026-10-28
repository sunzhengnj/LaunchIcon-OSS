#!/usr/bin/env python3
"""FOLDER-FOCUS-REVEAL-01: keyboard focus shows the whole folder or search cell."""
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


def body(text, start, end):
    i = text.index(start)
    return text[i : text.index(end, i + len(start))]


need("func scrollOffsetRevealingItem(" in core, "Core reveal offset missing")
need("testScrollOffsetRevealingItemShowsTheWholeCell" in tests, "Core reveal test missing")

offset = body(core, "public static func scrollOffsetRevealingItem(", "public static func visiblePageIndices(")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    need(banned not in offset, f"reveal offset must not page ({banned})")

reveal = body(direct, "private func revealScrollingItem(", "private func focusAdjacentPresentedItem(")
need("scrollOffsetRevealingItem(" in reveal, "reveal must ask Core for the offset")
need("nearestVerticalEdge" not in reveal, "reveal must not use the nearest edge")
need("clip.scroll(to:" in reveal, "reveal must set the clip offset")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    need(banned not in reveal, f"reveal must not page ({banned})")

for name in (
    "private func focusAdjacentPresentedItem(",
    "private func focusPresentedItem(",
    "private func scrollSearchKeyboardHighlightIntoViewIfNeeded(",
    "private func focusSearchResult(",
):
    # Each helper ends at the next private func. The search ones are private func too.
    start = direct.index(name)
    nxt = direct.index("\n    private func ", start + len(name))
    chunk = direct[start:nxt]
    need("revealScrollingItem(" in chunk, f"{name} must reveal the whole cell")
    need("nearestVerticalEdge" not in chunk, f"{name} must not use the nearest edge")
    for banned in ("showPage", "movePage", "transitionToPage"):
        need(banned not in chunk, f"{name} must not page ({banned})")

if failures:
    print("FAIL: folder focus reveal")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: folder focus reveal")

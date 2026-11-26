#!/usr/bin/env python3
"""Search/hover settle lives in hide(); icon-load cancel is not duplicated."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = "".join(p.read_text(encoding="utf-8") for p in [ROOT / "Sources/Direct/LauncherWindowController.swift", *sorted((ROOT / "Sources/Direct").glob("LauncherWindowController+*.swift"))])
app = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


def blocks(src: str, signature: str) -> list[str]:
    found = []
    start = 0
    while True:
        i = src.find(signature, start)
        if i < 0:
            break
        j = src.find("{", i)
        if j < 0:
            fail(f"no body for {signature}")
        depth = 0
        for k in range(j, len(src)):
            if src[k] == "{":
                depth += 1
            elif src[k] == "}":
                depth -= 1
                if depth == 0:
                    found.append(src[j : k + 1])
                    start = k + 1
                    break
        else:
            fail(f"unbalanced {signature}")
    return found


for token in (
    "ICON-PREFETCH-CANCEL-ON-SETTINGS-OPEN-01",
    "shouldCancelIconPrefetchWhenOpeningSettings",
    "TILE-ICON-CANCEL-ON-SETTINGS-OPEN-01",
    "shouldCancelTileIconLoadsWhenOpeningSettings",
    "SETTINGS-HANDOFF-SETTLE-VIA-HIDE-01",
    "SETTINGS-OPEN-DEDUPE-CALLS-01",
):
    if token not in core:
        fail(f"Core missing {token}")

if "testSettingsOpenSearchChromeHoverPrefetchCancelGates" not in tests:
    fail("Core test missing")

helper_i = direct.find("func settleInFlightVisualsForDismissal()")
helper = direct[helper_i : helper_i + 4500]
for token in (
    "SEARCH-CHROME-SETTLE-ON-SETTINGS-OPEN-01",
    "settleSearchChromeForDismissal()",
    "PAGE-BUTTON-HOVER-SETTLE-ON-SETTINGS-OPEN-01",
    "settlePageButtonHoverForDismissal()",
):
    if token not in helper:
        fail(f"shared settle helper missing {token}")

prep = blocks(direct, "func prepareChromeForOpeningSettings()")
if len(prep) != 1:
    fail(f"expected one prepareChrome, found {len(prep)}")
for token in (
    "cancelIconPrefetchBecauseLauncherIsDismissing",
    "cancelTileIconLoadsBecauseLauncherIsDismissing",
    "settleSearchChromeForDismissal()",
    "settlePageButtonHoverForDismissal()",
):
    if token in prep[0]:
        fail(f"prepareChrome still duplicates {token}")
if "SETTINGS-OPEN-DEDUPE-CALLS-01" not in prep[0]:
    fail("prepareChrome missing dedupe comment")

hidden = blocks(direct, "func cancelIconLoadsForSettingsWhileLauncherHidden()")
if len(hidden) != 2:
    fail(f"expected window + root cancel helpers, found {len(hidden)}")
if "rootView.cancelIconLoadsForSettingsWhileLauncherHidden()" not in hidden[0]:
    fail("window helper must forward to the root helper")
root_hidden = hidden[1]
for token in (
    "shouldCancelIconPrefetchWhenOpeningSettings",
    "cancelIconPrefetchBecauseLauncherIsDismissing",
    "shouldCancelTileIconLoadsWhenOpeningSettings",
    "cancelTileIconLoadsBecauseLauncherIsDismissing",
):
    if token not in root_hidden:
        fail(f"hidden-launcher cancel missing {token}")

show = blocks(app, "private func showSettings()")
if len(show) != 1:
    fail("showSettings missing")
body = show[0]
if body.count("clearSelectionBeforeOpeningSettings()") != 1:
    fail("showSettings must clear selection once")
if body.count("cancelIconLoadsForSettingsWhileLauncherHidden()") != 1:
    fail("showSettings must cancel icon loads once")
hide_at = body.find("shouldHideLauncherToShowSettings")
else_at = body.find("} else {", hide_at)
if hide_at < 0 or else_at < 0:
    fail("showSettings missing visible/hidden split")
visible = body[hide_at:else_at]
if ".hide(" not in visible:
    fail("visible Settings handoff must hide()")
if "cancelIconLoadsForSettingsWhileLauncherHidden" in visible:
    fail("visible handoff must not cancel icon loads outside hide()")
hidden_branch = body[else_at:]
if "cancelIconLoadsForSettingsWhileLauncherHidden()" not in hidden_branch:
    fail("hidden launcher must cancel icon loads once")

hide_i = direct.find("func hide(animated: Bool = true)")
hide = direct[hide_i : hide_i + 4500]
for token in (
    "cancelIconPrefetchBecauseLauncherIsDismissing",
    "cancelTileIconLoadsBecauseLauncherIsDismissing",
):
    if token not in hide:
        fail(f"hide() missing {token}")

for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    for ln in prep[0].splitlines() + helper.splitlines() + root_hidden.splitlines():
        if bad in ln and not ln.strip().startswith("//"):
            fail(f"paging red line {bad}: {ln.strip()}")

print("PASS: settings-open search/hover settle via hide; icon loads cancel once")

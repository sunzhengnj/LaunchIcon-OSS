#!/usr/bin/env python3
"""Guard: search-adjacent chrome interrupted-fade restore (count/settings/pill vs status/footer)."""
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

need("searchAdjacentChromeFadeAnimationKey" in core, "Core missing adjacent fade key")
need("searchAdjacentChromeShouldRestoreOpacityWhenAlreadyShown" in core, "Core missing adjacent restore gate")
need("searchAdjacentChromeShouldClearOpacityBeforeUnhide" in core, "Core missing adjacent clear gate")
need("testSearchAdjacentChromeRestoreParityWithStatus" in tests, "Core test missing")

need("searchAdjacentChromeGeneration" in direct, "Direct missing adjacent generation")
need(
    "searchAdjacentChromeFadeAnimationKey" != "statusChromeFadeAnimationKey",
    "keys must differ",
)
need(
    'searchAdjacentChromeFadeAnimationKey = "search-adjacent-chrome-fade"' in core
    or 'searchAdjacentChromeFadeAnimationKey = "search-adjacent' in core,
    "adjacent key must be distinct string",
)

adj = direct[
    direct.index("private func updateSearchAdjacentChrome(") : direct.index(
        "/// Catalog status message"
    )
]
need("searchAdjacentChromeGeneration" in adj, "adjacent must bump its own generation")
need("statusChromeGeneration &+= 1" not in adj, "adjacent must not bump status generation")
need("searchAdjacentChromeFadeAnimationKey" in adj, "adjacent must use its fade key")
need("searchAdjacentChromeShouldRestoreOpacityWhenAlreadyShown" in adj, "adjacent must use restore gate")
need("fadeKey: adjacentFadeKey" in adj, "count/settings/pill must pass adjacent fadeKey")
need("settingsButton" in adj and "searchChrome" in adj and "countLabel" in adj,
     "adjacent must drive count + settings + pill")

vis = direct[
    direct.index("private func setStatusChromeVisible(") : direct.index(
        "/// Show the page that is current"
    )
]
need("restoreGate" in vis, "setStatusChromeVisible must accept restoreGate")
need("statusChromeViewTokens[ObjectIdentifier(view)] == viewToken" in vis, "hide completion must be cancelled only by a later call for the same view")
need("live == generation" not in vis.split("if !visible {")[1].split("fadeViewOpacityFromPresentation")[0], "hide completion must not depend on shared generations")
need("fadeKey" in vis, "setStatusChromeVisible must use fadeKey param")

# Recovery buttons must still use status generation (not steal adjacent)
rec = direct[
    direct.index("private func updateRecoveryButtons(") : direct.index(
        "func setLayoutEditingEnabled("
    )
]
need("statusChromeGeneration &+= 1" in rec, "recovery must bump statusChromeGeneration")
need("searchAdjacentChromeGeneration" not in rec, "recovery must not use adjacent generation")

snap = direct[
    direct.index("func snapSearchAdjacentChromeForSettingsHandoffRestore(") : direct.index(
        "func snapSearchAdjacentChromeForSettingsHandoffRestore("
    )
    + 700
]
need("searchAdjacentChromeGeneration" in snap, "snap must bump adjacent generation")
need("searchAdjacentChromeFadeAnimationKey" in snap, "snap must clear adjacent fade key")

for label, chunk in (("Core adjacent", core[core.index("searchAdjacentChromeFadeAnimationKey"):core.index("searchAdjacentChromeFadeAnimationKey")+400]), ("updateSearchAdjacent", adj[:400])):
    need("showPage(" not in chunk and "pageTransition" not in chunk and "pageAnimationDuration" not in chunk,
         f"{label} must not retune paging")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: search-adjacent chrome interrupted-fade restore parity")

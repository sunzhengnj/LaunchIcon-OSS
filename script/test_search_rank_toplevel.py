#!/usr/bin/env python3
"""Guard: search prefers top-level apps over folder members at equal rank."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
models = (root / "Sources/Core/Models.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("topLevelAppDeduplicationKeys" in core, "Core missing topLevelAppDeduplicationKeys")
need("topLevelKeys" in models, "AppSearchIndex.filter must take topLevelKeys")
need("searchHitPlacementTier" in models, "missing equal-rank placement tiers")
need("testSearchPrefersTopLevelAppsOverFolderMembersAtEqualRank" in tests, "Core test missing")
need("topLevelAppDeduplicationKeys(in: layoutState)" in direct, "Direct must pass topLevelKeys")

idx = models.index("searchHitPlacementTier")
chunk = models[idx:idx + 400]
need("showPage" not in chunk and "pageTransition" not in chunk, "ranking must not touch paging")
idx2 = direct.index("topLevelAppDeduplicationKeys(in: layoutState)")
chunk2 = direct[max(0, idx2 - 200):idx2 + 200]
need("showPage" not in chunk2 and "pageTransition" not in chunk2,
     "Direct search filter wiring must not touch paging")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: search rank prefers top-level over folder members")

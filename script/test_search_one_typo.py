#!/usr/bin/env python3
"""Guard: SEARCH-ONE-TYPO-GUARD-01 — ≥5-char one-edit fallback ranks last."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
models = (root / "Sources/Core/Models.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


need("func matchesWithOneTypo" in models, "SearchText.matchesWithOneTypo")
need("func isWithinOneEdit" in models, "OSA distance helper")
need("testSearchToleratesOneTypoAfterAllRealMatches" in tests, "Core test")
# Rank 10 only when ranks.isEmpty (never reorders real hits)
idx = models.index("matchesWithOneTypo(query)")
# Look around matchRank one-typo branch
branch = models[models.index("if ranks.isEmpty"): models.index("if ranks.isEmpty") + 280]
need("return 10" in branch, "one-typo rank is 10")
need("matchesWithOneTypo" in branch, "branch calls typo matcher")
# Comment contract
need("one-typo" in models and "≥5" in models or ">=5" in models or "count >= 5" in models, "≥5 contract")
# Must not touch paging symbols near typo helpers
chunk = models[models.index("func matchesWithOneTypo"): models.index("func matchesWithOneTypo") + 1200]
for banned in ("showPage", "pageTransition", "PagingCollectionView", "scrollToPage"):
    need(banned not in chunk, f"typo matcher must not mention {banned}")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: search one-typo guard")

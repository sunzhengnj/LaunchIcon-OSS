#!/usr/bin/env python3
"""Guard: SEARCH-CMD-RETURN-REVEAL-01 (⌘↩ reveals search hit; no paging)."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []
def need(c, m):
    if not c: failures.append(m)
need("func searchRevealShortcutMatches(" in core, "Core missing searchRevealShortcutMatches")
need("SEARCH-CMD-RETURN-REVEAL-01" in core and "SEARCH-CMD-RETURN-REVEAL-01" in direct, "slice tag missing")
need("panel.searchRevealHandler" in direct, "panel handler not wired")
need("func revealSearchKeyboardHighlightOrFirst(" in direct, "root reveal missing")
need("testSearchRevealShortcutMatchesOnlyCommandReturnWhileSearching" in tests, "Core test missing")
fn = direct.split("func revealSearchKeyboardHighlightOrFirst(")[1].split("private func activateSearchKeyboardHighlightOrFirst")[0] if "func revealSearchKeyboardHighlightOrFirst(" in direct else ""
need("onRevealInFinderRequested" in fn, "must reuse onRevealInFinderRequested (dismiss + Finder)")
need("onCandidateSelected" not in fn, "⌘↩ must not launch")
for bad in ("movePage", "pageAnimationDuration", "PagingCollectionView", "currentPage =", "schedulePersist"):
    need(bad not in fn, f"slice must not touch {bad}")
if failures:
    print("FAIL:")
    for f in failures: print(" -", f)
    sys.exit(1)
print("PASS: search cmd-return reveal")

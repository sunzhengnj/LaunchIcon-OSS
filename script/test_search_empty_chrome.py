#!/usr/bin/env python3
"""Guard: search no-matches empty chrome in grid area (PRD), not status-line only."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
prd = (root / "Docs/LaunchIcon_PRD.md").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("未找到匹配的应用" in prd, "PRD must mention search empty copy")
need("enum LauncherEmptyChromeKind" in core, "Core missing empty chrome kind")
need("case searchNoMatches" in core, "Core missing searchNoMatches")
need("func emptyChromeKind(" in core, "Core missing emptyChromeKind")
need("testEmptyChromeKindSearchNoMatchesUsesGridNotStatusOnly" in tests, "Core test missing")

need("emptyChromeKind(" in direct, "Direct must use emptyChromeKind")
need(
    'L("未找到匹配的应用")' in direct
    or "CatalogEmptyChromeCopy" in direct and "searchNoMatchesTitleKey" in core,
    "Direct must show PRD title via literal or CatalogEmptyChromeCopy",
)
need(
    'L("按 Esc 清除搜索")' in direct
    or "searchNoMatchesDefaultDetailKey" in core and "CatalogEmptyChromeCopy.content(" in direct,
    "search empty detail should hint Esc via literal or CatalogEmptyChromeCopy",
)
need("func searchHiddenMatchHint(" in core and "testSearchHiddenMatchHint" in tests, "hidden-match hint Core + test")
need("LauncherLayout.searchHiddenMatchHint(" in direct, "search empty detail should explain hidden matches")
need("layoutState.hiddenAppKeys.isEmpty ? [] : hiddenApplications()" in direct, "skip hidden scan when nothing hidden")
need("kind: emptyKind" in direct, "setEmptyStateChrome must take kind")
need("search.empty" in direct, "search empty a11y id")

need('statusMessage = isSearching ? L("未找到匹配的应用，按 Esc 清除搜索")' not in direct,
     "must not use status-line-only search empty message")

idx = core.index("func emptyChromeKind(")
chunk = core[idx:idx + 700]
need("showPage" not in chunk and "pageTransition" not in chunk and "pageAnimation" not in chunk,
     "emptyChromeKind must not touch paging")

# setEmptyStateChrome must not keep old visible/cancelled-only API
start = direct.index("private func setEmptyStateChrome(")
sig = direct[start:start + 200]
need("kind: LauncherLayout.LauncherEmptyChromeKind?" in sig, "setEmptyStateChrome signature must take kind")
need("cancelled: Bool" not in sig, "old cancelled-only empty chrome API must go")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: search empty-result chrome")

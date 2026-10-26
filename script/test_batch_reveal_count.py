#!/usr/bin/env python3
"""Guard: BATCH-REVEAL-COUNT-01 (counted「在访达中显示（N）」; no paging)."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
strings = (root / "Resources/Localizable.xcstrings").read_text()
failures = []
def need(c, m):
    if not c: failures.append(m)
need("batchRevealMenuTitleFormatKey" in core, "Core missing batchRevealMenuTitleFormatKey")
need("BATCH-REVEAL-COUNT-01" in core, "Core must tag BATCH-REVEAL-COUNT-01")
need("BATCH-REVEAL-COUNT-01" in direct, "Direct must tag BATCH-REVEAL-COUNT-01")
need("batchRevealTitle" in direct, "Direct missing batchRevealTitle")
need("revealInFinderURLs(" in direct and "batchRevealTitle =" in direct, "reveal title must use revealInFinderURLs count")
need('L("在访达中显示")' in direct, "fallback「在访达中显示」must remain")
need('"在访达中显示（%d）"' in strings and '"Show in Finder (%d)"' in strings, "xcstrings missing")
need("testBatchRevealMenuTitleFormatKeyIncludesCount" in (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(), "Core test missing")
# No paging touch near the slice tag
chunk = direct.split("BATCH-REVEAL-COUNT-01")[1][:1200] if "BATCH-REVEAL-COUNT-01" in direct else ""
need("pageAnimationDuration" not in chunk and "PagingCollectionView" not in chunk, "slice must not touch paging")
if failures:
    print("FAIL:")
    for f in failures: print(" -", f)
    sys.exit(1)
print("PASS: batch reveal count")

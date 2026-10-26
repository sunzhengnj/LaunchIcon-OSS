#!/usr/bin/env python3
"""Guard: BATCH-UNINSTALL-REMAINING-01 — mid-batch stop reports unprocessed."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/AppUninstallEligibility.swift").read_text()
direct = (root / "Sources/Direct/UninstallCoordinator.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
xc = (root / "Resources/Localizable.xcstrings").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("BATCH-UNINSTALL-REMAINING-01" in core, "Core marker")
need("interruptedSuccessFormatKey" in core, "interrupted success key")
need("interruptedPartialFormatKey" in core, "interrupted partial key")
need("interruptedFailedFormatKey" in core, "interrupted failed key")
need("interruptedOnlyFormatKey" in core, "interrupted only key")
need("case interrupted(succeeded:" in core, "interrupted case")
need("unprocessedCount(total:" in core, "unprocessedCount helper")
need("unprocessed: Int = 0" in core or "unprocessed: Int" in core, "resultToast takes unprocessed")
need("BATCH-UNINSTALL-REMAINING-01" in direct, "Direct marker")
need("unprocessedCount(" in direct, "Direct computes unprocessed")
need("unprocessed: unprocessed" in direct, "Direct passes unprocessed")
need("testBatchUninstallResultToastVariants" in tests, "Core test still present")
need(".interrupted(succeeded:" in tests, "Core test covers interrupted")
for key in (
    "已卸载 %d 个应用，%d 个未处理",
    "已卸载 %d 个应用，%d 个失败，%d 个未处理",
    "%d 个失败，%d 个未处理",
    "%d 个未处理",
):
    need(key in xc, f"xcstrings missing {key}")

# No paging symbols in the result toast / unprocessed helpers region
idx = core.index("BATCH-UNINSTALL-REMAINING-01")
chunk = core[idx:idx + 3500]
for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
    need(bad not in chunk, f"paging symbol {bad} near remaining toast")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: batch uninstall remaining toast")

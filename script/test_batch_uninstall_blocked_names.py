#!/usr/bin/env python3
"""Guard: BATCH-UNINSTALL-BLOCKED-NAMES-01 — confirm lists blocked app names."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/AppUninstallEligibility.swift").read_text()
direct = (root / "Sources/Direct/UninstallCoordinator.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
strings = (root / "Resources/Localizable.xcstrings").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


need("blockedNameListFormatKey" in core, "Core format key")
need("blockedNameListOverflowFormatKey" in core, "Core overflow key")
need("BATCH-UNINSTALL-BLOCKED-NAMES-01" in core or "BATCH-UNINSTALL-BLOCKED-NAMES-01" in direct, "slice marker")
# CONFIRM-COPY-01: Direct may call confirmInformativeText instead of assembling keys itself.
wired = (
    "plan.blockedNameList" in direct
    or "confirmInformativeText(localize:" in direct
)
need(wired, "Direct uses blockedNameList or confirmInformativeText")
need(
    "blockedNameListOverflowFormatKey" in direct or "blockedNameListOverflowFormatKey" in core,
    "overflow format owned by Core (or Direct)",
)
need(
    "blockedNameListFormatKey" in direct or "blockedNameListFormatKey" in core,
    "short format owned by Core (or Direct)",
)
need("confirmInformativeText" in core and "blockedNameListFormatKey" in core, "Core still formats blocked names")
need("testBatchUninstallBlockedNameListTruncatesLikeEligible" in tests, "Core test")
need('"无法卸载：%@"' in strings, "zh format in xcstrings")
need('"Cannot uninstall: %@"' in strings, "en format in xcstrings")
start = direct.index("promptToBatchUninstall")
chunk = direct[start: start + 2500]
for banned in ("showPage", "scrollToPage", "PagingCollectionView"):
    need(banned not in chunk, f"paging symbol {banned} must stay out of batch prompt")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: batch uninstall blocked names")

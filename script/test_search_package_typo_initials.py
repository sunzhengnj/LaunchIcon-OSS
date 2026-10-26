#!/usr/bin/env python3
"""Guard: SEARCH-TYPO-PACKAGE-01 / SEARCH-INITIALS-RANK-01."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
models = (root / "Sources/Core/Models.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


need("package.matchesWithOneTypo(query)" in models, "package typo fallback")
i = models.find("package.matchesWithOneTypo(query)")
need("ranks.isEmpty" in models[max(0, i - 80):i], "package typo only when nothing else matched")
need("return 11" in models[i:i + 60], "package typo ranks after name typo (11)")
need("isWordStart(query) || matchesWordInitials(query)" in models, "initials share word-start rank")
need("package.matchesWordInitials(query)" in models, "package initials tier")
need("testSearchTypoAndInitialsUsePackageNameUnderLocalizedDisplayName" in tests, "Core test")
need('"a real prefix still beats an initials-only hit"' in tests, "prefix-beats-initials test kept")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS: search package typo + initials rank guard")

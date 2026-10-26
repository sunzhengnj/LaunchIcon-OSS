#!/usr/bin/env python3
"""Guard: CUSTOM-ROOT-SCAN-LIMIT-01 — depth/count caps on user-added roots."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
scanner = (root / "Sources/Core/AppCatalogScanner.swift").read_text()
models = (root / "Sources/Core/Models.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
layout = (root / "Sources/Core/LauncherLayout.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("customRootMaxRelativeDepth" in scanner, "scanner missing depth cap")
need("customRootMaxAppsDefault" in scanner or "customRootMaxApps" in scanner, "scanner missing app-count cap")
need("truncatedScanRootPaths" in models, "report missing truncatedScanRootPaths")
need("truncatedScanRootPaths" in scanner, "scanner must record truncated roots")
i = models.index("var canPersistReconciledLayout")
persist = models[i:i + 350]
need("truncatedScanRootPaths" not in persist, "canPersist must ignore truncatedScanRootPaths")
need("applyCustomLimits" in scanner, "limits must apply only to required/custom roots")
need("truncatedCustomRootExplanationKey" in layout, "Core soft notice copy missing")
need("showTransientToast" in direct, "Direct must toast truncated notice")
need("truncatedScanRootPaths.isEmpty" in direct, "Direct rescan/toast must check truncated")
need("testCustomRootScanRespectsDepthAndAppCountCaps" in tests, "Core cap test missing")
start = scanner.index("CUSTOM-ROOT-SCAN-LIMIT-01")
chunk = scanner[start:start + 1200]
for bad in ("scrollToPage", "pageTransition", "movePage"):
    need(bad not in chunk, f"scan limit must not touch {bad}")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: custom-root scan limit")

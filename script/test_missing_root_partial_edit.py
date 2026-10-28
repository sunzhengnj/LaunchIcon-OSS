#!/usr/bin/env python3
"""Guard: MISSING-ROOT-PARTIAL-EDIT-01 — missing user root does not lock editing."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
models = (root / "Sources/Core/Models.swift").read_text()
scanner = (root / "Sources/Core/AppCatalogScanner.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
layout = (root / "Sources/Core/LauncherLayout.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("unavailableRequiredRootPaths" in models, "CatalogScanReport must expose unavailableRequiredRootPaths")
need("retainingCandidates(" in models, "CatalogScanReport must offer retainingCandidates")
i = models.index("var canPersistReconciledLayout")
persist = models[i:i + 350]
need("unavailableRequiredRootPaths" not in persist,
     "canPersist must ignore unavailableRequiredRootPaths")
need("skippedPaths.isEmpty" in persist, "canPersist still blocks on skippedPaths")

scan = scanner[scanner.index("if requiredRootPaths.contains"):scanner.index("continue", scanner.index("if requiredRootPaths.contains"))+40]
need("unavailableRequiredRootPaths.append" in scan, "missing required root must append unavailable")
need("skippedPaths.append(root)" not in scan, "missing required root must not go to skippedPaths")

need("retainingCandidates(from:" in direct, "Direct reloadCatalog must retain prior candidates")
need("catalogCandidatesForRetention" in direct, "RootView must expose retention snapshot")
need("unavailableRequiredRootPaths.isEmpty" in direct,
     "Direct must react to unavailable roots (rescan / diagnostic / toast)")
need("unavailableCustomRootExplanationKey" in layout, "soft unavailable-root notice copy missing")
need("unavailableCustomRootExplanation" in direct, "Direct must toast unavailable-root notice")

need("testScanReportsMissingRequiredCustomRootAsUnavailable" in tests, "Core scan test missing")
need("testRetainingCandidatesKeepsUnavailableRootAppsThroughReconcile" in tests, "Core retain test missing")
need("allowsPersistingReconcile" in models, "Core must refuse persist when retention cannot cover the layout")
need("testMissingRootWithoutRetentionSourceDoesNotPersist" in tests, "Core no-cache missing-root test missing")
need("allowsPersistingReconcile(retainingFrom:" in direct, "Direct must use the no-cache persist gate")
need("layoutKeepingStoredNewerThanUnsafeReconcile" in direct, "unsafe reconcile must not outdate the layout file")
need("refusedUntrustedDrop" in direct, "read-only explanation must follow the no-cache gate")

chunk = direct[direct.index("MISSING-ROOT-PARTIAL-EDIT-01"):direct.index("await finishPendingLayoutSaves()")]
for bad in ("scrollToPage", "pageTransition", "movePage", "animator()"):
    need(bad not in chunk, f"MISSING-ROOT wire must not touch {bad}")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: missing-root partial edit")

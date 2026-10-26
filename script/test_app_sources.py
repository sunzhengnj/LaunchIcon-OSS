#!/usr/bin/env python3
"""Static guard for user-added app folders (APP-SOURCES-01)."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
W = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text()
D = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text()
S = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text()
fail = []
def need(src, text, why):
    if text not in src:
        fail.append(why)
need(W, "guard base == AppCatalogScanner.standardRoots, !additional.isEmpty else { return (base, []) }",
     "test roots / empty list must keep the original root list")
need(W, "roots: self.catalogRoots, requiredRootPaths: self.requiredCatalogRootPaths",
     "catalog scan must pass requiredRootPaths for user folders")
need(W, "retainingCandidates(from:",
     "MISSING-ROOT-PARTIAL-EDIT-01: Direct must retain prior apps under unavailable roots")
need(W, "unavailableRequiredRootPaths",
     "Direct must surface unavailableRequiredRootPaths (rescan / diagnostics)")
need(W, "guard resolved.roots != catalogRoots else { return }", "no rescan when roots unchanged")
need(W, "var uninstallCatalogRoots: [URL] { catalogRoots }", "uninstall safety must see user folders too")
need(D, "additionalAppDirectories: testRoot == nil ? preferences.additionalAppDirectories : []",
     "launch must apply saved folders (not under test root)")
need(D, "setAdditionalAppDirectories(proposed.additionalAppDirectories)", "settings change must apply")
need(S, "AppCatalogScanner.catalogRoots(additionalPaths: current + [url.path])", "add must validate via Core")
body = W[W.find("func setAdditionalAppDirectories"):]
body = body[:body.find("\n    }\n")]
for bad in ("scrollToPage", "currentPage", "setPage", "animator()"):
    if bad in body:
        fail.append(f"setAdditionalAppDirectories touches {bad}")
if fail:
    print("FAIL: app sources\n  " + "\n  ".join(fail)); sys.exit(1)
print("PASS: app sources wiring")

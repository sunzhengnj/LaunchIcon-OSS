#!/usr/bin/env python3
"""ALERT-ACCESSORY-FOCUS-01: alias/folder rename alerts focus the name field."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)

if "ALERT-ACCESSORY-FOCUS-01" not in direct:
    fail("missing slice tag")
if direct.count("makeFirstResponder(field)") < 2:
    fail("both alias and folder rename must makeFirstResponder(field)")
if "promptForAlias" not in direct or "promptForFolderName" not in direct:
    fail("prompt helpers missing")
# Ensure layout precedes makeFirstResponder in both sites (rough order check)
for fn in ("promptForAlias", "promptForFolderName"):
    i = direct.index(f"func {fn}")
    # ALIAS-FOLDER-PROMPT-COPY-01 lengthened the prompt bodies; keep the
    # layout/focus order check over a window large enough for Core wiring.
    chunk = direct[i:i+2400]
    if "alert.layout()" not in chunk:
        fail(f"{fn} must layout() before focus")
    if chunk.index("alert.layout()") > chunk.index("makeFirstResponder(field)"):
        fail(f"{fn}: layout must precede makeFirstResponder")
    for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
        if bad in chunk:
            fail(f"paging symbol {bad} in {fn} — refuse")

print("PASS: alert accessory focus")

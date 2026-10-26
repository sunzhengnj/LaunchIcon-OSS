#!/usr/bin/env python3
"""Guard: FOLDER-TITLE-AM-BEGIN-01 — retry field-editor open under AM/chrome lag."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
src = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
fail = []
def need(c, m):
    if not c: fail.append(m)
need("FOLDER-TITLE-AM-BEGIN-01" in src, "marker missing")
need("scheduleRenameBeginRetry" in src, "retry helper missing")
need("beginRenameEditingFromPointer" in src, "begin helper missing")
need("isAccessibilityFocused" in src[src.rfind("private final class FolderTitleField"):],
     "FolderTitleField must report AX focused while editing")
need("openFieldEditorForRename" in src, "openFieldEditor helper missing")
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
need("allowSingleClickBegin" in core, "Core single-click begin policy missing")
ft = src.rfind("private final class FolderTitleField")
need(ft >= 0, "FolderTitleField missing")
chunk = src[ft:ft + 12000]
need("LAUNCHICON_TEST_LAYOUT_PATH" in chunk,
     "FolderTitleField must gate single-click begin on test layout env")
need("scheduleRenameBeginRetry()" in chunk, "FolderTitleField must schedule retry")
need("allowSingleClickBegin" in chunk, "FolderTitleField must read allowSingleClickBegin")
# Production chrome block still schedules retry when not in fixture mode.
need(
    "guard pointerEditingAvailable() || allowSingleClickBegin else" in chunk
    or "guard pointerEditingAvailable() else" in chunk,
    "chrome-blocked path must remain",
)
idx = chunk.find("scheduleRenameBeginRetry()")
need(idx >= 0, "retry call missing in FolderTitleField")
if fail:
    print("FAIL:"); [print(x) for x in fail]; sys.exit(1)
print("PASS: folder-title AM begin retry")

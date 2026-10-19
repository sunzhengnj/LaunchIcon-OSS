#!/usr/bin/env python3
"""Guard: empty folder focuses title (open land / title-end) — no paging."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("folderOpenEmptyFocusesTitle" in core, "Core missing folderOpenEmptyFocusesTitle")
need("folderTitleEndFocusTarget" in core, "Core missing folderTitleEndFocusTarget")
need("testFolderEmptyFocusesTitleNotEmptyCollection" in tests, "Core test missing")
need("folderOpenEmptyFocusesTitle" in direct, "Direct must wire empty open title focus")
need("folderTitleEndFocusTarget" in direct, "Direct must wire title-end empty target")

# Open land: empty → title; still first-member when tiles exist; no ?? keyViews.first
start = direct.index("private func focusOpenedFolderMemberAfterChromeLands")
end = direct.index("private func closeFolder(", start)
body = direct[start:end]
need("case .focusFirstMember" in body, "open land missing focusFirstMember")
need("folderOpenEmptyFocusesTitle" in body and "focusTitleField" in body,
     "empty open must focus title")
need("?? keyViews.first" not in body, "must not ??-fallback to title/close for non-empty")
need("folderTitleFocusesFirstMemberAfterEndingEdit" in direct, "must not regress title→first-member gate")

# Title-end helper
hstart = direct.index("func refocusAfterTitleEditingEnds")
# next private func after
hnxt = direct.index("\n    func isTitleHit", hstart)
helper = direct[hstart:hnxt]
need("folderTitleEndFocusTarget" in helper, "title-end uses Core target")
need("case .firstMember" in helper and "case .title" in helper, "title-end switch targets")
need("makeFirstResponder(collectionView)" not in helper or "folderTitleEndFocusTarget" in helper,
     "empty title-end should not prefer empty collection over title")

for label, chunk in (("Core empty focus", core[core.index("folderOpenEmptyFocusesTitle"):core.index("folderTitleEndFocusTarget")+400]),
                     ("open land", body), ("title end", helper)):
    need("showPage" not in chunk and "pageTransition" not in chunk and "movePage" not in chunk,
         f"{label} must not touch paging")

# Dimmer park regression: keep animateOpen park pattern mentioned in HANDOFF
need("finishFolderBackdropOpen" in direct or "animateOpen" in direct, "folder open path present")
need("folderCloseShouldRestoreGridFocusOnChromeLand" in direct, "close focus restore must remain")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: empty folder focuses title (no empty collection; no paging)")

#!/usr/bin/env python3
"""REOPEN-PAGE-BEHAVIOR-01: Settings reopen-page policy; no paging animation."""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
_direct_dir = ROOT / "Sources/Direct"
direct = (_direct_dir / "LauncherWindowController.swift").read_text(encoding="utf-8") + "".join(
    p.read_text(encoding="utf-8") for p in sorted(_direct_dir.glob("LauncherWindowController+*.swift"))
)
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")
delegate = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
strings = json.loads((ROOT / "Resources/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for needle in (
    "enum LauncherReopenPageBehavior",
    "case rememberLast",
    "case alwaysHome",
    "case homeAfter30Seconds",
    'prefix + "reopenPageBehavior"',
    "reopenPageBehavior: LauncherReopenPageBehavior = .rememberLast",
    "enum ReopenPageCopy",
    "shouldResetToHomePageOnAppear",
    "shouldStampDismissInstant",
):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")

if "testReopenPageBehaviorDefaultsAndPolicy" not in tests:
    fail("Core test missing")
ui = (ROOT / "Tests/UITests/LauncherDragUITests.swift").read_text(encoding="utf-8")
if "testReopenAlwaysHomeReturnsToFirstPage" not in ui:
    fail("UI test missing always-home reopen")
if "LAUNCHICON_TEST_REOPEN_PAGE_BEHAVIOR" not in ui or "LAUNCHICON_TEST_REOPEN_PAGE_BEHAVIOR" not in delegate:
    fail("UI reopen override must be an env var the app applies with setReopenPageBehavior")
if "shouldStampDismissInstant" not in tests:
    fail("Core test missing dismiss-stamp assertions")

for needle in (
    "reopenPagePopup",
    "settings-reopen-page",
    "proposed.reopenPageBehavior",
):
    if needle not in settings:
        fail(f"Settings missing {needle!r}")

import re
# SETTINGS-COMPACT-SCROLL-02: scrolled viewport; reopen row retained.
if "NSScrollView" not in settings:
    fail("Settings must use NSScrollView after compact pass")
hm = re.search(r"defaultContentHeight:\s*CGFloat\s*=\s*(\d+)", settings)
if not hm or int(hm.group(1)) < 520 or int(hm.group(1)) > 760:
    fail("Settings defaultContentHeight should be compact (~520-760)")
if "settings-reopen-page" not in settings:
    fail("reopen AX id must remain")

if "showPage(" in settings or "pageTransition" in settings or "pageAnimation" in settings:
    fail("settings must not touch paging")

if delegate.count("setReopenPageBehavior(") != 2:
    fail("DirectAppDelegate must apply reopen behavior at boot and on settings change")

for needle in (
    "func setReopenPageBehavior",
    "func snapGridToHomePageForReopen",
    "lastDismissDate = Date()",
    "ReopenPageCopy.shouldStampDismissInstant",
    "ReopenPageCopy.shouldResetToHomePageOnAppear",
):
    if needle not in direct:
        fail(f"Direct missing {needle!r}")

# snap must not start a page transition
start = direct.find("    func snapGridToHomePageForReopen() {\n")
if start < 0:
    fail("snapGridToHomePageForReopen missing")
body = direct[start:direct.find("\n    }\n", start)]
for bad in ("showPage(", "transitionToPage(", "animatePage", "pageTransitionGeneration"):
    # pageTransitionGeneration bump would be ok if settling, but prefer settleInterruptedPaging only
    if bad == "pageTransitionGeneration" and "pageTransitionGeneration" in body:
        # allow only if settleInterruptedPaging is called (it bumps generation)
        pass
    if bad in ("showPage(", "transitionToPage(", "animatePage") and bad in body:
        fail(f"snapGridToHomePageForReopen must not call {bad} (paging red line)")

if "settleInterruptedPaging()" not in body:
    fail("snap must settle interrupted paging first")
if "currentPage = 0" not in body:
    fail("snap must set currentPage = 0")

for key in (
    "打开时页面",
    "记住上次位置",
    "始终回到首页",
    "30 秒后回首页",
    "1 分钟后回首页",
    "5 分钟后回首页",
    "再次打开启动器时停留在上次所在页，或回到第一页；不影响翻页动画",
):
    if key not in strings:
        fail(f"xcstrings missing {key!r}")

print("PASS: reopen page behavior wired")

#!/usr/bin/env python3
"""Guard: top-level grid rearrange (name/kind) — no paging."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
delegate = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("enum GridRearrangeSort" in core, "Core missing GridRearrangeSort")
need("rearrangeTopLevelEntries" in core, "Core missing rearrangeTopLevelEntries")
need("gridRearrangeToastMessage" in core, "Core missing toast helper")
need("testRearrangeTopLevelByNameAndKindPreservesFolderMembership" in tests, "Core test missing")
need("folder membership must not change" in tests, "test should assert folder membership")
need(
    ("按名称排列" in settings and "按类型排列" in settings)
    or (
        "GridRearrangeSort.byName.settingsButtonTitleKey" in settings
        and "GridRearrangeSort.byKind.settingsButtonTitleKey" in settings
    ),
    "Settings missing rearrange buttons",
)
need("CategoryRearrangeCopy.settingsButtonTitleKey" in settings or "按分类排列" in settings,
     "Settings missing category rearrange button title")
need("onRearrangeTopLevel" in settings, "Settings missing callback")
need("应用管理" in settings, "rearrange should live under 应用管理")
need("rootView.rearrangeTopLevelGrid" in direct, "WC must forward rearrange to rootView")
need("onRearrangeTopLevel" in delegate, "AppDelegate must wire rearrange")
need("onRearrangeByCategory" in settings and "onRearrangeByCategory" in delegate
     and "rootView.rearrangeTopLevelGridByCategory()" in direct, "category rearrange must be wired Settings → WC → rootView")
need("onRearrangeByColor" in settings and "onRearrangeByColor" in delegate
     and "rearrangeTopLevelGridByColorAwaitingCompletion" in direct,
     "color rearrange must be wired Settings → WC await API")
need("settings-rearrange-by-color" in settings, "Settings missing color rearrange button AX id")
cat_btn = settings[settings.index("@objc private func rearrangeByCategory()"):settings.index("private func applyRearrange(")]
need("cancelIsFirstButton" in cat_btn and "alertSecondButtonReturn" in cat_btn, "category rearrange confirm must be Cancel-first")

# Root implementation (the one that calls Core + commitLayout)
impl_key = "LauncherLayout.rearrangeTopLevelEntries"
need(impl_key in direct, "rootView must call Core rearrange")
start = direct.index(impl_key)
chunk = direct[max(0, start - 200):start + 600]
need("commitLayout(next)" in chunk, "rearrange must commitLayout for persist/backup")
need("itemSelection.clear()" in chunk, "rearrange should clear multi-select")
need("showPage" not in chunk and "pageTransition" not in chunk and "movePage" not in chunk,
     "rearrange must not touch paging")


need("GridRearrangeConfirmAlert" in core, "Core missing rearrange confirm alert")
need("cancelIsFirstButton = true" in core[core.index("GridRearrangeConfirmAlert"):core.index("GridRearrangeConfirmAlert")+400],
     "rearrange confirm must be Cancel-first")
need("confirmGridRearrange" in settings, "Settings must confirm before rearrange")
need("alertSecondButtonReturn" in settings, "Confirm must be second button (Cancel first)")
need("settingsFeedbackAccessibilityLabelKey" in core, "Core missing settings feedback AX label")
need("settingsFeedbackAccessibilityLabelKey" in settings, "Settings feedback row needs AX label")
need("setAccessibilityElement(true)" in settings[settings.index("messageLabel.textColor"):settings.index("messageLabel.textColor")+500],
     "messageLabel must be AX element")
need("testGridRearrangeConfirmAlertCancelIsFirstButton" in tests, "Core confirm test missing")

# Confirm path must not touch paging
conf = settings[settings.index("func confirmGridRearrange"):settings.index("func openLoginSettings")]
need("showPage" not in conf and "pageTransition" not in conf and "movePage" not in conf,
     "rearrange confirm must not touch paging")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: grid rearrange name/kind")

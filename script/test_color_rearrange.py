#!/usr/bin/env python3
"""Static guard for COLOR-REARRANGE-01 (blank-area 按颜色排列…)."""
import pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
w = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
plat = (root / "Sources/Core/PlatformServices.swift").read_text()
checks = [
    ("menu item", "L(LauncherLayout.ColorRearrangeCopy.menuTitleKey)" in w),
    ("action selector", "#selector(rearrangeByColorFromBlankAreaMenu)" in w),
    ("core sort", "static func rearrangeTopLevelEntriesByColor(" in core),
    ("sampler", "static func sample(of image: NSImage)" in plat or "func sample(of" in plat),
]
s = w.find("func rearrangeByColorFromBlankAreaMenu")
body = w[s:w.find("\n    }\n", s)]
checks += [
    ("cancel first", "cancelIsFirstButton" in body),
    ("modal confirm", "alertSecondButtonReturn" in body),
    ("no search/folder", "openedFolderID == nil" in body and "!isSearching" in body),
]
# Prefer the fire-and-forget RootView impl (not the WC forwarder / await API).
s = w.find("func rearrangeTopLevelGridByColor() -> Bool")
assert s >= 0, "missing rearrangeTopLevelGridByColor() -> Bool"
launch = w[s:w.find("\n    }\n", s)]
s = w.find("private func applyColorRearrange")
body = w[s:w.find("\n    }\n", s)]
checks += [
    ("offmain sampler", "IconColorSampler.shared.samples(for:" in launch and "isSamplingIconColors" in launch),
    ("hide drops color sort", "shouldApplyDeferredGridRearrange" in launch),
    ("no main-thread sampling", "IconColorSample.sample(of:" not in w),
    ("apply rechecks state", "openedFolderID == nil" in body and "!isSearching" in body),

    ("commit", "commitLayout(next)" in body),
    ("toast", "ColorRearrangeCopy.toastKey" in body),
    ("selection cleared", "itemSelection.clear()" in body),
    ("no paging", all(k not in body for k in ("currentPage", "scrollToPage", "setPage", "animatePage"))),
]
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
delegate = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
checks += [
    ("settings button key", "settingsButtonTitleKey" in core and "settingsButtonTitleKey" in settings),
    ("settings ax id", "settings-rearrange-by-color" in settings),
    ("settings callback", "var onRearrangeByColor: (() async -> Bool)?" in settings),
    ("settings cancel-first", "ColorRearrangeCopy.informativeTextKey" in settings
     and "rearrangeByColor()" in settings
     and "cancelIsFirstButton" in settings[settings.index("@objc private func rearrangeByColor()"):
                                           settings.index("private func applyRearrange(")]),
    ("settings progress then toast", "progressToastKey" in settings[settings.index("@objc private func rearrangeByColor()"):
                                                                   settings.index("private func applyRearrange(")]
     and "ColorRearrangeCopy.toastKey" in settings[settings.index("@objc private func rearrangeByColor()"):
                                                   settings.index("private func applyRearrange(")]),
    ("await API", "func rearrangeTopLevelGridByColorAwaitingCompletion() async -> Bool" in w),
    ("delegate wire", "onRearrangeByColor" in delegate
     and "rearrangeTopLevelGridByColorAwaitingCompletion" in delegate),
]
bad = [n for n, ok in checks if not ok]
if bad:
    print("FAIL:", ", ".join(bad)); sys.exit(1)
print("PASS: color rearrange")

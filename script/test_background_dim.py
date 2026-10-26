#!/usr/bin/env python3
"""BACKGROUND-DIM-01: Settings background-dim popup recolours only the overlay."""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")
delegate = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")
strings = json.loads((ROOT / "Resources/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


for needle in (
    "enum LauncherBackgroundDim",
    "case .standard: 0.24",
    'prefix + "backgroundDim"',
    "backgroundDim: LauncherBackgroundDim = .standard",
    "enum BackgroundDimCopy",
):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")

if "withAlphaComponent(0.24)" in direct:
    fail("Direct still hard-codes overlay 0.24")
start = direct.find("    func setBackgroundDim(_ dim: LauncherBackgroundDim) {\n        guard dim != backgroundDim")
if start < 0:
    fail("root view setBackgroundDim missing")
body = direct[start:direct.find("\n    }\n", start)]
for bad in ("reload", "currentPage", "layoutSubtreeIfNeeded", "needsLayout", "scrollTo", "makeFirstResponder"):
    if bad in body:
        fail(f"setBackgroundDim must not touch {bad} (paging red line)")

if delegate.count("setBackgroundDim(") != 2:
    fail("DirectAppDelegate must apply dim at boot and on settings change")
for needle in ("backgroundDimPopup", "settings-background-dim", "proposed.backgroundDim"):
    if needle not in settings:
        fail(f"Settings missing {needle!r}")

for key in ("浅", "标准", "深", "背景暗度", "调整启动器背后壁纸的变暗程度；越深图标名称越清楚，立即生效"):
    if key not in strings:
        fail(f"xcstrings missing {key!r}")

# BACKGROUND-BLUR-01
for needle in ('prefix + "blursBackground"', "blursBackground: Bool = true"):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")
if "NSVisualEffectView(frame: .zero)\n        effect.material" in direct:
    fail("blur view must be the stored backgroundBlurView")
bstart = direct.find("    func setBlursBackground(_ blurs: Bool) {\n        guard backgroundBlurView")
if bstart < 0:
    fail("root view setBlursBackground missing")
bbody = direct[bstart:direct.find("\n    }\n", bstart)]
for bad in ("reload", "currentPage", "layoutSubtreeIfNeeded", "needsLayout", "scrollTo", "makeFirstResponder"):
    if bad in bbody:
        fail(f"setBlursBackground must not touch {bad} (paging red line)")
if delegate.count("setBlursBackground(") != 2:
    fail("DirectAppDelegate must apply blur at boot and on settings change")
for needle in ("backgroundBlurCheckbox", "settings-background-blur", "proposed.blursBackground"):
    if needle not in settings:
        fail(f"Settings missing {needle!r}")
for key in ("背景", "模糊", "模糊壁纸", "关闭后直接显示清晰的桌面壁纸，只保留变暗；立即生效"):
    if key not in strings:
        fail(f"xcstrings missing {key!r}")

print("PASS: background dim + blur wired")

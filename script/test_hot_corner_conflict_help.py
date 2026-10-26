#!/usr/bin/env python3
"""HOT-CORNER-CONFLICT-HELP-01: hot-corner conflict help lives in Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
prefs = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
settings = (ROOT / "Sources/Direct/SettingsWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "HOT-CORNER-CONFLICT-HELP-01" not in prefs:
    fail("Core missing slice tag")
if "enum HotCornerConflictCopy" not in prefs:
    fail("missing HotCornerConflictCopy")

for needle in (
    "accessibilityHelpKey",
    "conflictToolTipKey",
    "将指针移入所选屏幕角可显示或隐藏启动器",
    "与系统触发角冲突时请换角或关闭系统该角",
    "func conflictMessage(",
):
    if needle not in prefs:
        fail(f"Core missing {needle!r}")

# No paging in the new copy block
idx = prefs.index("enum HotCornerConflictCopy")
chunk = prefs[idx:idx + 1200]
for bad in ("showPage", "pageTransition", "pageAnimation"):
    if bad in chunk:
        fail(f"HotCornerConflictCopy must not touch paging ({bad})")

for helper in (
    "HotCornerConflictCopy.accessibilityHelp",
    "HotCornerConflictCopy.conflictToolTip",
    "corner.conflictMessage(",
):
    if helper not in settings:
        fail(f"Settings missing {helper}")

for bad in (
    'L("将指针移入所选屏幕角可显示或隐藏启动器。若与系统设置「桌面与程序坞 → 触发角」选同一角，系统动作会一并触发；请选未占用的角，或在系统里将该角设为「-」。不需要辅助功能权限。")',
    'L("与系统触发角冲突时请换角或关闭系统该角")',
    "String(format: L(LauncherHotCorner.systemConflictMessageFormatKey)",
):
    if bad in settings:
        fail(f"Settings still has {bad}")

print("PASS: hot-corner conflict help owned by Core")

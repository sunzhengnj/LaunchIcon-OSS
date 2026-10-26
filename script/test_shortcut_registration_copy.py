#!/usr/bin/env python3
"""SHORTCUT-REGISTRATION-COPY-01: hotkey conflict copy lives in Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherPreferences.swift").read_text(encoding="utf-8")
delegate = (ROOT / "Sources/Direct/DirectAppDelegate.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "SHORTCUT-REGISTRATION-COPY-01" not in core:
    fail("Core missing slice tag")
if "enum ShortcutRegistrationCopy" not in core:
    fail("missing ShortcutRegistrationCopy")
for needle in (
    "bootConflictFormatKey",
    "changeConflictFormatKey",
    "cannotHideStatusItemKey",
    "无法使用呼出快捷键 %@",
    "无法使用快捷键 %@",
    "快捷键不可用时不能隐藏菜单栏图标。",
):
    if needle not in core:
        fail(f"Core missing {needle!r}")

for helper in (
    "ShortcutRegistrationCopy.bootConflictMessage",
    "ShortcutRegistrationCopy.changeConflictMessage",
    "ShortcutRegistrationCopy.cannotHideStatusItem",
):
    if helper not in delegate:
        fail(f"delegate missing {helper}")

for bad in (
    'L("无法使用呼出快捷键 %@。可能与系统或其他应用冲突，请选择其他组合；菜单栏图标仍可使用。")',
    'L("无法使用快捷键 %@，可能与系统或其他应用冲突。原组合保持不变。")',
    'L("快捷键不可用时不能隐藏菜单栏图标。")',
):
    if bad in delegate:
        fail(f"delegate still has {bad}")

print("PASS: shortcut registration copy owned by Core")

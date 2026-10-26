#!/usr/bin/env python3
"""LAUNCH-FEEDBACK-COPY-01: open failure / launching / layout-save toast in Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
layout = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "LAUNCH-FEEDBACK-COPY-01" not in layout:
    fail("Core missing slice tag")
if "enum LaunchFeedbackCopy" not in layout:
    fail("missing LaunchFeedbackCopy")

for needle in (
    'timedOutFormatKey = "打开“%@”超时"',
    'cannotOpenFormatKey = "无法打开“%@”"',
    'launchingTitleKey = "正在启动…"',
    'layoutSaveFailedKey = "布局未保存，请检查磁盘空间或文件权限"',
    "func openFailureMessage",
):
    if needle not in layout:
        fail(f"Core missing {needle!r}")

for helper in (
    "LauncherLayout.LaunchFeedbackCopy.openFailureMessage",
    "LauncherLayout.LaunchFeedbackCopy.launchingTitle",
    "LauncherLayout.LaunchFeedbackCopy.layoutSaveFailed",
):
    if helper not in direct:
        fail(f"Direct missing {helper}")

for bad in (
    'L("打开“%@”超时")',
    'L("无法打开“%@”")',
    'L("正在启动…")',
    'L("布局未保存，请检查磁盘空间或文件权限")',
):
    if bad in direct:
        fail(f"Direct still has {bad}")

print("PASS: launch feedback owned by Core")

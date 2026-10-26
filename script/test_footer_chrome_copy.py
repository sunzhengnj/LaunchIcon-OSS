#!/usr/bin/env python3
"""FOOTER-DRAG-HINT-01: footer drag hint + toast close owned by Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
layout = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


if "FOOTER-DRAG-HINT-01" not in layout:
    fail("Core missing slice tag")
if "enum FooterChromeCopy" not in layout:
    fail("missing FooterChromeCopy")

for needle in (
    'dragHintKey = "拖拽整理"',
    'dragHintMultiPageKey = "拖拽整理 · 悬停左右边缘跨页"',
    'toastCloseKey = "关闭提示"',
    "func dragHint(pageCount:",
):
    if needle not in layout:
        fail(f"Core missing {needle!r}")

for helper in (
    "LauncherLayout.FooterChromeCopy.dragHint",
    "LauncherLayout.FooterChromeCopy.toastCloseLabel",
):
    if helper not in direct:
        fail(f"Direct missing {helper}")

for bad in (
    'L("拖拽整理")',
    'L("拖拽整理 · 悬停左右边缘跨页")',
    'L("关闭提示")',
):
    if bad in direct:
        fail(f"Direct still has {bad}")

print("PASS: footer chrome owned by Core")

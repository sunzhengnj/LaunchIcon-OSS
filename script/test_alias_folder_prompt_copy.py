#!/usr/bin/env python3
"""ALIAS-FOLDER-PROMPT-COPY-01: alias + folder rename alert copy lives in Core."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core_layout = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


def body(src: str, start: str, end: str) -> str:
    i = src.index(start)
    j = src.index(end, i)
    return src[i:j]


if "ALIAS-FOLDER-PROMPT-COPY-01" not in core_layout:
    fail("Core missing ALIAS-FOLDER-PROMPT-COPY-01 tag")
if "enum AppAliasPromptAlert" not in core_layout:
    fail("missing AppAliasPromptAlert")
if "enum FolderRenamePromptAlert" not in core_layout:
    fail("missing FolderRenamePromptAlert")

alias = body(core_layout, "enum AppAliasPromptAlert", "enum FolderRenamePromptAlert")
folder = body(core_layout, "enum FolderRenamePromptAlert", "enum GridRearrangeConfirmAlert")

for needle in (
    'messageTextKey = "设置应用别名"',
    'informativeTextKey = "别名会用于显示和搜索；留空可恢复原名称。"',
    'saveButtonTitleKey = "保存"',
    'cancelButtonTitleKey = "取消"',
    'accessibilityLabelFormatKey = "%@ 的别名"',
    "saveIsFirstButton = true",
):
    if needle not in alias:
        fail(f"AppAliasPromptAlert missing {needle!r}")

for needle in (
    'messageTextKey = "重命名文件夹"',
    'informativeTextKey = "留空会保留原名称。"',
    'placeholderKey = "新建文件夹"',
    'accessibilityLabelKey = "文件夹名称"',
    'saveButtonTitleKey = "保存"',
    'cancelButtonTitleKey = "取消"',
    "saveIsFirstButton = true",
):
    if needle not in folder:
        fail(f"FolderRenamePromptAlert missing {needle!r}")

for fn, end in (
    ("promptForAlias", "private func restoreFocusAfterAlias("),
    ("promptForFolderName", "private func sortFolderByNameFromMenu("),
):
    chunk = body(direct, f"private func {fn}(", end)
    if "ALIAS-FOLDER-PROMPT-COPY-01" not in chunk:
        fail(f"{fn} missing slice tag")
    if fn == "promptForAlias":
        helpers = (
            "AppAliasPromptAlert.messageText",
            "AppAliasPromptAlert.informativeText",
            "AppAliasPromptAlert.saveButtonTitle",
            "AppAliasPromptAlert.cancelButtonTitle",
            "AppAliasPromptAlert.accessibilityLabel",
            "AppAliasPromptAlert.saveIsFirstButton",
        )
    else:
        helpers = (
            "FolderRenamePromptAlert.messageText",
            "FolderRenamePromptAlert.informativeText",
            "FolderRenamePromptAlert.placeholder",
            "FolderRenamePromptAlert.accessibilityLabel",
            "FolderRenamePromptAlert.saveButtonTitle",
            "FolderRenamePromptAlert.cancelButtonTitle",
            "FolderRenamePromptAlert.saveIsFirstButton",
        )
    for helper in helpers:
        if helper not in chunk:
            fail(f"{fn} must call {helper}")
    for bad in (
        'L("设置应用别名")',
        'L("别名会用于显示和搜索；留空可恢复原名称。")',
        'L("留空会清除别名，恢复显示应用原名。")',
        'L("重命名文件夹")',
        'L("留空会保留原名称。")',
        'L("新建文件夹")',
        'L("文件夹名称")',
        'L("保存")',
        'L("取消")',
        'L("%@ 的别名")',
    ):
        if bad in chunk:
            fail(f"{fn} still has Direct Chinese literal {bad}")
    if "precondition(" not in chunk or "saveIsFirstButton" not in chunk:
        fail(f"{fn} must precondition Save-first via Core flag")
    for bad in ("showPage(", "movePage(", "transitionToPage(", "pageAnimationDuration"):
        if bad in chunk:
            fail(f"paging symbol {bad} in {fn} — refuse")

print("PASS: alias/folder prompt copy owned by Core")

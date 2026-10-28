#!/usr/bin/env python3
"""SEARCH-GRID-TYPE-01: a grid letter must not re-enter the field editor keyDown."""
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


def body(text, start, end):
    i = text.index(start)
    return text[i : text.index(end, i + len(start))]


need("func searchGridKeyRoute(" in core, "Core route missing")
need("func searchGridKeyCommit(" in core, "Core commit missing")
need("func searchGridTypedCharacters(" in core, "Core typed-character fallback missing")
need("testSearchGridKeyRouteDoesNotReenterTheFieldEditor" in tests, "Core route test missing")
need("testSearchGridKeyCommitLandsTheLetter" in tests, "Core commit test missing")

route = body(core, "public static func searchGridKeyRoute(", "public static func searchQuery(")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage", "keyDown"):
    need(banned not in route, f"route must not page or dispatch keys ({banned})")
need("alreadyRouting { return .consume }" in route, "an in-progress route must be consumed")

begin = body(direct, "func beginSearch(with event: NSEvent)", "func deleteSearch(")
need("searchGridKeyRoute(" in begin, "beginSearch must ask Core")
need("searchGridTypedCharacters(" in begin, "beginSearch must recover an empty characters string")
need("searchGridKeyCommit(" in begin, "beginSearch must commit a letter the editor ignores")
need("interpretKeyEvents" in begin, "beginSearch must use the text input system")
need("editor.keyDown" not in begin, "beginSearch must not call the field editor keyDown")
need("insertText" not in begin, "beginSearch must not rely on insertText during keyDown")
need("replaceCharacters(in: full, with: query)" in begin, "a letter the editor ignores must be written into the editor")
need("validateEditing()" in begin, "the field value must match the editor after a grid letter")
need("suppressesEditorKeyDownEcho = true" in begin, "beginSearch must hold the echo off")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    need(banned not in begin, f"beginSearch must not page ({banned})")

field = body(direct, "private final class LauncherSearchField", "private final class AliasFieldEditorBridge")
need("suppressesEditorKeyDownEcho" in field, "search field must know when a route is in progress")
need("override func keyDown(with event: NSEvent)" in field, "search field must swallow the echo")
echo = body(field, "override func keyDown(with event: NSEvent)", "override func draggingEntered")
need("currentEditor() != nil" in echo, "swallow only while the field editor is up")
need("super.keyDown" in echo, "a normal key still reaches the field")

if failures:
    print("FAIL: search grid key route")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: search grid key route")

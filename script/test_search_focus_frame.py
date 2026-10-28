#!/usr/bin/env python3
"""SEARCH-FOCUS-FRAME-01: grid typing and search clicks use a real frame."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
app_delegate = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
project = (root / "LaunchIcon.xcodeproj/project.pbxproj").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


def body(text, start, end):
    i = text.index(start)
    return text[i : text.index(end, i + len(start))]


need("func accessibilityFrameOnScreen(" in core, "Core frame policy missing")
need("func applicationAccessibilityFrame(" in core, "application frame policy missing")
need("testAccessibilityFramePrefersTheViewScreenFrame" in tests, "Core frame test missing")
need("testApplicationAccessibilityFrameUsesTheKeyWindow" in tests, "application frame test missing")

frame = body(core, "public static func accessibilityFrameOnScreen(", "public enum LauncherInactivePointerEvent")
for banned in ("showPage", "transitionToPage", "completePageTransition", "movePage"):
    need(banned not in frame, f"frame policy must not page ({banned})")

search = body(direct, "private final class LauncherSearchField", "private final class AliasFieldEditorBridge")
need("override func accessibilityFrame()" in search, "search field must publish its screen frame")
need("accessibilityFrameOnScreen" in search, "search field must ask Core")

editor = body(direct, "private final class LauncherFieldEditor", "private class LauncherTextDropField")
need("override func accessibilityFrame()" in editor, "field editor must publish the client field")
need("accessibilityFrameOnScreen" in editor, "field editor must ask Core")

panel = body(direct, "override var accessibilityFocusedUIElement", "var dismissHandler")
need("return self" in panel, "a non-control focus must be the window")
need("override func accessibilityFrame()" in panel, "panel must publish its screen frame")
need("accessibilityAttributeNames()" in panel, "panel must list position and size")
need(".position" in panel and ".size" in panel, "panel must publish position and size")
need("accessibilityFrameOnScreen" in panel, "panel frame must ask Core")
need("searchFieldForGridFocusFrame()" in panel, "grid root focus must publish the search field frame")
need("delegate as? NSView" in panel, "field editor focus must follow the client field")
need("setAccessibilityElement(true)" not in panel, "focused-element hook must not flatten the tree")
for banned in ("showPage", "movePage", "transitionToPage"):
    need(banned not in panel, f"focused element must not page ({banned})")

root_key = body(
    direct,
    "override func keyDown(with event: NSEvent) {\n        guard !LauncherLayout.shouldConsumeLauncherKeyEquivalent",
    "func displayName(for candidate: AppCandidate)",
)
need("beginSearch(with: event)" in root_key, "grid root must start search from a letter")
need("movePage(by:" in root_key, "grid root arrows must use the existing page function")
need("deleteSearch(" in root_key, "grid root must delete a search query")
for banned in ("showPage", "transitionToPage", "completePageTransition"):
    need(banned not in root_key, f"root keyDown must not name paging ({banned})")

app_class = body(app_delegate, "@objc(LauncherApplication)", "@main")
need("override func accessibilityFrame()" in app_class, "application must publish a screen frame")
need("accessibilityAttributeNames()" in app_class, "application must list position and size")
need(".position" in app_class and ".size" in app_class, "application must publish position and size")
need("applicationAccessibilityFrame(" in app_class, "application frame must ask Core")
need("LauncherApplication.shared" in app_delegate, "main must create the application subclass")
need(app_delegate.index("LauncherApplication.shared") < app_delegate.index("application.delegate"), "subclass must exist before the delegate runs")
principal = "INFOPLIST_KEY_NSPrincipalClass = LauncherApplication;"
need(project.count(principal) == 2, "Direct debug and release must name the principal class")
for banned in ("showPage", "movePage", "transitionToPage"):
    need(banned not in app_class, f"application frame must not page ({banned})")

if failures:
    print("FAIL: search focus frame")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: search focus frame")

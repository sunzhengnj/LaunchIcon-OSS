#!/usr/bin/env python3
"""Settings-open chrome is one Core checklist. Fade pins do not force layers."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
direct = "".join(p.read_text(encoding="utf-8") for p in [ROOT / "Sources/Direct/LauncherWindowController.swift", *sorted((ROOT / "Sources/Direct").glob("LauncherWindowController+*.swift"))])
tests = (ROOT / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


def blocks(src: str, signature: str) -> list[str]:
    found = []
    start = 0
    while True:
        i = src.find(signature, start)
        if i < 0:
            break
        j = src.find("{", i)
        if j < 0:
            fail(f"no body for {signature}")
        depth = 0
        for k in range(j, len(src)):
            if src[k] == "{":
                depth += 1
            elif src[k] == "}":
                depth -= 1
                if depth == 0:
                    found.append(src[j : k + 1])
                    start = k + 1
                    break
        else:
            fail(f"unbalanced {signature}")
    return found


if "SETTINGS-OPEN-CHROME-POLICY-01" not in core:
    fail("Core missing SETTINGS-OPEN-CHROME-POLICY-01")
if "func settingsOpenChromeActions(" not in core:
    fail("Core missing settingsOpenChromeActions")
if "testSettingsOpenChromeActionsFollowOneChecklist" not in tests:
    fail("Core test missing")

policy = blocks(core, "public static func settingsOpenChromeActions(")
if len(policy) != 1:
    fail(f"expected one settingsOpenChromeActions, found {len(policy)}")
body = policy[0]
# Unconditional rows stay after the state rows, in this order.
for earlier, later in (
    ("actions.append(.dismissToast)", "actions.append(.invalidateDeferredGridRearrange)"),
    ("actions.append(.invalidateDeferredGridRearrange)", "actions.append(.clearIconSampling)"),
    ("actions.append(.clearIconSampling)", "actions.append(.resetExternalDragDockReveal)"),
    ("actions.append(.resetExternalDragDockReveal)", "actions.append(.cancelPendingPageInput)"),
):
    if body.find(earlier) < 0 or body.find(later) < 0 or body.find(earlier) > body.find(later):
        fail(f"checklist order broken: {earlier} before {later}")
for forbidden in (
    "settleReorderSlideForDismissal",
    "settleMergeFlightForDismissal",
    "settleDropLandingForDismissal",
    "settleFolderLandingForDismissal",
    "settleSearchChromeForDismissal",
    "settleDissolvedGridFadeForDismissal",
    "settleFolderChromeForDismissal",
    "settleLaunchFeedbackForDismissal",
    "settlePageButtonHoverForDismissal",
    "settleToastFadeForDismissal",
    "showPage(",
    "transitionToPage(",
    "completePageTransition(",
):
    if forbidden in body:
        fail(f"policy contains {forbidden}")

prep = blocks(direct, "func prepareChromeForOpeningSettings()")
if len(prep) != 1:
    fail(f"expected one prepareChrome, found {len(prep)}")
chrome = prep[0]
if chrome.count("settingsOpenChromeActions(") != 1:
    fail("prepareChrome must ask the checklist once")
expected_cases = [
    "case .dismissToast:",
    "case .closeFolder:",
    "case .cancelMarquee:",
    "case .cancelItemDrag:",
    "case .cancelIconContextMenu:",
    "case .resetPinchDismiss:",
    "case .clearDropHighlight:",
    "case .clearSearchKeyboardHighlight:",
    "case .abortSearchField:",
    "case .invalidateDeferredGridRearrange:",
    "case .clearIconSampling:",
    "case .resetExternalDragDockReveal:",
    "case .cancelPendingPageInput:",
]
cursor = -1
for case in expected_cases:
    at = chrome.find(case)
    if at < 0 or at <= cursor:
        fail(f"prepareChrome switch missing or reordered {case}")
    if chrome.count(case) != 1:
        fail(f"prepareChrome handles {case} more than once")
    cursor = at
for token in (
    "hideToast(animated: false)",
    "closeFolder(immediately: true)",
    "cancelMarquee(keepSelection: true)",
    "cancelInProgressItemDragIfNeeded()",
    "cancelIconContextMenuBecauseLauncherIsDismissing()",
    "resetPinchDismissBecauseLauncherIsDismissing()",
    "clearDropHighlightIfAllowed(animatedReorder: false)",
    "clearSearchKeyboardHighlightBecauseLauncherIsDismissing()",
    "abortSearchFieldForSettingsOpen()",
    "invalidateDeferredGridRearrange()",
    "clearIconSamplingBecauseLauncherIsDismissing()",
    "cancelExternalDragDockRevealBecauseLauncherIsDismissing()",
    "cancelPendingPageInput()",
):
    if chrome.count(token) != 1:
        fail(f"prepareChrome must perform {token} once, found {chrome.count(token)}")
abort = blocks(direct, "func abortSearchFieldForSettingsOpen()")
if len(abort) != 1:
    fail(f"expected one abortSearchFieldForSettingsOpen, found {len(abort)}")
abort_body = abort[0]
if abort_body.count("searchField.abortEditing()") != 1:
    fail("settings search abort must abort the field editor once")
if abort_body.find("discardSearchCompositionBecauseWindowResignedKey()") < 0:
    fail("settings search abort must discard the composition first")
if abort_body.find("discardSearchCompositionBecauseWindowResignedKey()") > abort_body.find("searchField.abortEditing()"):
    fail("discard must run before abortEditing")
if abort_body.count("postSearchCancelAccessibilityTreeChangeIfNeeded()") != 1:
    fail("settings search abort must refresh accessibility after the editor is gone")
if abort_body.find("searchField.abortEditing()") > abort_body.find("postSearchCancelAccessibilityTreeChangeIfNeeded()"):
    fail("accessibility refresh must follow abortEditing")
for forbidden in (
    "settleReorderSlideForDismissal()",
    "settleMergeFlightForDismissal()",
    "settleFolderChromeForDismissal()",
    "settleDissolvedGridFadeForDismissal()",
    "settleSearchChromeForDismissal()",
    "cancelIconPrefetchBecauseLauncherIsDismissing",
    "cancelTileIconLoadsBecauseLauncherIsDismissing",
    "showPage(",
    "transitionToPage(",
    "completePageTransition(",
):
    if forbidden in chrome:
        fail(f"prepareChrome still contains {forbidden}")

# Looking for an in-flight fade must not create a layer on a quiet view.
for signature in (
    "private func pinInFlightSearchChrome()",
    "private func snapInFlightSearchChromeFadeForMotionChange()",
    "private func pinInFlightDissolvedGridFade()",
    "private func snapInFlightDissolvedGridFadeForMotionChange()",
):
    found = blocks(direct, signature)
    if len(found) != 1:
        fail(f"expected one {signature}, found {len(found)}")
    if "wantsLayer = true" in found[0]:
        fail(f"{signature} forces layer-backing while inspecting a fade")

print("PASS: settings-open chrome policy")

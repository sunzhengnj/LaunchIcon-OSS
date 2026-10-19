#!/usr/bin/env python3
"""Closing settings restores the launcher when showSettings hid a visible grid."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
app = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()

def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    raise SystemExit(1)

if "shouldHideLauncherToShowSettings" not in core:
    fail("Core missing shouldHideLauncherToShowSettings")
if "shouldRestoreLauncherWhenSettingsCloses" not in core:
    fail("Core missing shouldRestoreLauncherWhenSettingsCloses")
if "didHideLauncherToShowSettings" not in app:
    fail("AppDelegate missing didHideLauncherToShowSettings")
if "shouldHideLauncherToShowSettings" not in app:
    fail("showSettings missing hide gate")
if "settingsWindowWillClose" not in app:
    fail("AppDelegate missing settingsWindowWillClose")
if "shouldRestoreLauncherWhenSettingsCloses" not in app:
    fail("settingsWindowWillClose missing restore gate")
if "launcherController?.show()" not in app:
    fail("settings close must call launcher show()")
# showSettings must not unconditionally hide
show_start = app.index("private func showSettings()")
show_body = app[show_start:show_start + 1600]
if "launcherController?.hide(" not in show_body:
    fail("showSettings must still hide when gate passes")
if "shouldHideLauncherToShowSettings" not in show_body:
    fail("showSettings must consult shouldHideLauncherToShowSettings before hide")
if "shouldAnimateLauncherHideForSettingsHandoff" not in show_body:
    fail("showSettings hide must use settings handoff animated gate")
if show_body.count("launcherController?.hide(") != 1:
    fail("showSettings should have exactly one hide call")
if "onWindowWillClose" not in settings:
    fail("Settings missing onWindowWillClose")
if "func windowWillClose" not in settings:
    fail("Settings must implement windowWillClose")
if "onWindowWillClose?()" not in settings:
    fail("windowWillClose must fire onWindowWillClose")
if "isReleasedWhenClosed = false" not in settings:
    fail("settings window must survive close for reuse")
if "onWindowWillClose = " not in app:
    fail("AppDelegate must wire onWindowWillClose")
if "shouldClearSettingsLauncherRestoreFlag" not in core:
    fail("Core missing shouldClearSettingsLauncherRestoreFlag")
if "clearSettingsLauncherRestoreIfLauncherVisible" not in app:
    fail("AppDelegate missing clearSettingsLauncherRestoreIfLauncherVisible")
if "clearSettingsLauncherRestoreIfLauncherVisible()" not in app:
    fail("onVisibilityChanged must clear restore flag when launcher is visible")
if "shouldClearSettingsLauncherRestoreFlag" not in app:
    fail("clear helper must consult Core gate")
if "shouldAnimateLauncherHideForSettingsHandoff" not in core:
    fail("Core missing shouldAnimateLauncherHideForSettingsHandoff")
if "shouldAnimateLauncherHideForSettingsHandoff" not in app:
    fail("showSettings must pass settings handoff animated gate to hide")
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
if "func hide(animated: Bool = true)" not in direct:
    fail("LauncherWindowController missing hide(animated:)")
hide_start = direct.index("func hide(animated: Bool = true)")
hide_end = direct.index("@objc private func windowDidUpdate", hide_start)
hide_body = direct[hide_start:hide_end]
if "if !animated" not in hide_body:
    fail("hide(animated:) missing immediate branch")
if "orderOut(nil)" not in hide_body:
    fail("immediate hide must orderOut")
# Immediate branch must return before animateLauncherPresence
imm = hide_body.find("if !animated")
fade = hide_body.find("animateLauncherPresence(visible: false")
if imm < 0 or fade < 0 or imm > fade:
    fail("immediate hide must run before dismiss fade")
if "return" not in hide_body[imm:fade]:
    fail("immediate hide must return before fade path")
if "shouldAnimateLauncherShowForSettingsHandoff" not in core:
    fail("Core missing shouldAnimateLauncherShowForSettingsHandoff")
if "shouldAnimateLauncherShowForSettingsHandoff" not in app:
    fail("settingsWindowWillClose must pass show handoff animated gate")
if "func show(animated: Bool = true)" not in direct:
    fail("LauncherWindowController missing show(animated:)")
if "snapLauncherPresenceVisible" not in direct:
    fail("Direct missing snapLauncherPresenceVisible")
show_start = direct.index("func show(animated: Bool = true)")
show_end = direct.index("func hide(animated: Bool = true)", show_start)
show_body = direct[show_start:show_end]
if "snapLauncherPresenceVisible()" not in show_body:
    fail("show(animated: false) must snap presence")
if "if animated" not in show_body:
    fail("show must branch on animated")
if "shouldClearSearchQueryWhenPreparingPresentation" not in core:
    fail("Core missing shouldClearSearchQueryWhenPreparingPresentation")
if "shouldClearSearchQueryWhenPreparingPresentation" not in direct:
    fail("show must gate prepareForPresentation query clear")
if "clearsSearchQuery:" not in direct:
    fail("prepareForPresentation must take clearsSearchQuery")
prep_start = direct.index("func prepareForPresentation(clearsSearchQuery:")
prep_end = direct.index("func applyDeferredVisualState()", prep_start)
prep = direct[prep_start:prep_end]
if "guard clearsSearchQuery else" not in prep:
    fail("prepareForPresentation must skip query clear when gated off")
if "shouldEnsureSearchResultsChromeWhenPreservingQuery" not in prep:
    fail("prepare when preserving query must ensure search results chrome")
show_start = direct.index("func show(animated: Bool = true)")
show_end = direct.index("func hide(animated: Bool = true)", show_start)
show_body = direct[show_start:show_end]
if "preservesQueryAcrossHandoff: !animated" not in show_body:
    fail("settings handoff restore (animated: false) must preserve query")
if "shouldParkSearchFocusForSettingsHandoff" not in core:
    fail("Core missing shouldParkSearchFocusForSettingsHandoff")
if "shouldRestoreSearchFocusAfterSettingsHandoff" not in core:
    fail("Core missing shouldRestoreSearchFocusAfterSettingsHandoff")
if "pendingSettingsHandoffSearchFocus" not in direct:
    fail("Direct missing pendingSettingsHandoffSearchFocus")
if "searchFieldHoldsKeyboardFocus" not in direct:
    fail("Direct missing searchFieldHoldsKeyboardFocus")
if "focusSearchFieldForSettingsHandoffRestore" not in direct:
    fail("Direct missing focusSearchFieldForSettingsHandoffRestore")
hide_start = direct.index("func hide(animated: Bool = true)")
hide_end = direct.index("@objc private func windowDidUpdate", hide_start)
hide_body = direct[hide_start:hide_end]
if "shouldParkSearchFocusForSettingsHandoff" not in hide_body:
    fail("immediate hide must park search focus")
show_start = direct.index("func show(animated: Bool = true)")
show_end = direct.index("func hide(animated: Bool = true)", show_start)
show_body = direct[show_start:show_end]
if "shouldRestoreSearchFocusAfterSettingsHandoff" not in show_body:
    fail("show must consult search focus restore gate")
if "focusSearchFieldForSettingsHandoffRestore()" not in show_body:
    fail("settings handoff restore must focus search field")
if "shouldParkSearchResultsChromeForSettingsHandoff" not in core:
    fail("Core missing shouldParkSearchResultsChromeForSettingsHandoff")
if "shouldRestoreSearchResultsChromeAfterSettingsHandoff" not in core:
    fail("Core missing shouldRestoreSearchResultsChromeAfterSettingsHandoff")
if "shouldEnsureSearchResultsChromeWhenPreservingQuery" not in core:
    fail("Core missing shouldEnsureSearchResultsChromeWhenPreservingQuery")
if "pendingSettingsHandoffSearchResultsChrome" not in direct:
    fail("Direct missing pendingSettingsHandoffSearchResultsChrome")
if "searchQueryIsNonEmpty" not in direct:
    fail("Direct missing searchQueryIsNonEmpty")
if "snapSearchResultsChromeForSettingsHandoffRestore" not in direct:
    fail("Direct missing snapSearchResultsChromeForSettingsHandoffRestore")
hide_start = direct.index("func hide(animated: Bool = true)")
hide_end = direct.index("@objc private func windowDidUpdate", hide_start)
hide_body = direct[hide_start:hide_end]
if "shouldParkSearchResultsChromeForSettingsHandoff" not in hide_body:
    fail("immediate hide must park search results chrome")
show_start = direct.index("func show(animated: Bool = true)")
show_end = direct.index("func hide(animated: Bool = true)", show_start)
show_body = direct[show_start:show_end]
if "shouldRestoreSearchResultsChromeAfterSettingsHandoff" not in show_body:
    fail("show must consult search results chrome restore gate")
if "snapSearchResultsChromeForSettingsHandoffRestore()" not in show_body:
    fail("settings handoff restore must snap search results chrome")
prep_idx = direct.index("func prepareForPresentation")
prep_body = direct[prep_idx:prep_idx + 2500]
if "shouldEnsureSearchResultsChromeWhenPreservingQuery" not in prep_body:
    fail("prepareForPresentation must ensure results chrome when preserving query")
if "shouldSuppressPageIndicatorAfterSettingsHandoff" not in core:
    fail("Core missing shouldSuppressPageIndicatorAfterSettingsHandoff")
if "shouldEnsurePageIndicatorSuppressedWhenPreservingQuery" not in core:
    fail("Core missing shouldEnsurePageIndicatorSuppressedWhenPreservingQuery")
if "snapPageIndicatorSuppressedForSettingsHandoffRestore" not in direct:
    fail("Direct missing snapPageIndicatorSuppressedForSettingsHandoffRestore")
hide_start = direct.index("func hide(animated: Bool = true)")
hide_end = direct.index("@objc private func windowDidUpdate", hide_start)
hide_body = direct[hide_start:hide_end]
if "snapPageIndicatorSuppressedForSettingsHandoffRestore()" not in hide_body:
    fail("immediate hide with non-empty query must snap page indicator suppressed")
show_start = direct.index("func show(animated: Bool = true)")
show_end = direct.index("func hide(animated: Bool = true)", show_start)
show_body = direct[show_start:show_end]
if "shouldSuppressPageIndicatorAfterSettingsHandoff" not in show_body:
    fail("show must consult page indicator suppress gate")
if "snapPageIndicatorSuppressedForSettingsHandoffRestore()" not in show_body:
    fail("settings handoff restore must snap page indicator suppressed")
prep_start = direct.index("func prepareForPresentation(clearsSearchQuery:")
prep_end = direct.index("func applyDeferredVisualState()", prep_start)
prep = direct[prep_start:prep_end]
if "shouldEnsurePageIndicatorSuppressedWhenPreservingQuery" not in prep:
    fail("prepare when preserving query must suppress page indicator")
if "shouldSuppressPageArrowsAfterSettingsHandoff" not in core:
    fail("Core missing shouldSuppressPageArrowsAfterSettingsHandoff")
if "shouldEnsurePageArrowsSuppressedWhenPreservingQuery" not in core:
    fail("Core missing shouldEnsurePageArrowsSuppressedWhenPreservingQuery")
if "snapPageArrowsSuppressedForSettingsHandoffRestore" not in direct:
    fail("Direct missing snapPageArrowsSuppressedForSettingsHandoffRestore")
hide_start = direct.index("func hide(animated: Bool = true)")
hide_end = direct.index("@objc private func windowDidUpdate", hide_start)
hide_body = direct[hide_start:hide_end]
if "snapPageArrowsSuppressedForSettingsHandoffRestore()" not in hide_body:
    fail("immediate hide with non-empty query must snap page arrows suppressed")
show_start = direct.index("func show(animated: Bool = true)")
show_end = direct.index("func hide(animated: Bool = true)", show_start)
show_body = direct[show_start:show_end]
if "shouldSuppressPageArrowsAfterSettingsHandoff" not in show_body:
    fail("show must consult page arrows suppress gate")
if "snapPageArrowsSuppressedForSettingsHandoffRestore()" not in show_body:
    fail("settings handoff restore must snap page arrows suppressed")
prep_start = direct.index("func prepareForPresentation(clearsSearchQuery:")
prep_end = direct.index("func applyDeferredVisualState()", prep_start)
prep = direct[prep_start:prep_end]
if "shouldEnsurePageArrowsSuppressedWhenPreservingQuery" not in prep:
    fail("prepare when preserving query must suppress page arrows")
if "shouldSnapSearchFooterChromeAfterSettingsHandoff" not in core:
    fail("Core missing shouldSnapSearchFooterChromeAfterSettingsHandoff")
if "shouldEnsureSearchFooterChromeWhenPreservingQuery" not in core:
    fail("Core missing shouldEnsureSearchFooterChromeWhenPreservingQuery")
if "snapSearchFooterChromeForSettingsHandoffRestore" not in direct:
    fail("Direct missing snapSearchFooterChromeForSettingsHandoffRestore")
hide_start = direct.index("func hide(animated: Bool = true)")
hide_end = direct.index("@objc private func windowDidUpdate", hide_start)
hide_body = direct[hide_start:hide_end]
if "snapSearchFooterChromeForSettingsHandoffRestore()" not in hide_body:
    fail("immediate hide with non-empty query must snap search footer chrome")
show_start = direct.index("func show(animated: Bool = true)")
show_end = direct.index("func hide(animated: Bool = true)", show_start)
show_body = direct[show_start:show_end]
if "shouldSnapSearchFooterChromeAfterSettingsHandoff" not in show_body:
    fail("show must consult search footer chrome snap gate")
if "snapSearchFooterChromeForSettingsHandoffRestore()" not in show_body:
    fail("settings handoff restore must snap search footer chrome")
prep_start = direct.index("func prepareForPresentation(clearsSearchQuery:")
prep_end = direct.index("func applyDeferredVisualState()", prep_start)
prep = direct[prep_start:prep_end]
if "shouldEnsureSearchFooterChromeWhenPreservingQuery" not in prep:
    fail("prepare when preserving query must ensure search footer chrome")
if 'L("Esc 清除搜索")' not in direct:
    fail("search footer snap must land Esc-clear navigation hint")
if "shouldSnapSearchAdjacentChromeAfterSettingsHandoff" not in core:
    fail("Core missing shouldSnapSearchAdjacentChromeAfterSettingsHandoff")
if "shouldEnsureSearchAdjacentChromeWhenPreservingQuery" not in core:
    fail("Core missing shouldEnsureSearchAdjacentChromeWhenPreservingQuery")
if "snapSearchAdjacentChromeForSettingsHandoffRestore" not in direct:
    fail("Direct missing snapSearchAdjacentChromeForSettingsHandoffRestore")
hide_start = direct.index("func hide(animated: Bool = true)")
hide_end = direct.index("@objc private func windowDidUpdate", hide_start)
hide_body = direct[hide_start:hide_end]
if "snapSearchAdjacentChromeForSettingsHandoffRestore()" not in hide_body:
    fail("immediate hide with non-empty query must snap search-adjacent chrome")
show_start = direct.index("func show(animated: Bool = true)")
show_end = direct.index("func hide(animated: Bool = true)", show_start)
show_body = direct[show_start:show_end]
if "shouldSnapSearchAdjacentChromeAfterSettingsHandoff" not in show_body:
    fail("show must consult search-adjacent chrome snap gate")
if "snapSearchAdjacentChromeForSettingsHandoffRestore()" not in show_body:
    fail("settings handoff restore must snap search-adjacent chrome")
prep_start = direct.index("func prepareForPresentation(clearsSearchQuery:")
prep_end = direct.index("func applyDeferredVisualState()", prep_start)
prep = direct[prep_start:prep_end]
if "shouldEnsureSearchAdjacentChromeWhenPreservingQuery" not in prep:
    fail("prepare when preserving query must ensure search-adjacent chrome")
print("PASS: settings close restores launcher when it hid the grid")

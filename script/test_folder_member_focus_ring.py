#!/usr/bin/env python3
"""Guard: folder-member focus-ring chrome-in-flight / land parity with title fill."""
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

need("folderMemberFocusFillAlpha" in core, "Core missing folderMemberFocusFillAlpha")
need("folderPanelChromeInFlight" in core, "Core missing folderPanelChromeInFlight")
need("tileChromeFillFadeDuration" in core, "Core missing tileChromeFillFadeDuration")
need("folderTitleEditUnderlineFadeDuration" in core, "Core missing title underline duration")
need("testFolderMemberFocusFillMatchesTitleChromeFlightGate" in tests, "Core test missing")

need("func refreshVisibleMemberFocusChrome()" in direct, "overlay missing refreshVisibleMemberFocusChrome")

open_start = direct.index("func animateOpen(collapse:")
close_start = direct.index("func animateClose(")
open_body = direct[open_start:close_start]
need(
    "refreshVisibleMemberFocusChrome()" in open_body,
    "animateOpen must refresh member focus chrome when flight begins",
)

close_body = direct[close_start:close_start + 4500]
need(
    "refreshVisibleMemberFocusChrome()" in close_body,
    "animateClose must refresh member focus chrome when flight begins",
)
need(
    "isAnimatingClose = true" in close_body
    and close_body.index("refreshVisibleMemberFocusChrome()")
    > close_body.index("isAnimatingClose = true"),
    "close must refresh after isAnimatingClose=true",
)

land_open = direct[
    direct.index("func focusOpenedFolderMemberAfterChromeLands") : direct.index(
        "func folderOpenFocusOwner"
    )
]
need("refreshFocusChrome()" in land_open, "open land must refreshFocusChrome")
land_close = direct[
    direct.index("func finishFolderCloseChromeLand") : direct.index(
        "func focusedOpenFolderMember"
    )
]
need(
    "refreshFocusChrome()" in land_close or "focusMainGridEntry" in land_close,
    "close land focus path intact",
)

chrome_idx = direct.index("private func updateDropTargetAppearance(focused: Bool? = nil)")
chrome_chunk = direct[chrome_idx : chrome_idx + 2500]
need("fillMode = .backwards" in chrome_chunk, "member focus fill must use fillMode.backwards")
need("presentedChromeFillAlpha" in chrome_chunk, "member fill must read presentation")
need("tileChromeFillFadeDuration" in chrome_chunk, "member fill must use shared fade duration")

need("folderCloseGridFocusID" in direct, "must not regress close-focus")
need("folderOpenEmptyFocusesTitle" in direct, "must not regress empty-title")
need("focusMainGridEntry" in direct, "must not regress close-focus main grid")

for label, chunk in (
    (
        "Core member fill",
        core[
            core.index("folderMemberFocusFillAlpha") : core.index(
                "folderMemberFocusFillAlpha"
            )
            + 400
        ],
    ),
    (
        "animateOpen refresh",
        open_body[
            open_body.index("refreshVisibleMemberFocusChrome") : open_body.index(
                "refreshVisibleMemberFocusChrome"
            )
            + 200
        ],
    ),
):
    need(
        "showPage(" not in chunk
        and "pageTransition" not in chunk
        and "pageAnimationDuration" not in chunk,
        f"{label} must not retune paging",
    )

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: folder member focus-ring (chrome-in-flight / land parity with title fill)")

#!/usr/bin/env python3
"""ESC-CANCEL-ITEM-DRAG-01 / ESC-CANCEL-DRAG-RELEASE-01.

Esc stops an airborne icon drag before folder close, multi-select clear, and
search clear. The synthetic leftMouseUp must not also land a drop, dismiss,
or close the folder.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = "".join(p.read_text(encoding="utf-8") for p in [root / "Sources/Direct/LauncherWindowController.swift", *sorted((root / "Sources/Direct").glob("LauncherWindowController+*.swift"))])
core = (root / "Sources/Core/LauncherLayout.swift").read_text(encoding="utf-8")
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text(encoding="utf-8")
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


need("ESC-CANCEL-ITEM-DRAG-01" in direct, "Esc-cancel-drag marker")
need("ESC-CANCEL-DRAG-RELEASE-01" in direct, "release side-effect marker")
need("func cancelInProgressItemDragIfNeeded()" in direct, "cancel helper missing")
need("NSEvent.mouseEvent" in direct and "leftMouseUp" in direct,
     "must synthesize leftMouseUp (no public NSDraggingSession.cancel)")
need("itemDragEscapeCancelInFlight = true" in direct,
     "flag must be set before the synthetic mouse-up is queued")
need("func suppressesPointerReleaseSideEffects(escapeCancelInFlight: Bool)" in core,
     "Core must own the release side-effect gate")
need("testItemDragEscapeCancelSuppressesPointerRelease" in tests,
     "Core test must cover the release gate")

esc_start = direct.index("func handleEscape() -> Bool")
esc_end = direct.index("var highlightedLaunchKey", esc_start)
esc = direct[esc_start:esc_end]
need("cancelInProgressItemDragIfNeeded()" in esc, "handleEscape must call cancel helper")
# Order: rename → drag → folder → multi-select → search
need(esc.index("cancelTitleEditingIfActive") < esc.index("cancelInProgressItemDragIfNeeded()"),
     "rename cancel before drag cancel")
need(esc.index("cancelInProgressItemDragIfNeeded()") < esc.index("openedFolderID"),
     "drag cancel before close folder")
need("TOAST-ESC-DISMISS-01" in esc or "shouldDismissToastOnEscape" in esc,
     "Esc must dismiss a visible toast before folder close")
need(esc.index("shouldDismissToastOnEscape") < esc.index("openedFolderID"),
     "toast dismiss before close folder")
need(esc.index("openedFolderID") < esc.index("itemSelection.isEmpty"),
     "close folder before multi-select clear")
need(esc.index("cancelInProgressItemDragIfNeeded()") < esc.index("itemSelection.isEmpty"),
     "drag cancel before multi-select clear")
need(esc.index("cancelInProgressItemDragIfNeeded()") < esc.index("clearSearchIfNeeded()"),
     "drag cancel before search clear")

send_start = direct.index("override func sendEvent(_ event: NSEvent)")
send_end = direct.index("private static func shouldDropInactivePointerEvent", send_start)
send = direct[send_start:send_end]
need("consumeItemDragEscapeCancelPointerRelease()" in send,
     "panel must consume the synthetic mouse-up")
need(send.index("consumeItemDragEscapeCancelPointerRelease()") < send.index("shouldDismiss"),
     "synthetic mouse-up must be consumed before dismiss")

drop_start = direct.index("func applyDrop(")
drop_end = direct.index("func dropLandsInOpenFolder", drop_start)
drop = direct[drop_start:drop_end]
need("suppressesPointerReleaseSideEffects" in drop,
     "applyDrop must refuse an Escape-cancel release before clearing dragPreview")
need(drop.index("suppressesPointerReleaseSideEffects") < drop.index("dragPreview = nil"),
     "refuse the drop before clearing the fly-home preview")

folder_start = direct.index("final class FolderOverlayView")
folder_end = direct.index("func discardMarkedTitleComposition", folder_start)
folder = direct[folder_start:folder_end]
need("suppressesPointerRelease()" in folder, "folder mouse-up must ignore the synthetic release")
need("suppressesPointerRelease()" in folder[folder.index("override func mouseUp"):],
     "folder mouseUp must consult suppressesPointerRelease")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: Esc cancels in-progress item drag")

# DRAG-CANCEL-ON-HIDE-01
direct = "".join(p.read_text(encoding="utf-8") for p in [root / "Sources/Direct/LauncherWindowController.swift", *sorted((root / "Sources/Direct").glob("LauncherWindowController+*.swift"))])
if "cancelItemDragBecauseLauncherIsDismissing" not in direct:
    print("FAIL: hide must cancel in-progress item drag")
    raise SystemExit(1)
if "DRAG-CANCEL-ON-HIDE-01" not in direct:
    print("FAIL: DRAG-CANCEL-ON-HIDE-01 marker")
    raise SystemExit(1)
hide = direct[direct.index("func hide(animated"): direct.index("func hide(animated") + 3500]
if "cancelItemDragBecauseLauncherIsDismissing()" not in hide:
    print("FAIL: hide() must call cancelItemDragBecauseLauncherIsDismissing")
    raise SystemExit(1)
print("PASS: hide cancels in-progress item drag")

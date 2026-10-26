#!/usr/bin/env python3
"""Guard: Direct marquee wiring uses Core LauncherMarquee and never pages."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
docs = (root / "Docs/MULTI_SELECT_DESIGN.md").read_text()
failures = []

def need(cond, msg):
    if not cond:
        failures.append(msg)

need("enum LauncherMarquee" in core, "Core missing LauncherMarquee")
need("activationDistance" in core, "Core missing activationDistance")
need("func canArm(" in core, "Core missing canArm")
need("suppressesDismissOnRelease" in core, "Core missing suppressesDismissOnRelease")
need("marqueeArmed" in direct, "Direct missing marqueeArmed state")
need("func armMarqueeIfNeeded" in direct, "Direct missing armMarqueeIfNeeded")
need("func updateMarquee" in direct, "Direct missing updateMarquee")
need("func endMarquee" in direct, "Direct missing endMarquee")
need("armMarqueeIfNeeded(with: event)" in direct, "Panel must arm on leftMouseDown")
need("updateMarquee(with: event)" in direct, "Panel must update on leftMouseDragged")
need("endMarquee(with: event)" in direct, "Panel must end on leftMouseUp")
need("LauncherMarquee.canArm(" in direct, "Direct must call Core canArm")
need("LauncherMarquee.hasActivated" in direct, "Direct must call hasActivated")
need("LauncherMarquee.clamped(" in direct, "Direct must clamp to page")
need("LauncherMarquee.hitIDs(" in direct, "Direct must hit test icons")
need("LauncherMarquee.selection(" in direct, "Direct must derive selection from base")
need("LauncherMarquee.suppressesDismissOnRelease" in direct, "Direct must suppress dismiss after activate")
need("didConsumeClick = true" in direct, "Activated marquee must consume click")
need("refreshItemSelectionChrome" in direct, "Marquee must refresh selection chrome")
need("cancelMarquee(keepSelection: true)" in direct, "Must cancel on page/present")
# Page-geometry harness extracts transitionToPage/showPage — cancel must live outside them.
need("func movePage(by direction: Int)" in direct and "cancelMarquee" in direct[
    direct.index("func movePage(by direction: Int)"):direct.index("func movePage(by direction: Int)") + 200
], "movePage must cancel marquee")
need("func updatePageDrag" in direct and "cancelMarquee" in direct[
    direct.index("func updatePageDrag"):direct.index("func updatePageDrag") + 400
], "updatePageDrag must cancel marquee")
need("func prepareForPresentation" in direct and "cancelMarquee" in direct[
    direct.index("func prepareForPresentation"):direct.index("func prepareForPresentation") + 800
], "prepareForPresentation must cancel marquee")
# Extracted paging methods must stay free of cancelMarquee.
for extracted in ("private func transitionToPage(", "private func showPage("):
    start = direct.index(extracted)
    # crude: until next "\n    private func " or "\n    func " at same indent after start+1
    rest = direct[start + len(extracted):]
    end_rel = len(rest)
    for marker in ("\n    private func ", "\n    func "):
        i = rest.find(marker)
        if 0 <= i < end_rel:
            end_rel = i
    body = direct[start:start + len(extracted) + end_rel]
    need("cancelMarquee" not in body, f"{extracted.strip()} must not call cancelMarquee (geometry harness)")
need("MARQUEE-WIRE" in docs or "Marquee" in docs, "Design doc must cover marquee")
need("wired" in docs.lower() or "MARQUEE-WIRE" in docs, "Design doc must note Direct wiring status")

# HARD: marquee methods must not call paging APIs
for name in ("armMarqueeIfNeeded", "updateMarquee", "endMarquee", "startsOnBlankArea", "marqueeItemFramesInRoot", "ensureMarqueeOverlay", "cancelMarquee"):
    key = f"func {name}"
    if key not in direct:
        # private func cancelMarquee / startsOnBlankArea
        key = f"private func {name}"
    if key not in direct:
        failures.append(f"missing {name}")
        continue
    start = direct.index(key)
    # Until next func at same indent roughly 2500 chars
    chunk = direct[start:start + 2500]
    for bad in ("showPage(", "movePage(", "transitionToPage(", "beginPaging", "queuedPage ="):
        # cancelMarquee is called FROM movePage/updatePageDrag/prepareForPresentation;
        # not from transitionToPage/showPage (page-geometry harness extracts those).
        if name == "cancelMarquee":
            continue
        need(bad not in chunk, f"{name} must not touch paging ({bad})")

# Overlay must be own chrome (no LaunchOS asset names)
overlay_start = direct.find("func ensureMarqueeOverlay")
if overlay_start > 0:
    chunk = direct[overlay_start:overlay_start + 800]
    need("NSColor.white" in chunk, "Marquee overlay should use neutral white chrome")
    need("LaunchOS" not in chunk and "launchpad" not in chunk.lower(), "No LaunchOS assets in overlay")

if failures:
    print("FAIL:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS test_marquee_wire.py")

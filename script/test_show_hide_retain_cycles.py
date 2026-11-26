#!/usr/bin/env python3
"""Guard: show/hide must not accumulate observers, FSEvents streams, or display links."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
dismissal = (root / "Sources/Direct/LauncherWindowController+Dismissal.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
watcher = (root / "Sources/Core/ApplicationDirectoryWatcher.swift").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


# NotificationCenter: selector observers are removed in deinit; block
# observers / watcher callbacks stay weak.
need("NotificationCenter.default.removeObserver(self)" in direct, "LWC must remove default-center observers in deinit")
need("NSWorkspace.shared.notificationCenter.removeObserver(self)" in direct, "LWC must remove workspace observers in deinit")
need("isolated deinit" in direct and "buttonScriptTimer?.invalidate()" in direct, "DEBUG button-script timer must stop on isolated deinit")
need("NotificationCenter.default.removeObserver(self)" in settings, "Settings must remove observers in deinit")

need("Unmanaged.passUnretained(self)" in watcher, "FSEvents context must not passRetained the watcher")
need("passRetained" not in watcher, "FSEvents must not retain the watcher through stream context")
need("deinit {\n        stop()" in watcher, "watcher deinit must stop the stream")
need("debounceWork?.cancel()" in watcher, "watcher stop must cancel the debounce item")
need("[weak self] in" in watcher, "debounce work must not retain the watcher")

need(
    "onChange: { [weak self] in" in direct and "onRootChanged: { [weak self] in" in direct,
    "catalog watcher callbacks must capture the window controller weakly",
)
need("directoryWatcher?.stop()" in direct, "flush/reload paths must stop the watcher")

# Display links retain their driver; drivers keep a weak owner and stop in
# isolated deinit so a hidden/released view cannot leak the pair.
for clock, owner in (
    ("ReorderSlideClock", "AppGridTileView"),
    ("PreviewPlateClock", "LauncherRootView"),
    ("PageWeightDriver", "PageIndicatorView"),
):
    need(f"private final class {clock}" in direct, f"{clock} missing")
    start = direct.index(f"private final class {clock}")
    chunk = direct[start : start + 1800]
    need("weak var owner:" in chunk, f"{clock} owner must be weak")
    need("link?.invalidate()" in chunk, f"{clock} stop must invalidate the display link")
    need("isolated deinit" in direct, "clock owners must stop on isolated deinit")

need("previewPlateClock.stop()" in direct, "root view deinit must stop the plate clock")
need("weightDriver.stop()" in direct, "page indicator deinit must stop the weight driver")
need("reorderClock.stop()" in direct, "tile deinit must stop the slide clock")
need("cancelIconPrefetchBecauseLauncherIsDismissing" in dismissal, "hide must cancel icon prefetch")

if failures:
    print("FAIL: show/hide retain cycles")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: show/hide retain cycles")

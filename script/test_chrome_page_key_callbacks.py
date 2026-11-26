#!/usr/bin/env python3
"""macOS-only event/callback regression for the production chrome keyDown.

Extracts the real LauncherChromeButton and paging/search helpers, and compiles
with real Core sources. Only the superclass is replaced with an NSButton spy to
observe entry into super.keyDown; no dispatch/resolver implementation is copied
or simulated. The root-view type is an unreachable fixture (the button has no
window), so root probe wiring and behavior *inside* NSButton remain out of scope.
No app/window is opened. Optional source path supports running against old code.
Exit 77 means NOT RUN on a non-macOS host, not a passing AppKit test.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def fixture(source):
    start = source.index("private final class LauncherChromeButton:")
    end = source.index("\nprivate func launcherPagingDirection(", start)
    button = source[start:end].replace(
        "LauncherChromeButton: NSButton", "LauncherChromeButton: FallbackRecordingButton", 1
    )
    helpers_end = source.index("\nfinal class PagingArrowButton:", end)
    helpers = source[end:helpers_end]
    cases = (ROOT / "Tests/DirectTests/ChromePageKeyCallbacks.swift").read_text()
    return "import AppKit\n" + cases.split("// PRODUCTION INSERTION\n")[0] + button + helpers + cases.split("// PRODUCTION INSERTION\n")[1]


def main():
    source = (Path(sys.argv[1]) if len(sys.argv) > 1 else
              ROOT / "Sources/Direct/LauncherWindowController.swift").read_text()
    swift = fixture(source)
    if sys.platform != "darwin":
        print("NOT RUN: AppKit callback test requires macOS and xcrun swiftc")
        return 77
    with tempfile.TemporaryDirectory(prefix="LaunchIcon-ChromePageKeys-") as directory:
        path = Path(directory)
        (path / "main.swift").write_text(swift)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6",
            *map(str, sorted((ROOT / "Sources/Core").glob("*.swift"))),
            str(path / "main.swift"), "-o", str(path / "test"),
        ], check=True)
        return subprocess.run([str(path / "test")], check=False).returncode


if __name__ == "__main__":
    sys.exit(main())

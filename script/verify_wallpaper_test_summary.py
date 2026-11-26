#!/usr/bin/env python3
"""Fail closed unless xcresulttool reports all nine scheduler tests passed."""
import json
import sys


def verify(summary):
    expected = {"totalTestCount": 9, "passedTests": 9, "failedTests": 0,
                "skippedTests": 0, "expectedFailures": 0}
    if not isinstance(summary, dict) or summary.get("result") != "Passed":
        raise ValueError("Scheduler test result must be Passed")
    for key, count in expected.items():
        if type(summary.get(key)) is not int or summary[key] != count:
            raise ValueError(f"Expected {key}={count}, got {summary.get(key)!r}")


if __name__ == "__main__":
    try:
        with open(sys.argv[1], encoding="utf-8") as source:
            summary = json.load(source)
        verify(summary)
    except (IndexError, OSError, ValueError) as error:
        print(f"Wallpaper test summary rejected: {error}", file=sys.stderr)
        sys.exit(1)
    print("Wallpaper scheduler XCTest summary: 9 passed, 0 failed/skipped/expected failures")

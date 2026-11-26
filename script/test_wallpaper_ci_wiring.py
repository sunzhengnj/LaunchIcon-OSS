#!/usr/bin/env python3
"""Local CI wiring tests with fixture tools; NOT Swift/macOS behavior evidence."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "script/verify_wallpaper_test_summary.py"
RUNNER = ROOT / "script/test_wallpaper_scheduler.sh"
PASSED = dict(result="Passed", totalTestCount=9, passedTests=9,
              failedTests=0, skippedTests=0, expectedFailures=0)


class SummaryGateTests(unittest.TestCase):
    def validate(self, value):
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / "summary.json"
            summary.write_text(json.dumps(value))
            return subprocess.run([sys.executable, str(VALIDATOR), str(summary)],
                                  capture_output=True, text=True)

    def test_accepts_exactly_nine_passed(self):
        result = self.validate(PASSED)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_zero_tests(self):
        self.assertNotEqual(self.validate(dict(PASSED, totalTestCount=0, passedTests=0)).returncode, 0)

    def test_rejects_skipped_tests(self):
        self.assertNotEqual(self.validate(dict(PASSED, passedTests=8, skippedTests=1)).returncode, 0)

    def test_rejects_failure(self):
        self.assertNotEqual(self.validate(dict(PASSED, result="Failed", passedTests=8, failedTests=1)).returncode, 0)

    def test_rejects_expected_failure(self):
        self.assertNotEqual(self.validate(dict(PASSED, expectedFailures=1)).returncode, 0)

    def test_rejects_missing_or_wrongly_typed_counts(self):
        for key in PASSED.keys() - {"result"}:
            for value in (None, "9", True):
                with self.subTest(key=key, value=value):
                    self.assertNotEqual(self.validate(dict(PASSED, **{key: value})).returncode, 0)
            missing = dict(PASSED)
            del missing[key]
            self.assertNotEqual(self.validate(missing).returncode, 0)

    def test_rejects_nonpassed_status(self):
        self.assertNotEqual(self.validate(dict(PASSED, result="unknown")).returncode, 0)


class RunnerControlFlowTests(unittest.TestCase):
    def run_fixture(self, *, build_status="0", summary_status="0", summary=None):
        self.assertTrue(RUNNER.is_file(), "Targeted runner has not been implemented")
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            tools = directory / "fixture-tools"
            tools.mkdir()
            trace = directory / "trace"
            # These external-command fixtures test shell propagation only. No Swift is executed.
            scripts = {
                "uname": '#!/bin/sh\nprintf "Darwin\\n"\n',
                "xcodebuild": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TRACE"\nexit "$FIXTURE_BUILD_STATUS"\n',
                "xcrun": '#!/bin/sh\nprintf "summary\\n" >> "$TRACE"\nprintf "%s\\n" "$FIXTURE_SUMMARY"\nexit "$FIXTURE_SUMMARY_STATUS"\n',
            }
            for name, content in scripts.items():
                path = tools / name
                path.write_text(content)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                       TRACE=str(trace), RUNNER_TEMP=str(directory),
                       FIXTURE_BUILD_STATUS=build_status, FIXTURE_SUMMARY_STATUS=summary_status,
                       FIXTURE_SUMMARY=json.dumps(PASSED if summary is None else summary))
            result = subprocess.run(["bash", str(RUNNER)], env=env, cwd=ROOT,
                                    capture_output=True, text=True)
            return result, trace.read_text().splitlines() if trace.exists() else []

    def test_only_nine_filter_then_direct_compile(self):
        result, calls = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 3, calls)
        self.assertIn("-only-testing:LaunchIconCoreTests/DesktopBackgroundDecodeSchedulerTests", calls[0])
        self.assertIn("-parallel-testing-enabled NO", calls[0])
        self.assertTrue(calls[0].endswith(" test"), calls)
        self.assertEqual(calls[1], "summary")
        self.assertIn("-scheme LaunchIconDirect", calls[2])
        self.assertTrue(calls[2].endswith(" build"), calls)
        self.assertNotIn("LaunchIconUITests", " ".join(calls))

    def test_build_exit_77_is_failure_not_skip(self):
        result, calls = self.run_fixture(build_status="77")
        self.assertEqual(result.returncode, 77)
        self.assertEqual(len(calls), 1)

    def test_build_failure_stops_before_summary_or_direct(self):
        result, calls = self.run_fixture(build_status="65")
        self.assertEqual(result.returncode, 65)
        self.assertEqual(len(calls), 1)

    def test_summary_command_failure_stops_before_direct(self):
        result, calls = self.run_fixture(summary_status="77")
        self.assertEqual(result.returncode, 77)
        self.assertEqual(len(calls), 2)

    def test_zero_test_summary_stops_before_direct(self):
        result, calls = self.run_fixture(summary=dict(PASSED, totalTestCount=0, passedTests=0))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)

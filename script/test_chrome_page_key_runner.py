#!/usr/bin/env python3
"""Linux-capable tests of harness extraction and runner failure propagation.

Compiler/process calls are mocked where macOS is required. These tests are NOT
AppKit execution evidence. The shell test really executes the non-macOS path.
"""
import io
from contextlib import redirect_stdout
from pathlib import Path
import runpy
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "script/test_chrome_page_key_callbacks.py"
MODULE = runpy.run_path(str(RUNNER))
SOURCE = (ROOT / "Sources/Direct/LauncherWindowController.swift").read_text()


class ChromeRunnerTests(unittest.TestCase):
    def invoke(self, run):
        with patch.object(sys, "platform", "darwin"), patch.object(sys, "argv", [str(RUNNER)]), \
                patch.object(subprocess, "run", side_effect=run):
            return MODULE["main"]()

    def test_embeds_production_class_and_main_actor_helper(self):
        swift = MODULE["fixture"](SOURCE)
        start = SOURCE.index("private final class LauncherChromeButton:")
        end = SOURCE.index("\nprivate func launcherPagingDirection(", start)
        expected = SOURCE[start:end].replace(
            "LauncherChromeButton: NSButton", "LauncherChromeButton: FallbackRecordingButton", 1
        )
        self.assertIn(expected, swift)
        self.assertIn("@MainActor\nprivate func launcherKeyboardProbe(", swift)
        self.assertNotIn("public static func resolveKeyboardCommand(", swift)
        self.assertIn('fatalError("root probe is outside this rootless-button fixture")', swift)

    def test_compile_then_execute_actual_generated_file(self):
        commands = []

        def run(command, check):
            commands.append(command)
            if len(commands) == 1:
                self.assertTrue(check)
                self.assertEqual(command[:4], ["xcrun", "swiftc", "-swift-version", "6"])
                core = sorted((ROOT / "Sources/Core").glob("*.swift"))
                self.assertEqual(command[4:-3], list(map(str, core)))
                swift = Path(command[-3])
                self.assertIn("button.keyDown(with: event)", swift.read_text())
                self.assertIn("verticalDirections == [direction]", swift.read_text())
                self.assertIn('check(eventCount == 132,', swift.read_text())
                return subprocess.CompletedProcess(command, 0)
            self.assertFalse(check)
            self.assertEqual(command, [commands[0][-1]])
            return subprocess.CompletedProcess(command, 0)

        self.assertEqual(self.invoke(run), 0)
        self.assertEqual(len(commands), 2)

    def test_compiler_failure_is_not_swallowed_or_followed_by_test(self):
        with patch.object(sys, "platform", "darwin"), patch.object(sys, "argv", [str(RUNNER)]), \
                patch.object(subprocess, "run", side_effect=subprocess.CalledProcessError(1, "swiftc")) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                MODULE["main"]()
            self.assertEqual(run.call_count, 1)

    def test_missing_toolchain_is_not_a_pass(self):
        with self.assertRaises(FileNotFoundError):
            self.invoke(lambda *args, **kwargs: (_ for _ in ()).throw(FileNotFoundError("xcrun")))

    def test_nonzero_callback_exit_is_preserved(self):
        for code in [1, 77, -9]:
            with self.subTest(code=code):
                calls = []

                def run(command, check):
                    calls.append(command)
                    return subprocess.CompletedProcess(command, 0 if check else code)

                self.assertEqual(self.invoke(run), code)
                self.assertEqual(len(calls), 2)

    def test_non_macos_is_77_without_compiler_calls(self):
        with patch.object(sys, "platform", "linux"), patch.object(sys, "argv", [str(RUNNER)]), \
                patch.object(subprocess, "run") as run, redirect_stdout(io.StringIO()):
            self.assertEqual(MODULE["main"](), 77)
            run.assert_not_called()

    def test_shell_propagation_case_is_not_skipped_on_macos(self):
        with patch.object(sys, "platform", "darwin"):
            tests = runpy.run_path(str(Path(__file__)))
            case = tests["ChromeRunnerTests"]("test_bash_errexit_does_not_turn_77_into_success")
            result = unittest.TestResult()
            case.run(result)
        self.assertFalse(result.skipped, "77 propagation must also be tested on macOS")
        self.assertTrue(result.wasSuccessful(), result.errors or result.failures)

    def test_bash_errexit_does_not_turn_77_into_success(self):
        # Force only this child into the non-macOS path, so this shell check
        # executes on macOS too; it never pretends to compile or run AppKit.
        force_linux = 'import runpy,sys; sys.platform="linux"; sys.argv=[sys.argv[1]]; runpy.run_path(sys.argv[0], run_name="__main__")'
        result = subprocess.run([
            "bash", "-e", "-o", "pipefail", "-c",
            '"$1" -c "$2" "$3"; echo SHOULD_NOT_REACH', "test", sys.executable, force_linux, str(RUNNER),
        ], text=True, capture_output=True)
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertNotIn("SHOULD_NOT_REACH", result.stdout)


if __name__ == "__main__":
    unittest.main()

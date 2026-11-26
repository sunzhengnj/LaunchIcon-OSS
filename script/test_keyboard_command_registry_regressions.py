#!/usr/bin/env python3
"""Regression tests for guard scope and the chrome dispatch source shape.

Runs the real registry guard against in-memory source mutations; never changes
repository files. Callback/NSResponder behavior is tested separately on macOS.
"""
from contextlib import redirect_stdout
import io
from pathlib import Path
import runpy
import re
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
DIRECT = ROOT / "Sources/Direct/LauncherWindowController.swift"
GUARD = ROOT / "script/test_keyboard_command_registry.py"


def braced_block(source, marker, start=0):
    """Return offsets for a known Swift declaration (no braces in its strings)."""
    first = source.index(marker, start)
    opening = source.index("{", first)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return first, end


def run_guard(direct):
    read_text = Path.read_text

    def read(path, *args, **kwargs):
        if path == DIRECT:
            return direct
        return read_text(path, *args, **kwargs)

    output = io.StringIO()
    with patch.object(Path, "read_text", read), redirect_stdout(output):
        try:
            runpy.run_path(str(GUARD), run_name="__main__")
        except SystemExit as error:
            return error.code, output.getvalue()
    return 0, output.getvalue()


class RegistryGuardRegressions(unittest.TestCase):
    def test_unmodified_source_passes(self):
        code, output = run_guard(DIRECT.read_text())
        self.assertEqual(code, 0, output)

    def test_missing_arrow_dispatch_is_not_hidden_by_ellipsis(self):
        source = DIRECT.read_text()
        arrow = source.index("final class PagingArrowButton:")
        start, end = braced_block(
            source, "switch LauncherLayout.resolveKeyboardCommand(", arrow
        )
        mutated = source[:start] + source[end:]
        # All other classes, especially PageEllipsisButton, remain intact.
        self.assertEqual(mutated[:arrow], source[:arrow])
        code, output = run_guard(mutated)
        self.assertNotEqual(code, 0, "guard accepted missing arrow dispatch:\n" + output)
        self.assertIn("paging arrow button must switch on .pageUpDown", output)

    def test_missing_arrow_class_does_not_scan_another_class(self):
        source = DIRECT.read_text()
        start, end = braced_block(source, "final class PagingArrowButton:")
        code, output = run_guard(source[:start] + source[end:])
        self.assertNotEqual(code, 0, output)
        self.assertIn("paging arrow button", output)

    def test_macos_workflow_runs_the_callback_test_not_just_core(self):
        workflow = (ROOT / ".github/workflows/macos-validation.yml").read_text()
        self.assertRegex(workflow, r"(?m)^ +python3 script/test_chrome_page_key_callbacks\.py$")
        self.assertRegex(workflow, r"(?m)^ +python3 script/test_keyboard_command_registry_regressions\.py$")

    def test_manual_default_remains_full_with_exclusive_jobs(self):
        workflow = (ROOT / ".github/workflows/macos-validation.yml").read_text()
        self.assertRegex(workflow, r"(?m)^        default: full$")
        self.assertIn("if: ${{ inputs.scope == 'chrome-page-keys' }}", workflow)
        self.assertIn("if: ${{ inputs.scope == 'full' }}", workflow)

    def test_targeted_job_only_runs_fixed_relevant_commands(self):
        workflow = (ROOT / ".github/workflows/macos-validation.yml").read_text()
        self.assertIn("  chrome_page_keys:\n", workflow, "Missing narrow manual job")
        job = workflow.split("  chrome_page_keys:\n", 1)[1].split("\n  validate:", 1)[0]
        commands = re.findall(r"(?m)^ +python3 (script/[^ \n]+)$", job)
        self.assertEqual(commands, ["script/test_keyboard_command_registry.py",
                                   "script/test_keyboard_command_registry_regressions.py",
                                   "script/test_chrome_page_key_runner.py",
                                   "script/test_chrome_page_key_callbacks.py"])
        self.assertIn("timeout-minutes: 10", job)
        self.assertIn("runs-on: xcode-27", job)
        self.assertIn("shell: bash --noprofile --norc -e -u -o pipefail {0}", job)
        for forbidden in ["continue-on-error", "upload-artifact", "actions/cache", "scope }}",
                          "test_core.sh", "LaunchIconStoreSpike", "LaunchIconUITests"]:
            self.assertNotIn(forbidden, job)

    def test_background_validation_includes_the_targeted_tests(self):
        background = (ROOT / "script/validate_background.sh").read_text()
        for script in ["test_chrome_page_key_callbacks.py", "test_keyboard_command_registry_regressions.py"]:
            self.assertIn('python3 "$ROOT_DIR/script/' + script + '"', background)

    def test_chrome_source_offers_vertical_scroll_at_one_call_site(self):
        source = DIRECT.read_text()
        start, end = braced_block(source, "private final class LauncherChromeButton:")
        chrome = source[start:end]
        self.assertEqual(chrome.count("launcherConsumesVerticalSearchPage("), 1)
        self.assertIn("if let onPage", chrome)
        self.assertIn("super.keyDown(with: event)", chrome)


if __name__ == "__main__":
    unittest.main()

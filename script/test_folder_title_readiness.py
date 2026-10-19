#!/usr/bin/env python3
"""Exercise title accessibility and keyboard-focus gating without a window/editor.

The availability callback is supplied by a fixture; integration with panel
animations and keyboard field editors must still be verified through UI tests.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (Path(sys.argv[1]) if len(sys.argv) > 1 else
          root / 'Sources/Direct/LauncherWindowController.swift').read_text()
start = source.index('@MainActor\nprivate final class FolderTitleField:')
end = source.index('\n@MainActor\nprivate final class FolderOverlayView:', start)
field = source[start:end].replace('private final class', 'final class', 1)
# Old source has no callback: it exposes the field throughout the same fixture
# states. Keep it executable so baseline failures are assertions, not compiler errors.
configure = 'field.pointerEditingAvailable = { ready }' if 'var pointerEditingAvailable:' in field else ''
cases = '''
var failures = 0
@MainActor func check(_ condition: Bool, _ label: String) {
    print("\\(condition ? "PASS" : "FAIL"): \\(label)")
    if !condition { failures += 1 }
}
let field = FolderTitleField(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
field.setAccessibilityHidden(false)
var ready = true
CONFIGURE
check(!field.isAccessibilityHidden(), "settled title is exposed")
ready = false
check(field.isAccessibilityHidden(), "traveling title is not advertised at its resting frame")
ready = true
check(!field.isAccessibilityHidden(), "landing restores the title without a timer or refresh")
ready = false
check(field.isAccessibilityHidden(), "reversed flight hides unedited title again")
field.setAccessibilityHidden(true)
ready = true
check(field.isAccessibilityHidden(), "explicit hidden state wins over readiness")
field.setAccessibilityHidden(false)
ready = false
check(!field.acceptsFirstResponder, "traveling title refuses keyboard focus")
ready = true
check(field.acceptsFirstResponder, "landed title accepts keyboard focus")
print("Failures: \\(failures)")
exit(failures == 0 ? 0 : 1)
'''.replace('CONFIGURE', configure)
with tempfile.TemporaryDirectory(prefix='LaunchIcon-TitleReadiness-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text('import AppKit\n' + field + cases)
    core_sources = sorted((root / 'Sources/Core').glob('*.swift'))
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *map(str, core_sources),
                    str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    sys.exit(subprocess.run([str(path / 'test')], check=False).returncode)

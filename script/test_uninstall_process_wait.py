#!/usr/bin/env python3
"""Run the production uninstall wait methods with windowless fake processes."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/Direct/UninstallCoordinator.swift').read_text()


def extract(name: str) -> str:
    start = source.index(f'    static func {name}(')
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end].replace('static func', 'func', 1).replace('NSRunningApplication', 'FakeRunningApplication')


swift = '''import Foundation

@MainActor final class FakeRunningApplication {
    var isTerminated = false
    let stopsOnRequest: Bool
    init(stopsOnRequest: Bool = false) { self.stopsOnRequest = stopsOnRequest }
    func terminate() -> Bool {
        if stopsOnRequest { isTerminated = true }
        return stopsOnRequest
    }
    func forceTerminate() -> Bool {
        if stopsOnRequest { isTerminated = true }
        return stopsOnRequest
    }
}
@MainActor final class Harness {
''' + extract('quitRunningApplications') + '\n' + extract('forceQuitRunningApplications') + '''
}
@MainActor func check(_ ok: Bool, _ name: String) -> Bool {
    print("\\(ok ? "PASS" : "FAIL"): \\(name)")
    return ok
}
@MainActor func run() async -> Bool {
    let harness = Harness()
    var passed = true
    let immediate = FakeRunningApplication(stopsOnRequest: true)
    passed = check(await harness.quitRunningApplications([immediate]),
        "a process that exits immediately is accepted") && passed

    let stubborn = FakeRunningApplication()
    let normalStart = Date()
    let normal = Task { await harness.quitRunningApplications([stubborn]) }
    let cancelNormal = Task.detached {
        try? await Task.sleep(for: .milliseconds(100))
        normal.cancel()
    }
    let normalResult = await normal.value
    await cancelNormal.value
    passed = check(!normalResult && Date().timeIntervalSince(normalStart) < 0.5,
        "cancelled graceful wait ends without blocking for two seconds") && passed

    let forced = FakeRunningApplication()
    let forceStart = Date()
    let force = Task { await harness.forceQuitRunningApplications([forced]) }
    let cancelForce = Task.detached {
        try? await Task.sleep(for: .milliseconds(100))
        force.cancel()
    }
    let forceResult = await force.value
    await cancelForce.value
    passed = check(!forceResult && Date().timeIntervalSince(forceStart) < 0.5,
        "cancelled force wait ends without blocking for one second") && passed
    return passed
}
exit(await run() ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix='LaunchIcon-UninstallWait-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(path / 'main.swift'),
                    '-o', str(path / 'probe')], check=True)
    sys.exit(subprocess.run([str(path / 'probe')], check=False).returncode)

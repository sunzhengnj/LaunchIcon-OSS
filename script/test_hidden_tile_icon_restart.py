#!/usr/bin/env python3
"""Hidden tile icon restart visits views item(at:) no longer returns.

Hide cancels loads while the window is visible. The next prepare restarts
them before orderFront, when NSCollectionView.item(at:) is nil. The walk is
the production realizedGridTiles weak-set path. The stub registers tiles the
same way when they gain a superview. Tile methods are stubs, so this does
not decode icons or open a window.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/Direct/LauncherWindowController.swift").read_text()


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


def extract(signature: str) -> str:
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    body = source[start:end]
    if body.startswith("    private func"):
        body = body.replace("private func", "func", 1)
    return body


names = (
    "    func realizedGridTiles() -> [AppGridTileView]",
    "    private func forEachMaterializedTile(",
    "    func cancelTileIconLoadsBecauseLauncherIsDismissing()",
    "    func restartCancelledTileIconLoadsAfterAppearance()",
    "    private func dismissalPlaceholderIconCount() -> Int",
)
methods = [extract(name) for name in names]
joined = "\n".join(methods)
if "item(at:" in methods[1]:
    fail("forEachMaterializedTile still looks up item(at:), which is nil while hidden")
for bad in ("showPage(", "transitionToPage(", "completePageTransition("):
    if bad in joined:
        fail(f"paging red line {bad} in hidden tile icon restart")
if "realizedGridTiles()" not in methods[1]:
    fail("forEachMaterializedTile must walk realizedGridTiles")

swift = r'''import AppKit

@MainActor final class AppGridTileView: NSView {
    fileprivate static let realizedTileTable = NSHashTable<AppGridTileView>.weakObjects()
    fileprivate static var realizedTiles: [AppGridTileView] { realizedTileTable.allObjects }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil { Self.realizedTileTable.add(self) }
        else { Self.realizedTileTable.remove(self) }
    }
    var cancelCount = 0
    var restartCount = 0
    var placeholders = 0
    func cancelIconLoadForDismissal() { cancelCount += 1 }
    func restartIconLoadIfCancelledDuringDismissal() { restartCount += 1 }
    func stuckPlaceholderIconCount() -> Int { placeholders }
}

@MainActor final class Harness {
    @MainActor struct Overlay { let collectionView = NSView() }
    let activeCollectionView = NSView()
    let stagingCollectionView = NSView()
    let searchCollectionView = NSView()
    let folderOverlay = Overlay()
''' + joined + r'''
}

var failures = 0
@MainActor func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL"): \(label)")
    if !condition { failures += 1 }
}

let harness = Harness()
let cell = NSView()
let hiddenTile = AppGridTileView()
hiddenTile.placeholders = 2
cell.addSubview(hiddenTile)
harness.activeCollectionView.addSubview(cell)

let stagingTile = AppGridTileView()
stagingTile.placeholders = 1
harness.stagingCollectionView.addSubview(stagingTile)

let searchTile = AppGridTileView()
searchTile.placeholders = 0
harness.searchCollectionView.addSubview(searchTile)

let folderCell = NSView()
let folderTile = AppGridTileView()
folderTile.placeholders = 4
folderCell.addSubview(folderTile)
harness.folderOverlay.collectionView.addSubview(folderCell)

let outsider = AppGridTileView()
outsider.placeholders = 9

let visited = [hiddenTile, stagingTile, searchTile, folderTile]
harness.cancelTileIconLoadsBecauseLauncherIsDismissing()
harness.restartCancelledTileIconLoadsAfterAppearance()
check(visited.allSatisfy { $0.cancelCount == 1 && $0.restartCount == 1 },
      "tiles that are only subviews are cancelled and restarted")
check(outsider.cancelCount == 0 && outsider.restartCount == 0,
      "a tile outside the grid hierarchy is left alone")
check(harness.dismissalPlaceholderIconCount() == 7,
      "placeholder count includes nested tiles item(at:) would miss")
check(hiddenTile.cancelCount == 1, "a nested grid tile is not visited twice")

print("Failures: \(failures)")
exit(failures == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix="LaunchIcon-HiddenTileRestart-") as directory:
    path = Path(directory)
    (path / "main.swift").write_text(swift)
    subprocess.run(
        ["xcrun", "swiftc", "-swift-version", "6", str(path / "main.swift"), "-o", str(path / "restart")],
        check=True,
    )
    sys.exit(subprocess.run([str(path / "restart")], check=False).returncode)

#!/usr/bin/env python3
"""Hidden preview-plate writes land on tiles item(at:) no longer returns.

The plate clock finishes after order-out. NSCollectionView.item(at:) is nil
then, so a lookup-only write leaves the folder plate mid-fade. Production
methods run here against nested AppKit views. Nothing is presented, and the
window is not ordered in.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
core = (root / "Sources/Core/LauncherLayout.swift").read_text()


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


def extract(text: str, signature: str) -> str:
    start = text.index(signature)
    end = text.index("\n    }", start) + len("\n    }")
    return text[start:end]


def static_func(name: str) -> str:
    body = extract(core, f"    public static func {name}(")
    return body.replace("public static func", "static func", 1)


def method(signature: str) -> str:
    body = extract(source, signature)
    if body.startswith("    private func"):
        body = body.replace("private func", "func", 1)
    return body


stamp = source.index("tile.representedItemID = representedID")
data_source = source.index("func collectionView(\n        _ collectionView: NSCollectionView,\n        itemForRepresentedObjectAt indexPath: IndexPath")
if stamp < data_source:
    fail("representedItemID is stamped outside the grid data source")
reset = source.index("    func resetForReuse() {")
if "representedItemID = nil" not in source[reset:source.index("\n    }", reset)]:
    fail("resetForReuse does not clear representedItemID")

names = (
    "    func realizedGridTiles() -> [AppGridTileView]",
    "    private func forEachFolderPreviewPlateTile(",
    "    private func applyPreviewPlateOpacity(",
    "    private func setBorrowedPreviewPlateHidden(",
    "    private func finishPreviewPlateYield(",
    "    private func releaseBorrowedPreviewPlate()",
    "    private func finishUnpinnedPreviewPlateClock(",
)
methods = [method(name) for name in names]
joined = "\n".join(methods)
for bad in ("showPage(", "transitionToPage(", "completePageTransition(", "pinWeightAnimation("):
    if bad in joined:
        fail(f"paging red line {bad} in hidden preview-plate write")
if "tileForPresentedItem" in methods[2] or "tileForPresentedItem" in methods[3]:
    fail("plate writers still talk to item(at:) themselves")
if "forEachFolderPreviewPlateTile" not in methods[2] or "forEachFolderPreviewPlateTile" not in methods[3]:
    fail("plate writers must share forEachFolderPreviewPlateTile")
if "realizedGridTiles()" not in methods[1] or "previewPlateShouldWriteRetainedTiles" not in methods[1]:
    fail("retained plate walk is missing")

layout = (
    "enum LauncherLayout {\n"
    "    enum FolderPreviewPlatePhase: Equatable {\n"
    "        case resting, borrowed, returning, yielding\n"
    "    }\n"
    "    enum UnpinnedPreviewPlateFinish: Equatable {\n"
    "        case leave, landReturning, landYielding\n"
    "    }\n"
    + static_func("unpinnedPreviewPlateFinish")
    + "\n"
    + static_func("previewPlateShouldWriteRetainedTiles")
    + "\n}\n"
)

swift = r'''import AppKit
''' + layout + r'''
@MainActor final class AppGridTileView: NSView {
    fileprivate static let realizedTileTable = NSHashTable<AppGridTileView>.weakObjects()
    fileprivate static var realizedTiles: [AppGridTileView] { realizedTileTable.allObjects }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil { Self.realizedTileTable.add(self) }
        else { Self.realizedTileTable.remove(self) }
    }
    var isFolder = false
    var representedItemID: UUID?
    var chromeHidesPlate = false
    var previewPlateOpacity: CGFloat = 1
}

@MainActor final class Harness {
    @MainActor struct Overlay { let collectionView = NSView() }
    struct PreviewPlateClock { var isRunning = false }
    let activeCollectionView = NSView()
    let stagingCollectionView = NSView()
    let searchCollectionView = NSView()
    let folderOverlay = Overlay()
    var previewPlateClock = PreviewPlateClock()
    var previewPlateReturnPresentedOpacity: CGFloat = 1
    var borrowedPreviewPlateFolderID: UUID?
    var borrowedPreviewPlatePhase: LauncherLayout.FolderPreviewPlatePhase = .resting
    var lookedUpTile: AppGridTileView?
    func stopPreviewPlateReturnTicker() { previewPlateClock.isRunning = false }
    func tileForPresentedItem(_ itemID: UUID, in collectionView: NSView) -> AppGridTileView? {
        guard let lookedUpTile, lookedUpTile.representedItemID == itemID else { return nil }
        return lookedUpTile
    }
''' + joined + r'''
}

var failures = 0
@MainActor func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL"): \(label)")
    if !condition { failures += 1 }
}

@MainActor func nest(_ tile: AppGridTileView, in root: NSView) {
    let cell = NSView()
    cell.addSubview(tile)
    root.addSubview(cell)
}

let folderID = UUID()
let otherID = UUID()

let harness = Harness()
let yielding = AppGridTileView()
yielding.isFolder = true
yielding.representedItemID = folderID
yielding.previewPlateOpacity = 0.35
yielding.chromeHidesPlate = false
nest(yielding, in: harness.activeCollectionView)

let searchCopy = AppGridTileView()
searchCopy.isFolder = true
searchCopy.representedItemID = folderID
searchCopy.previewPlateOpacity = 0.35
searchCopy.chromeHidesPlate = false
nest(searchCopy, in: harness.searchCollectionView)

let otherFolder = AppGridTileView()
otherFolder.isFolder = true
otherFolder.representedItemID = otherID
otherFolder.previewPlateOpacity = 0.2
otherFolder.chromeHidesPlate = false
nest(otherFolder, in: harness.activeCollectionView)

let appTile = AppGridTileView()
appTile.isFolder = false
appTile.representedItemID = folderID
appTile.previewPlateOpacity = 0.2
nest(appTile, in: harness.stagingCollectionView)

let recycled = AppGridTileView()
recycled.isFolder = true
recycled.representedItemID = nil
recycled.previewPlateOpacity = 0.2
recycled.chromeHidesPlate = true
nest(recycled, in: harness.activeCollectionView)

let outsider = AppGridTileView()
outsider.isFolder = true
outsider.representedItemID = folderID
outsider.previewPlateOpacity = 0.35

harness.borrowedPreviewPlateFolderID = folderID
harness.borrowedPreviewPlatePhase = .yielding
harness.previewPlateClock.isRunning = true
harness.finishUnpinnedPreviewPlateClock(windowVisible: false)
check(yielding.previewPlateOpacity == 1 && yielding.chromeHidesPlate,
      "a yielding plate hidden in the hierarchy lands hidden at opacity 1")
check(searchCopy.previewPlateOpacity == 1 && searchCopy.chromeHidesPlate,
      "a search copy item(at:) cannot see is landed too")
check(otherFolder.previewPlateOpacity == 0.2 && !otherFolder.chromeHidesPlate,
      "another folder keeps its mid-fade plate")
check(appTile.previewPlateOpacity == 0.2 && !appTile.chromeHidesPlate,
      "an app tile with the same id is not a plate")
check(recycled.previewPlateOpacity == 0.2 && recycled.chromeHidesPlate,
      "a reused tile with no id is left alone")
check(outsider.previewPlateOpacity == 0.35 && !outsider.chromeHidesPlate,
      "a tile outside the grid hierarchy is left alone")
check(harness.borrowedPreviewPlatePhase == .borrowed && !harness.previewPlateClock.isRunning,
      "yielding finishes borrowed and stops the clock")

let returning = Harness()
let returningTile = AppGridTileView()
returningTile.isFolder = true
returningTile.representedItemID = folderID
returningTile.previewPlateOpacity = 0.4
returningTile.chromeHidesPlate = true
nest(returningTile, in: returning.stagingCollectionView)
returning.borrowedPreviewPlateFolderID = folderID
returning.borrowedPreviewPlatePhase = .returning
returning.previewPlateClock.isRunning = true
returning.finishUnpinnedPreviewPlateClock(windowVisible: false)
check(returningTile.previewPlateOpacity == 1 && !returningTile.chromeHidesPlate,
      "a returning plate hidden in the hierarchy lands solid and visible")
check(returning.borrowedPreviewPlatePhase == .resting && returning.borrowedPreviewPlateFolderID == nil,
      "returning releases the borrowed plate")

let visible = Harness()
let visibleTile = AppGridTileView()
visibleTile.isFolder = true
visibleTile.representedItemID = folderID
visibleTile.previewPlateOpacity = 0.25
nest(visibleTile, in: visible.activeCollectionView)
visible.borrowedPreviewPlateFolderID = folderID
visible.borrowedPreviewPlatePhase = .yielding
visible.previewPlateClock.isRunning = true
visible.finishUnpinnedPreviewPlateClock(windowVisible: true)
check(visibleTile.previewPlateOpacity == 0.25 && visible.previewPlateClock.isRunning,
      "a visible window leaves the plate clock running")

let lookedUp = Harness()
let live = AppGridTileView()
live.isFolder = true
live.representedItemID = folderID
live.previewPlateOpacity = 0.5
live.chromeHidesPlate = false
let retained = AppGridTileView()
retained.isFolder = true
retained.representedItemID = folderID
retained.previewPlateOpacity = 0.2
retained.chromeHidesPlate = false
nest(retained, in: lookedUp.activeCollectionView)
lookedUp.lookedUpTile = live
lookedUp.borrowedPreviewPlateFolderID = folderID
lookedUp.borrowedPreviewPlatePhase = .yielding
lookedUp.previewPlateClock.isRunning = true
lookedUp.finishUnpinnedPreviewPlateClock(windowVisible: false)
check(live.previewPlateOpacity == 1 && live.chromeHidesPlate,
      "a live lookup receives the yielding land")
check(retained.previewPlateOpacity == 0.2 && !retained.chromeHidesPlate,
      "a retained tile is not painted once item(at:) finds a cell")

let nonFolderLookup = Harness()
let decoy = AppGridTileView()
decoy.isFolder = false
decoy.representedItemID = folderID
decoy.previewPlateOpacity = 0.4
let realFolder = AppGridTileView()
realFolder.isFolder = true
realFolder.representedItemID = folderID
realFolder.previewPlateOpacity = 0.3
realFolder.chromeHidesPlate = false
nest(realFolder, in: nonFolderLookup.activeCollectionView)
nonFolderLookup.lookedUpTile = decoy
nonFolderLookup.applyPreviewPlateOpacity(0.9, folderID: folderID)
nonFolderLookup.setBorrowedPreviewPlateHidden(true, folderID: folderID)
check(realFolder.previewPlateOpacity == 0.9 && realFolder.chromeHidesPlate,
      "a non-folder lookup does not block the retained folder tile")
check(decoy.previewPlateOpacity == 0.4 && !decoy.chromeHidesPlate,
      "the non-folder lookup tile is not written")

print("Failures: \(failures)")
exit(failures == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix="LaunchIcon-HiddenPreviewPlate-") as directory:
    path = Path(directory)
    (path / "main.swift").write_text(swift)
    compiled = subprocess.run(
        ["xcrun", "swiftc", "-swift-version", "6", str(path / "main.swift"), "-o", str(path / "plate")],
        check=False,
        capture_output=True,
        text=True,
    )
    if compiled.returncode != 0:
        sys.stderr.write(compiled.stderr)
        sys.exit(compiled.returncode)
    sys.exit(subprocess.run([str(path / "plate")], check=False).returncode)

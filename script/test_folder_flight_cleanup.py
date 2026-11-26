#!/usr/bin/env python3
"""Execute production flight cleanup/pinning on AppKit views without a window.

Lookup and ownership fixtures replace the collection views; cleanup, pinning,
and tile visibility methods come directly from the production source. An empty
lookup still clears glyph-hide flags and the incoming preview limit on folder
tiles that remain in the hierarchy. There is no presentation tree, so this
does not verify rendered motion or UI dispatch.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
if len(sys.argv) > 1:
    source = Path(sys.argv[1]).read_text()
else:
    source = "".join(
        p.read_text()
        for p in [root / "Sources/Direct/LauncherWindowController.swift", *sorted((root / "Sources/Direct").glob("LauncherWindowController+*.swift"))]
    )
core = (root / "Sources/Core/LauncherLayout.swift").read_text()
def static_func(name):
    start = core.index(f"    public static func {name}(")
    end = core.index("\n    }", start) + len("\n    }")
    return core[start:end].replace("public static func", "static func", 1)

layout_stub = (
    "enum LauncherLayout {\n"
    + static_func("folderGlyphFlightShouldRevealCells")
    + "\n"
    + static_func("dropLandingShouldRevealRetainedTiles")
    + "\n"
    + static_func("previewPlateShouldWriteRetainedTiles")
    + "\n}\n"
)


def method(name):
    start = source.index(f"    private func {name}(") if f"    private func {name}(" in source else source.index(f"    func {name}(")
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end].replace("private func", "func", 1)

glyph_commit = method("commitFolderPreviewGlyphFlight")
incoming_reveal = method("revealIncomingPreviewGlyphs")
if "forEachFolderPreviewPlateTile" not in glyph_commit:
    print("FAIL: glyph commit still clears hide flags through its own lookup")
    sys.exit(1)
if "forEachFolderPreviewPlateTile" not in incoming_reveal:
    print("FAIL: incoming reveal still clears the glyph limit through item(at:)")
    sys.exit(1)
for bad in ("showPage(", "transitionToPage(", "completePageTransition(", "tileForPresentedItem", "item(at:"):
    if bad in glyph_commit or bad in incoming_reveal:
        print(f"FAIL: {bad} leaked into hidden glyph-state clear")
        sys.exit(1)


tile = '''
@MainActor final class Tile: NSView {
    let iconView = NSImageView()
    let titleLabel = NSTextField()
    var isFolder = true
    var representedItemID: UUID?
    var openFlightHidesPreviewGlyphs = true
    var openFlightHidesPlate = false
    var previewGlyphDrawLimit: Int? = 1
''' + method("setOpenFlightContentHidden") + "\n}\n"
harness = '''
typealias AppGridTileView = Tile
@MainActor final class Harness: NSView {
    struct Hidden { var itemID = UUID(); weak var tile: Tile? }
    struct Flyer { var itemID = UUID(); let view: NSImageView }
    var previewGlyphFlightGeneration: UInt64 = 3
    var previewGlyphFlightWaitsForLauncher = true
    var previewGlyphFlightReturnsHome = false
    var previewGlyphSourceTile: Tile?
    var borrowedPreviewPlateFolderID: UUID? = UUID()
    let activeCollectionView = 0, stagingCollectionView = 1, searchCollectionView = 2
    var plates: [Tile] = []
    struct Overlay {
        let collectionView = 3
        var isAnimatingClose = false
    }
    let folderOverlay = Overlay()
    var pendingDropLanding: Int? = 1
    var dropLandingItemID: UUID?
    weak var dropLandingView: NSView?
    var dropLandingGeneration: UInt64 = 7
    var dropLandingWaitsForLauncher = true
    struct DropLandingHiddenTile { weak var tile: Tile? }
    var dropLandingHiddenTiles: [DropLandingHiddenTile] = []
    var suppressDropLandingLookup = false
    var suppressGlyphTileLookup = false
    var retainedFolderTiles: [Tile] = []
    func realizedGridTiles() -> [Tile] { retainedFolderTiles }
    func tileForPresentedItem(_ id: UUID, in index: Int) -> Tile? {
        if suppressDropLandingLookup || suppressGlyphTileLookup { return nil }
        guard plates.indices.contains(index) else { return nil }
        return plates[index]
    }
    var previewGlyphHiddenContent: [Hidden] = []
    var previewGlyphFlyerBoxes: [Flyer] = []
    var previewGlyphFlyers: [NSImageView] { previewGlyphFlyerBoxes.map(\\.view) }
    var dissolveScatterGeneration: UInt64 = 5
    var dissolveScatterWaitsForLauncher = true
    var dissolveScatterHiddenTiles: [Hidden] = []
    var dissolveScatterFlyers: [NSImageView] = []
'''
for name in ("commitFolderPreviewGlyphFlight", "pinInFlightFolderPreviewGlyphFlight",
             "pinPresentedAlpha", "commitFolderDissolveScatter", "pinInFlightDissolveScatter",
             "revealDropLandingContents", "commitDropLanding", "freezeDropLandingFlyer",
             "forEachFolderPreviewPlateTile"):
    harness += method(name) + "\n"
hide_on = source.index("    func hideDropLandingContents(on ")
hide_on_end = source.index("\n    }", hide_on) + len("\n    }")
harness += source[hide_on:hide_on_end].replace("private func", "func", 1) + "\n"
harness += "}\n"
merge_harness = '''
@MainActor final class MergeHarness: NSView {
    struct Flyer { let view: NSImageView }
    struct Item { let id: UUID }
    struct Cell { let view: NSView }
    final class Collection {
        var items: [Item] = []
        var tiles: [Tile] = []
        func item(at index: IndexPath) -> Cell? {
            guard tiles.indices.contains(index.item) else { return nil }
            return Cell(view: tiles[index.item])
        }
    }
    let activeCollectionView = Collection()
    let stagingCollectionView = Collection()
    let searchCollectionView = Collection()
    var mergePreviewFlightGeneration: UInt64 = 9
    var mergePreviewFolderTile: Tile?
    var mergePreviewFlyers: [Flyer] = []
    var incomingPreviewLimitedFolderID: UUID?
    var incomingPreviewGlyphLimit: Int? = 1
    var retainedIncomingTiles: [Tile] = []
    func realizedGridTiles() -> [Tile] { retainedIncomingTiles }
    func presentedItems(for collection: Collection) -> [Item] { collection.items }
    func tileForPresentedItem(_ id: UUID, in collection: Collection) -> Tile? {
        guard let index = collection.items.firstIndex(where: { $0.id == id }),
              collection.tiles.indices.contains(index) else { return nil }
        return collection.tiles[index]
    }
''' + method("commitMergePreviewLanding") + "\n" + method("revealIncomingPreviewGlyphs") + "\n" + method("forEachFolderPreviewPlateTile") + "\n}\n"
cases = r'''
var failures = 0
@MainActor func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL"): \(label)")
    if !condition { failures += 1 }
}
@MainActor func animate(_ view: NSView) {
    view.wantsLayer = true
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0; fade.toValue = 1; fade.duration = 10
    view.layer?.add(fade, forKey: "fixture")
}
@MainActor func fixture() -> (Harness, Tile, NSImageView) {
    let host = Harness(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let tile = Tile(); tile.setOpenFlightContentHidden(true)
    host.plates = [Tile(), Tile(), Tile()]
    host.previewGlyphSourceTile = host.plates[0]
    let flyer = NSImageView(frame: NSRect(x: 4, y: 8, width: 20, height: 20))
    host.addSubview(flyer); animate(flyer)
    host.previewGlyphHiddenContent = [Harness.Hidden(tile: tile)]
    host.previewGlyphFlyerBoxes = [Harness.Flyer(view: flyer)]
    return (host, tile, flyer)
}
for returnsHome in [false, true] {
    let (host, tile, flyer) = fixture()
    host.previewGlyphFlightReturnsHome = returnsHome
    animate(tile.iconView); animate(tile.titleLabel)
    host.commitFolderPreviewGlyphFlight()
    check(host.previewGlyphFlyers.isEmpty && flyer.superview == nil
          && flyer.layer?.animationKeys()?.isEmpty != false, "preview flyers detached and stopped, returning=\(returnsHome)")
    // No window: a return is not still closing on screen, so member icons
    // come back. An on-screen shrink stays hidden; Core covers that case.
    check(tile.iconView.alphaValue == 1
          && tile.titleLabel.alphaValue == 1,
          "off-screen commit reveals member icons, returning=\(returnsHome)")
    check(host.previewGlyphFlightGeneration == 4 && !host.previewGlyphFlightWaitsForLauncher
          && !host.previewGlyphFlightReturnsHome && host.previewGlyphHiddenContent.isEmpty
          && host.previewGlyphSourceTile == nil && host.plates.allSatisfy { !$0.openFlightHidesPreviewGlyphs },
          "preview ownership, generation and plate flags cleaned")
    check(tile.iconView.layer?.animationKeys()?.isEmpty != false
          && tile.titleLabel.layer?.animationKeys()?.isEmpty != false,
          "revealed content has no stale fade, returning=\(returnsHome)")
    host.commitFolderPreviewGlyphFlight()
    check(host.previewGlyphFlyers.isEmpty && flyer.superview == nil, "preview cleanup is repeatable")
}
let (reversed, reverseTile, reverseFlyer) = fixture()
reversed.previewGlyphFlightReturnsHome = true
reversed.commitFolderPreviewGlyphFlight(revealCells: true)
check(reverseTile.iconView.alphaValue == 1 && reverseFlyer.superview == nil, "reversed close restores open cells")
let (pinned, pinnedTile, pinnedFlyer) = fixture()
animate(pinnedTile.iconView); animate(pinnedTile.titleLabel)
let oldPreview = pinned.previewGlyphFlightGeneration
check(pinned.pinInFlightFolderPreviewGlyphFlight(), "preview can pin during launcher dismissal")
check(pinned.previewGlyphFlightGeneration != oldPreview && pinnedFlyer.superview === pinned
      && pinnedTile.iconView.alphaValue == 0 && pinnedFlyer.layer?.animationKeys()?.isEmpty != false
      && pinnedTile.iconView.layer?.animationKeys()?.isEmpty != false, "pin invalidates old generation and retains hidden cells")
pinned.commitFolderPreviewGlyphFlight()
check(pinned.previewGlyphFlyers.isEmpty && pinnedTile.iconView.alphaValue == 1, "pin then commit restores cells")
check(!pinned.pinInFlightFolderPreviewGlyphFlight(), "empty preview cannot pin")
let scatter = Harness(); let scatterTile = Tile(); scatterTile.alphaValue = 0
let scatterFlyer = NSImageView(); scatter.addSubview(scatterFlyer); animate(scatterFlyer)
scatter.dissolveScatterFlyers = [scatterFlyer]
scatter.dissolveScatterHiddenTiles = [Harness.Hidden(tile: scatterTile)]
let oldScatter = scatter.dissolveScatterGeneration
check(scatter.pinInFlightDissolveScatter(), "scatter can pin during dismissal")
check(scatter.dissolveScatterGeneration != oldScatter && scatterTile.alphaValue == 0
      && scatterFlyer.superview === scatter, "scatter pin invalidates old generation without revealing destination")
scatter.commitFolderDissolveScatter()
check(scatterTile.alphaValue == 1 && scatterFlyer.superview == nil
      && scatter.dissolveScatterFlyers.isEmpty && scatter.dissolveScatterHiddenTiles.isEmpty
      && !scatter.dissolveScatterWaitsForLauncher, "scatter commit restores destination and releases flight ownership")
scatter.commitFolderDissolveScatter()
check(!scatter.pinInFlightDissolveScatter(), "scatter cleanup is repeatable and empty pin is false")
let (lost, _, _) = fixture()
lost.previewGlyphHiddenContent = [Harness.Hidden(tile: nil)]
lost.commitFolderPreviewGlyphFlight()
check(lost.previewGlyphFlyers.isEmpty, "deallocated cell does not prevent cleanup")

let dropped = Harness()
dropped.plates = (0..<4).map { _ in
    let tile = Tile()
    tile.setOpenFlightContentHidden(true)
    tile.openFlightHidesPlate = true
    animate(tile.iconView); animate(tile.titleLabel)
    return tile
}
dropped.dropLandingItemID = UUID()
let dropFlyer = NSImageView(frame: NSRect(x: 10, y: 12, width: 30, height: 30))
dropped.addSubview(dropFlyer); animate(dropFlyer)
dropped.dropLandingView = dropFlyer
let beforeFreeze = dropped.dropLandingGeneration
dropFlyer.layer?.speed = 0
dropFlyer.layer?.timeOffset = 2
dropFlyer.layer?.beginTime = 3
dropped.freezeDropLandingFlyer(dropFlyer)
check(dropped.dropLandingGeneration == beforeFreeze + 1
      && dropped.dropLandingView === dropFlyer && dropFlyer.superview === dropped
      && dropped.plates.allSatisfy { $0.iconView.alphaValue == 0 && $0.openFlightHidesPlate },
      "drop freeze invalidates callback but keeps flyer and hidden destinations")
check(dropFlyer.layer?.animationKeys()?.isEmpty != false
      && dropFlyer.layer?.speed == 1 && dropFlyer.layer?.timeOffset == 0
      && dropFlyer.layer?.beginTime == 0, "drop freeze clears animation clocks")
animate(dropFlyer)
dropped.dropLandingHiddenTiles = dropped.plates.map { Harness.DropLandingHiddenTile(tile: $0) }
dropped.commitDropLanding()
check(dropFlyer.superview == nil && dropped.dropLandingView == nil
      && dropFlyer.layer?.animationKeys()?.isEmpty != false, "drop commit detaches and stops flyer")
check(dropped.plates.allSatisfy {
    $0.iconView.alphaValue == 1 && $0.titleLabel.alphaValue == 1
      && !$0.openFlightHidesPreviewGlyphs && !$0.openFlightHidesPlate
      && $0.iconView.layer?.animationKeys()?.isEmpty != false
      && $0.titleLabel.layer?.animationKeys()?.isEmpty != false
}, "drop commit restores active, staging, search and folder destination copies")
check(dropped.dropLandingGeneration == beforeFreeze + 2
      && dropped.pendingDropLanding == nil && dropped.dropLandingItemID == nil
      && !dropped.dropLandingWaitsForLauncher, "drop commit clears deferred ownership")
dropped.commitDropLanding()
check(dropped.dropLandingView == nil && dropped.plates.allSatisfy { $0.iconView.alphaValue == 1 },
      "drop cleanup is repeatable")
let lostDrop = Harness()
lostDrop.plates = (0..<4).map { _ in Tile() }
lostDrop.dropLandingItemID = UUID()
lostDrop.commitDropLanding()
check(lostDrop.dropLandingView == nil && lostDrop.dropLandingItemID == nil
      && lostDrop.pendingDropLanding == nil, "missing weak drop flyer does not prevent cleanup")
let remembered = Harness()
let parked = Tile()
remembered.hideDropLandingContents(on: parked)
check(parked.iconView.alphaValue == 0 && parked.titleLabel.alphaValue == 0
      && parked.openFlightHidesPlate && parked.openFlightHidesPreviewGlyphs
      && remembered.dropLandingHiddenTiles.count == 1
      && remembered.dropLandingHiddenTiles[0].tile === parked,
      "hide remembers the cell it parks")
remembered.hideDropLandingContents(on: parked)
check(remembered.dropLandingHiddenTiles.count == 1, "hide remembers each cell once")
remembered.suppressDropLandingLookup = true
remembered.dropLandingItemID = UUID()
remembered.commitDropLanding()
check(parked.iconView.alphaValue == 1 && parked.titleLabel.alphaValue == 1
      && !parked.openFlightHidesPlate && !parked.openFlightHidesPreviewGlyphs
      && remembered.dropLandingHiddenTiles.isEmpty && remembered.dropLandingItemID == nil,
      "order-out commit reveals the remembered cell when item(at:) is nil")
let lookupOnly = Harness()
let stray = Tile()
stray.setOpenFlightContentHidden(true)
stray.openFlightHidesPlate = true
stray.openFlightHidesPreviewGlyphs = true
lookupOnly.plates = [stray, stray, stray, stray]
lookupOnly.dropLandingItemID = UUID()
lookupOnly.commitDropLanding()
check(stray.iconView.alphaValue == 0 && stray.openFlightHidesPlate
      && stray.openFlightHidesPreviewGlyphs,
      "lookup alone does not uncover a cell this flight did not remember")
let gone = Harness()
gone.dropLandingHiddenTiles = [Harness.DropLandingHiddenTile(tile: nil)]
gone.dropLandingItemID = UUID()
gone.suppressDropLandingLookup = true
gone.commitDropLanding()
check(gone.dropLandingHiddenTiles.isEmpty && gone.dropLandingItemID == nil,
      "deallocated drop cell does not prevent cleanup")

let merged = MergeHarness()
let mergeID = UUID()
let plate = Tile(); plate.wantsLayer = true
plate.layer?.opacity = 0.2
plate.layer?.transform = CATransform3DMakeScale(0.5, 0.5, 1)
for key in ["folder-merge-plate", "folder-merge-plate-scale"] {
    plate.layer?.add(CABasicAnimation(keyPath: "opacity"), forKey: key)
}
merged.mergePreviewFolderTile = plate
merged.incomingPreviewLimitedFolderID = mergeID
let mergeCopies = [merged.activeCollectionView, merged.stagingCollectionView, merged.searchCollectionView]
for collection in mergeCopies {
    collection.items = [MergeHarness.Item(id: UUID()), MergeHarness.Item(id: mergeID)]
    collection.tiles = [Tile(), Tile()]
}
let mergeFlyer = NSImageView(); merged.addSubview(mergeFlyer); animate(mergeFlyer)
merged.mergePreviewFlyers = [MergeHarness.Flyer(view: mergeFlyer)]
merged.commitMergePreviewLanding()
check(plate.layer?.opacity == 1 && CATransform3DIsIdentity(plate.layer!.transform)
      && plate.layer?.animation(forKey: "folder-merge-plate") == nil
      && plate.layer?.animation(forKey: "folder-merge-plate-scale") == nil,
      "merge commit restores solid full-size plate and removes plate animations")
check(!plate.openFlightHidesPreviewGlyphs && plate.previewGlyphDrawLimit == nil,
      "merge commit reveals plate preview glyphs")
check(mergeCopies.allSatisfy { $0.tiles[1].previewGlyphDrawLimit == nil
      && $0.tiles[0].previewGlyphDrawLimit == 1 },
      "merge reveal restores matching folder copies and preserves unrelated tiles")
check(merged.mergePreviewFlightGeneration == 10 && merged.mergePreviewFolderTile == nil
      && merged.incomingPreviewLimitedFolderID == nil && merged.incomingPreviewGlyphLimit == nil,
      "merge commit invalidates callback and clears plate ownership")
check(merged.mergePreviewFlyers.isEmpty && mergeFlyer.superview == nil
      && mergeFlyer.layer?.animationKeys()?.isEmpty != false,
      "merge commit detaches flyers and stops their animations")
merged.commitMergePreviewLanding()
check(merged.mergePreviewFlyers.isEmpty && merged.mergePreviewFolderTile == nil,
      "merge cleanup is repeatable with no remaining plate")
let missingMerge = MergeHarness()
missingMerge.incomingPreviewLimitedFolderID = UUID()
missingMerge.commitMergePreviewLanding()
check(missingMerge.incomingPreviewLimitedFolderID == nil && missingMerge.incomingPreviewGlyphLimit == nil,
      "offscreen merge with no cell still clears preview ownership")

let hiddenGlyphs = Harness()
hiddenGlyphs.suppressGlyphTileLookup = true
let glyphFolder = hiddenGlyphs.borrowedPreviewPlateFolderID!
let keptGlyph = Tile()
keptGlyph.representedItemID = glyphFolder
keptGlyph.openFlightHidesPreviewGlyphs = true
let otherGlyph = Tile()
otherGlyph.representedItemID = UUID()
otherGlyph.openFlightHidesPreviewGlyphs = true
let appGlyph = Tile()
appGlyph.isFolder = false
appGlyph.representedItemID = glyphFolder
appGlyph.openFlightHidesPreviewGlyphs = true
let recycledGlyph = Tile()
recycledGlyph.representedItemID = nil
recycledGlyph.openFlightHidesPreviewGlyphs = true
let sourceGlyph = Tile()
sourceGlyph.openFlightHidesPreviewGlyphs = true
hiddenGlyphs.previewGlyphSourceTile = sourceGlyph
hiddenGlyphs.retainedFolderTiles = [keptGlyph, otherGlyph, appGlyph, recycledGlyph]
hiddenGlyphs.commitFolderPreviewGlyphFlight()
check(!sourceGlyph.openFlightHidesPreviewGlyphs && !keptGlyph.openFlightHidesPreviewGlyphs,
      "order-out glyph commit clears the source and the retained folder copy")
check(otherGlyph.openFlightHidesPreviewGlyphs && appGlyph.openFlightHidesPreviewGlyphs
      && recycledGlyph.openFlightHidesPreviewGlyphs,
      "order-out glyph commit leaves other folders, apps, and recycled cells")
let liveGlyph = Harness()
liveGlyph.plates = [Tile(), Tile(), Tile()]
let decoyGlyph = Tile()
decoyGlyph.representedItemID = liveGlyph.borrowedPreviewPlateFolderID
decoyGlyph.openFlightHidesPreviewGlyphs = true
liveGlyph.retainedFolderTiles = [decoyGlyph]
liveGlyph.commitFolderPreviewGlyphFlight()
check(liveGlyph.plates.allSatisfy { !$0.openFlightHidesPreviewGlyphs } && decoyGlyph.openFlightHidesPreviewGlyphs,
      "a live glyph lookup does not clear a folder tile item(at:) did not return")

let hiddenMerge = MergeHarness()
let hiddenMergeFolder = UUID()
hiddenMerge.incomingPreviewLimitedFolderID = hiddenMergeFolder
let shownLimit = Tile()
shownLimit.representedItemID = hiddenMergeFolder
shownLimit.previewGlyphDrawLimit = 2
let strangerLimit = Tile()
strangerLimit.representedItemID = UUID()
strangerLimit.previewGlyphDrawLimit = 2
let plainLimit = Tile()
plainLimit.isFolder = false
plainLimit.representedItemID = hiddenMergeFolder
plainLimit.previewGlyphDrawLimit = 2
let blankLimit = Tile()
blankLimit.representedItemID = nil
blankLimit.previewGlyphDrawLimit = 2
hiddenMerge.retainedIncomingTiles = [shownLimit, strangerLimit, plainLimit, blankLimit]
hiddenMerge.commitMergePreviewLanding()
check(shownLimit.previewGlyphDrawLimit == nil
      && strangerLimit.previewGlyphDrawLimit == 2
      && plainLimit.previewGlyphDrawLimit == 2
      && blankLimit.previewGlyphDrawLimit == 2
      && hiddenMerge.incomingPreviewLimitedFolderID == nil,
      "order-out merge reveal clears only the retained folder's glyph limit")
print("Failures: \(failures)")
exit(failures == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix="LaunchIcon-FlightCleanup-") as directory:
    path = Path(directory)
    (path / "main.swift").write_text(
        "import AppKit\nimport QuartzCore\n" + layout_stub + tile + harness + merge_harness + cases)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", str(path / "main.swift"),
                    "-o", str(path / "cleanup")], check=True)
    sys.exit(subprocess.run([str(path / "cleanup")], check=False).returncode)

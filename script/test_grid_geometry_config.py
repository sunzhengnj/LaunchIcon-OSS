#!/usr/bin/env python3
"""Guard: Direct honors grid geometry at default 7×5; paging animation stays frozen."""
from pathlib import Path
import hashlib
import sys

root = Path(__file__).resolve().parents[1]
prefs = (root / "Sources/Core/LauncherPreferences.swift").read_text()
layout = (root / "Sources/Core/LauncherLayout.swift").read_text()
direct = (root / "Sources/Direct/LauncherWindowController.swift").read_text()
settings = (root / "Sources/Direct/SettingsWindowController.swift").read_text()
delegate = (root / "Sources/Direct/DirectAppDelegate.swift").read_text()
tests = (root / "Tests/CoreTests/LaunchIconCoreTests.swift").read_text()
design = (root / "Docs/GRID_GEOMETRY_CONFIG.md").read_text()
failures = []


def need(cond, msg):
    if not cond:
        failures.append(msg)


def body(text, start, end):
    i = text.index(start)
    return text[i : text.index(end, i + len(start))]


def sha(text, start, end):
    return hashlib.sha256(body(text, start, end).encode()).hexdigest()


pref = body(prefs, "public struct GridGeometryPreference", "public struct LauncherPreferences")
need("columnBounds = 5...10" in pref and "rowBounds = 3...8" in pref, "bounds missing")
need("defaultColumns = 7" in pref and "defaultRows = 5" in pref, "default must stay 7×5")
need("func preservedPageIndex(" in pref, "slot-preserving page map missing")
need("self.init(columns: columns, rows: rows)" in pref, "decode must clamp through init")
for banned in ("showPage", "transitionToPage", "completePageTransition", "pageDrag"):
    need(banned not in pref, f"preference type must not name paging ({banned})")

need("public static let pageColumns = 7" in layout, "live columns changed")
need("public static let pageRows = 5" in layout, "live rows changed")
need("public static let pageCapacity = pageColumns * pageRows" in layout, "live capacity changed")
need("GridGeometryPreference" not in layout, "layout must keep using its own constants")
need("capacity: Int = pageCapacity" in layout, "layout overloads must default to pageCapacity")
need('prefix + "gridColumns"' in prefs and 'prefix + "gridRows"' in prefs, "preference keys missing")
need("func storedGridGeometry(" in prefs, "missing-key policy missing")
need("guard let columns, let rows else { return .standard }" in prefs, "one key must stay 7×5")

# Settings offers the clamped pair and must not drive a page turn.
need("GRID-GEOMETRY-SETTINGS-01" in settings, "Settings marker missing")
need("GridGeometryCopy.columnsPopupIdentifier" in settings and "GridGeometryCopy.rowsPopupIdentifier" in settings and 'columnsPopupIdentifier = "settings-grid-columns"' in prefs and 'rowsPopupIdentifier = "settings-grid-rows"' in prefs, "Settings popups missing identifiers")
need("proposed.gridGeometry" in settings, "Settings must apply the preference")
need("GridGeometryCopy.rowTitle" in settings, "Settings must use localized grid copy")
need("showPage(" not in settings and "transitionToPage(" not in settings, "Settings must not drive page transitions")
need("enum GridGeometryCopy" in prefs, "Settings copy type missing")
need("func choiceIndex(forColumns" in prefs and "func choiceIndex(forRows" in prefs, "choice index helpers missing")
need("columnChoices" in prefs and "rowChoices" in prefs, "choice lists missing")

# Direct must apply the stored pair without editing the page-turn functions.
need("func setGridGeometry(_ geometry: GridGeometryPreference)" in direct, "Direct setter missing")
need("private var gridGeometry = GridGeometryPreference.standard" in direct, "Direct default geometry missing")
need("setGridGeometry(preferences.gridGeometry)" in delegate, "launch must apply stored geometry")
need("LAUNCHICON_TEST_GRID_COLUMNS" in delegate and "LAUNCHICON_TEST_GRID_ROWS" in delegate,
     "test-only grid launch override missing")
need(
    'ProcessInfo.processInfo.environment["LAUNCHICON_TEST_LAYOUT_PATH"] != nil' in delegate
    and "preferences.gridGeometry = GridGeometryPreference(columns: columns, rows: rows)" in delegate,
    "grid launch override must be test-layout gated and use GridGeometryPreference",
)
need("setGridGeometry(proposed.gridGeometry)" in delegate, "preference changes must apply geometry")
need("pageSize = gridGeometry.capacity" in direct, "pagination must use the preference capacity")
need("columns: gridGeometry.columns" in direct and "rows: gridGeometry.rows" in direct, "itemSize must use the preference")
need("capacity: gridGeometry.capacity" in direct, "page math must pass the preference capacity")
# GRID-GEOMETRY-DROP-CAPACITY-01: drop / same-page batch must use the live
# capacity, or a 5×3 / 10×8 grid writes the wrong ordered-entry index.
need("capacity: Int = pageCapacity" in layout, "same-page helpers must default to 7×5")
need("func pageContainingDrop(_ drop: LayoutDrop, in state: LayoutState, capacity: Int = pageCapacity)" in layout,
     "pageContainingDrop must take capacity")
need("func topLevelIDsForBatchReorder(" in layout and "capacity: Int = pageCapacity" in body(
    layout,
    "    public static func topLevelIDsForBatchReorder(",
    "    public static func shouldBatchReorderSelection(",
), "batch reorder must take capacity")
need(direct.count("capacity: gridGeometry.capacity") >= 10, "Direct must pass live capacity into drop and batch helpers")
need("capacity: gridGeometry.capacity" in body(
    direct,
    "    func topLevelDropIndex(page: Int, localIndex: Int, source: LayoutItemRef) -> Int {",
    "    func handleHostDrop(_ info: NSDraggingInfo, on collectionView: NSCollectionView?) -> Bool {",
), "Direct drop-index wrapper must pass live capacity")
need("testBatchSamePageAndDropPagingHonorNonDefaultCapacity" in tests, "Core drop-capacity test missing")
need(
    "testChangingGeometryThenDroppingAndRestoringKeepsOrderedEntries" in tests,
    "Core change-geometry drop/restore test missing",
)
need(
    "testPageCountKeyboardNeighborAndSearchPlacementAtCompactAndWideGeometry" in tests,
    "Core 5×3 / 10×8 page, keyboard, and search-placement test missing",
)

apply = body(direct, "    /// GRID-GEOMETRY-APPLY-01:", "    /// Trackpad pinch-in while the launcher is open.")
need("showPage(" not in apply, "setGridGeometry must not call showPage")
need("transitionToPage(" not in apply, "setGridGeometry must not call transitionToPage")
need("completePageTransition(" not in apply, "setGridGeometry must not call completePageTransition")
need("preservedPageIndex" in apply, "apply must remap with preservedPageIndex")
need("snapGridToPageWithoutAnimation(" in apply, "apply must reuse the non-animated snap helper")
need("settleInterruptedPaging()" in body(
    direct,
    "    func snapGridToPageWithoutAnimation(_ page: Int) {",
    "    /// GRID-GEOMETRY-APPLY-01: remap the logical page with a non-animated",
), "non-animated snap must use the existing settle")
need("showPage(" not in body(
    direct,
    "    func snapGridToPageWithoutAnimation(_ page: Int) {",
    "    /// GRID-GEOMETRY-APPLY-01: remap the logical page with a non-animated",
), "non-animated snap must not call showPage")
need("transitionToPage(" not in body(
    direct,
    "    func snapGridToPageWithoutAnimation(_ page: Int) {",
    "    /// GRID-GEOMETRY-APPLY-01: remap the logical page with a non-animated",
) and "completePageTransition(" not in body(
    direct,
    "    func snapGridToPageWithoutAnimation(_ page: Int) {",
    "    /// GRID-GEOMETRY-APPLY-01: remap the logical page with a non-animated",
), "non-animated snap must not call paging transitions")
need(direct.count("showPage(") == 5, f"no new showPage call sites (found {direct.count('showPage(')})")
need(direct.count("transitionToPage(") == 3, f"no new transitionToPage call sites (found {direct.count('transitionToPage(')})")
need(direct.count("completePageTransition(") == 4, f"no new completePageTransition call sites (found {direct.count('completePageTransition(')})")
need("FOLDER-EXTRACT-SNAP-PAGE-01" in layout, "Core missing folder-extract snap policy")
need("func rememberedFolderExtractLandingPage(" in layout, "Core missing extract landing memory")
need("func folderExtractPageToSnapOnClose(" in layout, "Core missing extract close snap policy")
need("func folderCloseFocusIDAfterExtract(" in layout, "Core missing extract close focus policy")
need("testFolderExtractOntoTheNextPageSnapsWhenTheOverlayCloses" in tests, "Core extract-to-next-page test missing")
need("rememberedFolderExtractLandingPage(" in body(
    direct,
    "    func applyDrop(_ drop: LayoutDrop, releasePoint: CGPoint? = nil) -> Bool {",
    "    private func dropLandsInOpenFolder(_ drop: LayoutDrop) -> Bool {",
), "applyDrop must remember an off-page extract while the folder stays open")
need("snapGridToPageWithoutAnimation(" in body(
    direct,
    "    private func finishFolderCloseChromeLand() {",
    "    /// Close-folder restore and dissolve neighbor: always the main grid tile,",
), "folder close must snap with the non-animated remap, not showPage")
need("showPage(" not in body(
    direct,
    "    private func finishFolderCloseChromeLand() {",
    "    /// Close-folder restore and dissolve neighbor: always the main grid tile,",
), "folder close must not call showPage")

# Frozen page-turn function bodies. Update the hashes only if a later, guarded
# paging change is explicitly authorized.
FROZEN = {
    "showPage": (
        "    private func showPage(_ page: Int) {",
        "    @objc private func showPreviousPage() {",
        "94114af8765d41ab5a49ff5fca773632d7fffe5a361bef60d84f8d73e26c9014",
    ),
    "transitionToPage": (
        "    private func transitionToPage(_ targetPage: Int, direction: Int, discrete: Bool) {",
        "    private func completePageTransition(to targetPage: Int) {",
        "cfc6b64f0af0edfb4f533afd765c3f54003067e020287ef112553e68c9bb1034",
    ),
    "completePageTransition": (
        "    private func completePageTransition(to targetPage: Int) {",
        "    /// True when the page turn is still what the keyboard is doing.",
        "8f323cacbb41f9c32af0665164f65f24878a90116be808fb98b364005c8f0910",
    ),
}
for name, (start, end, digest) in FROZEN.items():
    chunk = body(direct, start, end)
    actual = hashlib.sha256(chunk.encode()).hexdigest()
    need(actual == digest, f"{name} body changed ({actual})")
    for banned in ("gridGeometry", "GridGeometryPreference", "pageCapacity", "pageColumns", "pageRows"):
        need(banned not in chunk, f"{name} must stay free of {banned}")

need("testGridGeometryPreferenceClampsAndMatchesSevenByFive" in tests, "Core test missing")
need("testGridGeometryPreferencePersistsOnlyAsAClampedPair" in tests, "persist test missing")
need(
    "testGridGeometryDerivationMatchesLayoutConstantsAtDefaultAndRemapsPages" in tests,
    "derivation Core test missing",
)
need(
    "testGridGeometrySettingsChoicesMatchClampedBoundsAndDefaultSevenByFive" in tests,
    "Settings choices Core test missing",
)
need("scanSkeleton.columns = geometry.columns" in direct, "skeleton must follow geometry")
need("itemSize(in: bounds.size, columns: columns, rows: rows)" in direct, "skeleton itemSize must use live columns and rows")
need("var columns = LauncherLayout.pageColumns" in direct and "var rows = LauncherLayout.pageRows" in direct, "skeleton default must stay 7×5")
need("GRID-GEOMETRY-SETTINGS-01" in design, "design must record the Settings slice")
need("pageIndex(containingEntryAt: 35), 1)" in tests, "index 35 must be page 1 at 7×5")
need("pageIndex(containingEntryAt: 35, capacity: 36), 0)" in tests, "index 35 must stay on page 0 above 35")
need("showPage" in design and "pageCapacity" in design, "design must name the paging red line")
need("preservedPageIndex" in design, "design must say how an apply keeps the slot")
need("GRID-GEOMETRY-APPLY-01" in design, "design must record the apply slice")

if failures:
    print("FAIL: grid geometry config")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS: grid geometry config")

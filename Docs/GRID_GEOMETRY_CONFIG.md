# Grid geometry configuration

LaunchOS lets someone pick how many columns and rows the main grid uses. LaunchIcon still defaults to 7×5 (`LauncherLayout.pageColumns` × `pageRows` = `pageCapacity` 35). Direct and Settings honor a stored `GridGeometryPreference`. **Paging animation is unchanged.**

## This slice (GRID-GEOMETRY-SETTINGS-01)

- Core type `GridGeometryPreference` clamps columns to 5…10 and rows to 3…8. The default is 7×5, capacity 35, matching today's constants.
- Settings on the 外观 tab offers「网格大小」with separate 列 / 行 popups over those bounds. Applying the pair uses the existing `setGridGeometry` snap; it does not call `showPage`.
- The loading skeleton follows the same columns and rows. At the default preference it still draws 7×5.
- `LauncherLayout.pageCount` / `pageIndex` / `entries(onPage:)` / `itemIDs(onPage:)` take an optional `capacity:` that defaults to `pageCapacity`, so default math is unchanged.
- Page index is `index / capacity` (negative indexes stay on page 0).
- `preservedPageIndex` maps the first slot of the page you were on into the new capacity.
- Decoding clamps too, so a stored 99×99 cannot become a live capacity.
- Folder grids stay on `folderColumns` (5). They are not this preference.

## Direct wiring (GRID-GEOMETRY-APPLY-01)

- `LauncherWindowController` / the root view read `preferences.gridGeometry` at launch and when Settings applies preferences.
- Live layout uses `gridGeometry.columns` / `rows` / `capacity` for `itemSize`, `pageCount`, keyboard/search columns, select-all, prefetch, restore-page clamping, and the loading skeleton.
- When the preference is `.standard`, those values equal `pageColumns` / `pageRows` / `pageCapacity`. Default geometry and paging behavior stay the same.
- When the counts change while the launcher is visible, `setGridGeometry` remaps the logical page with `preservedPageIndex` and the existing non-animated settle (`settleInterruptedPaging` / set `currentPage`). It does not call `showPage`, `transitionToPage`, or `completePageTransition`.
- Those three page-turn functions are frozen by hash in `script/test_grid_geometry_config.py`. Do not edit them to wire geometry.

## Persisted (GRID-GEOMETRY-PREFS-01)

- `LauncherPreferences.gridGeometry` stores the pair under `LaunchIcon.Preferences.gridColumns` and `gridRows`.
- Missing either key stays 7×5. A stored 99×1 is clamped, not applied raw.

## Not in this slice

- No change to the 7×5 `pageCapacity` constants.
- No edit to `showPage`, page hosts, gesture finish, page-turn curve, slide fraction, or distance threshold.
- Icon point size already follows the cell (`iconPointSize(in:)`). A smaller grid makes larger icons through the existing 60–84 pt clamp. Do not copy another product's metrics.

Changing capacity changes which icon sits on which page. That is why a non-default apply snaps the logical page and leaves the animation functions untouched.

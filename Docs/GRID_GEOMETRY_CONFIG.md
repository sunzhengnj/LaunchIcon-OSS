# Grid geometry configuration

LaunchOS lets someone pick how many columns and rows the main grid uses. LaunchIcon is fixed at 7×5 (`LauncherLayout.pageColumns` × `pageRows` = `pageCapacity` 35). This note is the design for making that configurable. **This slice does not change paging.**

## This slice

- Core type `GridGeometryPreference` clamps columns to 5…10 and rows to 3…8. The default is 7×5, capacity 35, matching today's constants.
- Page index is `index / capacity` (negative indexes stay on page 0), the same division as `LauncherLayout.pageIndex(containingEntryAt:)`.
- `preservedPageIndex` maps the first slot of the page you were on into the new capacity, so a later apply can keep that slot in view.
- Decoding clamps too, so a stored 99×99 cannot become a live capacity.
- Folder grids stay on `folderColumns` (5). They are not this preference.
- The live grid still uses the constants. Settings does not offer a control.

## Persisted (GRID-GEOMETRY-PREFS-01)

- `LauncherPreferences.gridGeometry` stores the pair under `LaunchIcon.Preferences.gridColumns` and `gridRows`.
- Missing either key stays 7×5. A stored 99×1 is clamped, not applied raw.
- Direct and Settings still do not read the value. `preservedPageIndex` is not passed into a page turn.

## Not in this slice

- No Settings control, and no change to `pageCapacity`. The preference keys exist; layout does not read them.
- No edit to `showPage`, page hosts, gesture finish, page-turn curve, slide fraction, or distance threshold.
- `preservedPageIndex` must not be passed into `showPage` until a later slice adds a paging guard.
- Icon point size already follows the cell (`iconPointSize(in:)`). A smaller grid makes larger icons through the existing 60–84 pt clamp. Do not copy another product's metrics.

## Later slice (still do not retune the animation)

1. Persist columns and rows on `LauncherPreferences`. Done in GRID-GEOMETRY-PREFS-01. Direct still ignores the stored pair.
2. Pass the stored counts into `itemSize(in:columns:rows:)`, which already takes those arguments. Keep `pageColumns` / `pageRows` as the default.
3. When the counts change while the launcher is visible, move the logical page with `preservedPageIndex` and the existing non-animated settle used by reopen-to-home (`snap` / set `currentPage`). Do not call a new transition and do not edit `showPage`.
4. Add a guard that the page-turn curve constants and `showPage` / `transitionToPage` / `completePageTransition` are unchanged, plus a Core test that index 35 is page 1 at 7×5 and page 0 at a capacity above 35.
5. Respect Reduce Motion the same way the current page snap does. No new motion.

Changing capacity changes which icon sits on which page. That is why the apply step stays behind the guard even though the math is ready.

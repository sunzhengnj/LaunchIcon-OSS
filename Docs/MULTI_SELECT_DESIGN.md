# Multi-select design (foundation)

Status: Core selection + ⌘/Shift-click + ⌘A + prune + context-menu batch + drag into existing folder / drop on app → new folder (same page). Marquee still later.

## Goal (behavior only)

Align with Launchpad/LaunchOS **behavior**: select several icons, then batch move into a folder or hide. Visuals stay LaunchIcon own chrome (neutral white fill alphas) — do not copy LaunchOS UI/resources.

## Click model (`LauncherItemSelection`)

| Input | Core policy | Effect |
| --- | --- | --- |
| Plain click | `.replace` then activate | Selection becomes that one item (or clears before activate in Direct); app/folder opens as today |
| Command-click | `.toggle` | Add/remove that id; **no** activate / open |
| Shift-click | `applyingRange` | Contiguous ids from range anchor through click target in **presented** order only; **no** activate / page turn |
| Command-A | `selectingAll` + `itemIDs(onPage:)` | All icons on **current page** only (open folder → members; search → visible hits); **no** page turn |
| Escape (selection non-empty) | Direct clear | Clears multi-select chrome; does not dismiss until selection empty |
| Plain click | existing | Clears / replaces then activates as before |
| Drag selection onto **existing folder** tile | `moveTopLevelApps` | Same-page selected top-level apps append into that folder; clear selection; single-item drag / new-folder merge unchanged |
| Drag selection onto **app** tile | `createFolderFromTopLevelApps` | Same-page selection + drop target → new folder; clear selection; single-item merge unchanged |
| Layout remove (hide/uninstall/reconcile) | `removeAbsent(from:)` | Drop stale ids |

Ordered unique ids preserve click order for later batch actions.

## Chrome policy

Fill priority (unchanged for launch/drop/focus; selection inserted):

1. Launching (`tileChromeLaunchingAlpha`)
2. Drop target (`tileChromeDropTargetAlpha`)
3. Selected (`tileChromeSelectionAlpha` = 0.10) — suppressed while folder panel chrome is in flight (same as focus)
4. Keyboard focus (`tileChromeFocusAlpha` = 0.08)
5. Idle (`0` / nil background)

Drag-lift snapshots stay idle (never bake selection/focus/drop/launch).

## Out of scope (later)

- Marquee / rubber-band selection
- Multi-item drag reorder (as a group)
- ~~Drag selection into an **existing** folder (same page)~~
- ~~Drop selection onto an **app** → new folder (same page)~~
- Batch uninstall from selection
- Any paging animation or gesture changes
- Changing single-select keyboard focus or reorder springs

## HARD constraints

- Do **not** touch page turn hosts, `pageAnimationDuration`, or paging input paths for multi-select work.
- Single-select focus (Tab / arrows) and reorder must keep working when selection is empty or when Command is not held.
- Plain click must still open/activate exactly as before when Command is not down.

## Next slices (suggested)

1. ~~Prune selection on hide/uninstall/reconcile commit paths.~~ 
2. ~~Context menu: Hide selected / Move selected to folder when `count > 1`.~~ (done: 隐藏所选应用 / 移入新建文件夹)
3. ~~Shift-click range (presented order only).~~
4. ~~Command-A select-all current page.~~
5. ~~Drag selection into existing folder (same page).~~
6. ~~Drop selection onto app → new folder (same page).~~
7. Optional marquee on empty wallpaper (no paging) — deferred (gesture conflict risk).

## Batch context menu (count > 1)

When the right-clicked tile is in the multi-selection and layout editing is on:

| Item | When | Effect |
| --- | --- | --- |
| 隐藏所选应用 | Any selected apps with keys | Hide all via `hideApplications`; clear selection; toast |
| 移入新建文件夹 | ≥2 **top-level** apps on main grid | `createFolderFromTopLevelApps`; clear selection; focus folder |

Single-item 隐藏应用 / 卸载 / 别名 stay when selection count ≤ 1 or the click target is outside the selection. No marquee; no paging.

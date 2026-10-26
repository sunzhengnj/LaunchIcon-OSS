# Multi-select design (foundation)

Status: Core selection + ⌘/Shift-click + ⌘A + prune + context-menu batch + drag into existing folder / drop on app → new folder (same page) + blank-area marquee (MARQUEE-WIRE-01).

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
| Opening Settings | `shouldClearSelectionWhenOpeningSettings` | Clears multi-select before Settings covers the grid (app menu / gear / blank / panel). No paging |
| Blank wallpaper click (selection non-empty) | `shouldClearSelectionInsteadOfDismiss` | Clears selection; does **not** dismiss (second click / Esc dismisses). Marquee-activated release still suppresses dismiss |
| Hide / hotkey / launch-dismiss (selection non-empty) | `shouldClearSelectionOnDismiss` | Clears selection under fade (`announce: false`); next show starts clean |
| Open folder (selection non-empty) | `shouldClearSelectionWhenOpeningFolder` | Clears grid multi-select under the folder veil; members start unselected |
| Close folder (selection non-empty) | `shouldClearSelectionWhenClosingFolder` | Clears multi-select as the veil lifts (`announce: false`) |
| Layout editing disabled (selection non-empty) | `shouldClearSelectionWhenLayoutEditingDisabled` | Clears on enabled→disabled; batch menus unavailable |
| Enter search (idle → non-empty query) | `shouldClearSelectionWhenEnteringSearch` | Clears grid multi-select once; ⌘A inside search still works |
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

- ~~Marquee / rubber-band selection~~ (wired: MARQUEE-WIRE-01)
- ~~Multi-item drag reorder (as a group)~~ — Core `reorderingTopLevelSelection` + Direct WIRE-01 (same-page gap drop; clears selection)
- ~~Drag selection into an **existing** folder (same page)~~
- ~~Drop selection onto an **app** → new folder (same page)~~
- ~~Batch uninstall from selection~~ (BATCH-UNINSTALL-WIRE-01)
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
7. ~~Optional marquee on empty wallpaper (no paging)~~ — Core `LauncherMarquee` (MARQUEE-CORE-01) + Direct MARQUEE-WIRE-01: blank left-drag after 8pt, clamped to current page, replace/Shift/⌘, own white chrome overlay; suppresses wallpaper dismiss after activation. See *Marquee design* below.

## Batch context menu (count > 1)

When the right-clicked tile is in the multi-selection and layout editing is on:

| Item | When | Effect |
| --- | --- | --- |
| 隐藏所选应用 | Any selected apps with keys | Hide all via `hideApplications`; clear selection; toast |
| 移入新建文件夹 | ≥2 **top-level** apps on main grid | `createFolderFromTopLevelApps`; clear selection; focus folder |

Single-item 隐藏应用 / 卸载 / 别名 stay when selection count ≤ 1 or the click target is outside the selection. No marquee; no paging.

## Marquee design (Core + Direct MARQUEE-WIRE-01)

Core: `LauncherMarquee` (geometry + policy, unit-tested). Direct: `LauncherRootView` arms on blank `leftMouseDown` via `LauncherPanel.sendEvent`, activates after `activationDistance`, live-updates selection + white overlay, `didConsumeClick` on release when activated.

### Gesture conflict table

| Existing gesture | Input | Conflict? | Gate |
| --- | --- | --- | --- |
| Page turn (trackpad swipe / scroll wheel) | `scrollWheel` on `PagingCollectionView` | None — marquee is left-button drag only | `canArm` false while `isPaging` (`isPagingGesture \|\| isPageTransitioning`); marquee never auto-scrolls and is `clamped` to the visible page |
| Click wallpaper → dismiss | left up with no consumed click | **Yes** | Marquee starts only after `activationDistance` (8 pt, same as item drag); after activation `suppressesDismissOnRelease` → release must set `didConsumeClick` |
| Item drag / reorder | left drag starting **on a tile** | No | `canArm` requires `startsOnBlankArea` (same hit-chain rule as the blank-area context menu) |
| Double-click wallpaper | `clickCount == 2` | Avoid | `canArm` requires `clickCount == 1` |
| Folder panel / search list | open folder or search | Avoid | `canArm` false when `folderOpen` or `isSearching` (⌘A covers those) |
| Rename / alias alert | modal | Avoid | `canArm` false while `isPromptingForAlias` |
| Dismiss fade | `isDismissing` | Avoid | `canArm` false |

### Selection semantics

- Hits are icon frames overlapping the rect (edge-touch is not a hit), reported in presented order.
- Plain drag replaces; Shift adds to the mouse-down selection; ⌘ toggles relative to the mouse-down selection (⌘ wins over Shift).
- Live updates always re-derive from the mouse-down selection, so shrinking the rect deselects.
- Current page only; no cross-page marquee, no paging, no edge auto-scroll.

### Wiring (MARQUEE-WIRE-01)

`LauncherPanel.sendEvent` → `armMarqueeIfNeeded` / `updateMarquee` / `endMarquee` on the root view (blank hit-chain matches the blank-area menu). Overlay: neutral white fill/stroke. Cancelled on `prepareForPresentation`, `movePage`, and `updatePageDrag` (not `transitionToPage`/`showPage` — page-geometry harness extracts those). No cross-page marquee, no auto-scroll, no LaunchOS assets.

## Batch uninstall (Core model only, 2026-10-25)

`AppBatchUninstallPlan.plan(selection:anchorID:in:candidatesByKey:decide:)` — nil unless the right-clicked item is in a ≥2 selection. Folders are skipped (never expanded); each app uses the single-app `AppUninstallDecision`; blocked apps are listed with reasons; duplicate tiles count once; stale ids are counted as missing; >20 eligible refuses (no truncation). Direct wiring (BATCH-UNINSTALL-WIRE-01): menu item「卸载 N 个应用…」, one confirmation listing skipped items, sequential per-app quit/trash-only via `UninstallCoordinator.promptToBatchUninstall` (no related-file sheets), one summary toast. Refuses while paging or dismissing. Related-file cleanup stays single-app only.

### BATCH-REVEAL-FINDER-01 (done)

- Core: `LauncherLayout.revealInFinderURLs(selection:anchorID:in:candidatesByKey:)` — apps only, folder IDs skipped, URL dedupe, nil if empty.
- Direct: `onRevealInFinderRequested: ([URL]) -> Void`; multi-select menu keeps「在访达中显示」; a11y `在访达中选中所选应用`.
- Remaining out of scope for now: cross-page multi-drag reorder. (Badge + companion hide: MULTI-DRAG-BADGE / COMPANIONS done.)

### MULTI-DRAG-REORDER-WIRE-01 (done)

- Core: `topLevelIDsForBatchReorder` / `shouldBatchReorderSelection` — same page as dragged item; insertAt must lie on that page; ≥2 top-level ids including drag source.
- Direct `applyDrop`: on `.topLevelIndex` when gated, call `reorderingTopLevelSelection` then clear selection. Merge / batch-into-folder paths unchanged.
- Does **not** touch paging hosts or page animation.

### MULTI-DRAG-BADGE-01 (done)

- Core `multiDragBadgeCount` → N when drag source is in a ≥2 top-level selection.
- Direct stamps a blue count pill on the drag image; single-item drag unchanged. No paging.

### MULTI-DRAG-COMPANIONS-01 (done)

- While a multi-select drag is airborne, other selected top-level tiles on the current page set opacity 0; restored with the drag source. Pairs with BADGE-01. No paging.

### BATCH-REMOVE-FROM-FOLDER-01 (done)

- Open-folder multi-select (≥2 members, folder keeps ≥2 after): menu「移出 N 个应用」→ `removingAppsFromFolder`; apps land after the folder tile in member order; clear selection; toast. Single「移出文件夹」unchanged. No paging.

### BLANK-SELECT-ALL-01 (done)

- Blank-area menu (layout editing, main grid):「选择本页全部」→ same as ⌘A current page;「清除选择」when selection non-empty. Folder/search blank menus stay suppressed. No paging.

### SELECTED-COUNT-LABEL-01 (done)

- When multi-select count > 0 and not searching, the adjacent count label shows「已选 N 项」instead of「N 个项目」; search results label unchanged. Refreshes with selection chrome. No paging.

### BATCH-MENU-COUNTS-01 (done)

- Multi-select context menu:「隐藏 N 个应用」/「移入新建文件夹（N）」using hideable-app / top-level-app counts (same style as「卸载 N 个应用…」). Fallbacks keep old titles. No paging.

### BATCH-REVEAL-COUNT-01 (done)

- Core `batchRevealMenuTitleFormatKey` →「在访达中显示（N）」; Direct sets `batchRevealTitle` from `revealInFinderURLs` count (read-only multi-select too). Fallback keeps「在访达中显示」. No paging.

### SELECTION-A11Y-ANNOUNCE-01 (done)

- Core `selectionAnnouncementKind` → `.selected(N)` / `.cleared`; Direct VoiceOver `announcementRequested` on discrete selection changes. Marquee suppresses per-frame (announce once on `endMarquee`). No paging.

### BATCH-DISSOLVE-FOLDERS-01 (done)

- Core: `folderIDsForBatchDissolve` / `dissolvingFolders` — ≥2 top-level folders in selection including the right-clicked anchor; dissolve each in place via `dissolveFolder`.
- Direct: folder tile multi-select menu「解散 N 个文件夹…」with cancel-first confirm; clears selection; toast「已解散 N 个文件夹」. Single「解散文件夹」unchanged when selection count ≤ 1. No paging.

### BATCH-SELECTED-FOLDERS-EDGE-01 (done)

- Core: `movingSelectedFoldersToEdge(folderIDs:atStart:in:)` — ≥2 top-level folders; stable partition of only those folders to front/back; relative order of selected folders and of the rest preserved; nil if unchanged.
- Direct: folder multi-select menu「所选文件夹移到最前/最后」above「解散 N 个文件夹…」; omits front/back when Core would no-op (already at that edge); clears selection; toast with count. Blank-area「文件夹移到最前/最后」(all folders) unchanged. No paging.


### BATCH-SELECTED-APPS-EDGE-01 (done)

- Core: `appIDsForBatchEdgeMove` / `movingSelectedAppsToEdge` — ≥2 top-level apps in selection including the right-clicked anchor; stable partition of only those apps to front/back; relative order preserved; nil if unchanged.
- Direct: app multi-select menu「所选应用移到最前/最后」(above alias/hide); omits front/back when Core would no-op; clears selection; toast with count. Folder edge + blank-area「文件夹移到最前/最后」unchanged. No paging.


### BATCH-BLANK-SELECTED-EDGE-01 (done)

- Core: `topLevelEntryIDsInSelection` / `movingSelectedTopLevelEntriesToEdge` — ≥2 top-level apps and/or folders; stable partition; nil if unchanged.
- Direct: blank-area menu「所选项目移到最前/最后」when multi-select ≥2 top-level (omit when already at edge); clears selection; toast with count. Tile-level apps/folders edge menus unchanged. No paging.



### BLANK-BATCH-SELECTION-ACTIONS-01 (done)

- Blank-area menu (layout editing): when multi-select has hideable apps →「隐藏 N 个应用」; when ≥2 top-level apps →「移入新建文件夹（N）」. Reuses `appKeysForBatchHide` / `topLevelAppIDsForBatchFolder` and existing hide / create-folder helpers. Tile menus unchanged. No paging.


### BLANK-BATCH-REVEAL-01 (done)

- Blank-area menu: when multi-select ≥2 has revealable apps →「在访达中显示（N）」via `revealInFinderURLs` (first selected app as anchor). Clears selection; dismisses launcher like tile reveal. Works while layout editing is on (blank menu already gated). Tile reveal unchanged. No paging.


### SETTINGS-CLEAR-SELECTION-01 (done)

- Core: `shouldClearSelectionWhenOpeningSettings` — clear when selection non-empty.
- Direct: gear / blank「设置…」/ panel settings handoff / AppDelegate `showSettings` call `clearSelectionBeforeOpeningSettings` (`announce: false`). No paging.

### REORGANIZE-CLEAR-SELECTION-01 (done)

- Core: `shouldClearSelectionAfterReorganize` — clear when selection non-empty.
- Direct: `commitReorganizedLayout` clears multi-select (`announce: false`) before commit — covers blank「解散所有文件夹」/「文件夹移到最前/最后」and other callers. No paging.


### BLANK-BATCH-DISSOLVE-01 (done)

- Blank-area menu (layout editing): when multi-select has ≥2 top-level folders →「解散 N 个文件夹…」via `folderIDsForBatchDissolve` (first selected folder as anchor) + existing `dissolveSelectedFolders` (cancel-first confirm, `dissolvingFolders`, clear selection, toast). Tile folder dissolve menu unchanged. No paging.



### BLANK-BATCH-DISSOLVE-SEP-01 (done)

- Blank-area「解散 N 个文件夹…」gets a separator before the item when the previous item is not already a separator (parity with blank uninstall). No paging.

### BLANK-BATCH-UNINSTALL-01 (done)

- Blank-area menu (layout editing): when multi-select has ≥2 items and `AppBatchUninstallPlan` is not `.hidden` →「卸载 N 个应用…」via first selected app as anchor + existing `uninstallSelectedApplications` (`activeCollectionView`, cancel-first, sequential trash-only). Separator before the item. Tile batch uninstall unchanged. No paging.

### BLANK-BATCH-UNINSTALL-DISABLED-01 (done)

- Same blank menu item when plan is `.disabled`: `menu.autoenablesItems = false`, `isEnabled = false`, tooltip/AX help from Core explanation; action toasts the reason if invoked. Mirrors tile batch uninstall disabled chrome. No paging.

### BATCH-UNINSTALL-BLOCKED-NAMES-01 (done)

- Batch uninstall confirm (`promptToBatchUninstall`) lists blocked app names under the skipped-count line via `blockedNameList` (same 5-name truncate as eligible). Folders/missing stay count-only. No paging.

### BATCH-UNINSTALL-BLOCKED-NAME-FALLBACK-01 (done)

- When building `Blocked`, empty/whitespace display names fall back to the bundle file name (same rule as `eligibleNameList`). No paging.

### BATCH-UNINSTALL-BLOCKED-REASONS-01 (done)

- Confirm sheet appends a reason×count summary under blocked names (`blockedReasonSummary`, stable first-seen reason order). No paging.

### BATCH-UNINSTALL-CONFIRM-COPY-01 (done)

- Core `confirmInformativeText(localize:anyRunning:)` owns the confirm sheet body (eligible names, skipped, blocked names/reasons, disclaimer, quit note). Direct only passes `L` + running flag. No paging.

### BATCH-UNINSTALL-RESULT-TOAST-01 (done)

- Core `resultToast(succeeded:failed:)` / `BatchResultToast.message` owns success / partial / all-failed toast copy + autoDismiss. Direct wires after the sequential loop. No paging.

### BATCH-UNINSTALL-PROGRESS-TOAST-01 (done)

- Core `progressToastMessage(index:total:)` owns「正在卸载 i / n…」during sequential trash. Direct uses it in the batch loop. No paging.

### BATCH-UNINSTALL-CONFIRM-BUTTONS-01 (done)

- Core `confirmCancelButtonTitle` / `confirmDestructiveButtonTitle(anyRunning:)` own Cancel / Move to Trash / Quit and Move to Trash. Direct wires batch confirm. Cancel stays first. No paging.

### UNINSTALL-SINGLE-CONFIRM-CHROME-01 (done)

- Single-app confirm reuses Core batch button helpers; trash progress uses `AppUninstallTrashProgress.messageKey`. No paging.

### BATCH-UNINSTALL-PROGRESS-NAME-01 (done)

- Core `progressToastMessage(index:total:appName:)` prefers「正在卸载 i / n：Name」; blank name falls back to count-only. Direct passes `host.displayName`. No paging.

### UNINSTALL-SINGLE-CONFIRM-COPY-01 (done)

- Core `AppUninstallSingleConfirmCopy` owns title + informative body (idle/running + other-copy notes). Direct wires `promptToUninstall`. No paging.

### UNINSTALL-OUTCOME-TOASTS-01 (done)

- Core `AppUninstallOutcomeToast` owns app-changed / still-running / copies-changed / permission / trash-failed mapping via `bundleFailedMessage`. Direct `promptToUninstall` wires helpers. No paging.

### UNINSTALL-RELATED-RESULT-TOAST-01 (done)

- Core `AppUninstallReport.successToastMessage` / `partialRelatedToast` + `AppUninstallFailureReason.relatedLabelKey`. Direct wires success outcomes. No paging.

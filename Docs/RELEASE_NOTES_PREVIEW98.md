# LaunchIcon preview.98 — public WIP snapshot after preview.85 (unnotarized)

Public WIP/prerelease rebuilt from the public source commit that this tag points to. Ad-hoc signed, not Developer ID signed, not notarized. This is not a formal 1.0 and is not a reuse of a private installer.

This snapshot covers product work after public preview.85 through private build 97, plus two later verified fixes (keyboard page-key dispatch, and wallpaper decode scheduling). The public app version is **1.0.0 (98)** because private build 97 was already issued and this tree is newer than that package.

## Highlights since public preview.85

1. Custom-root and scan safety follow-ups, secondary-display layout refresh, and Dock file-link / edge behavior work
2. Search and folder-title typing focus, cancel-button / function-key search fixes, and search-field editing durability
3. Settings window scrolling, tab chrome, compact layout, and several open-settings settle paths
4. Dynamic wallpaper still frames, appearance/screen-change refresh, and a bounded decoder that keeps one active decode plus only the latest pending request
5. Grid geometry preference (columns/rows) wired in Direct and Settings; default remains 7×5. Applying a new size does not rewrite `showPage` / `transitionToPage` / `completePageTransition`
6. Keyboard arrangement and one-step undo (⌘Z) for the last keyboard layout change
7. Page Up/Down from root and chrome, with a later fix so chrome vertical page keys are offered once and registry guards stay scoped
8. Paging and drag-margin refinements (side buttons, Command-arrow, wheel-while-drag, Esc canceling a drag) that leave the three page-turn function bodies unchanged
9. Hide/settings durability, animation finish on hide, and related chrome cleanup
10. Shift+arrow range selection (main grid still uses left/right for paging)

## Validation

- Targeted macOS checks already recorded for the two extra fixes: chrome page-key callback run with 132 events and zero assertion failures; wallpaper-only suite 9 passed, 0 failed, plus a Direct Release compile. Those runs were not a full UI suite.
- Public GitHub Actions `macOS validation` on this sync (Core tests, Direct/Store Release analyze, UI target compile, no UI Runner, no app launch) is recorded on the sync pull request / merge.
- Full UI Runner, physical paging, VoiceOver, device matrix, and a cold start of this DMG are **not claimed**. The last cited full UI green result in earlier private notes was 62/0/2 and is not re-asserted here.
- Ad-hoc signature only. Not Developer ID, not notarized.

## Packaging

- Tag: `v1.0.0-preview.98`
- Asset: `LaunchIcon-v1.0.0-preview.98-macOS-unnotarized.dmg` (ad-hoc)
- Requires macOS 26+ (Apple Silicon / Intel). First open may need System Settings → Privacy & Security → Open Anyway.

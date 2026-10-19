# LaunchIcon v1.0.0-preview.82 — WIP public preview

This release syncs build 82 to the public source repository and provides an installer rebuilt from that public source commit. It is a work-in-progress preview for macOS 26 or later (arm64/x86_64), ad-hoc signed and **not notarized**.

Changes since public preview.78:

- Settings now groups appearance, behavior, applications, and maintenance. Keyboard close/focus and feedback were refined.
- Command-click, Shift range, and Command-A select apps for batch hide and folder organization.
- Layout maintenance can sort top-level items, export/import layouts, and restore the previous backup.
- Optional hot-corner invocation, search empty state and folder-member results, and keyboard result navigation were added.
- Uninstall eligibility and related-file handling gained safeguards and clearer per-item feedback.
- Reduce Motion snaps more launcher, folder, drag, and search transitions to their final state.
- Paging position, direction, and timing received targeted corrections, but continuous physical-input feel is not yet accepted.

The public background validation result is in `Docs/TEST_MATRIX.md`. Full UI automation and physical-input regression were not run for this public snapshot. Store distribution, Developer ID signing, and notarization remain open. See `Docs/SOURCE_SNAPSHOT_2026-10-19.md` for the sync boundary.

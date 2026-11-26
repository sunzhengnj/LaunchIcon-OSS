# Source snapshot 2026-11-26 (preview.98)

Public WIP snapshot of product source after public preview.85. The export combines the private `main` tip with two subsequently verified, still-unmerged product fixes. It is not a copy of the private preview.97 installer.

- Private `main` at sync: `232701323edcd3a2a5f52a031e12099e185434cb` (docs: daily review 2026-11-23). Latest business commit on that branch: `1b2c298ee0f01f5297f257c61ba0f014ef97b6c1`.
- Additional product fixes included (local integration only; private `main` was not merged or pushed):
  - page-key single dispatch / scoped registry guards at `4cefd948a21943865fa914edba9bdb54ee4d1f14`
  - wallpaper decode scheduler (one active decode, keep only the latest pending request) at `a5056d24105aa2962836487e9a8d09264493f4c6`
- Build: `CURRENT_PROJECT_VERSION = 98`, `MARKETING_VERSION = 1.0.0`. Public preview.85 was build 85; private already used build 97, and this tree is newer than that private package, so the public snapshot uses the next unused build number 98.
- Maintainer `DEVELOPMENT_TEAM` stripped for the public project file
- Public community docs (README*, AGENTS, CONTRIBUTING, LICENSE, NOTICE, SECURITY, SUPPORT, CODE_OF_CONDUCT, `.github/` at export time, `Docs/SYNC_FROM_PRIVATE.md`) were **not** overwritten
- Public `Docs/Media`, historical release notes / source snapshots, `Docs/RELEASE_PROCESS.md`, and `Docs/TEST_MATRIX.md` were left as the public versions (the private test matrix contains internal paths and signing identifiers)
- Internal private files were not exported: `HANDOFF.md`, `TASKS.md`, `DECISIONS.md`, `Docs/DAILY_REVIEW.md`, `Docs/daily-reviews/`, `Docs/CODEX_GOAL.md`, `Docs/superpowers/`, `.codex/`, private CI workflow changes, and an unverified icon-flight investigation
- `showPage` / `transitionToPage` / `completePageTransition` function bodies are unchanged from private `main`
- Hot-corner script keeps the public optional-`DECISIONS.md` guard

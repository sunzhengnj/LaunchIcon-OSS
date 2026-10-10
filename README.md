<p align="right"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>

<p align="center">
  <img src="Resources/Assets.xcassets/LaunchIconBrand.imageset/Brand-Light@2x.png" width="112" alt="LaunchIcon four-color logo">
</p>

<h1 align="center">LaunchIcon</h1>

<p align="center"><strong>A lightweight, local-first app grid launcher for macOS 26+.</strong><br>
Press <kbd>⌥ Space</kbd> to see your apps in a 7 × 5 grid. Sort them into folders, drag them where you want, and search by name, including Chinese pinyin.<br>
Native AppKit · no account · no network · your layout stays on your Mac.</p>

<p align="center">
  <a href="https://github.com/sunzhengnj/LaunchIcon-OSS/releases/latest"><img src="https://img.shields.io/github/v/release/sunzhengnj/LaunchIcon-OSS?label=release" alt="Latest release"></a>
  <a href="https://github.com/sunzhengnj/LaunchIcon-OSS/actions/workflows/macos-validation.yml"><img src="https://github.com/sunzhengnj/LaunchIcon-OSS/actions/workflows/macos-validation.yml/badge.svg" alt="macOS validation"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="Apache-2.0 license"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Swift-AppKit-orange" alt="Swift and AppKit">
</p>

<p align="center">
  <a href="https://github.com/sunzhengnj/LaunchIcon-OSS/releases/latest"><strong>⬇ Download (unnotarized preview)</strong></a> ·
  <a href="#install">Install</a> ·
  <a href="#known-limitations">Known limitations</a> ·
  <a href="#build-from-source">Build from source</a> ·
  <a href="CONTRIBUTING.md">Contribute</a>
</p>

<!-- Demo slot: uncomment once Docs/Media/demo.gif is committed.
<p align="center"><img src="Docs/Media/demo.gif" width="760" alt="LaunchIcon demo: open with Option-Space, search by pinyin, drag an app into a folder"></p>
-->

> [!NOTE]
> **Early release, feedback welcome.** The installer is ad-hoc signed and **not notarized** (see [Install](#install)). The full UI test suite is not all green yet, and drag and drop across pages is still being fixed. See [Known limitations](#known-limitations).

> [!IMPORTANT]
> **The source and installer are at different revisions.** `main` contains a newer **work-in-progress source snapshot**. The [v1.0.0 installer](https://github.com/sunzhengnj/LaunchIcon-OSS/releases/tag/v1.0.0) was built from an earlier revision and does not include the changes listed below. There is no installer for the current `main` snapshot. See the [snapshot notes](Docs/SOURCE_SNAPSHOT_2026-10-09.md).

## Highlights

- **7 × 5 app grid with pages.** Browse with the mouse or keyboard navigation.
- **Folders and drag to organize.** Reorder apps, create and rename folders, and hide apps you never open.
- **Fast search, including Chinese.** Search names and aliases; Chinese app names match full pinyin or initials (e.g. `wx` → 微信).
- **Opens with `⌥ Space`** or from the menu bar. The shortcut can be changed in Settings.
- **Local-first and private.** No account, no cloud sync, no network calls. Layout and preferences are stored only on your Mac.
- **Native and lightweight.** Built with Swift and AppKit, uses public macOS APIs to find installed apps, and follows Reduce Motion.

## Features

| Browse | Organize | Find |
| --- | --- | --- |
| 7 × 5 app grid, pages, and keyboard navigation | Drag to reorder; create and rename folders | Search app names and aliases |
| Scan installed apps using public macOS APIs | Keep layout and preferences on your Mac | Search Chinese names by full pinyin or initials |
| Open with `⌥ Space` or the menu bar | Hide apps and restore them in Settings | Chinese and English interface in the current source |

LaunchIcon uses its own visual design. It does not read the system Launchpad database, copy another launcher's assets, or require an account or cloud sync. It follows the macOS Reduce Motion setting. Pinyin transliteration uses Foundation's default pronunciation.

### New in the current source snapshot

- App launch requests stop showing a perpetual loading state after 10 seconds and display a timeout notice. LaunchIcon now shows its main window when opened.
- Holding a drag near either screen edge can turn pages. Folders have no 25-app cap, and their cover previews up to nine icons.
- Folder merge motion starts at the drop position. The Direct app now includes English and Chinese UI strings.

These changes still need complete UI and physical-input verification. **A dark-mode Dock/Finder app icon is not yet implemented**; the existing dark brand image is not an AppIcon appearance variant.

## Install

1. Download `LaunchIcon-v1.0.0-macOS-unnotarized.dmg` and its `.sha256` file from the [v1.0.0 release](https://github.com/sunzhengnj/LaunchIcon-OSS/releases/tag/v1.0.0), then verify the download in the folder that holds both files:
   ```bash
   shasum -a 256 -c LaunchIcon-v1.0.0-macOS-unnotarized.dmg.sha256
   ```
2. Open the DMG and drag `LaunchIcon.app` to Applications. Quit an older copy before replacing it; your saved layout and preferences live outside the app bundle.
3. Open LaunchIcon once. macOS will say it can't verify the developer. This is expected: the app is **ad-hoc signed and not notarized yet**.
4. Only if you trust the download from this repository, go to **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway** next to LaunchIcon, and confirm with your password or Touch ID. On macOS 15 and later, Control-click → Open no longer bypasses this prompt. See [Apple's guidance](https://support.apple.com/102445).
5. **The v1.0.0 build starts in the background.** Press `⌥ Space` or click the menu bar icon to show the grid. (The newer source snapshot opens its main window on launch.)

Please don't disable Gatekeeper or run quarantine-removal commands you don't trust. If you'd rather not run an unnotarized build, [build from source](#build-from-source) with Xcode.

## Known limitations

- The installer is ad-hoc signed, not Developer ID signed or notarized.
- The last full UI suite recorded **47 passed / 5 failed / 2 skipped** and has not been rerun on the current snapshot.
- Drag and drop across pages is still being fixed. Physical-input, VoiceOver, large-folder, and dark Dock/Finder icon checks are still open.
- The v1.0.0 installer starts in the background (use `⌥ Space` or the menu bar icon).
- Requires macOS 26 or later.

## Build from source

**Requirements:** macOS 26 or later, Xcode 27, and its matching SDK.

```bash
git clone https://github.com/sunzhengnj/LaunchIcon-OSS.git
cd LaunchIcon-OSS
./script/validate_background.sh
```

Open `LaunchIcon.xcodeproj` in Xcode and configure your own Apple development team for signing. The repository contains no maintainer Team ID, certificate, or notarization credentials.

The background validation script runs a network API static guard, Core tests, Release analysis for Direct and StoreSpike, and a UI test target build. **It does not run the app or the UI test suite.** Visible tests take over the desktop and require the computer user's consent:

```bash
LAUNCHICON_ALLOW_VISIBLE_TESTS=1 ./script/test_direct_bootstrap.sh
```

`StoreSpike` is a sandbox feasibility target, not an App Store release. Packaging and signing entry points are in `script/package_preview.sh` and `script/distribution_preflight.sh`.

## Project status

| Area | Current evidence |
| --- | --- |
| Core and build | Current public snapshot: Core **129/129** locally, Direct/StoreSpike Release analysis, UI target build, and [GitHub macOS validation](https://github.com/sunzhengnj/LaunchIcon-OSS/actions/workflows/macos-validation.yml) passed. A Direct Release build also passed locally. |
| Full UI | The most recent full suite recorded before this snapshot had **47 passed / 5 failed / 2 skipped**. It has not been rerun on this public snapshot. |
| Distribution | No installer was produced for the current `main`. The v1.0.0 DMG remains ad-hoc signed and unnotarized. |
| Open checks | Physical drag and drop, large folders, individual app launches, VoiceOver, Store sandbox behavior, and the dark Dock/Finder icon. |

The CI badge reports **background validation only**. It is not a claim that the full UI suite or distribution checks passed. See the [test matrix](Docs/TEST_MATRIX.md) and [snapshot notes](Docs/SOURCE_SNAPSHOT_2026-10-09.md).

## Contributing

Issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md) before changing code. Keep changes tied to a documented requirement or reproducible bug, and report Core, UI, and packaging results separately. For bug reports, include the app version, macOS version, chip, and reproduction steps; remove personal data from logs, crash reports, layouts, and preferences.

Daily development happens in a separate maintainer repository. This public repository receives reviewed releases and explicitly labeled source snapshots; see the [sync policy](Docs/SYNC_FROM_PRIVATE.md).

## License

Code and documentation are available under the [Apache License 2.0](LICENSE); see [NOTICE](NOTICE). The LaunchIcon name and brand artwork identify this project and are not automatically licensed as trademarks. LaunchIcon is not an Apple Launchpad clone.

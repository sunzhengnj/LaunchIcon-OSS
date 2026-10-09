#!/usr/bin/env bash
set -euo pipefail

if [[ "${LAUNCHICON_ALLOW_VISIBLE_TESTS:-}" != "1" ]]; then
  echo "This test launches LaunchIcon and may show a window. Set LAUNCHICON_ALLOW_VISIBLE_TESTS=1 only during an agreed UI test window." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/LaunchIcon-DirectBootstrap.XXXXXX")"
AUDIT_DIR="$(cd "$AUDIT_DIR" && pwd -P)"
BUNDLE_ID="com.sunzheng.LaunchIcon.BootstrapTest$$"
FAILURE_SUITE="$BUNDLE_ID.shortcutFailure"
APP_BUNDLE="$AUDIT_DIR/DerivedData/Build/Products/Debug/LaunchIcon.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/LaunchIcon"
LOG_PATH="$AUDIT_DIR/diagnostics.log"

stop_test_process() {
  /bin/ps ax -o pid= -o command= | /usr/bin/awk -v binary="$APP_BINARY" '$2 == binary { print $1 }' |
    while IFS= read -r pid; do
      kill "$pid" 2>/dev/null || true
    done
}

cleanup() {
  stop_test_process
  defaults delete "$FAILURE_SUITE" >/dev/null 2>&1 || true
  rm -rf "$AUDIT_DIR"
}
trap cleanup EXIT

mkdir -p "$AUDIT_DIR/Applications"
mkdir -p "$AUDIT_DIR/catalog-v1.json"
cp "$ROOT_DIR/Tests/stale-entries-layout.json" "$AUDIT_DIR/layout-v1.json"
ln -s /System/Applications/Calculator.app "$AUDIT_DIR/Applications/Calculator.app"
mkdir -p "$AUDIT_DIR/Applications/Unlaunchable.app/Contents"
UNLAUNCHABLE_INFO="$AUDIT_DIR/Applications/Unlaunchable.app/Contents/Info.plist"
plutil -create xml1 "$UNLAUNCHABLE_INFO"
plutil -insert CFBundleIdentifier -string com.launchicon.bootstrap.unlaunchable "$UNLAUNCHABLE_INFO"
plutil -insert CFBundleName -string Unlaunchable "$UNLAUNCHABLE_INFO"
plutil -insert CFBundlePackageType -string APPL "$UNLAUNCHABLE_INFO"
plutil -insert CFBundleExecutable -string MissingExecutable "$UNLAUNCHABLE_INFO"
touch "$AUDIT_DIR/scan.hold"

xcodebuild \
  -project "$ROOT_DIR/LaunchIcon.xcodeproj" \
  -scheme LaunchIconDirect \
  -configuration Debug \
  -derivedDataPath "$AUDIT_DIR/DerivedData" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build -quiet

/usr/bin/open -n -a "$APP_BUNDLE" \
  --env "LAUNCHICON_TEST_SCAN_ROOT=$AUDIT_DIR/Applications" \
  --env "LAUNCHICON_TEST_LAYOUT_PATH=$AUDIT_DIR/layout-v1.json" \
  --env "LAUNCHICON_TEST_PREFERENCES_SUITE=$BUNDLE_ID.preferences" \
  --env "LAUNCHICON_DIAGNOSTICS_PATH=$LOG_PATH" \
  --env "LAUNCHICON_TEST_SCAN_HOLD_FILE=$AUDIT_DIR/scan.hold" \
  --env LAUNCHICON_TEST_CANCEL_SCAN_WITHOUT_RETRY=1

booted=false
for ((attempt = 0; attempt < 40; attempt++)); do
  if [[ -f "$LOG_PATH" ]] && /usr/bin/grep -Fq 'Hot key ' "$LOG_PATH"; then
    booted=true
    break
  fi
  sleep 0.1
done
if [[ "$booted" != true ]]; then
  echo "Held startup did not reach the scan cancellation check" >&2
  exit 1
fi
sleep 1
if ! /usr/bin/cmp -s "$ROOT_DIR/Tests/stale-entries-layout.json" "$AUDIT_DIR/layout-v1.json"; then
  echo "Cancelling the initial scan overwrote the existing layout" >&2
  exit 1
fi
stop_test_process
rm "$AUDIT_DIR/scan.hold"

/usr/bin/open -n -a "$APP_BUNDLE" \
  --env "LAUNCHICON_TEST_SCAN_ROOT=$AUDIT_DIR/Applications" \
  --env "LAUNCHICON_TEST_LAYOUT_PATH=$AUDIT_DIR/layout-v1.json" \
  --env "LAUNCHICON_TEST_PREFERENCES_SUITE=$BUNDLE_ID.preferences" \
  --env "LAUNCHICON_DIAGNOSTICS_PATH=$LOG_PATH" \
  --env LAUNCHICON_TEST_CANCEL_SCAN_ON_BOOT=1 \
  --env "LAUNCHICON_SPIKE_LAUNCH_PATH=$AUDIT_DIR/NeverLaunch.app"

ready=false
for ((attempt = 0; attempt < 60; attempt++)); do
  if [[ -f "$AUDIT_DIR/layout-v1.json" && -f "$LOG_PATH" ]] &&
     /usr/bin/grep -Fq 'bundle:com.apple.calculator' "$AUDIT_DIR/layout-v1.json" &&
     [[ "$(/usr/bin/plutil -extract orderedEntries raw -o - "$AUDIT_DIR/layout-v1.json" 2>/dev/null)" == 2 ]] &&
     [[ "$(/usr/bin/plutil -extract orderedEntries.0.app._0 raw -o - "$AUDIT_DIR/layout-v1.json" 2>/dev/null)" == '11111111-2222-4333-8444-555555555555' ]] &&
     ! /usr/bin/grep -Fq '22222222-3333-4444-8555-666666666666' "$AUDIT_DIR/layout-v1.json" &&
     ! /usr/bin/grep -Fq '33333333-4444-4555-8666-777777777777' "$AUDIT_DIR/layout-v1.json" &&
     ! /usr/bin/grep -Fq '44444444-5555-4666-8777-888888888888' "$AUDIT_DIR/layout-v1.json" &&
     /usr/bin/grep -Fq 'Discovery: 2 candidates; skipped: 0' "$LOG_PATH" &&
     /usr/bin/grep -Fq '/Applications/Unlaunchable.app; bundle executable missing or not executable' "$LOG_PATH"; then
    ready=true
    break
  fi
  sleep 0.25
done

if [[ "$ready" != true ]]; then
  echo "Cancelled scan did not recover and reconcile stale layout entries" >&2
  if [[ -f "$AUDIT_DIR/layout-v1.json" ]]; then
    /usr/bin/plutil -p "$AUDIT_DIR/layout-v1.json" >&2
  fi
  if [[ -f "$LOG_PATH" ]]; then
    tail -n 20 "$LOG_PATH" >&2
  fi
  exit 1
fi
if /usr/bin/grep -Eq 'Launch requested:|Launch request submitted|Launch failed:' "$LOG_PATH"; then
  echo "Legacy spike environment variable unexpectedly launched an app" >&2
  exit 1
fi

cache_error_logged=false
for ((attempt = 0; attempt < 20; attempt++)); do
  if /usr/bin/grep -Fq 'Catalog snapshot save failed:' "$LOG_PATH"; then
    cache_error_logged=true
    break
  fi
  sleep 0.25
done
if [[ "$cache_error_logged" != true ]]; then
  echo "Catalog snapshot write failure was not diagnosed" >&2
  exit 1
fi

stop_test_process
defaults write "$FAILURE_SUITE" LaunchIcon.Preferences.showsStatusItem -bool false
if [[ "$(defaults read "$FAILURE_SUITE" LaunchIcon.Preferences.showsStatusItem)" != 0 ]]; then
  echo "Shortcut failure fixture did not start with the menu bar fallback disabled" >&2
  exit 1
fi
/usr/bin/open -n -a "$APP_BUNDLE" \
  --env "LAUNCHICON_TEST_SCAN_ROOT=$AUDIT_DIR/Applications" \
  --env "LAUNCHICON_TEST_LAYOUT_PATH=$AUDIT_DIR/layout-v1.json" \
  --env "LAUNCHICON_TEST_PREFERENCES_SUITE=$FAILURE_SUITE" \
  --env "LAUNCHICON_DIAGNOSTICS_PATH=$LOG_PATH" \
  --env LAUNCHICON_TEST_FORCE_HOTKEY_FAILURE=optionSpace

shortcut_recovered=false
for ((attempt = 0; attempt < 40; attempt++)); do
  if /usr/bin/grep -Fq 'Hot key ⌥ Space: failed: registrationFailed(-1)' "$LOG_PATH" &&
     /usr/bin/grep -Fq 'Shortcut recovery shown: registrationFailed(-1)' "$LOG_PATH" &&
     [[ "$(defaults read "$FAILURE_SUITE" LaunchIcon.Preferences.showsStatusItem 2>/dev/null)" == 1 ]]; then
    shortcut_recovered=true
    break
  fi
  sleep 0.25
done
if [[ "$shortcut_recovered" != true ]]; then
  echo "Failed shortcut registration did not restore the menu bar fallback" >&2
  tail -n 20 "$LOG_PATH" >&2
  exit 1
fi

echo "Direct bootstrap regression passed: cancelled scan preserved existing layout; retry removed stale and duplicate entries; unlaunchable bundle diagnosed; legacy auto-launch ignored; cache write failure and shortcut fallback diagnosed"

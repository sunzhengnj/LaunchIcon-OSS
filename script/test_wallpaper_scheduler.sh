#!/bin/bash
# Only the nine production scheduler tests and Direct compilation; no UI runner.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Wallpaper XCTest validation requires macOS/Xcode; not a successful skip." >&2
  exit 1
fi

cd "$(dirname "$0")/.."
work_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/wallpaper-validation.XXXXXX")
printf 'Targeted wallpaper validation in %s\n' "$work_dir"

xcodebuild -quiet -project LaunchIcon.xcodeproj \
  -scheme LaunchIconCoreTests -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$work_dir/Core" \
  -resultBundlePath "$work_dir/Wallpaper.xcresult" \
  -only-testing:LaunchIconCoreTests/DesktopBackgroundDecodeSchedulerTests \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 30 \
  -maximum-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO test

xcrun xcresulttool get test-results summary \
  --path "$work_dir/Wallpaper.xcresult" > "$work_dir/summary.json"
python3 script/verify_wallpaper_test_summary.py "$work_dir/summary.json"

xcodebuild -quiet -project LaunchIcon.xcodeproj \
  -scheme LaunchIconDirect -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$work_dir/Direct" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build

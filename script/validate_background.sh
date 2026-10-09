#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$(mktemp -d /private/tmp/LaunchIcon-BackgroundValidation.XXXXXX)"
trap 'rm -rf "$DERIVED_DATA"' EXIT

"$ROOT_DIR/script/check_no_network_apis.sh"
TMPDIR=/private/tmp "$ROOT_DIR/script/test_core.sh"

for scheme in LaunchIconDirect LaunchIconStoreSpike; do
  xcodebuild -quiet \
    -project "$ROOT_DIR/LaunchIcon.xcodeproj" \
    -scheme "$scheme" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA/$scheme" \
    CODE_SIGNING_ALLOWED=NO \
    analyze
done

# Compile XCTest code without starting the app, UI Runner, or an automation session.
xcodebuild -quiet \
  -project "$ROOT_DIR/LaunchIcon.xcodeproj" \
  -scheme LaunchIconUITests \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA/LaunchIconUITests" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

echo "Background validation passed; no app or UI Runner was launched."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/LaunchIcon-CoreTests.XXXXXX")"

cleanup() {
  rm -rf "$DERIVED_DATA"
}
trap cleanup EXIT

xcodebuild \
  -project "$ROOT_DIR/LaunchIcon.xcodeproj" \
  -scheme LaunchIconCoreTests \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  build-for-testing -quiet

# Core tests do not need Xcode's UI automation session.
XCTEST_BINARY="$(xcrun --find xctest)"
DYLD_FRAMEWORK_PATH="$DERIVED_DATA/Build/Products/Debug" \
  "$XCTEST_BINARY" "$DERIVED_DATA/Build/Products/Debug/LaunchIconCoreTests.xctest"

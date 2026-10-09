#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/build/release-preview}"
DERIVED_DATA="$OUTPUT_DIR/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/LaunchIcon.app"

[[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]] || {
  echo "Commit or remove working-tree changes before packaging a preview." >&2
  exit 1
}
source_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"

mkdir -p "$OUTPUT_DIR"
xcodebuild \
  -quiet \
  -project "$ROOT_DIR/LaunchIcon.xcodeproj" \
  -scheme LaunchIconDirect \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

[[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$source_commit" &&
   -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]] || {
  echo "Source changed while the preview was building." >&2
  exit 1
}
plutil -replace LaunchIconSourceCommit -string "$source_commit" "$APP_PATH/Contents/Info.plist"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
embedded_commit="$(/usr/libexec/PlistBuddy -c 'Print :LaunchIconSourceCommit' "$APP_PATH/Contents/Info.plist")"
[[ "$short_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_version" =~ ^[0-9]+$ ]] || {
  echo "Expected numeric app and build versions, got $short_version ($build_version)" >&2
  exit 1
}
[[ "$embedded_commit" == "$source_commit" ]] || {
  echo "Built app does not identify the current source commit." >&2
  exit 1
}

for arch in arm64 x86_64; do
  if ! otool -l -arch "$arch" "$APP_PATH/Contents/MacOS/LaunchIcon" |
    grep -F 'path @executable_path/../Frameworks' >/dev/null; then
    echo "Missing embedded framework runtime path for $arch" >&2
    exit 1
  fi
done

version="${LAUNCHICON_RELEASE_TAG:-v$short_version-preview.$build_version}"
[[ "$version" == "v$short_version-preview.$build_version" || "$version" == "v$short_version" ]] || {
  echo "Release tag $version does not match App version $short_version ($build_version)." >&2
  exit 1
}
[[ -z "$(git -C "$ROOT_DIR" tag -l "$version")" ]] || {
  echo "Preview tag already exists: $version" >&2
  exit 1
}
asset_name="LaunchIcon-$version-macOS-unnotarized.dmg"
asset_path="$OUTPUT_DIR/$asset_name"
[[ ! -e "$asset_path" ]] || {
  echo "Package already exists: $asset_path" >&2
  exit 1
}

# Ad-hoc signatures have no shared Team ID. Hardened Runtime's library validation
# rejects the embedded Core framework even when both bundles verify correctly.
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

stage_dir="$(mktemp -d "$OUTPUT_DIR/.LaunchIcon-stage.XXXXXX")"
trap 'rm -r "$stage_dir"' EXIT
ditto "$APP_PATH" "$stage_dir/LaunchIcon.app"
ln -s /Applications "$stage_dir/Applications"
hdiutil create -quiet -fs HFS+ -volname "LaunchIcon $version" -srcfolder "$stage_dir" "$asset_path"
hdiutil verify -quiet "$asset_path"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$asset_name" > "$asset_name.sha256"
)

echo "Preview package: $asset_path"
echo "Checksum: $asset_path.sha256"
echo "Source commit: $source_commit"
echo "Ad-hoc signed, not Developer ID signed or notarized."

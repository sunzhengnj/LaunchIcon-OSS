#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <local-dmg> <source-commit-or-tag> [downloaded-dmg]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DMG="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
SOURCE_REF="$2"
DOWNLOADED_DMG="${3:-}"
ASSET_NAME="$(basename "$LOCAL_DMG")"
CHECKSUM_FILE="$LOCAL_DMG.sha256"

[[ -f "$LOCAL_DMG" && -f "$CHECKSUM_FILE" ]] || {
  echo "Missing local DMG or checksum: $LOCAL_DMG" >&2
  exit 1
}
if [[ "$SOURCE_REF" == v* ]]; then
  SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify "refs/tags/$SOURCE_REF^{commit}")"
else
  SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify "$SOURCE_REF^{commit}")"
fi
PRODUCT_PATHS=(Sources Resources LaunchIcon.xcodeproj script/package_preview.sh)
if ! git -C "$ROOT_DIR" diff --quiet "$SOURCE_COMMIT" HEAD -- "${PRODUCT_PATHS[@]}" ||
   [[ -n "$(git -C "$ROOT_DIR" status --porcelain -- "${PRODUCT_PATHS[@]}")" ]]; then
  echo "Current product source differs from package source $SOURCE_COMMIT; rebuild before publishing." >&2
  exit 1
fi
read -r RECORDED_HASH RECORDED_NAME < "$CHECKSUM_FILE"
[[ "$RECORDED_NAME" == "$ASSET_NAME" ]] || {
  echo "Checksum names a different asset: $RECORDED_NAME" >&2
  exit 1
}
ACTUAL_HASH="$(shasum -a 256 "$LOCAL_DMG" | awk '{print $1}')"
[[ "$RECORDED_HASH" == "$ACTUAL_HASH" ]] || {
  echo "Local DMG SHA-256 does not match its checksum." >&2
  exit 1
}

if [[ -n "$DOWNLOADED_DMG" ]]; then
  [[ -f "$DOWNLOADED_DMG" && -f "$DOWNLOADED_DMG.sha256" ]] || {
    echo "Missing downloaded DMG or checksum: $DOWNLOADED_DMG" >&2
    exit 1
  }
  cmp -s "$LOCAL_DMG" "$DOWNLOADED_DMG" || {
    echo "Downloaded DMG differs from the locally verified package." >&2
    exit 1
  }
  cmp -s "$CHECKSUM_FILE" "$DOWNLOADED_DMG.sha256" || {
    echo "Downloaded checksum differs from the locally verified checksum." >&2
    exit 1
  }
fi

hdiutil verify -quiet "$LOCAL_DMG"
ATTACH_PLIST="$(hdiutil attach -readonly -nobrowse -plist "$LOCAL_DMG")"
MOUNT_POINT=""
for entity_index in {0..9}; do
  if candidate_mount_point="$(printf '%s' "$ATTACH_PLIST" | plutil -extract "system-entities.$entity_index.mount-point" raw -o - - 2>/dev/null)"; then
    MOUNT_POINT="$candidate_mount_point"
    break
  fi
done
[[ -d "$MOUNT_POINT" ]] || {
  echo "The preview DMG did not mount." >&2
  exit 1
}
cleanup() { hdiutil detach "$MOUNT_POINT" >/dev/null; }
trap cleanup EXIT

APP_PATH="$MOUNT_POINT/LaunchIcon.app"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || {
  echo "Preview DMG does not contain LaunchIcon.app." >&2
  exit 1
}
EMBEDDED_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :LaunchIconSourceCommit' "$INFO_PLIST")"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
VERSION_TAG="v$SHORT_VERSION-preview.$BUILD_VERSION"
if [[ "$ASSET_NAME" == "LaunchIcon-v$SHORT_VERSION-macOS-unnotarized.dmg" ]]; then
  VERSION_TAG="v$SHORT_VERSION"
fi
[[ "$EMBEDDED_COMMIT" == "$SOURCE_COMMIT" ]] || {
  echo "Package source $EMBEDDED_COMMIT does not match $SOURCE_REF ($SOURCE_COMMIT)." >&2
  exit 1
}
[[ "$ASSET_NAME" == "LaunchIcon-$VERSION_TAG-macOS-unnotarized.dmg" ]] || {
  echo "Package filename does not match App version $VERSION_TAG." >&2
  exit 1
}
if [[ "$SOURCE_REF" == v* && "$SOURCE_REF" != "$VERSION_TAG" ]]; then
  echo "Tag $SOURCE_REF does not match App version $VERSION_TAG." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP_PATH"
for arch in arm64 x86_64; do
  lipo -verify_arch "$arch" "$APP_PATH/Contents/MacOS/LaunchIcon"
done

echo "Verified $ASSET_NAME"
echo "Source commit: $EMBEDDED_COMMIT"
echo "SHA-256: $ACTUAL_HASH"
if [[ -n "$DOWNLOADED_DMG" ]]; then
  echo "Downloaded DMG and checksum are byte-identical."
fi

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LaunchIcon"
ARCHIVE_PATH="${LAUNCHICON_ARCHIVE_PATH:-$ROOT_DIR/build/$APP_NAME.xcarchive}"
APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"

usage() {
  cat <<'EOF'
Usage:
  ./script/distribution_preflight.sh --preflight
  ./script/distribution_preflight.sh --verify <path-to-LaunchIcon.app>
  DEVELOPER_ID_APPLICATION='Developer ID Application: …' \
  NOTARY_KEYCHAIN_PROFILE='<notarytool keychain profile>' \
  ./script/distribution_preflight.sh --archive-and-notarize

--preflight checks that a Developer ID Application signing identity is installed.
--verify checks an existing distribution app for a valid hardened signature,
no development-only get-task-allow entitlement, and a stapled notarization ticket.
--archive-and-notarize creates a Release archive, submits its ZIP with notarytool,
then staples and validates the ticket. It requires both environment variables above.
EOF
}

find_developer_id_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
    | head -n 1
}

require_developer_id_identity() {
  DEVELOPER_ID_RESOLVED="${DEVELOPER_ID_APPLICATION:-$(find_developer_id_identity)}"
  if [[ -z "$DEVELOPER_ID_RESOLVED" ]]; then
    cat >&2 <<'EOF'
Distribution preflight failed: no Developer ID Application identity is installed.
Install the certificate in the login keychain, then run this command again. The
currently available Apple Development certificate is suitable for local builds,
not for Developer ID notarization.
EOF
    exit 1
  fi
  if [[ "$DEVELOPER_ID_RESOLVED" != "Developer ID Application:"* ]]; then
    echo "Distribution preflight failed: DEVELOPER_ID_APPLICATION must name a Developer ID Application identity." >&2
    exit 1
  fi
}

verify_app() {
  local app="$1"
  [[ -d "$app" ]] || { echo "App bundle not found: $app" >&2; exit 2; }

  codesign --verify --deep --strict --verbose=2 "$app"
  local signing_details
  signing_details="$(codesign -dvvv "$app" 2>&1)"
  grep -q 'Authority=Developer ID Application:' <<<"$signing_details" || {
    echo "Distribution verification failed: app is not signed with Developer ID Application." >&2
    exit 1
  }
  grep -q 'flags=.*runtime' <<<"$signing_details" || {
    echo "Distribution verification failed: Hardened Runtime is missing." >&2
    exit 1
  }

  local entitlements_file
  entitlements_file="$(mktemp "${TMPDIR:-/tmp}/launchicon-entitlements.XXXXXX")"
  trap 'rm -f "$entitlements_file"' RETURN
  codesign -d --entitlements :- "$app" >"$entitlements_file" 2>/dev/null || true
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements_file" 2>/dev/null | grep -qx 'true'; then
    echo "Distribution verification failed: get-task-allow must not be enabled." >&2
    exit 1
  fi

  xcrun stapler validate "$app"
  echo "Distribution verification passed: $app"
}

archive_and_notarize() {
  require_developer_id_identity
  local identity="$DEVELOPER_ID_RESOLVED"
  local profile="${NOTARY_KEYCHAIN_PROFILE:-}"
  [[ -n "$profile" ]] || {
    echo "NOTARY_KEYCHAIN_PROFILE is required for notarization." >&2
    exit 2
  }

  if [[ -e "$ARCHIVE_PATH" ]]; then
    echo "Archive path already exists; choose a new LAUNCHICON_ARCHIVE_PATH: $ARCHIVE_PATH" >&2
    exit 2
  fi
  xcodebuild \
    -project "$ROOT_DIR/LaunchIcon.xcodeproj" \
    -scheme LaunchIconDirect \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$identity" \
    archive

  local zip_path="$ROOT_DIR/build/$APP_NAME-notarization.zip"
  mkdir -p "$(dirname "$zip_path")"
  if [[ -e "$zip_path" ]]; then
    echo "Notarization ZIP already exists; move it aside before retrying: $zip_path" >&2
    exit 2
  fi
  ditto -c -k --keepParent "$APP_PATH" "$zip_path"
  xcrun notarytool submit "$zip_path" --keychain-profile "$profile" --wait
  xcrun stapler staple "$APP_PATH"
  verify_app "$APP_PATH"
}

case "${1:---preflight}" in
  --preflight)
    require_developer_id_identity
    echo "Developer ID identity ready: $DEVELOPER_ID_RESOLVED"
    ;;
  --verify)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    verify_app "$2"
    ;;
  --archive-and-notarize)
    archive_and_notarize
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

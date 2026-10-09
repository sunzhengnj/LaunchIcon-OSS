#!/usr/bin/env bash
set -euo pipefail

if [[ "${LAUNCHICON_ALLOW_VISIBLE_TESTS:-}" != "1" ]]; then
  echo "This script may show a LaunchIcon window. Set LAUNCHICON_ALLOW_VISIBLE_TESTS=1 only during an agreed UI test window." >&2
  exit 2
fi

MODE="${1:-run}"
APP_NAME="LaunchIcon"
BUNDLE_ID="com.sunzheng.LaunchIcon"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$(cd /tmp && pwd -P)/LaunchIcon-CodexRun"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

script_instance_pids() {
  /bin/ps ax -o pid= -o command= | /usr/bin/awk -v binary="$APP_BINARY" '$2 == binary { print $1 }'
}

stop_script_instances() {
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done < <(script_instance_pids)
}

stop_script_instances

xcodebuild \
  -project "$ROOT_DIR/LaunchIcon.xcodeproj" \
  -scheme LaunchIconDirect \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  build

open_app() {
  LAUNCHICON_SHOW_ON_LAUNCH=1 /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -o 'settings set target.env-vars LAUNCHICON_SHOW_ON_LAUNCH=1' -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    script_instance_pids | /usr/bin/grep -q .
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

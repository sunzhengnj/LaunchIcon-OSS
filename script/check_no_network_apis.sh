#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATTERN='\b(URLSession|URLRequest|URLProtocol|NWConnection|NWBrowser|NWListener|NWPathMonitor|CFHTTPMessage|CFSocket)\b|import[[:space:]]+(Network|CFNetwork)\b'
SOURCES_DIR="$ROOT_DIR/Sources"

if command -v rg >/dev/null 2>&1; then
  SCAN=(rg --line-number --glob '*.swift' "$PATTERN" "$SOURCES_DIR")
  TOOL=ripgrep
elif command -v grep >/dev/null 2>&1; then
  echo "ripgrep (rg) not found; falling back to grep." >&2
  SCAN=(grep -R -n -E --include='*.swift' "$PATTERN" "$SOURCES_DIR")
  TOOL=grep
else
  echo "Network API scan failed: neither rg nor grep is available." >&2
  exit 127
fi

set +e
matches="$("${SCAN[@]}")"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  printf 'Explicit network API references found in product source:\n%s\n' "$matches" >&2
  exit 1
fi

if [[ "$status" -eq 1 ]]; then
  echo 'No explicit network transport APIs found in Sources/*.swift.'
  echo 'This static guard does not prove zero runtime outbound traffic.'
  exit 0
fi

echo "Network API scan failed with $TOOL status $status." >&2
exit "$status"

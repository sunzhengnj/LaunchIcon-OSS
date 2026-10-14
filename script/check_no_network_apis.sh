#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATTERN='\b(URLSession|URLRequest|URLProtocol|NWConnection|NWBrowser|NWListener|NWPathMonitor|CFHTTPMessage|CFSocket)\b|import[[:space:]]+(Network|CFNetwork)\b'

if command -v rg >/dev/null 2>&1; then
  if matches="$(rg --line-number --glob '*.swift' "$PATTERN" "$ROOT_DIR/Sources")"; then
    printf 'Explicit network API references found in product source:\n%s\n' "$matches" >&2
    exit 1
  else
    status=$?
    if [[ "$status" -ne 1 ]]; then
      echo "Network API scan failed with ripgrep status $status." >&2
      exit "$status"
    fi
  fi
else
  # Hosts without ripgrep (some Macs / CI images): GNU/BSD grep -E fallback.
  matches="$(/usr/bin/grep -R -n -E --include='*.swift' "$PATTERN" "$ROOT_DIR/Sources" || true)"
  if [[ -n "${matches}" ]]; then
    printf 'Explicit network API references found in product source:\n%s\n' "$matches" >&2
    exit 1
  fi
fi

echo 'No explicit network transport APIs found in Sources/*.swift.'
echo 'This static guard does not prove zero runtime outbound traffic.'

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

check() {
  local source="$1" served="$2" hash expected body
  hash="$(sha256 "$source")"
  expected="$(sed -n '2s/.*sha256: \([0-9a-f]*\).*/\1/p' "$served")"
  body="$(mktemp)"
  tail -n +3 "$served" > "$body"
  if [[ "$expected" != "$hash" ]] || ! diff -u "$source" "$body"; then
    echo "design-system drift: $(basename "$served")" >&2
    rm -f "$body"
    return 1
  fi
  rm -f "$body"
}

check dev/design-system/tokens.css packages/dartclaw_server/lib/src/static/tokens.css
check dev/design-system/components.css packages/dartclaw_server/lib/src/static/design-system.css
check dev/design-system/icons.css packages/dartclaw_server/lib/src/static/icons.css

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECK="$ROOT_DIR/dev/tools/fitness/check_css_comment_state.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dartclaw-css-comments-XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

printf '%s\n' ':root { /* valid */ --z-base: 0; }' '.quoted { content: "/* not a comment */"; }' > "$TEMP_DIR/valid.css"
printf '%s\n' ':root { /* malformed' '  --z-base: 0;' '}' > "$TEMP_DIR/malformed.css"
printf '%s\n' ':root { --z-base: 0; } */' > "$TEMP_DIR/unexpected-close.css"

bash "$CHECK" "$TEMP_DIR/valid.css"
if bash "$CHECK" "$TEMP_DIR/malformed.css" 2> "$TEMP_DIR/error.log"; then
  echo "comment-state check accepted an unterminated comment" >&2
  exit 1
fi
grep -q 'comment opened at line 1 is not closed' "$TEMP_DIR/error.log"
if bash "$CHECK" "$TEMP_DIR/unexpected-close.css" 2> "$TEMP_DIR/unexpected-close.log"; then
  echo "comment-state check accepted an unexpected comment close" >&2
  exit 1
fi
grep -q 'unexpected comment close' "$TEMP_DIR/unexpected-close.log"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

check_file() {
  awk '
    function fail(message) {
      print FILENAME ":" FNR ": " message > "/dev/stderr"
      failed = 1
    }

    {
      for (i = 1; i <= length($0); i++) {
        character = substr($0, i, 1)
        pair = substr($0, i, 2)
        if (in_comment) {
          if (pair == "*/") {
            in_comment = 0
            i++
          }
        } else if (quote) {
          if (escaped) {
            escaped = 0
          } else if (character == "\\") {
            escaped = 1
          } else if (character == quote) {
            quote = ""
          }
        } else if (character == "\"" || character == "\047") {
          quote = character
        } else if (pair == "/*") {
          in_comment = 1
          comment_line = FNR
          i++
        } else if (pair == "*/") {
          fail("unexpected comment close")
          i++
        }
      }
      escaped = 0
    }

    END {
      if (in_comment) {
        fail("comment opened at line " comment_line " is not closed")
      }
      exit failed ? 1 : 0
    }
  ' "$1"
}

if (( $# > 0 )); then
  for file in "$@"; do
    check_file "$file"
  done
else
  while IFS= read -r -d '' file; do
    check_file "$file"
  done < <(
    find dev/design-system packages/dartclaw_runtime/lib/src/static \
      -type f -name '*.css' -print0
  )
fi

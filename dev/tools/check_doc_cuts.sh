#!/usr/bin/env bash

# Release gate: fails when the release range removes more than DOC_CUT_LIMIT net
# lines from markdown docs, counted per file so additions elsewhere do not offset
# a cut. A deliberate cut is acknowledged by a `Docs-Cut: <reason>` line in any
# commit message of the range (`git commit --allow-empty -m 'Docs-Cut: ...'`).
# dev/bundle is transient and exempt.
# Usage: bash dev/tools/check_doc_cuts.sh [base]
#   base defaults to the merge-base with main (HEAD^ when HEAD is on main).
# Exit code 0 = within limit or acknowledged, 1 = unacknowledged cut.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

limit="${DOC_CUT_LIMIT:-1000}"
base="${1:-$(git merge-base HEAD main)}"
if [ "$(git rev-parse "$base")" = "$(git rev-parse HEAD)" ]; then
  base="HEAD^"
fi

cut=$(git diff -M --numstat "$base" HEAD -- '*.md' ':!dev/bundle' |
  awk '$1 != "-" && $2 > $1 { n += $2 - $1 } END { print n + 0 }')

if [ "$cut" -le "$limit" ]; then
  echo "Doc cuts: $cut net lines in $base..HEAD (limit $limit)"
elif [ -n "$(git log "$base..HEAD" --grep='^Docs-Cut: ' --format=%h)" ]; then
  echo "Doc cuts: $cut net lines in $base..HEAD (limit $limit), acknowledged by Docs-Cut"
else
  echo "FAIL: $base..HEAD removes $cut net doc lines (limit $limit):" >&2
  git diff -M --numstat "$base" HEAD -- '*.md' ':!dev/bundle' |
    awk '$1 != "-" && $2 > $1 { print $2 - $1, $3 }' | sort -rn | head -10 >&2
  echo "If intended, add a commit with a 'Docs-Cut: <reason>' message line." >&2
  exit 1
fi

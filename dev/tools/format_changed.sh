#!/usr/bin/env bash

# Formats only the Dart files this working tree has touched (staged, unstaged, or
# untracked). Used by the Claude Code Stop hook: a whole-repo `dart format .` costs
# ~10 s per turn and rewrites files other agents sharing the checkout are editing.
# Usage: bash dev/tools/format_changed.sh

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

files=()
while IFS= read -r f; do
  if [ -f "$f" ]; then files+=("$f"); fi
done < <(
  {
    git diff --name-only --diff-filter=ACMR HEAD -- '*.dart'
    git ls-files --others --exclude-standard -- '*.dart'
  } | sort -u
)

if [ ${#files[@]} -eq 0 ]; then exit 0; fi
exec dart format --line-length=120 "${files[@]}"

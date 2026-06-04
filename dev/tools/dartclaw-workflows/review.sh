#!/usr/bin/env bash
# Run review-and-remediate-inline in standalone mode — reviews all changes on
# the current branch (diffed against BASE_BRANCH, default main) with mixed +
# Claude council + architecture review, remediates findings, and runs the
# deterministic verification gate, all in the live checkout (no integration
# branch, no worktree, no merge-back). For a single-methodology PR/branch
# review with worktree isolation, use `run.sh workflow run code-review`.
# Usage: bash dev/tools/dartclaw-workflows/review.sh '<what to review>' [-v BASE_BRANCH=...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -eq 0 ]; then
  echo "Usage: $(basename "$0") '<what to review>' [-v BASE_BRANCH=...]" >&2
  exit 64
fi

TARGET="$1"
shift

exec bash "$SCRIPT_DIR/run.sh" workflow run --standalone --allow-dirty-localpath \
  review-and-remediate-inline -v "TARGET=$TARGET" "$@"

#!/usr/bin/env bash
# Run story-and-implement-inline in standalone mode — runs on the current
# branch in the live checkout (no integration branch, no worktree, no
# merge-back). For the worktree-isolated variant, invoke
# `run.sh workflow run story-and-implement` directly.
# Usage: bash dev/tools/dartclaw-workflows/story.sh <fis-path-or-feature-description>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -eq 0 ]; then
  echo "Usage: $(basename "$0") <fis-path-or-feature-description>" >&2
  exit 64
fi

exec bash "$SCRIPT_DIR/run.sh" workflow run --standalone --allow-dirty-localpath story-and-implement-inline -v "FEATURE=$*"

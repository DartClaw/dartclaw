#!/usr/bin/env bash
# Run implement-prd-inline in standalone mode — runs on the current
# branch in the live checkout (no integration branch, no per-story worktrees,
# no merge-back). MAX_PARALLEL defaults to 1 inside the YAML. For the
# worktree-isolated variant, invoke `run.sh workflow run implement-prd`
# directly.
# Usage: bash dev/tools/dartclaw-workflows/plan.sh <feature-prd-or-plan-path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -eq 0 ]; then
  echo "Usage: $(basename "$0") <requirements-or-plan-path>" >&2
  exit 64
fi

exec bash "$SCRIPT_DIR/run.sh" workflow run --standalone --allow-dirty-localpath implement-prd-inline -v "FEATURE=$*"

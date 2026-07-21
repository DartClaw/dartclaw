#!/usr/bin/env bash
# Run multi-agent-review-inline in standalone mode — parallel Codex (Sol 5.6)
# + Claude Code (Fable 5) andthen:review passes, aggregated, remediated, and
# closed with the deterministic verification gate, all in the live checkout.
# For the multi-lens single-run review, use review.sh.
# Usage: bash dev/tools/dartclaw-workflows/multi-review.sh '<what to review>' [-v ...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -eq 0 ]; then
  echo "Usage: $(basename "$0") '<what to review>' [-v ...]" >&2
  exit 64
fi

TARGET="$1"
shift

exec bash "$SCRIPT_DIR/run.sh" workflow run --standalone --allow-dirty-localpath \
  multi-agent-review-inline -v "TARGET=$TARGET" "$@"

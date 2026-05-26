#!/usr/bin/env bash
# Runs the Dart fitness suite.
# Usage: bash dev/tools/run-fitness.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

exec dart test --reporter expanded packages/dartclaw_testing/test/fitness/

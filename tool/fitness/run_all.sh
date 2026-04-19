#!/usr/bin/env bash
# Runs every architectural fitness function gated by S35.
# Exits non-zero on the first failure so CI surfaces it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

echo "==> fitness: check_no_workflow_private_config"
bash tool/fitness/check_no_workflow_private_config.sh

echo "==> fitness: check_workflow_server_imports"
bash tool/fitness/check_workflow_server_imports.sh

echo "==> fitness: check_task_executor_workflow_refs"
dart run tool/fitness/check_task_executor_workflow_refs.dart \
  --source packages/dartclaw_server/lib/src/task/task_executor.dart \
  --allowlist tool/fitness/task_executor_workflow_allowlist.txt

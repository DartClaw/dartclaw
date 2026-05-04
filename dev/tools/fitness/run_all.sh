#!/usr/bin/env bash
# Runs every architectural fitness function gated by S35.
# Exits non-zero on the first failure so CI surfaces it.
#
# Prerequisites: workspace dependencies must be installed (`dart pub get` from
# the repo root). CI runs `dart pub get` before invoking this script; locally,
# run it manually if you haven't yet.
#
# Working dir: the script resolves the repo root from its own location, so it
# can be invoked from anywhere. The `--source` and `--allowlist` paths handed
# to the Dart check are resolved relative to the repo root.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

echo "==> fitness: check_no_workflow_private_config"
bash dev/tools/fitness/check_no_workflow_private_config.sh

echo "==> fitness: check_workflow_server_imports"
bash dev/tools/fitness/check_workflow_server_imports.sh

echo "==> fitness: check_task_executor_workflow_refs"
dart run dev/tools/fitness/check_task_executor_workflow_refs.dart \
  --source packages/dartclaw_server/lib/src/task/task_executor.dart \
  --allowlist dev/tools/fitness/task_executor_workflow_allowlist.txt

#!/usr/bin/env bash
# Runs every architectural fitness function gated by S35.
# Exits non-zero on the first failure so CI surfaces it.
#
# Prerequisites: workspace dependencies must be installed (`dart pub get` from
# the repo root) and ripgrep (`rg`) must be on PATH. CI installs both before
# invoking this script.
#
# Working dir: the script resolves the repo root from its own location, so it
# can be invoked from anywhere. The `--source` and `--allowlist` paths handed
# to the Dart check are resolved relative to the repo root.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
  echo "fitness suite: missing required command: rg (ripgrep)" >&2
  exit 2
fi

echo "==> fitness: check_no_workflow_private_config"
bash dev/tools/fitness/check_no_workflow_private_config.sh

echo "==> fitness: check_no_framework_coupling"
bash dev/tools/fitness/check_no_framework_coupling.sh

echo "==> fitness: check_no_prose_parsing"
bash dev/tools/fitness/test_check_no_prose_parsing.sh
bash dev/tools/fitness/check_no_prose_parsing.sh

echo "==> fitness: check_css_comment_state"
bash dev/tools/fitness/check_css_comment_state.sh

echo "==> fitness: check_no_external_origins"
bash dev/tools/fitness/check_no_external_origins.sh

echo "==> fitness: check_task_executor_workflow_refs"
bash dev/tools/fitness/test_check_task_executor_workflow_refs.sh
dart run dev/tools/fitness/check_task_executor_workflow_refs.dart \
  --source packages/dartclaw_runtime/lib/src/task/task_executor.dart \
  --allowlist dev/tools/fitness/task_executor_workflow_allowlist.txt \
  --workflow-runner-source packages/dartclaw_runtime/lib/src/task/workflow_one_shot_runner.dart \
  --step-runner-source packages/dartclaw_runtime/lib/src/task/step_turn_runner.dart

echo "==> fitness: config schema drift"
dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check

echo "==> fitness: config reference drift"
bash dev/tools/fitness/test_render_config_reference.sh
bash dev/tools/fitness/check_config_reference_drift.sh

# The Dart suite carries the gates that need the consulted-key allowlist reader,
# which lives in it: no_second_implementation_test.dart is one of them.
echo "==> fitness: Dart fitness suite"
bash dev/tools/run-fitness.sh

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECK="$ROOT_DIR/dev/tools/fitness/check_task_executor_workflow_refs.dart"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dartclaw-workflow-authority-XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

cp "$ROOT_DIR/packages/dartclaw_runtime/lib/src/task/task_executor.dart" "$TEMP_DIR/task_executor.dart"
cp "$ROOT_DIR/packages/dartclaw_runtime/lib/src/task/workflow_one_shot_runner.dart" "$TEMP_DIR/workflow_one_shot_runner.dart"
cp "$ROOT_DIR/packages/dartclaw_runtime/lib/src/task/workflow_one_shot_runner_helpers.dart" "$TEMP_DIR/workflow_one_shot_runner_helpers.dart"
cp "$ROOT_DIR/packages/dartclaw_runtime/lib/src/task/step_turn_runner.dart" "$TEMP_DIR/step_turn_runner.dart"

run_check() {
  dart run "$CHECK" \
    --source "$TEMP_DIR/task_executor.dart" \
    --allowlist "$ROOT_DIR/dev/tools/fitness/task_executor_workflow_allowlist.txt" \
    --workflow-runner-source "$TEMP_DIR/workflow_one_shot_runner.dart" \
    --step-runner-source "$TEMP_DIR/step_turn_runner.dart"
}

run_check >/dev/null

printf '\nWorkflowCliRunner? forbiddenLegacyDriver;\n' >> "$TEMP_DIR/workflow_one_shot_runner_helpers.dart"
if run_check >"$TEMP_DIR/legacy.log" 2>&1; then
  echo "FAIL: workflow authority check accepted WorkflowCliRunner reachability" >&2
  exit 1
fi
rg -q 'WorkflowCliRunner' "$TEMP_DIR/legacy.log"

cp "$ROOT_DIR/packages/dartclaw_runtime/lib/src/task/workflow_one_shot_runner.dart" "$TEMP_DIR/workflow_one_shot_runner.dart"
printf '\nfinal forbiddenProcess = Process.run("false", const []);\n' >> "$TEMP_DIR/step_turn_runner.dart"
if run_check >"$TEMP_DIR/process.log" 2>&1; then
  echo "FAIL: workflow authority check accepted a direct process starter" >&2
  exit 1
fi
rg -q 'Process.run' "$TEMP_DIR/process.log"

echo "OK: workflow authority check rejects legacy CLI and process-starter reachability"

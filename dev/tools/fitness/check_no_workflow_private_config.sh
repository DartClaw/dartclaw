#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

# Workflow-private task-config and context keys (`_workflow*`) are owned by the
# workflow package. They originate in `workflow_task_factory.dart` (where the
# task config map is built), are read/written by sibling files inside the
# executor as steps run, and a small number of keys (notably
# `_workflowNeedsWorktree` and `_workflowMergeResolveEnv`) are intentionally
# persisted in `task.configJson` so server-side task plumbing can branch on
# them. The allowlist below enumerates the currently sanctioned consumer sites.
#
# Adding a new consumer outside this list re-opens the storage boundary closed
# by 0.16.4 S33-S35 (AgentExecution decomposition) and should instead go behind
# a typed accessor (TD-103 tracks moving the two server-side reads —
# workflow_one_shot_runner.dart and task_config_view.dart — behind a typed
# view, slated for 0.16.5 S34).
ALLOWED_FILES=(
  # Source of truth: builds and strips the workflow task-config map.
  'packages/dartclaw_workflow/lib/src/workflow/workflow_task_factory.dart'
  'packages/dartclaw_workflow/lib/src/workflow/workflow_task_config.dart'
  # Workflow execution sites that legitimately read/write workflow keys.
  'packages/dartclaw_workflow/lib/src/workflow/workflow_executor_helpers.dart'
  'packages/dartclaw_workflow/lib/src/workflow/workflow_git_lifecycle.dart'
  'packages/dartclaw_workflow/lib/src/workflow/step_dispatcher.dart'
  'packages/dartclaw_workflow/lib/src/workflow/map_iteration_runner.dart'
  'packages/dartclaw_workflow/lib/src/workflow/map_iteration_dispatcher.dart'
  'packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart'
  # Server-side persisted-key consumers — pending TD-103 follow-up to wrap
  # behind a typed accessor on TaskConfigView (0.16.5 S34).
  'packages/dartclaw_server/lib/src/task/workflow_one_shot_runner.dart'
  'packages/dartclaw_server/lib/src/task/task_config_view.dart'
)

matches="$(rg -n "['\"]_workflow" packages/*/lib 2>/dev/null || true)"
for allowed in "${ALLOWED_FILES[@]}"; do
  matches="$(printf '%s\n' "$matches" | { grep -v "^${allowed}:" || true; })"
done
matches="$(printf '%s' "$matches" | sed '/^$/d')"

if [[ -n "$matches" ]]; then
  echo "Fitness function failed: workflow-private keys (_workflow*) referenced outside the allowlist."
  echo "Allowlist (see header in this script for rationale):"
  for allowed in "${ALLOWED_FILES[@]}"; do
    echo "  ${allowed}"
  done
  echo "Offending references:"
  echo "$matches"
  exit 1
fi

echo "Fitness function passed: no workflow-private key references outside the allowlist."

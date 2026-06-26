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
# Adding a new task-config consumer outside this list re-opens the storage
# boundary closed by 0.16.4 S33-S35 (AgentExecution decomposition) and should
# instead go behind a typed accessor on WorkflowTaskConfig.
#
# Workflow *run-context* keys (read from `WorkflowRun.contextJson`, not
# `Task.configJson` — e.g. `_workflow.approvals`) are a separate concern from
# that storage boundary. They live behind a module-level const + typed accessor
# in their owning module (e.g. `workflowApprovalPolicyFromRun` in
# `workflow_approval_policy.dart`); only that single definition site is
# allowlisted, and every consumer routes through the const/accessor identifier.
#
# TD-103 resolved by 0.16.5 S34 — both server-side reads now route through
# WorkflowTaskConfig (workflowNeedsWorktree constant and readMergeResolveEnv).
ALLOWED_FILES=(
  # Source of truth: builds and strips the workflow task-config map.
  'packages/dartclaw_workflow/lib/src/workflow/workflow_task_factory.dart'
  'packages/dartclaw_workflow/lib/src/workflow/workflow_task_config.dart'
  # Workflow execution sites that legitimately read/write workflow keys.
  'packages/dartclaw_workflow/lib/src/workflow/workflow_executor_helpers.dart'
  'packages/dartclaw_workflow/lib/src/workflow/workflow_executor_node_helpers.dart'
  'packages/dartclaw_workflow/lib/src/workflow/workflow_git_lifecycle.dart'
  'packages/dartclaw_workflow/lib/src/workflow/step_dispatcher.dart'
  'packages/dartclaw_workflow/lib/src/workflow/map_iteration_runner.dart'
  'packages/dartclaw_workflow/lib/src/workflow/map_iteration_dispatcher.dart'
  'packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart'
  # Run-context approval-policy key: a WorkflowRun.contextJson key (not a
  # task-config key) defined here as a module const and consumed only through
  # the typed accessor workflowApprovalPolicyFromRun.
  'packages/dartclaw_workflow/lib/src/workflow/workflow_approval_policy.dart'
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

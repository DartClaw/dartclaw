#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# Workflow-private task-config keys (`_workflow*`) are built and consumed
# exclusively inside the workflow executor, where they live only transiently in
# a step's task-config map before `_stripWorkflowStepConfig` removes them prior
# to persistence (`AgentExecution` / `WorkflowStepExecution` are the durable
# carriers). Any `_workflow*` literal elsewhere in packages/*/lib re-opens the
# storage boundary S33-S35 closed.
ALLOWED_FILE='packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart'

matches="$(rg -n "['\"]_workflow" packages/*/lib 2>/dev/null || true)"
matches="$(printf '%s\n' "$matches" | { grep -v "^${ALLOWED_FILE}:" || true; })"
matches="$(printf '%s' "$matches" | sed '/^$/d')"

if [[ -n "$matches" ]]; then
  echo "Fitness function failed: workflow-private keys (_workflow*) must only be referenced in ${ALLOWED_FILE}."
  echo "Offending references:"
  echo "$matches"
  exit 1
fi

echo "Fitness function passed: no workflow-private key references outside ${ALLOWED_FILE}."

#!/usr/bin/env bash
# Fast deterministic workflow validation.
#
# This profile intentionally avoids live harness/API calls. Use it while
# iterating on workflow YAML policy, output contracts, resolver behavior, step
# outcome semantics, and review aggregation. Run workflow-live only after this
# profile is green.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

if [ ! -d "${REPO_ROOT}/packages/dartclaw_workflow" ]; then
  echo "Error: cannot resolve dartclaw repo root from ${SCRIPT_DIR}" >&2
  exit 1
fi

TESTS=(
  "packages/dartclaw_workflow/test/workflow/built_in_workflow_contracts_test.dart"
  "packages/dartclaw_workflow/test/workflow/workflow_builtin_spec_and_implement_test.dart"
  "packages/dartclaw_workflow/test/workflow/workflow_builtin_plan_and_implement_test.dart"
  "packages/dartclaw_workflow/test/workflow/workflow_builtin_code_review_test.dart"
  "packages/dartclaw_workflow/test/workflow/context_extractor_test.dart"
  "packages/dartclaw_workflow/test/workflow/aggregate_step_runner_test.dart"
  "packages/dartclaw_workflow/test/workflow/step_dispatcher_test.dart"
  "packages/dartclaw_workflow/test/workflow/executor_step_outcome_test.dart"
  "packages/dartclaw_workflow/test/workflow/story_spec_output_validator_test.dart"
  "packages/dartclaw_workflow/test/workflow/workflow_e2e_preconditions_test.dart"
)

cd "${REPO_ROOT}"

echo "Running workflow contract validation..."
printf '  %s\n' "${TESTS[@]}"

dart test --reporter=failures-only "${TESTS[@]}" "$@"

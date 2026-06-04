#!/usr/bin/env bash
# Live workflow integration runner.
#
# Encodes the explicit integration-tagged files and --run-skipped requirement.
# The workspace root has no default test/ directory, so plain `dart test -t
# integration` is not a valid full live workflow gate for this repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

if [ ! -d "${REPO_ROOT}/packages/dartclaw_workflow" ]; then
  echo "Error: cannot resolve dartclaw repo root from ${SCRIPT_DIR}" >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage:
  bash dev/testing/profiles/workflow-live/run.sh --canary <name> [-- <dart test args...>]
  bash dev/testing/profiles/workflow-live/run.sh --full [-- <dart test args...>]
  bash dev/testing/profiles/workflow-live/run.sh --list

Canaries:
  core                 Real core bridge protocol smoke.
  step-isolation       Live workflow step/output contract probes.
  spec-and-implement   Single spec workflow E2E.
  plan-and-implement   Multi-story plan workflow E2E.
  merge-resolve        Live merge-resolve conflict workflow.
  server               Server integration files.
  cli                  CLI live integration files.

Environment:
  DARTCLAW_TEST_LOG_DIR   Log directory. Defaults to .agent_temp/.
  DARTCLAW_TEST_PROVIDER  Provider preset for workflow E2E fixtures.
EOF
}

FULL_FILES=(
  "packages/dartclaw_core/test/integration/direct_bridge_test.dart"
  "packages/dartclaw_workflow/test/workflow/workflow_step_isolation_test.dart"
  "packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart"
  "packages/dartclaw_workflow/test/workflow/merge_resolve_integration_test.dart"
  "packages/dartclaw_server/test/integration/crash_recovery_smoke_test.dart"
  "packages/dartclaw_server/test/integration/turn_governance_integration_test.dart"
  "packages/dartclaw_server/test/integration/thread_binding_lifecycle_integration_test.dart"
  "apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart"
  "apps/dartclaw_cli/test/commands/reload_trigger_service_sigusr1_test.dart"
)

FILES=()
NAME_FILTER=""
MODE=""
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --full)
      MODE="full"
      shift
      ;;
    --canary)
      if [ $# -lt 2 ]; then
        echo "Error: --canary requires a name" >&2
        usage >&2
        exit 2
      fi
      MODE="canary"
      CANARY="$2"
      shift 2
      ;;
    --list)
      usage
      exit 0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_ARGS=("$@")
      break
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "${MODE}" ]; then
  echo "Error: choose --canary <name> or --full" >&2
  usage >&2
  exit 2
fi

case "${MODE}:${CANARY:-}" in
  full:)
    FILES=("${FULL_FILES[@]}")
    LOG_LABEL="full"
    ;;
  canary:core)
    FILES=("packages/dartclaw_core/test/integration/direct_bridge_test.dart")
    LOG_LABEL="canary-core"
    ;;
  canary:step-isolation)
    FILES=("packages/dartclaw_workflow/test/workflow/workflow_step_isolation_test.dart")
    LOG_LABEL="canary-step-isolation"
    ;;
  canary:spec-and-implement)
    FILES=("packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart")
    NAME_FILTER="spec-and-implement e2e"
    LOG_LABEL="canary-spec-and-implement"
    ;;
  canary:plan-and-implement)
    FILES=("packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart")
    NAME_FILTER="plan-and-implement e2e"
    LOG_LABEL="canary-plan-and-implement"
    ;;
  canary:merge-resolve)
    FILES=("packages/dartclaw_workflow/test/workflow/merge_resolve_integration_test.dart")
    LOG_LABEL="canary-merge-resolve"
    ;;
  canary:server)
    FILES=(
      "packages/dartclaw_server/test/integration/crash_recovery_smoke_test.dart"
      "packages/dartclaw_server/test/integration/turn_governance_integration_test.dart"
      "packages/dartclaw_server/test/integration/thread_binding_lifecycle_integration_test.dart"
    )
    LOG_LABEL="canary-server"
    ;;
  canary:cli)
    FILES=(
      "apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart"
      "apps/dartclaw_cli/test/commands/reload_trigger_service_sigusr1_test.dart"
    )
    LOG_LABEL="canary-cli"
    ;;
  canary:*)
    echo "Error: unknown canary: ${CANARY}" >&2
    usage >&2
    exit 2
    ;;
esac

LOG_DIR="${DARTCLAW_TEST_LOG_DIR:-${REPO_ROOT}/.agent_temp}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/workflow-live-${LOG_LABEL}-$(date '+%Y%m%d-%H%M%S').log"

cd "${REPO_ROOT}"

CMD=(dart test --run-skipped -j 1 --reporter=expanded -t integration)
CMD+=("${FILES[@]}")
if [ -n "${NAME_FILTER}" ]; then
  CMD+=(--name "${NAME_FILTER}")
fi
if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
  CMD+=("${EXTRA_ARGS[@]}")
fi

echo "Running live workflow integration (${LOG_LABEL})..."
echo "Log: ${LOG_FILE}"
printf 'Command:'
printf ' %q' "${CMD[@]}"
printf '\n'

set +e
set -o pipefail
"${CMD[@]}" 2>&1 | tee "${LOG_FILE}"
STATUS=$?
set +o pipefail
set -e

summarize_log() {
  local warning_count cleanup_count large_token_count
  warning_count="$(grep -c 'WARNING:' "${LOG_FILE}" || true)"
  cleanup_count="$(grep -Ec 'not a working tree|branch .* not found' "${LOG_FILE}" || true)"
  large_token_count="$(grep -Ec 'turn [0-9]+ completed \(\+[0-9]{7,} tokens' "${LOG_FILE}" || true)"

  echo
  echo "Live integration log summary:"
  echo "  warnings: ${warning_count}"
  echo "  cleanup warnings: ${cleanup_count}"
  echo "  large token-count lines: ${large_token_count}"

  if [ "${warning_count}" != "0" ]; then
    echo
    echo "Warning excerpts:"
    grep -n 'WARNING:' "${LOG_FILE}" | head -n 30 || true
  fi

  if [ "${cleanup_count}" != "0" ]; then
    echo
    echo "Cleanup warning excerpts:"
    grep -En 'not a working tree|branch .* not found' "${LOG_FILE}" | head -n 30 || true
  fi

  if [ "${large_token_count}" != "0" ]; then
    echo
    echo "Large token-count excerpts:"
    grep -En 'turn [0-9]+ completed \(\+[0-9]{7,} tokens' "${LOG_FILE}" | head -n 30 || true
  fi

  echo
  grep -E 'All tests passed|Some tests failed|No tests ran' "${LOG_FILE}" | tail -n 5 || true
}

summarize_log

exit "${STATUS}"

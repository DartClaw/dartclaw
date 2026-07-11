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
  bash dev/testing/profiles/workflow-live/run.sh --full [--skip-e2e] [-- <dart test args...>]
  bash dev/testing/profiles/workflow-live/run.sh --e2e [-- <dart test args...>]
  bash dev/testing/profiles/workflow-live/run.sh --list

Modes:
  --full               Full live sweep. Add --skip-e2e to exclude the heavy
                       multi-minute real-provider agent e2e (tag: live-e2e),
                       keeping the fast integration tests as a quick gate.
  --e2e                Run only the heavy real-provider agent e2e
                       (spec-and-implement + plan-and-implement, tag: live-e2e).
  --canary <name>      Single targeted canary (see below).
  --skip-preflight     Skip the fail-fast provider preflight (version, codex
                       bundled-tool quarantine check, one pinned-model
                       round-trip). Combines with any execute mode.

Canaries:
  core                 Real core bridge protocol smoke.
  step-isolation       Live workflow step/output contract probes.
  spec-and-implement   Single spec workflow E2E.
  plan-and-implement   Multi-story plan workflow E2E.
  merge-resolve        Live merge-resolve conflict workflow.
  server               Server integration files.
  cli                  CLI live integration files.

Environment:
  DARTCLAW_TEST_LOG_DIR         Log directory. Defaults to .agent_temp/.
  DARTCLAW_TEST_PROVIDER        Provider preset for workflow E2E fixtures.
  DARTCLAW_TEST_EXECUTOR_MODEL  Pins the executor model used by the preflight
                                round-trip and the hermetic codex config.toml.
                                Defaults to the E2EFixture preset.

For codex runs this script writes a hermetic CODEX_HOME under the log dir
(auth.json seeded from the operator's ~/.codex, config.toml pinning the executor
model) and exports it, so operator dotfiles cannot override fixture models in
spawns that omit --model (skill-introspection probes, direct executeTurn calls).
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
SKIP_E2E=0
SKIP_PREFLIGHT=0
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --full)
      MODE="full"
      shift
      ;;
    --e2e)
      MODE="e2e"
      shift
      ;;
    --skip-e2e)
      SKIP_E2E=1
      shift
      ;;
    --skip-preflight)
      SKIP_PREFLIGHT=1
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
  echo "Error: choose --canary <name>, --full, or --e2e" >&2
  usage >&2
  exit 2
fi

if [ "${SKIP_E2E}" -eq 1 ] && [ "${MODE}" = "e2e" ]; then
  echo "Error: --skip-e2e cannot be combined with --e2e (it would exclude every selected test)" >&2
  exit 2
fi

case "${MODE}:${CANARY:-}" in
  full:)
    FILES=("${FULL_FILES[@]}")
    LOG_LABEL="full"
    ;;
  e2e:)
    FILES=("packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart")
    LOG_LABEL="e2e"
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

# Provider is the fixture default (codex / gpt-5.3-codex-spark) unless overridden.
# Opt into Claude Sonnet with DARTCLAW_TEST_PROVIDER=claude. The codex `-mini`
# executor/reviewer measured a regression on these pipelines (~5-8x slower, ~100x
# tokens/review), so the default stays on spark.

# Executor-model defaults mirror the E2EFixture presets in
# packages/dartclaw_workflow/test/fixtures/e2e_fixture.dart — keep them in sync so
# the preflight round-trip and the hermetic codex config.toml pin the same model
# the tests resolve to.
PROVIDER="${DARTCLAW_TEST_PROVIDER:-codex}"
case "${PROVIDER}" in
  codex) EXECUTOR_MODEL="${DARTCLAW_TEST_EXECUTOR_MODEL:-gpt-5.3-codex-spark}" ;;
  claude) EXECUTOR_MODEL="${DARTCLAW_TEST_EXECUTOR_MODEL:-claude-sonnet-4-6}" ;;
  *) EXECUTOR_MODEL="${DARTCLAW_TEST_EXECUTOR_MODEL:-}" ;;
esac

LOG_DIR="${DARTCLAW_TEST_LOG_DIR:-${REPO_ROOT}/.agent_temp}"
mkdir -p "${LOG_DIR}"

# Hermetic CODEX_HOME (codex only). Operator dotfiles (~/.codex/config.toml
# model/effort overrides) must not leak into codex spawns that don't pass
# --model — skill-introspection probes and direct executeTurn calls fall back to
# CODEX_HOME/config.toml otherwise. Seed auth from the operator home, pin the
# executor model, and export so it reaches `dart test` → Platform.environment →
# the sanitized spawn passthrough.
if [ "${PROVIDER}" = "codex" ]; then
  SEED_CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
  if [ ! -f "${SEED_CODEX_HOME}/auth.json" ]; then
    echo "Error: no codex auth.json at ${SEED_CODEX_HOME}/auth.json — run \`codex login\` first." >&2
    exit 1
  fi
  CODEX_HOME_DIR="${LOG_DIR}/codex-home"
  rm -rf "${CODEX_HOME_DIR}"
  mkdir -p "${CODEX_HOME_DIR}"
  chmod 700 "${CODEX_HOME_DIR}"
  cp "${SEED_CODEX_HOME}/auth.json" "${CODEX_HOME_DIR}/auth.json"
  printf 'model = "%s"\n' "${EXECUTOR_MODEL}" >"${CODEX_HOME_DIR}/config.toml"
  export CODEX_HOME="${CODEX_HOME_DIR}"
fi
LOG_FILE="${LOG_DIR}/workflow-live-${LOG_LABEL}-$(date '+%Y%m%d-%H%M%S').log"

cd "${REPO_ROOT}"

# Portable ~N-second wall-clock cap: macOS has no coreutils `timeout`. Background
# the command, poll for exit, kill on expiry. Combined output goes to $2. Returns
# the command's exit code, or 124 on timeout.
run_with_timeout() {
  local timeout_secs="$1" output_file="$2"
  shift 2
  "$@" >"${output_file}" 2>&1 &
  local cmd_pid=$! waited=0
  while kill -0 "${cmd_pid}" 2>/dev/null; do
    if [ "${waited}" -ge "${timeout_secs}" ]; then
      kill "${cmd_pid}" 2>/dev/null || true
      wait "${cmd_pid}" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  local rc=0
  wait "${cmd_pid}" || rc=$?
  return "${rc}"
}

# Fail-fast provider preflight: prove the CLI runs and the pinned executor model
# actually round-trips before spending real tokens on `dart test`.
run_preflight() {
  local exe login_hint
  case "${PROVIDER}" in
    codex)
      exe="codex"
      login_hint="run \`codex login\`"
      ;;
    claude)
      exe="claude"
      login_hint="run \`claude login\`"
      ;;
    *)
      echo "Preflight: no preflight available for provider '${PROVIDER}', skipping."
      return 0
      ;;
  esac

  if ! command -v "${exe}" >/dev/null 2>&1; then
    echo "Preflight: '${exe}' not found on PATH — install it and log in (${login_hint})." >&2
    exit 1
  fi

  local version_output
  version_output="$("${exe}" --version 2>&1)" || {
    echo "Preflight: '${exe} --version' exited non-zero:" >&2
    echo "${version_output}" >&2
    exit 1
  }

  # Codex bundles unsigned tools (e.g. `rg`) next to the real binary; brew cask
  # upgrades can re-quarantine them, silently breaking agent turns.
  if [ "${PROVIDER}" = "codex" ]; then
    local resolved tool_dir tool
    resolved="$(readlink -f "$(command -v codex)" 2>/dev/null || command -v codex)"
    tool_dir="$(dirname "${resolved}")/../codex-path"
    if [ -d "${tool_dir}" ]; then
      for tool in "${tool_dir}"/*; do
        [ -f "${tool}" ] || continue
        if [ ! -x "${tool}" ]; then
          echo "Preflight: bundled codex tool is not executable: ${tool}" >&2
          echo "  Fix: chmod +x '${tool}' or 'brew reinstall --cask codex --no-quarantine'." >&2
          exit 1
        fi
        if [ "$(uname)" = "Darwin" ] && xattr -p com.apple.quarantine "${tool}" >/dev/null 2>&1; then
          echo "Preflight: bundled codex tool is quarantined: ${tool}" >&2
          echo "  Fix: xattr -d com.apple.quarantine '${tool}' or 'brew reinstall --cask codex --no-quarantine'." >&2
          exit 1
        fi
      done
    fi
  fi

  # One trivial one-shot round-trip on the pinned executor model. Codex reads the
  # already-exported hermetic CODEX_HOME.
  local preflight_log cmd rc=0
  preflight_log="${LOG_DIR}/workflow-live-preflight-${LOG_LABEL}-$(date '+%Y%m%d-%H%M%S').log"
  if [ "${PROVIDER}" = "codex" ]; then
    cmd="codex exec --json --skip-git-repo-check --ephemeral --sandbox read-only -c approval_policy=\"never\" --model \"${EXECUTOR_MODEL}\" 'Reply with exactly: OK'"
    run_with_timeout 120 "${preflight_log}" \
      codex exec --json --skip-git-repo-check --ephemeral --sandbox read-only \
      -c approval_policy="never" --model "${EXECUTOR_MODEL}" 'Reply with exactly: OK' || rc=$?
  else
    cmd="claude -p --model \"${EXECUTOR_MODEL}\" 'Reply with exactly: OK'"
    run_with_timeout 120 "${preflight_log}" \
      claude -p --model "${EXECUTOR_MODEL}" 'Reply with exactly: OK' || rc=$?
  fi

  if [ "${rc}" -ne 0 ]; then
    echo >&2
    echo "Preflight round-trip FAILED." >&2
    echo "  Command: ${cmd}" >&2
    if [ "${rc}" -eq 124 ]; then
      echo "  Result: timed out after 120s" >&2
    else
      echo "  Result: exit code ${rc}" >&2
    fi
    echo "  Log: ${preflight_log}" >&2
    echo "  Last output:" >&2
    tail -n 20 "${preflight_log}" 2>/dev/null | sed 's/^/    /' >&2 || true
    echo "  Likely causes:" >&2
    echo "    - provider not logged in (${login_hint})" >&2
    echo "    - configured model not supported by the installed CLI — upgrade the CLI or set DARTCLAW_TEST_EXECUTOR_MODEL" >&2
    if [ "${PROVIDER}" = "codex" ]; then
      echo "    - quarantined bundled tools (xattr -d com.apple.quarantine <path>)" >&2
    fi
    exit 1
  fi

  echo "Preflight OK: ${version_output}, model ${EXECUTOR_MODEL} round-trip passed."
}

if [ "${SKIP_PREFLIGHT}" -eq 0 ]; then
  run_preflight
else
  echo "Skipping provider preflight (--skip-preflight)."
fi

CMD=(dart test --run-skipped -j 1 --reporter=expanded)
if [ "${MODE}" = "e2e" ]; then
  CMD+=(-t live-e2e)
else
  CMD+=(-t integration)
fi
if [ "${SKIP_E2E}" -eq 1 ]; then
  CMD+=(-x live-e2e)
fi
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

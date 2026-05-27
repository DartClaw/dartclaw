#!/usr/bin/env bash
# Start DartClaw with the workflows testing profile.
#
# Server mode (default):
#   bash dev/testing/profiles/workflows/run.sh [extra serve args...]
#   bash dev/testing/profiles/workflows/run.sh --port 4000
#
# CLI commands:
#   bash dev/testing/profiles/workflows/run.sh workflow list
#   bash dev/testing/profiles/workflows/run.sh workflow run plan-and-implement -v 'REQUIREMENTS=...'
#   bash dev/testing/profiles/workflows/run.sh workflow status <run-id>
#   bash dev/testing/profiles/workflows/run.sh workflow validate <file.yaml>
#   bash dev/testing/profiles/workflows/run.sh tasks show <task-id> --json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEED_DIR="${SCRIPT_DIR}/data"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

if [ ! -d "${REPO_ROOT}/apps/dartclaw_cli" ]; then
  echo "Error: cannot resolve dartclaw repo root from ${SCRIPT_DIR}" >&2
  exit 1
fi

# The workflows profile keeps state across runs by default (sessions, tasks,
# the workflow fixture checkout under data/projects/, etc.). Override with
# DARTCLAW_WORKFLOWS_DATA_DIR to redirect to a fresh location.
if [ -n "${DARTCLAW_WORKFLOWS_DATA_DIR:-}" ]; then
  DATA_DIR="${DARTCLAW_WORKFLOWS_DATA_DIR}"
  mkdir -p "${DATA_DIR}"
  if [ ! -e "${DATA_DIR}/dartclaw.yaml" ]; then
    cp -R "${SEED_DIR}/." "${DATA_DIR}/"
  fi
else
  DATA_DIR="${SEED_DIR}"
fi

DATA_DIR_ABS="$(cd "${DATA_DIR}" && pwd)"
TEMPLATE_CONFIG="${DATA_DIR_ABS}/dartclaw.yaml"
RUNTIME_CONFIG="${DATA_DIR_ABS}/.workflows.runtime.yaml"

# Substitute placeholders into a runtime YAML so we don't dirty the tracked
# template. __WORKFLOW_WORKSPACE_DIR__ is only substituted when the profile
# ships a seed workflow-workspace/ directory; otherwise the runtime
# auto-materializes the built-in workspace under <dataDir>/workflow-workspace/.
escape_sed() {
  local val="$1"
  val=${val//\\/\\\\}
  val=${val//&/\\&}
  val=${val//|/\\|}
  printf '%s\n' "$val"
}

if [ -d "${DATA_DIR_ABS}/workflow-workspace" ]; then
  WORKFLOW_WORKSPACE_DIR_ABS="$(cd "${DATA_DIR_ABS}/workflow-workspace" && pwd)"
  sed -e "s|__WORKFLOW_WORKSPACE_DIR__|$(escape_sed "${WORKFLOW_WORKSPACE_DIR_ABS}")|g" \
      -e "s|__DATA_DIR__|$(escape_sed "${DATA_DIR_ABS}")|g" \
      "${TEMPLATE_CONFIG}" > "${RUNTIME_CONFIG}"
else
  sed -e "s|__DATA_DIR__|$(escape_sed "${DATA_DIR_ABS}")|g" \
      "${TEMPLATE_CONFIG}" > "${RUNTIME_CONFIG}"
fi

# Export GITHUB_TOKEN from the fixture-local askpass file if not already set.
if [ -z "${GITHUB_TOKEN:-}" ] && [ -f "${DATA_DIR_ABS}/projects/.git-askpass-github-main.token" ]; then
  GITHUB_TOKEN_VALUE="$(tr -d '\r\n' < "${DATA_DIR_ABS}/projects/.git-askpass-github-main.token")"
  if [ -n "${GITHUB_TOKEN_VALUE}" ]; then
    export GITHUB_TOKEN="${GITHUB_TOKEN_VALUE}"
  fi
fi

chmod 600 "${DATA_DIR_ABS}/gateway_token" 2>/dev/null || true

resolve_snapshot() {
  local sdk_version snapshot
  sdk_version="$(dart --version 2>&1 | sed -n 's/^Dart SDK version: \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
  if [ -n "${sdk_version}" ]; then
    snapshot="${REPO_ROOT}/.dart_tool/pub/bin/dartclaw_cli/dartclaw.dart-${sdk_version}.snapshot"
    if [ -f "${snapshot}" ]; then
      printf '%s\n' "${snapshot}"
      return 0
    fi
  fi
  snapshot="$(ls -1t "${REPO_ROOT}/.dart_tool/pub/bin/dartclaw_cli/dartclaw.dart-"*.snapshot 2>/dev/null | head -n 1 || true)"
  if [ -n "${snapshot}" ]; then
    printf '%s\n' "${snapshot}"
  fi
}

cd "${REPO_ROOT}"

run_cli() {
  if [ "${DARTCLAW_TEST_USE_SNAPSHOT:-0}" = "1" ]; then
    local snapshot
    snapshot="$(resolve_snapshot)"
    if [ -n "${snapshot}" ]; then
      exec dart "${snapshot}" --config "${RUNTIME_CONFIG}" "$@"
    fi
  fi

  if printf '%s\n' "$*" | grep -q -- ' --json\|^--json\| --json$\|^--json$'; then
    dart run dartclaw_cli:dartclaw --config "${RUNTIME_CONFIG}" "$@" | awk '
      BEGIN { started = 0 }
      {
        if (!started) {
          gsub(/Running build hooks\.\.\./, "")
          if (length($0) == 0) {
            next
          }
          started = 1
        }
        print
        fflush()
      }
    '
  else
    exec dart run dartclaw_cli:dartclaw --config "${RUNTIME_CONFIG}" "$@"
  fi
}

if [ $# -eq 0 ]; then
  if [ "${DARTCLAW_TEST_USE_SNAPSHOT:-0}" = "1" ]; then
    SNAPSHOT="$(resolve_snapshot)"
    if [ -n "${SNAPSHOT}" ]; then
      exec dart "${SNAPSHOT}" --config "${RUNTIME_CONFIG}" serve --dev --data-dir "${DATA_DIR_ABS}"
    fi
  fi
  exec dart run dartclaw_cli:dartclaw --config "${RUNTIME_CONFIG}" serve --dev --data-dir "${DATA_DIR_ABS}"
fi

case "${1:-}" in
  -*)
    if [ "${DARTCLAW_TEST_USE_SNAPSHOT:-0}" = "1" ]; then
      SNAPSHOT="$(resolve_snapshot)"
      if [ -n "${SNAPSHOT}" ]; then
        exec dart "${SNAPSHOT}" --config "${RUNTIME_CONFIG}" serve --dev --data-dir "${DATA_DIR_ABS}" "$@"
      fi
    fi
    exec dart run dartclaw_cli:dartclaw --config "${RUNTIME_CONFIG}" serve --dev --data-dir "${DATA_DIR_ABS}" "$@"
    ;;
  workflow)
    shift
    run_cli workflow "$@"
    ;;
  *)
    run_cli "$@"
    ;;
esac

#!/usr/bin/env bash
# Start DartClaw with the plain testing profile (no channels, seeded data).
# Used by dev/testing/UI-SMOKE-TEST.md and scenario files under
# dev/testing/scenarios/ that declare `profile: plain`.
#
# Usage: bash dev/testing/profiles/plain/run.sh [extra args...]
# Example: bash dev/testing/profiles/plain/run.sh --port 4000

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../postgres.sh"
SEED_DIR="${SCRIPT_DIR}/data"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

if [ ! -d "${REPO_ROOT}/apps/dartclaw_cli" ]; then
  echo "Error: cannot resolve dartclaw repo root from ${SCRIPT_DIR}" >&2
  exit 1
fi

# Run against a writable copy of the seeded data so the runtime's session /
# message / db writes don't dirty the tracked seed files. Override with
# DARTCLAW_PLAIN_DATA_DIR=<path> to debug persistent state across runs.
if [ -n "${DARTCLAW_PLAIN_DATA_DIR:-}" ]; then
  DATA_DIR="${DARTCLAW_PLAIN_DATA_DIR}"
  mkdir -p "${DATA_DIR}"
  if [ ! -e "${DATA_DIR}/dartclaw.yaml" ]; then
    cp -R "${SEED_DIR}/." "${DATA_DIR}/"
  fi
  trap profile_postgres_stop EXIT
else
  # The data dir is the server's cwd, and the runtime names its implicit local
  # project after it — so the unique part goes on the parent and the dir itself
  # keeps a readable fixed name.
  DATA_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/dartclaw-plain-XXXXXX")"
  trap 'profile_postgres_stop; rm -rf "${DATA_PARENT}"' EXIT
  DATA_DIR="${DATA_PARENT}/dartclaw-plain"
  mkdir -p "${DATA_DIR}"
  cp -R "${SEED_DIR}/." "${DATA_DIR}/"
fi

CONFIG="${DATA_DIR}/dartclaw.yaml"
chmod 600 "${DATA_DIR}/gateway_token" 2>/dev/null || true
profile_postgres_start

cd "${DATA_DIR}"

if [ "${DARTCLAW_TEST_USE_SNAPSHOT:-0}" = "1" ]; then
  SDK_VERSION="$(dart --version 2>&1 | sed -n 's/^Dart SDK version: \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
  SNAPSHOT="${REPO_ROOT}/.dart_tool/pub/bin/dartclaw_cli/dartclaw.dart-${SDK_VERSION}.snapshot"
  if [ ! -f "${SNAPSHOT}" ]; then
    SNAPSHOT="$(ls -1t "${REPO_ROOT}/.dart_tool/pub/bin/dartclaw_cli/dartclaw.dart-"*.snapshot 2>/dev/null | head -n 1 || true)"
  fi
  # No exec anywhere below: the EXIT trap has to survive the server, or the
  # temp parent outlives every run.
  if [ -n "${SNAPSHOT}" ] && [ -f "${SNAPSHOT}" ]; then
    dart "${SNAPSHOT}" --config "${CONFIG}" serve --dev --data-dir "${DATA_DIR}" --source-dir "${REPO_ROOT}" "$@"
    exit $?
  fi
fi

# Generated asset libraries are gitignored; emit them before running from source.
dart run "${REPO_ROOT}/dev/tools/embed_assets.dart" >/dev/null

dart \
  --packages="${REPO_ROOT}/.dart_tool/package_config.json" \
  "${REPO_ROOT}/apps/dartclaw_cli/bin/dartclaw.dart" \
  --config "${CONFIG}" serve --dev --data-dir "${DATA_DIR}" --source-dir "${REPO_ROOT}" "$@"

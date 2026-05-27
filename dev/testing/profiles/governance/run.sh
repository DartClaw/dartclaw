#!/usr/bin/env bash
# Start DartClaw with the governance testing profile.
# Tight governance limits for integration/scenario testing.
#
# Usage: bash dev/testing/profiles/governance/run.sh [extra args...]
# Example: bash dev/testing/profiles/governance/run.sh --port 4000

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEED_DIR="${SCRIPT_DIR}/data"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

if [ ! -d "${REPO_ROOT}/apps/dartclaw_cli" ]; then
  echo "Error: cannot resolve dartclaw repo root from ${SCRIPT_DIR}" >&2
  exit 1
fi

# Run against a writable copy of the seeded data so the runtime's session /
# message / db writes don't dirty the tracked seed files. Override with
# DARTCLAW_GOVERNANCE_DATA_DIR=<path> to debug persistent state across runs.
if [ -n "${DARTCLAW_GOVERNANCE_DATA_DIR:-}" ]; then
  DATA_DIR="${DARTCLAW_GOVERNANCE_DATA_DIR}"
  mkdir -p "${DATA_DIR}"
  if [ ! -e "${DATA_DIR}/dartclaw.yaml" ]; then
    cp -R "${SEED_DIR}/." "${DATA_DIR}/"
  fi
else
  DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dartclaw-governance-XXXXXX")"
  trap 'rm -rf "${DATA_DIR}"' EXIT
  cp -R "${SEED_DIR}/." "${DATA_DIR}/"
fi

CONFIG="${DATA_DIR}/dartclaw.yaml"
KV_FILE="${DATA_DIR}/kv.json"
chmod 600 "${DATA_DIR}/gateway_token" 2>/dev/null || true

# Seed the current UTC day near the 80% warning threshold so the governance
# scenario can deterministically trigger a budget warning on the next turn.
python3 - <<'PY' "$KV_FILE"
from datetime import datetime, timezone
import json
import sys
from pathlib import Path

kv_path = Path(sys.argv[1])
now = datetime.now(timezone.utc)
date_key = f"usage_daily:{now.strftime('%Y-%m-%d')}"
payload = {
    date_key: {
        "value": json.dumps({
            "total_input_tokens": 4000,
            "total_output_tokens": 4000,
            "by_agent": {"main": {"input": 4000, "output": 4000, "turns": 1}},
        }),
        "updatedAt": now.isoformat().replace("+00:00", "Z"),
    }
}
kv_path.write_text(json.dumps(payload))
PY

cd "${DATA_DIR}"

if [ "${DARTCLAW_TEST_USE_SNAPSHOT:-0}" = "1" ]; then
  SDK_VERSION="$(dart --version 2>&1 | sed -n 's/^Dart SDK version: \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
  SNAPSHOT="${REPO_ROOT}/.dart_tool/pub/bin/dartclaw_cli/dartclaw.dart-${SDK_VERSION}.snapshot"
  if [ ! -f "${SNAPSHOT}" ]; then
    SNAPSHOT="$(ls -1t "${REPO_ROOT}/.dart_tool/pub/bin/dartclaw_cli/dartclaw.dart-"*.snapshot 2>/dev/null | head -n 1 || true)"
  fi
  if [ -n "${SNAPSHOT}" ] && [ -f "${SNAPSHOT}" ]; then
    exec dart "${SNAPSHOT}" --config "${CONFIG}" serve --dev --data-dir "${DATA_DIR}" --source-dir "${REPO_ROOT}" "$@"
  fi
fi

exec dart \
  --packages="${REPO_ROOT}/.dart_tool/package_config.json" \
  "${REPO_ROOT}/apps/dartclaw_cli/bin/dartclaw.dart" \
  --config "${CONFIG}" serve --dev --data-dir "${DATA_DIR}" --source-dir "${REPO_ROOT}" "$@"

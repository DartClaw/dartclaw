#!/usr/bin/env bash
# Proves container isolation end to end: a real agent turn runs inside a
# container, the container holds no provider credential, and a task tool is
# served to it over the MCP bridge.
#
# Usage: bash dev/testing/profiles/container/run.sh [--ci]
#
# Default (local) mode skips (exit 0) when no container runtime answers; never
# fails for that reason. Requires a container runtime, curl, dart, python3, and
# either a stored Claude subscription credential (`dartclaw auth claude`, with
# DARTCLAW_CONTAINER_DATA_DIR pointing at that data dir) or ANTHROPIC_API_KEY.
#
# `--ci` is the mode CI runs. It differs in three ways, each deliberate:
#   - an absent container runtime is a FAILURE, not a skip — on a runner the
#     advisory downgrade is the thing being guarded against, so it must never
#     read as a pass;
#   - the config declares no `container:` section, so the posture is *inferred*.
#     Asserting a declared `true` would prove only that an explicit request is
#     honoured, and would fail closed instead of downgrading on a runtime-free
#     runner — hiding the case the job exists to catch;
#   - it issues no model turn and reads no provider credential, so it runs on a
#     fork PR with no repository secret.

set -euo pipefail

CI_MODE=""
case "${1:-}" in
  --ci) CI_MODE=1 ;;
  "") ;;
  *) echo "usage: $0 [--ci]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEED_DIR="${SCRIPT_DIR}/data"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
if [ -n "$CI_MODE" ]; then
  CONFIG_NAME="dartclaw.ci.yaml"
  PORT=3342
else
  CONFIG_NAME="dartclaw.yaml"
  PORT=3341
fi

RUNTIME=""
for candidate in docker podman; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" version >/dev/null 2>&1; then
    RUNTIME="$candidate"
    break
  fi
done

if [ -z "$RUNTIME" ]; then
  if [ -n "$CI_MODE" ]; then
    echo "FAIL: no container runtime (docker or podman) answered a version probe." >&2
    echo "The container job proves the boundary; a runner without a runtime cannot prove it," >&2
    echo "and the server's advisory downgrade would exit zero and read as a pass." >&2
    exit 1
  fi
  echo "SKIP: no container runtime (docker or podman) answered a version probe."
  exit 0
fi

# A containerized Claude turn is host-mediated: the host presents the credential
# and the container never holds one, so the vendor CLI's own interactive login
# is not usable here however healthy `claude auth status` looks. Two host-held
# credentials are presentable, and ADR-053 makes the subscription the default of
# the two: a stored `setup-token` this instance's data dir carries, written by
# `dartclaw auth claude`, or an `ANTHROPIC_API_KEY`. Point
# DARTCLAW_CONTAINER_DATA_DIR at a data dir holding the former to run this on a
# subscription; the default fresh temp dir holds neither.
if [ -z "$CI_MODE" ]; then
  STORED_TOKEN=""
  if [ -n "${DARTCLAW_CONTAINER_DATA_DIR:-}" ] &&
    [ -f "${DARTCLAW_CONTAINER_DATA_DIR}/credentials/claude/setup-token.json" ]; then
    STORED_TOKEN="1"
  fi
  if [ -z "$STORED_TOKEN" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "SKIP: no host-held Claude credential to present. A containerized turn is host-mediated, so the"
    echo "      vendor CLI's own login cannot reach the container. Either run \`dartclaw auth claude\` and point"
    echo "      DARTCLAW_CONTAINER_DATA_DIR at that data dir, or export ANTHROPIC_API_KEY. Use --ci to prove"
    echo "      the posture without a turn."
    exit 0
  fi
fi

if [ -n "$CI_MODE" ]; then
  # Containerized Claude is host-mediated, so wiring refuses to start without a
  # host-held credential — presence is the gate, never validity, because nothing
  # here reaches a provider. A placeholder therefore satisfies it without a
  # repository secret and without spending a turn, which is what lets this mode
  # run unchanged on a fork PR. Exported only for the server this script starts.
  export ANTHROPIC_API_KEY="ci-posture-probe-placeholder-not-a-credential"
fi

if [ -n "${DARTCLAW_CONTAINER_DATA_DIR:-}" ]; then
  DATA_DIR="${DARTCLAW_CONTAINER_DATA_DIR}"
  mkdir -p "${DATA_DIR}"
  if [ ! -e "${DATA_DIR}/${CONFIG_NAME}" ]; then
    cp -R "${SEED_DIR}/." "${DATA_DIR}/"
  fi
else
  DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dartclaw-container-XXXXXX")"
  cp -R "${SEED_DIR}/." "${DATA_DIR}/"
fi

CONFIG="${DATA_DIR}/${CONFIG_NAME}"
LOG_PATH="${DATA_DIR}/server.log"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # Remove by the names the server recorded. The runtime hashes the data dir
  # with FNV-1a and appends a per-authority epoch and counter, so a name
  # recomputed here would match nothing and leak every container it meant to
  # reap. The server sweeps its own authorities at shutdown; this is the
  # backstop for a kill that skipped that.
  if [ -f "$LOG_PATH" ]; then
    for name in $(grep -oE 'Container dartclaw-[a-z0-9-]+ \(' "$LOG_PATH" | awk '{print $2}' | sort -u); do
      "$RUNTIME" rm -f "$name" >/dev/null 2>&1 || true
    done
  fi
  if [ -z "${DARTCLAW_CONTAINER_DATA_DIR:-}" ]; then
    rm -rf "${DATA_DIR}"
  fi
}
trap cleanup EXIT

fail_with_log() {
  echo "FAIL: $1" >&2
  [ -f "$LOG_PATH" ] && cat "$LOG_PATH" >&2
  exit 1
}

cd "$REPO_ROOT"

"$RUNTIME" build -t dartclaw-agent:latest docker/

# Generated asset libraries are gitignored; emit them before running from source.
dart run "${REPO_ROOT}/dev/tools/embed_assets.dart" >/dev/null

# The in-container bridge is a build artifact too. Without it the posture
# resolves to advisory mode, which the CI assertion below is there to catch —
# so build it rather than letting the job report a boundary failure as a
# missing-artifact failure.
if [ ! -x "${REPO_ROOT}/build/bridge/dartclaw-bridge-linux-x64" ]; then
  bash "${REPO_ROOT}/dev/tools/build_bridge.sh" >/dev/null
fi

# `dart run`, not `dart <file>`: only `dart run` executes the build hooks that
# produce the sqlite3 native asset. A runner without a system libsqlite3 has
# nothing to fall back to and the server dies in storage wiring.
(cd "${REPO_ROOT}" && exec dart run apps/dartclaw_cli/bin/dartclaw.dart \
  --config "$CONFIG" serve --data-dir "$DATA_DIR" --source-dir "$REPO_ROOT") >"$LOG_PATH" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 60); do
  curl -sf "http://localhost:$PORT/health" >/dev/null && break
  sleep 1
done
curl -sf "http://localhost:$PORT/health" >/dev/null || fail_with_log "server did not come up"

if [ -n "$CI_MODE" ]; then
  # The resolved posture, read off what a non-TTY boot actually emits: the
  # startup banner needs a terminal, the server log does not.
  grep -q 'Container isolation enabled on' "$LOG_PATH" ||
    fail_with_log "the server reached a serving state without resolving the posture to container isolation"
  if grep -q 'agent has full host access' "$LOG_PATH"; then
    fail_with_log "the server downgraded to advisory mode on a runner that has a container runtime"
  fi
  echo "PASS: posture resolved to container isolation on $RUNTIME, serving, with no turn and no credential."
  exit 0
fi

SESSION_JSON="$(curl -sf -X POST "http://localhost:$PORT/api/sessions")" || fail_with_log "session creation failed"
SESSION_ID="$(printf '%s' "$SESSION_JSON" | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])')"

curl -sf -X POST "http://localhost:$PORT/api/sessions/$SESSION_ID/send" \
  -H 'content-type: application/json' \
  -d '{"message":"Call the task_list tool, then reply with exactly: ok"}' >/dev/null ||
  fail_with_log "send failed"

TURN_OK=""
for _ in $(seq 1 60); do
  MESSAGES_JSON="$(curl -sf "http://localhost:$PORT/api/sessions/$SESSION_ID/messages")" || fail_with_log "messages read failed"
  if printf '%s' "$MESSAGES_JSON" | python3 -c 'import sys, json; raise SystemExit(0 if len(json.load(sys.stdin)) >= 2 else 1)'; then
    TURN_OK=1
    break
  fi
  sleep 1
done
[ -n "$TURN_OK" ] || fail_with_log "no assistant turn completed"

# The execution really happened inside a container. Read the name the server
# actually used rather than recomputing it: the runtime hashes the data dir with
# FNV-1a and appends a per-authority epoch and counter, so no formula here can
# reproduce it, and a recomputed name silently asserts nothing.
STARTED_CONTAINER="$(grep -oE 'Container dartclaw-[a-z0-9]+-workspace-[a-z0-9]+ \(workspace\) started' "$LOG_PATH" |
  head -1 | awk '{print $2}')"
[ -n "$STARTED_CONTAINER" ] || fail_with_log "the server started no workspace container for this turn"

"$RUNTIME" ps --filter "name=^${STARTED_CONTAINER}$" --format '{{.Names}}' | grep -qx "$STARTED_CONTAINER" ||
  fail_with_log "workspace container $STARTED_CONTAINER is not running"

# And it held no provider credential of its own.
if "$RUNTIME" exec "$STARTED_CONTAINER" env | grep -q '^ANTHROPIC_API_KEY='; then
  fail_with_log "ANTHROPIC_API_KEY leaked into the container"
fi

# The default posture did not cost the agent its host tool surface: an MCP
# dispatch is audited per call, so a served task tool leaves a record.
AUDIT="${DATA_DIR}/audit-$(date -u +%Y-%m-%d).ndjson"
grep -q 'task_list' "$AUDIT" 2>/dev/null || fail_with_log "no task_list dispatch was audited in $AUDIT"

echo "PASS: containerized turn completed, no credential in the container, task_list served over the bridge."

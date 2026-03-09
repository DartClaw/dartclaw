#!/usr/bin/env bash
# Requires: Docker, curl, dart, python3
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
CONFIG_PATH="$TMP_DIR/dartclaw.yaml"
LOG_PATH="$TMP_DIR/server.log"
PORT=3334
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  docker rm -f dartclaw-agent >/dev/null 2>&1 || true
  rm -r "$TMP_DIR"
}

trap cleanup EXIT

fail_with_log() {
  if [[ -f "$LOG_PATH" ]]; then
    cat "$LOG_PATH"
  fi
  exit 1
}

if ! docker version >/dev/null 2>&1; then
  echo "Docker is required"
  exit 1
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && ! claude auth status >/dev/null 2>&1; then
  echo "ANTHROPIC_API_KEY or Claude OAuth/setup-token auth is required"
  exit 1
fi

cd "$REPO"

docker build -t dartclaw-agent:latest docker/
docker run --rm dartclaw-agent:latest claude --version

cat >"$CONFIG_PATH" <<EOF
port: $PORT
gateway:
  auth_mode: none
container:
  enabled: true
EOF

dart run dartclaw_cli:dartclaw serve --config "$CONFIG_PATH" --port "$PORT" >"$LOG_PATH" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 30); do
  if curl -sf "http://localhost:$PORT/health" >/dev/null; then
    break
  fi
  sleep 1
done

curl -sf "http://localhost:$PORT/health" >/dev/null || fail_with_log

SESSION_JSON="$(curl -sf -X POST "http://localhost:$PORT/api/sessions")" || fail_with_log
SESSION_ID="$(printf '%s' "$SESSION_JSON" | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])')" || fail_with_log

SEND_CODE="$(
  curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://localhost:$PORT/api/sessions/$SESSION_ID/send" \
    -H 'content-type: application/json' \
    -d '{"message":"Reply with exactly: ok"}'
)" || fail_with_log
[[ "$SEND_CODE" == "200" ]] || fail_with_log

TURN_OK=""
for _ in $(seq 1 40); do
  MESSAGES_JSON="$(curl -sf "http://localhost:$PORT/api/sessions/$SESSION_ID/messages")" || fail_with_log
  if printf '%s' "$MESSAGES_JSON" | python3 -c 'import sys, json; msgs = json.load(sys.stdin); raise SystemExit(0 if len(msgs) >= 2 else 1)'; then
    TURN_OK=1
    break
  fi
  sleep 1
done

[[ -n "$TURN_OK" ]] || fail_with_log
docker ps --filter name=dartclaw-agent --format '{{.Names}}' | grep -x 'dartclaw-agent' >/dev/null
if docker exec dartclaw-agent env | grep -q '^ANTHROPIC_API_KEY='; then
  echo "FAIL: ANTHROPIC_API_KEY leaked into container"
  fail_with_log
fi

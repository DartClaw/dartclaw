#!/usr/bin/env bash
set -euo pipefail

MODE="${1:?mode must be provider, browser, eof, graceful, sigkill, or postgres}"
EVIDENCE="${2:?evidence directory required}"
BACKEND="${3:-sqlite}"
TEMPORARY_MARKER_PATTERN='TEMPORARY_TURN_ONE|TEMPORARY_TURN_TWO|TEMPORARY_ATTACHMENT_MARKER|TEMPORARY_TOOL_DETAIL_MARKER|TEMPORARY_TOOL_REPLY_MARKER|TEMPORARY_LINEAGE_MARKER|TEMPORARY_PENDING_TOOL_MARKER|TEMPORARY_ACTIVE_REPLY_MARKER|TEMPORARY_QUEUED_INPUT_MARKER|TEMPORARY_QUEUED_REPLY_MARKER'
if [ "$MODE" = postgres ]; then
  MODE=sigkill
  BACKEND=postgres
fi
case "$MODE" in
  provider|browser|eof|graceful|sigkill) ;;
  *) echo 'mode must be provider, browser, eof, graceful, sigkill, or postgres' >&2; exit 2 ;;
esac
case "$BACKEND" in
  sqlite|postgres) ;;
  *) echo 'backend must be sqlite or postgres' >&2; exit 2 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
source "${SCRIPT_DIR}/temporary_history_checks.sh"
DART_LOCK="${REPO_ROOT}/.agent_temp/exec-plan-0.27/with-dart-lock.py"
RUNTIME="${DARTCLAW_CONTAINER_RUNTIME:-docker}"
DARTCLAW_EXECUTABLE="${DARTCLAW_EXECUTABLE:-${REPO_ROOT}/build/bin/dartclaw}"
if ! command -v codex >/dev/null 2>&1 || ! codex login status >/dev/null 2>&1; then
  echo 'codexLoginAvailable=false (the mediated Codex row requires the installed normal Codex login)' >&2
  exit 2
fi
case "$DARTCLAW_EXECUTABLE" in
  *$'\n'*|*$'\r'*) echo 'DARTCLAW_EXECUTABLE must be one executable path' >&2; exit 2 ;;
esac
[ -x "$DARTCLAW_EXECUTABLE" ] || {
  echo "Build the canonical AOT executable first: bash dev/tools/build.sh" >&2
  exit 2
}
"$RUNTIME" version >/dev/null
mkdir -p "$EVIDENCE"
printf '{"codexLoginAvailable":true,"provider":"codex","placement":"container(workspace)"}\n' >"${EVIDENCE}/prerequisites.json"
"$DARTCLAW_EXECUTABLE" --help >"${EVIDENCE}/cli-help.txt"
"$DARTCLAW_EXECUTABLE" serve --help >"${EVIDENCE}/serve-help.txt"
rg -q -- '--config' "${EVIDENCE}/cli-help.txt"
rg -q -- '--port' "${EVIDENCE}/serve-help.txt"
rg -q -- '--data-dir' "${EVIDENCE}/serve-help.txt"
rg -q -- '--source-dir' "${EVIDENCE}/serve-help.txt"
DATA_DIR="$(mktemp -d "${EVIDENCE}/runtime-data-XXXXXX")"
PORT="${DARTCLAW_TEMPORARY_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')}"
BASE_URL="http://127.0.0.1:${PORT}"
CONFIG="${DATA_DIR}/temporary.yaml"
[ "$BACKEND" != postgres ] || : "${DARTCLAW_POSTGRES_URL:?DARTCLAW_POSTGRES_URL is required}"
{
  printf 'data_dir: %s\n' "$DATA_DIR"
  cat "${SCRIPT_DIR}/temporary_conversation.yaml"
} >"$CONFIG"
if [ "$BACKEND" = postgres ]; then
  cat >>"$CONFIG" <<'YAML'
database:
  backend: postgres
  url: ${DARTCLAW_POSTGRES_URL}
YAML
fi
MODEL_CACHE="${REPO_ROOT}/.agent_temp/testing/temporary-conversation-model"
MODEL_NAME='embeddinggemma-300M-Q8_0.gguf'
mkdir -p "$MODEL_CACHE"
{
  printf 'data_dir: %s\n' "$MODEL_CACHE"
  cat "${SCRIPT_DIR}/temporary_conversation.yaml"
} >"${MODEL_CACHE}/temporary-model.yaml"
"$DARTCLAW_EXECUTABLE" --config "${MODEL_CACHE}/temporary-model.yaml" search download-model --json >"${EVIDENCE}/embedding-model.json"
mkdir -p "${DATA_DIR}/models"
ln "${MODEL_CACHE}/models/${MODEL_NAME}" "${DATA_DIR}/models/${MODEL_NAME}" 2>/dev/null || \
  cp "${MODEL_CACHE}/models/${MODEL_NAME}" "${DATA_DIR}/models/${MODEL_NAME}"
SERVER_PID=""
cleanup() {
  agent-browser --session temporary-e2e close >/dev/null 2>&1 || true
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" >/dev/null 2>&1 || true
  [ -z "$SERVER_PID" ] || wait "$SERVER_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
boot() {
  (cd "$REPO_ROOT" && exec "$DARTCLAW_EXECUTABLE" --config "$CONFIG" serve --port "$PORT" --data-dir "$DATA_DIR" --source-dir "$REPO_ROOT") >>"${EVIDENCE}/server.log" 2>&1 &
  SERVER_PID=$!
  ps -p "$SERVER_PID" -o pid= -o comm= -o args= >"${EVIDENCE}/server-process.txt"
  if rg -q 'with-dart-lock|dart run' "${EVIDENCE}/server-process.txt"; then
    echo 'fixture server is not the canonical AOT executable' >&2
    exit 1
  fi
  for _ in $(seq 1 120); do curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && return; kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 1; done
  cat "${EVIDENCE}/server.log" >&2; exit 1
}
create() {
  curl -fsS -H 'content-type: application/json' -d '{"retention":"process","disclosureAccepted":true}' "http://127.0.0.1:${PORT}/api/sessions" >"${EVIDENCE}/session.json"
  SESSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${EVIDENCE}/session.json")"
}
send_turn() {
  local marker="$1"
  local submission_id="$2"
  local artifact="${3:-$2}"
  local response="${EVIDENCE}/turn-${artifact}.json"
  local before="${EVIDENCE}/assistants-before-${artifact}.json"
  curl -fsS "http://127.0.0.1:${PORT}/api/sessions/${SESSION_ID}/messages" >"${EVIDENCE}/messages.json"
  python3 - "${EVIDENCE}/messages.json" "$before" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1]))
json.dump([row.get('id') for row in rows if row.get('role') == 'assistant'], open(sys.argv[2], 'w'))
PY
  curl -fsS -H 'accept: application/json' -H 'content-type: application/x-www-form-urlencoded' --data-urlencode "message=$marker" --data-urlencode "attachments=${ATTACHMENTS:-[]}" --data-urlencode "submission_id=$submission_id" --data-urlencode "revision_id=${submission_id}-revision" "http://127.0.0.1:${PORT}/api/sessions/${SESSION_ID}/send" >"$response"
  cat "$response" >>"${EVIDENCE}/turns.jsonl"; printf '\n' >>"${EVIDENCE}/turns.jsonl"
  local turn_id
  turn_id="$(python3 -c 'import json,sys; row=json.load(open(sys.argv[1])); print(row["turn_id"])' "$response")"
  for _ in $(seq 1 180); do
    curl -fsS "http://127.0.0.1:${PORT}/api/sessions/${SESSION_ID}/turn-status" >"${EVIDENCE}/turn-status-${artifact}.json"
    curl -fsS "http://127.0.0.1:${PORT}/api/sessions/${SESSION_ID}/messages" >"${EVIDENCE}/messages.json"
    python3 - "$turn_id" "$before" "${EVIDENCE}/turn-status-${artifact}.json" "${EVIDENCE}/messages.json" <<'PY' && return || true
import json,sys
turn_id=sys.argv[1]
before=set(json.load(open(sys.argv[2])))
status=json.load(open(sys.argv[3]))
rows=json.load(open(sys.argv[4]))
assert status.get('turn_id') == turn_id, (status.get('turn_id'), turn_id)
assert status.get('provider') == 'codex', status.get('provider')
assert status.get('state') == 'completed', status.get('state')
assert any(row.get('role') == 'assistant' and row.get('id') not in before for row in rows)
PY
    sleep 1
  done
  cat "${EVIDENCE}/turn-status-${artifact}.json" >&2
  exit 1
}
owned_containers() { "$RUNTIME" ps --filter "label=dartclaw.data-dir=$DATA_DIR" --format '{{.Names}}' | sort; }

boot
owned_containers >"${EVIDENCE}/containers-before-temporary.txt"
create
curl -fsS -H 'content-type: application/json' -d '{"filename":"temporary-marker.txt","mediaType":"text/plain","size":27,"contentBase64":"VEVNUE9SQVJZX0FUVEFDSE1FTlRfTUFSS0VS"}' "http://127.0.0.1:${PORT}/api/sessions/${SESSION_ID}/attachments" >"${EVIDENCE}/attachment.json"
ATTACHMENT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${EVIDENCE}/attachment.json")"
ATTACHMENTS="[{\"id\":\"${ATTACHMENT_ID}\"}]"
send_turn 'TEMPORARY_TURN_ONE' 'temporary-turn-one'
ATTACHMENTS='[]'
owned_containers >"${EVIDENCE}/containers-after-temporary.txt"
FIRST_CONTAINER="$(comm -13 "${EVIDENCE}/containers-before-temporary.txt" "${EVIDENCE}/containers-after-temporary.txt")"
[ "$(printf '%s\n' "$FIRST_CONTAINER" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ]
test -n "$FIRST_CONTAINER"; "$RUNTIME" inspect "$FIRST_CONTAINER" >"${EVIDENCE}/container-first.json"
LIFETIME_CLIENT_PID="$(ps -axo pid=,ppid=,command= | awk -v parent="$SERVER_PID" -v name="$FIRST_CONTAINER" '$2 == parent && index($0, name) > 0 && index($0, " run ") > 0 {print $1}')"
[ "$(printf '%s\n' "$LIFETIME_CLIENT_PID" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ]
kill -0 "$LIFETIME_CLIENT_PID"
ps -p "$LIFETIME_CLIENT_PID" -o pid= -o ppid= -o command= >"${EVIDENCE}/attached-client.txt"
"$RUNTIME" version >"${EVIDENCE}/container-runtime-version.txt"
python3 - "${EVIDENCE}/container-first.json" <<'PY'
import json,sys
row=json.load(open(sys.argv[1]))[0]
assert row['Config']['AttachStdin'] is True
assert row['Config']['OpenStdin'] is True
assert row['Config']['StdinOnce'] is True
assert row['Config']['Tty'] is False
assert row['HostConfig']['AutoRemove'] is True
assert row['Config']['Cmd'] == ['cat']
assert '/home/dartclaw/.dartclaw' in row['HostConfig']['Tmpfs']
assert not any('/home/dartclaw/.dartclaw' in mount for mount in row['HostConfig']['Binds'] or [])
PY
send_turn 'TEMPORARY_TURN_TWO' 'temporary-turn-two'
temporary_history_setup "$BASE_URL" "$SESSION_ID" "$EVIDENCE"
BRANCH_SESSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${EVIDENCE}/temporary-branch-session.json")"
cp "${EVIDENCE}/messages.json" "${EVIDENCE}/temporary-messages.json"
owned_containers >"${EVIDENCE}/containers-after-turn-two.txt"
rg -qx "$FIRST_CONTAINER" "${EVIDENCE}/containers-after-turn-two.txt"
TEMPORARY_SESSION_ID="$SESSION_ID"
curl -fsS -H 'content-type: application/json' -d '{}' "http://127.0.0.1:${PORT}/api/sessions" >"${EVIDENCE}/ordinary-session.json"
ORDINARY_SESSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${EVIDENCE}/ordinary-session.json")"
SESSION_ID="$ORDINARY_SESSION_ID"
curl -fsS -H 'content-type: application/json' -d '{"filename":"ordinary-control.txt","mediaType":"text/plain","size":27,"contentBase64":"T1JESU5BUllfQVRUQUNITUVOVF9DT05UUk9M"}' "http://127.0.0.1:${PORT}/api/sessions/${SESSION_ID}/attachments" >"${EVIDENCE}/ordinary-attachment.json"
ORDINARY_ATTACHMENT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${EVIDENCE}/ordinary-attachment.json")"
ATTACHMENTS="[{\"id\":\"${ORDINARY_ATTACHMENT_ID}\"}]"
send_turn 'Reply exactly ORDINARY_TURN_CONTROL. Before replying, call memory_observe once with text ORDINARY_MEMORY_CONTROL and role observation.' 'ordinary-replay-control'
cp "${EVIDENCE}/messages.json" "${EVIDENCE}/ordinary-messages.json"
ATTACHMENTS='[]'
curl -fsS -w '%{http_code}' -o "${EVIDENCE}/ordinary-replay.json" -H 'accept: application/json' -H 'content-type: application/x-www-form-urlencoded' --data-urlencode 'message=Reply exactly ORDINARY_TURN_CONTROL. Before replying, call memory_observe once with text ORDINARY_MEMORY_CONTROL and role observation.' --data-urlencode "attachments=[{\"id\":\"${ORDINARY_ATTACHMENT_ID}\"}]" --data-urlencode 'submission_id=ordinary-replay-control' --data-urlencode 'revision_id=ordinary-replay-control-revision' "http://127.0.0.1:${PORT}/api/sessions/${SESSION_ID}/send" >"${EVIDENCE}/ordinary-replay.status"
[ "$(cat "${EVIDENCE}/ordinary-replay.status")" = 200 ]
python3 - "${EVIDENCE}/ordinary-replay.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['replayed'] is True
PY
owned_containers >"${EVIDENCE}/containers-after-ordinary.txt"
ORDINARY_CONTAINER="$(rg -vx "$FIRST_CONTAINER" "${EVIDENCE}/containers-after-ordinary.txt")"
[ "$(printf '%s\n' "$ORDINARY_CONTAINER" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ]
test -n "$ORDINARY_CONTAINER"
run_sink_checks() {
  local artifact="$1"
  for _ in $(seq 1 60); do
    python3 "${SCRIPT_DIR}/temporary_sink_checks.py" "$DATA_DIR" "$TEMPORARY_SESSION_ID" "$ORDINARY_SESSION_ID" "${EVIDENCE}/server.log" "$BACKEND" - "$ORDINARY_CONTAINER" >"${EVIDENCE}/sink-checks-${artifact}.json" 2>"${EVIDENCE}/sink-checks-${artifact}.err" && return
    sleep 1
  done
  cat "${EVIDENCE}/sink-checks-${artifact}.err" >&2
  exit 1
}
run_sink_checks before-queue
SESSION_ID="$TEMPORARY_SESSION_ID"

if [ "$MODE" = browser ]; then
  command -v agent-browser >/dev/null || { echo 'agent-browser is required' >&2; exit 2; }
  bash "${SCRIPT_DIR}/temporary_browser_checks.sh" "http://127.0.0.1:${PORT}" "$SESSION_ID" "${EVIDENCE}/browser" "${DARTCLAW_TEMPORARY_COMPARE_WIREFRAMES:-0}"
fi

temporary_queue_setup "$BASE_URL" "$SESSION_ID" "$EVIDENCE"
run_sink_checks after-queue

if [ "$MODE" = provider ] || [ "$MODE" = browser ]; then
  curl -fsS -H 'content-type: application/json' -d '{"confirmed":true,"durableCopyAccepted":true}' "http://127.0.0.1:${PORT}/api/sessions/${SESSION_ID}/export" >"${EVIDENCE}/export.md"
  rg -q 'TEMPORARY_TURN_ONE' "${EVIDENCE}/export.md"; rg -q 'durable copy' "${EVIDENCE}/export.md"
  curl -fsS -X POST "http://127.0.0.1:${PORT}/api/sessions/${SESSION_ID}/end-temporary" -o /dev/null
  if kill -0 "$LIFETIME_CLIENT_PID" 2>/dev/null; then echo 'provider client survived confirmed end' >&2; exit 1; fi
  if "$RUNTIME" inspect "$FIRST_CONTAINER" >/dev/null 2>&1; then echo 'container survived confirmed end' >&2; exit 1; fi
  if curl -fsS "http://127.0.0.1:${PORT}/api/sessions/${SESSION_ID}" >/dev/null 2>&1; then
    echo 'temporary session survived confirmed end' >&2
    exit 1
  fi
  run_sink_checks after-boundary
elif [ "$MODE" = eof ]; then
  curl -fsS -X POST "http://127.0.0.1:${PORT}/api/sessions/${SESSION_ID}/end-temporary" -o /dev/null
  for _ in $(seq 1 60); do ! "$RUNTIME" inspect "$FIRST_CONTAINER" >/dev/null 2>&1 && break; sleep 1; done
  if kill -0 "$LIFETIME_CLIENT_PID" 2>/dev/null; then echo 'provider client survived confirmed end' >&2; exit 1; fi
  if "$RUNTIME" inspect "$FIRST_CONTAINER" >/dev/null 2>&1; then echo 'container survived confirmed end' >&2; exit 1; fi
  run_sink_checks after-boundary
  DARTCLAW_TEMPORARY_EOF_EVIDENCE="${EVIDENCE}/owner-eof" python3 "$DART_LOCK" dart test --reporter=failures-only --run-skipped -t integration packages/dartclaw_runtime/test/container/temporary_container_manager_live_test.dart
elif [ "$MODE" = graceful ] || [ "$MODE" = sigkill ]; then
  if [ "$MODE" = graceful ]; then
    kill "$SERVER_PID"
  else
    kill -9 "$SERVER_PID"
  fi
  wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""
  for _ in $(seq 1 60); do ! "$RUNTIME" inspect "$FIRST_CONTAINER" >/dev/null 2>&1 && break; sleep 1; done
  if kill -0 "$LIFETIME_CLIENT_PID" 2>/dev/null; then echo 'provider client survived server termination' >&2; exit 1; fi
  if "$RUNTIME" inspect "$FIRST_CONTAINER" >/dev/null 2>&1; then echo 'container survived server termination' >&2; exit 1; fi
  if rg -uuu -q "$TEMPORARY_MARKER_PATTERN" "$DATA_DIR"; then echo 'temporary marker persisted before restart' >&2; exit 1; fi
  boot
  if curl -fsS "http://127.0.0.1:${PORT}/api/sessions/${SESSION_ID}" >/dev/null 2>&1; then
    echo 'temporary session returned after restart' >&2
    exit 1
  fi
  if curl -fsS "http://127.0.0.1:${PORT}/api/sessions/${BRANCH_SESSION_ID}" >/dev/null 2>&1; then
    echo 'temporary branch returned after restart' >&2
    exit 1
  fi
  curl -fsS "http://127.0.0.1:${PORT}/api/sessions/${ORDINARY_SESSION_ID}" >"${EVIDENCE}/ordinary-after-restart.json"
  if rg -uuu -q "$TEMPORARY_MARKER_PATTERN" "$DATA_DIR"; then echo 'temporary marker persisted after restart' >&2; exit 1; fi
  if [ "$BACKEND" = postgres ]; then
    pg_dump --data-only "$DARTCLAW_POSTGRES_URL" >"${EVIDENCE}/postgres-data.sql"
    if rg -q "$TEMPORARY_MARKER_PATTERN" "${EVIDENCE}/postgres-data.sql"; then
      echo 'temporary marker persisted in PostgreSQL' >&2
      exit 1
    fi
  fi
  run_sink_checks after-restart
fi

printf '%s\n' "$FIRST_CONTAINER" >"${EVIDENCE}/authority.txt"

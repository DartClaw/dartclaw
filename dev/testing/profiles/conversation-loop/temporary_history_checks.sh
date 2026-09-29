#!/usr/bin/env bash

# Sourced by the live fixture, reusing its genuine-provider send_turn operation.
temporary_history_setup() {
  local base_url="$1" session_id="$2" evidence="$3"
  send_turn "Run only this harmless shell command: printf '%s\\n' TEMPORARY_TOOL_DETAIL_MARKER. Do not read or modify project files. Then reply exactly TEMPORARY_TOOL_REPLY_MARKER." temporary-tool-history
  curl --fail --silent --show-error "${base_url}/api/sessions/${session_id}/conversation-state" >"${evidence}/temporary-history-state.json"
  curl --fail --silent --show-error "${base_url}/api/sessions/${session_id}/messages" >"${evidence}/temporary-messages.json"
  python3 - "${evidence}/temporary-history-state.json" "${evidence}/temporary-messages.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
messages = json.load(open(sys.argv[2]))
records = [record for record in state['records'] if record['kind'] == 'tool']
assert any(record['state'] == 'succeeded'
           and 'TEMPORARY_TOOL_DETAIL_MARKER' in (record.get('arguments') or '')
           and 'TEMPORARY_TOOL_DETAIL_MARKER' in (record.get('result') or '')
           for record in records), 'real successful tool arguments/result were not retained'
assert any(message['role'] == 'assistant' and 'TEMPORARY_TOOL_REPLY_MARKER' in message['content']
           for message in messages), 'real provider response marker missing'
PY
  local message_id
  message_id="$(python3 - "${evidence}/temporary-messages.json" <<'PY'
import json, sys
print(next(row['id'] for row in reversed(json.load(open(sys.argv[1]))) if row['role'] == 'assistant'))
PY
)"
  local revision
  revision="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "${evidence}/temporary-history-state.json")"
  curl --fail --silent --show-error -X POST \
    --data-urlencode kind=fork --data-urlencode mutation_id=TEMPORARY_LINEAGE_MARKER \
    --data-urlencode "conversation_revision=${revision}" \
    "${base_url}/api/sessions/${session_id}/messages/${message_id}/branch" >"${evidence}/temporary-branch.json"
  local branch_id
  branch_id="$(python3 - "${evidence}/temporary-branch.json" "$session_id" "$message_id" <<'PY'
import json, sys
row = json.load(open(sys.argv[1]))
assert row['kind'] == 'fork' and row['completed'] is True
assert row['mutationId'] == 'TEMPORARY_LINEAGE_MARKER'
assert row['sourceSessionId'] == sys.argv[2] and row['sourceMessageId'] == sys.argv[3]
assert row['destinationSessionId'] != sys.argv[2]
print(row['destinationSessionId'])
PY
)"
  curl --fail --silent --show-error "${base_url}/api/sessions/${branch_id}" >"${evidence}/temporary-branch-session.json"
  curl --fail --silent --show-error "${base_url}/api/sessions/${branch_id}/messages" >"${evidence}/temporary-branch-messages.json"
  python3 - "${evidence}/temporary-branch-session.json" "${evidence}/temporary-branch-messages.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['retention'] == 'process', 'fork changed retention'
assert any('TEMPORARY_TOOL_REPLY_MARKER' in row['content'] for row in json.load(open(sys.argv[2]))), 'fork omitted visible history'
PY
  curl --fail --silent --show-error -X POST "${base_url}/api/sessions/${branch_id}/end-temporary" -o /dev/null
  local status
  status="$(curl --silent --show-error -o "${evidence}/temporary-branch-ended.json" -w '%{http_code}' "${base_url}/api/sessions/${branch_id}")"
  [ "$status" = 404 ] || { echo 'ended temporary branch remains available' >&2; return 1; }
  curl --fail --silent --show-error "${base_url}/api/sessions/${session_id}/conversation-state" >"${evidence}/temporary-history-state.json"
  python3 - "${evidence}/temporary-history-state.json" <<'PY'
import json, sys
assert any(row['mutationId'] == 'TEMPORARY_LINEAGE_MARKER' and row['completed'] is True
           for row in json.load(open(sys.argv[1]))['branches']), 'source lineage record missing'
PY
}

temporary_queue_setup() {
  local base_url="$1" session_id="$2" evidence="$3"
  curl --fail --silent --show-error -H 'accept: application/json' \
    --data-urlencode 'message=Run only this harmless shell command: printf TEMPORARY_PENDING_TOOL_MARKER; sleep 60. Do not read or modify project files. When it finishes reply TEMPORARY_ACTIVE_REPLY_MARKER.' \
    --data-urlencode submission_id=temporary-active-boundary \
    --data-urlencode revision_id=temporary-active-boundary-revision \
    "${base_url}/api/sessions/${session_id}/send" >"${evidence}/temporary-active-admission.json"
  local ready=0
  for _ in $(seq 1 120); do
    curl --fail --silent --show-error "${base_url}/api/sessions/${session_id}/conversation-state" >"${evidence}/temporary-active-state.json"
    if python3 - "${evidence}/temporary-active-state.json" 2>"${evidence}/temporary-active-wait.err" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert any(row['submissionId'] == 'temporary-active-boundary' and row['workState'] == 'running'
           for row in state['submissions']), 'boundary turn is not running'
assert any(row['kind'] == 'tool' and row['state'] == 'running'
           and 'TEMPORARY_PENDING_TOOL_MARKER' in (row.get('arguments') or '')
           for row in state['records']), 'real provider has not entered the bounded tool wait'
PY
    then ready=1; break; fi
    sleep 0.25
  done
  if [ "$ready" -ne 1 ]; then
    cat "${evidence}/temporary-active-wait.err" >&2
    echo 'temporary boundary has no active real tool' >&2
    return 1
  fi
  curl --fail --silent --show-error -H 'accept: application/json' \
    --data-urlencode 'message=Reply exactly TEMPORARY_QUEUED_REPLY_MARKER for TEMPORARY_QUEUED_INPUT_MARKER.' \
    --data-urlencode submission_id=temporary-held-boundary \
    --data-urlencode revision_id=temporary-held-boundary-revision \
    "${base_url}/api/sessions/${session_id}/send" >"${evidence}/temporary-queue-admission.json"
  curl --fail --silent --show-error "${base_url}/api/sessions/${session_id}/conversation-state" >"${evidence}/temporary-boundary-state.json"
  curl --fail --silent --show-error "${base_url}/api/sessions/${session_id}/messages" >"${evidence}/temporary-messages.json"
  python3 - "${evidence}/temporary-boundary-state.json" "${evidence}/temporary-messages.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
messages = json.load(open(sys.argv[2]))
queued = [row for row in state['queue'] if row['submissionId'] == 'temporary-held-boundary']
assert len(queued) == 1 and queued[0]['workState'] == 'queued', 'boundary input was not durably accepted into the process queue'
assert 'TEMPORARY_QUEUED_INPUT_MARKER' in queued[0]['message']
assert queued[0].get('turnId') is None, 'queued work already dispatched'
assert any(row['submissionId'] == 'temporary-active-boundary' and row['workState'] == 'running' for row in state['submissions'])
assert not any(row['role'] == 'assistant' and 'TEMPORARY_QUEUED_REPLY_MARKER' in row['content'] for row in messages), 'held work executed before boundary'
assert any(row['mutationId'] == 'TEMPORARY_LINEAGE_MARKER' for row in state['branches'])
PY
}

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
CASE=""
COMPARE_WIREFRAMES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --case) CASE="${2:-}"; shift 2 ;;
    --compare-wireframes) COMPARE_WIREFRAMES=1; shift ;;
    --help|-h)
      echo "usage: $0 --case fixture-self-test|q4-draft-send|q6-live-delivery|q1-e11|q2-q3-q7-history|q2-q3-q6-q7-q9-history|q9-effective-context|e11-effective-context|q6-q8-q10-inbox-attention|q8-q10-inbox-attention|q9-temporary-destruction-boundaries|q9-temporary-supported-provider|q9-temporary-browser-memory|q9-temporary-export-e11 [--live-provider] [--compare-wireframes]"
      exit 0
      ;;
    --live-provider) LIVE_PROVIDER=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "${CASE}" in
  fixture-self-test|q4-draft-send|q6-live-delivery|q1-e11|q2-q3-q7-history|q2-q3-q6-q7-q9-history|q9-effective-context|e11-effective-context|q6-q8-q10-inbox-attention|q8-q10-inbox-attention|q9-temporary-destruction-boundaries|q9-temporary-supported-provider|q9-temporary-browser-memory|q9-temporary-export-e11) ;;
  *) echo "--case names an unsupported conversation-loop fixture" >&2; exit 2 ;;
esac

EVIDENCE_ROOT="${DARTCLAW_CONVERSATION_EVIDENCE_DIR:-${REPO_ROOT}/.agent_temp/testing/conversation-loop/${CASE}}"
mkdir -p "${EVIDENCE_ROOT}"

if [ "${CASE}" = "q9-temporary-destruction-boundaries" ]; then
  "${SCRIPT_DIR}/temporary_conversation_e2e.sh" eof "${EVIDENCE_ROOT}/sqlite-confirmed-end" sqlite
  "${SCRIPT_DIR}/temporary_conversation_e2e.sh" graceful "${EVIDENCE_ROOT}/sqlite-graceful" sqlite
  "${SCRIPT_DIR}/temporary_conversation_e2e.sh" sigkill "${EVIDENCE_ROOT}/sqlite-sigkill" sqlite
  "${SCRIPT_DIR}/temporary_conversation_e2e.sh" eof "${EVIDENCE_ROOT}/postgres-confirmed-end" postgres
  "${SCRIPT_DIR}/temporary_conversation_e2e.sh" graceful "${EVIDENCE_ROOT}/postgres-graceful" postgres
  "${SCRIPT_DIR}/temporary_conversation_e2e.sh" sigkill "${EVIDENCE_ROOT}/postgres-sigkill" postgres
  echo "Evidence: ${EVIDENCE_ROOT}"
  exit 0
fi
if [ "${CASE}" = "q9-temporary-supported-provider" ]; then
  test "${LIVE_PROVIDER:-0}" -eq 1 || { echo "--live-provider is required" >&2; exit 2; }
  "${SCRIPT_DIR}/temporary_conversation_e2e.sh" provider "${EVIDENCE_ROOT}"
  echo "Evidence: ${EVIDENCE_ROOT}"
  exit 0
fi
if [ "${CASE}" = "q9-temporary-browser-memory" ] || [ "${CASE}" = "q9-temporary-export-e11" ]; then
  DARTCLAW_TEMPORARY_COMPARE_WIREFRAMES="${COMPARE_WIREFRAMES}" \
    "${SCRIPT_DIR}/temporary_conversation_e2e.sh" browser "${EVIDENCE_ROOT}"
  echo "Evidence: ${EVIDENCE_ROOT}"
  exit 0
fi

if [ "${CASE}" = "fixture-self-test" ] || [ "${CASE}" = "q4-draft-send" ]; then
  cd "${REPO_ROOT}"
  if ! dart test --reporter=failures-only --run-skipped -t integration \
    packages/dartclaw_runtime/test/integration/conversation_submission_crash_recovery_test.dart \
    >"${EVIDENCE_ROOT}/crash-fixture.log" 2>&1; then
    cat "${EVIDENCE_ROOT}/crash-fixture.log" >&2
    exit 1
  fi
fi

DATA_DIR="$(mktemp -d "${EVIDENCE_ROOT}/runtime-data-XXXXXX")"
PORT="${DARTCLAW_CONVERSATION_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')}"
FIXTURE="${REPO_ROOT}/packages/dartclaw_runtime/test/integration/_fixtures/conversation_loop_browser_process.dart"
READY="${DATA_DIR}/conversation-browser-ready.json"
SERVER_PID=""

close_all() {
  agent-browser --session conversation-origin close >/dev/null 2>&1 || true
  agent-browser --session conversation-passive close >/dev/null 2>&1 || true
  agent-browser --session conversation-draft close >/dev/null 2>&1 || true
  agent-browser --session conversation-quota close >/dev/null 2>&1 || true
  agent-browser --session conversation-history close >/dev/null 2>&1 || true
  agent-browser --session conversation-wire close >/dev/null 2>&1 || true
  if [ -n "${SERVER_PID}" ]; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
}
trap close_all EXIT

start_server() {
  dart run "${FIXTURE}" "${DATA_DIR}" "${PORT}" >>"${EVIDENCE_ROOT}/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 600); do
    if [ -s "${READY}" ]; then return; fi
    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
      cat "${EVIDENCE_ROOT}/server.log" >&2
      exit 1
    fi
    sleep 0.1
  done
  echo "conversation browser fixture did not become ready" >&2
  exit 1
}

restart_server() {
  kill "${SERVER_PID}"
  wait "${SERVER_PID}" || true
  mv "${READY}" "${READY}.before-restart"
  start_server
}

start_server
BASE_URL="http://127.0.0.1:${PORT}"
curl -fsS -X POST -H 'content-type: application/json' -d '{}' "${BASE_URL}/api/sessions" >"${EVIDENCE_ROOT}/session.json"
SESSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${EVIDENCE_ROOT}/session.json")"
CHANNEL_SESSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["channelSessionId"])' "${READY}")"
CRON_SESSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cronSessionId"])' "${READY}")"
HISTORY_SESSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["historySessionId"])' "${READY}")"
HISTORY_OLD_MESSAGE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["historyOldMessageId"])' "${READY}")"
HISTORY_APPROVAL_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["historyApprovalRequestId"])' "${READY}")"
HISTORY_LIVE_APPROVAL_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["historyLiveApprovalRequestId"])' "${READY}")"
NAMED_AGENT_SESSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["namedAgentSessionId"])' "${READY}")"
INBOX_DRAFT_SESSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inboxDraftSessionId"])' "${READY}")"
INBOX_DONE_SESSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inboxDoneSessionId"])' "${READY}")"
INBOX_ARCHIVED_SESSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inboxArchivedSessionId"])' "${READY}")"
INBOX_LINEAGE_SESSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inboxLineageSessionId"])' "${READY}")"
SESSION_URL="${BASE_URL}/sessions/${SESSION_ID}"

ab() {
  local session="$1"; shift
  agent-browser --session "${session}" "$@"
}

assert_eval() {
  local session="$1" script="$2"
  ab "${session}" eval "${script}" >>"${EVIDENCE_ROOT}/browser-eval.log"
}

source "${SCRIPT_DIR}/visual_comparison.sh"

run_q4() {
  printf 'attachment bytes retained in IndexedDB\n' >"${EVIDENCE_ROOT}/draft-attachment.txt"
  ab conversation-draft open "${SESSION_URL}" >"${EVIDENCE_ROOT}/draft-open.log"
  ab conversation-draft wait '#message-input'
  assert_eval conversation-draft "(async () => { const limits=await fetch('/api/sessions/${SESSION_ID}/attachments/limits').then(r=>r.json()); if(!Number.isInteger(limits.max_attachment_bytes)) throw new Error('server attachment limit missing'); return limits })()"
  assert_eval conversation-draft "(async () => { const c=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat'); const started=performance.now(); while(!c.draftDb && performance.now()-started<2000) await new Promise(r=>setTimeout(r,20)); const provisional={key:c.provisionalDraftKey,submissionId:'provisional-submission',revisionId:'provisional-revision',text:'Provisional transfer proof',references:[],attachments:[{id:'local-file',filename:'provisional.txt',mediaType:'text/plain',size:5,state:'local',file:new File(['bytes'],'provisional.txt',{type:'text/plain'})}],updatedAt:Date.now()}; await c.draftRequest('readwrite',s=>s.put(provisional)); await c.draftRequest('readwrite',s=>s.delete(c.draftKey)); return true })()"
  ab conversation-draft reload
  ab conversation-draft wait '#message-input'
  ab conversation-draft wait 300
  assert_eval conversation-draft "(async () => { const c=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat'); const started=performance.now(); while(!c.attachments.some(a=>a.filename==='provisional.txt' && a.state==='ready' && a.id!=='local-file') && performance.now()-started<2000) await new Promise(r=>setTimeout(r,20)); if(document.querySelector('#message-input').value!=='Provisional transfer proof' || !c.attachments.some(a=>a.filename==='provisional.txt' && a.state==='ready' && a.id!=='local-file')) throw new Error('provisional draft did not transfer and upload'); return true })()"
  assert_eval conversation-draft "(async () => { const i=document.querySelector('#message-input'); const t=performance.now(); i.value='Draft line one\\nDraft line two'; i.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'o'})); await new Promise(requestAnimationFrame); const ms=performance.now()-t; if(ms>=100) throw new Error('input feedback '+ms); return {inputFeedbackMs:ms} })()"
  ab conversation-draft fill '#message-input' $'Draft line one\nDraft line two'
  ab conversation-draft upload '#composer-files' "${EVIDENCE_ROOT}/draft-attachment.txt"
  ab conversation-draft wait 500
  assert_eval conversation-draft "(() => { const s=document.querySelector('[data-dc-chat-target=saveStatus]').textContent; if(!s.includes('Saved on this device')) throw new Error(s); if(!document.body.textContent.includes('draft-attachment.txt')) throw new Error('attachment preview missing'); return true })()"
  ab conversation-draft screenshot "${EVIDENCE_ROOT}/draft-saved.png"
  assert_eval conversation-draft "(async () => { const target=document.querySelector('.input-area'); const drop=new DataTransfer(); drop.items.add(new File(['drop bytes'],'dropped.txt',{type:'text/plain'})); target.dispatchEvent(new DragEvent('drop',{bubbles:true,dataTransfer:drop})); const paste=new DataTransfer(); paste.items.add(new File(['paste bytes'],'pasted.txt',{type:'text/plain'})); target.dispatchEvent(new ClipboardEvent('paste',{bubbles:true,clipboardData:paste})); const started=performance.now(); while((!document.body.textContent.includes('dropped.txt') || !document.body.textContent.includes('pasted.txt')) && performance.now()-started<2000) await new Promise(r=>setTimeout(r,20)); if(!document.body.textContent.includes('dropped.txt') || !document.body.textContent.includes('pasted.txt')) throw new Error('drop/paste upload missing'); return true })()"
  assert_eval conversation-draft "(async () => { const c=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat'); const original=window.fetch; window.fetch=(url,options) => String(url).includes('/attachments') ? Promise.resolve(new Response('{\"error\":{\"message\":\"fixture failure\"}}',{status:500,headers:{'content-type':'application/json'}})) : original(url,options); const input=new DataTransfer(); input.items.add(new File(['retry bytes'],'retry.txt',{type:'text/plain'})); document.querySelector('.input-area').dispatchEvent(new DragEvent('drop',{bubbles:true,dataTransfer:input})); const started=performance.now(); while(!c.attachments.some(a=>a.filename==='retry.txt' && a.state==='failed') && performance.now()-started<2000) await new Promise(r=>setTimeout(r,20)); window.fetch=original; const failed=c.attachments.find(a=>a.filename==='retry.txt' && a.state==='failed'); if(!failed) throw new Error('failed upload state missing'); const retry=document.querySelector('[data-attachment-id=\"'+failed.id+'\"][data-action=\"dc-chat#retryAttachment\"]'); if(!retry) throw new Error('failed upload had no retry'); retry.click(); const retryStarted=performance.now(); while(!c.attachments.some(a=>a.filename==='retry.txt' && a.state==='ready') && performance.now()-retryStarted<2000) await new Promise(r=>setTimeout(r,20)); if(!c.attachments.some(a=>a.filename==='retry.txt' && a.state==='ready')) throw new Error('retry never reached ready'); return true })()"
  assert_eval conversation-draft "(() => { const c=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat'); c.references.push({type:'session',id:'reference-proof',label:'Reference proof',state:'resolved'}); c.syncRichInputs(); const remove=document.querySelector('[data-reference-id=\"reference-proof\"]'); if(!remove || !document.body.textContent.includes('@Reference proof')) throw new Error('reference preview missing'); remove.click(); if(c.references.some(r=>r.id==='reference-proof')) throw new Error('reference removal failed'); return true })()"
  assert_eval conversation-draft "(() => { const c=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat'); const oversized=new File([new Uint8Array(c.maxAttachmentBytes+1)],'too-large.bin'); c.uploadAttachment(oversized); if(!document.body.textContent.includes('exceeds the server limit')) throw new Error('host limit was not enforced'); return true })()"
  ab conversation-draft reload
  ab conversation-draft wait '#message-input'
  ab conversation-draft wait 300
  assert_eval conversation-draft "(() => { if(document.querySelector('#message-input').value !== 'Draft line one\\nDraft line two') throw new Error('saved text did not restore'); if(!document.body.textContent.includes('draft-attachment.txt')) throw new Error('saved file did not restore'); return true })()"

  ab conversation-draft set offline on
  ab conversation-draft fill '#message-input' 'Offline edit that must not send'
  ab conversation-draft wait 300
  ab conversation-draft set offline off
  ab conversation-draft wait 300
  assert_eval conversation-draft "(() => { if(document.querySelectorAll('#messages .msg-user').length !== 0) throw new Error('reconnect auto-sent'); return true })()"

  ab conversation-draft tab new --label second "${SESSION_URL}"
  ab conversation-draft wait '#message-input'
  ab conversation-draft wait 300
  ab conversation-draft fill '#message-input' 'Second tab edit'
  ab conversation-draft wait 300
  ab conversation-draft tab t1
  ab conversation-draft fill '#message-input' 'First tab conflicting edit'
  ab conversation-draft wait 300
  ab conversation-draft tab second
  ab conversation-draft fill '#message-input' 'Second tab wins storage'
  ab conversation-draft wait 300
  ab conversation-draft tab t1
  ab conversation-draft wait 300
  assert_eval conversation-draft "(() => { if(!document.body.textContent.includes('Another tab saved a different revision')) throw new Error('conflict was overwritten'); return true })()"
  ab conversation-draft screenshot "${EVIDENCE_ROOT}/draft-conflict.png"
  assert_eval conversation-draft "(() => { const c=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat'); c.recoverConflictingDraft(); if(document.querySelector('#message-input').value!=='Second tab wins storage' || c.pendingConflict) throw new Error('conflicting draft did not recover'); return true })()"

  ab conversation-draft reload
  ab conversation-draft wait '#message-input'
  ab conversation-draft tab second
  ab conversation-draft reload
  ab conversation-draft wait '#message-input'
  ab conversation-draft tab t1
  ab conversation-draft press Control+Enter
  ab conversation-draft wait '#streaming-msg'
  ab conversation-draft tab second
  assert_eval conversation-draft "(() => { const c=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat'); const attachment=c.attachments.find(a=>a.filename==='draft-attachment.txt'); if(!attachment) throw new Error('losing-tab attachment missing'); const remove=document.querySelector('[data-attachment-id=\"'+attachment.id+'\"][data-action=\"dc-chat#removeAttachment\"]'); if(!remove) throw new Error('losing-tab attachment remove missing'); remove.click(); if(c.attachments.some(a=>a.id===attachment.id)) throw new Error('losing-tab attachment removal failed'); return true })()"
  ab conversation-draft fill '#message-input' 'Newer losing-tab edit remains recoverable'
  assert_eval conversation-draft "(async () => { const state=await fetch('/api/sessions/${SESSION_ID}/conversation-state').then(r=>r.json()); const accepted=state.submissions.find(i=>i.message==='Second tab wins storage'); if(!accepted) throw new Error('accepted revision missing'); const response=await fetch('/api/sessions/${SESSION_ID}/send',{method:'POST',headers:{'content-type':'application/json','accept':'application/json'},body:JSON.stringify({submission_id:accepted.submissionId,revision_id:accepted.revisionId,message:accepted.message,attachments:accepted.attachments,references:accepted.references})}); const retry=await response.json(); if(!response.ok || retry.replayed!==true || retry.message_id!==accepted.messageId || retry.attempt_id!==accepted.attemptId) throw new Error('same revision did not reuse stable result'); const current=await fetch('/api/sessions/${SESSION_ID}/conversation-state').then(r=>r.json()); if(current.submissions.filter(i=>i.submissionId===accepted.submissionId).length!==1) throw new Error('submission duplicated'); const messages=await fetch('/api/sessions/${SESSION_ID}/messages').then(r=>r.json()); if(messages.filter(i=>i.id===accepted.messageId).length!==1) throw new Error('message duplicated'); return {submissionId:accepted.submissionId,messageId:accepted.messageId,attemptId:accepted.attemptId} })()"
  assert_eval conversation-draft "(() => { if(document.querySelector('#message-input').value!=='Newer losing-tab edit remains recoverable') throw new Error('newer edit was cleared'); if(document.body.textContent.includes('draft-attachment.txt')) throw new Error('losing-tab attachment removal was overwritten'); return true })()"
  curl -fsS -X POST "${BASE_URL}/api/sessions/${SESSION_ID}/turn/stop" >"${EVIDENCE_ROOT}/duplicate-stop.json"

  ab conversation-quota addinitscript "Object.defineProperty(globalThis,'indexedDB',{configurable:true,value:{open(){throw new DOMException('quota','QuotaExceededError')}}})"
  ab conversation-quota open "${SESSION_URL}"
  ab conversation-quota wait '#message-input'
  ab conversation-quota fill '#message-input' 'Unsaved quota draft'
  ab conversation-quota wait 300
  assert_eval conversation-quota "(() => { const text=document.body.textContent; if(!text.includes('will not recover after reload') || !text.includes('Copy draft') || !text.includes('Download draft')) throw new Error('quota recovery incomplete'); return true })()"
  ab conversation-quota screenshot "${EVIDENCE_ROOT}/draft-quota-failure.png"
}

run_q1() {
  ab conversation-origin open "${SESSION_URL}"
  ab conversation-origin wait '#message-input'
  assert_eval conversation-origin "(async () => { const i=document.querySelector('#message-input'); const samples=[]; for(let n=0;n<20;n++){ const t=performance.now(); i.value='latency probe '+n; i.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'e'})); await new Promise(requestAnimationFrame); samples.push(performance.now()-t); } samples.sort((a,b)=>a-b); const p95=samples[Math.ceil(samples.length*.95)-1]; if(p95>=100) throw new Error('input feedback p95 '+p95); return {inputFeedbackSamplesMs:samples,p95} })()"
  assert_eval conversation-origin "(async () => { const form=document.querySelector('#chat-form'); const t=performance.now(); form.requestSubmit(); while(!document.querySelector('#streaming-msg,.msg-queued')) { if(performance.now()-t>500) throw new Error('accepted state exceeded 500ms'); await new Promise(requestAnimationFrame); } return {acceptedStateMs:performance.now()-t} })()"
  ab conversation-origin fill '#message-input' 'Control shortcut queue proof'
  ab conversation-origin press Control+Enter
  ab conversation-origin wait --text 'Control shortcut queue proof'
  ab conversation-origin fill '#message-input' 'Command shortcut queue proof'
  ab conversation-origin press Meta+Enter
  ab conversation-origin wait --text 'Command shortcut queue proof'
  for width in 375 390 768 1440; do
    for theme in dark light; do
      ab conversation-origin set viewport "${width}" 900
      ab conversation-origin set media "${theme}" reduced-motion
      assert_eval conversation-origin "(() => { for(const b of document.querySelectorAll('#send-btn,[data-dc-chat-target=stopButton],[data-dc-chat-target=steerButton]')) { const r=b.getBoundingClientRect(); if(r.width<44 || r.height<44) throw new Error('undersized action '+r.width+'x'+r.height); } const i=document.querySelector('#message-input'); if(parseFloat(getComputedStyle(i).maxHeight)>innerHeight*.34) throw new Error('composer growth unbounded'); return true })()"
      ab conversation-origin screenshot "${EVIDENCE_ROOT}/composer-${width}-${theme}.png"
    done
  done
  assert_eval conversation-origin "(async () => { const i=document.querySelector('#message-input'); i.focus(); const before=document.activeElement; document.body.dispatchEvent(new CustomEvent('dartclaw:conversation-changed',{detail:{session_id:'${SESSION_ID}',revision:9999}})); await new Promise(r=>setTimeout(r,100)); if(document.activeElement!==before) throw new Error('reconciliation stole composer focus'); if(document.querySelectorAll('[role=status][aria-live]').length!==1) throw new Error('live region is not bounded'); const selection=getComputedStyle(document.querySelector('#messages')).userSelect; if(selection==='none') throw new Error('streaming disabled selection'); return true })()"
  assert_eval conversation-origin "(() => { const stop=document.querySelector('[data-dc-chat-target=\"stopButton\"]'); if(!stop || stop.hidden) throw new Error('keyboard stop control unavailable'); stop.focus(); if(document.activeElement!==stop) throw new Error('stop control could not receive focus'); return true })()"
  ab conversation-origin press Enter
  ab conversation-origin wait 200
  assert_eval conversation-origin "(() => { if(!document.querySelector('[data-dc-chat-target=\"liveStatus\"]').textContent.includes('Stopping')) throw new Error('keyboard stop was not announced'); return true })()"
  ab conversation-origin set viewport 390 900
  ab conversation-origin set media light reduced-motion
  assert_eval conversation-origin "(() => { document.documentElement.style.zoom='2'; if(!document.querySelector('#send-btn').checkVisibility()) throw new Error('send hidden at 200% zoom'); return true })()"
  ab conversation-origin screenshot "${EVIDENCE_ROOT}/composer-390-light-zoom200.png"
  ab conversation-origin a11y --selector '.input-area' --json >"${EVIDENCE_ROOT}/composer-a11y.json"
  if [ "${COMPARE_WIREFRAMES}" -eq 1 ]; then
    ab conversation-origin set viewport 1440 900
    ab conversation-origin set media dark reduced-motion
    assert_eval conversation-origin "(() => { document.documentElement.style.zoom='1'; return true })()"
    capture_wireframe chat-composer
    compare_current_to_wireframe chat-composer
    capture_wireframe chat-conversation-cards
    compare_current_to_wireframe chat-conversation-cards
  fi
}

run_q6() {
  local origin_headers='{"x-conversation-viewer":"origin"}'
  local passive_headers='{"x-conversation-viewer":"passive"}'
  agent-browser --session conversation-origin --headers "${origin_headers}" open "${SESSION_URL}"
  agent-browser --session conversation-passive --headers "${passive_headers}" open "${SESSION_URL}"
  ab conversation-origin wait '#message-input'
  ab conversation-passive wait '#message-input'
  for external_id in "${CHANNEL_SESSION_ID}" "${CRON_SESSION_ID}"; do
    ab conversation-passive open "${BASE_URL}/sessions/${external_id}"
    ab conversation-passive wait '#message-input'
    assert_eval conversation-passive "(async () => { const snapshot=await fetch('/api/sessions/${external_id}/conversation-state').then(r=>r.json()); if(snapshot.activity.ordinary_controls!==false || !snapshot.activity.message_id || !snapshot.activity.turn.turn_id || snapshot.activity.turn.can_cancel!==true) throw new Error('external activity projection incomplete'); const c=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat'); await c.reconcileConversationState(); if(document.querySelector('#send-btn').textContent==='Queue' || !document.querySelector('[data-dc-chat-target=\"steerButton\"]').hidden) throw new Error('external destination advertised ordinary controls'); const stop=document.querySelector('[data-dc-chat-target=\"stopButton\"]'); if(!stop || stop.hidden) throw new Error('external stop unavailable'); stop.click(); const started=performance.now(); let terminal; while(performance.now()-started<2000){ terminal=await fetch('/api/sessions/${external_id}/conversation-state').then(r=>r.json()); if(terminal.activity.turn.can_cancel===false) break; await new Promise(r=>setTimeout(r,20)); } if(terminal.activity.turn.can_cancel!==false) throw new Error('external cancellation did not settle'); return {before:snapshot.activity,after:terminal.activity} })()"
  done
  ab conversation-passive open "${SESSION_URL}"
  ab conversation-passive wait '#message-input'
  ab conversation-origin fill '#message-input' 'Keep the first turn active'
  ab conversation-origin press Control+Enter
  ab conversation-origin wait '#streaming-msg'
  ab conversation-origin fill '#message-input' 'Queued from origin'
  ab conversation-origin press Control+Enter
  ab conversation-passive wait 500
  assert_eval conversation-passive "(() => { if(!document.body.textContent.includes('Queued from origin')) throw new Error('passive viewer missed queue'); return true })()"

  ab conversation-passive set offline on
  ab conversation-origin fill '#message-input' 'Missed while passive is offline'
  ab conversation-origin press Control+Enter
  ab conversation-passive set offline off
  ab conversation-passive wait 500
  assert_eval conversation-passive "(() => { if(!document.body.textContent.includes('Missed while passive is offline')) throw new Error('reconnect did not reconcile'); document.body.dispatchEvent(new CustomEvent('dartclaw:conversation-changed',{detail:{session_id:'${SESSION_ID}',revision:999}})); document.body.dispatchEvent(new CustomEvent('dartclaw:conversation-changed',{detail:{session_id:'${SESSION_ID}',revision:999}})); return true })()"
  ab conversation-passive wait 300
  assert_eval conversation-passive "(() => { const ids=[...document.querySelectorAll('[data-queue-id]')].map(n=>n.dataset.queueId); if(new Set(ids).size!==ids.length) throw new Error('duplicate invalidation duplicated queue'); return true })()"

  printf 'passive\n' >"${DATA_DIR}/revoked-viewers.txt"
  ab conversation-origin fill '#message-input' 'Revocation invalidation'
  ab conversation-origin press Control+Enter
  ab conversation-passive wait 500
  assert_eval conversation-passive "(() => { const shell=document.querySelector('.shell'); if(shell?.dataset.connection!=='lost') throw new Error('revoked stream retained'); if(!document.body.textContent.includes('Conversation access was revoked') && document.querySelector('#send-btn')?.disabled!==true) throw new Error('revoked snapshot stayed actionable'); return true })()"
  ab conversation-passive screenshot "${EVIDENCE_ROOT}/passive-revoked.png"

  restart_server
  agent-browser --session conversation-origin --headers "${origin_headers}" open "${SESSION_URL}"
  ab conversation-origin wait '#message-input'
  ab conversation-origin wait 500
  assert_eval conversation-origin "(() => { const text=document.body.textContent; if(!text.includes('Held') && !text.includes('uncertain')) throw new Error('restart state was not recoverable'); return true })()"
  ab conversation-origin screenshot "${EVIDENCE_ROOT}/restart-reconciled.png"
}

run_history() {
  local history_url="${BASE_URL}/sessions/${HISTORY_SESSION_ID}?message=${HISTORY_OLD_MESSAGE_ID}"
  ab conversation-history open "${history_url}" >"${EVIDENCE_ROOT}/history-open.log"
  ab conversation-history wait "[data-message-id='${HISTORY_OLD_MESSAGE_ID}']"
  assert_eval conversation-history "(async () => { const target=document.querySelector('[data-message-id=\"${HISTORY_OLD_MESSAGE_ID}\"]'); const rows=[...document.querySelectorAll('#messages [data-message-id]')]; if(!target || rows.length>200) throw new Error('bounded deep-link window failed'); if(target.getAttribute('tabindex')!=='-1') throw new Error('deep-link target cannot receive focus'); const around=await fetch('/api/sessions/${HISTORY_SESSION_ID}/messages?count=200&around_message_id=${HISTORY_OLD_MESSAGE_ID}').then(r=>r.json()); if(!Array.isArray(around.messages) || around.messages.length>200 || !around.messages.some(m=>m.id==='${HISTORY_OLD_MESSAGE_ID}')) throw new Error('bounded around API failed'); if(new Set(rows.map(row=>row.dataset.messageId)).size!==rows.length) throw new Error('history identities duplicated'); return {rendered:rows.length,around:around.messages.length,target:'${HISTORY_OLD_MESSAGE_ID}'} })()"
  assert_eval conversation-history "(() => { const details=document.querySelector('details[data-tool-id]'); if(!details || !details.querySelector('summary') || !details.textContent.includes('partial fixture result')) throw new Error('retained tool disclosure missing'); details.open=true; details.querySelector('summary').focus(); const c=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat'); c.captureHistoryViewState(); c.persistHistoryViewState(); return {tool:details.dataset.toolId,state:details.dataset.state} })()"
  ab conversation-history reload
  ab conversation-history wait "[data-message-id='${HISTORY_OLD_MESSAGE_ID}']"
  assert_eval conversation-history "(() => { const details=document.querySelector('details[data-tool-id]'); if(!details?.open) throw new Error('disclosure state did not survive reload'); const card=document.querySelector('[data-approval-request-id=\"${HISTORY_APPROVAL_ID}\"]'); if(!card || card.dataset.state!=='unavailable' || card.querySelectorAll('[data-approval-decision]').length!==0) throw new Error('stale approval was not rendered unavailable'); return true })()"
  assert_eval conversation-history "(async () => { const card=document.querySelector('[data-approval-request-id=\"${HISTORY_APPROVAL_ID}\"]'); const response=await fetch('/api/sessions/${HISTORY_SESSION_ID}/approvals/${HISTORY_APPROVAL_ID}',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({attempt_id:card.querySelector('[data-approval-attempt-id]').dataset.approvalAttemptId,turn_id:card.querySelector('[data-approval-turn-id]').dataset.approvalTurnId,decision:'approve'})}); const body=await response.json(); if(response.status!==409 || body.error?.code!=='APPROVAL_UNAVAILABLE') throw new Error('stale provider approval was not unavailable'); return body.error })()"
  assert_eval conversation-history "(async () => { const response=await fetch('/api/sessions/${HISTORY_SESSION_ID}/send',{method:'POST',headers:{'content-type':'application/json','accept':'application/json'},body:JSON.stringify({submission_id:'history-live-browser',revision_id:'history-live-browser-r1',message:'Live history approval proof'})}); const body=await response.json(); if(response.status!==202 || !body.attempt_id || !body.turn_id) throw new Error('live history turn was not admitted'); sessionStorage.setItem('history-live-attempt',body.attempt_id); sessionStorage.setItem('history-live-turn',body.turn_id); return body })()"
  ab conversation-history open "${BASE_URL}/sessions/${HISTORY_SESSION_ID}"
  ab conversation-history wait "[data-approval-request-id='${HISTORY_LIVE_APPROVAL_ID}']"
  assert_eval conversation-history "(async () => { const card=document.querySelector('[data-approval-request-id=\"${HISTORY_LIVE_APPROVAL_ID}\"]'); const approve=card?.querySelector('[data-approval-decision=approve]'); if(!approve) throw new Error('live approval control missing'); approve.focus(); if(document.activeElement!==approve) throw new Error('exact approval control did not receive focus'); const payload={attempt_id:sessionStorage.getItem('history-live-attempt'),turn_id:sessionStorage.getItem('history-live-turn'),decision:'approve'}; const request=()=>fetch('/api/sessions/${HISTORY_SESSION_ID}/approvals/${HISTORY_LIVE_APPROVAL_ID}',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(payload)}); const responses=await Promise.all([request(),request()]); const bodies=await Promise.all(responses.map(r=>r.json())); if(responses.some(r=>!r.ok) || bodies.some(b=>b.state!=='approved')) throw new Error('competing live approval decisions did not converge'); const fixture=await fetch('/fixture/history-state').then(r=>r.json()); if(fixture.approvalResponses!==1 || fixture.lastApproved!==true) throw new Error('provider received duplicate or wrong approval'); const state=await fetch('/api/sessions/${HISTORY_SESSION_ID}/conversation-state').then(r=>r.json()); const tool=state.records.find(r=>r.id==='history-live-tool'); if(!tool || tool.state!=='succeeded' || tool.result!=='live fixture result') throw new Error('live tool events were not retained'); return {responses:bodies.map(b=>b.state),fixture,tool} })()"
  assert_eval conversation-history "(async () => { const state=await fetch('/api/sessions/${HISTORY_SESSION_ID}/conversation-state').then(r=>r.json()); const source=state.submissions.find(item=>item.attemptId==='history-fixture-attempt'); if(!source) throw new Error('recovery source missing'); const mutation='history-browser-fork'; const fork=await fetch('/api/sessions/${HISTORY_SESSION_ID}/messages/'+encodeURIComponent(source.messageId)+'/branch',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({mutation_id:mutation,kind:'fork'})}); const linked=await fork.json(); if(!fork.ok || linked.sourceMessageId!==source.messageId || linked.destinationSessionId==='${HISTORY_SESSION_ID}') throw new Error('fork lineage failed'); const replay=await fetch('/api/sessions/${HISTORY_SESSION_ID}/messages/'+encodeURIComponent(source.messageId)+'/branch',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({mutation_id:mutation,kind:'fork'})}); const replayBody=await replay.json(); if(!replay.ok || replayBody.destinationSessionId!==linked.destinationSessionId) throw new Error('fork idempotency failed'); const destination=await fetch('/sessions/'+linked.destinationSessionId).then(r=>r.text()); if(!destination.includes('fixture.txt') || !destination.includes('Fixture conversation')) throw new Error('fork destination lost retained rich input'); const edit=await fetch('/api/sessions/${HISTORY_SESSION_ID}/messages/'+encodeURIComponent(source.messageId)+'/branch',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({mutation_id:'history-browser-edit',kind:'edit',message:'Edited retained browser prompt'})}); const edited=await edit.json(); if(!edit.ok || edited.destinationSessionId===linked.destinationSessionId) throw new Error('edit destination failed'); const editPage=await fetch('/sessions/'+edited.destinationSessionId).then(r=>r.text()); if(!editPage.includes('Edited retained browser prompt') || !editPage.includes('fixture.txt') || !editPage.includes('Fixture conversation')) throw new Error('edit destination lost text or rich input'); return {fork:linked,edit:edited} })()"
  restart_server
  ab conversation-history open "${BASE_URL}/sessions/${HISTORY_SESSION_ID}"
  ab conversation-history wait "[data-approval-request-id='${HISTORY_LIVE_APPROVAL_ID}']"
  assert_eval conversation-history "(async () => { const state=await fetch('/api/sessions/${HISTORY_SESSION_ID}/conversation-state').then(r=>r.json()); const approval=state.records.find(r=>r.id==='${HISTORY_LIVE_APPROVAL_ID}'); const branches=state.branches.filter(b=>b.mutationId==='history-browser-fork'||b.mutationId==='history-browser-edit'); if(approval?.state!=='approved' || branches.length!==2 || branches.some(b=>b.completed!==true)) throw new Error('restart lost approval or recovery lineage'); if(document.querySelector('[data-approval-request-id=\"${HISTORY_LIVE_APPROVAL_ID}\"] [data-approval-decision]')) throw new Error('restart replayed resolved approval controls'); return {approval:approval.state,branches} })()"
  assert_eval conversation-history "(async () => { const state=await fetch('/api/sessions/${HISTORY_SESSION_ID}/conversation-state').then(r=>r.json()); const source=state.submissions.find(item=>item.attemptId==='history-fixture-attempt'); const before=await fetch('/api/sessions/${HISTORY_SESSION_ID}/messages').then(r=>r.json()); const response=await fetch('/api/sessions/${HISTORY_SESSION_ID}/attempts/history-fixture-attempt/retry',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({mutation_id:'history-browser-retry'})}); const body=await response.json(); if(response.status!==202 || !body.warning?.includes('external tool effects') || body.attempt_id===source.attemptId) throw new Error('linked retry failed'); const after=await fetch('/api/sessions/${HISTORY_SESSION_ID}/messages').then(r=>r.json()); if(!before.some(m=>m.id===source.messageId) || !after.some(m=>m.id===source.messageId)) throw new Error('retry mutated source history'); return {sourceAttempt:source.attemptId,newAttempt:body.attempt_id} })()"
  for width in 375 768 1440; do
    for theme in dark light; do
      ab conversation-history set viewport "${width}" 900
      ab conversation-history set media "${theme}" reduced-motion
      assert_eval conversation-history "(() => { if(document.documentElement.scrollWidth>document.documentElement.clientWidth) throw new Error('history horizontal overflow'); for(const button of document.querySelectorAll('[data-copy-message],[data-history-action],[data-approval-decision]')) { const box=button.getBoundingClientRect(); if(box.width<44 || box.height<44) throw new Error('undersized history action '+box.width+'x'+box.height); } return {width:innerWidth,theme:'${theme}'} })()"
      ab conversation-history screenshot "${EVIDENCE_ROOT}/history-${width}-${theme}.png"
    done
  done
  ab conversation-history a11y --selector '#messages' --json >"${EVIDENCE_ROOT}/history-a11y.json"
  assert_eval conversation-history "(() => { const resources=performance.getEntriesByType('resource').filter(entry=>entry.name.includes('/api/sessions/${HISTORY_SESSION_ID}')); const longTasks=performance.getEntriesByType('longtask').map(entry=>entry.duration); return {resources:resources.map(entry=>({name:entry.name,duration:entry.duration,transferSize:entry.transferSize})),longTasks} })()"
  if [ "${COMPARE_WIREFRAMES}" -eq 1 ]; then
    ab conversation-history set viewport 1440 900
    ab conversation-history set media dark reduced-motion
    capture_wireframe chat-conversation-cards history-cards
    compare_session_to_wireframe conversation-history history-cards
    capture_wireframe guard-block-chat history-guard
    compare_session_to_wireframe conversation-history history-guard
  fi
}

run_q9_effective_context() {
  ab conversation-origin open "${SESSION_URL}"
  ab conversation-origin wait '#effective-context-summary'
  ab conversation-passive open "${SESSION_URL}"
  ab conversation-passive wait '#effective-context-summary'
  ab conversation-passive fill '#message-input' 'Passive draft survives context reconciliation'
  assert_eval conversation-passive "(() => { document.querySelector('#message-input').focus(); return {revision:window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat').conversationRevision} })()"
  if [ "${COMPARE_WIREFRAMES}" -eq 1 ]; then
    ab conversation-origin set viewport 1440 900
    ab conversation-origin set media dark reduced-motion
    capture_wireframe new-session
    compare_current_to_wireframe new-session
  fi
  assert_eval conversation-origin "(async () => { const initial=await fetch('/api/sessions/${SESSION_ID}/conversation-state').then(r=>r.json()); if(!initial.next_context || initial.next_context.projectId!=='fixture-docs') throw new Error('configured default project context missing'); if(!document.body.textContent.includes('Fixture Docs') || document.querySelector('[data-identicon-id=\"fixture-docs\"]')===null) throw new Error('project name or stable identity missing'); const c=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat'); const input=document.querySelector('#message-input'); input.value='Draft retained across context validation'; input.dispatchEvent(new InputEvent('input',{bubbles:true})); document.querySelector('#effective-context-model-input').value='fixture-model'; document.querySelector('#effective-context-effort-input').value='high'; document.querySelector('#effective-context-form').requestSubmit(); const started=performance.now(); while(c.conversationRevision===initial.revision && performance.now()-started<2000) await new Promise(r=>setTimeout(r,20)); if(c.conversationRevision===initial.revision || input.value!=='Draft retained across context validation') throw new Error('context form did not apply without changing draft'); return {revision:c.conversationRevision} })()"
  ab conversation-origin fill '#message-input' 'Active context capture'
  ab conversation-origin press Control+Enter
  ab conversation-origin wait '#streaming-msg'
  ab conversation-origin fill '#message-input' 'Queued context capture with @reference'
  assert_eval conversation-origin "(async () => { const c=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat'); const before=await fetch('/api/sessions/${SESSION_ID}/conversation-state').then(r=>r.json()); const active=before.submissions.find(i=>i.workState==='running'||i.workState==='dispatching'); if(!active || active.admittedContext.model!=='fixture-model') throw new Error('active attempt lost admitted context'); const suggestions=await fetch('/api/sessions/${SESSION_ID}/references?q=reference').then(r=>r.json()); const ref=suggestions.references.find(r=>r.type==='file'&&r.id==='reference.md'); if(!ref) throw new Error('selected-project reference root not used'); c.references=[ref]; c.syncRichInputs(); const change={conversation_revision:before.revision,project_id:'fixture-docs',directory:before.next_context.directory,provider:'acp',model:null,effort:null}; const response=await fetch('/api/sessions/${SESSION_ID}/context',{method:'PATCH',headers:{'content-type':'application/json'},body:JSON.stringify(change)}); if(!response.ok) throw new Error('next context mutation rejected'); const accepted=await response.json(); c.reconcileContext(accepted); const stale=await fetch('/api/sessions/${SESSION_ID}/context',{method:'PATCH',headers:{'content-type':'application/json'},body:JSON.stringify(change)}); if(stale.status!==409 || document.querySelector('#message-input').value!=='Queued context capture with @reference') throw new Error('stale context mutation changed state or draft'); return accepted })()"
  assert_eval conversation-passive "(async () => { const c=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=dc-chat]'),'dc-chat'); const started=performance.now(); while(document.querySelector('#effective-context-provider').value!=='acp' && performance.now()-started<2000) await new Promise(r=>setTimeout(r,20)); if(document.querySelector('#effective-context-provider').value!=='acp' || !document.querySelector('#effective-context-model-input').disabled || !document.querySelector('#effective-context-effort-input').disabled) throw new Error('authoritative form controls did not reconcile'); if(!document.querySelector('#effective-context-current').textContent.includes('claude') || !document.querySelector('#effective-context-next').textContent.includes('acp')) throw new Error('current/next context did not reconcile'); if(document.querySelector('#message-input').value!=='Passive draft survives context reconciliation' || document.activeElement!==document.querySelector('#message-input')) throw new Error('reconciliation changed draft or focus'); const before=c.conversationRevision; document.querySelector('#effective-context-form').requestSubmit(); while(c.conversationRevision===before && performance.now()-started<4000) await new Promise(r=>setTimeout(r,20)); const state=await fetch('/api/sessions/${SESSION_ID}/conversation-state').then(r=>r.json()); if(state.next_context.provider!=='acp') throw new Error('reconciled form restored stale provider'); return state })()"
  ab conversation-origin press Control+Enter
  ab conversation-origin wait --text 'Queued context capture with @reference'
  assert_eval conversation-origin "(async () => { let state=await fetch('/api/sessions/${SESSION_ID}/conversation-state').then(r=>r.json()); const queued=state.submissions.find(i=>i.workState==='queued'); if(!queued || queued.admittedContext.provider!=='acp' || queued.references[0].id!=='reference.md') throw new Error('queued attempt lost next context or revalidated reference'); await fetch('/__fixture/harness/primary/complete',{method:'POST'}); const started=performance.now(); let harnesses; while(performance.now()-started<3000){ harnesses=await fetch('/__fixture/harnesses').then(r=>r.json()); if(harnesses.secondary.turns===1) break; await new Promise(r=>setTimeout(r,20)); } if(harnesses.secondary.turns!==1 || harnesses.secondary.sessionId!=='${SESSION_ID}' || harnesses.secondary.directory!==state.next_context.directory || harnesses.secondary.model!==null || harnesses.secondary.effort!==null) throw new Error('admitted ACP context did not cross coordinator into secondary harness'); if(harnesses.primary.turns!==1) throw new Error('primary harness received selected-provider turn'); await fetch('/__fixture/harness/secondary/complete',{method:'POST'}); while(performance.now()-started<5000){ state=await fetch('/api/sessions/${SESSION_ID}/conversation-state').then(r=>r.json()); if(state.telemetry?.source==='acp') break; await new Promise(r=>setTimeout(r,20)); } if(state.telemetry?.source!=='acp' || state.telemetry.availability!=='measured' || state.telemetry.usedTokens!==0 || !state.telemetry.behaviorFiles.some(f=>f.path.endsWith('TOOLS.md')&&f.origin==='configured workspace') || state.telemetry.memoryContributed!==false) throw new Error('runtime telemetry/provenance was not recorded by the executing harness'); return state })()"
  ab conversation-origin reload
  ab conversation-origin wait '#effective-context-summary'
  assert_eval conversation-origin "(() => { const text=document.querySelector('#effective-context-summary').textContent; if(!text.includes('Workspace owner') || !text.includes('Current') || !text.includes('Next turn')) throw new Error('ownership/context projection incomplete'); document.querySelector('#effective-context-open').click(); const d=document.querySelector('#effective-context-dialog'); if(!d.open || !d.textContent.includes('Provider-native session and tool state do not')) throw new Error('continuity disclosure missing'); if(!d.textContent.includes('0 tokens') || !d.textContent.includes('TOOLS.md (configured workspace)') || !document.querySelector('#effective-context-memory').hidden) throw new Error('measured zero or provenance missing'); if(!document.querySelector('#effective-context-model-input').disabled || !document.querySelector('#effective-context-effort-input').disabled) throw new Error('ACP unavailable controls stayed editable'); document.querySelector('#effective-context-close').click(); return true })()"
  ab conversation-origin screenshot "${EVIDENCE_ROOT}/effective-context-chat.png"
  if [ "${COMPARE_WIREFRAMES}" -eq 1 ]; then
    capture_wireframe chat-conversation-cards
    compare_current_to_wireframe chat-conversation-cards
  fi
  restart_server
  ab conversation-origin open "${SESSION_URL}"
  ab conversation-origin wait '#effective-context-summary'
  assert_eval conversation-origin "(async () => { const state=await fetch('/api/sessions/${SESSION_ID}/conversation-state').then(r=>r.json()); const retained=state.submissions.find(i=>i.admittedContext?.provider==='acp'); if(!retained || retained.references[0].id!=='reference.md') throw new Error('restart lost admitted context'); return state })()"
  ab conversation-origin open "${BASE_URL}/sessions/${SESSION_ID}/info"
  ab conversation-origin wait '#session-effective-context'
  ab conversation-origin screenshot "${EVIDENCE_ROOT}/effective-context-session-info.png"
  if [ "${COMPARE_WIREFRAMES}" -eq 1 ]; then
    capture_wireframe session-info-panel
    compare_current_to_wireframe session-info-panel
  fi
  ab conversation-origin open "${BASE_URL}/sessions/${NAMED_AGENT_SESSION_ID}"
  ab conversation-origin wait '#effective-context-workspace'
  assert_eval conversation-origin "(() => { if(document.querySelector('#effective-context-workspace').textContent.trim()!=='agent:fixture-agent') throw new Error('named-agent workspace principal changed'); return true })()"
  ab conversation-origin screenshot "${EVIDENCE_ROOT}/effective-context-named-agent.png"
}

run_e11_effective_context() {
  ab conversation-origin open "${SESSION_URL}"
  ab conversation-origin wait '#effective-context-open'
  if [ "${COMPARE_WIREFRAMES}" -eq 1 ]; then
    ab conversation-origin set viewport 1440 900
    ab conversation-origin set media dark reduced-motion
    capture_wireframe new-session
    compare_current_to_wireframe new-session
  fi
  for width in 375 390 768 1440; do
    for theme in dark light; do
      ab conversation-origin set viewport "${width}" 900
      ab conversation-origin set media "${theme}" reduced-motion
      assert_eval conversation-origin "(() => { const open=document.querySelector('#effective-context-open'); open.focus(); open.click(); const dialog=document.querySelector('#effective-context-dialog'); if(!dialog.open || !dialog.contains(document.activeElement)) throw new Error('dialog focus missing'); const controls=[open,...dialog.querySelectorAll('button,input:not([type=hidden]),select')]; for(const control of controls){ const r=control.getBoundingClientRect(); if(r.width<44 || r.height<44) throw new Error('context target '+r.width+'x'+r.height); } const attach=document.querySelector('label[for=composer-files]'); const context=document.querySelector('#effective-context-open-composer'); const effective=document.querySelector('#effective-context-composer-provider'); const send=document.querySelector('#send-btn'); if(!(attach.getBoundingClientRect().left<=context.getBoundingClientRect().left && effective.getBoundingClientRect().left<=send.getBoundingClientRect().left)) throw new Error('composer context/action order changed'); dialog.querySelector('#effective-context-close').focus(); dialog.querySelector('#effective-context-close').dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true})); if(!dialog.contains(document.activeElement)) throw new Error('focus escaped dialog'); dialog.querySelector('#effective-context-close').click(); if(document.activeElement!==open) throw new Error('focus did not restore'); return true })()"
      ab conversation-origin screenshot "${EVIDENCE_ROOT}/effective-context-${width}-${theme}.png"
    done
  done
  ab conversation-origin set viewport 390 900
  assert_eval conversation-origin "(() => { document.documentElement.style.zoom='2'; if(!document.querySelector('#effective-context-open').checkVisibility() || !document.querySelector('#send-btn').checkVisibility()) throw new Error('controls hidden at 200% zoom'); return true })()"
  ab conversation-origin a11y --selector '.input-area' --json >"${EVIDENCE_ROOT}/effective-context-a11y.json"
  if [ "${COMPARE_WIREFRAMES}" -eq 1 ]; then
    assert_eval conversation-origin "(() => { document.documentElement.style.zoom='1'; return true })()"
    ab conversation-origin set viewport 1440 900
    ab conversation-origin set media dark reduced-motion
    capture_wireframe chat-conversation-cards
    compare_current_to_wireframe chat-conversation-cards
    ab conversation-origin open "${BASE_URL}/sessions/${SESSION_ID}/info"
    ab conversation-origin wait '#session-effective-context'
    capture_wireframe session-info-panel
    compare_current_to_wireframe session-info-panel
  fi
}

run_inbox_attention() {
  ab conversation-origin open "${SESSION_URL}"
  ab conversation-origin wait '[data-inbox-filters]'
  assert_eval conversation-origin "(async () => { const db=await new Promise((resolve,reject)=>{const request=indexedDB.open('dartclaw-conversation-drafts',1);request.onupgradeneeded=()=>{if(!request.result.objectStoreNames.contains('drafts'))request.result.createObjectStore('drafts',{keyPath:'key'})};request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error)}); await new Promise((resolve,reject)=>{const tx=db.transaction('drafts','readwrite');tx.objectStore('drafts').put({key:'fixture:${INBOX_DRAFT_SESSION_ID}',text:'Local draft retained on this device',references:[],attachments:[],updatedAt:Date.now()});tx.oncomplete=resolve;tx.onabort=()=>reject(tx.error)}); const controller=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.body,'dc-shell'); await controller.refreshInboxUi(); const drafts=encodeURIComponent('${INBOX_DRAFT_SESSION_ID}'); const active=await fetch('/api/inbox?limit=200&local_draft_session_ids='+drafts).then(r=>r.json()); const settled=await fetch('/api/inbox?settled=1&limit=50&local_draft_session_ids='+drafts).then(r=>r.json()); const archived=await fetch('/api/sessions?type=archive').then(r=>r.json()); const attention=await fetch('/api/attention?limit=200').then(r=>r.json()); if(active.total<200||active.entries.length>200) throw new Error('bounded inbox fixture missing'); if(!Number.isInteger(active.filtered_total)||!Number.isInteger(active.waiting_total)||active.waiting_total<1) throw new Error('complete inbox counts missing'); for(const state of ['unread','waiting','running','failed','done']) if(!active.entries.some(entry=>entry[state])) throw new Error(state+' fixture missing'); if(!settled.entries.some(entry=>entry.session.id==='${INBOX_DRAFT_SESSION_ID}'&&entry.local_draft)) throw new Error('settled local draft missing'); if(!archived.some(session=>session.id==='${INBOX_ARCHIVED_SESSION_ID}')||active.entries.some(entry=>entry.session.id==='${INBOX_ARCHIVED_SESSION_ID}')||settled.entries.some(entry=>entry.session.id==='${INBOX_ARCHIVED_SESSION_ID}')) throw new Error('archive membership leaked'); if(!active.entries.some(entry=>entry.session.id==='${INBOX_LINEAGE_SESSION_ID}'&&entry.parent_session_id)) throw new Error('fork lineage missing'); if(!Array.isArray(attention.items)||!Number.isInteger(attention.unread_total)||!attention.items.some(item=>item.request_id&&item.attempt_id&&item.turn_id)) throw new Error('attention projection missing'); const filtered=await fetch('/api/inbox?filter=drafts&limit=50&local_draft_session_ids='+drafts).then(r=>r.json()); if(filtered.next_attention_session_id==null) throw new Error('offscreen attention navigation missing'); const done=active.entries.find(entry=>entry.session.id==='${INBOX_DONE_SESSION_ID}'); const bulk=await fetch('/api/inbox/settle',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({members:[{session_id:done.session.id,conversation_revision:done.conversation_revision}]})}).then(r=>r.json()); if(bulk.results?.[0]?.accepted!==true) throw new Error('row settle failed'); const restore=await fetch('/api/inbox/'+encodeURIComponent(done.session.id)+'/restore',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({conversation_revision:bulk.results[0].conversation_revision})}); if(!restore.ok) throw new Error('restore failed'); return {active:active.total,settled:settled.total,attention:attention.total,waiting:active.waiting_total} })()"
  assert_eval conversation-origin "(() => { const handle=document.querySelector('.sidebar-resize-handle'); handle.focus(); handle.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true})); if(handle.getAttribute('aria-valuenow')!=='270') throw new Error('keyboard resize failed'); handle.dispatchEvent(new KeyboardEvent('keydown',{key:'Home',bubbles:true})); if(handle.getAttribute('aria-valuenow')!=='260') throw new Error('resize reset failed'); return true })()"
  assert_eval conversation-origin "(async () => { const settled=await fetch('/api/inbox?settled=1&limit=2').then(r=>r.json()); if(!settled.next_cursor||settled.entries.length!==2)throw new Error('settled boundary fixture missing'); const boundary=settled.entries.at(-1); const restoredResponse=await fetch('/api/inbox/'+encodeURIComponent(boundary.session.id)+'/restore',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({conversation_revision:boundary.conversation_revision})}); if(!restoredResponse.ok)throw new Error('settled boundary restore failed'); const restored=await restoredResponse.json(); const nextResponse=await fetch('/api/inbox?settled=1&limit=2&cursor='+encodeURIComponent(settled.next_cursor)); if(!nextResponse.ok)throw new Error('settled keyset cursor rejected removed boundary'); const next=await nextResponse.json(); if(next.entries.some(entry=>entry.session.id===boundary.session.id))throw new Error('settled boundary duplicated'); const active=await fetch('/api/inbox?limit=200').then(r=>r.json()); const staleDone=active.entries.find(entry=>entry.session.id==='${INBOX_DONE_SESSION_ID}'); const moved=await fetch('/api/inbox/settle',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({members:[{session_id:staleDone.session.id,conversation_revision:staleDone.conversation_revision}]})}).then(r=>r.json()); const movedBack=await fetch('/api/inbox/'+encodeURIComponent(staleDone.session.id)+'/restore',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({conversation_revision:moved.results[0].conversation_revision})}).then(r=>r.json()); if(!movedBack.accepted)throw new Error('stale-race setup failed'); const bulk=await fetch('/api/inbox/settle',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({members:[{session_id:boundary.session.id,conversation_revision:restored.conversation_revision},{session_id:staleDone.session.id,conversation_revision:staleDone.conversation_revision}]})}).then(r=>r.json()); if(bulk.results?.[0]?.accepted!==true||bulk.results?.[1]?.code!=='STALE_CONVERSATION_REVISION')throw new Error('bulk partial stale race not preserved'); await fetch('/api/inbox/'+encodeURIComponent(boundary.session.id)+'/restore',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({conversation_revision:bulk.results[0].conversation_revision})}); const attention=await fetch('/api/attention?limit=2').then(r=>r.json()); if(!attention.next_cursor||attention.items.length!==2||!attention.items.at(-1).dismissible)throw new Error('attention boundary fixture missing'); const attentionBoundary=attention.items.at(-1); const dismissed=await fetch('/api/attention/dismiss',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({session_id:attentionBoundary.session_id,event_id:attentionBoundary.event_id,conversation_revision:attentionBoundary.conversation_revision})}); if(!dismissed.ok)throw new Error('attention boundary dismissal failed'); const attentionNext=await fetch('/api/attention?limit=2&cursor='+encodeURIComponent(attention.next_cursor)); if(!attentionNext.ok||(await attentionNext.json()).items.some(item=>item.event_id===attentionBoundary.event_id))throw new Error('attention keyset cursor failed after dismissal'); return {settledCursor:settled.next_cursor,attentionCursor:attention.next_cursor} })()"
  local zoom_modifier=Control
  if [ "$(uname -s)" = Darwin ]; then zoom_modifier=Meta; fi
  for width in 375 390 768 1440; do
    for theme in dark light; do
      ab conversation-origin press "${zoom_modifier}+0"
      ab conversation-origin set viewport "${width}" 900
      ab conversation-origin set media "${theme}" reduced-motion
      assert_eval conversation-origin "(() => { const newChat=document.querySelector('.topbar-new-chat'); if(!newChat||!newChat.checkVisibility()) throw new Error('New Chat unavailable outside closed drawer'); for(const control of document.querySelectorAll('[data-attention-toggle],[data-next-attention],[data-settled-next],.topbar-new-chat')){if(!control.checkVisibility())continue;const box=control.getBoundingClientRect();if(box.width<44||box.height<44)throw new Error('undersized inbox action '+box.width+'x'+box.height)} if(document.documentElement.scrollWidth>document.documentElement.clientWidth)throw new Error('inbox horizontal overflow'); return {width:innerWidth,theme:'${theme}',motion:getComputedStyle(document.documentElement).getPropertyValue('scroll-behavior')} })()"
      ab conversation-origin screenshot "${EVIDENCE_ROOT}/inbox-${width}-${theme}.png"
      assert_eval conversation-origin "(() => { window.__inboxZoomBaseline={width:innerWidth,dpr:devicePixelRatio}; return window.__inboxZoomBaseline })()"
      for _ in 1 2 3 4 5; do ab conversation-origin press "${zoom_modifier}++"; done
      assert_eval conversation-origin "(() => { const baseline=window.__inboxZoomBaseline; const zoomed=innerWidth<=baseline.width*0.6||devicePixelRatio>=baseline.dpr*1.8; if(!zoomed)throw new Error('browser did not reach 200% zoom'); if(document.documentElement.scrollWidth>document.documentElement.clientWidth)throw new Error('inbox horizontal overflow at 200% zoom'); return {width:innerWidth,dpr:devicePixelRatio,theme:'${theme}'} })()"
      ab conversation-origin screenshot "${EVIDENCE_ROOT}/inbox-${width}-${theme}-zoom200.png"
    done
  done
  ab conversation-origin press "${zoom_modifier}+0"
  ab conversation-origin set viewport 1440 900
  assert_eval conversation-origin "(() => { const bell=document.querySelector('[data-attention-toggle]'); bell.click(); if(bell.getAttribute('aria-expanded')!=='true') throw new Error('attention panel did not open'); return true })()"
  ab conversation-origin screenshot "${EVIDENCE_ROOT}/attention-desktop.png"
  ab conversation-origin a11y --selector '#sidebar' --json >"${EVIDENCE_ROOT}/inbox-a11y.json"
  ab conversation-origin a11y --selector '[data-attention-panel]' --json >"${EVIDENCE_ROOT}/attention-a11y.json"
  if [ "${COMPARE_WIREFRAMES}" -eq 1 ]; then
    capture_wireframe session-sidebar-control-plane inbox-reference
    compare_session_to_wireframe conversation-origin inbox-reference 15
    capture_wireframe notification-center attention-reference
    compare_session_to_wireframe conversation-origin attention-reference 15
  fi
}

run_inbox_joined_proof() {
  local origin_headers='{"x-conversation-viewer":"origin"}'
  local passive_headers='{"x-conversation-viewer":"passive"}'
  local history_url="${BASE_URL}/sessions/${HISTORY_SESSION_ID}"
  agent-browser --session conversation-origin --headers "${origin_headers}" open "${history_url}"
  agent-browser --session conversation-passive --headers "${passive_headers}" open "${history_url}"
  ab conversation-origin wait '#message-input'
  ab conversation-passive wait '#message-input'
  ab conversation-origin fill '#message-input' 'Live history approval proof'
  ab conversation-origin press Control+Enter
  ab conversation-origin wait 500
  assert_eval conversation-origin "(async () => { const shell=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.body,'dc-shell'); const started=performance.now(); while(performance.now()-started<3000){await shell.refreshAttentionUi();const item=(shell.attentionItems||[]).find(item=>item.request_id==='history-live-approval');if(item)return {event:item.event_id,revision:item.conversation_revision};await new Promise(r=>setTimeout(r,50))}throw new Error('live attention request never reached origin') })()"
  assert_eval conversation-passive "(async () => { const shell=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.body,'dc-shell'); await shell.refreshInboxUi(); await shell.refreshAttentionUi(); const inbox=await fetch('/api/inbox?limit=200').then(r=>r.json()); if(!shell.attentionItems.some(item=>item.request_id==='history-live-approval')||inbox.waiting_total<1)throw new Error('passive viewer missed joined inbox attention state'); return {waiting:inbox.waiting_total,attention:shell.attentionItems.length} })()"
  assert_eval conversation-origin "(async () => { const shell=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.body,'dc-shell'); const item=shell.attentionItems.find(item=>item.request_id==='history-live-approval'); const row=document.querySelector('[data-event-id="'+CSS.escape(item.event_id)+'"]'); const approve=[...row.querySelectorAll('button')].find(button=>button.textContent==='Approve'); if(!approve)throw new Error('exact attention action missing'); approve.click(); const started=performance.now(); let state; while(performance.now()-started<3000){state=await fetch('/fixture/history-state').then(r=>r.json());if(state.approvalResponses===1)break;await new Promise(r=>setTimeout(r,50))} if(state?.approvalResponses!==1||state.lastApproved!==true)throw new Error('attention action did not reach provider once'); const repeated=await fetch('/api/attention/action',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({event_id:item.event_id,session_id:item.session_id,attempt_id:item.attempt_id,turn_id:item.turn_id,request_id:item.request_id,conversation_revision:item.conversation_revision,approved:true})}); if(repeated.ok)throw new Error('duplicate stale action was accepted'); state=await fetch('/fixture/history-state').then(r=>r.json());if(state.approvalResponses!==1)throw new Error('duplicate action reached provider'); await shell.refreshAttentionUi(); return state })()"
  assert_eval conversation-passive "(async () => { const shell=window.dartclaw.stimulus.getControllerForElementAndIdentifier(document.body,'dc-shell'); const started=performance.now(); while(performance.now()-started<3000){await shell.refreshAttentionUi();const item=shell.attentionItems.find(item=>item.request_id==='history-live-approval');if(item?.status==='approved')return item;await new Promise(r=>setTimeout(r,50))}throw new Error('passive attention did not converge after action') })()"
  local attention_href
  attention_href="$(agent-browser --session conversation-origin get attr href '[data-event-id="record:history-live-approval"] a')"
  if [[ "${attention_href}" != *"message="* || "${attention_href}" != *"#record-history-live-approval"* ]]; then
    echo "attention deep link did not name the message and record: ${attention_href}" >&2
    exit 1
  fi
  ab conversation-origin open "${attention_href}"
  ab conversation-origin wait '#record-history-live-approval'
  assert_eval conversation-origin "(() => { const target=document.querySelector('#record-history-live-approval'); if(document.activeElement!==target)throw new Error('exact attention record did not receive focus'); if(!new URL(location.href).searchParams.get('message'))throw new Error('message window target missing'); return {target:target.id,message:new URL(location.href).searchParams.get('message')} })()"

  ab conversation-passive network route '**/api/inbox*' --abort
  assert_eval conversation-passive "(() => { document.body.dispatchEvent(new CustomEvent('dartclaw:conversation-changed',{detail:{session_id:'${HISTORY_SESSION_ID}',revision:9001}})); return true })()"
  ab conversation-passive wait 300
  assert_eval conversation-passive "(() => { if(!document.body.textContent.includes('Inbox updates are unavailable'))throw new Error('source-keyed inbox outage missing'); return true })()"
  ab conversation-passive network unroute '**/api/inbox*'
  assert_eval conversation-passive "(() => { document.body.dispatchEvent(new CustomEvent('dartclaw:conversation-changed',{detail:{session_id:'${HISTORY_SESSION_ID}',revision:9002}})); return true })()"
  ab conversation-passive wait 300
  assert_eval conversation-passive "(() => { if(document.body.textContent.includes('Inbox updates are unavailable'))throw new Error('recovered inbox outage persisted'); return true })()"

  ab conversation-passive set viewport 390 900
  ab conversation-passive click '.menu-toggle'
  assert_eval conversation-passive "(() => { const sidebar=document.querySelector('#sidebar'); const main=document.querySelector('.shell-main'); if(!sidebar.classList.contains('open')||!main.hasAttribute('inert')||document.activeElement!==sidebar.querySelector('.sidebar-close'))throw new Error('drawer open/focus/inert contract failed'); const focusable=[...sidebar.querySelectorAll('a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])')].filter(element=>!element.hidden&&element.offsetParent!==null); focusable.at(-1).focus(); return {first:focusable[0].className,last:focusable.at(-1).className} })()"
  ab conversation-passive press Tab
  assert_eval conversation-passive "(() => { const sidebar=document.querySelector('#sidebar'); if(!sidebar.contains(document.activeElement))throw new Error('drawer focus escaped'); return true })()"
  ab conversation-passive press Escape
  assert_eval conversation-passive "(() => { if(document.querySelector('#sidebar').classList.contains('open')||document.querySelector('.shell-main').hasAttribute('inert')||document.activeElement!==document.querySelector('.menu-toggle'))throw new Error('drawer close did not restore focus'); return true })()"
}

case "${CASE}" in
  fixture-self-test) run_q4; run_q6 ;;
  q4-draft-send) run_q4 ;;
  q1-e11) run_q1 ;;
  q6-live-delivery) run_q6 ;;
  q2-q3-q7-history) run_history ;;
  q2-q3-q6-q7-q9-history) run_q6; run_history ;;
  q9-effective-context) run_q9_effective_context ;;
  e11-effective-context) run_e11_effective_context ;;
  q6-q8-q10-inbox-attention) run_q6; run_inbox_attention; run_inbox_joined_proof ;;
  q8-q10-inbox-attention) run_inbox_attention ;;
esac

echo "Evidence: ${EVIDENCE_ROOT}"

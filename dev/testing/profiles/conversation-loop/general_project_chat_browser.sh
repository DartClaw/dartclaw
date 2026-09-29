#!/usr/bin/env bash

set -euo pipefail

BASE_URL="$1"
EVIDENCE_ROOT="$2"
COMPARE_WIREFRAMES="$3"
REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SESSION=general-project-chat

ab() {
  agent-browser --session "${SESSION}" "$@"
}

check() {
  ab --json eval "$1" >"${EVIDENCE_ROOT}/$2.json"
}

curl -fsS -X POST -H 'content-type: application/json' -d '{"project_id":null}' \
  "${BASE_URL}/api/sessions/open" >"${EVIDENCE_ROOT}/general-open.json"
GENERAL_ID="$(jq -r '.id' "${EVIDENCE_ROOT}/general-open.json")"
test -n "${GENERAL_ID}"
curl -fsS "${BASE_URL}/api/sessions/${GENERAL_ID}/conversation-state" >"${EVIDENCE_ROOT}/general-state.json"
jq -e '.next_context.projectId == null and .next_context.directory != null' "${EVIDENCE_ROOT}/general-state.json" >/dev/null

ab open "${BASE_URL}/sessions/${GENERAL_ID}" >"${EVIDENCE_ROOT}/general-open.log"
ab wait '#message-input'
check "(() => { const body=document.body.textContent; if(document.querySelector('[data-sidebar-projects]')?.checkVisibility()||document.querySelector('[data-project-controls]')?.checkVisibility()||body.includes('_local'))throw new Error('project chrome in project-free chat'); if(!body.includes('Agent')||!body.includes('Chats'))throw new Error('general navigation missing'); return {projectSection:false,agent:true,chats:true} })()" project-free-dom
ab set viewport 1280 800
ab screenshot "${EVIDENCE_ROOT}/general-desktop.png"
ab set viewport 375 667
check "(() => { if(document.documentElement.scrollWidth>document.documentElement.clientWidth)throw new Error('mobile overflow'); return {width:innerWidth,overflow:0} })()" general-mobile-dom
ab screenshot "${EVIDENCE_ROOT}/general-mobile.png"

curl -fsS -X POST "${BASE_URL}/__fixture/projects/enable" >"${EVIDENCE_ROOT}/projects-enabled.json"
ab set viewport 1280 800
ab reload
ab wait '[data-sidebar-projects]'
check "(() => { const projects=[...document.querySelectorAll('[data-sidebar-project]')].map(x=>x.dataset.sidebarProject); if(projects.length!==2||projects.includes('_local'))throw new Error('project destinations '+projects); return projects })()" project-list-dom
ab click '[data-sidebar-project="s07-project-alpha"] [data-session-create]'
ab wait --fn "document.querySelector('.chat-area')?.dataset.projectId==='s07-project-alpha'"
check "(() => { if(document.querySelector('.chat-area')?.dataset.projectId!=='s07-project-alpha')throw new Error('project New chat selected wrong context'); return {url:location.href,project:document.querySelector('.chat-area').dataset.projectId} })()" project-created-dom
curl -fsS -X POST -H 'content-type: application/json' -d '{"project_id":"s07-project-alpha"}' \
  "${BASE_URL}/api/sessions/open" >"${EVIDENCE_ROOT}/project-reopen.json"
PROJECT_ID="$(jq -r '.id' "${EVIDENCE_ROOT}/project-reopen.json")"
test -n "${PROJECT_ID}"
check "(() => { if(location.pathname.split('/').at(-1)!=='${PROJECT_ID}')throw new Error('project draft was not reused'); return location.pathname })()" project-reuse-dom
ab screenshot "${EVIDENCE_ROOT}/project-desktop.png"
ab open "${BASE_URL}/sessions/${PROJECT_ID}/info"
ab wait 'main'
check "(async () => { const state=await fetch('/api/sessions/${PROJECT_ID}/conversation-state').then(r=>r.json()); const dir=state.next_context.directory; if(!document.body.textContent.includes(dir))throw new Error('Session info omitted project execution directory'); return {directory:dir} })()" project-session-info-dom
ab open "${BASE_URL}/sessions/${PROJECT_ID}"
ab wait '#message-input'
ab click '#sidebar [data-session-create]:not([data-project-id])'
ab wait --fn "!document.querySelector('.chat-area')?.dataset.projectId"
check "(() => { if(document.querySelector('.chat-area')?.dataset.projectId)throw new Error('global New chat inherited project'); return {url:location.href,project:null} })()" global-new-general-dom
curl -fsS -X POST -H 'content-type: application/json' -d '{"project_id":"s07-project-alpha"}' \
  "${BASE_URL}/api/sessions/open" >"${EVIDENCE_ROOT}/project-reopen-after-general.json"
jq -e --arg id "${PROJECT_ID}" '.id == $id' "${EVIDENCE_ROOT}/project-reopen-after-general.json" >/dev/null
ab click '[data-sidebar-project="s07-project-alpha"] [data-session-create]'
ab wait --url "**/sessions/${PROJECT_ID}"
check "(() => { if(location.pathname.split('/').at(-1)!=='${PROJECT_ID}')throw new Error('global New chat consumed project draft'); return {reusedProjectDraft:true} })()" project-draft-retained-dom
ab set viewport 375 667
ab screenshot "${EVIDENCE_ROOT}/project-mobile.png"
ab set viewport 1280 800
ab reload
ab wait '#message-input'

ab fill '#message-input' 'Keep this draft while changing context'
ab click '#effective-context-open'
ab click '#effective-context-project-pop button[data-action="dc-chat#openMoveDialog"]'
ab wait '#context-move-dialog'
check "(() => { const d=document.querySelector('#context-move-dialog'); if(!d.open||!d.textContent.toLowerCase().includes('history'))throw new Error('move disclosure missing'); return {open:d.open,draft:document.querySelector('#message-input').value} })()" move-dialog-dom
ab screenshot "${EVIDENCE_ROOT}/move-dialog-desktop.png"
ab set viewport 375 667
check "(() => { const d=document.querySelector('#context-move-dialog'); const r=d.getBoundingClientRect(); if(!d.open||r.left<0||r.right>innerWidth||r.top<0||r.bottom>innerHeight||document.documentElement.scrollWidth>innerWidth)throw new Error('mobile move dialog clipped'); return {width:innerWidth,dialog:r.toJSON()} })()" move-dialog-mobile-dom
ab screenshot "${EVIDENCE_ROOT}/move-dialog-mobile.png"
ab set viewport 1280 800
ab select '#context-move-destination' ''
ab click '#context-move-dialog button[data-action="dc-chat#confirmMove"]'
ab wait 500
check "(() => { const input=document.querySelector('#message-input'); if(input.value!=='Keep this draft while changing context')throw new Error('move lost draft'); if(document.querySelector('.chat-area')?.dataset.projectId)throw new Error('move did not become general'); if(!document.body.textContent.includes('Future messages run in General chat'))throw new Error('context marker missing'); return {draft:input.value,project:null,marker:true} })()" moved-general-dom
curl -fsS "${BASE_URL}/api/sessions/${PROJECT_ID}/conversation-state" >"${EVIDENCE_ROOT}/moved-general-state.json"
jq -e '[.records[] | select(.kind == "contextChange")] | length == 1' "${EVIDENCE_ROOT}/moved-general-state.json" >/dev/null
ab screenshot "${EVIDENCE_ROOT}/moved-general-desktop.png"

curl -sS -o "${EVIDENCE_ROOT}/invalid-destination.json" -w '%{http_code}' -X POST \
  -H 'content-type: application/json' -d '{"project_id":"missing-project"}' \
  "${BASE_URL}/api/sessions/open" >"${EVIDENCE_ROOT}/invalid-destination-status.txt"
test "$(cat "${EVIDENCE_ROOT}/invalid-destination-status.txt")" != 200
test "$(cat "${EVIDENCE_ROOT}/invalid-destination-status.txt")" != 201

ab click '#effective-context-open'
ab click '#effective-context-project-pop button[data-action="dc-chat#openMoveDialog"]'
ab select '#context-move-destination' 's07-project-beta'
ab click '#context-move-dialog button[data-action="dc-chat#confirmMove"]'
ab wait 500
check "(() => { if(document.querySelector('.chat-area')?.dataset.projectId!=='s07-project-beta')throw new Error('second move failed'); if(document.querySelector('#message-input').value!=='Keep this draft while changing context')throw new Error('second move lost draft'); return {project:'s07-project-beta',draft:true} })()" moved-project-dom
curl -fsS "${BASE_URL}/api/sessions/${PROJECT_ID}/conversation-state" >"${EVIDENCE_ROOT}/moved-project-state.json"
jq -e '[.records[] | select(.kind == "contextChange")] | length == 2' "${EVIDENCE_ROOT}/moved-project-state.json" >/dev/null

ab fill '#message-input' 'Run fixture work before the blocked move'
ab press Control+Enter
ab wait '#streaming-msg'
ab fill '#message-input' 'Draft remains after the blocked move'
ab click '#effective-context-open'
ab click '#effective-context-project-pop button[data-action="dc-chat#openMoveDialog"]'
ab select '#context-move-destination' ''
ab click '#context-move-dialog button[data-action="dc-chat#confirmMove"]'
check "(() => { const error=document.querySelector('#context-move-error'); if(error.hidden||!error.textContent.includes('Finish or cancel pending work'))throw new Error('pending move refusal missing'); if(document.querySelector('#message-input').value!=='Draft remains after the blocked move')throw new Error('refusal lost draft'); return {refused:true,draft:true,error:error.textContent} })()" pending-refusal-dom
ab screenshot "${EVIDENCE_ROOT}/pending-refusal-desktop.png"
ab click '#context-move-dialog button[data-action="dc-chat#closeMoveDialog"]'
curl -fsS -X POST "${BASE_URL}/__fixture/harness/primary/complete" >"${EVIDENCE_ROOT}/pending-complete.json"
ab wait 500

curl -fsS -X POST "${BASE_URL}/__fixture/projects/remove/s07-project-beta" >"${EVIDENCE_ROOT}/project-removed.json"
ab reload
ab wait '#message-input'
check "(() => { const text=document.body.textContent; if(!text.includes('unavailable'))throw new Error('unavailable context not explained'); if(document.querySelector('#message-input').value!=='Draft remains after the blocked move')throw new Error('unavailable reload lost draft'); return {unavailable:true,draft:true} })()" unavailable-dom
ab screenshot "${EVIDENCE_ROOT}/unavailable-desktop.png"
ab set viewport 375 667
ab screenshot "${EVIDENCE_ROOT}/unavailable-mobile.png"

if [ "${COMPARE_WIREFRAMES}" -eq 1 ]; then
  WIREFRAME_ROOT="${REPO_ROOT}/../dartclaw-private/docs/wireframes"
  test -f "${WIREFRAME_ROOT}/general-chat.html"
  test -f "${WIREFRAME_ROOT}/project-chat.html"
  agent-browser --session general-project-wireframe open "file://${WIREFRAME_ROOT}/general-chat.html" >"${EVIDENCE_ROOT}/wireframe-general-open.log"
  agent-browser --session general-project-wireframe set viewport 1280 800
  agent-browser --session general-project-wireframe screenshot "${EVIDENCE_ROOT}/wireframe-general-desktop.png"
  agent-browser --session general-project-wireframe set viewport 375 667
  agent-browser --session general-project-wireframe screenshot "${EVIDENCE_ROOT}/wireframe-general-mobile.png"
  agent-browser --session general-project-wireframe open "file://${WIREFRAME_ROOT}/project-chat.html" >"${EVIDENCE_ROOT}/wireframe-project-open.log"
  agent-browser --session general-project-wireframe set viewport 1280 800
  agent-browser --session general-project-wireframe screenshot "${EVIDENCE_ROOT}/wireframe-project-desktop.png"
  agent-browser --session general-project-wireframe set viewport 375 667
  agent-browser --session general-project-wireframe screenshot "${EVIDENCE_ROOT}/wireframe-project-mobile.png"
fi

ab --json errors >"${EVIDENCE_ROOT}/browser-errors.json"
ab --json console >"${EVIDENCE_ROOT}/browser-console.json"
jq -e '.data.errors | length == 0' "${EVIDENCE_ROOT}/browser-errors.json" >/dev/null
jq -e '[.data.messages[] | select((.type // .level // "" | ascii_downcase) == "error" or (.type // .level // "" | ascii_downcase) == "severe")] | length == 0' "${EVIDENCE_ROOT}/browser-console.json" >/dev/null
jq -n --argjson compared "${COMPARE_WIREFRAMES}" \
  '{case:"general-project-chat",result:"passed",wireframeComparison:$compared,checks:["project-free desktop/mobile","two explicit projects","named-project creation","draft-preserving moves and markers","pending move refusal","invalid destination","unavailable current project","browser console"]}' \
  >"${EVIDENCE_ROOT}/browser-result.json"

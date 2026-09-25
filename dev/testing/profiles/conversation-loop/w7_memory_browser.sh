#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
EVIDENCE_ROOT="$1"
COMPARE_WIREFRAMES="$2"
DATA_DIR="$(mktemp -d "${EVIDENCE_ROOT}/runtime-data-XXXXXX")"
PORT="${DARTCLAW_CONVERSATION_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')}"
PG_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
BASE_URL="http://localhost:${PORT}"
SERVER_PID=""
PG_STARTED=0
printf '{"case":"w7-memory-administration","result":"running"}\n' >"${EVIDENCE_ROOT}/browser-result.json"

close_all() {
  agent-browser --session w7-memory close >/dev/null 2>&1 || true
  agent-browser --session w7-wireframe close >/dev/null 2>&1 || true
  if [ -n "${SERVER_PID}" ]; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
  if [ "${PG_STARTED}" -eq 1 ]; then
    pg_ctl -D "${DATA_DIR}/postgres" stop -m immediate >/dev/null 2>&1 || true
  fi
}
trap close_all EXIT

ab() {
  agent-browser --session w7-memory "$@"
}

check() {
  ab --json eval "$1" >"${EVIDENCE_ROOT}/$2.json"
}

dart run "${SCRIPT_DIR}/w7_memory_seed.dart" "${DATA_DIR}" >"${EVIDENCE_ROOT}/seed.log" 2>&1
initdb -D "${DATA_DIR}/postgres" -A trust -U w7_fixture >"${EVIDENCE_ROOT}/postgres-init.log" 2>&1
pg_ctl -D "${DATA_DIR}/postgres" -o "-h 127.0.0.1 -p ${PG_PORT}" -l "${EVIDENCE_ROOT}/postgres.log" start >"${EVIDENCE_ROOT}/postgres-start.log" 2>&1
PG_STARTED=1
createdb -h 127.0.0.1 -p "${PG_PORT}" -U w7_fixture w7_memory
export DARTCLAW_POSTGRES_URL="postgres://w7_fixture@127.0.0.1:${PG_PORT}/w7_memory?sslmode=disable"
sed "s|__DATA_DIR__|${DATA_DIR}|g" "${SCRIPT_DIR}/w7_memory.yaml" >"${DATA_DIR}/dartclaw.yaml"
dart run "${REPO_ROOT}/dev/tools/embed_assets.dart" >"${EVIDENCE_ROOT}/assets.log" 2>&1
dart --packages="${REPO_ROOT}/.dart_tool/package_config.json" \
  "${REPO_ROOT}/apps/dartclaw_cli/bin/dartclaw.dart" \
  --config "${DATA_DIR}/dartclaw.yaml" serve --dev --data-dir "${DATA_DIR}" --source-dir "${REPO_ROOT}" --port "${PORT}" \
  >"${EVIDENCE_ROOT}/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 600); do
  if curl -fsS "${BASE_URL}/api/memory/corpora" >"${EVIDENCE_ROOT}/corpora.json" 2>/dev/null; then break; fi
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    cat "${EVIDENCE_ROOT}/server.log" >&2
    exit 1
  fi
  sleep 0.1
done
test -s "${EVIDENCE_ROOT}/corpora.json"

python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); got={x["principal"] for x in d["corpora"]}; expected={"owner","agent:alpha","agent:beta","agent:empty","agent:removed"}; assert got==expected,(got,expected); assert {x["kind"] for x in d["corpora"]}=={"default","configured","retained"}' "${EVIDENCE_ROOT}/corpora.json"
ALPHA_SELECTOR="$(python3 -c 'import json,sys; print(next(x["selector"] for x in json.load(open(sys.argv[1]))["corpora"] if x["principal"]=="agent:alpha"))' "${EVIDENCE_ROOT}/corpora.json")"
BETA_SELECTOR="$(python3 -c 'import json,sys; print(next(x["selector"] for x in json.load(open(sys.argv[1]))["corpora"] if x["principal"]=="agent:beta"))' "${EVIDENCE_ROOT}/corpora.json")"
EMPTY_SELECTOR="$(python3 -c 'import json,sys; print(next(x["selector"] for x in json.load(open(sys.argv[1]))["corpora"] if x["principal"]=="agent:empty"))' "${EVIDENCE_ROOT}/corpora.json")"
REMOVED_SELECTOR="$(python3 -c 'import json,sys; print(next(x["selector"] for x in json.load(open(sys.argv[1]))["corpora"] if x["principal"]=="agent:removed"))' "${EVIDENCE_ROOT}/corpora.json")"
curl -fsS "${BASE_URL}/api/memory/entries?corpus=${ALPHA_SELECTOR}" >"${EVIDENCE_ROOT}/alpha-before.json"
ALPHA_ENTRY_ID="$(python3 -c 'import json,sys; print(next(x["id"] for x in json.load(open(sys.argv[1]))["entries"] if x["state"]=="active"))' "${EVIDENCE_ROOT}/alpha-before.json")"
ALPHA_COLLECTION_REVISION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["collectionRevision"])' "${EVIDENCE_ROOT}/alpha-before.json")"
ALPHA_ENTRY_REVISION="$(python3 -c 'import json,sys; print(next(x["entryRevision"] for x in json.load(open(sys.argv[1]))["entries"] if x["state"]=="active"))' "${EVIDENCE_ROOT}/alpha-before.json")"

ab open "${BASE_URL}/memory" >"${EVIDENCE_ROOT}/open.log"
ab wait '#memory-corpus'
ab errors --clear >/dev/null
ab console --clear >/dev/null
check "(() => { const text=document.querySelector('.memory-dashboard-page').textContent; if(!text.includes('owner-only')||text.includes('alpha-only')||text.includes('beta-only')||text.includes('removed-only'))throw new Error('default corpus mixed'); if(!text.includes('Shared wiki')||!text.includes('Default agent'))throw new Error('selected owner or private/shared boundary missing'); return {selected:document.querySelector('#memory-corpus').value,rows:document.querySelectorAll('.memory-dashboard-page table tbody tr').length,text:text.slice(0,1400)} })()" default-dom
ab screenshot "${EVIDENCE_ROOT}/default.png"

for principal in alpha beta removed empty; do
  case "${principal}" in
    alpha) selector="${ALPHA_SELECTOR}" ;;
    beta) selector="${BETA_SELECTOR}" ;;
    removed) selector="${REMOVED_SELECTOR}" ;;
    empty) selector="${EMPTY_SELECTOR}" ;;
  esac
  ab open "${BASE_URL}/memory?corpus=${selector}"
  ab wait '#memory-corpus'
  check "(() => { const text=document.querySelector('.memory-dashboard-page').textContent; const marker='${principal}-only'; if('${principal}'==='empty'){if(!text.includes('No canonical entries'))throw new Error('empty state missing')}else if(!text.includes(marker))throw new Error('selected marker missing: '+marker); for(const other of ['owner-only','alpha-only','beta-only','removed-only'])if(other!==marker&&text.includes(other))throw new Error('cross-corpus leak: '+other); if(document.querySelector('#memory-corpus').value!=='${selector}')throw new Error('selector mismatch'); return {principal:'${principal}',selector:'${selector}',rows:document.querySelectorAll('.memory-dashboard-page table tbody tr').length,health:document.querySelector('.memory-dashboard-section .card-detail')?.textContent.trim()} })()" "${principal}-dom"
  ab screenshot "${EVIDENCE_ROOT}/${principal}.png"
done

ab open "${BASE_URL}/memory?corpus=${ALPHA_SELECTOR}&q=collisiontoken"
ab wait '#memory-entry-query'
check "(() => { const text=document.querySelector('.memory-dashboard-page').textContent; if(!text.includes('alpha-only')||text.includes('beta-only'))throw new Error('search crossed corpus'); return {query:document.querySelector('#memory-entry-query').value,rows:document.querySelectorAll('.memory-dashboard-page table tbody tr').length} })()" search-dom
ab open "${BASE_URL}/memory?corpus=${ALPHA_SELECTOR}&q=missingtoken"
ab wait '#memory-entry-query'
check "(() => { if(!document.querySelector('.empty-state')?.textContent.includes('No matches'))throw new Error('no-match recovery missing'); return document.querySelector('.empty-state').textContent.trim() })()" no-match-dom
ab screenshot "${EVIDENCE_ROOT}/no-match.png"

ab open "${BASE_URL}/memory?corpus=${ALPHA_SELECTOR}"
ab wait '.memory-dashboard-page table tbody tr'
ab click '.memory-dashboard-page table tbody tr a'
ab wait '#memory-entry-detail'
check "(() => { const d=document.querySelector('#memory-entry-detail'); if(!d.textContent.includes('alpha-only')||!d.textContent.includes('Entry revision'))throw new Error('entry detail missing'); return {detail:d.textContent.trim(),edit:document.querySelector('#memory-edit-dialog form').action,remove:document.querySelector('#memory-remove-dialog form').action} })()" detail-dom
ab focus '#memory-entry-detail button'
ab press Enter
check "(() => { const d=document.querySelector('#memory-edit-dialog'); if(!d.open||!d.contains(document.activeElement))throw new Error('edit dialog focus failed'); return {open:d.open,focus:document.activeElement.id||document.activeElement.tagName} })()" edit-focus
ab press Escape
check "(() => { if(document.querySelector('#memory-edit-dialog').open||document.activeElement?.textContent?.trim()!=='Edit entry')throw new Error('edit focus restore failed'); return {restored:document.activeElement.textContent.trim()} })()" edit-restore
ab click '#memory-entry-detail .btn-danger'
check "(() => { const d=document.querySelector('#memory-remove-dialog'); if(!d.open||!d.contains(document.activeElement)||!d.textContent.includes('retained source observations, transcripts, audit records, or backups'))throw new Error('removal disclosure or focus failed'); return {open:d.open,focus:document.activeElement.id||document.activeElement.tagName,disclosure:d.textContent.trim()} })()" remove-dialog
ab screenshot "${EVIDENCE_ROOT}/remove-confirm.png"
ab click '#memory-remove-dialog button.btn-ghost'
check "(() => { if(document.querySelector('#memory-remove-dialog').open)throw new Error('cancel did not close dialog'); return {cancelled:true,detailStillPresent:!!document.querySelector('#memory-entry-detail')} })()" remove-cancel

ab click '#memory-entry-detail button.btn-ghost'
ab fill '#memory-edit-content' 'collisiontoken alpha-corrected marker'
ab focus '#memory-edit-dialog button.btn-primary'
ab press Enter
ab wait 2000
ab --json network requests >"${EVIDENCE_ROOT}/edit-requests.json"
ab wait '#memory-entry-detail'
check "(() => { const text=document.querySelector('.memory-dashboard-page').textContent; if(!text.includes('alpha-corrected')||!text.includes('Canonical edit saved')||text.includes('beta-only'))throw new Error('owner edit did not render authoritative selected result'); return {selected:document.querySelector('#memory-corpus').value,detail:document.querySelector('#memory-entry-detail').textContent.trim(),notice:[...document.querySelectorAll('[role=status]')].map(x=>x.textContent.trim())} })()" edit-result
ab screenshot "${EVIDENCE_ROOT}/edit-result.png"
curl -fsS "${BASE_URL}/api/memory/entries?corpus=${ALPHA_SELECTOR}" >"${EVIDENCE_ROOT}/alpha-after.json"
python3 -c 'import json,sys; before=json.load(open(sys.argv[1])); after=json.load(open(sys.argv[2])); assert after["collectionRevision"]>before["collectionRevision"]; assert any("alpha-corrected" in x["content"] for x in after["entries"]); assert all("alpha-only" not in x["content"] for x in after["entries"])' "${EVIDENCE_ROOT}/alpha-before.json" "${EVIDENCE_ROOT}/alpha-after.json"
STALE_STATUS="$(curl -sS -o "${EVIDENCE_ROOT}/stale-edit.json" -w '%{http_code}' -X POST -H 'content-type: application/json' -d "{\"corpus\":\"${ALPHA_SELECTOR}\",\"expectedCollectionRevision\":${ALPHA_COLLECTION_REVISION},\"expectedEntryRevision\":${ALPHA_ENTRY_REVISION},\"topic\":\"general\",\"content\":\"stale overwrite forbidden\",\"state\":\"active\"}" "${BASE_URL}/api/memory/entries/${ALPHA_ENTRY_ID}/revise")"
test "${STALE_STATUS}" = 409
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["canonicalOutcome"]=="conflict"; assert "alpha-corrected" in d["currentEntry"]["content"]' "${EVIDENCE_ROOT}/stale-edit.json"
CROSS_ORIGIN_STATUS="$(curl -sS -o "${EVIDENCE_ROOT}/cross-origin-denied.json" -w '%{http_code}' -X POST -H 'Origin: https://cross-origin.invalid' -H 'content-type: application/json' -d "{\"corpus\":\"${ALPHA_SELECTOR}\",\"expectedCollectionRevision\":${ALPHA_COLLECTION_REVISION},\"expectedEntryRevision\":${ALPHA_ENTRY_REVISION},\"topic\":\"general\",\"content\":\"cross-origin overwrite forbidden\",\"state\":\"active\"}" "${BASE_URL}/api/memory/entries/${ALPHA_ENTRY_ID}/revise")"
test "${CROSS_ORIGIN_STATUS}" = 403
FORGED_STATUS="$(curl -sS -o "${EVIDENCE_ROOT}/forged-selector.json" -w '%{http_code}' "${BASE_URL}/api/memory/entries?corpus=agent:alpha")"
test "${FORGED_STATUS}" = 404
UNKNOWN_STATUS="$(curl -sS -o "${EVIDENCE_ROOT}/unknown-selector.json" -w '%{http_code}' "${BASE_URL}/api/memory/entries?corpus=unknown")"
test "${UNKNOWN_STATUS}" = 404
curl -fsS "${BASE_URL}/api/memory/entries?corpus=${BETA_SELECTOR}" >"${EVIDENCE_ROOT}/beta-after-alpha-edit.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d["entries"])==1 and "beta-only" in d["entries"][0]["content"]' "${EVIDENCE_ROOT}/beta-after-alpha-edit.json"

ALPHA_CURRENT_COLLECTION_REVISION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["collectionRevision"])' "${EVIDENCE_ROOT}/alpha-after.json")"
ALPHA_CURRENT_ENTRY_REVISION="$(python3 -c 'import json,sys; print(next(x["entryRevision"] for x in json.load(open(sys.argv[1]))["entries"] if x["id"]==sys.argv[2]))' "${EVIDENCE_ROOT}/alpha-after.json" "${ALPHA_ENTRY_ID}")"
curl -fsS -X POST -H 'content-type: application/json' -d "{\"corpus\":\"${ALPHA_SELECTOR}\",\"expectedCollectionRevision\":${ALPHA_CURRENT_COLLECTION_REVISION},\"expectedEntryRevision\":${ALPHA_CURRENT_ENTRY_REVISION},\"topic\":\"general\",\"content\":\"collisiontoken alpha-newer marker\",\"state\":\"active\"}" "${BASE_URL}/api/memory/entries/${ALPHA_ENTRY_ID}/revise" >"${EVIDENCE_ROOT}/alpha-newer-api.json"
ab click '#memory-entry-detail button.btn-ghost'
ab fill '#memory-edit-content' 'stale browser overwrite forbidden'
ab focus '#memory-edit-dialog button.btn-primary'
ab press Enter
ab wait 700
check "(() => { const text=document.querySelector('.memory-dashboard-page').textContent; if(!text.includes('This entry or collection changed')||!text.includes('alpha-newer')||text.includes('stale browser overwrite forbidden'))throw new Error('stale browser view did not recover authoritative entry'); return {url:location.href,selected:document.querySelector('#memory-corpus').value,notice:[...document.querySelectorAll('[role=status]')].map(x=>x.textContent.trim()),detail:document.querySelector('#memory-entry-detail')?.textContent.trim()} })()" stale-browser
ab screenshot "${EVIDENCE_ROOT}/stale-browser.png"

curl -fsS "${BASE_URL}/api/memory/entries?corpus=${REMOVED_SELECTOR}" >"${EVIDENCE_ROOT}/removed-before.json"
REMOVED_ENTRY_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["entries"][0]["id"])' "${EVIDENCE_ROOT}/removed-before.json")"
ab open "${BASE_URL}/memory?corpus=${REMOVED_SELECTOR}&entry=${REMOVED_ENTRY_ID}"
ab wait '#memory-entry-detail'
ab click '#memory-entry-detail .btn-danger'
ab fill '#memory-remove-reason' 'Owner correction'
ab focus '#memory-remove-dialog button.btn-danger-fill'
ab press Enter
ab wait '#memory-corpus'
check "(() => { const text=document.querySelector('.memory-dashboard-page').textContent; if(!text.includes('Curated entry removed')||!text.includes('does not erase retained source observations, transcripts, audit records, or backups')||text.includes('removed-only'))throw new Error('remove result or retained-source disclosure failed'); return {selected:document.querySelector('#memory-corpus').value,notice:[...document.querySelectorAll('[role=status]')].map(x=>x.textContent.trim()),empty:text.includes('No canonical entries')} })()" remove-result
ab screenshot "${EVIDENCE_ROOT}/remove-result.png"
curl -fsS "${BASE_URL}/api/memory/entries?corpus=${REMOVED_SELECTOR}" >"${EVIDENCE_ROOT}/removed-after.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["entries"]==[]' "${EVIDENCE_ROOT}/removed-after.json"
rg -q 'retained source observation marker' "${DATA_DIR}/agents/removed/workspace/memory/2026-02-23.md"

STATUS_FILE="${DATA_DIR}/agents/beta/workspace/.dartclaw-memory-index.json"
jq '.state="degraded" | .failureStage="fixture" | .reason="Browser fixture index unavailable" | .action="Run dartclaw rebuild-index."' "${STATUS_FILE}" >"${DATA_DIR}/beta-degraded.json"
mv "${DATA_DIR}/beta-degraded.json" "${STATUS_FILE}"
ab open "${BASE_URL}/memory?corpus=${BETA_SELECTOR}"
ab wait '#memory-corpus'
check "(() => { const text=document.querySelector('.memory-dashboard-page').textContent; if(!text.includes('Health degraded')||!text.includes('Canonical entries remain available')||!text.includes('beta-only'))throw new Error('degraded corpus UI missing'); return {selected:document.querySelector('#memory-corpus').value,warning:[...document.querySelectorAll('[role=status]')].map(x=>x.textContent.trim())} })()" degraded-dom
ab screenshot "${EVIDENCE_ROOT}/degraded.png"
curl -fsS "${BASE_URL}/api/memory/entries?corpus=${BETA_SELECTOR}" >"${EVIDENCE_ROOT}/degraded-api.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["state"]=="degraded" and d["selected"]["principal"]=="agent:beta" and len(d["entries"])==1' "${EVIDENCE_ROOT}/degraded-api.json"
curl -sS -o "${EVIDENCE_ROOT}/unavailable-response.html" -w '%{http_code}\n' "${BASE_URL}/memory?corpus=unknown" >"${EVIDENCE_ROOT}/unavailable-status.txt"
ab open "${BASE_URL}/memory?corpus=unknown"
ab --json eval "(() => ({url:location.href,title:document.title,body:document.body.textContent.slice(0,1800),main:document.querySelector('main')?.outerHTML.slice(0,1800)}))()" >"${EVIDENCE_ROOT}/unavailable-response.json"
ab screenshot "${EVIDENCE_ROOT}/unavailable.png"

ab open "${BASE_URL}/memory?corpus=${ALPHA_SELECTOR}&entry=${ALPHA_ENTRY_ID}"
ab wait '#memory-entry-detail'

for width in 375 390 768 1440; do
  for theme in dark light; do
    ab set viewport "${width}" 900
    ab set media "${theme}" reduced-motion
    check "(async () => { const desired='${theme}'==='light'?'light':''; const root=document.documentElement; if((root.dataset.theme||'')!==desired)document.querySelector('.theme-toggle')?.click(); await new Promise(requestAnimationFrame); if((root.dataset.theme||'')!==desired||!matchMedia('(prefers-reduced-motion: reduce)').matches)throw new Error('theme/motion mismatch'); const page=document.querySelector('.memory-dashboard-page'); const table=page.querySelector('.table-wrap'); const audit={width:innerWidth,theme:'${theme}',motion:matchMedia('(prefers-reduced-motion: reduce)').matches,overflow:root.scrollWidth-root.clientWidth,tableOverflow:table?table.scrollWidth-table.clientWidth:0,selectorHeight:document.querySelector('#memory-corpus').getBoundingClientRect().height,searchHeight:document.querySelector('#memory-entry-query').getBoundingClientRect().height,accent:getComputedStyle(document.querySelector('.btn-danger')).color}; if(audit.overflow>1||audit.searchHeight>48)throw new Error('memory layout mismatch '+JSON.stringify(audit)); return audit })()" "layout-${width}-${theme}"
    ab screenshot "${EVIDENCE_ROOT}/memory-${width}-${theme}.png"
  done
done
ab set viewport 390 900
check "(() => { document.documentElement.style.zoom='2'; const s=document.querySelector('#memory-corpus'); s.scrollIntoView({block:'center'}); if(!s.checkVisibility())throw new Error('selector unreachable at 200% zoom'); return {zoom:getComputedStyle(document.documentElement).zoom,selector:s.getBoundingClientRect().toJSON(),overflow:document.documentElement.scrollWidth-document.documentElement.clientWidth} })()" zoom-dom
ab screenshot "${EVIDENCE_ROOT}/memory-390-zoom200.png"
check "(() => { document.documentElement.style.zoom='1'; return true })()" zoom-reset

ab a11y --selector '.memory-dashboard-page' --json >"${EVIDENCE_ROOT}/memory-a11y.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["success"] and d["data"]["counts"]["violations"]==0, d' "${EVIDENCE_ROOT}/memory-a11y.json"
ab --json network requests >"${EVIDENCE_ROOT}/network.json"
ab --json errors >"${EVIDENCE_ROOT}/browser-errors.json"
ab --json console >"${EVIDENCE_ROOT}/console.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert not d["data"]["errors"], d["data"]["errors"]' "${EVIDENCE_ROOT}/browser-errors.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert not [m for m in d["data"]["messages"] if str(m.get("type") or m.get("level") or "").lower() in {"error","severe"}], d["data"]["messages"]' "${EVIDENCE_ROOT}/console.json"

if [ "${COMPARE_WIREFRAMES}" -eq 1 ]; then
  WIREFRAME="${REPO_ROOT}/../dartclaw-private/docs/wireframes/memory-dashboard.html"
  test -f "${WIREFRAME}"
  agent-browser --session w7-wireframe open "file://${WIREFRAME}" >"${EVIDENCE_ROOT}/wireframe-open.log"
  for width in 375 390 768 1440; do
    agent-browser --session w7-wireframe set viewport "${width}" 900
    agent-browser --session w7-wireframe --json eval "(() => ({width:innerWidth,searchHeight:document.querySelector('#memory-query')?.getBoundingClientRect().height,selectorHeight:document.querySelector('#memory-corpus')?.getBoundingClientRect().height}))()" >"${EVIDENCE_ROOT}/wireframe-layout-${width}.json"
    agent-browser --session w7-wireframe screenshot "${EVIDENCE_ROOT}/wireframe-${width}.png"
  done
fi

rg -q 'Selected corpus unavailable' "${EVIDENCE_ROOT}/unavailable-response.html"
if rg -q 'owner-only marker|alpha-only marker|beta-only marker|removed-only marker' "${EVIDENCE_ROOT}/unavailable-response.html"; then
  echo 'unavailable selection revealed a private corpus marker' >&2
  exit 1
fi
jq -n --argjson compared "${COMPARE_WIREFRAMES}" '{case:"w7-memory-administration",result:"passed",assembledRuntime:true,disposablePostgres:true,wireframeComparison:$compared,checks:["default/A/B/retained/empty isolation","search/no-match","detail and dialog focus/cancel","browser edit and removal","stale API and browser revision rejection","cross-origin and forged selector denial","degraded and unavailable states","retained source persistence","375/390/768/1440 both themes","200% zoom and reduced motion","accessibility, network, console"]}' >"${EVIDENCE_ROOT}/browser-result.json"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
BASE_URL="${1:?base URL required}"
TEMPORARY_ID="${2:?live temporary session ID required}"
EVIDENCE_ROOT="${3:?evidence directory required}"
mkdir -p "$EVIDENCE_ROOT"
source "${SCRIPT_DIR}/visual_checks.sh"
SESSION="temporary-browser-${TEMPORARY_ID}"
WARNING_SESSION="temporary-warning-${TEMPORARY_ID}"
PROFILE="${EVIDENCE_ROOT}/browser-profile"
ab() { local session="$1"; shift; agent-browser --session "$session" "$@"; }
browser() { ab "$SESSION" "$@"; }
check() { browser eval "$1" >>"${EVIDENCE_ROOT}/assertions.log"; }
trap 'browser close >/dev/null 2>&1 || true; ab "$WARNING_SESSION" close >/dev/null 2>&1 || true' EXIT
TEMP_URL="${BASE_URL}/sessions/${TEMPORARY_ID}"
MARKER="temporary-browser-${TEMPORARY_ID}-draft"
FILE_MARKER="temporary-browser-${TEMPORARY_ID}-file"
FILE_MARKER_BASE64="$(python3 -c 'import base64,sys; print(base64.b64encode(sys.argv[1].encode()).decode())' "$FILE_MARKER")"
CONTROL="ordinary-browser-${TEMPORARY_ID}-draft"
printf '%s' "$FILE_MARKER" >"${EVIDENCE_ROOT}/temporary-file.txt"
ORDINARY_ID="$(curl --fail --silent --show-error -X POST "${BASE_URL}/api/sessions" -H 'Content-Type: application/json' -d '{}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
ORDINARY_URL="${BASE_URL}/sessions/${ORDINARY_ID}"

# One persistent browser profile makes the restart and ordinary-draft control meaningful.
browser --profile "$PROFILE" open "$ORDINARY_URL"
browser wait '#message-input'
browser fill '#message-input' "$CONTROL"
browser wait 700
browser reload
browser wait '#message-input'
check "(async()=>{const stop=Date.now()+5000;while(document.querySelector('#message-input').value!=='${CONTROL}'&&Date.now()<stop)await new Promise(r=>setTimeout(r,25));if(document.querySelector('#message-input').value!=='${CONTROL}')throw Error('ordinary draft positive control did not persist');return true})()"

STORAGE_SCAN="$(cat <<'JS'
(async () => {
  const records = [];
  async function flatten(value, path) {
    if (value instanceof Blob) { records.push([path, await value.text()]); return; }
    if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) {
      records.push([path, new TextDecoder().decode(value)]); return;
    }
    if (value && typeof value === 'object') {
      for (const [key, child] of Object.entries(value)) await flatten(child, path + '.' + key);
    } else records.push([path, String(value)]);
  }
  for (const [name, storage] of [['localStorage', localStorage], ['sessionStorage', sessionStorage]]) {
    for (let i = 0; i < storage.length; i++) {
      const key = storage.key(i); records.push([name + '.' + key, storage.getItem(key)]);
    }
  }
  for (const info of await indexedDB.databases()) {
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open(info.name);
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    try {
      for (const store of db.objectStoreNames) {
        const values = await new Promise((resolve, reject) => {
          const request = db.transaction(store, 'readonly').objectStore(store).getAll();
          request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
        });
        await flatten(values, 'indexedDB.' + info.name + '.' + store);
      }
    } finally { db.close(); }
  }
  for (const name of await caches.keys()) {
    const cache = await caches.open(name);
    for (const request of await cache.keys()) {
      records.push(['cache-url.' + name, request.url]);
      records.push(['cache-body.' + name, await (await cache.match(request)).text()]);
    }
  }
  const text = JSON.stringify(records);
  for (const marker of window.fixtureForbidden) {
    if (text.includes(marker)) throw Error('temporary bytes persisted: ' + marker);
  }
  if (!text.includes(window.fixtureControl)) throw Error('ordinary storage positive control missing');
  return { inspectedRecords: records.length, surfaces: records.map(([path]) => path), positiveControl: true };
})()
JS
)"
scan_storage() {
  check "window.fixtureForbidden=['${MARKER}','${FILE_MARKER}','${FILE_MARKER_BASE64}'];window.fixtureControl='${CONTROL}';true"
  check "$STORAGE_SCAN"
}
browser open "$TEMP_URL"
browser wait '#message-input'
check "(async()=>{const e=document.querySelector('[data-retention=process]');if(!e||e.getAttribute('hx-history')!=='false')throw Error('temporary HTMX snapshots enabled');for(const path of ['${TEMP_URL}','${BASE_URL}/api/sessions/${TEMPORARY_ID}/messages']){const r=await fetch(path);if(!r.ok||!r.headers.get('cache-control')?.includes('no-store'))throw Error('temporary response cacheable '+path)}return true})()"
browser fill '#message-input' "$MARKER"
browser upload '#composer-files' "${EVIDENCE_ROOT}/temporary-file.txt"
browser wait 700
check "(()=>{if(document.querySelector('#message-input').value!=='${MARKER}'||!document.body.textContent.includes('temporary-file.txt'))throw Error('temporary draft/file did not render');return true})()"
scan_storage

# HTMX swaps preserve the document. Full navigations below deliberately do not.
check "window.fixtureDocumentIdentity=crypto.randomUUID();window.fixtureOriginalIdentity=window.fixtureDocumentIdentity;htmx.ajax('GET','${ORDINARY_URL}',{target:'#main-content',swap:'outerHTML'});true"
browser wait "[data-session-id='${ORDINARY_ID}']"
check "htmx.ajax('GET','${TEMP_URL}',{target:'#main-content',swap:'outerHTML'});true"
browser wait "[data-session-id='${TEMPORARY_ID}']"
check "(()=>{if(window.fixtureDocumentIdentity!==window.fixtureOriginalIdentity||document.querySelector('#message-input').value!=='${MARKER}'||!document.body.textContent.includes('temporary-file.txt'))throw Error('same-document draft did not survive');return true})()"
scan_storage
browser tab new --label second "$TEMP_URL"
browser wait '#message-input'
check "(()=>{if(document.querySelector('#message-input').value||document.body.textContent.includes('temporary-file.txt'))throw Error('draft crossed tabs');return true})()"
scan_storage
browser tab t1
browser reload
browser wait '#message-input'
check "(()=>{if(document.querySelector('#message-input').value||document.body.textContent.includes('temporary-file.txt'))throw Error('draft survived reload');return true})()"
scan_storage
browser fill '#message-input' "$MARKER"
browser wait 700
browser open "$ORDINARY_URL"
browser back
browser wait '#message-input'
check "(()=>{if(document.querySelector('#message-input').value)throw Error('draft survived full history restoration');return true})()"
scan_storage
browser fill '#message-input' "$MARKER"
browser wait 700
browser tab close
browser tab new --label reopened "$TEMP_URL"
browser wait '#message-input'
check "(()=>{if(document.querySelector('#message-input').value)throw Error('draft survived tab close');return true})()"
browser fill '#message-input' "$MARKER"
browser wait 700
browser close
browser --profile "$PROFILE" open "$TEMP_URL"
browser wait '#message-input'
check "(()=>{if(document.querySelector('#message-input').value)throw Error('draft survived browser restart');return true})()"
scan_storage

ab "$WARNING_SESSION" --no-auto-dialog open "$TEMP_URL"
ab "$WARNING_SESSION" wait '#message-input'
ab "$WARNING_SESSION" fill '#message-input' "$MARKER"
ab "$WARNING_SESSION" eval 'setTimeout(()=>location.reload(),100);true'
sleep 0.2
ab "$WARNING_SESSION" --json dialog status >"${EVIDENCE_ROOT}/draft-loss-dialog.json"
python3 - "${EVIDENCE_ROOT}/draft-loss-dialog.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
data = result.get('data', result)
dialog = data.get('dialog', data)
if dialog.get('type') != 'beforeunload':
    raise SystemExit('destructive reload did not present a beforeunload warning')
PY
ab "$WARNING_SESSION" dialog dismiss
ab "$WARNING_SESSION" eval "(()=>{if(document.querySelector('#message-input').value!=='${MARKER}')throw Error('declining destructive navigation lost draft');return true})()" >>"${EVIDENCE_ROOT}/assertions.log"
ab "$WARNING_SESSION" eval 'setTimeout(()=>location.reload(),100);true'
sleep 0.2
ab "$WARNING_SESSION" dialog accept
ab "$WARNING_SESSION" wait '#message-input'
ab "$WARNING_SESSION" eval "(()=>{if(document.querySelector('#message-input').value)throw Error('accepted destructive reload restored draft');return true})()" >>"${EVIDENCE_ROOT}/assertions.log"
ab "$WARNING_SESSION" close

dialog_checks() {
  local opener="$1" dialog="$2"
  browser focus "$opener"
  browser press Enter
  browser wait "$dialog[open]"
  check "(()=>{const d=document.querySelector('${dialog}');if(!d.contains(document.activeElement)||!document.getElementById(d.getAttribute('aria-labelledby'))?.textContent.trim())throw Error('dialog focus/name missing');return true})()"
  for direction in Tab Shift+Tab; do
    for step in 1 2 3 4 5; do
      browser press "$direction"
      check "(()=>{if(!document.querySelector('${dialog}').contains(document.activeElement))throw Error('focus escaped dialog');return true})()"
    done
  done
  browser press Escape
  check "(()=>{if(document.querySelector('${dialog}').open||document.activeElement!==document.querySelector('${opener}'))throw Error('Escape/return focus failed');return true})()"
}
dialog_checks '[data-action="dc-chat#openTemporaryExport"]' '#temporary-export-dialog'
dialog_checks '[data-action="dc-chat#openTemporaryEnd"]' '#temporary-end-dialog'
browser click '[data-action="dc-chat#openTemporaryExport"]'
browser download '[data-action="dc-chat#exportTemporary"]' "${EVIDENCE_ROOT}/browser-export.md"
python3 - "${EVIDENCE_ROOT}/browser-export.md" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
for required in ('Temporary', 'attachment', 'not included'):
    if required.lower() not in text.lower():
        raise SystemExit(f'export missing disclosure: {required}')
if len(text.splitlines()) < 8:
    raise SystemExit('download has no readable transcript/manifest')
PY

for width in 375 390 768 1440; do
  for theme in dark light; do
    browser set viewport "$width" 900
    set_app_theme "$SESSION" "$theme"
    artifact="temporary-${width}-${theme}"
    check "(()=>{const root=document.querySelector('#main-content');if(document.documentElement.scrollWidth>innerWidth+1)throw Error('horizontal overflow');for(const e of root.querySelectorAll('.conversation-retention-controls button')){const r=e.getBoundingClientRect();if(r.width<44||r.height<44)throw Error('retention touch target below 44px');if(!e.textContent.trim()&&!e.getAttribute('aria-label'))throw Error('unlabelled control')}if(!matchMedia('(prefers-reduced-motion: reduce)').matches)throw Error('reduced motion inactive');return {width:innerWidth,theme:'${theme}'}})()"
    browser screenshot "${EVIDENCE_ROOT}/${artifact}.png"
    capture_accessibility "$SESSION" '#main-content' "${artifact}-a11y"
    assert_layout_canon "$SESSION" "$artifact"
    browser click '[data-action="dc-chat#openTemporaryExport"]'
    browser screenshot "${EVIDENCE_ROOT}/${artifact}-export-dialog.png"
    browser press Escape
  done
done

# Require an actual browser zoom change; CSS zoom and device scaling cannot close this row.
browser set viewport 1440 900
check 'window.fixtureZoomWidth=innerWidth;true'
browser press Control+0
for step in 1 2 3 4 5; do browser press Control+plus; done
check "(()=>{const factor=window.fixtureZoomWidth/innerWidth;if(factor<1.95||factor>2.05)throw Error('browser did not reach 200% zoom: '+factor);if(document.documentElement.scrollWidth>innerWidth+1)throw Error('overflow at 200% zoom');return {zoom:factor}})()"
browser screenshot "${EVIDENCE_ROOT}/temporary-200-percent-browser-zoom.png"
browser press Control+0
browser console >"${EVIDENCE_ROOT}/console.log"
browser errors >"${EVIDENCE_ROOT}/browser-errors.log"
browser network requests >"${EVIDENCE_ROOT}/network.log"
scan_storage

# Create/end flow gets its own conversation so the caller's provider lifetime row remains live.
browser open "$ORDINARY_URL"
browser wait '[data-action="dc-chat#openTemporaryCreate"]'
dialog_checks '[data-action="dc-chat#openTemporaryCreate"]' '#temporary-create-dialog'
browser click '[data-action="dc-chat#openTemporaryCreate"]'
browser click '[data-action="dc-chat#createTemporary"]'
browser wait '[data-retention="process"]'
check "window.fixtureEndId=document.querySelector('[data-retention=process]').dataset.sessionId;if(window.fixtureEndId==='${TEMPORARY_ID}')throw Error('create reused temporary authority');true"
browser fill '#message-input' "$MARKER"
browser wait 700
check "(()=>{window.fixtureFetch=window.fetch;window.fetch=(url,options)=>String(url).endsWith('/end-temporary')?new Promise(resolve=>{window.fixtureEndResponse=resolve}):window.fixtureFetch(url,options);return true})()"
browser click '[data-action="dc-chat#openTemporaryEnd"]'
browser wait '#temporary-end-dialog[open]'
browser click '[data-action="dc-chat#endTemporary"]'
check "(()=>{const text=document.querySelector('[data-temporary-state]').textContent;if(!text.includes('Ending'))throw Error('missing Ending');if([...document.querySelectorAll('.conversation-retention-controls button')].some(e=>!e.disabled))throw Error('Ending controls still active');window.fixtureEndResponse(new Response(JSON.stringify({error:{message:'termination unconfirmed'}}),{status:503,headers:{'content-type':'application/json'}}));return true})()"
browser wait 100
check "(()=>{if(!document.querySelector('[data-temporary-state]').textContent.includes('End failed'))throw Error('unconfirmed termination claimed success');window.fetch=window.fixtureFetch;return true})()"
browser screenshot "${EVIDENCE_ROOT}/temporary-end-failed.png"
browser click '[data-action="dc-chat#openTemporaryEnd"]'
browser wait '#temporary-end-dialog[open]'
browser click '[data-action="dc-chat#endTemporary"]'
browser wait '[data-action="dc-chat#openTemporaryCreate"]'
scan_storage

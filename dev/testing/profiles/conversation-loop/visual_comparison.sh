#!/usr/bin/env bash

set_app_theme() {
  local session="$1" theme="$2" desired
  case "$theme" in
    dark) desired="" ;;
    light) desired="light" ;;
    *) echo "unsupported app theme: ${theme}" >&2; return 2 ;;
  esac
  ab "$session" set media "$theme" reduced-motion
  ab "$session" eval "(async () => { const desired='${desired}'; const root=document.documentElement; if((root.dataset.theme||'')!==desired){ const toggle=document.querySelector('.theme-toggle'); if(!toggle)throw new Error('theme toggle missing'); toggle.click(); } if((root.dataset.theme||'')!==desired)throw new Error('app theme did not become ${theme}'); if(!matchMedia('(prefers-reduced-motion: reduce)').matches)throw new Error('reduced motion inactive'); await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame); return {theme:desired||'dark',datasetTheme:root.dataset.theme||'',reducedMotion:true}; })()"
}

capture_wireframe() {
  local wireframe="$1" artifact="${2:-$1}" width="${3:-1440}" theme="${4:-dark}" dialog="${5:-}"
  agent-browser --session conversation-wire --allow-file-access open "file://${REPO_ROOT}/dev/bundle/docs/wireframes/${wireframe}.html"
  agent-browser --session conversation-wire eval "(() => { const expected=['tokens.css','components.css','icons.css']; const links=[...document.querySelectorAll('link[rel=stylesheet]')]; for(const name of expected){ const link=links.find(item=>new URL(item.href).pathname.endsWith('/dev/design-system/'+name)); if(!link?.sheet || link.sheet.cssRules.length===0)throw new Error('wireframe stylesheet unavailable: '+name); } if(!getComputedStyle(document.documentElement).getPropertyValue('--bg-base').trim())throw new Error('wireframe design tokens were not applied'); return expected; })()"
  agent-browser --session conversation-wire set viewport "$width" 900
  set_app_theme conversation-wire "$theme"
  if [ -n "$dialog" ]; then
    agent-browser --session conversation-wire eval "document.querySelector('${dialog}').showModal(); true"
  fi
  agent-browser --session conversation-wire screenshot "${EVIDENCE_ROOT}/wireframe-${artifact}.png"
}

compare_session_to_wireframe() {
  local session="$1" artifact="$2" max_mismatch_percent="${3:-20}"
  local result="${EVIDENCE_ROOT}/wireframe-${artifact}-comparison.json"
  ab "${session}" --json diff screenshot \
    --baseline "${EVIDENCE_ROOT}/wireframe-${artifact}.png" \
    --threshold 0.1 \
    --output "${EVIDENCE_ROOT}/wireframe-${artifact}-diff.png" >"${result}"
  python3 - "${result}" "${max_mismatch_percent}" <<'PY'
import json
import math
import sys

def find(value, key):
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for nested in value.values():
            found = find(nested, key)
            if found is not None:
                return found
    if isinstance(value, list):
        for nested in value:
            found = find(nested, key)
            if found is not None:
                return found
    return None

path, maximum = sys.argv[1], float(sys.argv[2])
with open(path, encoding='utf-8') as handle:
    result = json.load(handle)
if find(result, 'dimensionMismatch') is True:
    raise SystemExit(f'{path}: compared screenshots have different dimensions')
mismatch = find(result, 'mismatchPercentage')
different = find(result, 'differentPixels')
total = find(result, 'totalPixels')
if not isinstance(mismatch, (int, float)) or not math.isfinite(mismatch):
    raise SystemExit(f'{path}: missing numeric mismatchPercentage')
if not isinstance(different, int) or not isinstance(total, int) or total <= 0:
    raise SystemExit(f'{path}: missing valid pixel counts')
if not 0 <= different <= total or not 0 <= mismatch <= 100:
    raise SystemExit(f'{path}: invalid pixel counts or mismatch percentage')
if abs(mismatch - 100 * different / total) > 0.1:
    raise SystemExit(f'{path}: percentage disagrees with pixel counts')
if mismatch > maximum:
    raise SystemExit(f'{path}: mismatch {mismatch:.3f}% exceeds {maximum:.3f}%')
PY
}

compare_current_to_wireframe() {
  compare_session_to_wireframe conversation-origin "$@"
}

check_accessibility_report() {
  python3 - "$1" <<'PYTHON'
import json
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as handle:
    report = json.load(handle)
if not isinstance(report, dict) or report.get('success') is not True:
    raise SystemExit(f'{path}: accessibility audit did not succeed')
data = report.get('data')
if not isinstance(data, dict):
    raise SystemExit(f'{path}: missing accessibility report')
counts = data.get('counts')
for key in ('violations', 'incomplete'):
    entries = data.get(key)
    if (not isinstance(entries, list) or not isinstance(counts, dict)
            or type(counts.get(key)) is not int or counts[key] != len(entries)):
        raise SystemExit(f'{path}: malformed accessibility {key}')
    if entries:
        raise SystemExit(f'{path}: {len(entries)} accessibility {key}; inspect retained report')
PYTHON
}

capture_accessibility() {
  local session="$1" selector="$2" artifact="$3"
  local report="${EVIDENCE_ROOT}/${artifact}.json"
  ab "$session" a11y --selector "$selector" --json >"$report"
  check_accessibility_report "$report"
}

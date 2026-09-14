#!/usr/bin/env bash

capture_wireframe() {
  local wireframe="$1" artifact="${2:-$1}" width="${3:-1440}" theme="${4:-dark}" dialog="${5:-}"
  agent-browser --session conversation-wire --allow-file-access open "file://${REPO_ROOT}/dev/bundle/docs/wireframes/${wireframe}.html"
  agent-browser --session conversation-wire set viewport "$width" 900
  agent-browser --session conversation-wire set media "$theme" reduced-motion
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

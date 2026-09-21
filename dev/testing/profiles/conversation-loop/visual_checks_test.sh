#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../../.." && pwd)"
mkdir -p "${repo_root}/.agent_temp"
test_dir="$(mktemp -d "${repo_root}/.agent_temp/accessibility-report-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
source "${script_dir}/visual_checks.sh"

python3 - "$test_dir" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
valid = {'success': True, 'data': {'counts': {'violations': 0, 'incomplete': 0}, 'violations': [], 'incomplete': []}}
(root / 'valid.json').write_text(json.dumps(valid))
for key in ('violations', 'incomplete'):
    report = json.loads(json.dumps(valid))
    report['data'][key] = [{'id': 'button-name'}]
    report['data']['counts'][key] = 1
    (root / (key + '.json')).write_text(json.dumps(report))
for name, report in [('unsuccessful', {'success': False}), ('missing', {'success': True, 'data': {}}),
                     ('inconsistent', {'success': True, 'data': {'counts': {'violations': 1, 'incomplete': 0}, 'violations': [], 'incomplete': []}})]:
    (root / (name + '.json')).write_text(json.dumps(report))
(root / 'malformed.json').write_text('{')

# The one exempt incomplete, and the mixed case that must stay a failure: a
# single node axe could actually judge is enough to fail the whole entry.
unresolvable = 'Fix any of the following:\n  Element\'s background color could not be determined'
judged = 'Fix any of the following:\n  Element has insufficient color contrast of 2.1:1'
for name, summaries in [('exempt', [unresolvable, unresolvable]), ('mixed', [unresolvable, judged])]:
    report = json.loads(json.dumps(valid))
    report['data']['incomplete'] = [
        {'id': 'color-contrast', 'nodes': [{'failureSummary': s} for s in summaries]}
    ]
    report['data']['counts']['incomplete'] = 1
    (root / (name + '.json')).write_text(json.dumps(report))

# A needs-review aria-controls incomplete: exempt only when the same-page idref
# capture resolves its referenced id to true.
aria_reason = 'Unable to determine if aria-controls referenced ID exists on the page: aria-controls="popover-1"'
report = json.loads(json.dumps(valid))
report['data']['incomplete'] = [
    {'id': 'aria-valid-attr-value', 'nodes': [{'failureSummary': 'Fix any of the following:\n  ' + aria_reason}]}
]
report['data']['counts']['incomplete'] = 1
(root / 'aria.json').write_text(json.dumps(report))
PY
EVIDENCE_ROOT="$test_dir"
audit_fixture="${test_dir}/valid.json"
# capture_accessibility makes two ab calls: "a11y ... --json" (the audit report,
# selected by $audit_fixture) and "eval ..." (the same-page idref map, selected
# by $idref_json). An empty map is a valid capture for every fixture below,
# since none of them carry an aria-controls incomplete.
idref_json='{}'
ab() {
  if [ "$2" = "eval" ]; then
    printf '%s' "$idref_json"
  else
    cat "$audit_fixture"
  fi
}
# check_accessibility_report writes the idref capture back into the report as
# data.ariaControls whenever it reads far enough to parse one, so a captured
# report matches its fixture either verbatim (rejected before that point) or
# with that one field added (rejected after, or accepted).
assert_captured_matches_fixture() {
  local fixture="$1" captured="$2"
  python3 - "$fixture" "$captured" "$idref_json" <<'PY'
import json
import sys

fixture_path, captured_path, idref_json = sys.argv[1:4]
with open(fixture_path, encoding='utf-8') as handle:
    fixture_text = handle.read()
with open(captured_path, encoding='utf-8') as handle:
    captured_text = handle.read()
if captured_text == fixture_text:
    sys.exit(0)
try:
    fixture = json.loads(fixture_text)
    captured = json.loads(captured_text)
except ValueError:
    raise SystemExit(f'{captured_path}: does not match {fixture_path}')
data = fixture.get('data') if isinstance(fixture, dict) else None
if isinstance(data, dict):
    data['ariaControls'] = json.loads(idref_json)
if captured != fixture:
    raise SystemExit(f'{captured_path}: does not match {fixture_path}, with or without an added ariaControls capture')
PY
}
capture_accessibility test-session '#main-content' captured
assert_captured_matches_fixture "$audit_fixture" "${test_dir}/captured.json"
for invalid in violations incomplete unsuccessful missing inconsistent malformed mixed; do
  audit_fixture="${test_dir}/${invalid}.json"
  if capture_accessibility test-session '#main-content' captured >"${test_dir}/output" 2>&1; then
    echo "accessibility gate accepted ${invalid}" >&2
    exit 1
  fi
  assert_captured_matches_fixture "$audit_fixture" "${test_dir}/captured.json"
done
audit_fixture="${test_dir}/exempt.json"
capture_accessibility test-session '#main-content' captured >"${test_dir}/output" 2>&1
grep -q '2 contrast node(s) exempt' "${test_dir}/output" || {
  echo 'exempt report did not report its exempt node count' >&2
  exit 1
}

audit_fixture="${test_dir}/aria.json"
idref_json='{"popover-1": true}'
capture_accessibility test-session '#main-content' captured >"${test_dir}/output" 2>&1
grep -q '1 aria-controls node(s) exempt' "${test_dir}/output" || {
  echo 'aria-controls exempt report did not report its exempt node count' >&2
  exit 1
}

idref_json='{"popover-1": false}'
if capture_accessibility test-session '#main-content' captured >"${test_dir}/output" 2>&1; then
  echo 'accessibility gate accepted an unresolved aria-controls reference' >&2
  exit 1
fi
grep -q 'neither an unresolvable background nor an aria-controls reference' "${test_dir}/output" || {
  echo 'unresolved aria-controls reference did not fail with the expected message' >&2
  exit 1
}

idref_json=''
if capture_accessibility test-session '#main-content' captured >"${test_dir}/output" 2>&1; then
  echo 'accessibility gate accepted an unparseable idref capture' >&2
  exit 1
fi
grep -Eq 'unreadable aria-controls idref capture|malformed aria-controls idref capture' "${test_dir}/output" || {
  echo 'unparseable idref capture did not fail with the expected message' >&2
  exit 1
}

echo 'Accessibility report gate: valid, exempt and aria-controls-resolved accepted; seven invalid reports, an unresolved aria-controls reference and a bad idref capture rejected'

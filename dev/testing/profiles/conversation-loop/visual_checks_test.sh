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
PY
EVIDENCE_ROOT="$test_dir"
audit_fixture="${test_dir}/valid.json"
ab() { cat "$audit_fixture"; }
capture_accessibility test-session '#main-content' captured
cmp "$audit_fixture" "${test_dir}/captured.json"
for invalid in violations incomplete unsuccessful missing inconsistent malformed mixed; do
  audit_fixture="${test_dir}/${invalid}.json"
  if capture_accessibility test-session '#main-content' captured >"${test_dir}/output" 2>&1; then
    echo "accessibility gate accepted ${invalid}" >&2
    exit 1
  fi
  cmp "$audit_fixture" "${test_dir}/captured.json"
done
audit_fixture="${test_dir}/exempt.json"
capture_accessibility test-session '#main-content' captured >"${test_dir}/output" 2>&1
grep -q '2 contrast node(s) exempt' "${test_dir}/output" || {
  echo 'exempt report did not report its exempt node count' >&2
  exit 1
}
echo 'Accessibility report gate: valid and exempt accepted; seven invalid reports rejected'

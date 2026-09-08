#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
tool=(dart run "$repo_root/dev/tools/contract_groups_check.dart")

cat >"$tmp_dir/manifest.json" <<'JSON'
{"shared":["a"],"sqlite":["b"],"postgres":["c"]}
JSON

cat >"$tmp_dir/success.json" <<'JSON'
{"type":"testStart","test":{"id":1,"name":"suite [contract:a] works","metadata":{"skip":false}}}
{"type":"testDone","testID":1,"result":"success","skipped":false,"hidden":false}
{"type":"testStart","test":{"id":2,"name":"suite [contract:b] works","metadata":{"skip":false}}}
{"type":"testDone","testID":2,"result":"success","skipped":false,"hidden":false}
{"type":"testStart","test":{"id":3,"name":"hidden setup","metadata":{"skip":false}}}
{"type":"testDone","testID":3,"result":"success","skipped":false,"hidden":true}
{"type":"done","success":true}
JSON

"${tool[@]}" --manifest "$tmp_dir/manifest.json" --expect shared,sqlite --report "$tmp_dir/success.json" >/dev/null

expect_failure() {
  local expected="$1"
  shift
  if "$@" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
    echo "expected failure containing: $expected" >&2
    exit 1
  fi
  rg -q "$expected" "$tmp_dir/stderr"
}

cat >"$tmp_dir/missing.json" <<'JSON'
{"type":"testStart","test":{"id":1,"name":"[contract:a] works","metadata":{"skip":false}}}
{"type":"testDone","testID":1,"result":"success","skipped":false,"hidden":false}
{"type":"done","success":true}
JSON
expect_failure "missing: b" "${tool[@]}" --manifest "$tmp_dir/manifest.json" --expect shared,sqlite --report "$tmp_dir/missing.json"

cat >"$tmp_dir/failed.json" <<'JSON'
{"type":"testStart","test":{"id":1,"name":"[contract:a] fails","metadata":{"skip":false}}}
{"type":"testDone","testID":1,"result":"failure","skipped":false,"hidden":false}
{"type":"done","success":true}
JSON
expect_failure "failed or skipped: a" "${tool[@]}" --manifest "$tmp_dir/manifest.json" --expect shared --report "$tmp_dir/failed.json"

cat >"$tmp_dir/skipped.json" <<'JSON'
{"type":"testStart","test":{"id":1,"name":"[contract:a] skips","metadata":{"skip":"reason"}}}
{"type":"testDone","testID":1,"result":"success","skipped":true,"hidden":false}
{"type":"done","success":true}
JSON
expect_failure "failed or skipped: a" "${tool[@]}" --manifest "$tmp_dir/manifest.json" --expect shared --report "$tmp_dir/skipped.json"

cat >"$tmp_dir/unregistered.json" <<'JSON'
{"type":"testStart","test":{"id":1,"name":"[contract:z] unknown","metadata":{"skip":false}}}
{"type":"testDone","testID":1,"result":"success","skipped":false,"hidden":false}
{"type":"done","success":true}
JSON
expect_failure "unregistered: z" "${tool[@]}" --manifest "$tmp_dir/manifest.json" --expect shared --report "$tmp_dir/unregistered.json"

cat >"$tmp_dir/real_omission_test.dart" <<'DART'
import 'package:test/test.dart';

void main() {
  group('[contract:z] undeclared manifest group', () {
    test('runs as an actual contract declaration', () {});
  });
}
DART
(cd "$repo_root/packages/dartclaw_core" && dart test "$tmp_dir/real_omission_test.dart" --reporter json) \
  | rg -o '\{.*$' >"$tmp_dir/real_omission.json"
expect_failure "unregistered: z" "${tool[@]}" \
  --manifest "$tmp_dir/manifest.json" --expect shared --report "$tmp_dir/real_omission.json"

cat >"$tmp_dir/dangling.json" <<'JSON'
{"type":"testStart","test":{"id":1,"name":"[contract:a] works","metadata":{"skip":false}}}
{"type":"testDone","testID":1,"result":"success","skipped":false,"hidden":false}
{"type":"testStart","test":{"id":2,"name":"[contract:a] truncated","metadata":{"skip":false}}}
{"type":"done","success":true}
JSON
expect_failure "Unmatched testStart ids" "${tool[@]}" \
  --manifest "$tmp_dir/manifest.json" --expect shared --report "$tmp_dir/dangling.json"

cat >"$tmp_dir/no_terminal.json" <<'JSON'
{"type":"testStart","test":{"id":1,"name":"[contract:a] works","metadata":{"skip":false}}}
{"type":"testDone","testID":1,"result":"success","skipped":false,"hidden":false}
JSON
expect_failure "no successful terminal done" "${tool[@]}" \
  --manifest "$tmp_dir/manifest.json" --expect shared --report "$tmp_dir/no_terminal.json"

cat >"$tmp_dir/unsuccessful_terminal.json" <<'JSON'
{"type":"testStart","test":{"id":1,"name":"[contract:a] works","metadata":{"skip":false}}}
{"type":"testDone","testID":1,"result":"success","skipped":false,"hidden":false}
{"type":"done","success":false}
JSON
expect_failure "terminal done was not successful" "${tool[@]}" \
  --manifest "$tmp_dir/manifest.json" --expect shared --report "$tmp_dir/unsuccessful_terminal.json"

cat >"$tmp_dir/double.json" <<'JSON'
{"shared":["a"],"sqlite":["a"],"postgres":[]}
JSON
expect_failure "classified more than once: a" "${tool[@]}" --manifest "$tmp_dir/double.json" --expect shared --report "$tmp_dir/failed.json"

: >"$tmp_dir/empty.json"
expect_failure "Report is empty" "${tool[@]}" --manifest "$tmp_dir/manifest.json" --expect shared --report "$tmp_dir/empty.json"
expect_failure "does not exist" "${tool[@]}" --manifest "$tmp_dir/manifest.json" --expect shared --report "$tmp_dir/absent.json"

printf '{broken\n' >"$tmp_dir/malformed.json"
expect_failure "Malformed JSON" "${tool[@]}" --manifest "$tmp_dir/manifest.json" --expect shared --report "$tmp_dir/malformed.json"
expect_failure "Unknown --expect set" "${tool[@]}" --manifest "$tmp_dir/manifest.json" --expect missing --report "$tmp_dir/failed.json"

echo "contract_groups_check_test: PASS"

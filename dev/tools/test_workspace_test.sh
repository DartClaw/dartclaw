#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$root/.agent_temp"
fixture="$(mktemp -d "$root/.agent_temp/test-workspace.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/dev/tools" "$fixture/dev/fitness/test" "$fixture/app/test"
cp "$root/dev/tools/test_workspace.sh" "$fixture/dev/tools/"

# The selector owns which members run. The nested developer-tool suites have their own proofs.
printf '#!/bin/sh\nexit 0\n' > "$fixture/bin/bash"
cat > "$fixture/bin/dart" <<'SH'
#!/bin/sh
case "$1" in
  run) exit 0 ;;
  pub)
    printf 'Package Path\nworkspace ./\nfitness dev/fitness/\n'
    [ -z "${DISCOVERY_ERROR:-}" ] || exit 42
    printf 'app app/\n'
    ;;
  test)
    echo "${PWD##*/}" >> "$WORKSPACE_TEST_MEMBERS"
    [ -z "${MEMBER_ERROR:-}" ] || exit 37
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fixture/bin/bash" "$fixture/bin/dart"
export PATH="$fixture/bin:$PATH" WORKSPACE_TEST_MEMBERS="$fixture/members"

expect_run() {
  local expected_status="$1" expected_members="$2" status=0
  shift 2
  : > "$WORKSPACE_TEST_MEMBERS"
  "$BASH" "$fixture/dev/tools/test_workspace.sh" "$@" > "$fixture/output" 2>&1 || status=$?
  if [[ "$status" != "$expected_status" || "$(< "$WORKSPACE_TEST_MEMBERS")" != "$expected_members" ]]; then
    cat "$fixture/output" "$WORKSPACE_TEST_MEMBERS" >&2
    echo "Expected exit $expected_status and members [$expected_members], got exit $status" >&2
    exit 1
  fi
}

expect_run 0 $'fitness\napp'
expect_run 0 app --separate-fitness
expect_run 2 '' --unknown
DISCOVERY_ERROR=1 expect_run 42 ''
MEMBER_ERROR=1 expect_run 37 fitness
echo 'test_workspace_test: PASS'

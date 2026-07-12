#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
TOOL="$ROOT_DIR/dev/tools/parallels_windows.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dartclaw-parallels-test.XXXXXX")"
PROJECT_TEST_DIR="$ROOT_DIR/.agent_temp/parallels-test-$$"
FAKE_PRLCTL="$TEST_DIR/prlctl"
LOG_FILE="$TEST_DIR/prlctl.log"

cleanup() {
  rm -rf "$TEST_DIR"
  rm -rf "$PROJECT_TEST_DIR"
}
trap cleanup EXIT INT TERM

cat > "$FAKE_PRLCTL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command_name="$1"
shift

{
  printf '%s' "$command_name"
  printf '\t%s' "$@"
  printf '\n'
} >> "$PARALLELS_TEST_LOG"

case "$command_name" in
  status) printf 'VM %s exist %s\n' "$1" "${PARALLELS_TEST_STATE:-paused}" ;;
  exec)
    if [[ " $* " != *' exit 0 '* && -n "${PARALLELS_TEST_EXEC_FAILURE:-}" ]]; then
      exit 42
    elif [[ " $* " == *' whoami '* ]]; then
      printf 'test\\user\n'
    fi
    ;;
esac
EOF
chmod 755 "$FAKE_PRLCTL"

run_tool() {
  : > "$LOG_FILE"
  PARALLELS_PRLCTL="$FAKE_PRLCTL" \
    PARALLELS_WINDOWS_VM="Test VM" \
    PARALLELS_TEST_LOG="$LOG_FILE" \
    PARALLELS_TEST_STATE="${PARALLELS_TEST_STATE:-paused}" \
    bash "$TOOL" "$@"
}

assert_log() {
  local expected="$1"
  local expected_file="$TEST_DIR/expected.log"
  printf '%s\n' "$expected" > "$expected_file"
  diff -u "$expected_file" "$LOG_FILE"
}

run_tool status >/dev/null
assert_log $'status\tTest VM'

run_tool exec cmd.exe /d /c whoami >/dev/null
assert_log $'status\tTest VM\nresume\tTest VM\nexec\tTest VM\t--current-user\tcmd.exe\t/d\t/c\texit\t0\nexec\tTest VM\t--current-user\tcmd.exe\t/d\t/c\twhoami'

run_tool exec cmd.exe /d /c "echo spaced value" >/dev/null
assert_log $'status\tTest VM\nresume\tTest VM\nexec\tTest VM\t--current-user\tcmd.exe\t/d\t/c\texit\t0\nexec\tTest VM\t--current-user\tcmd.exe\t/d\t/c\techo spaced value'

run_tool exec-system cmd.exe /d /c whoami >/dev/null
assert_log $'status\tTest VM\nresume\tTest VM\nexec\tTest VM\tcmd.exe\t/d\t/c\texit\t0\nexec\tTest VM\tcmd.exe\t/d\t/c\twhoami'

mkdir -p "$PROJECT_TEST_DIR/scripts with spaces"
probe="$PROJECT_TEST_DIR/scripts with spaces/probe file.ps1"
printf 'Write-Output "ok"\n' > "$probe"
probe_relative="${probe#"$ROOT_DIR/"}"
run_tool powershell "$probe_relative" argument >/dev/null
probe_absolute="$(cd "$(dirname "$probe")" && pwd -P)/$(basename "$probe")"
assert_log "$(printf '%s' $'status\tTest VM\nresume\tTest VM\nexec\tTest VM\t--current-user\tcmd.exe\t/d\t/c\texit\t0\nexec\tTest VM\t-r\t--current-user\tpowershell.exe\t-NoLogo\t-NoProfile\t-NonInteractive\t-ExecutionPolicy\tBypass\t-File\t')$probe_absolute"$'\targument'

run_tool powershell-system "$probe" "spaced argument" >/dev/null
assert_log "$(printf '%s' $'status\tTest VM\nresume\tTest VM\nexec\tTest VM\tcmd.exe\t/d\t/c\texit\t0\nexec\tTest VM\t-r\tpowershell.exe\t-NoLogo\t-NoProfile\t-NonInteractive\t-ExecutionPolicy\tBypass\t-File\t')$probe_absolute"$'\tspaced argument'

: > "$LOG_FILE"
if run_tool delete >/dev/null 2>&1; then
  printf 'Expected destructive command to be rejected\n' >&2
  exit 1
fi
[[ ! -s "$LOG_FILE" ]]

PARALLELS_TEST_STATE=stopped run_tool start >/dev/null
assert_log $'status\tTest VM\nstart\tTest VM\nexec\tTest VM\tcmd.exe\t/d\t/c\texit\t0'

PARALLELS_TEST_STATE=running run_tool start >/dev/null
assert_log $'status\tTest VM\nexec\tTest VM\tcmd.exe\t/d\t/c\texit\t0'

PARALLELS_TEST_STATE=suspended run_tool start >/dev/null
assert_log $'status\tTest VM\nresume\tTest VM\nexec\tTest VM\tcmd.exe\t/d\t/c\texit\t0'

capture_path="$TEST_DIR/capture file.png"
run_tool capture "$capture_path" >/dev/null
assert_log "$(printf '%s' $'status\tTest VM\nresume\tTest VM\nexec\tTest VM\tcmd.exe\t/d\t/c\texit\t0\ncapture\tTest VM\t--file\t')$capture_path"

run_tool snapshot "checkpoint with spaces" >/dev/null
assert_log $'status\tTest VM\nresume\tTest VM\nexec\tTest VM\tcmd.exe\t/d\t/c\texit\t0\nsnapshot\tTest VM\t--name\tcheckpoint with spaces'

run_tool snapshots >/dev/null
assert_log $'snapshot-list\tTest VM\t--json'

PARALLELS_TEST_STATE=running run_tool pause >/dev/null
assert_log $'status\tTest VM\npause\tTest VM'

PARALLELS_TEST_STATE=paused run_tool pause >/dev/null
assert_log $'status\tTest VM'

if PARALLELS_TEST_STATE=unknown run_tool start >/dev/null 2>&1; then
  printf 'Expected unsupported VM state to be rejected\n' >&2
  exit 1
fi
assert_log $'status\tTest VM'

if PARALLELS_PRLCTL="$TEST_DIR/missing" PARALLELS_WINDOWS_VM="Test VM" bash "$TOOL" status >/dev/null 2>&1; then
  printf 'Expected missing prlctl to be rejected\n' >&2
  exit 1
fi

if PARALLELS_TEST_EXEC_FAILURE=1 run_tool exec cmd.exe /d /c fail >/dev/null 2>&1; then
  printf 'Expected guest command failure to propagate\n' >&2
  exit 1
fi

printf 'parallels_windows_test: PASS\n'

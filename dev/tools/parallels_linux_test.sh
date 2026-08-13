#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
TOOL="$ROOT_DIR/dev/tools/parallels_linux.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dartclaw-parallels-linux-test.XXXXXX")"
FAKE_PRLCTL="$TEST_DIR/prlctl"
FAKE_SSH="$TEST_DIR/ssh"
LOG_FILE="$TEST_DIR/transport.log"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM

cat > "$FAKE_PRLCTL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command_name="$1"
shift
{
  printf 'prlctl\t%s' "$command_name"
  printf '\t%s' "$@"
  printf '\n'
} >> "$PARALLELS_TEST_LOG"

case "$command_name" in
  status)
    printf 'VM %s exist %s\n' "$1" "${PARALLELS_TEST_STATE:-paused}"
    ;;
  list)
    printf '%s\n' "${PARALLELS_TEST_IP:-192.0.2.10}"
    ;;
  exec)
    shift
    if [[ "$1" == /bin/bash && "$2" == -s ]]; then
      program="$(mktemp "${TMPDIR:-/tmp}/dartclaw-parallels-program.XXXXXX")"
      changed="$program.changed"
      trap 'rm -f "$program" "$changed"' EXIT
      cat > "$program"
      sed 's#/usr/bin/sha256sum#'"$(command -v sha256sum)"'#g' "$program" > "$changed"
      mv "$changed" "$program"
      if [[ -n "${PARALLELS_TEST_TAMPER_UPLOAD:-}" ]]; then
        sed 's/^expected_sha256=.*/expected_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
          "$program" > "$changed"
        mv "$changed" "$program"
      fi
      set +e
      /bin/bash "$program"
      status=$?
      set -e
      exit "$status"
    fi
    ;;
esac
EOF
chmod 755 "$FAKE_PRLCTL"

cat > "$FAKE_SSH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'ssh'
  printf '\t%s' "$@"
  printf '\n'
} >> "$PARALLELS_TEST_LOG"

while [[ "${1:-}" == -o ]]; do
  shift 2
done
shift

remote_command="$*"
if [[ "$remote_command" == /usr/bin/true ]]; then
  exit 0
fi

if [[ "$remote_command" == '/bin/bash -s' ]]; then
  program="$(mktemp "${TMPDIR:-/tmp}/dartclaw-parallels-ssh-program.XXXXXX")"
  changed="$program.changed"
  trap 'rm -f "$program" "$changed"' EXIT
  cat > "$program"
  sed 's#/usr/bin/sha256sum#'"$(command -v sha256sum)"'#g' "$program" > "$changed"
  mv "$changed" "$program"
  set +e
  /bin/bash "$program"
  status=$?
  set -e
  exit "$status"
fi

set +e
/bin/bash -c "$remote_command"
status=$?
set -e
exit "$status"
EOF
chmod 755 "$FAKE_SSH"

run_tool() {
  : > "$LOG_FILE"
  PARALLELS_PRLCTL="$FAKE_PRLCTL" \
    PARALLELS_SSH="$FAKE_SSH" \
    PARALLELS_LINUX_VM="Test VM" \
    PARALLELS_LINUX_USER="guest user" \
    PARALLELS_TEST_LOG="$LOG_FILE" \
    PARALLELS_TEST_STATE="${PARALLELS_TEST_STATE:-paused}" \
    PARALLELS_TEST_TAMPER_UPLOAD="${PARALLELS_TEST_TAMPER_UPLOAD:-}" \
    bash "$TOOL" "$@"
}

assert_log() {
  local expected="$1"
  local expected_file="$TEST_DIR/expected.log"
  printf '%s\n' "$expected" > "$expected_file"
  diff -u "$expected_file" "$LOG_FILE"
}

assert_contains() {
  local text="$1"
  local expected="$2"
  if [[ "$text" != *"$expected"* ]]; then
    printf 'Expected text to contain: %s\n' "$expected" >&2
    exit 1
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

list_stage_dirs() {
  local path
  for path in /tmp/dartclaw-guest.*; do
    [[ -d "$path" ]] && printf '%s\n' "$path"
  done
  return 0
}

mkdir -p "$TEST_DIR/guest commands"
ARGV_PROBE="$TEST_DIR/guest commands/argv probe.sh"
cat > "$ARGV_PROBE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
expected="$1"
shift
actual="$(mktemp "${TMPDIR:-/tmp}/dartclaw-argv.XXXXXX")"
trap 'rm -f "$actual"' EXIT
printf '%s\0' "$@" > "$actual"
cmp "$expected" "$actual"
EOF
chmod 755 "$ARGV_PROBE"

EXIT_PROBE="$TEST_DIR/guest commands/exit probe.sh"
cat > "$EXIT_PROBE" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod 755 "$EXIT_PROBE"

edge_args=(
  'spaced value'
  ''
  "single'quote"
  '"double quote"'
  "; \$HOME & | < > ( ) { } * ?"
  '{"name":"DartClaw","items":[1,2]}'
  'Grüße 世界'
  $'line one\nline two'
)
EXPECTED_ARGV="$TEST_DIR/expected.argv"
printf '%s\0' "${edge_args[@]}" > "$EXPECTED_ARGV"

run_tool exec "$ARGV_PROBE" "$EXPECTED_ARGV" "${edge_args[@]}"
assert_contains "$(< "$LOG_FILE")" $'ssh\t-o\tBatchMode=yes\t-o\tConnectTimeout=5\t-o\tStrictHostKeyChecking=accept-new\tguest user@192.0.2.10\t/bin/bash\t-s'
if grep -F 'spaced value' "$LOG_FILE" >/dev/null; then
  printf 'User argv leaked into the SSH command line\n' >&2
  exit 1
fi

run_tool exec-system "$ARGV_PROBE" "$EXPECTED_ARGV" "${edge_args[@]}"
assert_contains "$(< "$LOG_FILE")" $'prlctl\texec\tTest VM\t/bin/bash\t-s'
if grep -F 'spaced value' "$LOG_FILE" >/dev/null; then
  printf 'Root argv leaked into the prlctl command line\n' >&2
  exit 1
fi

set +e
run_tool exec "$EXIT_PROBE" >/dev/null
status=$?
set -e
[[ "$status" == 7 ]] || { printf 'Expected user exit 7, got %s\n' "$status" >&2; exit 1; }

set +e
run_tool exec-system "$EXIT_PROBE" >/dev/null
status=$?
set -e
[[ "$status" == 7 ]] || { printf 'Expected root exit 7, got %s\n' "$status" >&2; exit 1; }

UPLOAD_PROBE="$TEST_DIR/guest commands/upload '; probe.sh"
cat > "$UPLOAD_PROBE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
expected="$1"
shift
actual="$(mktemp "${TMPDIR:-/tmp}/dartclaw-script-argv.XXXXXX")"
trap 'rm -f "$actual"' EXIT
printf '%s\0' "$@" > "$actual"
cmp "$expected" "$actual"
printf 'sha=%s\n' "$(sha256sum "$0" | awk '{ print $1 }')"
printf 'stage=%s\n' "$(dirname "$0")"
EOF
chmod 755 "$UPLOAD_PROBE"

upload_hash="$(sha256_file "$UPLOAD_PROBE")"
NO_ARG_PROBE="$TEST_DIR/guest commands/no arg probe.sh"
cat > "$NO_ARG_PROBE" <<'EOF'
#!/usr/bin/env bash
[[ $# == 0 ]]
EOF
chmod 755 "$NO_ARG_PROBE"
run_tool script "$NO_ARG_PROBE"
run_tool script-user "$NO_ARG_PROBE"

output="$(run_tool script "$UPLOAD_PROBE" "$EXPECTED_ARGV" "${edge_args[@]}")"
assert_contains "$output" "sha=$upload_hash"
stage_dir="$(printf '%s\n' "$output" | sed -n 's/^stage=//p')"
[[ -n "$stage_dir" && ! -e "$stage_dir" ]] || { printf 'Root staging was not cleaned\n' >&2; exit 1; }

output="$(run_tool script-user "$UPLOAD_PROBE" "$EXPECTED_ARGV" "${edge_args[@]}")"
assert_contains "$output" "sha=$upload_hash"
stage_dir="$(printf '%s\n' "$output" | sed -n 's/^stage=//p')"
[[ -n "$stage_dir" && ! -e "$stage_dir" ]] || { printf 'User staging was not cleaned\n' >&2; exit 1; }

FAILURE_PROBE="$TEST_DIR/guest commands/failure probe.sh"
cat > "$FAILURE_PROBE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$(dirname "$0")" > "$1"
exit 7
EOF
chmod 755 "$FAILURE_PROBE"
failure_stage_file="$TEST_DIR/failure-stage"
for script_command in script script-user; do
  set +e
  run_tool "$script_command" "$FAILURE_PROBE" "$failure_stage_file" >/dev/null
  status=$?
  set -e
  [[ "$status" == 7 ]] || {
    printf 'Expected %s exit 7, got %s\n' "$script_command" "$status" >&2
    exit 1
  }
  stage_dir="$(< "$failure_stage_file")"
  [[ ! -e "$stage_dir" ]] || { printf 'Failed-script staging was not cleaned\n' >&2; exit 1; }
done

stages_before="$(list_stage_dirs)"
set +e
PARALLELS_TEST_TAMPER_UPLOAD=1 run_tool script "$UPLOAD_PROBE" "$EXPECTED_ARGV" 2> "$TEST_DIR/tamper.err"
status=$?
set -e
[[ "$status" == 125 ]] || { printf 'Expected hash rejection status 125, got %s\n' "$status" >&2; exit 1; }
assert_contains "$(< "$TEST_DIR/tamper.err")" 'Guest script SHA-256 mismatch'
stages_after="$(list_stage_dirs)"
[[ "$stages_before" == "$stages_after" ]] || { printf 'Hash-failure staging was not cleaned\n' >&2; exit 1; }

capture_path="$TEST_DIR/capture file.png"
PARALLELS_TEST_STATE=stopped run_tool capture "$capture_path" >/dev/null
assert_log "$(printf '%s' $'prlctl\tcapture\tTest VM\t--file\t')$capture_path"

PARALLELS_TEST_STATE=paused run_tool snapshot 'checkpoint with spaces' >/dev/null
assert_log $'prlctl\tsnapshot\tTest VM\t--name\tcheckpoint with spaces'

help_text="$(bash "$TOOL" --help)"
assert_contains "$help_text" 'prlctl installtools "<VM name>"'
assert_contains "$help_text" 'wait for automatic login, the graphical session, or Cua Driver'
assert_contains "$help_text" 'single-caller: give concurrent agents separate clones'
if [[ "$help_text" == *'apt install parallels-tools'* ]]; then
  printf 'Help still recommends the nonexistent Ubuntu package\n' >&2
  exit 1
fi

printf 'parallels_linux_test: PASS\n'

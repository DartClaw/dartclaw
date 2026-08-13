#!/usr/bin/env bash

set -euo pipefail

VM_NAME="${PARALLELS_LINUX_VM:-Ubuntu 24}"
GUEST_USER="${PARALLELS_LINUX_USER:-parallels}"
PRLCTL="${PARALLELS_PRLCTL:-}"
SSH_BIN="${PARALLELS_SSH:-}"

usage() {
  cat <<'EOF'
Usage: parallels_linux.sh <command> [args...]

Commands:
  status                     Show VM status
  start                      Start or resume the VM and wait for the guest
  exec <command> [args...]   Run as the configured guest user over key-only SSH
  exec-system <command> ...  Run as root
  script <file> [args...]    Copy a host shell script into the guest and run it as root
  script-user <file> [...]   Same, run as the configured guest user
  capture [path]             Save a VM screenshot
  snapshot [name]            Create a snapshot
  snapshots                  List snapshots as JSON
  pause                      Pause the VM

Environment:
  PARALLELS_LINUX_VM         VM name; defaults to "Ubuntu 24"
  PARALLELS_LINUX_USER       SSH user; defaults to "parallels"
  PARALLELS_PRLCTL           prlctl path; defaults to PATH discovery
  PARALLELS_SSH              ssh path; defaults to PATH discovery

Requires Parallels Tools installed in the guest (enables `prlctl exec`). A
fresh Ubuntu install has no Tools: install via the Parallels menu
(Actions > Install Parallels Tools) or `prlctl installtools "<VM name>"`, then
complete the guest installer and reboot. User commands require the key-only SSH
setup in dev/guidelines/PARALLELS_LINUX_AGENT_VM.md.

Start and command readiness cover only the VM and command transport. They do not
wait for automatic login, the graphical session, or Cua Driver; the
desktop-automation caller must probe its own readiness. Treat a VM as
single-caller: give concurrent agents separate clones. Destructive VM
configuration, deletion, and snapshot restoration are intentionally absent.
EOF
}

resolve_prlctl() {
  if [[ -z "$PRLCTL" ]]; then
    PRLCTL="$(command -v prlctl || true)"
  fi
  if [[ -z "$PRLCTL" || ! -x "$PRLCTL" ]]; then
    printf 'prlctl not found; Parallels Desktop Pro, Business, or Enterprise is required\n' >&2
    exit 1
  fi
}

resolve_ssh() {
  if [[ -z "$SSH_BIN" ]]; then
    SSH_BIN="$(command -v ssh || true)"
  fi
  if [[ -z "$SSH_BIN" || ! -x "$SSH_BIN" ]]; then
    printf 'ssh not found; key-only SSH is required for guest-user commands\n' >&2
    exit 1
  fi
}

vm_state() {
  "$PRLCTL" status "$VM_NAME" | awk '{print $NF}'
}

wait_for_guest() {
  local execution_mode="${1:-system}"
  local target
  local _
  for _ in {1..60}; do
    if [[ "$execution_mode" == user ]]; then
      target="$(guest_target 2>/dev/null || true)"
      if [[ -n "$target" ]] && "$SSH_BIN" \
        -o BatchMode=yes \
        -o ConnectTimeout=2 \
        -o StrictHostKeyChecking=accept-new \
        "$target" /usr/bin/true >/dev/null 2>&1; then
        return 0
      fi
    elif "$PRLCTL" exec "$VM_NAME" /usr/bin/true >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  if [[ "$execution_mode" == user ]]; then
    printf 'Key-only SSH did not become ready for %s in VM: %s\n' "$GUEST_USER" "$VM_NAME" >&2
  else
    printf 'Guest did not become ready in VM: %s (is Parallels Tools installed?)\n' "$VM_NAME" >&2
  fi
  return 1
}

start_vm() {
  local execution_mode="${1:-system}"
  local state
  state="$(vm_state)"
  case "$state" in
    running) ;;
    paused | suspended) "$PRLCTL" resume "$VM_NAME" ;;
    stopped) "$PRLCTL" start "$VM_NAME" ;;
    *)
      printf 'Unsupported VM state: %s\n' "$state" >&2
      return 1
      ;;
  esac
  wait_for_guest "$execution_mode"
}

guest_target() {
  local guest_ip
  guest_ip="$(
    "$PRLCTL" list -f -o ip_configured --no-header "$VM_NAME" |
      awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit } }'
  )"
  [[ -n "$guest_ip" ]] || return 1
  printf '%s@%s\n' "$GUEST_USER" "$guest_ip"
}

absolute_file_path() {
  local path="$1"
  local directory
  [[ -f "$path" ]] || {
    printf 'Script not found: %s\n' "$path" >&2
    return 1
  }
  directory="$(cd "$(dirname "$path")" && pwd -P)"
  printf '%s/%s\n' "$directory" "$(basename "$path")"
}

encode_argv() {
  if (( $# > 0 )); then
    printf '%s\0' "$@"
  fi | base64 | tr -d '\r\n'
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    printf 'sha256sum or shasum is required\n' >&2
    return 1
  fi
}

run_remote_shell() {
  local execution_mode="$1"
  if [[ "$execution_mode" == user ]]; then
    local target
    target="$(guest_target)"
    "$SSH_BIN" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new \
      "$target" /bin/bash -s
  else
    "$PRLCTL" exec "$VM_NAME" /bin/bash -s
  fi
}

run_guest_command() {
  local execution_mode="$1"
  shift
  local argv_envelope
  argv_envelope="$(encode_argv "$@")"

  {
    printf 'argv_envelope=%s\n' "$argv_envelope"
    printf 'argv_count=%d\n' "$#"
    cat <<'EOF'
set -euo pipefail
declare -a argv=()
while IFS= read -r -d '' argument; do
  argv+=("$argument")
done < <(printf '%s' "$argv_envelope" | /usr/bin/base64 -d)
if (( ${#argv[@]} != argv_count )); then
  printf 'Guest argv envelope was corrupted\n' >&2
  exit 125
fi
if (( argv_count == 1 )); then
  exec "${argv[0]}"
fi
exec "${argv[0]}" "${argv[@]:1}"
EOF
  } | run_remote_shell "$execution_mode"
}

run_guest_script() {
  local execution_mode="$1"
  shift
  local host_script
  host_script="$(absolute_file_path "$1")"
  shift
  local argv_envelope expected_sha256
  argv_envelope="$(encode_argv "$@")"
  expected_sha256="$(sha256_file "$host_script")"

  {
    printf 'argv_envelope=%s\n' "$argv_envelope"
    printf 'argv_count=%d\n' "$#"
    printf 'expected_sha256=%s\n' "$expected_sha256"
    cat <<'EOF'
set -euo pipefail
umask 077
stage_dir="$(/usr/bin/mktemp -d /tmp/dartclaw-guest.XXXXXXXXXX)"
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  /bin/rm -rf -- "$stage_dir"
  return "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
staged_script="$stage_dir/script"
/usr/bin/base64 -d > "$staged_script" <<'__DARTCLAW_SCRIPT_PAYLOAD__'
EOF
    base64 < "$host_script"
    cat <<'EOF'
__DARTCLAW_SCRIPT_PAYLOAD__
actual_sha256="$(/usr/bin/sha256sum "$staged_script" | awk '{ print $1 }')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  printf 'Guest script SHA-256 mismatch\n' >&2
  exit 125
fi
/bin/chmod 0700 "$staged_script"
declare -a argv=()
while IFS= read -r -d '' argument; do
  argv+=("$argument")
done < <(printf '%s' "$argv_envelope" | /usr/bin/base64 -d)
if (( ${#argv[@]} != argv_count )); then
  printf 'Guest script argv envelope was corrupted\n' >&2
  exit 125
fi
if (( argv_count == 0 )); then
  "$staged_script"
else
  "$staged_script" "${argv[@]}"
fi
EOF
  } | run_remote_shell "$execution_mode"
}

if (( $# == 0 )); then
  usage
  exit 2
fi

command_name="$1"
shift

case "$command_name" in
  help | -h | --help)
    usage
    exit 0
    ;;
esac

resolve_prlctl

case "$command_name" in
  status)
    (( $# == 0 )) || { usage; exit 2; }
    "$PRLCTL" status "$VM_NAME"
    ;;
  start)
    (( $# == 0 )) || { usage; exit 2; }
    start_vm
    ;;
  exec)
    (( $# > 0 )) || { usage; exit 2; }
    resolve_ssh
    start_vm user
    run_guest_command user "$@"
    ;;
  exec-system)
    (( $# > 0 )) || { usage; exit 2; }
    start_vm
    run_guest_command system "$@"
    ;;
  script | script-user)
    (( $# > 0 )) || { usage; exit 2; }
    if [[ "$command_name" == script-user ]]; then
      resolve_ssh
      start_vm user
      run_guest_script user "$@"
    else
      start_vm system
      run_guest_script system "$@"
    fi
    ;;
  capture)
    (( $# <= 1 )) || { usage; exit 2; }
    output_path="${1:-${TMPDIR:-/tmp}/parallels-linux.png}"
    "$PRLCTL" capture "$VM_NAME" --file "$output_path"
    printf '%s\n' "$output_path"
    ;;
  snapshot)
    (( $# <= 1 )) || { usage; exit 2; }
    snapshot_name="${1:-agent-checkpoint-$(date +%Y%m%d-%H%M%S)}"
    "$PRLCTL" snapshot "$VM_NAME" --name "$snapshot_name"
    ;;
  snapshots)
    (( $# == 0 )) || { usage; exit 2; }
    "$PRLCTL" snapshot-list "$VM_NAME" --json
    ;;
  pause)
    (( $# == 0 )) || { usage; exit 2; }
    if [[ "$(vm_state)" == running ]]; then
      "$PRLCTL" pause "$VM_NAME"
    fi
    ;;
  *)
    printf 'Unknown command: %s\n' "$command_name" >&2
    usage
    exit 2
    ;;
esac

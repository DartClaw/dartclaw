#!/usr/bin/env bash

set -euo pipefail

VM_NAME="${PARALLELS_WINDOWS_VM:-Windows 11}"
PRLCTL="${PARALLELS_PRLCTL:-}"

usage() {
  cat <<'EOF'
Usage: parallels_windows.sh <command> [args...]

Commands:
  status                     Show VM status
  start                      Start or resume the VM and wait for Windows
  exec <command> [args...]   Run as the signed-in Windows user (must be active)
  exec-system <command> ...  Run as NT AUTHORITY\SYSTEM
  powershell <file> [...]    Run a host .ps1 as the signed-in user
  powershell-system <file>   Run a host .ps1 as NT AUTHORITY\SYSTEM
  capture [path]             Save a VM screenshot
  snapshot [name]            Create a snapshot
  snapshots                  List snapshots as JSON
  pause                      Pause the VM

Environment:
  PARALLELS_WINDOWS_VM       VM name; defaults to "Windows 11"
  PARALLELS_PRLCTL           prlctl path; defaults to PATH discovery

The system commands use Parallels Tools' credential-free execution context.
PowerShell file commands require host-folder sharing for the script's directory.
Destructive VM configuration, deletion, and snapshot restoration are intentionally absent.
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

vm_state() {
  "$PRLCTL" status "$VM_NAME" | awk '{print $NF}'
}

wait_for_guest() {
  local execution_mode="${1:-system}"
  local _
  for _ in {1..60}; do
    if [[ "$execution_mode" == user ]]; then
      if "$PRLCTL" exec "$VM_NAME" --current-user cmd.exe /d /c exit 0 >/dev/null 2>&1; then
        return 0
      fi
    elif "$PRLCTL" exec "$VM_NAME" cmd.exe /d /c exit 0 >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  if [[ "$execution_mode" == user ]]; then
    printf 'Signed-in Windows user did not become ready in VM: %s\n' "$VM_NAME" >&2
  else
    printf 'Windows did not become ready in VM: %s\n' "$VM_NAME" >&2
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

absolute_file_path() {
  local path="$1"
  local directory
  [[ -f "$path" ]] || {
    printf 'PowerShell script not found: %s\n' "$path" >&2
    return 1
  }
  directory="$(cd "$(dirname "$path")" && pwd -P)"
  printf '%s/%s\n' "$directory" "$(basename "$path")"
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
    start_vm user
    "$PRLCTL" exec "$VM_NAME" --current-user "$@"
    ;;
  exec-system)
    (( $# > 0 )) || { usage; exit 2; }
    start_vm
    "$PRLCTL" exec "$VM_NAME" "$@"
    ;;
  powershell | powershell-system)
    (( $# > 0 )) || { usage; exit 2; }
    script_path="$(absolute_file_path "$1")"
    shift
    exec_options=(-r)
    if [[ "$command_name" == powershell ]]; then
      start_vm user
      exec_options+=(--current-user)
    else
      start_vm system
    fi
    "$PRLCTL" exec "$VM_NAME" "${exec_options[@]}" \
      powershell.exe -NoLogo -NoProfile -NonInteractive \
      -ExecutionPolicy Bypass -File "$script_path" "$@"
    ;;
  capture)
    (( $# <= 1 )) || { usage; exit 2; }
    start_vm
    output_path="${1:-${TMPDIR:-/tmp}/parallels-windows.png}"
    "$PRLCTL" capture "$VM_NAME" --file "$output_path"
    printf '%s\n' "$output_path"
    ;;
  snapshot)
    (( $# <= 1 )) || { usage; exit 2; }
    start_vm
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

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run_all.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dartclaw-fitness-prerequisites-XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

BASH_BIN="$(command -v bash)"
for command_name in bash dart dirname; do
  ln -s "$(command -v "$command_name")" "$TEMP_DIR/$command_name"
done

set +e
PATH="$TEMP_DIR" "$BASH_BIN" "$RUNNER" > "$TEMP_DIR/output.log" 2>&1
status=$?
set -e

if [[ "$status" -ne 2 ]]; then
  echo "fitness prerequisite test: expected exit 2 without rg, got $status" >&2
  cat "$TEMP_DIR/output.log" >&2
  exit 1
fi

expected_output="fitness suite: missing required command: rg (ripgrep)"
actual_output="$(< "$TEMP_DIR/output.log")"
if [[ "$actual_output" != "$expected_output" ]]; then
  echo "fitness prerequisite test: expected only the actionable rg diagnostic" >&2
  cat "$TEMP_DIR/output.log" >&2
  exit 1
fi

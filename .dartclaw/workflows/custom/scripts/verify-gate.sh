#!/usr/bin/env bash
#
# Deterministic verification gate for the inline DartClaw workflows.
#
# Invoked from a workflow `type: bash` step after the review/remediation loop.
# Bash steps run on the host with a sandboxed working directory under the run
# data dir, so this script does NOT rely on its cwd: it locates the repo root by
# walking up from the artifacts directory passed as $2 (which lives under
# <repo>/.dartclaw/...).
#
# It runs one or all CI-equivalent gates, captures full output under
# <artifacts>/verify/<gate>.log, and prints exactly `pass` or `fail` (no
# trailing newline) as its ONLY stdout. The workflow captures that token as a
# context value and a gate expression branches on it; the evaluator compares the
# raw value, so a trailing newline would break the match.
#
# The script ALWAYS exits 0. A non-zero exit marks the bash step failed and
# discards its outputs before the gate can read them, so gate failures are
# captured in the printed token instead.
#
# Usage: verify-gate.sh <format|analyze|test|focused|arch|fitness|whitespace|status|all> <artifacts_dir>

set -uo pipefail

emit_fail() {
  printf '%s' fail
  exit 0
}

GATE="${1:-}"
ARTIFACTS="${2:-}"
if [ -z "$GATE" ] || [ -z "$ARTIFACTS" ]; then
  echo "verify-gate: usage: verify-gate.sh <format|analyze|test|focused|arch|fitness|whitespace|status|all> <artifacts_dir>" >&2
  emit_fail
fi

# Locate the repo root by climbing from the artifacts dir until both the
# workflow tool dir and the workspace pubspec are present.
repo=""
dir="$ARTIFACTS"
while [ -n "$dir" ] && [ "$dir" != "/" ]; do
  if [ -d "$dir/dev/tools/dartclaw-workflows" ] && [ -f "$dir/pubspec.yaml" ]; then
    repo="$dir"
    break
  fi
  dir="$(dirname "$dir")"
done
if [ -z "$repo" ]; then
  echo "verify-gate: could not locate repo root from '$ARTIFACTS'" >&2
  emit_fail
fi

log_dir="$ARTIFACTS/verify"
mkdir -p "$log_dir" || emit_fail
cd "$repo" || emit_fail

# Automated remediation gates (mirror the CI checks that can pass with intended
# inline workflow edits still uncommitted).
# `dart format`/`dart analyze` skip hidden dirs, so the gitignored .dartclaw tree is
# never scanned.
gate_format() {
  dart format --line-length=120 --output=none --set-exit-if-changed .
}
gate_analyze() {
  dart analyze --fatal-infos
}
gate_test() {
  bash dev/tools/test_workspace.sh
}
gate_arch() {
  dart run dev/tools/arch_check.dart
}
gate_fitness() {
  bash dev/tools/fitness/run_all.sh
}
gate_whitespace() {
  git diff --check
}
gate_status() {
  local porcelain
  porcelain="$(git status --porcelain)"
  if [ -n "$porcelain" ]; then
    printf '%s\n' "$porcelain"
    return 1
  fi
}

# Runs a single gate with all output tee'd to its log; returns the gate's status.
run_gate() {
  local name="$1"
  "gate_$name" >"$log_dir/$name.log" 2>&1
}

status=0
case "$GATE" in
  format | analyze | test | arch | fitness | whitespace | status)
    run_gate "$GATE" || status=1
    ;;
  focused)
    run_gate format || status=1
    run_gate analyze || status=1
    run_gate test || status=1
    ;;
  all)
    run_gate format || status=1
    run_gate analyze || status=1
    run_gate test || status=1
    run_gate arch || status=1
    run_gate fitness || status=1
    run_gate whitespace || status=1
    ;;
  *)
    echo "verify-gate: unknown gate '$GATE'" >&2
    emit_fail
    ;;
esac

if [ "$status" -eq 0 ]; then
  printf '%s' pass
else
  printf '%s' fail
fi
exit 0

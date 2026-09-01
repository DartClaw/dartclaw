#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/data/projects/workflow-test-todo-app"

usage() {
  cat <<'EOF'
Usage:
  bash dev/testing/profiles/workflows/fixture.sh check
  bash dev/testing/profiles/workflows/fixture.sh reset

Commands:
  check  Verify that the workflow-test-todo-app fixture is present, locally bounded,
         and free of smoke-generated drift. The boundary instructions are committed
         upstream in the fixture repo's AGENTS.md / CLAUDE.md.
  reset  Remove known smoke-generated artifacts, then run the same checks.
EOF
}

check_fixture_exists() {
  if [ ! -d "$FIXTURE_DIR/.git" ]; then
    echo "Error: workflow-test-todo-app fixture repo not found at $FIXTURE_DIR" >&2
    exit 1
  fi
}

require_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "Error: required fixture file is missing: $path" >&2
    exit 1
  fi
}

check_instruction_contract() {
  require_file "$FIXTURE_DIR/AGENTS.md"
  require_file "$FIXTURE_DIR/CLAUDE.md"

  rg -q 'complete project root for workflow smoke runs' "$FIXTURE_DIR/AGENTS.md"
  rg -q 'Do not inspect parent or sibling repositories' "$FIXTURE_DIR/AGENTS.md"
  rg -q 'framework: fastapi' "$FIXTURE_DIR/AGENTS.md"

  rg -q 'complete project root for workflow smoke runs' "$FIXTURE_DIR/CLAUDE.md"
  rg -q 'Do not inspect parent or sibling repositories' "$FIXTURE_DIR/CLAUDE.md"
  rg -q 'framework: fastapi' "$FIXTURE_DIR/CLAUDE.md"
}


reset_fixture() {
  while IFS= read -r worktree_path; do
    [ "$worktree_path" = "$FIXTURE_DIR" ] && continue
    git -C "$FIXTURE_DIR" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
  done < <(git -C "$FIXTURE_DIR" worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}')
  git -C "$FIXTURE_DIR" checkout -f -B main origin/main >/dev/null 2>&1
  git -C "$FIXTURE_DIR" branch --list 'dartclaw/workflow/*' 'dartclaw/task-*' | while IFS= read -r branch; do
    branch="$(printf '%s' "$branch" | sed 's/^[*+[:space:]]*//')"
    [ -n "$branch" ] && git -C "$FIXTURE_DIR" branch -D "$branch" >/dev/null 2>&1 || true
  done
  git -C "$FIXTURE_DIR" checkout -- . >/dev/null 2>&1
  git -C "$FIXTURE_DIR" clean -fd >/dev/null 2>&1
  git -C "$FIXTURE_DIR" worktree prune >/dev/null 2>&1 || true
}

check_clean_git_state() {
  local status
  status="$(
    git -C "$FIXTURE_DIR" status --short --untracked-files=all
  )"
  if [ -n "$status" ]; then
    echo "Error: workflow-test-todo-app fixture is not clean." >&2
    echo "Run 'bash dev/testing/profiles/workflows/fixture.sh reset' and investigate any remaining paths." >&2
    echo >&2
    printf '%s\n' "$status" >&2
    exit 1
  fi
}

command="${1:-check}"

case "$command" in
  check)
    check_fixture_exists
    check_instruction_contract
    check_clean_git_state
    ;;
  reset)
    check_fixture_exists
    reset_fixture
    check_instruction_contract
    check_clean_git_state
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

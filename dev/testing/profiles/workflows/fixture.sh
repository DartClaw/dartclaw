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
         and free of smoke-generated drift. Untracked boundary overlay files
         (AGENTS.md and CLAUDE.md) are permitted.
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
  rg -q 'framework: none' "$FIXTURE_DIR/AGENTS.md"

  rg -q 'complete project root for workflow smoke runs' "$FIXTURE_DIR/CLAUDE.md"
  rg -q 'Do not inspect parent or sibling repositories' "$FIXTURE_DIR/CLAUDE.md"
  rg -q 'framework: none' "$FIXTURE_DIR/CLAUDE.md"
}

check_boundary_overlay_state() {
  local overlay_status unexpected
  overlay_status="$(
    git -C "$FIXTURE_DIR" status --short --untracked-files=all -- AGENTS.md CLAUDE.md
  )"
  if [ -z "$overlay_status" ]; then
    return
  fi

  unexpected="$(printf '%s\n' "$overlay_status" | rg -v '^\?\? (AGENTS|CLAUDE)\.md$' || true)"
  if [ -n "$unexpected" ]; then
    echo "Error: workflow-test-todo-app fixture boundary overlay files are in an unexpected state." >&2
    echo "Expected either clean files or untracked local overlays for AGENTS.md / CLAUDE.md." >&2
    echo >&2
    printf '%s\n' "$unexpected" >&2
    exit 1
  fi
}

reset_fixture() {
  local initial_commit
  initial_commit="$(git -C "$FIXTURE_DIR" rev-list --max-parents=0 HEAD | tail -n 1)"
  while IFS= read -r worktree_path; do
    [ "$worktree_path" = "$FIXTURE_DIR" ] && continue
    git -C "$FIXTURE_DIR" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
  done < <(git -C "$FIXTURE_DIR" worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}')
  if [ -n "$initial_commit" ]; then
    git -C "$FIXTURE_DIR" checkout -B main "$initial_commit" >/dev/null 2>&1
  fi
  git -C "$FIXTURE_DIR" branch --list 'dartclaw/workflow/*' 'dartclaw/task-*' | while IFS= read -r branch; do
    branch="$(printf '%s' "$branch" | sed 's/^[*+[:space:]]*//')"
    [ -n "$branch" ] && git -C "$FIXTURE_DIR" branch -D "$branch" >/dev/null 2>&1 || true
  done
  rm -f "$FIXTURE_DIR"/notes/*.md
  rmdir "$FIXTURE_DIR"/notes 2>/dev/null || true
  find "$FIXTURE_DIR" -maxdepth 1 -type f -name '*.md' \
    ! -name 'README.md' \
    ! -name 'AGENTS.md' \
    ! -name 'CLAUDE.md' \
    -delete
  rm -rf "$FIXTURE_DIR"/docs
  git -C "$FIXTURE_DIR" worktree prune >/dev/null 2>&1 || true
}

check_clean_git_state() {
  local status
  status="$(
    git -C "$FIXTURE_DIR" status --short --untracked-files=all -- \
      ':(exclude)AGENTS.md' \
      ':(exclude)CLAUDE.md'
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
    check_boundary_overlay_state
    check_clean_git_state
    ;;
  reset)
    check_fixture_exists
    reset_fixture
    check_instruction_contract
    check_boundary_overlay_state
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

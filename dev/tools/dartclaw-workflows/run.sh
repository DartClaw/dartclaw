#!/usr/bin/env bash
# Run DartClaw's built-in implementation workflows against this checkout.
#
# Server mode:
#   bash dev/tools/dartclaw-workflows/run.sh
#   bash dev/tools/dartclaw-workflows/run.sh --port 4000
#
# CLI workflow mode:
#   bash dev/tools/dartclaw-workflows/run.sh workflow list
#   bash dev/tools/dartclaw-workflows/run.sh workflow run spec-and-implement -v 'FEATURE=...'
#   bash dev/tools/dartclaw-workflows/run.sh workflow run plan-and-implement -v 'REQUIREMENTS=...'
#
# By default the host is AOT-compiled to a content-addressed file under
# ${DATA_DIR}/bin/dartclaw-<key> and exec'd. Concurrent invocations cannot
# clobber a binary that a running process holds open. The cache key combines
# HEAD sha, pubspec.lock hash, the diff hash of apps/+packages/+pubspec.* ,
# the contents of any untracked files in the same scope, and the local dart
# SDK version. Restricted scope avoids needless rebuilds from doc-only edits.
#
# Escape hatches:
#   DARTCLAW_WORKFLOWS_JIT=1       run via `dart run` (live source, no isolation)
#   DARTCLAW_WORKFLOWS_REBUILD=1   force AOT rebuild even if the cache key matches

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DATA_DIR="${DARTCLAW_WORKFLOWS_DATA_DIR:-${SCRIPT_DIR}/.data}"
TEMPLATE_CONFIG="${SCRIPT_DIR}/dartclaw.yaml"
RUNTIME_CONFIG="${DATA_DIR}/dartclaw.runtime.yaml"
ENTRY="${REPO_ROOT}/apps/dartclaw_cli/bin/dartclaw.dart"
BIN_DIR="${DATA_DIR}/bin"
BIN_TO_EXEC=""

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[dartclaw-workflows] required command not found on PATH: $1" >&2
    exit 1
  }
}

require_git_repo() {
  if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "[dartclaw-workflows] $REPO_ROOT is not a git checkout; cache invalidation requires git. Aborting." >&2
    echo "[dartclaw-workflows] Use DARTCLAW_WORKFLOWS_JIT=1 to bypass the AOT path if you must run from a non-git tree." >&2
    exit 1
  fi
}

escape_sed() {
  local val="$1"
  val=${val//\\/\\\\}
  val=${val//&/\\&}
  val=${val//|/\\|}
  printf '%s\n' "$val"
}

prepare_runtime_config() {
  local data_dir_abs
  mkdir -p "$DATA_DIR"
  data_dir_abs="$(cd "$DATA_DIR" && pwd)"

  sed -e "s|__DATA_DIR__|$(escape_sed "$data_dir_abs")|g" \
      -e "s|__REPO_ROOT__|$(escape_sed "$REPO_ROOT")|g" \
      "$TEMPLATE_CONFIG" > "$RUNTIME_CONFIG"
}

# Hash *contents* of untracked files in a path-scope. Path-only hashing would
# silently miss new source files added by a workflow.
hash_untracked_in_scope() {
  local f
  git -C "$REPO_ROOT" ls-files --others --exclude-standard -- \
    'apps/' 'packages/' 'pubspec.yaml' 'pubspec.lock' 2>/dev/null \
    | while IFS= read -r f; do
        printf '%s\n' "$f"
        shasum -a 256 "$REPO_ROOT/$f" 2>/dev/null | awk '{print $1}'
      done \
    | shasum -a 256 | awk '{print $1}'
}

compute_build_key() {
  {
    git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "no-head"
    if [ -f "$REPO_ROOT/pubspec.lock" ]; then
      shasum -a 256 "$REPO_ROOT/pubspec.lock" | awk '{print $1}'
    else
      echo "no-lock"
    fi
    # Scope diff to source paths the AOT build consumes; doc/CI edits do not
    # invalidate the cache. `|| true` keeps `set -o pipefail` from aborting
    # when HEAD is missing (fresh checkout with no commits) — `require_git_repo`
    # above already filtered out non-git trees.
    { git -C "$REPO_ROOT" diff HEAD -- \
      'apps/' 'packages/' 'pubspec.yaml' 'pubspec.lock' 2>/dev/null || true; } \
      | shasum -a 256 | awk '{print $1}'
    hash_untracked_in_scope
    # Dart SDK version pins the binary to a (sdk, arch) pair so a cached
    # binary from a different machine or post-SDK-upgrade is not silently reused.
    dart --version 2>&1 | shasum -a 256 | awk '{print $1}'
  } | shasum -a 256 | awk '{print $1}'
}

ensure_binary() {
  mkdir -p "$BIN_DIR"

  local key versioned
  key="$(compute_build_key)"
  versioned="${BIN_DIR}/dartclaw-${key}"

  if [ -z "${DARTCLAW_WORKFLOWS_REBUILD:-}" ] && [ -x "$versioned" ]; then
    BIN_TO_EXEC="$versioned"
    return
  fi

  echo "[dartclaw-workflows] compiling host binary (key=${key:0:12})..." >&2

  ( cd "$REPO_ROOT" && dart pub get >&2 )

  # `dart pub get` may rewrite pubspec.lock; recompute the key so the artifact
  # name reflects the post-resolve state and the next run does not redundantly
  # rebuild.
  key="$(compute_build_key)"
  versioned="${BIN_DIR}/dartclaw-${key}"
  if [ -z "${DARTCLAW_WORKFLOWS_REBUILD:-}" ] && [ -x "$versioned" ]; then
    BIN_TO_EXEC="$versioned"
    return
  fi

  # Compile to a unique tempfile, then atomically rename. A crashed compile
  # leaves only the tempfile (with a unique suffix); the published `versioned`
  # path is only ever a fully-written binary because `mv -f` is atomic on the
  # same filesystem. Concurrent invocations for the same key produce
  # equivalent output and race harmlessly to the same final path; the running
  # process holds its binary by inode and is unaffected by the rename.
  local tmp="${versioned}.tmp.$$"
  ( cd "$REPO_ROOT" && dart compile exe "$ENTRY" -o "$tmp" >&2 )
  mv -f "$tmp" "$versioned"

  # Stable symlink for operator convenience (lsof, manual invocation). The
  # exec below uses the versioned path directly so swapping this symlink in a
  # concurrent run cannot affect the running process.
  ln -sfn "dartclaw-${key}" "${BIN_DIR}/dartclaw"

  BIN_TO_EXEC="$versioned"
}

# Per-arg match avoids false positives on user-supplied -v values containing
# the literal string "--json".
has_json_flag() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = "--json" ]; then
      return 0
    fi
  done
  return 1
}

run_host() {
  if [ -n "${DARTCLAW_WORKFLOWS_JIT:-}" ]; then
    if has_json_flag "$@"; then
      dart run dartclaw_cli:dartclaw "$@" | awk '
        BEGIN { started = 0 }
        {
          if (!started) {
            gsub(/Running build hooks\.\.\./, "")
            if (length($0) == 0) {
              next
            }
            started = 1
          }
          print
          fflush()
        }
      '
    else
      exec dart run dartclaw_cli:dartclaw "$@"
    fi
  else
    ensure_binary
    exec "$BIN_TO_EXEC" "$@"
  fi
}

require_command dart
require_command git
require_command shasum
require_command awk
require_git_repo

prepare_runtime_config

# For built-in implementation workflows, always target the seeded project. If
# the caller does not pass BRANCH explicitly, use the checkout's current branch
# so workflow branches fork from the operator's active line of work.
if [ $# -ge 2 ] && [ "$1" = "workflow" ] && [ "$2" = "run" ]; then
  user_set_branch=0
  for arg in "$@"; do
    case "$arg" in
      BRANCH=*|--var=BRANCH=*|-vBRANCH=*) user_set_branch=1 ;;
    esac
  done

  workflow_cmd="$1"
  workflow_sub="$2"
  shift 2
  set -- "$workflow_cmd" "$workflow_sub" "$@" -v "PROJECT=dartclaw-public"

  if [ "$user_set_branch" -eq 0 ]; then
    current_branch="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [ -n "$current_branch" ]; then
      echo "[dartclaw-workflows] injecting BRANCH=$current_branch (from current checkout)" >&2
      set -- "$@" -v "BRANCH=$current_branch"
    else
      echo "[dartclaw-workflows] warning: detached HEAD; no BRANCH injected (workflow will fall back to its default)" >&2
    fi
  fi
fi

cd "$REPO_ROOT"

if [ $# -eq 0 ]; then
  run_host --config "$RUNTIME_CONFIG" serve --dev --data-dir "$DATA_DIR"
  exit 0
fi

case "${1:-}" in
  -*)
    run_host --config "$RUNTIME_CONFIG" serve --dev --data-dir "$DATA_DIR" "$@"
    ;;
  *)
    run_host --config "$RUNTIME_CONFIG" "$@"
    ;;
esac

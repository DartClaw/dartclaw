#!/usr/bin/env bash
# Run DartClaw's built-in + inline workflows against this checkout.
#
# Server-less: workflows run in-process via the standalone CLI path, reading the
# committed config at <repo>/.dartclaw/dartclaw.yaml (data dir, local DB, and
# worktrees all live under .dartclaw/). For a web-UI dev server, use
# `bash examples/run.sh` instead.
#
#   bash dev/tools/dartclaw-workflows/run.sh workflow list
#   bash dev/tools/dartclaw-workflows/run.sh workflow run spec-and-implement -v 'FEATURE=...'
#   bash dev/tools/dartclaw-workflows/run.sh workflow run plan-and-implement -v 'FEATURE=...'
#
# The spec.sh / plan.sh / review.sh wrappers run the inline variants
# (--standalone --allow-dirty-localpath) against the current branch.
#
# By default the host is AOT-compiled to a content-addressed file under
# .cache/bin/dartclaw-<key> and exec'd. Concurrent invocations cannot clobber a
# binary that a running process holds open. The cache key combines HEAD sha,
# pubspec.lock hash, the diff hash of apps/+packages/+pubspec.* , the contents
# of any untracked files in the same scope, and the local dart SDK version.
# Restricted scope avoids needless rebuilds from doc-only edits.
#
# Host selection:
#   DARTCLAW_WORKFLOWS_HOST=auto    build/use the local content-addressed AOT binary (default)
#   DARTCLAW_WORKFLOWS_HOST=jit     run via `dart run` (live source, no isolation)
#   DARTCLAW_WORKFLOWS_HOST=cached  use the local AOT cache; fail if the current key is missing
#   DARTCLAW_WORKFLOWS_HOST=system  use `dartclaw` from PATH (e.g. Homebrew)
#   DARTCLAW_WORKFLOWS_BINARY=/path/to/dartclaw
#                                  use an explicit binary path
#
# Compatibility escape hatches:
#   DARTCLAW_WORKFLOWS_JIT=1       alias for DARTCLAW_WORKFLOWS_HOST=jit
#   DARTCLAW_WORKFLOWS_REBUILD=1   force AOT rebuild even if the cache key matches
#   DARTCLAW_WORKFLOWS_PREFER_SOURCE=0
#                                  fall back to default asset-resolver order
#                                  (asset cache wins over source tree). The
#                                  local-source host modes set this to 1 by
#                                  default so live edits to skills/workflow
#                                  YAMLs apply.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CONFIG="${REPO_ROOT}/.dartclaw/dartclaw.yaml"
ENTRY="${REPO_ROOT}/apps/dartclaw_cli/bin/dartclaw.dart"
BIN_DIR="${SCRIPT_DIR}/.cache/bin"
BIN_TO_EXEC=""
HOST_MODE="${DARTCLAW_WORKFLOWS_HOST:-auto}"

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

require_build_commands() {
  require_command dart
  require_command git
  require_command shasum
  require_command awk
  require_git_repo
}

resolve_host_mode() {
  if [ -n "${DARTCLAW_WORKFLOWS_BINARY:-}" ]; then
    if [ -n "${DARTCLAW_WORKFLOWS_HOST:-}" ] && [ "$DARTCLAW_WORKFLOWS_HOST" != "path" ]; then
      echo "[dartclaw-workflows] DARTCLAW_WORKFLOWS_BINARY conflicts with DARTCLAW_WORKFLOWS_HOST=$DARTCLAW_WORKFLOWS_HOST" >&2
      echo "[dartclaw-workflows] Use DARTCLAW_WORKFLOWS_HOST=path or unset DARTCLAW_WORKFLOWS_HOST." >&2
      exit 64
    fi
    HOST_MODE="path"
  fi

  if [ -n "${DARTCLAW_WORKFLOWS_JIT:-}" ]; then
    if [ -n "${DARTCLAW_WORKFLOWS_HOST:-}" ] && [ "$DARTCLAW_WORKFLOWS_HOST" != "jit" ]; then
      echo "[dartclaw-workflows] DARTCLAW_WORKFLOWS_JIT=1 conflicts with DARTCLAW_WORKFLOWS_HOST=$DARTCLAW_WORKFLOWS_HOST" >&2
      exit 64
    fi
    HOST_MODE="jit"
  fi

  case "$HOST_MODE" in
    auto|jit|cached|system|path) ;;
    *)
      echo "[dartclaw-workflows] unsupported DARTCLAW_WORKFLOWS_HOST=$HOST_MODE" >&2
      echo "[dartclaw-workflows] supported modes: auto, jit, cached, system, path" >&2
      exit 64
      ;;
  esac
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
  require_build_commands
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

select_cached_binary() {
  require_build_commands

  local key versioned
  key="$(compute_build_key)"
  versioned="${BIN_DIR}/dartclaw-${key}"

  if [ ! -x "$versioned" ]; then
    echo "[dartclaw-workflows] no cached host binary for current key (${key:0:12})" >&2
    echo "[dartclaw-workflows] Run with DARTCLAW_WORKFLOWS_HOST=auto to build it." >&2
    exit 1
  fi

  echo "[dartclaw-workflows] using cached host binary: $versioned" >&2
  BIN_TO_EXEC="$versioned"
}

select_explicit_binary() {
  if [ -z "${DARTCLAW_WORKFLOWS_BINARY:-}" ]; then
    echo "[dartclaw-workflows] DARTCLAW_WORKFLOWS_HOST=path requires DARTCLAW_WORKFLOWS_BINARY=/path/to/dartclaw" >&2
    exit 64
  fi
  if [ ! -x "$DARTCLAW_WORKFLOWS_BINARY" ]; then
    echo "[dartclaw-workflows] explicit host binary is not executable: $DARTCLAW_WORKFLOWS_BINARY" >&2
    exit 1
  fi

  echo "[dartclaw-workflows] using explicit host binary: $DARTCLAW_WORKFLOWS_BINARY" >&2
  BIN_TO_EXEC="$DARTCLAW_WORKFLOWS_BINARY"
}

select_system_binary() {
  BIN_TO_EXEC="$(command -v dartclaw || true)"
  if [ -z "$BIN_TO_EXEC" ]; then
    echo "[dartclaw-workflows] DARTCLAW_WORKFLOWS_HOST=system requires dartclaw on PATH" >&2
    exit 1
  fi

  echo "[dartclaw-workflows] using system host binary: $BIN_TO_EXEC" >&2
  "$BIN_TO_EXEC" --version >&2 || echo "[dartclaw-workflows] warning: unable to read system dartclaw version" >&2
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
  case "$HOST_MODE" in
    jit)
      require_command dart
      require_command awk

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
      ;;
    auto)
      ensure_binary
      exec "$BIN_TO_EXEC" "$@"
      ;;
    cached)
      select_cached_binary
      exec "$BIN_TO_EXEC" "$@"
      ;;
    system)
      select_system_binary
      exec "$BIN_TO_EXEC" "$@"
      ;;
    path)
      select_explicit_binary
      exec "$BIN_TO_EXEC" "$@"
      ;;
  esac
}

resolve_host_mode

# Local-source host modes run against this checkout. Tell the standalone CLI to
# prefer the checked-out skills/workflow-YAMLs over any
# `~/.dartclaw/assets/v<version>/` install — otherwise a stale asset cache
# (e.g. left over from a `dartclaw init` for an earlier dev cycle) wins and
# materializes outdated workflow definitions, silently excluding them at load
# time when their skill refs no longer resolve.
# Use `${X-1}` (no colon): only substitutes when the var is unset. An explicit
# empty-string override (e.g. `DARTCLAW_WORKFLOWS_PREFER_SOURCE=`) passes
# through and the Dart side reads it as "off" — `:-1` would silently turn that
# back into "on".
case "$HOST_MODE" in
  system|path) default_prefer_source=0 ;;
  *) default_prefer_source=1 ;;
esac
export DARTCLAW_WORKFLOWS_PREFER_SOURCE="${DARTCLAW_WORKFLOWS_PREFER_SOURCE-$default_prefer_source}"

if [ $# -eq 0 ]; then
  echo "Usage: $(basename "$0") workflow <list|run ...> [args]" >&2
  echo "       (server-less; for a web-UI dev server use: bash examples/run.sh)" >&2
  exit 64
fi

# For workflow runs, inject BRANCH from the checkout's current branch (unless
# the caller passed their own) so workflow branches fork from the operator's
# active line of work. The project is the cwd repo — standalone mode needs no
# named project.
if [ $# -ge 2 ] && [ "$1" = "workflow" ] && [ "$2" = "run" ]; then
  user_set_branch=0
  for arg in "$@"; do
    case "$arg" in
      BRANCH=*|--var=BRANCH=*|-vBRANCH=*) user_set_branch=1 ;;
    esac
  done

  if [ "$user_set_branch" -eq 0 ]; then
    current_branch=""
    if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      current_branch="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    fi
    if [ -n "$current_branch" ]; then
      echo "[dartclaw-workflows] injecting BRANCH=$current_branch (from current checkout)" >&2
      set -- "$@" -v "BRANCH=$current_branch"
    else
      echo "[dartclaw-workflows] warning: detached HEAD; no BRANCH injected (workflow will fall back to its default)" >&2
    fi
  fi
fi

cd "$REPO_ROOT"
run_host --config "$CONFIG" "$@"

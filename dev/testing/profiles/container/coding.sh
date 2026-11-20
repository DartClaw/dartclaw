#!/usr/bin/env bash
# Live implement-story proof with workspace-container steps and public-registry fixtures.
# Usage: coding.sh [--provider claude|codex] [--fixture dart|node|python|rust|go] [--baseline]
# Requires Docker/Podman, Dart, git, curl, python3 and a host-held credential per
# selected provider: DARTCLAW_CONTAINER_DATA_DIR names its DartClaw store, or use
# ANTHROPIC_API_KEY / CODEX_API_KEY. The store is a credential source only.
# Builds a recipe image per fixture; DARTCLAW_CODING_IMAGE selects an
# already-built image for all fixtures (for example dartclaw-agent:latest).
# Exit 0 means every selected install/test passed; --baseline permits only those
# command failures. Missing credentials/runtime, placement or cleanup errors fail.
# Do not run another DartClaw Codex server concurrently: its rollouts confound
# the before/after ~/.codex/sessions observation. Results stay in .agent_temp.
set -euo pipefail
# Codex Desktop's parent label overrides app-server's own client identity.
unset CODEX_INTERNAL_ORIGINATOR_OVERRIDE

PROVIDERS=(claude codex)
FIXTURES=(dart node python rust go)
BASELINE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider) [ "$#" -ge 2 ] || exit 2; PROVIDERS=("$2"); shift 2 ;;
    --fixture) [ "$#" -ge 2 ] || exit 2; FIXTURES=("$2"); shift 2 ;;
    --baseline) BASELINE=1; shift ;;
    *) echo "usage: $0 [--provider claude|codex] [--fixture dart|node|python|rust|go] [--baseline]" >&2; exit 2 ;;
  esac
done
for provider in "${PROVIDERS[@]}"; do
  case "$provider" in claude|codex) ;; *) echo "Unknown provider: $provider" >&2; exit 2 ;; esac
  if [ "$provider" = claude ]; then
    if [ -z "${ANTHROPIC_API_KEY:-}" ] &&
       [ ! -f "${DARTCLAW_CONTAINER_DATA_DIR:-/nonexistent}/credentials/claude/setup-token.json" ]; then
      echo 'FAIL: Claude needs a stored `dartclaw auth claude` credential under DARTCLAW_CONTAINER_DATA_DIR, or ANTHROPIC_API_KEY.' >&2
      exit 1
    fi
  elif [ -z "${CODEX_API_KEY:-}" ] &&
       [ ! -f "${DARTCLAW_CONTAINER_DATA_DIR:-/nonexistent}/credentials/codex/auth.json" ]; then
    echo 'FAIL: Codex needs a stored `dartclaw auth codex` credential under DARTCLAW_CONTAINER_DATA_DIR, or CODEX_API_KEY.' >&2
    exit 1
  fi
done
for fixture in "${FIXTURES[@]}"; do
  case "$fixture" in dart|node|python|rust|go) ;; *) echo "Unknown fixture: $fixture" >&2; exit 2 ;; esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$SCRIPT_DIR/coding_results_test.py"
source "$SCRIPT_DIR/../postgres.sh"
RUNTIME=""
for candidate in docker podman; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" info >/dev/null 2>&1; then
    RUNTIME="$candidate"; break
  fi
done
[ -n "$RUNTIME" ] || { echo 'FAIL: no Docker or Podman container runtime answered.' >&2; exit 1; }

mkdir -p "$REPO_ROOT/.agent_temp/container-coding"
RESULT_DIR="$(mktemp -d "$REPO_ROOT/.agent_temp/container-coding/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
RUN_ROOT="$(mktemp -d "$REPO_ROOT/.agent_temp/container-coding-run.XXXXXX")"
SERVER_PID=""
DATA_DIR=""
FIXTURE_STATE=""
fixture_state() {
  python3 - "$SCRIPT_DIR/fixtures" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1])
print(json.dumps({str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob('*')) if p.is_file()},sort_keys=True))
PY
}
cleanup_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    for ((attempt=0; attempt<30; attempt++)); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  if [ -n "$DATA_DIR" ]; then
    local names
    names="$("$RUNTIME" ps -aq --filter "label=dartclaw.data-dir=$DATA_DIR")" || return 1
    # -v also removes each container's anonymous package-cache volume.
    for name in $names; do "$RUNTIME" rm -f -v "$name" >/dev/null || return 1; done
    names="$("$RUNTIME" ps -aq --filter "label=dartclaw.data-dir=$DATA_DIR")" || return 1
    [ -z "$names" ] || return 1
  fi
}
cleanup() {
  local status=$?
  trap - EXIT
  cleanup_server || status=1
  profile_postgres_stop
  if [ -n "$FIXTURE_STATE" ] && [ "$(fixture_state)" != "$FIXTURE_STATE" ]; then
    echo 'FAIL: the committed source fixtures changed during the scenario.' >&2
    status=1
  fi
  rm -rf "$RUN_ROOT"
  [ ! -e "$RUN_ROOT" ] || status=1
  echo "Results: $RESULT_DIR/results.md"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
FIXTURE_STATE="$(fixture_state)"
printf '%s\n' "$FIXTURE_STATE" > "$RESULT_DIR/fixture-state.json"
profile_postgres_start
cd "$REPO_ROOT"
dart run dev/tools/embed_assets.dart >/dev/null
if [ ! -x "$REPO_ROOT/build/bridge/dartclaw-bridge-linux-x64" ]; then
  bash dev/tools/build_bridge.sh >"$RESULT_DIR/bridge-build.log" 2>&1
fi
"$RUNTIME" image inspect dartclaw-agent:latest >/dev/null 2>&1 ||
  "$RUNTIME" build -t dartclaw-agent:latest docker/ >"$RESULT_DIR/image-build.log" 2>&1

if [ -z "${DARTCLAW_CODING_IMAGE:-}" ]; then
  for fixture in "${FIXTURES[@]}"; do
    "$RUNTIME" build -t "dartclaw-agent-coding-$fixture:latest" -f "$SCRIPT_DIR/images/$fixture.Dockerfile" \
      "$SCRIPT_DIR/images" >"$RESULT_DIR/$fixture-image-build.log" 2>&1
  done
fi

matrix_status=0
for provider in "${PROVIDERS[@]}"; do
  for fixture in "${FIXTURES[@]}"; do
    NAME="$provider-$fixture"
    DATA_DIR="$RUN_ROOT/$NAME/data"
    PROJECT="$RUN_ROOT/$NAME/project"
    REMOTE="$RUN_ROOT/$NAME/origin.git"
    mkdir -p "$DATA_DIR" "$PROJECT"
    cp -R "$SCRIPT_DIR/fixtures/$fixture/." "$PROJECT/"
    for instructions in AGENTS.md CLAUDE.md; do
      cp "$SCRIPT_DIR/fixtures/project-instructions.md" "$PROJECT/$instructions"
    done
    git -C "$PROJECT" init -q --initial-branch=main
    git -C "$PROJECT" config user.name 'Container fixture'
    git -C "$PROJECT" config user.email 'fixture@example.invalid'
    git -C "$PROJECT" add -- .
    git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm 'Initialize container coding fixture'
    git clone --bare --quiet "$PROJECT" "$REMOTE"
    if [ -n "${DARTCLAW_CONTAINER_DATA_DIR:-}" ]; then
      case "$provider" in claude) STORE_FILE=setup-token.json ;; codex) STORE_FILE=auth.json ;; esac
      SOURCE_CREDENTIAL="$DARTCLAW_CONTAINER_DATA_DIR/credentials/$provider/$STORE_FILE"
      if [ -f "$SOURCE_CREDENTIAL" ]; then
        mkdir -p "$DATA_DIR/credentials"
        # Refresh must rotate the source store rather than fork its refresh-token lineage.
        ln -s "$(cd "$(dirname "$SOURCE_CREDENTIAL")" && pwd)" "$DATA_DIR/credentials/$provider"
      fi
    fi
    IMAGE="${DARTCLAW_CODING_IMAGE:-dartclaw-agent-coding-$fixture:latest}"
    dart "$SCRIPT_DIR/coding_config.dart" "$provider" "$DATA_DIR" "$REMOTE" "$IMAGE" "$fixture" \
      >"$RESULT_DIR/$NAME-definition-proof.json"
    (exec dart run apps/dartclaw_cli/bin/dartclaw.dart --config "$DATA_DIR/dartclaw.yaml" \
      serve --data-dir "$DATA_DIR" --source-dir "$REPO_ROOT") >"$RESULT_DIR/$NAME-server.log" 2>&1 &
    SERVER_PID=$!
    for ((attempt=0; attempt<90; attempt++)); do
      kill -0 "$SERVER_PID" 2>/dev/null || { tail -60 "$RESULT_DIR/$NAME-server.log" >&2; exit 1; }
      curl -sf http://localhost:3343/health >/dev/null && break
      sleep 1
    done
    curl -sf http://localhost:3343/health >/dev/null || { echo 'FAIL: scenario server not ready' >&2; exit 1; }
    python3 "$SCRIPT_DIR/coding_results.py" "$provider" "$fixture" "$DATA_DIR" "$PROJECT" "$REMOTE" "$RESULT_DIR" "$BASELINE" ||
      matrix_status=1
    cleanup_server
    DATA_DIR=""
  done
done
exit "$matrix_status"

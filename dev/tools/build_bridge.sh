#!/usr/bin/env bash
# Cross-compiles the in-container bridge executable for every Linux container
# architecture DartClaw supports.
#
# The bridge and the host framing codec ship from the same source, so a build
# whose artifacts are distributed must run this before `embed_assets.dart`.
#
#   build_bridge.sh            binaries only, into build/bridge/ — what a source
#                              checkout resolves at runtime for local container work
#   build_bridge.sh --embed    additionally stages gzipped copies in
#                              build/bridge-embed/, which the asset generator embeds
#
# The two directories are separate on purpose: embedding ~6 MB of base64 into a
# generated Dart library is a release cost, not something local container work
# should pay on every analyze.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/build/bridge"
EMBED_DIR="$ROOT_DIR/build/bridge-embed"
ARCHES=(x64 arm64)
STAGE_FOR_EMBED=""

for arg in "$@"; do
  case "$arg" in
    --embed) STAGE_FOR_EMBED=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done

mkdir -p "$OUT_DIR"
[[ -n "$STAGE_FOR_EMBED" ]] && mkdir -p "$EMBED_DIR"

for arch in "${ARCHES[@]}"; do
  target="$OUT_DIR/dartclaw-bridge-linux-$arch"
  echo "==> Cross-compiling container bridge for linux-$arch"
  # `dart compile exe` cross-compiles standalone hook-free executables; the
  # bridge package has zero dependencies precisely so this stays possible.
  (cd "$ROOT_DIR/packages/dartclaw_bridge" \
    && dart compile exe bin/dartclaw_bridge.dart \
         --target-os=linux --target-arch="$arch" -o "$target")
  if [[ -n "$STAGE_FOR_EMBED" ]]; then
    gzip -9 -c "$target" > "$EMBED_DIR/dartclaw-bridge-linux-$arch.gz"
    echo "    staged dartclaw-bridge-linux-$arch.gz ($(wc -c < "$EMBED_DIR/dartclaw-bridge-linux-$arch.gz") bytes)"
  fi
done

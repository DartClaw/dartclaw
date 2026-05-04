#!/usr/bin/env bash
# Validates a publishable package copy with pana and dart pub publish --dry-run.
# Packages that still depend on unpublished sibling DartClaw packages fail fast
# with a clear message instead of attempting a broken dependency rewrite.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: bash dev/tools/validate_pana.sh <package-dir>" >&2
  exit 64
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PKG_DIR_INPUT="$1"
PKG_DIR=$(cd "$PKG_DIR_INPUT" && pwd)
PUBSPEC_PATH="$PKG_DIR/pubspec.yaml"

if [[ ! -f "$PUBSPEC_PATH" ]]; then
  echo "FAIL: pubspec.yaml not found in $PKG_DIR_INPUT" >&2
  exit 64
fi

if ! command -v pana >/dev/null 2>&1; then
  echo "FAIL: pana is not installed or not in PATH." >&2
  exit 1
fi

PKG_NAME=$(sed -n 's/^name:[[:space:]]*//p' "$PUBSPEC_PATH" | head -1)
TEMP_DIR=$(mktemp -d)
COPY_DIR="$TEMP_DIR/$PKG_NAME"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

SIBLING_DEP_PATTERN='path:[[:space:]]+(\.\./dartclaw|\.\./\.\./packages/dartclaw)'
if grep -Eq "$SIBLING_DEP_PATTERN" "$PUBSPEC_PATH"; then
  echo "SKIP: Cannot validate packages with unpublished sibling dependencies -- skipping full pana run for $PKG_NAME." >&2
  exit 1
fi

echo "Validating $PKG_NAME from $PKG_DIR..."
echo "Temp dir: $TEMP_DIR"

cp -R "$PKG_DIR" "$COPY_DIR"
cp "$REPO_ROOT/analysis_options.yaml" "$TEMP_DIR/analysis_options.yaml"
cp "$REPO_ROOT/analysis_options.yaml" "$COPY_DIR/analysis_options.yaml"

TMP_PUBSPEC="$TEMP_DIR/pubspec.yaml"
grep -vE '^(publish_to: none|resolution: workspace)$' "$COPY_DIR/pubspec.yaml" > "$TMP_PUBSPEC"
mv "$TMP_PUBSPEC" "$COPY_DIR/pubspec.yaml"

echo
echo "=== Modified pubspec.yaml ==="
cat "$COPY_DIR/pubspec.yaml"
echo

echo "=== Running pana ==="
if ! pana "$COPY_DIR"; then
  echo "FAIL: pana validation failed for $PKG_NAME." >&2
  exit 1
fi

echo
echo "=== Running dart pub publish --dry-run ==="
if ! (
  cd "$COPY_DIR"
  dart pub publish --dry-run
); then
  echo "FAIL: dart pub publish --dry-run failed for $PKG_NAME." >&2
  exit 1
fi

echo
echo "SUCCESS: Finished validating $PKG_NAME."

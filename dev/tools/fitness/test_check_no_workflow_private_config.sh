#!/usr/bin/env bash
# Regression test for check_no_workflow_private_config.sh.
#
# Creates a minimal synthetic tree with a rogue `_workflow*` write outside
# the allowlisted file and asserts the fitness script fails on it. This guards
# against the script narrowing back to only detect literal `configJson[...]`
# syntax, which previously missed real leaks such as `nextConfig['_workflow*']`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/check_no_workflow_private_config.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Synthesize a workspace with a rogue leak outside the allowlist.
mkdir -p "$TMPDIR/packages/rogue/lib"
cat > "$TMPDIR/packages/rogue/lib/leak.dart" <<'DART'
void leak(Map<String, dynamic> nextConfig) {
  nextConfig['_workflowProviderSessionId'] = 'x';
}
DART

mkdir -p "$TMPDIR/dev/tools/fitness"
cp "$SCRIPT" "$TMPDIR/dev/tools/fitness/"

cd "$TMPDIR"
if bash dev/tools/fitness/check_no_workflow_private_config.sh >/dev/null 2>&1; then
  echo "FAIL: fitness script did not detect rogue _workflow* write in packages/rogue/lib/leak.dart"
  exit 1
fi

# Remove the leak; script must pass again.
rm "$TMPDIR/packages/rogue/lib/leak.dart"
if ! bash dev/tools/fitness/check_no_workflow_private_config.sh >/dev/null 2>&1; then
  echo "FAIL: fitness script reported failure on a clean synthetic tree"
  exit 1
fi

echo "OK: fitness script detects rogue _workflow* leaks and passes on a clean tree"

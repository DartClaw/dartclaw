#!/usr/bin/env bash
# Regression test for check_no_workflow_private_config.sh.
#
# Exercise both sides of the ownership boundary in a synthetic tree. A rogue
# write can be missed if the scan checks only `configJson[...]` or exempts the
# whole workflow package instead of individual owners.
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

WORKFLOW_DIR='packages/dartclaw_workflow/lib/src/workflow'
mkdir -p "$WORKFLOW_DIR"
mv packages/rogue/lib/leak.dart "$WORKFLOW_DIR/leak.dart"
if bash dev/tools/fitness/check_no_workflow_private_config.sh >/dev/null 2>&1; then
  echo "FAIL: fitness script did not detect rogue _workflow* write in $WORKFLOW_DIR/leak.dart"
  exit 1
fi
rm "$WORKFLOW_DIR/leak.dart"

if ! bash dev/tools/fitness/check_no_workflow_private_config.sh >/dev/null 2>&1; then
  echo "FAIL: fitness script reported failure on a clean synthetic tree"
  exit 1
fi

cat > "$WORKFLOW_DIR/workflow_output_contract.dart" <<'DART'
const workflowExecutionSurfaceHoldKey = '_workflow.git.execution_surface_hold';
const workflowApprovedCandidateKey = '_workflow.git.approved_candidate';
DART
if ! bash dev/tools/fitness/check_no_workflow_private_config.sh; then
  echo "FAIL: fitness script rejected host approval keys in the workflow output contract"
  exit 1
fi

mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/rg" <<'SH'
#!/usr/bin/env bash
exit 2
SH
chmod +x "$TMPDIR/bin/rg"
if PATH="$TMPDIR/bin:$PATH" bash dev/tools/fitness/check_no_workflow_private_config.sh > "$TMPDIR/rg-error.log" 2>&1; then
  echo "FAIL: fitness script passed when rg could not scan"
  exit 1
fi
if grep -q 'Fitness function passed' "$TMPDIR/rg-error.log"; then
  echo "FAIL: fitness script printed a pass result after an rg scan error"
  exit 1
fi
grep -q 'rg scan error (exit 2)' "$TMPDIR/rg-error.log"

echo "OK: fitness script accepts private-key owners, rejects rogue writes, and fails on scan errors"

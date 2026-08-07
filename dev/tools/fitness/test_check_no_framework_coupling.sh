#!/usr/bin/env bash
# Regression test for check_no_framework_coupling.sh.
#
# Creates a minimal synthetic tree with framework literals in both legitimate
# and rogue locations. This guards against the excludes being widened to the
# point where the gate becomes toothless.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/check_no_framework_coupling.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/packages/dartclaw_workflow/lib/src/workflow/definitions"
cat > "$TMPDIR/packages/dartclaw_workflow/lib/src/workflow/definitions/built_in.yaml" <<'YAML'
steps:
  - skill: andthen:review
YAML

mkdir -p "$TMPDIR/packages/dartclaw_workflow/lib/src/generated"
cat > "$TMPDIR/packages/dartclaw_workflow/lib/src/generated/embedded_assets.g.dart" <<'DART'
const embeddedPath = 'skills/dartclaw-discover-andthen-plan/SKILL.md';
DART

mkdir -p "$TMPDIR/packages/dartclaw_workflow/lib/src/workflow"
touch \
  "$TMPDIR/packages/dartclaw_workflow/lib/src/workflow/review_scoring_fragment.dart" \
  "$TMPDIR/packages/dartclaw_workflow/lib/src/workflow/review_finding_derivations.dart" \
  "$TMPDIR/packages/dartclaw_workflow/lib/src/workflow/schema_presets.dart"

# Synthesize a rogue mixed-case literal under lib/src/skills. This is engine
# code, not the package-root bundled skill payload directory, so the gate must
# scan it.
mkdir -p "$TMPDIR/packages/dartclaw_workflow/lib/src/skills"
cat > "$TMPDIR/packages/dartclaw_workflow/lib/src/skills/rogue.dart" <<'DART'
const String skill = 'AndThen:review';
DART

mkdir -p "$TMPDIR/dev/tools/fitness"
cp "$SCRIPT" "$TMPDIR/dev/tools/fitness/"

cd "$TMPDIR"
if bash dev/tools/fitness/check_no_framework_coupling.sh >/dev/null 2>&1; then
  echo "FAIL: fitness script did not detect rogue AndThen literal in packages/dartclaw_workflow/lib/src/skills/rogue.dart"
  exit 1
fi

# Remove the rogue file; script must pass with allowed built-in YAML and generated-data literals.
rm "$TMPDIR/packages/dartclaw_workflow/lib/src/skills/rogue.dart"
if ! bash dev/tools/fitness/check_no_framework_coupling.sh >/dev/null 2>&1; then
  echo "FAIL: fitness script reported failure on a clean synthetic tree with allowed built-in YAML/generated literals"
  exit 1
fi

mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/rg" <<'SH'
#!/usr/bin/env bash
exit 2
SH
chmod +x "$TMPDIR/bin/rg"
if PATH="$TMPDIR/bin:$PATH" bash dev/tools/fitness/check_no_framework_coupling.sh > "$TMPDIR/rg-error.log" 2>&1; then
  echo "FAIL: fitness script passed when rg could not scan"
  exit 1
fi
if grep -q 'Fitness function passed' "$TMPDIR/rg-error.log"; then
  echo "FAIL: fitness script printed a pass result after an rg scan error"
  exit 1
fi
grep -q 'rg scan error (exit 2)' "$TMPDIR/rg-error.log"

echo "OK: fitness script detects rogue AndThen literals and permits built-in YAML/generated literals"

#!/usr/bin/env bash
# Regression test for check_no_prose_parsing.sh.
#
# Plants one violation per scanned group in a synthetic tree, and pins the
# legitimate string handling the gate must NOT match — the milestone keeps
# `'null'` as a JSON Schema type name and as the authored gate grammar, and a
# broader pattern would need the allowlist this gate refuses to ship.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/check_no_prose_parsing.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

WORKFLOW_LIB="$TMPDIR/packages/dartclaw_workflow/lib/src/workflow"
mkdir -p "$WORKFLOW_LIB" "$TMPDIR/packages/dartclaw_core/lib/src" "$TMPDIR/apps/dartclaw_cli/lib/src" \
  "$TMPDIR/packages/dartclaw_workflow/lib/src/generated" "$TMPDIR/dev/tools/fitness"
cp "$SCRIPT" "$TMPDIR/dev/tools/fitness/"
cat > "$TMPDIR/pubspec.yaml" <<'YAML'
name: scratch
workspace:
  - packages/dartclaw_workflow
  - packages/dartclaw_core
  - apps/dartclaw_cli
YAML
cd "$TMPDIR"

# The two files the sentinel scan names must exist, or the gate fails on that alone.
cat > "$WORKFLOW_LIB/context_extractor.dart" <<'DART'
String? claim(String raw) => raw.isEmpty ? null : raw;
DART
cat > "$WORKFLOW_LIB/produced_artifact_resolver.dart" <<'DART'
String? resolve(String raw) => raw.isEmpty ? null : raw;
DART

# Legitimate uses the gate must stay silent about.
cat > "$WORKFLOW_LIB/execution_envelope_schema.dart" <<'DART'
Map<String, Object?> nullable(String type) => {'type': [type, 'null']};
DART
cat > "$WORKFLOW_LIB/gate_evaluator.dart" <<'DART'
bool isNullGate(String op, String expected) => (op == '==') && expected == 'null';
DART

expect_pass() {
  if ! bash dev/tools/fitness/check_no_prose_parsing.sh >/dev/null 2>&1; then
    echo "FAIL: gate failed on a clean synthetic tree ($1)"
    bash dev/tools/fitness/check_no_prose_parsing.sh || true
    exit 1
  fi
}

expect_fail() {
  local label="$1" needle="$2" log="$TMPDIR/gate.log"
  if bash dev/tools/fitness/check_no_prose_parsing.sh > "$log" 2>&1; then
    echo "FAIL: gate passed with a planted $label"
    exit 1
  fi
  if ! grep -q "$needle" "$log"; then
    echo "FAIL: gate failed on a planted $label without naming '$needle'"
    cat "$log"
    exit 1
  fi
}

expect_pass 'baseline, with the legitimate JSON-Schema type and gate grammar present'

# 1. A retired output-recovery symbol, in a package.
cat > "$WORKFLOW_LIB/rogue.dart" <<'DART'
int? deriveReviewFindingCount(Map<String, Object?> payload) => payload.length;
DART
expect_fail 'retired output-recovery symbol' 'rogue.dart:1'
rm "$WORKFLOW_LIB/rogue.dart"

# 1b. The same symbol reintroduced private, which is how a library-level helper
#     comes back under lib/src. A word-boundary match cannot see this.
cat > "$WORKFLOW_LIB/rogue_private.dart" <<'DART'
int? _deriveReviewFindingCount(Map<String, Object?> payload) => payload.length;
DART
expect_fail 'privately renamed retired symbol' 'rogue_private.dart:1'
rm "$WORKFLOW_LIB/rogue_private.dart"

# 1c. A longer identifier that merely ends in a retired name is not a match.
cat > "$TMPDIR/apps/dartclaw_cli/lib/src/tasks_review_command.dart" <<'DART'
class TasksReviewCommand {}
DART
expect_pass 'a live command class whose name ends in a retired one'
rm "$TMPDIR/apps/dartclaw_cli/lib/src/tasks_review_command.dart"

# 2. A retired chat grammar, in an app - apps are in scope, packages/ alone is not enough.
cat > "$TMPDIR/apps/dartclaw_cli/lib/src/rogue_cli.dart" <<'DART'
class ReviewCommandParser {}
DART
expect_fail 'retired chat grammar in an app' 'rogue_cli.dart:1'
rm "$TMPDIR/apps/dartclaw_cli/lib/src/rogue_cli.dart"

# 3. The advisor mention detector.
cat > "$TMPDIR/packages/dartclaw_core/lib/src/rogue_mention.dart" <<'DART'
const mention = '@advisor';
DART
expect_fail 'advisor mention detector' 'rogue_mention.dart:1'
rm "$TMPDIR/packages/dartclaw_core/lib/src/rogue_mention.dart"

# 4. The 'null' path sentinel, back on the artifact-claim path.
cat > "$WORKFLOW_LIB/context_extractor.dart" <<'DART'
String? claim(String raw) => raw == 'null' ? null : raw;
DART
expect_fail "'null' path sentinel" 'context_extractor.dart:1'
cat > "$WORKFLOW_LIB/context_extractor.dart" <<'DART'
String? claim(String raw) => raw.isEmpty ? null : raw;
DART

# 5. Generated asset data is out of scope: it embeds arbitrary payloads.
cat > "$TMPDIR/packages/dartclaw_workflow/lib/src/generated/embedded_assets.g.dart" <<'DART'
const asset = 'deriveReviewFindingCount @advisor';
DART
expect_pass 'a retired symbol inside generated asset data'

# 5b. A workspace member outside packages/ and apps/ is not silently unscanned.
mkdir -p "$TMPDIR/dev/extra/lib"
echo 'class Extra {}' > "$TMPDIR/dev/extra/lib/extra.dart"
cat > "$TMPDIR/pubspec.yaml" <<'YAML'
name: scratch
workspace:
  - packages/dartclaw_workflow
  - packages/dartclaw_core
  - apps/dartclaw_cli
  - dev/extra
YAML
expect_fail 'workspace member outside packages/ and apps/' 'invisible to this gate'
rm -r "$TMPDIR/dev/extra"
cat > "$TMPDIR/pubspec.yaml" <<'YAML'
name: scratch
workspace:
  - packages/dartclaw_workflow
  - packages/dartclaw_core
  - apps/dartclaw_cli
YAML

# 6. A renamed claim file must fail, not silently scan nothing.
mv "$WORKFLOW_LIB/context_extractor.dart" "$WORKFLOW_LIB/claim_extractor.dart"
expect_fail 'renamed artifact-claim file' 'no longer exist'
mv "$WORKFLOW_LIB/claim_extractor.dart" "$WORKFLOW_LIB/context_extractor.dart"

# 7. A broken rg must fail loudly, never print a pass.
mkdir -p "$TMPDIR/bin"
printf '#!/usr/bin/env bash\nexit 2\n' > "$TMPDIR/bin/rg"
chmod +x "$TMPDIR/bin/rg"
if PATH="$TMPDIR/bin:$PATH" bash dev/tools/fitness/check_no_prose_parsing.sh > "$TMPDIR/rg-error.log" 2>&1; then
  echo "FAIL: gate passed when rg could not scan"
  exit 1
fi
grep -q 'Fitness function passed' "$TMPDIR/rg-error.log" && { echo "FAIL: gate printed a pass after an rg scan error"; exit 1; }
grep -q 'rg scan error (exit 2)' "$TMPDIR/rg-error.log"

echo "OK: prose-parsing gate catches each retired construct, in apps as well as packages, and leaves the kept string handling alone"

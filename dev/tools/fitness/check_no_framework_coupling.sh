#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

# Asserts that the workflow engine's Dart source carries no framework-specific
# literals (andthen / dartclaw-discover-andthen, case-insensitive).
#
# Scan scope: packages/dartclaw_workflow/lib/src/ only.
# Within that scope, two subtrees are excluded:
#   - **/definitions/*.yaml  (built-in workflow YAMLs reference skills by name — legitimate)
#   - **/generated/*         (generated embedded assets are data, not engine code)
#
# Note: packages/dartclaw_workflow/skills/ (bundled skill payloads at the package root) is
# outside the scan scope entirely and is not affected by these excludes.
#
# Any match outside the excluded subtrees is an undeclared framework dependency
# violating the governance invariant in ADR-041 (governance level 2, sibling to
# dev/tools/arch_check.dart — ADR-033).
#
# The case-insensitive match covers both `andthen` and `dartclaw-discover-andthen`
# (the latter is a subset of the former under -i).

rg_scan() {
  local description="$1" output rc
  shift
  output="$(rg "$@" 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) printf '%s' "$output" ;;
    1) ;;
    *)
      echo "Fitness function failed: rg scan error (exit $rc): $description" >&2
      [[ -z "$output" ]] || echo "$output" >&2
      return 2
      ;;
  esac
}

matches="$(rg_scan 'framework literals' -i 'andthen' packages/dartclaw_workflow/lib/src/ \
  -g '!**/definitions/*.yaml' \
  -g '!**/generated/*' \
  --with-filename -n)"
matches="$(printf '%s' "$matches" | sed '/^$/d')"

if [[ -n "$matches" ]]; then
  echo "Fitness function failed: andthen/dartclaw-discover-andthen literals in workflow engine source outside excluded built-in workflow YAMLs."
  echo "Excluded subtree within packages/dartclaw_workflow/lib/src/:"
  echo "  **/definitions/*.yaml  (built-in workflow YAMLs)"
  echo "  **/generated/*         (generated embedded asset data)"
  echo "Offending references:"
  echo "$matches"
  exit 1
fi

scoring_files=(
  "packages/dartclaw_workflow/lib/src/workflow/review_scoring_fragment.dart"
  "packages/dartclaw_workflow/lib/src/workflow/review_finding_derivations.dart"
  "packages/dartclaw_workflow/lib/src/workflow/schema_presets.dart"
)

scoring_pattern='FIS|Fix/Note|review-verdict\.md|fis-authoring-guidelines\.md'
scoring_matches="$(rg_scan 'framework scoring concepts' "$scoring_pattern" "${scoring_files[@]}" --with-filename -n)"
scoring_matches="$(printf '%s' "$scoring_matches" | sed '/^$/d')"

if [[ -n "$scoring_matches" ]]; then
  echo "Fitness function failed: framework-specific scoring concepts found in workflow scoring-path files."
  echo "Offending references:"
  echo "$scoring_matches"
  exit 1
fi

echo "Fitness function passed: no framework-coupling literals in workflow engine source (excluding definitions/*.yaml and generated assets), and no framework-specific scoring concepts in scoring-path files."

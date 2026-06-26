#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

# Asserts that the workflow engine's Dart source carries no framework-specific
# literals (andthen / dartclaw-discover-andthen, case-insensitive).
#
# Scan scope: packages/dartclaw_workflow/lib/src/ only.
# Within that scope, one subtree is excluded:
#   - **/definitions/*.yaml  (built-in workflow YAMLs reference skills by name — legitimate)
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

matches="$(rg -i 'andthen' packages/dartclaw_workflow/lib/src/ \
  -g '!**/definitions/*.yaml' \
  --with-filename -n 2>/dev/null || true)"
matches="$(printf '%s' "$matches" | sed '/^$/d')"

if [[ -n "$matches" ]]; then
  echo "Fitness function failed: andthen/dartclaw-discover-andthen literals in workflow engine source outside excluded built-in workflow YAMLs."
  echo "Excluded subtree within packages/dartclaw_workflow/lib/src/:"
  echo "  **/definitions/*.yaml  (built-in workflow YAMLs)"
  echo "Offending references:"
  echo "$matches"
  exit 1
fi

echo "Fitness function passed: no framework-coupling literals in packages/dartclaw_workflow/lib/src/ (excluding definitions/*.yaml)."

#!/usr/bin/env bash

# Verifies all published packages in the workspace share the same version.
# Usage: bash dev/tools/check_versions.sh [expected_version]
# Exit code 0 = all versions match, 1 = mismatch found.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION_FILE="$REPO_ROOT/packages/dartclaw_runtime/lib/src/version.dart"

pubspecs=(
  "$REPO_ROOT/packages/dartclaw/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_acp/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_bridge/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_client/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_core/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_kernel/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_testing/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_whatsapp/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_signal/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_google_chat/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_runtime/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_workflow/pubspec.yaml"
  "$REPO_ROOT/apps/dartclaw_cli/pubspec.yaml"
)

expected="${1:-}"
errors=0

for pubspec in "${pubspecs[@]}"; do
  version="$(grep '^version:' "$pubspec" | head -1 | sed 's/version: *//')"
  name="$(grep '^name:' "$pubspec" | head -1 | sed 's/name: *//')"

  if [[ -z "$expected" ]]; then
    expected="$version"
    echo "Reference version: $expected (from $name)"
  fi

  if [[ "$version" != "$expected" ]]; then
    echo "MISMATCH: $name has version $version (expected $expected)"
    errors=$((errors + 1))
  else
    echo "  OK: $name @ $version"
  fi
done

runtime_version="$(sed -n "s/^const dartclawVersion = '\([^']*\)';/\1/p" "$VERSION_FILE" | head -1)"
if [[ -z "$runtime_version" ]]; then
  echo "MISMATCH: unable to read dartclawVersion from $VERSION_FILE"
  errors=$((errors + 1))
elif [[ "$runtime_version" != "$expected" ]]; then
  echo "MISMATCH: dartclawVersion is $runtime_version (expected $expected)"
  errors=$((errors + 1))
else
  echo "  OK: dartclawVersion @ $runtime_version"
fi

if [[ $errors -gt 0 ]]; then
  echo
  echo "FAILED: $errors version mismatch(es) found."
  exit 1
fi

echo
echo "PASSED: All packages at version $expected."

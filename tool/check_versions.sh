#!/usr/bin/env bash

# Verifies all published packages in the workspace share the same version.
# Usage: bash tool/check_versions.sh [expected_version]
# Exit code 0 = all versions match, 1 = mismatch found.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

pubspecs=(
  "$REPO_ROOT/packages/dartclaw/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_core/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_models/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_security/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_storage/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_whatsapp/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_signal/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_google_chat/pubspec.yaml"
  "$REPO_ROOT/packages/dartclaw_server/pubspec.yaml"
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

if [[ $errors -gt 0 ]]; then
  echo
  echo "FAILED: $errors version mismatch(es) found."
  exit 1
fi

echo
echo "PASSED: All packages at version $expected."

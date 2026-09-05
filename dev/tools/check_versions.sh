#!/usr/bin/env bash

# Verifies all published packages in the workspace, and every packaging
# artifact that pins a version, share the same version.
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

# Packaging templates carry the same pin. The release renders them at tag time,
# so a drift here ships a formula or manifest pointing at assets that do not
# exist for that tag — and nothing else checks them.
for formula in "$REPO_ROOT/package/homebrew/dartclaw.rb" "$REPO_ROOT/package/homebrew/dartclaw-workflow.rb"; do
  name="package/homebrew/$(basename "$formula")"
  formula_version="$(sed -n 's/^  version "\([^"]*\)"/\1/p' "$formula" | head -1)"
  if [[ -z "$formula_version" ]]; then
    echo "MISMATCH: unable to read version from $name"
    errors=$((errors + 1))
  elif [[ "$formula_version" != "$expected" ]]; then
    echo "MISMATCH: $name has version $formula_version (expected $expected)"
    errors=$((errors + 1))
  else
    echo "  OK: $name @ $formula_version"
  fi
done

# The Scoop manifests additionally carry a concrete install-time URL, which must
# name the same version as the manifest's own version field.
for manifest in "$REPO_ROOT/package/scoop/dartclaw.json" "$REPO_ROOT/package/scoop/dartclaw-workflow.json"; do
  name="package/scoop/$(basename "$manifest")"
  artifact="$(basename "$manifest" .json)"
  manifest_version="$(sed -n 's/^  "version": "\([^"]*\)",/\1/p' "$manifest" | head -1)"
  if [[ -z "$manifest_version" ]]; then
    echo "MISMATCH: unable to read version from $name"
    errors=$((errors + 1))
  elif [[ "$manifest_version" != "$expected" ]]; then
    echo "MISMATCH: $name has version $manifest_version (expected $expected)"
    errors=$((errors + 1))
  elif ! grep -qF "/v$expected/$artifact-v$expected-windows-x64.zip" "$manifest"; then
    echo "MISMATCH: $name install-time URL does not name $artifact-v$expected-windows-x64.zip"
    errors=$((errors + 1))
  else
    echo "  OK: $name @ $manifest_version"
  fi
done

if [[ $errors -gt 0 ]]; then
  echo
  echo "FAILED: $errors version mismatch(es) found."
  exit 1
fi

echo
echo "PASSED: All packages at version $expected."

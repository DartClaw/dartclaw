#!/usr/bin/env bash
# Asserts that workspace pubspec.yaml files use the canonical versions of
# yaml (^3.1.3) and path (^1.9.1). Exits non-zero and prints offending lines
# when any constraint drifts from the baseline.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

YAML_BASELINE="^3.1.3"
PATH_BASELINE="^1.9.1"

failed=0

check_constraint() {
  local pubspec="$1"
  local dep="$2"
  local expected="$3"

  awk -v dep="$dep" -v expected="$expected" -v pubspec="$pubspec" '
    /^[^[:space:]][^:]*:/ {
      in_deps = ($0 == "dependencies:" || $0 == "dev_dependencies:")
    }
    in_deps && $0 ~ "^  " dep ":" {
      value = $0
      sub("^  " dep ":[[:space:]]*", "", value)
      if (value != expected) {
        printf("DRIFT: %s: %s: %s (expected %s)\n", pubspec, dep, value, expected) > "/dev/stderr"
        failed = 1
      }
    }
    END { exit failed }
  ' "$pubspec"
}

while IFS= read -r pubspec; do
  if ! check_constraint "$pubspec" "yaml" "$YAML_BASELINE"; then
    failed=1
  fi
  if ! check_constraint "$pubspec" "path" "$PATH_BASELINE"; then
    failed=1
  fi
done < <(find "$WORKSPACE_ROOT/packages" "$WORKSPACE_ROOT/apps" -name "pubspec.yaml" -not -path "*/.*")

if [[ $failed -ne 0 ]]; then
  exit 1
fi

echo "check-deps: all yaml and path constraints are aligned."

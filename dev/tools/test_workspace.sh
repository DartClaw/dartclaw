#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

echo "==> Testing developer tools"
bash dev/tools/parallels_windows_test.sh

SERIAL_TEST_TARGETS=(
  "packages/dartclaw_workflow"
  "packages/dartclaw_server"
  "apps/dartclaw_cli"
)

is_serial_target() {
  local package_path="$1"
  local target
  for target in "${SERIAL_TEST_TARGETS[@]}"; do
    if [[ "$package_path" == "$target" ]]; then
      return 0
    fi
  done
  return 1
}

while IFS= read -r package_path; do
  if [[ ! -d "${package_path}/test" ]]; then
    continue
  fi
  if is_serial_target "$package_path"; then
    continue
  fi

  echo "==> Testing ${package_path}"
  dart test --reporter=failures-only "${package_path}"
done < <(dart pub workspace list | awk 'NR > 1 && $2 != "./" { print $2 }')

serial_targets=()
for target in "${SERIAL_TEST_TARGETS[@]}"; do
  if [[ -d "${target}/test" ]]; then
    serial_targets+=("$target")
  fi
done

if [[ "${#serial_targets[@]}" -gt 0 ]]; then
  echo "==> Testing serialized: ${serial_targets[*]}"
  dart test -j 1 --reporter=failures-only "${serial_targets[@]}"
fi

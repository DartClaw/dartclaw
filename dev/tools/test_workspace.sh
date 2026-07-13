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
  package_path="${package_path%/}"
  package_path="${package_path#./}"
  if [[ ! -d "${package_path}/test" ]]; then
    continue
  fi
  if is_serial_target "$package_path"; then
    continue
  fi

  echo "==> Testing ${package_path}"
  (
    cd "${package_path}"
    dart test --reporter=failures-only
  )
done < <(dart pub workspace list | awk 'NR > 1 && $2 != "./" { print $2 }')

serial_targets=()
for target in "${SERIAL_TEST_TARGETS[@]}"; do
  if [[ -d "${target}/test" ]]; then
    serial_targets+=("$target")
  fi
done

if [[ "${#serial_targets[@]}" -gt 0 ]]; then
  echo "==> Testing serialized: ${serial_targets[*]}"
  for target in "${serial_targets[@]}"; do
    (
      cd "${target}"
      dart test -j 1 --reporter=failures-only
    )
  done
fi

#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

while IFS= read -r package_path; do
  if [[ ! -d "${package_path}/test" ]]; then
    continue
  fi

  echo "==> Testing ${package_path}"
  dart test --reporter=failures-only "${package_path}"
done < <(dart pub workspace list | awk 'NR > 1 && $2 != "./" { print $2 }')

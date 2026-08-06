#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

echo "==> Testing developer tools"
bash dev/tools/parallels_windows_test.sh
bash dev/tools/release_check_test.sh

# Every package runs at default parallelism. Suites share one OS process, so
# cross-suite coupling can only come through process-level state: ports (all
# binds use ephemeral port 0), the filesystem (all fixtures use temp dirs), and
# the working directory (no test assigns `Directory.current` outside
# dartclaw_config and dartclaw_cli, whose suites carry no cwd-dependent tests).
# Keep it that way — reintroducing a cwd mutator alongside a cwd-dependent test
# is what previously forced this script to serialize.
while IFS= read -r package_path; do
  package_path="${package_path%/}"
  package_path="${package_path#./}"
  if [[ ! -d "${package_path}/test" ]]; then
    continue
  fi

  echo "==> Testing ${package_path}"
  (
    cd "${package_path}"
    dart test --reporter=failures-only
  )
done < <(dart pub workspace list | awk 'NR > 1 && $2 != "./" { print $2 }')

#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -gt 0 && ( $# -ne 1 || $1 != --separate-fitness ) ]]; then
  echo "Usage: $0 [--separate-fitness]" >&2
  exit 2
fi

# Process substitution on the loop would swallow a failed pub command and run a partial list.
package_paths="$(dart pub workspace list | awk 'NR > 1 && $2 != "./" { print $2 }')"
if [[ -z "$package_paths" ]]; then
  echo "No workspace members discovered" >&2
  exit 1
fi

# A git worktree is a clean checkout with no gitignored files, so the generated
# libraries lib/ imports are absent there. Idempotent and ~1s.
echo "==> Generating embedded assets"
dart run dev/tools/embed_assets.dart

echo "==> Testing developer tools"
bash dev/tools/test_workspace_test.sh
bash dev/tools/parallels_linux_test.sh
bash dev/tools/parallels_windows_test.sh
bash dev/tools/contract_groups_check_test.sh
bash dev/tools/postgres_contract_test.sh
bash dev/testing/profiles/conversation-loop/visual_checks_test.sh
bash dev/tools/fitness/test_run_all_prerequisites.sh
bash dev/tools/fitness/test_check_no_workflow_private_config.sh
bash dev/tools/fitness/test_check_no_framework_coupling.sh

# Keep one Dart process per member. CLI and kernel tests can change its cwd.
while IFS= read -r package_path; do
  package_path="${package_path%/}"
  package_path="${package_path#./}"
  if [[ "${1:-}" == --separate-fitness && "$package_path" == dev/fitness ]]; then
    continue
  fi
  if [[ ! -d "${package_path}/test" ]]; then
    continue
  fi

  echo "==> Testing ${package_path}"
  (
    cd "${package_path}"
    dart test --reporter=failures-only
  )
done <<< "$package_paths"

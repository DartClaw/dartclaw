#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# A git worktree is a clean checkout with no gitignored files, so the generated
# libraries lib/ imports are absent there. Idempotent and ~1s.
echo "==> Generating embedded assets"
dart run dev/tools/embed_assets.dart

echo "==> Testing developer tools"
bash dev/tools/parallels_windows_test.sh
bash dev/tools/release_check_test.sh

# Every package runs at default parallelism. Suites share one OS process, so
# cross-suite coupling can only come through process-level state: ports (all
# binds use ephemeral port 0), the filesystem (all fixtures use temp dirs), and
# the working directory. Each package runs in its own `dart test` process, so a
# cwd mutator can only reach suites in the same package. The mutators live in
# dartclaw_config and dartclaw_cli; the only cwd readers beside them are the
# dartclaw_cli tool tests (homebrew_formula, scoop_manifest, build_tool,
# release_binaries_workflow), which try DARTCLAW_REPO_ROOT/GITHUB_WORKSPACE/PWD
# before falling back to `Directory.current`. One further reader,
# reload_trigger_service_sigusr1_test, has no env fallback but is
# integration-tagged and skipped by default. Keep it that way — a test that
# assigns `Directory.current` beside one that resolves a relative path is what
# previously forced this script to serialize.
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

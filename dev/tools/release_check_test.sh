#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dartclaw-release-check-test.XXXXXX")"
FAKE_GIT="$TEST_DIR/git"
UNEXPECTED_CALL="$TEST_DIR/unexpected-git-call"

if ! git -C "$ROOT_DIR" ls-files --error-unmatch pubspec.lock >/dev/null 2>&1; then
  echo "root workspace pubspec.lock must be tracked" >&2
  exit 1
fi
if ! grep -Fq 'dart pub get --enforce-lockfile' "$ROOT_DIR/.github/workflows/ci.yml"; then
  echo "CI must enforce the tracked workspace lockfile" >&2
  exit 1
fi
qualification_smoke_step="$(sed -n \
  '/      - name: Run x64 artifact smoke/,/      - name: Record provider evidence identity/p' \
  "$ROOT_DIR/.github/workflows/windows-x64-qualification.yml")"
for smoke_contract in \
  '[Diagnostics.ProcessStartInfo]::new()' \
  '$smokeProcess.ExitCode' \
  'if ($smokeExitCode -eq 2)'; do
  if [[ "$qualification_smoke_step" != *"$smoke_contract"* ]]; then
    echo "Windows qualification must inspect incomplete smoke results: $smoke_contract" >&2
    exit 1
  fi
done
if [[ "$qualification_smoke_step" == *'$LASTEXITCODE'* ]]; then
  echo 'Windows qualification cannot inspect expected smoke exit 2 through $LASTEXITCODE' >&2
  exit 1
fi
for release_lock_contract in \
  'section "3. Dependency lock"' \
  'git ls-files --error-unmatch pubspec.lock' \
  'dart pub get --enforce-lockfile' \
  'git diff --exit-code -- pubspec.lock'; do
  if ! grep -Fq "$release_lock_contract" "$ROOT_DIR/dev/tools/release_check.sh"; then
    echo "release check must enforce the tracked workspace lockfile: $release_lock_contract" >&2
    exit 1
  fi
done

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM

cat > "$FAKE_GIT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == "status --porcelain=v1 --untracked-files=all" ]]; then
  printf ' M tracked-file\n?? untracked-file\n'
  exit 0
fi

touch "$RELEASE_CHECK_UNEXPECTED_GIT_CALL"
exit 99
EOF
chmod 755 "$FAKE_GIT"

set +e
output="$(
  PATH="$TEST_DIR:$PATH" \
    RELEASE_CHECK_UNEXPECTED_GIT_CALL="$UNEXPECTED_CALL" \
    bash "$ROOT_DIR/dev/tools/release_check.sh" --version 0.21.0 --quick 2>&1
)"
exit_code=$?
set -e

if [[ "$exit_code" -ne 1 ]]; then
  echo "expected dirty-worktree rejection (exit 1), got $exit_code" >&2
  exit 1
fi
if [[ "$output" != *"Release check requires a clean worktree"* ]]; then
  echo "dirty-worktree rejection was not reported" >&2
  exit 1
fi
if [[ -e "$UNEXPECTED_CALL" ]]; then
  echo "release check did not fail before later git-backed gates" >&2
  exit 1
fi

echo "release_check dependency-lock and dirty-worktree gates: PASS"

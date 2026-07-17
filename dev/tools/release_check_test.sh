#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dartclaw-release-check-test.XXXXXX")"
FAKE_GIT="$TEST_DIR/git"
UNEXPECTED_CALL="$TEST_DIR/unexpected-git-call"

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

echo "release_check dirty-worktree gate: PASS"

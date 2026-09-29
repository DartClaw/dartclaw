#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$root_dir/.agent_temp"
fixture="$(mktemp -d "$root_dir/.agent_temp/postgres-contract-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/dev/tools" "$fixture/packages/dartclaw_core" \
  "$fixture/packages/dartclaw_runtime" "$fixture/apps/dartclaw_cli"
cp "$root_dir/dev/tools/postgres_contract.sh" "$fixture/dev/tools/"

cat > "$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "docker $*" >> "$POSTGRES_TEST_LOG"
case "$1" in
  info) exit "${POSTGRES_TEST_DOCKER_EXIT:-0}" ;;
  run) echo test-container ;;
  port) echo '127.0.0.1:49152' ;;
  exec)
    if [[ "$*" == *pg_isready* ]]; then
      exit "${POSTGRES_TEST_READY_EXIT:-0}"
    fi
    if [[ "${POSTGRES_TEST_INTERRUPT:-}" == 1 ]]; then
      kill -TERM "$PPID"
    fi
    exit "${POSTGRES_TEST_PROVISION_EXIT:-0}"
    ;;
  rm|logs) ;;
  *) exit 99 ;;
esac
EOF
cat > "$fixture/bin/dart" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "dart $* URL=${DARTCLAW_TEST_POSTGRES_URL:-}" >> "$POSTGRES_TEST_LOG"
exit "${POSTGRES_TEST_DART_EXIT:-0}"
EOF
cat > "$fixture/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fixture/bin/docker" "$fixture/bin/dart" "$fixture/bin/sleep"
export PATH="$fixture/bin:$PATH"
export POSTGRES_TEST_LOG="$fixture/commands.log"
unset DARTCLAW_TEST_POSTGRES_URL DARTCLAW_TEST_POSTGRES_PLAIN_URL DARTCLAW_TEST_PGVECTOR_URL

bash "$fixture/dev/tools/postgres_contract.sh" > "$fixture/output" 2>&1
if [[ "$(rg -c 'docker run .*127.0.0.1::5432' "$POSTGRES_TEST_LOG")" != 2 ]]; then
  echo 'The contract must provision separate plain PostgreSQL and pgvector databases.' >&2
  exit 1
fi
rg -q 'postgres:14@sha256:' "$POSTGRES_TEST_LOG"
rg -q 'pgvector/pgvector:pg14@sha256:' "$POSTGRES_TEST_LOG"
rg -q 'CREATE EXTENSION vector' "$POSTGRES_TEST_LOG"
rg -q 'URL=postgres://postgres:PostgresFixturePasswordX9@127.0.0.1:49152/dartclaw_test\?sslmode=disable' "$POSTGRES_TEST_LOG"
rg -q 'docker rm -f -v test-container' "$POSTGRES_TEST_LOG"
rg -q 'including managed research, rebuild, and temporary retention' "$fixture/output"

: > "$POSTGRES_TEST_LOG"
DARTCLAW_TEST_POSTGRES_PLAIN_URL='postgres://plain.invalid/test' \
  DARTCLAW_TEST_PGVECTOR_URL='postgres://vector.invalid/test' \
  bash "$fixture/dev/tools/postgres_contract.sh" > "$fixture/output" 2>&1
if rg -q '^docker ' "$POSTGRES_TEST_LOG"; then
  echo 'A supplied database must not start or remove containers.' >&2
  exit 1
fi
rg -q 'URL=postgres://plain.invalid/test' "$POSTGRES_TEST_LOG"
rg -q 'URL=postgres://vector.invalid/test' "$POSTGRES_TEST_LOG"

expect_failure() {
  local code="$1"
  local variable="$2"
  local value="$3"
  : > "$POSTGRES_TEST_LOG"
  local actual=0
  env "$variable=$value" bash "$fixture/dev/tools/postgres_contract.sh" > "$fixture/output" 2>&1 || actual=$?
  if [[ "$actual" != "$code" ]]; then
    cat "$fixture/output" >&2
    echo "Expected exit $code, got $actual" >&2
    exit 1
  fi
}

expect_failure 2 POSTGRES_TEST_DOCKER_EXIT 1
rg -q 'Start Docker, or set DARTCLAW_TEST_POSTGRES_PLAIN_URL and DARTCLAW_TEST_PGVECTOR_URL' "$fixture/output"
if rg -q '^dart |docker run |docker rm ' "$POSTGRES_TEST_LOG"; then
  echo 'An unavailable Docker engine must stop before provisioning or testing.' >&2
  exit 1
fi

expect_failure 2 POSTGRES_TEST_READY_EXIT 1
rg -q 'did not become ready' "$fixture/output"
rg -q 'docker rm -f -v test-container' "$POSTGRES_TEST_LOG"
if [[ "$(rg -c pg_isready "$POSTGRES_TEST_LOG")" != 60 ]]; then
  echo 'Database readiness must have a bounded number of attempts.' >&2
  exit 1
fi

expect_failure 7 POSTGRES_TEST_PROVISION_EXIT 7
rg -q 'docker rm -f -v test-container' "$POSTGRES_TEST_LOG"
if rg -q 'postgres_schema_gate_vector_live_test.dart' "$POSTGRES_TEST_LOG"; then
  echo 'Failed pgvector provisioning must not run vector tests.' >&2
  exit 1
fi

expect_failure 9 POSTGRES_TEST_DART_EXIT 9
rg -q 'docker rm -f -v test-container' "$POSTGRES_TEST_LOG"

expect_failure 143 POSTGRES_TEST_INTERRUPT 1
rg -q 'docker rm -f -v test-container' "$POSTGRES_TEST_LOG"

echo 'postgres_contract_test: PASS'

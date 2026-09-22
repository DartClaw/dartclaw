#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
container=""

cleanup() {
  if [[ -n "$container" ]]; then
    docker rm -f -v "$container" >/dev/null
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "Start Docker, or set DARTCLAW_TEST_POSTGRES_PLAIN_URL and DARTCLAW_TEST_PGVECTOR_URL to disposable PostgreSQL 14+ databases (see dev/guidelines/TESTING-STRATEGY.md)." >&2
    exit 2
  fi
}

start_database() {
  local image="$1"
  local label="$2"
  echo "==> Starting disposable $label" >&2
  container="$(docker run -d --rm -e POSTGRES_PASSWORD=PostgresFixturePasswordX9 -e POSTGRES_DB=dartclaw_test \
    -p 127.0.0.1::5432 "$image")"
  local ready=false
  for ((attempt = 0; attempt < 60; attempt++)); do
    if docker exec "$container" pg_isready --host 127.0.0.1 --username postgres --dbname dartclaw_test >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  if [[ "$ready" != true ]]; then
    echo "PostgreSQL did not become ready within 60 attempts." >&2
    docker logs "$container" >&2
    exit 2
  fi
  local address
  address="$(docker port "$container" 5432/tcp)"
  export DARTCLAW_TEST_POSTGRES_URL="postgres://postgres:PostgresFixturePasswordX9@$address/dartclaw_test?sslmode=disable"
}

stop_database() {
  if [[ -n "$container" ]]; then
    docker rm -f -v "$container" >/dev/null
    container=""
  fi
}

run_plain_lane() {
  export DARTCLAW_TEST_SEARCH_BACKEND=lexical
  local report_dir="$root_dir/build/postgres-contract"
  local manifest="$root_dir/packages/dartclaw_core/test/storage/contract/contract_groups.json"
  local postgres_report="$report_dir/postgres.json"
  mkdir -p "$report_dir"

  (
    cd "$root_dir/packages/dartclaw_core"
    dart test --run-skipped -t integration --reporter=failures-only --concurrency=1 \
      --file-reporter=json:"$postgres_report" \
      test/storage/contract/postgres_backend_contract_test.dart \
      test/storage/postgres_backend_live_test.dart \
      test/storage/postgres_schema_gate_live_test.dart \
      test/storage/postgres_interlock_live_test.dart \
      test/storage/sqlite_to_postgres_migration_live_test.dart \
      test/storage/index_reconciler_postgres_live_test.dart \
      test/search/postgres_fts_index_live_test.dart \
      test/search/conversation_index_postgres_live_test.dart \
      test/search/conversation_search_backends_contract_test.dart \
      test/knowledge/postgres_fact_search_live_test.dart
  )

  (
    cd "$root_dir/packages/dartclaw_runtime"
    dart test --run-skipped -t integration --reporter=failures-only --concurrency=1 \
      test/runtime/storage_wiring_postgres_live_test.dart \
      test/runtime/storage_wiring_postgres_search_live_test.dart \
      test/runtime/storage_wiring_postgres_interlock_live_test.dart \
      test/integration/postgres_serve_run_probe_test.dart \
      test/integration/workspace_memory_postgres_live_test.dart
  )

  (
    cd "$root_dir/apps/dartclaw_cli"
    dart test --run-skipped -t integration --reporter=failures-only --concurrency=1 \
      test/commands/postgres_sanctioned_clients_live_test.dart \
      test/commands/rebuild_index_command_postgres_live_test.dart
  )

  dart run "$root_dir/dev/tools/contract_groups_check.dart" \
    --manifest "$manifest" --expect shared,postgres --report "$postgres_report"
}

run_vector_lane() {
  export DARTCLAW_TEST_SEARCH_BACKEND=hybrid
  (
    cd "$root_dir/packages/dartclaw_core"
    dart test --run-skipped -t integration --reporter=failures-only --concurrency=1 \
      test/storage/postgres_schema_gate_vector_live_test.dart \
      test/search/postgres_vector_index_live_test.dart
  )

  (
    cd "$root_dir/packages/dartclaw_runtime"
    dart test --run-skipped -t integration --reporter=failures-only --concurrency=1 \
      test/runtime/storage_wiring_hybrid_postgres_live_test.dart \
      test/integration/workspace_memory_postgres_live_test.dart
  )

  (
    cd "$root_dir/apps/dartclaw_cli"
    dart test --run-skipped -t integration --reporter=failures-only --concurrency=1 \
      test/commands/rebuild_index_command_postgres_live_test.dart
  )
}

plain_url="${DARTCLAW_TEST_POSTGRES_PLAIN_URL:-${DARTCLAW_TEST_POSTGRES_URL:-}}"
vector_url="${DARTCLAW_TEST_PGVECTOR_URL:-${DARTCLAW_TEST_POSTGRES_URL:-}}"
if [[ -z "$plain_url" || -z "$vector_url" ]]; then
  require_docker
fi

if [[ -n "$plain_url" ]]; then
  echo "==> Using supplied plain PostgreSQL test database"
  export DARTCLAW_TEST_POSTGRES_URL="$plain_url"
else
  start_database \
    "postgres:14@sha256:816cf7d06ec33116c8f54cf14197085be89f25291686229485ee7d53a785b901" \
    "PostgreSQL 14 without optional extensions"
fi
run_plain_lane
stop_database

if [[ -n "$vector_url" ]]; then
  echo "==> Using supplied pgvector test database"
  export DARTCLAW_TEST_POSTGRES_URL="$vector_url"
else
  start_database \
    "pgvector/pgvector:pg14@sha256:fb27b00a92028f4749bf18f3d31b18fc62510258326486fb8900653ab2701252" \
    "PostgreSQL 14 with pgvector"
  docker exec "$container" psql --host 127.0.0.1 --username postgres --dbname dartclaw_test --set ON_ERROR_STOP=1 \
    --command 'CREATE EXTENSION vector WITH SCHEMA public'
fi
run_vector_lane

echo "PostgreSQL plain and pgvector gates passed, including managed research, rebuild, and temporary retention."

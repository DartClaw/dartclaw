#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DARTCLAW_TEST_POSTGRES_URL:-}" ]]; then
  echo "DARTCLAW_TEST_POSTGRES_URL is required" >&2
  exit 2
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
report_dir="$root_dir/build/postgres-contract"
manifest="$root_dir/packages/dartclaw_core/test/storage/contract/contract_groups.json"
sqlite_report="$report_dir/sqlite.json"
postgres_report="$report_dir/postgres.json"
mkdir -p "$report_dir"

(
  cd "$root_dir/packages/dartclaw_core"
  dart test --reporter=failures-only --file-reporter=json:"$sqlite_report" test/storage/contract/sqlite_backend_contract_test.dart
)
dart run "$root_dir/dev/tools/contract_groups_check.dart" --manifest "$manifest" --expect shared,sqlite --report "$sqlite_report"

(
  cd "$root_dir/packages/dartclaw_core"
  dart test --run-skipped -t integration --reporter=failures-only --file-reporter=json:"$postgres_report" test/storage/contract/postgres_backend_contract_test.dart test/storage/postgres_backend_live_test.dart test/storage/postgres_schema_gate_live_test.dart test/search/postgres_fts_index_live_test.dart test/knowledge/postgres_fact_search_live_test.dart test/storage/index_reconciler_postgres_live_test.dart
)

(
  cd "$root_dir/packages/dartclaw_runtime"
  dart test --run-skipped -t integration --reporter=failures-only --concurrency=1 test/runtime/storage_wiring_postgres_live_test.dart test/runtime/storage_wiring_postgres_search_live_test.dart
)

(
  cd "$root_dir/apps/dartclaw_cli"
  dart test --run-skipped -t integration --reporter=failures-only --concurrency=1 test/commands/rebuild_index_command_postgres_live_test.dart test/commands/postgres_sanctioned_clients_live_test.dart
)

dart run "$root_dir/dev/tools/contract_groups_check.dart" --manifest "$manifest" --expect shared,postgres --report "$postgres_report"

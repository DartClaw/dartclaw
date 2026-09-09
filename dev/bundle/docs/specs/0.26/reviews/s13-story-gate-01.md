Intent Context: dev/bundle/docs/specs/0.26/s13-conversation-message-index-rider.md

## Fix

None.

## Note

None.

Finding closure map:

- PostgreSQL schema initialization selected the sole search table -> select `memory_chunks` by name and cover both corpus vectors, GIN indexes, reopen, refusal, and rollback inventory -> targeted live PostgreSQL bootstrap/refusal suite passed 2 tests.
- SQLite accepted one half of the legacy memory rebuild callback pair -> refuse the XOR case before any corpus callback or schema mutation -> owning SQLite schema-gate suite passed 12 tests.
- Data-model recovery and lifecycle rows described memory-only rebuilds and underreported direct-session protection -> describe both projections and the enforced channel/cron protection -> focused source and documentation closure found no remaining contradiction.

Guardrails Coverage: 18 checked, 0 findings
Files: CHANGELOG.md, apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart, apps/dartclaw_cli/test/commands/rebuild_index_command_postgres_live_test.dart, apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart, apps/dartclaw_cli/test/commands/rebuild_index_conversation_test.dart, dev/architecture/data-model.md, dev/state/UBIQUITOUS_LANGUAGE.md, dev/tools/arch_check.dart, docs/guide/search.md, docs/guide/workspace.md, packages/dartclaw_core/lib/dartclaw_core.dart, packages/dartclaw_core/lib/src/search/conversation_index_projection.dart, packages/dartclaw_core/lib/src/search/conversation_indexer.dart, packages/dartclaw_core/lib/src/search/conversation_search_service.dart, packages/dartclaw_core/lib/src/search/postgres_fts_index.dart, packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart, packages/dartclaw_core/lib/src/storage/index_reconciler.dart, packages/dartclaw_core/lib/src/storage/message_service.dart, packages/dartclaw_core/lib/src/storage/postgres_schema_gate.dart, packages/dartclaw_core/lib/src/storage/schema_identity.dart, packages/dartclaw_core/lib/src/storage/session_service.dart, packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart, packages/dartclaw_core/test/search/conversation_index_postgres_live_test.dart, packages/dartclaw_core/test/search/conversation_index_projection_test.dart, packages/dartclaw_core/test/search/conversation_indexer_test.dart, packages/dartclaw_core/test/search/sqlite_fts_index_test.dart, packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart, packages/dartclaw_core/test/storage/index_reconciler_test.dart, packages/dartclaw_core/test/storage/message_service_test.dart, packages/dartclaw_core/test/storage/postgres_schema_gate_live_test.dart, packages/dartclaw_core/test/storage/session_service_test.dart, packages/dartclaw_core/test/storage/sqlite_schema_gate_search_test.dart, packages/dartclaw_kernel/lib/src/models.dart, packages/dartclaw_kernel/test/session_test.dart, packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart, packages/dartclaw_runtime/test/runtime/storage_wiring_conversation_index_test.dart, packages/dartclaw_runtime/test/session/session_lifecycle_conversation_index_test.dart, packages/dartclaw_testing/lib/dartclaw_testing.dart, packages/dartclaw_testing/lib/src/in_memory_session_service.dart, packages/dartclaw_testing/test/in_memory_session_service_test.dart
Story-Gate: PASS @ a087f9d8005a+c3689f09e940

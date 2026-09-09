Intent Context: dev/bundle/docs/specs/0.26/s13-conversation-message-index-rider.md

Prior Review: s13-story-gate-01.md at a087f9d8005a+c3689f09e940

## Fix

None.

## Note

None.

Finding closure map:

- The released 0.25 search fixture was compared to the expanded current manifest -> preserve the historical fixture, assert that it is incompatible because the conversation corpus is absent, and separately prove the current bootstrap matches all eight declared SQLite objects -> focused two-file suite passed 34 tests.
- The SQLite rollback snapshot queried the new conversation FTS virtual/shadow tables as ordinary tables -> exclude both memory and conversation FTS table families from row snapshots while retaining their object DDL and both base-table rows -> focused two-file suite passed 34 tests; analyzer and diff check passed.

Guardrails Coverage: 20 checked, 0 findings
Files: CHANGELOG.md, apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart, apps/dartclaw_cli/test/commands/rebuild_index_command_postgres_live_test.dart, apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart, apps/dartclaw_cli/test/commands/rebuild_index_conversation_test.dart, dev/architecture/data-model.md, dev/state/UBIQUITOUS_LANGUAGE.md, dev/tools/arch_check.dart, docs/guide/search.md, docs/guide/workspace.md, packages/dartclaw_core/lib/dartclaw_core.dart, packages/dartclaw_core/lib/src/search/conversation_index_projection.dart, packages/dartclaw_core/lib/src/search/conversation_indexer.dart, packages/dartclaw_core/lib/src/search/conversation_search_service.dart, packages/dartclaw_core/lib/src/search/postgres_fts_index.dart, packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart, packages/dartclaw_core/lib/src/storage/index_reconciler.dart, packages/dartclaw_core/lib/src/storage/message_service.dart, packages/dartclaw_core/lib/src/storage/postgres_schema_gate.dart, packages/dartclaw_core/lib/src/storage/schema_identity.dart, packages/dartclaw_core/lib/src/storage/session_service.dart, packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart, packages/dartclaw_core/test/search/conversation_index_postgres_live_test.dart, packages/dartclaw_core/test/search/conversation_index_projection_test.dart, packages/dartclaw_core/test/search/conversation_indexer_test.dart, packages/dartclaw_core/test/search/sqlite_fts_index_test.dart, packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart, packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart, packages/dartclaw_core/test/storage/index_reconciler_test.dart, packages/dartclaw_core/test/storage/message_service_test.dart, packages/dartclaw_core/test/storage/postgres_schema_gate_live_test.dart, packages/dartclaw_core/test/storage/schema_identity_test.dart, packages/dartclaw_core/test/storage/session_service_test.dart, packages/dartclaw_core/test/storage/sqlite_schema_gate_search_test.dart, packages/dartclaw_kernel/lib/src/models.dart, packages/dartclaw_kernel/test/session_test.dart, packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart, packages/dartclaw_runtime/test/runtime/storage_wiring_conversation_index_test.dart, packages/dartclaw_runtime/test/session/session_lifecycle_conversation_index_test.dart, packages/dartclaw_testing/lib/dartclaw_testing.dart, packages/dartclaw_testing/lib/src/in_memory_session_service.dart, packages/dartclaw_testing/test/in_memory_session_service_test.dart
Story-Gate: PASS @ a087f9d8005a+788ada3596af

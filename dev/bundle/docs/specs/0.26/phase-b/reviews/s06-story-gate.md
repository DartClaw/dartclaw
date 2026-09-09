Intent Context: `/Users/tobias/Repos/Libs/dartclaw/dartclaw-public/dev/bundle/docs/specs/0.26/phase-b/s06-retrieval-inspection-and-turn-source-provenance.md`

## Fix

None.

## Note

None.

Coverage evidence: reviewed the immutable `ToolCallRecord.sourceLocators` JSON/value contract and existing `turns.tool_calls` round trip; successful correlated `memory_search` extraction with exact first-order deduplication, 50-item cap, failure/unmatched/other-tool/malformed-output fallbacks; authenticated closed-body inspection for memory and conversation through the existing guarded owners; result identity, bounded Unicode snippets, backend-native order/scores, content-free diagnostics, unavailable/error containment, owner scope and deferred diagnostic release; connected root CLI request, authentication/error policy, human nullable-rank rendering and JSON identity; server composition, causal callers, architecture updates and the exact core ceiling. The supplied focused evidence covers 76 trace/model/storage/API/provenance tests, 24 CLI/runner tests, 61 route/server/conversation tests, analyzer success for all 18 changed Dart files and formatting. No broad, live, native or fast-tier command was rerun in this review.

Applied inline severity calibration and the critic pass (Findings Filter skipped: no Critical findings and <=5 total).

Guardrails Coverage: 12 checked, 0 findings

Files: CHANGELOG.md, apps/dartclaw_cli/lib/src/commands/search_command.dart, apps/dartclaw_cli/lib/src/commands/search_inspect_command.dart, apps/dartclaw_cli/test/commands/search_inspect_command_test.dart, dev/architecture/cli-api-architecture.md, dev/architecture/data-model.md, dev/architecture/observability-operations-architecture.md, dev/tools/arch_check.dart, packages/dartclaw_core/lib/src/search/conversation_search_service.dart, packages/dartclaw_core/lib/src/turn/tool_call_record.dart, packages/dartclaw_core/test/search/conversation_indexer_test.dart, packages/dartclaw_core/test/storage/turn_trace_service_test.dart, packages/dartclaw_core/test/task/tool_call_record_test.dart, packages/dartclaw_core/test/task/turn_trace_test.dart, packages/dartclaw_runtime/lib/src/api/search_inspection_routes.dart, packages/dartclaw_runtime/lib/src/runtime/service_wiring_builder.dart, packages/dartclaw_runtime/lib/src/server.dart, packages/dartclaw_runtime/lib/src/server_deps.dart, packages/dartclaw_runtime/lib/src/turn_guard_evaluator.dart, packages/dartclaw_runtime/test/api/search_inspection_routes_test.dart, packages/dartclaw_runtime/test/api/trace_routes_test.dart, packages/dartclaw_runtime/test/server_test.dart, packages/dartclaw_runtime/test/turn_guard_evaluator_test.dart

Story-Gate: PASS @ 3f3150e45601+6d2931ed2557

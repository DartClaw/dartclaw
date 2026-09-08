Intent Context: /Users/tobias/Repos/Libs/dartclaw/dartclaw-public/dev/bundle/docs/specs/0.26/s01-databasebackend-seam-and-sqlite-backend.md

## Fix

### F8-R1

- reviewer: Gap closure, Gap Critic
- severity: MEDIUM
- confidence: 100
- location: packages/dartclaw_core/test/storage/sqlite_backend_test.dart:312
- scope_relation: primary
- finding: F8 regression checks original error identity but not original stack preservation.
- threatened_assumption_or_invariant: FIS Technical Overview #3 and DatabaseBackend.transaction require the original body error and stack after rollback cleanup fails.
- evidence: throwsA(same(bodyError)) checks identity only. Root isolated Dart and real-SQLite probes confirmed normal throw replaces the stack with the backend catch site.
- impact: Stack-preservation can regress while the owning test stays green.
- suggested_fix: Capture the body-site stack, catch transaction error and stack, assert error identity and original stack equality. Production code remains unchanged.
- verification_needed: Original real-SQLite assertion passes; isolated normal-throw mutation fails; focused backend suite passes.
- Class: code-defect
- Routing: Fix – bounded primary proof correction.

Inline filter validated the single finding against the contract and actual isolated mutation. Both code passes were clean; F1-F5/F7 closed and F8 production is correct.

Guardrails Coverage: 12 checked, 0 findings
Files: dev/architecture/context-map.md, dev/architecture/data-model.md, dev/architecture/system-architecture.md, packages/dartclaw_core/lib/dartclaw_core.dart, packages/dartclaw_core/lib/src/storage/sql_placeholder_rewriter.dart, packages/dartclaw_core/lib/src/storage/sqlite_backend.dart, packages/dartclaw_core/lib/src/storage/sqlite_goal_repository.dart, packages/dartclaw_core/test/storage/sql_placeholder_rewriter_test.dart, packages/dartclaw_core/test/storage/sqlite_backend_test.dart, packages/dartclaw_core/test/storage/sqlite_goal_repository_test.dart, packages/dartclaw_kernel/lib/dartclaw_kernel.dart, packages/dartclaw_kernel/lib/src/database_backend.dart, packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart, packages/dartclaw_runtime/test/api/goal_routes_test.dart, packages/dartclaw_runtime/test/server_test.dart, packages/dartclaw_runtime/test/task/budget_enforcement_test.dart
Story-Gate: FAIL @ b545fc9797f2+2216defdc62d

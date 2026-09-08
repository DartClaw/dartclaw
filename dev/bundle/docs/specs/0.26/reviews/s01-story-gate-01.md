Intent Context: dev/bundle/docs/specs/0.26/s01-databasebackend-seam-and-sqlite-backend.md

## Fix

### F1: Active explicit tx handles and transaction-bound statements routed through owner._run self-deadlock when called via Zone.root from an awaited transaction body.

- reviewer: Code
- severity: HIGH
- confidence: 100
- location: packages/dartclaw_core/lib/src/storage/sqlite_backend.dart:166
- scope_relation: primary
- finding: Active explicit tx handles and transaction-bound statements routed through owner._run self-deadlock when called via Zone.root from an awaited transaction body.
- threatened_assumption_or_invariant: OC02/Technical Overview3: explicit transaction handles join; ambient zone only discriminates owner reentrancy.
- evidence: tx._run and bound statements call owner._run, which queues absent matching ambient zone behind the open transaction.
- impact: Indefinite transaction deadlock for active explicit handles.
- suggested_fix: Route active tx and bound statements via their explicit transaction identity; keep owner operations zone-gated.
- verification_needed: Real SQLite Zone.root tx.execute/query/prepare plus bound statement execute/query/close, completion and rollback membership.
- Class: code-defect
- Routing: Fix

### F2: No stale-zone isolation regression test protects active transaction identity/liveness matching.

- reviewer: Code, Gap Critic
- severity: HIGH
- confidence: 100
- location: packages/dartclaw_core/test/storage/sqlite_backend_test.dart:127
- scope_relation: primary
- finding: No stale-zone isolation regression test protects active transaction identity/liveness matching.
- threatened_assumption_or_invariant: FIS TI05 explicitly requires stale/foreign contexts to queue.
- evidence: Current tests only root-zone unrelated and current-zone reentrant; none retains transaction A zone during transaction B.
- impact: Presence-only matcher regression can corrupt isolation while tests pass; current implementation comparison is correct.
- suggested_fix: Handshake test stale A zone write during B; write waits and survives B rollback. Foreign backend if meaningful (zone key is per-owner).
- verification_needed: Mutation on isolated copy replacing full identity/liveness matcher with presence-only must fail.
- Class: code-defect
- Routing: Fix

### F3: New file imports package before dart:async.

- reviewer: Guardrails
- severity: LOW
- confidence: 100
- location: packages/dartclaw_core/lib/src/storage/sqlite_backend.dart:1
- scope_relation: primary
- finding: New file imports package before dart:async.
- threatened_assumption_or_invariant: DART-EFFECTIVE Import Organization.
- evidence: First package:kernel, then dart:async, then package:sqlite3.
- impact: Declared import convention violated.
- suggested_fix: dart imports first, package imports alphabetized.
- verification_needed: Format/analyze.
- Class: code-defect
- Routing: Fix

### F4: Parity suite only roundtrips new writes; no raw released-row fixture, nonnull maxTokens, storage types or tie ordering proof.

- reviewer: Gap, Gap Critic
- severity: MEDIUM
- confidence: 100
- location: packages/dartclaw_core/test/storage/sqlite_goal_repository_test.dart:11
- scope_relation: primary
- finding: Parity suite only roundtrips new writes; no raw released-row fixture, nonnull maxTokens, storage types or tie ordering proof.
- threatened_assumption_or_invariant: S01 OC01/OC03/SC04 old-row compatibility and unchanged SQLite representation.
- evidence: Only setup changed; helper omits maxTokens; no raw rows/typeof assertions.
- impact: Symmetric marshalling drift can pass advertised parity proof.
- suggested_fix: Seed raw RELEASED-0.25 goals DDL/row before open, read all fields; insert nonnull-token goal and inspect raw created_at TEXT/max_tokens INTEGER and timestamp tie ordering. Do not invent older schema support beyond the story.
- verification_needed: Focused test and isolated marshalling mutation falsifier.
- Class: code-defect
- Routing: Fix

### F5: Public dartdoc promises global serialization for all backends and idempotent close for transaction views, contradicting plan and implementation.

- reviewer: Gap
- severity: MEDIUM
- confidence: 100
- location: packages/dartclaw_kernel/lib/src/database_backend.dart:24
- scope_relation: primary
- finding: Public dartdoc promises global serialization for all backends and idempotent close for transaction views, contradicting plan and implementation.
- threatened_assumption_or_invariant: Shared decision SQLite alone serializes unrelated operations; tx.close rejects, owner.close idempotent.
- evidence: transaction doc unqualified unrelated waits; close doc unconditional no-ops; tx.close alwaysStateError.
- impact: Wrong contract for PostgreSQL/consumers.
- suggested_fix: Distinguish SQLite concurrency, explicit handles and owner lifecycle; tx rejects close/use after completion.
- verification_needed: Read against FIS/shared decisions; kernel analyze.
- Class: code-defect
- Routing: Fix

### F7: Owner-prepared statement close after backend close throws before finalizing.

- reviewer: Code Critic
- severity: LOW
- confidence: 75
- location: packages/dartclaw_core/lib/src/storage/sqlite_backend.dart:218
- scope_relation: primary
- finding: Owner-prepared statement close after backend close throws before finalizing.
- threatened_assumption_or_invariant: DatabaseStatement.close releases resources/idempotent with no documented backend-first prohibition.
- evidence: close routes owner._run -> _ensureOpen before _closeDirect.
- impact: Defensive cleanup fails; native statement may remain outstanding.
- suggested_fix: Permit direct statement finalization after owner closes or finalize on shutdown, preserving active queue ordering.
- verification_needed: Real SQLite prepare, owner.close, statement.close twice, execute/query remain StateError.
- Class: code-defect
- Routing: Fix

### F8: Rollback failure replaces original body error.

- reviewer: Code Critic
- severity: MEDIUM
- confidence: 100
- location: packages/dartclaw_core/lib/src/storage/sqlite_backend.dart:49
- scope_relation: primary
- finding: Rollback failure replaces original body error.
- threatened_assumption_or_invariant: transaction rethrows original body error after rollback.
- evidence: Catch executes unguarded ROLLBACK before Error.throwWithStackTrace; SQLite auto-abort means rollback itself can fail.
- impact: Callers receive secondary error instead of original failure.
- suggested_fix: Preserve body error/stack through rollback cleanup without inventing logging/exception hierarchy.
- verification_needed: Real SQLite auto-rollback or ended transaction then original body error, backend still usable.
- Class: code-defect
- Routing: Fix

Formal Findings Filter: 6 validated, 1 downgraded, 1 withdrawn. F6 withdrawn: concurrent pilot initialization is outside the single-construction FIS contract; schema transactions would violate its shared raw-connection constraint.

Guardrails Coverage: 12 checked, 1 finding
Files: dev/architecture/context-map.md, dev/architecture/data-model.md, dev/architecture/system-architecture.md, packages/dartclaw_core/lib/dartclaw_core.dart, packages/dartclaw_core/lib/src/storage/sql_placeholder_rewriter.dart, packages/dartclaw_core/lib/src/storage/sqlite_backend.dart, packages/dartclaw_core/lib/src/storage/sqlite_goal_repository.dart, packages/dartclaw_core/test/storage/sql_placeholder_rewriter_test.dart, packages/dartclaw_core/test/storage/sqlite_backend_test.dart, packages/dartclaw_core/test/storage/sqlite_goal_repository_test.dart, packages/dartclaw_kernel/lib/dartclaw_kernel.dart, packages/dartclaw_kernel/lib/src/database_backend.dart, packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart, packages/dartclaw_runtime/test/api/goal_routes_test.dart, packages/dartclaw_runtime/test/server_test.dart, packages/dartclaw_runtime/test/task/budget_enforcement_test.dart
Story-Gate: FAIL @ b545fc9797f2+4f0f8e1b240c

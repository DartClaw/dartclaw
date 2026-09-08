# FIS: DatabaseBackend Seam and SQLite Backend

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S01

_Refreshed 2026-09-02 against released 0.25 (public HEAD `daf5125a`), after the 2026-07-30 authoring and the 2026-08-14 refresh against 0.24. Version labels: 0.26 is this milestone (the PRD title still carries its pre-renumber label), released 0.25 is the compatibility baseline, 0.27 is the Chat consumer._

## Feature Overview and Goal

**Intent**: Storage services are hard-coupled to the `sqlite3` API, so a PostgreSQL backend cannot exist without rewriting every repository – this story lands the single `DatabaseBackend` seam (kernel port + SQLite implementation + pinned transaction semantics) that every later 0.26 story builds on, proven end-to-end by a tracer slice with zero behavior change.

**Expected Outcomes**:

- [OC01] Portable CRUD (execute, query, prepared-statement handles) issued through `DatabaseBackend` against SQLite returns results identical to direct `sqlite3` usage – same rows, same stored data formats – and the seam's placeholder-rewriting contract is proven literal-aware.
- [OC02] `transaction()` is safe and deterministic: unrelated SQLite operations wait outside the awaited body, reentrant operations join it, nested/reentrant `transaction()` calls fail fast with `NestedTransactionError`, and transaction-created statements cannot outlive their transaction.
- [OC03] Goal persistence (the pilot) runs entirely through the seam with zero user-visible change – all existing goal behavior across the runtime API, service layer, and composition-root wiring works exactly as before.


## Required Context

- `docs/specs/0.26/plan.json#sharedDecisions` – decision "DatabaseBackend seam shape and placement under the 0.25 topology": ports in `dartclaw_kernel`, implementations in `packages/dartclaw_core/lib/src/storage/`, the LOC-ceiling protocol, the 1500-line lib / 1300-line test file caps, explicit barrel `show` clauses. Decision "Async transaction and nested-transaction contract": the `transaction()` contract this story pins for S04/S05/S07/S11; repositories and the transactor are already `Future`-returning at 0.25, so no caller-signature contagion.
- `docs/specs/0.26/prd.md#fr1-backend-agnostic-storage-layer` – the FR1 acceptance criteria this story seeds: async seam with serialized SQLite `transaction()`, `NestedTransactionError`, transaction-bound statements, portable CRUD through the thin backend, typed-exception posture ("no behavioral change to existing error paths in this phase"), and the zero-behavior-change bar. The PRD and plan carry the verified 0.25 census (18 importers, 5 CLI typedef consumers); the Spec-Time Census below and `launch-context.md` record its evidence.
- `docs/specs/0.26/prd.md#constraints` – binding constraints: ADR-045 contracts and its 2026-07-30 amendment are owner decisions not to be reopened; abstraction scope is exactly the `tasks.db` + `search.db` surfaces; single-threaded runtime; portable-subset SQL, no ORM.
- `docs/specs/0.26/prd.md#user-stories` – US01: the SQLite default keeps working exactly as before; full suite green post-refactor, no config, data-dir, or manual storage action.
- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#decided-posture--contracts-owner-accepted-2026-07-24` – decision #7, the ratified hybrid (settled owner decision, do not reopen): thin portable-subset CRUD, prepared-statement handles, literal-aware placeholder rewriting counted as real shim cost, transaction-bound statements (`StateError` after completion, idempotent close). The `FullTextIndex` riders in the same item are story S03's scope.
- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#r2--async-transaction-trap-sqlite3-is-sync-postgres-is-async` – why the SQLite `transaction()` must hold one exclusive slot for the awaited body's full duration, and the canonical precedent to reuse (`SqliteExecutionRepositoryTransactor`). The sync-to-async contagion it warns about is already discharged at 0.25.
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#amendment-2026-08-21--storage-absorption-landed` – `dartclaw_core` carries `sqlite3` and owns the former storage package's repositories; `dartclaw_kernel` depends on nothing. This is what places the port in the kernel and the implementation in core.
- `../dartclaw-public/dev/package_tiers.txt` – the tier order the dependency-direction gate derives from (T0 kernel, T1 core, T3 runtime); same-tier and upward edges are forbidden with no exception mechanism. This story adds no edge: core already depends on kernel, runtime already depends on both.
- `docs/specs/0.26/launch-context.md` – the live committed baseline, storage census, topology, wiring facts, and structural constraints that supersede the temporary re-plan audits.


## Deeper Context

- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#schema-bootstrap-and-compatibility` – current-schema policy owned by story S02; read when seam work appears to need schema-history machinery.
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#amendment-2026-08-22--the-tier-order-replaces-the-per-edge-tables` – why there is no per-edge exception table; a placement that needs one is wrong.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#test-layers` – layer model; backend tests are Layer 1/2 against real in-memory SQLite, no mocks.
- `../dartclaw-public/dev/architecture/data-model.md#goal` – pilot entity fields and authoritative `tasks.db` ownership.
- `../dartclaw-public/dev/state/DECISIONS.md#still-current` – the 2026-09-01 LOC-band decision (`_locHeadroom` 1500, ceilings re-cut at milestone close-out).


## Acceptance Scenarios

- **S01 [OC01,OC03] [TI03,TI06] Pilot CRUD through the seam is behavior-identical**
  - **Given** a tasks database containing goal rows written by the pre-refactor code (ISO8601 TEXT `created_at`, nullable `max_tokens`)
  - **When** the seam-backed `SqliteGoalRepository` runs `insert`, `getById`, `list`, and `delete`, plus `getById` for a missing id
  - **Then** results are identical to the pre-refactor implementation: same field values and ordering (`created_at DESC, id DESC`), new rows stored as ISO8601 TEXT / integer scalars in the unchanged `goals` schema, and the missing id returns `null` (no throw)
  - **Proof**: `packages/dartclaw_core/test/storage/sqlite_goal_repository_test.dart#SqliteGoalRepository` – green – parity/regression (every assertion stays; only construction/setup moves onto the seam)

- **S02 [OC01,OC02] [TI03,TI05] Prepared-statement lifetime is explicit**
  - **Given** one statement prepared on the owning backend and two statements prepared through transaction handles, one in a committing transaction and one in a rolling-back transaction
  - **When** the owner statement is reused and closed twice, and each transaction-created statement is used after its transaction completes and then closed twice
  - **Then** owner-statement executions persist and return their affected-row counts, every post-close or post-transaction `execute`/`query` throws `StateError`, and every repeated `close()` completes without error

- **S03 [OC02] [TI04] A concurrent operation cannot enter an open transaction**
  - **Given** a `transaction()` whose body inserts row A, signals the test through a `Completer`, awaits a second test-controlled `Completer`, inserts row B, then throws (forcing ROLLBACK)
  - **When** the test – on the body's signal, so "mid-body" is a handshake and not a timing race – issues from outside the transaction a concurrent `backend.execute` inserting row C and a concurrent `DatabaseStatement.execute` (handle prepared before the transaction) inserting row D, then releases the body's gate
  - **Then** rows C and D are persisted and rows A/B are not, and both futures complete only after `transaction()`'s future has completed (asserted as explicit completion ordering, never a delay) – proving both doors, plain and prepared-statement, were held out of the open `BEGIN…ROLLBACK` rather than interleaved into it, and that `transaction()` rethrows the body error after rollback

- **S04 [OC02] [TI05] Reentrant owner operations join the open transaction**
  - **Given** a `transaction()` body that writes through the `tx` handle, the owning `SqliteBackend`, and a statement prepared through that owning backend (the repository-held-reference pattern story S05 consumes)
  - **When** the body throws after all three writes
  - **Then** no write survives – both owner-instance paths joined the same transaction instead of deadlocking on the serialization slot or escaping the rollback

- **S05 [OC02] [TI05] Nested transaction() is rejected fast, never deadlocks**
  - **Given** an active `transaction()` body that writes once, then calls `transaction()` again – on the `tx` handle and, in a second case, on the owning backend – and **catches** the resulting error rather than letting it propagate
  - **When** the body writes once more and returns normally after catching
  - **Then** each nested call threw `NestedTransactionError` promptly (the test completes without any timeout), and the outer transaction commits both the before and the after write

- **S06 [OC01] [TI02] Placeholder rewriting is literal-aware**
  - **Given** portable SQL containing real `?` placeholders alongside a `?` inside a single-quoted string literal (including an escaped `''` case), a `?` inside a double-quoted identifier, and a `?` inside a `--` line comment and `/* */` block comment
  - **When** the rewriter runs with a `$n`-style dialect formatter (story S07's PostgreSQL target)
  - **Then** only the real placeholders become `$1`, `$2`, … in order; every quoted/commented `?` is untouched – a naive string-replace implementation fails this

- **S07 [OC03] [TI06,TI07] Zero behavior change across the existing goal surfaces**
  - **Given** the pilot wired through `StorageWiring.wire()` with `SqliteBackend` wrapping the shared task database
  - **When** every pre-existing suite that constructs `SqliteGoalRepository` runs – `dartclaw_core`'s `sqlite_goal_repository_test.dart` and `dartclaw_runtime`'s `api/goal_routes_test.dart`, `server_test.dart` (group `goal route wiring`), and `task/budget_enforcement_test.dart`
  - **Then** all pass with unchanged assertions (only construction/setup updated for the seam) – goal behavior via repository, HTTP routes, server composition, and budget-enforcement flows is exactly as before. (`task/goal_service_test.dart` is untouched: it runs against an in-test `_InMemoryGoalRepository`, never the pilot.)
  - **Proof**: `packages/dartclaw_runtime/test/api/goal_routes_test.dart#/api/goals` – green – parity/regression (all four route groups; the other three suites are bound by TI07's Verify)


## Structural Criteria

- **SC01** `packages/dartclaw_core/lib/src/storage/sqlite_goal_repository.dart` no longer imports `package:sqlite3`; every other 0.25 census importer keeps its import untouched (stories S04–S06 scope preserved), so the repo-wide importer count stays at 18 – one import removed (the pilot), one added (the SQLite backend implementation file).
- **SC02** The port surface is published once, from the kernel barrel with an explicit `show` clause (`DatabaseBackend`, `DatabaseStatement`, `NestedTransactionError`); `SqliteBackend` is exported from the core barrel with an explicit `show` clause; the core barrel does not re-export the kernel barrel (arch_check L1).
- **SC03** No new cross-package dependency edge: the fitness suite (`dependency_direction`, `package_cycles`, `no_second_implementation`, `src_import_hygiene`, `barrel_show_clauses`, `max_file_loc`, `max_test_file_loc`) stays green.
- **SC04** Zero schema, data-format, or user-visible change: the `goals` DDL (table, `idx_goals_parent`, additive `max_tokens` repair) is byte-identical to 0.25; the full workspace suite, `arch_check` (LOC ceilings, 12-package ceiling), and `git diff --check` are green.


## Scope & Boundaries

### Spec-Time Census (FR1, re-run 2026-09-02 against public HEAD `daf5125a` – discharged by this FIS)

Both instruments re-run repo-wide (`packages/` + `apps/`, tests excluded) match the S01 brief exactly – **no drift; no plan reconciliation needed**. Recorded here for story S06's closure:

- **Instrument A** – `rg -l "import 'package:sqlite3" packages apps --glob '!**/test/**' --glob '!**/*_test.dart'`: **18 files** – 15 in `dartclaw_core` (`knowledge/temporal_knowledge_graph_service`, `storage/{index_reconciler, memory_service, search_db, sqlite_agent_execution_repository, sqlite_execution_repository_transactor, sqlite_execution_row_mappers, sqlite_goal_repository, sqlite_task_repository, sqlite_workflow_step_execution_repository, task_db, task_event_service, turn_state_store, turn_trace_service, webhook_delivery_store}`), 1 in `dartclaw_workflow` (`storage/sqlite_workflow_run_repository`), 2 in `dartclaw_runtime` (`runtime/service_wiring`, `runtime/storage_wiring`). `apps/dartclaw_cli` contains zero `package:sqlite3` imports.
- **Instrument B** – `rg -l 'TaskDbFactory|SearchDbFactory|openTaskDb|openSearchDb' apps --glob '!**/test/**' --glob '!**/*_test.dart'`: **5 `dartclaw_cli` consumer files** (`cleanup_command`, `serve_command`, `workflow/standalone_lifecycle_support`, `workflow/workflow_run_command`, `workflow/workflow_status_command`), all via injected-factory-with-default. `rebuild_index_command.dart` stays outside the set (it goes through `CanonicalIndexReconciler`). The same pattern also matches 8 non-consumer files in `dartclaw_core` (`lib/dartclaw_core.dart`, the definition sites `storage/task_db.dart` and `storage/search_db.dart`, `storage/index_reconciler.dart`, `example/example.dart`, `CLAUDE.md`) and `dartclaw_runtime` (`runtime/service_wiring.dart`, `runtime/storage_wiring.dart`) – story S06's removal sweep.

The 0.24 targets the prior FIS named – the `dartclaw_storage` package and its barrel, the `barrel_export_count_test.dart` export-count gate, and the CLI files `cli_workflow_wiring.dart` and `release_sqlite_check_command.dart` – no longer exist; nothing in this FIS depends on them.

### Work Areas
- New port surface: `../dartclaw-public/packages/dartclaw_kernel/lib/src/database_backend.dart` – `DatabaseBackend`, `DatabaseStatement`, `NestedTransactionError` – plus its `show`-scoped export from `../dartclaw-public/packages/dartclaw_kernel/lib/dartclaw_kernel.dart`
- New SQLite implementation and rewriter: `../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_backend.dart` and `../dartclaw-public/packages/dartclaw_core/lib/src/storage/sql_placeholder_rewriter.dart`, with `SqliteBackend` `show`-exported from `../dartclaw-public/packages/dartclaw_core/lib/dartclaw_core.dart`
- Pilot repository: `../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_goal_repository.dart` + its existing test
- Pilot construction sites (all five, from `rg -l "SqliteGoalRepository\("`): production `../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart` (goal-repo wiring only), plus the four suites that construct it directly – `dartclaw_core/test/storage/sqlite_goal_repository_test.dart` and `dartclaw_runtime/test/{api/goal_routes_test.dart, server_test.dart, task/budget_enforcement_test.dart}` (construction/setup-only updates)
- New backend tests: `../dartclaw-public/packages/dartclaw_core/test/storage/` (`sqlite_backend_test.dart`, `sql_placeholder_rewriter_test.dart`; split transaction coverage into a sibling file if the 1300-line test cap approaches)

### What We're NOT Doing

_(`S<NN>` below and elsewhere outside `## Acceptance Scenarios` names a **plan story**; inside `## Acceptance Scenarios` the same token is a scenario ID. Story references are prefixed "story" wherever the number also exists as a scenario.)_

- Refactoring the remaining 17 census importers or any `dartclaw_cli` typedef consumers – stories S04/S05 (repositories/services) and S06 (composition root, helper/typedef removal, fitness check) own them.
- Current-schema bootstrap and compatibility policy – story S02. The pilot's existing ad-hoc `_initSchema` SQL (including its SQLite-specific `PRAGMA table_info` column check) flows through the seam unchanged as a transitional carry; the seam does not grow schema-history behavior.
- `FullTextIndex` / any FTS or search.db work – story S03.
- Any PostgreSQL code – story S07. This story ships the `$n` rewriting *rules* as a tested dialect-parameterized utility inside core (seam-shape scope per the plan); wiring it into a live backend is story S07's.
- A typed storage-exception hierarchy and DSN redaction – stories S07/S08 per the plan's shared decisions. This story adds only `NestedTransactionError`; existing `sqlite3` exceptions propagate unchanged (FR1: no behavioral change to error paths in this phase).
- Packaging tests as the shared `databaseBackendContractTests` suite – story S11 generalizes; this story ships plain unit tests.


## Architecture Decision

**Approach**: Realize ADR-045 decision #7 as the `DatabaseBackend` port in `dartclaw_kernel` (T0, depends on nothing) and `SqliteBackend` in `packages/dartclaw_core/lib/src/storage/` (T1, the only driver-bearing package), tracer-sliced through `SqliteGoalRepository`, per plan shared decision "DatabaseBackend seam shape and placement". See ADR: `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md`; topology: `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md`.
**Why this over alternatives**: a port in core would force Phase B's `dartclaw_search` (story S03's pin) and any future consumer to take a storage edge for a contract, and the tier order has no exception mechanism; the kernel already hosts the sibling port `ExecutionRepositoryTransactor` and every other repository port's value types, so the seam follows the pattern that exists.


## Technical Overview

Pinned seam contract (consumed verbatim by stories S02, S04/S05, S07, S11 – changing these later is a plan-level event):

1. **Portable SQL** uses positional `?` placeholders only. Each backend rewrites to its native form via the shared literal-aware rewriter (SQLite: identity; PostgreSQL: `$n`, story S07).
2. **Result marshalling** – canonical portable scalars are SQLite's storage classes: `int`, `double`, `String`, `Uint8List`, `null`; booleans as `int` 0/1; timestamps as ISO8601 `String`. Rows are `List<Map<String, Object?>>`. Rationale: SQLite's dynamic typing makes "marshal up to typed" impossible schema-agnostically, and this set is byte-identical to today's stored data (zero data-format change); story S07's PostgresBackend marshals its typed results *down* to this set.
3. **Transactions** – `Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body)` returns the body's value and rethrows its error after rollback. The `tx` handle is valid only during that body; later use (and caller `tx.close()`) throws `StateError`. SQLite holds one serialization slot across the complete awaited `BEGIN…COMMIT`/`ROLLBACK`; unrelated operations wait. Owner-instance operations inside the body join via a zone-carried context that must equal the backend's *currently active* transaction; stale/foreign contexts are unrelated. `transaction()` invoked from either the owner or `tx` while active rejects immediately with `NestedTransactionError`.
4. **Prepared statements** – `Future<DatabaseStatement> prepare(String sql)` returns an async handle whose `execute`/`query` participate in the same context gate as direct operations. An owner-prepared statement used from outside an active transaction waits on SQLite; one prepared through `tx` (or through the zone-matched owner inside the body) is transaction-bound. On commit or rollback, that handle becomes unusable: later `execute`/`query` throws `StateError`, while `close()` remains safe and idempotent. Closing any statement twice is a no-op; using it after explicit close throws `StateError`.
5. **Execution results** – `DatabaseBackend.execute` and `DatabaseStatement.execute` return `Future<int>`, the affected-row count (`sqlite3`'s `Database.updatedRows`; the PostgreSQL driver's affected-rows result, story S07) – this is what the nine `_db.updatedRows` guard sites in the story S04/S05 census files (task, agent-execution, step-execution, and workflow-run repositories, the KG service) consume post-refactor. The contract exposes **no `lastInsertRowId`** (an engine-specific accessor): insert-and-fetch flows use the portable `INSERT/UPDATE/DELETE … RETURNING` form issued via `query()` – supported by both engines (SQLite ≥ 3.35, proven against the bundled engine by a backend unit test; PostgreSQL native) and exactly the coupling ADR-045's census table flags for abstraction. The one live `_db.lastInsertRowId` call site (`temporal_knowledge_graph_service.dart`) migrates to `RETURNING id` when story S04 refactors it.
6. **Close idempotency** – `DatabaseBackend.close()` is idempotent: later calls on an already-closed backend are no-ops. Story S06 will make the composition root the sole close owner; S01 must not transfer ownership of the shared raw connection.
7. **Construction** – a seam-backed repository whose schema init needs the seam exposes an awaited static factory (`SqliteGoalRepository.open(DatabaseBackend backend)`), never DDL in a constructor; this is the construction shape stories S04/S05 copy until story S02 relocates the DDL.


## Code Patterns & External References

```
# type | path#anchor                                                                                                     | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_execution_repository_transactor.dart#SqliteExecutionRepositoryTransactor | Single-slot completer-chain queue holding BEGIN…COMMIT across an awaited body – reuse this exact serialization pattern
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_goal_repository.dart#SqliteGoalRepository      | Pilot surface – current prepare/execute/select usage and _initSchema to move onto the seam
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring.wire            | Construction site – the line constructing SqliteGoalRepository(taskDb) inside the tasks.db try block; wrap the shared taskDb in SqliteBackend for the goal repo only
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/execution_repository_transactor.dart#ExecutionRepositoryTransactor | Sibling storage port in the kernel – file placement, dartdoc density, and barrel export shape to match
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/turn_state_store.dart#TurnStateStore                 | Portable `ON CONFLICT … DO UPDATE` upsert exemplar (ADR-045 R1) – the portable-subset style the contract dartdoc cites
file   | ../dartclaw-public/packages/dartclaw_core/test/storage/sqlite_goal_repository_test.dart#main                   | Existing pilot tests – update construction/setup only, keep every assertion
file   | ../dartclaw-public/dev/tools/arch_check.dart#_libLocCeilings                                                    | LOC ceilings (core 27705, kernel 19920) and the CHANGELOG-noted rebaseline protocol if this story crosses one
```


## Constraints & Gotchas

- **Critical**: A boolean "in transaction" flag cannot distinguish a *reentrant* caller (must join / be rejected) from a *concurrent* caller (must queue) – reentrancy detection must be a `Zone` value carrying the active transaction context, **compared against the currently-active transaction** rather than merely tested for presence (Technical Overview #3). Getting either half wrong produces the self-deadlock the binding constraint forbids, or lets a post-completion callback interleave into a later transaction.
- **Critical**: A statement created by `tx.prepare` cannot degrade into an ordinary owner statement when the body ends – both commit and rollback invalidate it; later `execute`/`query` must fail before touching SQLite, while cleanup remains repeatable.
- **Constraint**: During stories S01–S05 the same `sqlite3` `Database` connection is shared between the seam and raw-Database co-users (all non-pilot repositories, the existing transactor). The seam's serialization guarantees cover only operations issued through the same `SqliteBackend` instance – raw co-users keep today's semantics until stories S04–S06 unify them. Do not attempt cross-instance coordination here. (Safe for this story because the pilot issues no transactions in production: no seam `BEGIN…COMMIT` ever opens on the shared `taskDb` in this story.)
- **Avoid**: DDL or any awaited work in constructors – an async seam cannot be awaited there. Instead: schema init moves to the awaited static factory (Technical Overview #7), invoked from `StorageWiring.wire()` (already async, inside the tasks.db try block whose failure path is `_exitFn(1)`).
- **Avoid**: Closing the shared connection from the seam in this story – `StorageWiring.dispose()` ownership is unchanged until story S06. Neither wiring nor `SqliteGoalRepository.dispose()` may call `SqliteBackend.close()`: the repository's `dispose()` is a no-op today and stays one, because `SqliteTaskRepository.dispose()` already closes that same shared `Database` and both existing tearDowns (`sqlite_goal_repository_test.dart`, `api/goal_routes_test.dart`) dispose the goal surface *first*.
- **Constraint**: Barrel hygiene is a gate, not a convention – every new `export 'src/…'` line carries an explicit `show` clause (`dev/fitness/test/barrel_show_clauses_test.dart`), the core barrel must not re-export the kernel barrel (`arch_check` L1), and every new public class/typedef name must be workspace-unique (`no_second_implementation_test.dart`). Consumers import the port from `package:dartclaw_kernel`, as `sqlite_execution_repository_transactor.dart` does today.
- **Constraint**: LOC gates. Measured 2026-09-02: `dartclaw_core` 26269 of 27740, `dartclaw_kernel` 18428 of 19920 lib lines; this story's additions are expected to fit. If a ceiling is crossed, the protocol is a recorded rebaseline in `arch_check.dart` with a CHANGELOG note in the same change – never a silent bump. No lib file may exceed 1500 lines, no test file 1300 (`max_file_loc_test.dart`, `max_test_file_loc_test.dart`; allowlist additions are ratcheted and need a shrink target).
- **Constraint**: `sqlite3` calls execute synchronously on the event loop even behind the async seam – keep per-operation work small and never hold the serialization slot on non-database awaits longer than the body requires (see LEARNINGS: microtask starvation in async loops).
- **Constraint**: `dart test` runs suites as isolates in one process (LEARNINGS: tooling-verification) – new backend tests use `sqlite3.openInMemory()` / `openTaskDbInMemory()` and never touch `Directory.current`.
- **Constraint**: Comments are rationale-only per project rules; the contract's dartdoc documents the *contract* (semantics above), not call-site narration.


## Implementation Plan

### Implementation Tasks

- **TI01** The `DatabaseBackend` port exists in `dartclaw_kernel` and is barrel-exported with an explicit `show` clause
  - `packages/dartclaw_kernel/lib/src/database_backend.dart` declares `DatabaseBackend` (`execute`, `query`, `Future<DatabaseStatement> prepare(String sql)`, `transaction`, `close`), `DatabaseStatement` (`execute`, `query`, `close`), and `NestedTransactionError`; `transaction` has the Technical Overview #3 signature and both `execute` members return `Future<int>` affected rows. Public dartdoc pins positional `?`, canonical scalars, transaction queue/join/reject behavior, transaction-bound statement lifetime, idempotent close, and `RETURNING` for insert-and-fetch – no `lastInsertRowId`. Follow `execution_repository_transactor.dart#ExecutionRepositoryTransactor` for placement and export shape.
  - **Verify**: `cmd: rg -qU "database_backend\.dart'\s*show[^;]*\bDatabaseBackend\b" packages/dartclaw_kernel/lib/dartclaw_kernel.dart && rg -qU "database_backend\.dart'\s*show[^;]*\bDatabaseStatement\b" packages/dartclaw_kernel/lib/dartclaw_kernel.dart && rg -qU "database_backend\.dart'\s*show[^;]*\bNestedTransactionError\b" packages/dartclaw_kernel/lib/dartclaw_kernel.dart && dart analyze --fatal-infos packages/dartclaw_kernel` – all three symbols are exported from the kernel barrel under one `show` clause and the kernel analyzes clean
  - **SATISFIES**: SC02

- **TI02** A dialect-parameterized, literal-aware placeholder rewriter is available in `packages/dartclaw_core/lib/src/storage/`
  - `sql_placeholder_rewriter.dart` takes portable SQL + an ordinal formatter (e.g. `(i) => '\$$i'`); skips `?` inside single-quoted literals (incl. `''` escapes), double-quoted identifiers, `--` line comments, and `/* */` block comments; SQLite usage is identity (no rewrite applied). Not barrel-exported (its only consumers, `SqliteBackend` and story S07's `PostgresBackend`, live in the same package); tests import it by its own-package `src` path.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sql_placeholder_rewriter_test.dart --plain-name "rewrites only real placeholders"` – scenario S06's mixed input rewrites only real placeholders to `$1`, `$2`, … in order while every quoted/commented `?` survives verbatim
  - **SATISFIES**: S06

- **TI03** `SqliteBackend` implements the port over an injected `sqlite3` `Database` with pass-through marshalling and is barrel-exported
  - `packages/dartclaw_core/lib/src/storage/sqlite_backend.dart`: constructor wraps an existing open `Database`; `execute`/`query`/`prepare` delegate to `sqlite3` with rows marshalled to `List<Map<String, Object?>>` in the canonical scalar set and `execute` resolving to `updatedRows` (Technical Overview #5); `close()` closes the wrapped connection and is idempotent. Exported from `dartclaw_core.dart` as `export 'src/storage/sqlite_backend.dart' show SqliteBackend;`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --plain-name "marshalling and statements" && rg -q "show SqliteBackend" packages/dartclaw_core/lib/dartclaw_core.dart` – round-trips `int`, `double`, `String`, `Uint8List` (blob), and `null`; an `UPDATE` matching two rows resolves to `2`; `INSERT … RETURNING id` returns the id; an owner `DatabaseStatement` executes twice, closes twice without error, then rejects both `execute` and `query` with `StateError` (scenario S02's owner half); `SqliteBackend.close()` completes twice without error; and `rg -q "show SqliteBackend" packages/dartclaw_core/lib/dartclaw_core.dart` exits 0
  - **SATISFIES**: S01, S02, SC02

- **TI04** `SqliteBackend.transaction()` serializes on a single-slot queue holding `BEGIN…COMMIT`/`ROLLBACK` for the awaited body
  - Reuse the completer-chain pattern from `sqlite_execution_repository_transactor.dart#SqliteExecutionRepositoryTransactor`; returns the body's value; rethrows the body's error after `ROLLBACK`; concurrent `execute`/`query`/`prepare`/`transaction` callers **and concurrent `DatabaseStatement.execute`/`query` callers** queue until completion (Technical Overview #4)
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --plain-name "concurrent operations wait for the open transaction"` – scenario S03: a concurrent `execute` *and* a concurrent `DatabaseStatement.execute`, both issued mid-body via the body's `Completer` handshake, complete only after the transaction finishes; after a body throw, both concurrent writes persist and the body's writes do not; the body error is rethrown from `transaction()`
  - **SATISFIES**: S03

- **TI05** Reentrancy and transaction-bound lifetimes are enforced
  - A `Zone` carries the active context; owner `execute`/`query`/`prepare` and statement operations join only when it matches the currently-active transaction. Stale/foreign contexts queue; nested `transaction()` on owner or `tx` rejects; escaped `tx` handles and statements prepared through `tx` or the zone-matched owner reject use after completion, while statement `close()` stays idempotent.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --plain-name "reentrancy and transaction-bound lifetimes"` – scenario S04 rolls back writes through `tx`, owner, and owner-prepared statement; scenario S05 rejects nested calls on both paths without a timeout; scenario S02 proves transaction-created statements expire after both commit and rollback, reject `execute`/`query` with `StateError`, and tolerate two later `close()` calls; a statement prepared through the zone-matched owner is likewise invalidated; an escaped `tx` rejects both `execute` and `close()` with `StateError`
  - **SATISFIES**: S02, S04, S05

- **TI06** `SqliteGoalRepository` is seam-backed with unchanged behavior
  - Consumes `DatabaseBackend` (imported from `package:dartclaw_kernel`) through the awaited static factory `SqliteGoalRepository.open(DatabaseBackend backend)` (Technical Overview #7); all SQL – including the transitional `_initSchema` DDL and `PRAGMA table_info` check – flows through the seam; `dispose()` stays a no-op (it must not call `DatabaseBackend.close()` – connection ownership is unchanged until story S06); `GoalRepository` port and `GoalService` untouched (already `Future`-returning). `sqlite_goal_repository_test.dart` gets a construction/setup-only update.
  - **Verify**: `cmd: ! rg -q "package:sqlite3" packages/dartclaw_core/lib/src/storage/sqlite_goal_repository.dart && ! rg -qi "backend\.close\(\)" packages/dartclaw_core/lib/src/storage/sqlite_goal_repository.dart && ! rg -q 'SqliteGoalRepository\(' packages/dartclaw_core/lib/src/storage/sqlite_goal_repository.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_goal_repository_test.dart` – the pilot has no `sqlite3` import, never closes the backend, exposes no raw-`Database` constructor, and its pre-existing assertions pass unchanged (scenarios S01, S07)
  - **SATISFIES**: S01, S07, SC01, SC04

- **TI07** `StorageWiring` constructs the pilot through the seam; everything else unchanged
  - In `storage_wiring.dart#StorageWiring.wire`, inside the tasks.db try block, wrap the shared `taskDb` in a `SqliteBackend` and await `SqliteGoalRepository.open(...)` for the goal repository only; all other repositories/services keep the raw `Database`; wiring does not call `SqliteBackend.close()` (ownership unchanged until story S06); the three `dartclaw_runtime` suites that construct `SqliteGoalRepository` directly – `api/goal_routes_test.dart`, `server_test.dart`, `task/budget_enforcement_test.dart` – get construction/setup-only updates. Depends on TI03 and TI06.
  - **Verify**: `cmd: rg -q "SqliteBackend\(" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && ! rg -q 'SqliteGoalRepository\(' packages apps --glob '*.dart' && dart test --reporter=failures-only packages/dartclaw_runtime/test/api/goal_routes_test.dart packages/dartclaw_runtime/test/task/budget_enforcement_test.dart && dart test --reporter=failures-only packages/dartclaw_runtime/test/server_test.dart --name "goal route wiring"` – wiring constructs the backend, no site constructs the pilot from a raw `Database`, and the three runtime suites pass with unchanged assertions (scenario S07)
  - **SATISFIES**: S07

- **TI08** Zero-behavior-change gate holds workspace-wide
  - Depends on TI01–TI07; pure-refactor checkpoint per US01. If `arch_check` reports a crossed LOC ceiling, apply the rebaseline protocol (ceiling raise in `arch_check.dart#_libLocCeilings` + CHANGELOG note) in this same change.
  - **Verify**: `cmd: dart analyze --fatal-infos && test "$(rg -l "import 'package:sqlite3" packages apps --glob '!**/test/**' --glob '!**/*_test.dart' | wc -l | tr -d ' ')" = 18 && rg -q "import 'package:sqlite3" packages/dartclaw_core/lib/src/storage/sqlite_backend.dart && bash dev/tools/test_workspace.sh && dart run dev/tools/arch_check.dart && bash dev/tools/fitness/run_all.sh && git diff --check` – analysis clean; the census importer count is unchanged at 18 with the goal repository's import replaced by the backend file's; workspace suite, LOC/package ceilings, and the fitness suite are green
  - **SATISFIES**: SC01, SC03, SC04

### Testing Strategy

- Backend tests are Layer 1/2 per TESTING-STRATEGY: real in-memory SQLite (`sqlite3.openInMemory()` / `openTaskDbInMemory()`), no mocks – the transaction/serialization scenarios are only meaningful against the real engine. No `@Tags` needed; everything runs in the default suite. Test names used as Verify targets above are the group names the `--plain-name` selector matches. [TI02, TI03, TI04, TI05]

### Execution Contract

- TI01–TI05 (seam) must complete before TI06–TI07 (pilot consumes the seam); TI08 runs last. All commands run from the `../dartclaw-public/` root.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/storage/sql_placeholder_rewriter_test.dart#rewrites only real placeholders` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sql_placeholder_rewriter_test.dart --name "rewrites only real placeholders"`

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/storage/sqlite_backend_test.dart#marshalling and statements` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --name "marshalling and statements"`

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/storage/sqlite_backend_test.dart#concurrent operations wait for the open transaction` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --name "concurrent operations wait for the open transaction"`

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI05 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/storage/sqlite_backend_test.dart#reentrancy and transaction-bound lifetimes` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --name "reentrancy and transaction-bound lifetimes"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sql_placeholder_rewriter_test.dart --name "rewrites only real placeholders"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sql_placeholder_rewriter_test.dart --plain-name "rewrites only real placeholders"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --name "marshalling and statements"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --plain-name "marshalling and statements"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --name "concurrent operations wait for the open transaction"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --plain-name "concurrent operations wait for the open transaction"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI05 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --name "reentrancy and transaction-bound lifetimes"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --plain-name "reentrancy and transaction-bound lifetimes"`

### Run: 2026-09-05 08:42 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --plain-name "marshalling and statements"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_backend_test.dart --plain-name "marshalling and statements" && rg -q "show SqliteBackend" packages/dartclaw_core/lib/dartclaw_core.dart`

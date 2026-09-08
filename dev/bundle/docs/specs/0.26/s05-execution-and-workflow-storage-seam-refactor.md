# FIS: Execution and Workflow Storage Seam Refactor

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S05

_Refreshed 2026-09-02 against released 0.25 (public HEAD `daf5125a`), replacing the 2026-07-30 authoring (then "Execution and Workflow Storage Async Refactor", written against 0.24 and the dissolved `dartclaw_storage` / `dartclaw_server` packages). Version labels: 0.26 is this milestone (the PRD title still carries its pre-renumber label), released 0.25 is the compatibility baseline. Premise corrections versus the prior FIS: `SqliteExecutionRepositoryTransactor` and its kernel port `ExecutionRepositoryTransactor` were already `Future`-returning at 0.24 and are at HEAD, so no sync-to-async signature change exists anywhere in this story; `cli_workflow_wiring.dart` was deleted in 0.25 and the standalone CLI commands now stage through `DartclawRuntime`, so the only CLI construction sites are `workflow_status_command.dart` and `cleanup_command.dart`; `sqlite_workflow_run_repository.dart` lives in `dartclaw_workflow` (own barrel, own LOC ceiling, tier T2), not beside the other three in `dartclaw_core`; the shared row mappers are widened by story S04 and only consumed here._

## Feature Overview and Goal

**Intent**: The agent-execution, workflow-step-execution, and workflow-run repositories and the execution transactor still talk to `sqlite3` directly, so the atomic "task + execution + step" action that protects workflow state cannot exist on the milestone's PostgreSQL backend – this story moves the cluster onto the `DatabaseBackend` seam and rebuilds the transactor over S01's transaction contract, with zero user-visible change on SQLite.

**Expected Outcomes**:

- [OC01] Agent-execution, workflow-step-execution, and workflow-run persistence returns the same rows, ordering, stored formats, missing-id results, not-found errors, and status events as released 0.25.
- [OC02] One execution action commits every participating write across the task, agent-execution, step-execution, and workflow-run repositories or rolls all of them back; an unrelated seam operation waits outside the open action, and a nested action is rejected instead of hanging.
- [OC03] Every runtime, workflow-engine, and CLI flow that creates, runs, inspects, or prunes workflows produces the same output and error handling as before, on a store prepared once by the S02 gate.


## Required Context

- `docs/specs/0.26/plan.json#sharedDecisions` – decision "DatabaseBackend seam shape and placement under the 0.25 topology": `dartclaw_core` is the only package that may carry the `sqlite3` driver (so `dartclaw_workflow` sheds its driver dependency here), the two-sided LOC ceilings, the 1500/1300-line file caps, explicit barrel `show` clauses. Decision "Async transaction and nested-transaction contract": the transactor is rebuilt over S01's `transaction()`; repositories and the transactor are already `Future`-returning, so no caller-signature contagion – this FIS holds to that clause for all four classes.
- `docs/specs/0.26/prd.md#fr1-backend-agnostic-storage-layer` – the FR1 bar: the SQLite `transaction()` serializes for the awaited body's duration by reusing the `SqliteExecutionRepositoryTransactor` pattern (S01 generalized it; this story retires the original), "no behavioral change to existing error paths in this phase", full workspace suite green. **NOTICED**: the FR census figures, package names, and the `cli_workflow_wiring.dart` mention predate 0.25; the verified census is in the S01 FIS and the PRD amendment is owner-owned.
- `docs/specs/0.26/prd.md#user-stories` – US01: the SQLite default keeps working exactly as before, no config, data-dir, or manual storage action.
- `docs/specs/0.26/s01-databasebackend-seam-and-sqlite-backend.md#technical-overview` – the seam contract consumed verbatim: #3 `transaction()` returns the body's value and rethrows its error after rollback, owner-instance operations inside the body join via the zone-carried context, a stale or foreign context is unrelated and queues, and a nested `transaction()` rejects with `NestedTransactionError` (the transactor's new semantics come from here, not from a second queue); #5 `execute` returns affected rows (the three `_db.updatedRows` guards in this cluster consume it); #6 close ownership stays with wiring until S06; #7 the awaited `open()` factory is only for schema-initialising repositories – after S02 none of these four has schema init, so all take the backend by constructor, as S04 does.
- `docs/specs/0.26/s01-databasebackend-seam-and-sqlite-backend.md#acceptance-scenarios` – scenario S04 "Reentrant owner operations join the open transaction" names the repository-held-reference pattern this story consumes: repositories keep a reference to the owning `SqliteBackend` and never see a `tx` handle.
- `docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md#technical-overview` – the gate's classification (empty bootstraps, current no-op, released-unmarked adopts, everything else refuses) and why the gate must run before any constructor on a fresh connection; `workflow_runs`, `workflow_run_migrations`, `agent_executions`, and `workflow_step_executions` with their indexes are in the tasks manifest.
- `docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md#structural-criteria` – SC03 leaves the `workflow_runs` constructor repairs to this story; SC04: `workflow_run_migrations` is domain data the gate never reads – after this story no code reads or writes it either (see What We're NOT Doing).
- `docs/specs/0.26/s04-task-domain-storage-seam-refactor.md#technical-overview` – the construction order at both production sites (open → one `SqliteBackend` → `prepareTasks` → constructors in any order) and the row-mapper widening (`Row` → `Map<String, Object?>`) this story's mappers already carry.
- `docs/specs/0.26/s04-task-domain-storage-seam-refactor.md#implementation-tasks` – TI03 `openPreparedTaskBackend()` in `dartclaw_testing` (the one shared fixture; a `test/` file is not importable across packages), TI08 the `prepareTasks` calls already placed in `storage_wiring.dart` and `workflow_status_command.dart`, TI09's importer list naming this story's four files as the ones that keep their `sqlite3` import until now.
- `docs/specs/0.26/s04-task-domain-storage-seam-refactor.md#constraints--gotchas` – one `SqliteBackend` per connection (a second wrapper escapes serialization and rollback), the only sanctioned fire-and-forget shape, `foreign_keys=ON` issued by the `task_db.dart` open helpers (why the step-execution constructor PRAGMA can go), the `dartclaw_testing` driver ban.
- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#decided-posture--contracts-owner-accepted-2026-07-24` – decision #7 (thin portable CRUD, affected-row results, statement handles); settled owner decision.
- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#r2--async-transaction-trap-sqlite3-is-sync-postgres-is-async` – why one exclusive slot must span the awaited body; the transactor was the canonical precedent and S01's backend now owns that slot.
- `../dartclaw-public/dev/state/LEARNINGS.md#concurrency--async` – "`StreamController.broadcast()` fire is synchronous" (the status event `SqliteAgentExecutionRepository.update` fires runs inside the transaction body) and the `unawaited()` shape for any boundary that cannot await.
- `../dartclaw-public/dev/state/LEARNINGS.md#workflow-engine` – "Every task-completion listener shares the same async-listener / SQLite-teardown race": listeners fire-and-forget `_taskService.get` from synchronous handlers; under the seam such a call that outlives the body carries a stale context and queues (S01 #3), so the listener pattern is untouched by this story.
- `docs/specs/0.26/launch-context.md` – the live committed package placement, orphan-column fact, CLI consumers, store wiring, and LOC constraints that supersede both temporary re-plan audits.


## Deeper Context

- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#amendment-2026-08-21--storage-absorption-landed` – why three of the four files live in `dartclaw_core` and why no new package or edge is available.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#test-layers` and `#data-integrity` – persistence tests are Layer 2 against real in-memory SQLite, no mocks; transaction tests assert crash-safe outcomes.
- `../dartclaw-public/dev/architecture/data-model.md#agentexecution`, `#workflowstepexecution`, `#workflow-models` – the entity fields whose stored formats must not move.
- `../dartclaw-public/dev/state/DECISIONS.md#still-current` – the 2026-09-01 LOC-band decision (`_locHeadroom` 1500; ceilings re-cut downward when a package shrinks).
- `../dartclaw-public/dev/state/LEARNINGS.md#tooling--verification` – `dart test` runs suites as isolates in one process (`Directory.current` is shared); workspace-root `dart pub get` owns native-asset regeneration after a `sqlite3` dependency move.


## Acceptance Scenarios

- **S01 [OC01] [TI02,TI03,TI06] Agent-execution and step-execution persistence is identical through the seam**
  - **Given** a prepared current `tasks.db` (S02 gate) holding agent executions and workflow-step executions written in the released 0.25 format (ISO8601 TEXT timestamps, JSON TEXT columns, 14 step-execution columns), plus tasks they reference
  - **When** the seam-backed `SqliteAgentExecutionRepository` runs `create`, `get`, `list` (no filter, `sessionId`, `provider`, both), `update` (with and without a status change), and `delete`, and the seam-backed `SqliteWorkflowStepExecutionRepository` runs `create`, `getByTaskId`, `listByRunId`, `update`, and `delete`
  - **Then** every result equals the pre-refactor implementation: `list` orders `started_at DESC, id DESC`, `listByRunId` orders `step_index ASC, task_id ASC`, a missing id reads back `null`, `update` of a missing id throws `ArgumentError` with the same message, `update` fires `AgentExecutionStatusChangedEvent` exactly when the derived status changes (queued → running → completed) and never otherwise, a duplicate `create` still surfaces the driver's constraint error unchanged, and deleting a task still cascades to its step execution
  - **Proof**: `packages/dartclaw_core/test/storage/sqlite_agent_execution_repository_test.dart#SqliteAgentExecutionRepository` – green – parity/regression (every behavior assertion stays; construction moves onto a prepared backend; the `creates table and indexes` test is retired with the DDL, see TI02)

- **S02 [OC01] [TI04,TI06] Workflow-run persistence is identical and needs only a prepared store**
  - **Given** a prepared current `tasks.db` whose `workflow_runs` rows include an execution cursor, a cursor naming the retired `map` node type, legacy single-object and `items`-wrapped `workflow_worktree_json`, and nullable fields
  - **When** the seam-backed `SqliteWorkflowRunRepository` runs `insert`, `getById`, `list` (no filter, `status`, `definitionName`, both), `update`, `delete`, `setWorktreeBinding`, `getWorktreeBinding`, and `getWorktreeBindings`
  - **Then** every result equals the pre-refactor implementation: JSON maps, cursors (including the no-cursor hydration for the retired node type), and worktree bindings round-trip byte-for-byte, `list` orders `started_at DESC, id DESC`, `update` keeps `COALESCE(?, workflow_worktree_json)` semantics, `getById` of a missing id returns `null`, `setWorktreeBinding` on a missing run throws `ArgumentError`, and constructing the repository performs no DDL, `PRAGMA table_info`, `ALTER TABLE`, or status rewrite on the store
  - **Proof**: `packages/dartclaw_workflow/test/storage/sqlite_workflow_run_repository_test.dart#SqliteWorkflowRunRepository` – green – parity/regression (behavior groups stay; the `schema` group and the legacy paused-status migration group are retired with the repairs, see TI04)

- **S03 [OC02] [TI01,TI03] A production-shaped action rolls back every participant**
  - **Given** `createWorkflowTaskTriple` running over the seam-backed transactor, task repository, agent-execution repository, and a step-execution repository that throws on `create`, all constructed on one prepared `SqliteBackend`
  - **When** the action runs and the third write throws
  - **Then** the error reaches the caller unchanged, and neither the task nor the agent execution survives; the same action without the failure commits all three
  - **Proof**: `packages/dartclaw_workflow/test/workflow/workflow_task_factory_test.dart#rolls back task and agent execution when step execution insert fails` – green – parity/regression

- **S04 [OC02] [TI01] An outside seam operation waits and a nested action is rejected**
  - **Given** a transactor action whose body writes an agent execution, signals the test through a `Completer`, awaits a second test-controlled `Completer`, then throws
  - **When** the test – on the body's signal – issues a plain `backend.execute` insert from outside the action and a second `transactor.transaction` call from inside the body (which the body catches), then releases the gate
  - **Then** the outside write persists and completes only after the action's future completes (explicit completion ordering, never a delay), the body's write does not persist, the nested call threw `NestedTransactionError` promptly (no timeout), and the action's future rejects with the body's error

- **S05 [OC03] [TI05,TI06] Runtime, workflow-engine, and CLI consumers behave exactly as before**
  - **Given** the runtime wired through `StorageWiring.wire()` with the four classes on the shared task backend after the S04 gate call, the `workflow run --standalone` and lifecycle commands staging through `DartclawRuntime`, `workflow status` standalone, and `cleanup` workflow-artifact retention on the same store
  - **When** tasks are created and transitioned with a changed agent execution through `TaskService` (including an optimistic-lock conflict inside the action), workflow runs are created, resumed, and read through `service_wiring_workflow.dart`, the task and workflow routes and pages render, `workflow status` prints a run and its child steps, and `cleanup` prunes terminal runs' runtime artifacts
  - **Then** each surface produces the same response, page, CLI output, and caught-error behavior as released 0.25: the conflict path reports `false` with the agent execution untouched, and the standalone commands keep their exit codes
  - **Proof**: `apps/dartclaw_cli/test/commands/cleanup_command_test.dart#CleanupCommand workflow runtime-artifacts retention` – green – parity/regression (the other surfaces are bound by the TI05/TI06 Verify lines)

- **S06 [OC03] [TI05] Cleanup retention on an incompatible store skips with the existing warning**
  - **Given** retention enabled and a `tasks.db` file the S02 gate refuses (for example a legacy `tasks` table without `agent_execution_id`)
  - **When** `cleanup` runs
  - **Then** the run prints the existing `WARNING: workflow artifact retention skipped (database read failed): …` line, continues to the rest of the maintenance report, and leaves the file's `sqlite_master` and data unchanged – the gate's refusal lands in the same catch the constructor failure used to


## Structural Criteria

- **SC01** `sqlite_agent_execution_repository.dart`, `sqlite_workflow_step_execution_repository.dart`, `sqlite_execution_repository_transactor.dart`, and `sqlite_workflow_run_repository.dart` import no `package:sqlite3`; `packages/dartclaw_workflow/lib` contains no `package:sqlite3` import and `sqlite3` is gone from the `dependencies:` block of `packages/dartclaw_workflow/pubspec.yaml`; every S06-owned 0.25 census importer (`task_db.dart`, `search_db.dart`, `turn_state_store.dart`, `webhook_delivery_store.dart`, `service_wiring.dart`, `storage_wiring.dart`) keeps its import, and `apps/` stays at zero.
- **SC02** The four classes contain no DDL, `PRAGMA`, `ALTER TABLE`, `PRAGMA table_info`, raw `BEGIN`/`COMMIT`/`ROLLBACK`, completer-chain queue (`_tail`), `updatedRows`, or `workflow_run_migrations` access: `_initSchema` in all three repositories and `_migrateLegacyPausedStatuses` are gone; S02's `SqliteSchemaGate` is the sole schema precondition.
- **SC03** The ports are untouched: `ExecutionRepositoryTransactor` keeps `Future<T> transaction<T>(FutureOr<T> Function() action)`, `AgentExecutionRepository`, `WorkflowStepExecutionRepository`, and `WorkflowRunRepository` keep their members; every transactor call site (`task_service.dart`, `workflow_task_factory.dart`) and `service_wiring_workflow.dart` keep their 0.25 text; the `dartclaw_core` and `dartclaw_workflow` barrel export lines for the four classes are unchanged.
- **SC04** At all three production construction sites the four classes take the one `SqliteBackend` that wraps the task connection – in `StorageWiring.wire()` the S01 instance, in `workflow_status_command.dart` the S04 instance, and in `cleanup_command.dart` a new wrap-and-prepare inside the existing inner try – and no production site constructs any of the four from a raw `Database`.
- **SC05** Workspace analysis, the fitness suite (`dependency_direction`, `package_cycles`, `no_second_implementation`, `src_import_hygiene`, `barrel_show_clauses`, `no_duplicate_local_fakes`, `max_file_loc`, `max_test_file_loc`), `arch_check` (LOC band and 12-package ceiling, with `dartclaw_workflow`'s ceiling re-cut downward in this change), and `git diff --check` are green; the allowlisted `workflow_service_test.dart` does not grow past its ratchet.


## Scope & Boundaries

### Work Areas
- Seam consumers in `../dartclaw-public/packages/dartclaw_core/lib/src/storage/`: `sqlite_agent_execution_repository.dart`, `sqlite_workflow_step_execution_repository.dart`, `sqlite_execution_repository_transactor.dart`
- Seam consumer in `../dartclaw-public/packages/dartclaw_workflow/lib/src/storage/sqlite_workflow_run_repository.dart` plus `../dartclaw-public/packages/dartclaw_workflow/pubspec.yaml` (driver dependency leaves `dependencies:`)
- Construction sites: `../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart` (four lines in the tasks.db try block), `../dartclaw-public/apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart` (`_runStandalone`), `../dartclaw-public/apps/dartclaw_cli/lib/src/commands/cleanup_command.dart` (`_runWorkflowArtifactRetention`, gate-first)
- New suite `../dartclaw-public/packages/dartclaw_core/test/storage/sqlite_execution_repository_transactor_test.dart`
- Tests: the two repository suites (retired schema/migration tests), a new refusal test in `cleanup_command_test.dart`, and the 22 test files across `dartclaw_core`, `dartclaw_runtime`, `dartclaw_workflow`, and `dartclaw_cli` that construct one of the four classes today (`rg -l "SqliteAgentExecutionRepository\(|SqliteWorkflowStepExecutionRepository\(|SqliteWorkflowRunRepository\(|SqliteExecutionRepositoryTransactor\(" packages apps --glob '**/test/**'`) – construction-only updates
- `../dartclaw-public/dev/tools/arch_check.dart` `_libLocCeilings` (downward re-cut for `dartclaw_workflow`, and for `dartclaw_core` if reported)

### What We're NOT Doing

_(`S<NN>` outside `## Acceptance Scenarios` names a plan story; inside it, a scenario ID.)_

- Editing `sqlite_execution_row_mappers.dart` – story S04 (TI01) widens its row type and removes its driver import; this story only consumes the portable mappers. If S04's change is somehow absent at entry, that is a sequencing error to report, not work to redo here.
- The task-domain cluster (`SqliteTaskRepository`, `TaskEventService`, `TurnTraceService`, `TemporalKnowledgeGraphService`) – story S04; they participate in this story's transactions only as the seam-backed classes S04 delivers.
- Removal of `task_db.dart`/`search_db.dart` and the typedef factories, the CLI factory sweep, the `search.db` gate call, close-ownership transfer, and the `package:sqlite3` fitness check – story S06. This story adds exactly one `prepareTasks` call at `cleanup_command.dart` (S04's precedent: a class with no DDL cannot bootstrap a store the command opens on its own), and S06 takes it as given.
- Dropping `workflow_run_migrations` from S02's tasks manifest. After this story no code reads or writes the table, but it is part of the exact released-0.25 identity; removing it is a schema change with its own epoch bump. **NOTICED**: owner call, natural home S14 (store rename) or a later milestone.
- Typed storage exceptions, DSN redaction, or dialecting the SQL that flows through unchanged (`COALESCE`, dynamic `WHERE` assembly) – stories S07/S08/S11; FR1 is SQLite-only zero behavior change and the driver's `SqliteException` still propagates from a duplicate insert.
- Any workflow feature, status, cursor, or data-format change – the run repository's JSON envelopes and the legacy single-binding decoding stay byte-for-byte.


## Architecture Decision

**Approach**: Each of the four classes takes S01's `DatabaseBackend` by constructor and issues its existing SQL through `execute`/`query`; the transactor becomes a thin adapter from the kernel port's zero-argument action to `backend.transaction((_) => action())`, relying on S01's owner-instance join so repositories never see a `tx` handle; all constructor DDL, the `workflow_runs` column repairs, and the legacy paused-status rewrite are retired, and S02's gate becomes the only schema precondition at the one construction site that lacks it. See ADR: `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md` (decision #7, R2).
**Why this over alternatives**: threading `tx` through the repositories would change the kernel port and every already-async caller for nothing (the plan pins no contagion, and S01 scenario S04 proves the held-reference join); keeping the transactor's own completer queue on top of S01's slot would serialize twice and let a raw `BEGIN` collide with the backend's, which is exactly the double-door ADR-045 R2 warns about.


## Technical Overview

What changes (everything else keeps its 0.25 signature):

| Class | Change | Notes |
|---|---|---|
| `SqliteExecutionRepositoryTransactor` | constructor (`DatabaseBackend`); `transaction` delegates to `backend.transaction` | port unchanged; body error rethrown after rollback (S01 #3) so `TaskService`'s `_TaskTransitionConflict` still arrives as the same object; `_tail` and raw `BEGIN`/`COMMIT`/`ROLLBACK` deleted |
| `SqliteAgentExecutionRepository` | constructor (`DatabaseBackend`, `eventBus:`); `_initSchema` deleted; `update` guard uses the `execute` result | the status-change fire stays where it is – inside the body, before commit, as today |
| `SqliteWorkflowStepExecutionRepository` | constructor (`DatabaseBackend`); `_initSchema` (with its `PRAGMA foreign_keys=ON`) deleted; `update` guard uses the `execute` result | `foreign_keys=ON` is issued by the `task_db.dart` open helpers since S04 |
| `SqliteWorkflowRunRepository` | constructor (`DatabaseBackend`); `_initSchema`, `_migrateLegacyPausedStatuses`, and the now-unused `Logger` deleted; `setWorktreeBinding` guard uses the `execute` result; `_workflowRunFromRow` takes `Map<String, Object?>` | the class dartdoc ("shares the tasks database ([Database]) … CREATE TABLE IF NOT EXISTS") is rewritten to the prepared-store contract |

The paused-status rewrite is dead by construction after S02: every store the gate admits was created or opened by 0.24/0.25 code, whose constructor applied the rewrite and recorded it in `workflow_run_migrations`; a fresh store bootstraps with no paused rows. Retiring it therefore changes no admitted store, and an unrecognized shape is S02's refusal, never a repair.

Nested-call semantics: today a nested `transactor.transaction` deadlocks on its own queue; after this story it throws `NestedTransactionError` (S01 #3). No production caller nests (it would hang at 0.25), so no observable behavior moves; scenario S04 pins the new contract.

Construction at `cleanup_command.dart`: inside the existing inner try, wrap the opened connection in one `SqliteBackend`, `await SqliteSchemaGate.prepareTasks(backend, storeName: 'tasks.db')`, then construct the repository on the backend; the `finally` still closes the connection it opened (close ownership unchanged until S06). At `workflow_status_command.dart` the bare `SqliteAgentExecutionRepository(taskDb);` statement, which existed only for its schema side effect, is deleted; the run repository takes the S04 backend.


## Code Patterns & External References

```
# type | path#anchor                                                                                                                | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_goal_repository.dart#SqliteGoalRepository                  | S01 pilot – how a repository consumes DatabaseBackend (kernel import, execute/query usage, dispose posture)
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/database_backend.dart#DatabaseBackend                                   | the port: execute (affected rows), query (row maps), transaction, close (created by story S01; absent at HEAD `daf5125a`)
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/execution_repository_transactor.dart#ExecutionRepositoryTransactor      | the port the transactor keeps implementing unchanged
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_execution_repository_transactor.dart#SqliteExecutionRepositoryTransactor | the queue and raw transaction SQL to delete; only the class name, port, and constructor shape survive
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart#SqliteSchemaGate                          | prepareTasks – the call cleanup_command makes first; SchemaIncompatibleException lands in its existing catch (created by story S02; absent at HEAD)
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_execution_row_mappers.dart#agentExecutionFromRow           | S04-widened mappers – consume as-is
file   | ../dartclaw-public/packages/dartclaw_workflow/lib/src/storage/sqlite_workflow_run_repository.dart#_migrateLegacyPausedStatuses | the rewrite (and its BEGIN…COMMIT) to retire together with _initSchema
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/task/task_service.dart#TaskService                                       | the three transactor actions and the conflict-by-throw pattern the rethrow contract must preserve
file   | ../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/workflow_task_factory.dart#createWorkflowTaskTriple             | the production three-repository action scenario S03 binds
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring.wire                            | the tasks.db try block: S01 backend + S04 gate already there; four constructions switch to the backend
file   | ../dartclaw-public/apps/dartclaw_cli/lib/src/commands/cleanup_command.dart#_runWorkflowArtifactRetention                       | the one construction site without a gate call; inner try is where wrap-and-prepare goes
file   | ../dartclaw-public/apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart#_runStandalone                     | S04 gate-first site; drop the side-effect-only constructor statement
file   | ../dartclaw-public/packages/dartclaw_testing/lib/src/prepared_task_backend.dart                                                | S04 TI03 helper – the one shared prepared-backend fixture every swept test uses (created by story S04; absent at HEAD)
file   | ../dartclaw-public/packages/dartclaw_runtime/test/helpers/in_memory_execution_repository_transactor.dart                       | the in-memory double – unchanged; shows the port is all callers depend on
file   | ../dartclaw-public/dev/tools/arch_check.dart#_libLocCeilings                                                                   | the two-sided band – this story deletes workflow and core lines
```


## Constraints & Gotchas

- **Critical**: one `SqliteBackend` per connection, shared by every participant. The transactor, S04's task repository, and these three repositories must be constructed on the same instance at every site (production and test); a second wrapper has its own serialization slot and its writes escape the rollback. Never construct a `SqliteBackend` inside any of the four classes.
- **Critical**: the status event `SqliteAgentExecutionRepository.update` fires runs synchronously inside the transaction body, before commit – as at 0.25. Subscribers run in the body's zone and join the open transaction; storage work they leave running past the body carries a stale context and queues (S01 #3). Do not move the fire after commit "to be safe" – that is a behavior change to event ordering that no story asked for.
- **Critical**: `transaction()` must rethrow the body's error object after rollback (S01 #3). `TaskService` signals a conditional-update conflict by throwing `_TaskTransitionConflict` inside the body and catching it outside; wrapping or translating errors in the transactor breaks that path silently (the conflict would surface as an unhandled error instead of `false`).
- **Constraint**: affected-row guards use the `int` that `execute` returns; `_db.updatedRows` has no seam equivalent (three sites: agent-execution `update`, step-execution `update`, run `setWorktreeBinding`). Row iteration becomes iteration over `Map<String, Object?>`; the existing `as int?` / `as String?` casts keep working on the canonical scalar set.
- **Constraint**: gate before any constructor on a fresh connection, at every site. Tests use `openPreparedTaskBackend()` (S04 TI03); a test that seeds a file-backed store (`cleanup_command_test.dart` opens `tasks.db` by path) applies the same three steps inline on the connection it opened. `dartclaw_core/test`'s `failing_database_backend.dart` and `schema_fixtures.dart` are not importable from `dartclaw_workflow`, `dartclaw_runtime`, or `dartclaw_cli` tests – the incompatible store for scenario S06 is an inline legacy `CREATE TABLE tasks (id TEXT PRIMARY KEY, …)` without `agent_execution_id`, as S04's wiring gate test does.
- **Constraint**: two-sided LOC ratchet. Measured 2026-09-02: `dartclaw_workflow` 24132 of 25632 (slack exactly the 1500 band) and `dartclaw_core` 26269 of 27740. This story deletes roughly 100 lib lines from `dartclaw_workflow`, so `arch_check` will report slack above the band – lower `dartclaw_workflow`'s ceiling in `_libLocCeilings` in the same change (downward re-cut, no CHANGELOG note); apply the same to `dartclaw_core` if it reports after S01–S04's net change.
- **Constraint**: `workflow_service_test.dart` is allowlisted in `dev/fitness/test/allowlist/max_test_file_loc.txt` with ratchet 2198 against 2187 measured lines; its construction edits must be line-neutral or shrinking.
- **Constraint**: `dartclaw_workflow` declares `sqlite3` in `dependencies:` today solely for the run repository. After the import goes, remove it from `dependencies:`; if any `dartclaw_workflow` test still imports `package:sqlite3` after the sweep, declare it under `dev_dependencies:` instead (a dev entry is not a tier edge). Run `dart pub get` at the workspace root afterwards – it owns native-asset regeneration (tooling-verification learning).
- **Constraint**: `dartclaw_workflow` (T2) reaches `SqliteBackend`, `SqliteSchemaGate`, and `openTaskDbInMemory` only through the `dartclaw_core` barrel (`src_import_hygiene`), and `DatabaseBackend` through the `dartclaw_kernel` barrel; no new public name is introduced (`no_second_implementation`).
- **Constraint**: `dart test` runs suites as isolates in one process – prepared stores are in-memory per test, CLI tests get a temp data dir by path; never touch `Directory.current`.
- **Avoid**: calling `SqliteBackend.close()` from any of the four classes – none owns the connection; wiring and the CLI `finally` blocks close what they opened until S06 makes the composition root the sole close owner.
- **Constraint**: comments are rationale-only; the retired-repair history lives in this FIS and the CHANGELOG, not in dartdoc; no story IDs in code.


## Implementation Plan

### Implementation Tasks

- **TI01** The execution transactor rides S01's transaction contract
  - `packages/dartclaw_core/lib/src/storage/sqlite_execution_repository_transactor.dart` takes `DatabaseBackend` (imported from `package:dartclaw_kernel`), implements `transaction` as a delegation to `backend.transaction` that returns the body's value and lets its error propagate unchanged, and loses `_tail`, the completer chain, and every raw `BEGIN`/`COMMIT`/`ROLLBACK`; the port and the class name are unchanged. New suite `packages/dartclaw_core/test/storage/sqlite_execution_repository_transactor_test.dart` over `openPreparedTaskBackend()` with the seam-backed task, agent-execution, and step-execution repositories on the same backend. Depends on S01 and S04 only.
  - **Verify**: `cmd: ! rg -q "package:sqlite3|_tail|BEGIN|COMMIT|ROLLBACK|Completer" packages/dartclaw_core/lib/src/storage/sqlite_execution_repository_transactor.dart && rg -q "implements ExecutionRepositoryTransactor" packages/dartclaw_core/lib/src/storage/sqlite_execution_repository_transactor.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_execution_repository_transactor_test.dart` – the suite's `rolls back every participant when the body throws` test proves no task, agent execution, or step execution survives and the body's error object is what the caller receives (scenario S03's shape in core); `outside operation waits and nested action is rejected` proves scenario S04 by completion ordering through `Completer` handshakes with the outside write persisted, the body's write absent, and `NestedTransactionError` thrown promptly; the file holds no driver import, no queue, and no raw transaction SQL
  - **SATISFIES**: S03, S04, SC02, SC03

- **TI02** `SqliteAgentExecutionRepository` is seam-backed, schema-free, and behavior-identical
  - Constructor takes `DatabaseBackend` (keeping `eventBus:`); every statement runs through `execute`/`query`; `_initSchema` deleted; the `update` not-found guard uses the `execute` result; the status-change fire stays inside `update` exactly where it is. In `sqlite_agent_execution_repository_test.dart` the `creates table and indexes` test is deleted (S02 owns bootstrap) and construction moves onto `openPreparedTaskBackend()`; the `duplicate id surfaces sqlite constraint error` test keeps its `SqliteException` expectation (core tests may import the driver). Depends on TI01 for nothing; independent.
  - **Verify**: `cmd: ! rg -q "package:sqlite3|CREATE TABLE|CREATE INDEX|_initSchema|updatedRows" packages/dartclaw_core/lib/src/storage/sqlite_agent_execution_repository.dart && rg -q "AgentExecutionStatusChangedEvent" packages/dartclaw_core/lib/src/storage/sqlite_agent_execution_repository.dart && ! rg -q "creates table and indexes" packages/dartclaw_core/test/storage/sqlite_agent_execution_repository_test.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_agent_execution_repository_test.dart` – no driver, DDL, or `updatedRows`; the status event still fires from the repository; the bootstrap test is gone; every behavior assertion (round-trip with nulls, session ordering, update/delete, not-found `ArgumentError`, constraint error) passes unchanged (scenario S01)
  - **SATISFIES**: S01, SC01, SC02

- **TI03** `SqliteWorkflowStepExecutionRepository` is seam-backed, schema-free, and behavior-identical
  - Constructor takes `DatabaseBackend`; `_initSchema` and its `PRAGMA foreign_keys=ON` deleted (the open helpers issue it since S04); `update` guard uses the `execute` result; `listByRunId` ordering and the cascade from `tasks` are unchanged. The suites that exercise it – `sqlite_task_repository_test.dart` (cascade and joined hydration) and `workflow_task_factory_test.dart` – switch their construction onto the shared prepared backend. Independent of TI01/TI02.
  - **Verify**: `cmd: ! rg -q "package:sqlite3|CREATE TABLE|CREATE INDEX|PRAGMA|_initSchema|updatedRows" packages/dartclaw_core/lib/src/storage/sqlite_workflow_step_execution_repository.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_task_repository_test.dart packages/dartclaw_workflow/test/workflow/workflow_task_factory_test.dart` – no driver, DDL, PRAGMA, or `updatedRows`; the step-execution create/read/list/update/delete, the task-delete cascade, and the three-repository rollback pass unchanged (scenarios S01, S03)
  - **SATISFIES**: S01, S03, SC01, SC02

- **TI04** `SqliteWorkflowRunRepository` is seam-backed, repair-free, and `dartclaw_workflow` carries no driver
  - Constructor takes `DatabaseBackend` (from `package:dartclaw_kernel`); `_initSchema`, the `PRAGMA table_info`/`ALTER TABLE` column repairs, `_migrateLegacyPausedStatuses`, the `workflow_run_migrations` access, and the unused `Logger` are deleted; `setWorktreeBinding` uses the `execute` result; `_workflowRunFromRow` takes `Map<String, Object?>`; the class dartdoc states the prepared-store contract. In `sqlite_workflow_run_repository_test.dart` the `schema` group and the legacy paused-status migration group are deleted and construction moves onto `openPreparedTaskBackend()`. `sqlite3` leaves `dependencies:` in `packages/dartclaw_workflow/pubspec.yaml` (Constraints); the barrel export line is untouched. Independent of TI01–TI03.
  - **Verify**: `cmd: ! rg -q "package:sqlite3|CREATE TABLE|ALTER TABLE|PRAGMA|_migrateLegacyPausedStatuses|workflow_run_migrations|updatedRows|BEGIN|COMMIT|ROLLBACK|Logger" packages/dartclaw_workflow/lib/src/storage/sqlite_workflow_run_repository.dart && ! rg -q "package:sqlite3" packages/dartclaw_workflow/lib && ! sed -n '/^dependencies:/,/^dev_dependencies:/p' packages/dartclaw_workflow/pubspec.yaml | rg -q "sqlite3" && rg -q "show SqliteWorkflowRunRepository" packages/dartclaw_workflow/lib/dartclaw_workflow.dart && ! rg -q "creates workflow_runs table|legacy paused" packages/dartclaw_workflow/test/storage/sqlite_workflow_run_repository_test.dart && dart test --reporter=failures-only packages/dartclaw_workflow/test/storage/sqlite_workflow_run_repository_test.dart` – no driver, DDL, repair, rewrite, or `updatedRows` in the class; the workflow package's `lib/` and production dependency block are driver-free; the barrel export survives; the bootstrap and migration tests are gone; every round-trip, list, update, worktree-binding, and delete assertion passes unchanged (scenario S02)
  - **SATISFIES**: S02, SC01, SC02, SC03

- **TI05** All three production sites construct the cluster on the shared backend, cleanup gate-first
  - In `storage_wiring.dart#StorageWiring.wire` the four constructions take the S01 `SqliteBackend` after the S04 `prepareTasks` call, `TaskService` receives the seam-backed transactor, and the catch → `_exitFn(1)` path is untouched. In `workflow_status_command.dart#_runStandalone` the side-effect-only `SqliteAgentExecutionRepository(taskDb);` statement is deleted and `SqliteWorkflowRunRepository` takes the S04 backend. In `cleanup_command.dart#_runWorkflowArtifactRetention` the inner try wraps the connection in a `SqliteBackend`, awaits `SqliteSchemaGate.prepareTasks(backend, storeName: 'tasks.db')`, then constructs the repository on it; the outer `finally` still closes the connection; the stale "schema init runs in the repository constructor" comment is rewritten to the gate rationale. `cleanup_command_test.dart` seeds its file-backed store gate-first and gains `retention skips an incompatible tasks.db with the warning and leaves the file unchanged` (scenario S06, inline legacy DDL). Depends on TI01–TI04.
  - **Verify**: `cmd: ! rg -q "SqliteAgentExecutionRepository\(taskDb|SqliteWorkflowStepExecutionRepository\(taskDb|SqliteExecutionRepositoryTransactor\(taskDb|SqliteWorkflowRunRepository\(taskDb" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart && ! rg -q "SqliteAgentExecutionRepository\(" apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart && test "$(rg -n 'prepareTasks' apps/dartclaw_cli/lib/src/commands/cleanup_command.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'SqliteWorkflowRunRepository\(' apps/dartclaw_cli/lib/src/commands/cleanup_command.dart | head -1 | cut -d: -f1)" && dart analyze --fatal-infos && dart test --reporter=failures-only apps/dartclaw_cli/test/commands/cleanup_command_test.dart apps/dartclaw_cli/test/commands/workflow/workflow_status_command_test.dart apps/dartclaw_cli/test/commands/workflow/workflow_lifecycle_standalone_test.dart apps/dartclaw_cli/test/commands/workflow/workflow_run_command_standalone_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_tasks_gate_test.dart packages/dartclaw_runtime/test/runtime/dartclaw_runtime_test.dart packages/dartclaw_runtime/test/server_test.dart packages/dartclaw_runtime/test/api/task_routes_test.dart packages/dartclaw_runtime/test/api/workflow_routes_test.dart packages/dartclaw_runtime/test/task/task_service_locking_test.dart packages/dartclaw_runtime/test/task/task_service_events_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_workflow_preflight_test.dart` – no production site hands a raw `Database` to the four classes (analysis is the enforcer: the constructors no longer accept one), the status command's side-effect constructor is gone, cleanup prepares before constructing, and the CLI, wiring-gate, runtime, route, and task-service suites pass with unchanged assertions plus the new refusal test printing the existing warning line with the file's `sqlite_master` and data unchanged (scenarios S05, S06)
  - **SATISFIES**: S05, S06, SC04

- **TI06** Every test that constructs the cluster does so on a prepared shared backend
  - The remaining files of the 22 (Work Areas) switch to `openPreparedTaskBackend()` or the inline idiom, constructing all four classes and S04's classes on the same backend instance; test support files that expose a raw `Database` to their callers keep the connection they opened and add the backend beside it. `dart analyze` is the sweep enforcer. The `workflow_service_test.dart` edit is line-neutral (Constraints). Depends on TI01–TI05.
  - **Verify**: `cmd: dart analyze --fatal-infos && test "$(wc -l < packages/dartclaw_workflow/test/workflow/workflow_service_test.dart)" -le 2198 && dart test --reporter=failures-only packages/dartclaw_workflow packages/dartclaw_core/test/storage packages/dartclaw_runtime/test/api/workflow_sidebar_sse_test.dart packages/dartclaw_runtime/test/api/task_bindings_routes_test.dart packages/dartclaw_runtime/test/api/task_routes_provider_test.dart packages/dartclaw_runtime/test/web/pages/workflows_page_test.dart packages/dartclaw_runtime/test/helpers/in_memory_agent_execution_repository_test.dart` – analysis clean (no raw-`Database` construction survives anywhere), the allowlisted suite stays under its ratchet, and the whole workflow package suite, the core storage suite, and every runtime suite that constructs the cluster pass with unchanged assertions (scenarios S01, S02, S05)
  - **SATISFIES**: S01, S02, S05, SC05

- **TI07** The zero-behavior-change gate holds workspace-wide
  - Depends on TI01–TI06. Apply the downward ceiling re-cut for `dartclaw_workflow` (and `dartclaw_core` if reported) in `dev/tools/arch_check.dart#_libLocCeilings` in this change; run `dart pub get` at the workspace root after the pubspec edit.
  - **Verify**: `cmd: dart analyze --fatal-infos && ! rg -q "import 'package:sqlite3" packages/dartclaw_core/lib/src/storage/sqlite_agent_execution_repository.dart packages/dartclaw_core/lib/src/storage/sqlite_workflow_step_execution_repository.dart packages/dartclaw_core/lib/src/storage/sqlite_execution_repository_transactor.dart packages/dartclaw_workflow/lib/src/storage/sqlite_workflow_run_repository.dart && for f in packages/dartclaw_core/lib/src/storage/task_db.dart packages/dartclaw_core/lib/src/storage/search_db.dart packages/dartclaw_core/lib/src/storage/turn_state_store.dart packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart; do rg -q "import 'package:sqlite3" "$f" || exit 1; done && ! rg -l "import 'package:sqlite3" apps --glob '!**/test/**' | rg -q . && dart run dev/tools/arch_check.dart && git diff --check` – analysis clean, the four files import no driver, every S06-owned importer still does, `apps/` at zero, workspace suite, fitness suite, LOC band (after the re-cut), 12-package ceiling, and whitespace all green
  - **SATISFIES**: SC01, SC05

### Testing Strategy

- [TI01] The transactor suite is Layer 2 against real in-memory SQLite prepared by the S02 gate, with real seam-backed repositories as participants – a fake backend cannot prove serialization or rollback. Ordering is asserted through `Completer` handshakes and recorded completion order, never delays; the nested case must complete without a timeout, since a hang is exactly the 0.25 behavior being retired.
- [TI02–TI04] Keep every observable assertion; change only construction and the deleted bootstrap/migration tests. Deleted tests are not replaced: S02's identity and gate suites cover bootstrap and refusal of those shapes, and the paused-status rewrite has no admitted input left.
- [TI05] Scenario S06's incompatible store is inline legacy DDL written through the raw connection the test opened, before any backend wraps it; assert the warning line and a `sqlite_master`/data snapshot equality, not the exception type.

### Execution Contract

- Stories S01, S02, and S04 must be complete (this story consumes `SqliteBackend`, `SqliteSchemaGate`, the widened row mappers, the S04 gate calls at two sites, and `openPreparedTaskBackend()`). All commands run from the `../dartclaw-public/` root. TI01/TI02/TI03/TI04 (independent) → TI05 → TI06 → TI07.
- The public working tree may carry another session's uncommitted edits outside this story's Work Areas; touch only the files named there.
- If a caller is found that nests `transactor.transaction` (it would deadlock at 0.25), do not catch `NestedTransactionError` to preserve the hang – record it in Implementation Observations and let the S01 contract stand.


## Final Validation Checklist

- No `transaction()` implementation, DDL, PRAGMA, repair, rewrite, or `workflow_run_migrations` access exists in the four classes; the only new production call into S02 is `prepareTasks` at `cleanup_command.dart`.
- No kernel port file, `task_service.dart`, `workflow_task_factory.dart`, or `service_wiring_workflow.dart` changed; `dartclaw_testing` gained nothing.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

### Run: 2026-09-08 14:19 UTC – repair-proof

#### DRIFT

- spec-stale: TI07 Verify target repaired | Stale targets: – | `cmd: dart analyze --fatal-infos && ! rg -q "import 'package:sqlite3" packages/dartclaw_core/lib/src/storage/sqlite_agent_execution_repository.dart packages/dartclaw_core/lib/src/storage/sqlite_workflow_step_execution_repository.dart packages/dartclaw_core/lib/src/storage/sqlite_execution_repository_transactor.dart packages/dartclaw_workflow/lib/src/storage/sqlite_workflow_run_repository.dart && for f in packages/dartclaw_core/lib/src/storage/task_db.dart packages/dartclaw_core/lib/src/storage/search_db.dart packages/dartclaw_core/lib/src/storage/turn_state_store.dart packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart; do rg -q "import 'package:sqlite3" "$f" || exit 1; done && ! rg -l "import 'package:sqlite3" apps --glob '!**/test/**' | rg -q . && bash dev/tools/test_workspace.sh && bash dev/tools/fitness/run_all.sh && dart run dev/tools/arch_check.dart && git diff --check` → `cmd: dart analyze --fatal-infos && ! rg -q "import 'package:sqlite3" packages/dartclaw_core/lib/src/storage/sqlite_agent_execution_repository.dart packages/dartclaw_core/lib/src/storage/sqlite_workflow_step_execution_repository.dart packages/dartclaw_core/lib/src/storage/sqlite_execution_repository_transactor.dart packages/dartclaw_workflow/lib/src/storage/sqlite_workflow_run_repository.dart && for f in packages/dartclaw_core/lib/src/storage/task_db.dart packages/dartclaw_core/lib/src/storage/search_db.dart packages/dartclaw_core/lib/src/storage/turn_state_store.dart packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart; do rg -q "import 'package:sqlite3" "$f" || exit 1; done && ! rg -l "import 'package:sqlite3" apps --glob '!**/test/**' | rg -q . && dart run dev/tools/arch_check.dart && git diff --check`

### Run: 2026-09-08 14:19 UTC – observations

2026-09-08 16:14 CEST owner scheduling override: one focused independent review and relevant checks per story. Full workspace and full fitness runs in task Verify commands are deferred to the final combined A+B gate, with no acceptance requirement removed. The retained command proves the story-local checks; prose referring to full-suite success describes final milestone evidence. Standard fast-tier closure remains; broad integration, platform and release verification run at the end.

### Run: 2026-09-08 16:21 UTC – discovered-requirements

#### DISCOVERED REQUIREMENTS

- The shared FakeWorkflowService test factory also constructs SqliteWorkflowRunRepository. Keep the factory synchronous, replace its raw Database parameter with DatabaseBackend, and propagate that parameter through its nine call sites in seven runtime test files (server_test.dart, mcp_schema_compliance_test.dart, workflow_tools_test.dart, workflow_run_form_route_test.dart, github_webhook_test.dart, workflow_routes_test.dart, workflow_sse_test.dart). Each caller supplies the same prepared backend for its connection. Preserve assertions and connection ownership. These indirect fixture consumers extend the captured 22-file direct-constructor census without changing production scope or behavior.

### Run: 2026-09-08 17:01 UTC – observations

Focused gate closure: retained fake_async and restored virtual-time timeout assertions by constructing the prepared backend inside the fakeAsync zone. Awaiting the initial insert outside the zone alone did not fix the queued work; the real backend queue and timer now share one virtual-time zone. All 11 approval-step tests pass, focused analyze and format checks pass, and the direct fake_async dependency has a current consumer. Updated workflow package guidance to describe DatabaseBackend production ownership and dev-only sqlite3 fixtures. No timer-policy exception or real-time wait remains in the repaired test.

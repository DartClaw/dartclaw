# FIS: SQLite Schema Bootstrap and Compatibility Gate

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S02

_Refreshed 2026-09-02 against released 0.25 (public HEAD `daf5125a`), after the 2026-07-30 authoring (exact 0.23 baseline) and the 2026-08-14 rebase (exact 0.24 baseline). Version labels: 0.26 is this milestone (the PRD title still carries its pre-renumber label), released 0.25 is the compatibility baseline, 0.27 is the Chat consumer. The release-baseline gate fired again on 0.25: `workflow_step_executions.external_artifact_mount` was dropped with no migration, every other SQLite DDL is byte-identical 0.24 → 0.25 → HEAD. Per the gate's own rule the contract is refreshed, not widened – the one bounded transition now targets the exact released 0.25 required structure, and the identity is built so the orphan column is tolerated by construction._

## Feature Overview and Goal

**Intent**: Every SQLite store DartClaw opens today gets its schema from constructor-era `CREATE IF NOT EXISTS` plus ad-hoc additive repairs, so nothing can tell a current store from an unsupported one before repositories write to it – this story lands the smallest compatibility contract (one epoch plus required-object manifests) and its SQLite gate, so that fresh stores bootstrap atomically, the exact released 0.25 shape is adopted once, and every other authoritative shape is refused before use.

**Expected Outcomes**:

- [OC01] Fresh and current SQLite stores are structurally complete and epoch-marked before any repository uses them, with no additive repair replayed at open.
- [OC02] A store in the exact released 0.25 shape – including one upgraded from 0.24 that still carries the orphan `external_artifact_mount` column – gains the current epoch atomically without any change to domain data.
- [OC03] Incompatible authoritative data is never mutated and the operator gets a named, actionable refusal; incompatible derived search data is rebuilt only from complete supported inputs, otherwise refused with the prior file preserved.


## Required Context

- `docs/specs/0.26/plan.json#sharedDecisions` – decision "Schema compatibility: exact released 0.25 baseline, required-object manifests, ADR-045 amendment" is this story's contract (one epoch + required manifests, orphan tolerated by construction, no second adoption path, S02 writes the ADR amendment); decision "DatabaseBackend seam shape and placement under the 0.25 topology" places schema identity and the gate in `packages/dartclaw_core/lib/src/storage/`, pins the LOC ceilings, 1500/1300-line file caps, and explicit barrel `show` clauses.
- `docs/specs/0.26/prd.md#fr2-current-schema-bootstrap--compatibility-gate` – the acceptance criteria this story seeds (fresh bootstrap, epoch + manifest validation, one bounded transition, transactional rollback under injected failure, authoritative refusal with guidance, derived rebuild-or-refuse, no migration framework, test coverage list). **NOTICED**: the FR text still labels the baseline "released-0.24" and the milestone "0.25"; read it as released 0.25 / milestone 0.26 per the plan overview. The PRD amendment is owner-owned.
- `docs/specs/0.26/prd.md#edge-cases` – rows "Authoritative `tasks.db` … incompatible" and "Derived `search.db` schema is incompatible" fix the two refusal postures. The "Phase-A memory rebuild … empty `MEMORY.md`" row is a `MEMORY.md`-era fossil; the derived source at 0.25 is the canonical corpus (see Constraints, derived-source boundary).
- `docs/specs/0.26/prd.md#constraints` – ADR-045 contracts and the 2026-07-30 amendment are owner decisions not to be reopened; abstraction scope is exactly `tasks.db` + `search.db`; AOT single binary means no external schema tool.
- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#schema-bootstrap-and-compatibility` – the four startup outcomes and the no-framework rule this story implements. Item 2 still reads "verify the exact expected 0.23 structure" – neither the 2026-08-14 nor this rebase is recorded there; TI06 writes the dated amendment.
- `docs/specs/0.26/s01-databasebackend-seam-and-sqlite-backend.md#technical-overview` – the pinned seam contract this story consumes verbatim: `transaction()` semantics (#3), `execute` returning affected rows (#5), and construction shape #7 (an awaited factory, never DDL in a constructor). The gate is the first consumer of `transaction()` for DDL.
- `../dartclaw-public/packages/dartclaw_core/lib/src/storage/index_reconciler.dart#IndexHealthStore` – the JSON health file (`<workspaceDir>/.dartclaw-memory-index.json`) with `read` (throws `FormatException` on malformed evidence, reports a stale `rebuilding` state as interrupted degradation), `recordRebuilding`, `recordHealthy`, `recordDegraded`. Index health is this file, not a SQLite table; the derived rebuild publishes through it.
- `../dartclaw-public/dev/state/LEARNINGS.md#storage--data-model` – "guard missing columns at every SQL touch point" (why classification precedes every write) and "parse-then-rewrite makes a lenient parser destructive" (why unparseable health evidence refuses instead of being overwritten).
- `docs/specs/0.26/launch-context.md#live-storage-baseline` – the current schema, orphan-column compatibility fact, and live `StorageWiring.wire()` ordering that supersede the temporary re-plan audit.


## Deeper Context

- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#decided-posture--contracts-owner-accepted-2026-07-24` – decision #7 (seam shape) for what the gate may assume of `DatabaseBackend`.
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#amendment-2026-08-21--storage-absorption-landed` – why identity and gate live in `dartclaw_core` (the only driver-bearing package) and why `dartclaw_storage` no longer exists.
- `docs/specs/0.26/intent.md#resolved-decisions` – the minimality decisions (no runner, epoch + manifests). **NOTICED**: its "Supported SQLite transition – exact 0.23 shape only" row is superseded twice and never updated; owner-owned.
- `../dartclaw-public/dev/architecture/data-model.md#derived-memory-index-row` – `search.db` is a rebuildable projection of the validated canonical corpus; `MEMORY.audit.md` is never indexed.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#data-integrity` – storage services must prove restart persistence and crash-safe transitions; `#test-layers` – Layer 2 against real in-memory SQLite, no mocks.
- `../dartclaw-public/dev/state/LEARNINGS.md#tooling--verification` – `dart test` runs suites as isolates in one process (never touch `Directory.current`); the host `libsqlite3` can mask a skipped build hook.


## Acceptance Scenarios

- **S01 [OC01] [TI01,TI03,TI04] Fresh stores bootstrap atomically**
  - **Given** an empty `tasks.db` or `search.db` (no non-internal entry in `sqlite_master`)
  - **When** the SQLite gate prepares it
  - **Then** in one transaction the complete current schema is created with every required column declared directly in `CREATE TABLE` (no `ALTER TABLE ADD COLUMN` replay) and exactly one epoch row `(1, 1)` exists in `dartclaw_schema`; every manifest descriptor matches the live `PRAGMA table_info` / `index_list` / `index_info` / `sqlite_master` facts; a second prepare is a no-op.

- **S02 [OC01] [TI02,TI03,TI04] Current compatible stores reopen unchanged**
  - **Given** epoch `1` and a live structure satisfying the store's required manifest – including a `tasks.db` upgraded from 0.24 that still carries the nullable orphan column `workflow_step_executions.external_artifact_mount`, and a store that additionally holds an unrelated user table
  - **When** the gate inspects and prepares it
  - **Then** it classifies the store as current and performs no schema or data write (`PRAGMA schema_version` and a full data dump are identical before and after); the orphan column and the foreign table are neither required nor rejected.

- **S03 [OC02] [TI03] Exact released 0.25 authoritative data is adopted**
  - **Given** a populated, unmarked `tasks.db` in the exact released 0.25 shape – both the fresh-0.25 variant and the 0.24-upgraded variant with the orphan column
  - **When** the gate prepares it
  - **Then** in one transaction it adds only the `dartclaw_schema` table and row `(1, 1)`; every domain row and every pre-existing column, including the orphan, is byte-for-byte unchanged; a subsequent prepare classifies the store as current.

- **S04 [OC03] [TI02,TI03] Unsupported authoritative shapes fail closed**
  - **Given** a `tasks.db` that is unmarked and not exact 0.25 (owner-less `kg_facts`; `goals` without `max_tokens`; a legacy `tasks` table lacking `agent_execution_id`; a missing or differently-columned required index; a file holding only foreign objects), or marked with an absent, empty, duplicated, non-integer, older (`0`) or newer (`2`) epoch, or marked epoch `1` with a required table, column, or index missing or mismatched
  - **When** the gate inspects it
  - **Then** it throws the typed refusal before any repository is constructed, naming the store by the name the caller supplied (`tasks.db` today; S14 passes the renamed file), stating expected versus found epoch and the structural differences, and directing the operator to back up the store, then reset/recreate it for this release or restore a compatible one; the file is unchanged (`schema_version` and data dump identical). An unrecognized shape is a refusal, never a new transition.

- **S05 [OC01,OC02] [TI05] Every atomic transition rolls back on injected DDL failure**
  - **Given** a failure injected after each schema statement (every prefix `1..N`) of fresh `tasks.db` bootstrap, fresh `search.db` bootstrap, exact-0.25 adoption, and derived search rebuild, through a test-only `DatabaseBackend` decorator (no production fault seam)
  - **When** the transition runs
  - **Then** the pre-transition snapshot (`sqlite_master` and data dump) is unchanged – no epoch, partial object, or partial content persists – and a clean retry on the same backend instance converges on the current shape.

- **S06 [OC03] [TI04] Incompatible search is rebuilt from complete supported inputs**
  - **Given** an incompatible `search.db` (a 0.23-shaped `memory_chunks` lacking the five canonical-identity columns, or epoch `2`), readable health evidence (absent, healthy, degraded, or a stale `rebuilding` state from a crashed process), and a derived-rebuild source whose corpus projection populates at manifest revision `R` / fingerprint `F` and whose completion authentication succeeds – including the authenticated **empty** corpus
  - **When** the gate prepares it with that source
  - **Then** in one transaction the owned derived objects are dropped and recreated in the current shape, the projection is written through the caller's populate step, the marker `(1, 1)` is recorded, and after commit the health evidence reads `healthy` at `(R, F)`; an FTS5 `MATCH` returns the rebuilt content, and the empty corpus yields a current zero-row index rather than a refusal.
  - **Proof**: `packages/dartclaw_core/test/storage/index_reconciler_test.dart#validated empty corpus is healthy with exact zero rows` – green – parity/regression (pins that an authenticated empty corpus is a complete source; the gate's predicate must agree)

- **S07 [OC03] [TI04,TI05] Search rebuild is unavailable or fails**
  - **Given** an incompatible `search.db` and one of: no rebuild source supplied (preflight did not produce a manifest); the populate step throws; completion authentication fails (corpus revision changed mid-projection); the health evidence file is unparseable; or a DDL failure injected mid-rebuild
  - **When** the gate prepares it
  - **Then** it throws the typed refusal naming `search.db` and pointing at `dartclaw rebuild-index` with DartClaw stopped or restoring supported rebuild sources; the prior file contents (`sqlite_master` and data dump) are unchanged; health evidence records `degraded` with the failing stage, except in the unparseable case, where the evidence file is left byte-for-byte untouched and no store write occurs.


## Structural Criteria

- **SC01** The compatibility identity is exactly one integer epoch per store plus data-only required-object descriptors (tables with columns compared by name on declared type, not-null, default, and primary-key membership; indexes by name, table, uniqueness, ordered columns; the SQLite-required FTS5 table and three triggers by name) – no ordered history, version stream, migration class, generator, directive, or hook exists in the new files, and ordinal column position is not part of the identity.
- **SC02** Every schema transition runs inside S01's `DatabaseBackend.transaction()` on the backend instance handed to the gate (the instance repositories later use); the identity and gate files import no `package:sqlite3`, so the repo-wide `package:sqlite3` importer census stays at 18.
- **SC03** Fresh bootstrap creates final columns directly; `TemporalKnowledgeGraphService._migrateOwnerColumn` (with `hasOwnerColumn`) and `MemoryService._migrateResultColumns` are retired together with their additive-repair tests; the constructor-era repairs S04/S05 own (`goals.max_tokens`, `workflow_runs` columns, the legacy `tasks` rewrite) are untouched.
- **SC04** `workflow_run_migrations` is domain data of the workflow repository: it is a required table in the manifest but the gate never reads its rows, and `dartclaw_schema` is the only marker the gate names.
- **SC05** No production composition root or CLI path changes: the gate is barrel-exported from `dartclaw_core` under an explicit `show` clause and referenced nowhere in `dartclaw_runtime` or `apps/`; S06 wires it.
- **SC06** ADR-045 § Schema Bootstrap and Compatibility item 2 and its Status line carry a dated amendment recording both rebases: 2026-08-14 (exact 0.23 → exact 0.24, decided in the private bundle and never written into the ADR) and 2026-09-02 (exact 0.24 → exact released 0.25, the orphan column tolerated by construction, required-object manifests, no second adoption path).
- **SC07** The `dartclaw_core` suite, workspace analysis, the fitness suite, `arch_check` (LOC ceilings, 12-package ceiling), and `git diff --check` are green; no new test file exceeds 1300 lines and no lib file 1500.


## Scope & Boundaries

### Work Areas
- Schema identity descriptors: `../dartclaw-public/packages/dartclaw_core/lib/src/storage/schema_identity.dart` (`SchemaIdentity` for `tasks.db` and `search.db`)
- SQLite gate: `../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart` (`SqliteSchemaGate`, its store-state classification, `SchemaIncompatibleException`), `show`-exported from `../dartclaw-public/packages/dartclaw_core/lib/dartclaw_core.dart`
- Repair retirement: `../dartclaw-public/packages/dartclaw_core/lib/src/knowledge/temporal_knowledge_graph_service.dart` and `../dartclaw-public/packages/dartclaw_core/lib/src/storage/memory_service.dart`, plus their tests under `../dartclaw-public/packages/dartclaw_core/test/{knowledge,storage}/`
- Test fixtures and fault injection reused by S03/S04/S05/S07/S11: `../dartclaw-public/packages/dartclaw_core/test/storage/schema_fixtures.dart` (verbatim released-0.25 DDL and its variants) and `failing_database_backend.dart` (Nth-statement failing decorator), with new suites `schema_identity_test.dart`, `sqlite_schema_gate_test.dart`, `sqlite_schema_gate_search_test.dart`, `sqlite_schema_gate_rollback_test.dart`
- Public ADR: `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md` (§ Schema Bootstrap and Compatibility item 2 and the Status line)

### What We're NOT Doing

_(`S<NN>` outside `## Acceptance Scenarios` names a plan story; inside it, a scenario ID.)_

- A general migration runner, ordered versions, history ledger, SQL generator, directives, hooks, or wedged-migration recovery – rejected by FR2 and ADR-045; an unrecognized shape is refused, not transitioned.
- A second adoption path (exact 0.24 alongside exact 0.25) – the PRD's 2026-08-14 precedent rejects doubling the fingerprint/fixture/rollback matrix for a pre-alpha with no compatibility promise; a 0.24 store that was never opened by 0.25 is already in the 0.25 required shape (0.25 dropped a column, it added none) and adopts through the single path.
- PostgreSQL schema bootstrap – story S07 implements the same identity for PostgreSQL and re-parents `SchemaIncompatibleException` under the kernel `StorageException` family without renaming it.
- Retiring `MemoryService._initSchema`, the goals/workflow-runs/legacy-tasks constructor repairs, the connection PRAGMAs (`journal_mode=WAL`, `foreign_keys=ON`), or moving repositories onto the seam – stories S03/S04/S05 own their storage surfaces; between S02 and S06 those constructors still run their `CREATE IF NOT EXISTS` unchanged.
- Production open-path wiring, the refuse-versus-degrade posture of the composition root, and `dartclaw rebuild-index` – story S06 orders the gate into `StorageWiring.wire()` ahead of `CanonicalIndexReconciler`, story S10 the recovery/interlock order; the reconciler's sibling-file rebuild flow is untouched here and moves onto the seam in story S03.
- The `tasks.db` → `dartclaw.db` rename – story S14; the gate takes the store name from its caller so S14 changes no gate code.


## Architecture Decision

**Approach**: Immutable backend-owned manifests of *required* objects plus one epoch; classify before mutating, then allow exactly three writes – fresh bootstrap, exact-0.25 adoption (marker only), and derived rebuild from a proven-complete source – each inside one S01 `transaction()`. See ADR: `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md` (§ Schema Bootstrap and Compatibility, item 2 as amended by TI06).
**Why this over alternatives**: fingerprinting the live DDL (`sqlite_master.sql` or full `table_info` hashes) would reject every store upgraded from 0.24 because of one orphan column no statement names; a required-only manifest tolerates it by construction and still refuses any shape the running code cannot use.


## Technical Overview

`SchemaIdentity` (data only) carries `currentEpoch = 1` and the required table/column/index descriptors per store, plus the SQLite-specific required objects for `search.db`. `SqliteSchemaGate` operates on one already-open S01 `DatabaseBackend` and a caller-supplied store name, and classifies a store as **empty** (no non-internal `sqlite_master` entry), **current** (marker row `(1, 1)` and every required object matching), **released-unmarked** (no `dartclaw_schema` table, every required object matching – the exact released 0.25 shape), or **incompatible** (everything else, with typed detail). `prepareTasks` bootstraps empty stores, adopts released-unmarked stores by adding only the marker, accepts current stores without writes, and throws `SchemaIncompatibleException` otherwise. `prepareSearch` does the same and, for an incompatible store, accepts an optional derived-rebuild source – manifest revision and fingerprint, the `IndexHealthStore`, a `populate(tx)` step supplied by the memory side, and an `authenticateComplete()` step – and only with that source rebuilds: read health evidence (malformed → refuse, no write), `recordRebuilding`, one transaction that drops the owned derived objects, creates the current schema and marker, runs `populate`, then `authenticateComplete`, commits, then `recordHealthy`; any failure rolls back, records `degraded` with the stage, and rethrows as the typed refusal. The gate holds no memory-row SQL – the projection writer stays memory-side, and each corpus contributes its own populate/authenticate pair (S13 adds the conversation corpus).

The marker is `dartclaw_schema(id INTEGER PRIMARY KEY CHECK (id = 1), epoch INTEGER NOT NULL CHECK (typeof(epoch) = 'integer'))` with exactly row `(1, 1)` in each store. "Exact released 0.25 shape" means: every required table present with every required column matching by name on declared type, not-null, default expression, and primary-key membership; every required index present by name with the expected table, uniqueness, and ordered columns; for `search.db` the FTS5 table and three triggers present by name; no `dartclaw_schema` table. Anything outside the manifests – the orphan `external_artifact_mount`, `sqlite_sequence`, FTS shadow tables, `sqlite_autoindex_*`, unrelated user objects – neither satisfies nor invalidates it. Foreign-key clauses are not fingerprinted (no shipped shape differs only in them; fresh bootstrap declares them).


## Code Patterns & External References

```
# type | path#anchor                                                                                                          | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_task_repository.dart#_initSchema                      | released 0.25 DDL for agent_executions, workflow_step_executions (14 columns), tasks, task_artifacts and their indexes – copy into fresh bootstrap and the fixtures verbatim
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_task_repository.dart#_migrateLegacyTaskTableIfNeeded  | the legacy tasks rewrite the gate must never replay – its trigger conditions enumerate shapes S04 scenario refuses
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_goal_repository.dart#_initSchema                      | goals DDL; max_tokens is added by ALTER today and becomes a direct column in fresh bootstrap
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/task_event_service.dart#_initSchema                          | task_events DDL and three indexes
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/turn_trace_service.dart#_initSchema                          | turns DDL and five indexes
file   | ../dartclaw-public/packages/dartclaw_workflow/lib/src/storage/sqlite_workflow_run_repository.dart#_initSchema          | workflow_runs, workflow_run_migrations (domain data, SC04) and two indexes
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/knowledge/temporal_knowledge_graph_service.dart#_initSchema          | kg_facts DDL and kg_facts_lookup; _migrateOwnerColumn and hasOwnerColumn are the repair to retire
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/memory_service.dart#_initSchema                              | memory_chunks (11 columns), FTS5 table and triggers; _migrateResultColumns is the repair to retire
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/index_reconciler.dart#CanonicalIndexReconciler               | the shipped derived-rebuild and health protocol (recordRebuilding → healthy/degraded) the gate mirrors through the same store and must not re-implement
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#_canonicalRowBatches                 | how the corpus projection is produced at manifest revision/fingerprint with mid-stream consistency checks – the populate/authenticate shape S06 wires
file   | ../dartclaw-public/packages/dartclaw_core/test/storage/index_reconciler_test.dart#main                                  | fixture style for health-evidence and rebuild tests (temp workspace, injected transition hooks)
file   | ../dartclaw-public/packages/dartclaw_core/test/knowledge/temporal_knowledge_graph_service_test.dart#main                | the "owner migration is additive" test to delete and the hasOwnerColumn assertion to drop from the owner-persistence test
```


## Constraints & Gotchas

- **Required tables** (columns by name; type, not-null, default, and primary-key membership come from the released DDL cited above and are pinned by the TI01 fixtures):
  - `agent_executions`: `id, session_id, provider, model, workspace_dir, container_json, budget_tokens, harness_meta_json, started_at, completed_at`
  - `workflow_step_executions`: `task_id, agent_execution_id, workflow_run_id, step_index, step_id, step_type, git_json, provider_session_id, structured_schema_json, structured_output_json, follow_up_prompts_json, map_iteration_index, map_iteration_total, step_token_breakdown_json` (`external_artifact_mount` is **not** required: 0.25 dropped it, 0.24-upgraded stores keep it as a nullable orphan)
  - `tasks`: `id, title, description, type, status, version, goal_id, acceptance_criteria, config_json, worktree_json, created_at, started_at, completed_at, created_by, agent_execution_id, project_id, workflow_run_id, step_index, max_retries, retry_count` (`type` is still written, with a storage placeholder, since 0.25 retired `TaskType`)
  - `task_artifacts`: `id, task_id, name, kind, path, created_at`
  - `goals`: `id, title, parent_goal_id, mission, created_at, max_tokens`
  - `task_events`: `id, task_id, timestamp, kind, details`
  - `turns`: `id, session_id, task_id, runner_id, model, provider, started_at, ended_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, is_error, error_type, tool_calls`
  - `workflow_runs`: `id, definition_name, status, context_json, variables_json, started_at, updated_at, completed_at, error_message, total_tokens, current_step_index, definition_json, execution_cursor_json, workflow_worktree_json`
  - `workflow_run_migrations`: `name, applied_at`
  - `kg_facts`: `id, entity, predicate, value, valid_from, valid_to, source, owner, invalidated_at, invalidation_reason, created_at`
- **Required tasks indexes** (`name(table; unique; ordered columns)`, 21): `idx_tasks_status(tasks;false;status)`, `idx_tasks_type(tasks;false;type)`, `idx_tasks_status_type(tasks;false;status,type)`, `idx_tasks_workflow_run_id(tasks;false;workflow_run_id)`, `idx_task_artifacts_task_id(task_artifacts;false;task_id)`, `idx_agent_executions_session_id(agent_executions;false;session_id)`, `idx_agent_executions_provider(agent_executions;false;provider)`, `idx_wse_run_step(workflow_step_executions;false;workflow_run_id,step_index)`, `idx_wse_agent_execution(workflow_step_executions;false;agent_execution_id)`, `idx_goals_parent(goals;false;parent_goal_id)`, `idx_task_events_task(task_events;false;task_id)`, `idx_task_events_task_kind(task_events;false;task_id,kind)`, `idx_task_events_timestamp(task_events;false;timestamp)`, `idx_turns_session(turns;false;session_id)`, `idx_turns_task(turns;false;task_id)`, `idx_turns_started(turns;false;started_at)`, `idx_turns_model(turns;false;model)`, `idx_turns_provider(turns;false;provider)`, `idx_workflow_runs_status(workflow_runs;false;status)`, `idx_workflow_runs_definition(workflow_runs;false;definition_name)`, `kg_facts_lookup(kg_facts;false;entity,predicate,valid_from,valid_to)`.
- **Required search manifest** (unchanged since the 2026-08-14 correction; verified byte-identical at 0.25): `memory_chunks(id, text, source, category, created_at, user_id, role, provenance, locator, entry_id, entry_revision)` with `role TEXT NOT NULL DEFAULT 'memory'`, `provenance TEXT NOT NULL DEFAULT 'unknown'`, `locator TEXT`, `entry_id TEXT`, `entry_revision INTEGER`; FTS5 virtual table `memory_chunks_fts(body)` with external content `memory_chunks` / rowid `id`; triggers `memory_chunks_ai`, `memory_chunks_ad`, `memory_chunks_au`; no conventional index. The six additive definitions in `_migrateResultColumns` are byte-identical to the `CREATE TABLE` definitions, so a store it upgraded and a fresh store present the same descriptors – the gate needs no tolerance here and the repair retires without a compatibility gap.
- **Derived-source boundary** *(per-corpus predicate amended 2026-08-07 for the S13 rider; source corrected 2026-08-14 to the canonical corpus; memory predicate re-verified 2026-09-02 against 0.25)*: completeness is decided **per corpus**, each contributing its own populate/authenticate pair, and every pair must succeed for the rebuild to commit. At S02's execution the only corpus is memory, whose authoritative source is the canonical corpus manifest produced after `MemoryPreflight` (fatal before any store opens): the projection is complete when it is produced at one manifest `collectionRevision`/`fingerprint` and `MemoryCorpusService.authenticate(manifest)` succeeds afterwards. An authenticated **empty** corpus is a complete source yielding a zero-row index – the shipped reconciler pins this (scenario S06 Proof) – so the earlier "non-empty" clause, a `MEMORY.md`-era condition, is retired; a null manifest, a revision change mid-projection, or a failed authentication is not complete. `MEMORY.md` is not a source. S13 adds the conversation corpus (session NDJSON; zero chat-facing sessions is a complete empty source).
- **Reconciler ownership** *(2026-08-14, restated)*: `CanonicalIndexReconciler` remains the content-reconciliation and health authority and its sibling-file rebuild flow is untouched. The gate owns schema classification and preparation; its derived rebuild is the schema-level transition that exists because an incompatible `search.db` cannot be opened by the reconciler's fast path at all, and it publishes through the same `IndexHealthStore` so the reconciler, ordered after it by S06, fast-paths on healthy `(R, F)` evidence instead of rebuilding twice.
- **Inspection boundary**: ignore `sqlite_%` internal tables, FTS5 shadow tables (`memory_chunks_fts_*`), and autoindexes; compare columns by name, never by `cid`; unrelated user objects neither satisfy nor invalidate the manifest; emptiness means no non-internal `sqlite_master` entry at all.
- **Critical**: in-memory SQLite is connection-local and `transaction()` serializes per `SqliteBackend` instance – inspect, transition, and later repository use must share one instance; the rollback matrix must retry on the same instance.
- **Critical**: the derived rebuild awaits the caller's populate stream inside the transaction, holding S01's serialization slot; that is acceptable only at startup before other seam users exist (S06's order guarantees it). Never add a second connection or a fallback path to "help".
- **Avoid**: production callbacks or flags for fault injection – use the test-only `DatabaseBackend` decorator that fails on the Nth `execute` inside `transaction()` (TI05).
- **Constraint**: refusal messages are assembled from the caller-supplied store name and the typed detail; never embed a path the caller did not pass (S14 renames the file, S08 owns redaction posture).
- **Constraint**: comments are rationale-only; the identity's dartdoc states the contract (required-only semantics, orphan tolerance), not the history of rebases – that history lives in ADR-045 (TI06).


## Implementation Plan

### Implementation Tasks

- **TI01** The released-0.25 schema identity is explicit, data-only, and pinned by verbatim fixtures
  - `packages/dartclaw_core/lib/src/storage/schema_identity.dart` declares `SchemaIdentity` (epoch `1`, the required table/column/index descriptors above, the SQLite FTS5 table and triggers for `search.db`); `packages/dartclaw_core/test/storage/schema_fixtures.dart` carries the released DDL copied verbatim from the cited `_initSchema` sites as raw literals (never produced by the code under test), in variants: fresh 0.25, 0.24-upgraded (orphan `external_artifact_mount` present between `follow_up_prompts_json` and `map_iteration_index`), 0.23-shaped `search.db` (five canonical columns absent), owner-less `kg_facts`, `goals` without `max_tokens`, legacy `tasks` without `agent_execution_id`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/schema_identity_test.dart --plain-name "manifests describe the released 0.25 fixtures exactly" && ! rg -q "class \w*(Migration|Migrator|History|Upgrade)\w*" packages/dartclaw_core/lib/src/storage/schema_identity.dart packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart` – on both the fresh and the 0.24-upgraded fixture every descriptor equals the live `PRAGMA table_info` / `index_list` / `index_info` / `sqlite_master` facts, all 21 indexes and the FTS5 table plus three triggers are covered, and `! rg -q "class \w*(Migration|Migrator|History|Upgrade)\w*" packages/dartclaw_core/lib/src/storage/schema_identity.dart packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart` exits 0
  - **SATISFIES**: S01, SC01

- **TI02** SQLite stores are classified read-only before any write
  - `SqliteSchemaGate.inspect(backend, identity)` reads only `sqlite_master`, the PRAGMAs, and `dartclaw_schema` through S01 `query`, returning empty / current / released-unmarked / incompatible with typed detail (store name, expected and found epoch, missing or mismatched objects, operator guidance). Depends on TI01.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart --plain-name "classification" && ! rg -q "workflow_run_migrations" packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart` – table-driven over all four classes plus absent/empty/duplicate/non-integer/older/newer epochs and every required table, column, index, FTS, and trigger mismatch from scenario S04; incompatible inspection leaves `PRAGMA schema_version` and the data dump unchanged; and `! rg -q "workflow_run_migrations" packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart` exits 0
  - **SATISFIES**: S02, S04, SC04

- **TI03** The authoritative `tasks.db` is prepared safely and the temporal-KG owner repair is retired
  - `SqliteSchemaGate.prepareTasks(backend, storeName:)` bootstraps an empty store (full final DDL with direct columns, marker, one transaction), adopts released-unmarked by adding only the marker, accepts current without writes, otherwise throws `SchemaIncompatibleException`; `_migrateOwnerColumn` and `hasOwnerColumn` are deleted from `temporal_knowledge_graph_service.dart`, the "owner migration is additive" test is deleted and the `hasOwnerColumn` expectation dropped from the owner-persistence test. Depends on TI02.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart --plain-name "authoritative tasks store" && ! rg -q "_migrateOwnerColumn|hasOwnerColumn" packages/dartclaw_core/lib/src/knowledge/temporal_knowledge_graph_service.dart packages/dartclaw_core/test/knowledge/temporal_knowledge_graph_service_test.dart` – scenarios S01–S04 for `tasks.db`: populated adoption of both released variants preserves a before/after domain dump byte-for-byte, owner-less `kg_facts` is refused unchanged with the store name in the message; and `! rg -q "_migrateOwnerColumn|hasOwnerColumn" packages/dartclaw_core/lib/src/knowledge/temporal_knowledge_graph_service.dart packages/dartclaw_core/test/knowledge/temporal_knowledge_graph_service_test.dart` exits 0
  - **SATISFIES**: S01, S02, S03, S04, SC03

- **TI04** The derived `search.db` is prepared, rebuilt from a proven-complete source, or refused; the memory additive repair is retired
  - `SqliteSchemaGate.prepareSearch(backend, storeName:, rebuild:)` with the same classifier; for an incompatible store with a rebuild source, apply the Technical Overview protocol (health read → `recordRebuilding` → one transaction: drop owned objects, current DDL, marker, `populate(tx)`, `authenticateComplete()` → `recordHealthy`); without a source, or on any failure, refuse with the prior contents intact and `degraded` recorded (never on unparseable evidence). `_migrateResultColumns` is deleted from `memory_service.dart`; `_initSchema` itself stays (S03 retires it). Depends on TI02.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_search_test.dart --plain-name "derived search store" && ! rg -q "_migrateResultColumns" packages/dartclaw_core/lib/src/storage/memory_service.dart` – scenarios S01, S02, S06, S07 for `search.db`: rebuilt content answers an FTS5 `MATCH`, the authenticated empty corpus yields a current zero-row index, health evidence is `healthy` at `(R, F)` after rebuild and `degraded` with the stage after each refusal, the unparseable-evidence case leaves both the store and the evidence file byte-identical; and `! rg -q "_migrateResultColumns" packages/dartclaw_core/lib/src/storage/memory_service.dart` exits 0
  - **SATISFIES**: S01, S02, S06, S07, SC03

- **TI05** Every transition rolls back under injected DDL failure and converges on retry
  - `packages/dartclaw_core/test/storage/failing_database_backend.dart` decorates any `DatabaseBackend`, failing the Nth `execute` issued through a `transaction()` handle (reusable by S03/S07/S11); the suite parameterizes `N` over `1..statementCount` for fresh tasks bootstrap, fresh search bootstrap, marker adoption, and derived rebuild. Depends on TI03 and TI04.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_rollback_test.dart --plain-name "every DDL prefix rolls back and a clean retry converges"` – after each injected failure the pre-transition `sqlite_master` and data dump are unchanged and no `dartclaw_schema` row exists, the retry on the same backend instance yields the current classification, and a mid-rebuild failure leaves the incompatible `search.db` contents intact with `degraded` evidence
  - **SATISFIES**: S05, S07

- **TI06** ADR-045 records both compatibility-baseline rebases
  - In `dev/adrs/045-pluggable-database-backend.md`, rewrite § Schema Bootstrap and Compatibility item 2 to the current contract (exact released 0.25 required structure; required-object manifests with the orphan `external_artifact_mount` tolerated by construction; marker-only adoption; no second adoption path) and append a dated amendment to the Status line naming both rebases (2026-08-14: exact 0.23 → exact 0.24, decided in the private bundle, unrecorded until now; 2026-09-02: exact 0.24 → exact released 0.25). Use `date +%Y-%m-%d` for the amendment date; en dashes; no story IDs in the ADR body beyond the milestone label. Public-repo doc edit executed in-milestone.
  - **Verify**: `cmd: rg -q "exact released 0\.25" dev/adrs/045-pluggable-database-backend.md && rg -q "external_artifact_mount" dev/adrs/045-pluggable-database-backend.md && rg -q "2026-08-14" dev/adrs/045-pluggable-database-backend.md && ! rg -q "exact expected 0\.23 structure" dev/adrs/045-pluggable-database-backend.md` – item 2 names the 0.25 baseline and the tolerated orphan, the Status line carries the 2026-08-14 rebase, and the 0.23 wording is gone
  - **SATISFIES**: SC06

- **TI07** The gate is exported, unwired in production, and the storage regression and fitness gates stay green
  - `export 'src/storage/sqlite_schema_gate.dart' show SqliteSchemaGate, SchemaIncompatibleException, …;` and the `SchemaIdentity` export carry explicit `show` clauses in `dartclaw_core.dart`; nothing in `dartclaw_runtime` or `apps/` references the gate. If `arch_check` reports a crossed `dartclaw_core` ceiling, apply the rebaseline protocol (ceiling raise in `dev/tools/arch_check.dart#_libLocCeilings` plus a CHANGELOG note) in the same change. Depends on TI01–TI06.
  - **Verify**: `cmd: rg -qU "sqlite_schema_gate\.dart'\s*show[^;]*\bSqliteSchemaGate\b" packages/dartclaw_core/lib/dartclaw_core.dart && ! rg -q "SqliteSchemaGate|SchemaIdentity" packages/dartclaw_runtime/lib apps && ! rg -q "package:sqlite3" packages/dartclaw_core/lib/src/storage/schema_identity.dart packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart && test "$(rg -l "import 'package:sqlite3" packages apps --glob '!**/test/**' --glob '!**/*_test.dart' | wc -l | tr -d ' ')" = 18 && dart analyze --fatal-infos && dart test --reporter=failures-only packages/dartclaw_core && bash dev/tools/fitness/run_all.sh && dart run dev/tools/arch_check.dart && git diff --check` – barrel export under `show`, no production wiring, no new `sqlite3` importer (census 18), core suite, fitness suite, LOC/package ceilings, and whitespace check all green
  - **SATISFIES**: SC02, SC05, SC07

### Testing Strategy

- [TI02–TI05] Layer 2 against real SQLite (`openTaskDbInMemory()` / `openSearchDbInMemory()` wrapped in S01's `SqliteBackend`, temp files under a per-test `Directory.systemTemp.createTemp` for health evidence) – transactional DDL is the behavior under test, so no mocks; never touch `Directory.current`.
- [TI01,TI03,TI04] Fixtures are raw DDL literals; a fixture built by the gate's own bootstrap would never exercise the classifier against foreign input.
- [TI05] Assert the pre-transition snapshot after each failure and the converged state after retry, not merely that an exception was thrown; the failure must hit the claimed transition (count statements per transition, assert the injected `N` was reached).
- [TI03,TI04] Compare observable schema/data snapshots and typed failures; do not assert private call order.

### Execution Contract

- Story S01 must be complete (the gate consumes `SqliteBackend` and `transaction()`). All commands run from the `../dartclaw-public/` root. TI01 → TI02 → TI03/TI04 → TI05 → TI06 → TI07.
- Do not broaden a discovered historical repair into a transition: an unrecognized authoritative shape is a refusal.
- The public working tree may carry another session's uncommitted edits outside this story's Work Areas; touch only the files named there.


## Final Validation Checklist

- No runner, migration history/version stream, generator, directives, hooks, or production fault-injection seam exists; `dartclaw_schema` is the only marker.
- No composition-root, CLI, or reconciler code changed; the only non-test production edits are the two new files, the two repair retirements, the barrel export, and ADR-045.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI01 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/storage/schema_identity_test.dart#manifests describe the released 0.25 fixtures exactly` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/schema_identity_test.dart --name "manifests describe the released 0.25 fixtures exactly"`

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart#classification` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart --name "classification"`

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart#authoritative tasks store` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart --name "authoritative tasks store"`

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/storage/sqlite_schema_gate_search_test.dart#derived search store` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_search_test.dart --name "derived search store"`

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI05 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/storage/sqlite_schema_gate_rollback_test.dart#every DDL prefix rolls back and a clean retry converges` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_rollback_test.dart --name "every DDL prefix rolls back and a clean retry converges"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI01 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/schema_identity_test.dart --name "manifests describe the released 0.25 fixtures exactly"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/schema_identity_test.dart --plain-name "manifests describe the released 0.25 fixtures exactly"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart --name "classification"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart --plain-name "classification"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart --name "authoritative tasks store"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart --plain-name "authoritative tasks store"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_search_test.dart --name "derived search store"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_search_test.dart --plain-name "derived search store"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI05 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_rollback_test.dart --name "every DDL prefix rolls back and a clean retry converges"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_rollback_test.dart --plain-name "every DDL prefix rolls back and a clean retry converges"`

### Run: 2026-09-05 08:42 UTC – repair-proof

#### DRIFT

- spec-stale: TI01 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/schema_identity_test.dart --plain-name "manifests describe the released 0.25 fixtures exactly"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/schema_identity_test.dart --plain-name "manifests describe the released 0.25 fixtures exactly" && ! rg -q "class \w*(Migration|Migrator|History|Upgrade)\w*" packages/dartclaw_core/lib/src/storage/schema_identity.dart packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart`

### Run: 2026-09-05 08:42 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart --plain-name "classification"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart --plain-name "classification" && ! rg -q "workflow_run_migrations" packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart`

### Run: 2026-09-05 08:42 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart --plain-name "authoritative tasks store"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart --plain-name "authoritative tasks store" && ! rg -q "_migrateOwnerColumn|hasOwnerColumn" packages/dartclaw_core/lib/src/knowledge/temporal_knowledge_graph_service.dart packages/dartclaw_core/test/knowledge/temporal_knowledge_graph_service_test.dart`

### Run: 2026-09-05 08:42 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_search_test.dart --plain-name "derived search store"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_search_test.dart --plain-name "derived search store" && ! rg -q "_migrateResultColumns" packages/dartclaw_core/lib/src/storage/memory_service.dart`

### Run: 2026-09-08 11:40 UTC – observations

#### ASSUMPTIONS (AUTO_MODE)
- The explicit S07/TI04 failure-preservation invariant governs the healthy-publication order: publish healthy evidence inside the existing database transaction after authentication, then commit. The outer failure path records degraded evidence. This supersedes the Technical Overview's post-commit narration without weakening any failed-rebuild outcome.
- SqliteSearchRebuild carries health context independently of complete source availability: its populate/authenticate pair may be absent, in which case preparation records degraded unavailable-source evidence before refusing without database writes. Callers with existing health evidence must supply this context even when the source is unavailable. A wholly absent context identifies no writable evidence authority and can only produce the typed refusal; no manifest is invented.
- Reserved marker collision checks follow SQLite's shared table/view/index namespace case-insensitively. Same-named triggers do not collide and remain unrelated objects. Malformed health optional fields are rejected by the existing IndexHealthStore decoder authority as FormatException.

### Run: 2026-09-08 12:13 UTC – observations

The required fast-tier runtime suite exposed a pre-existing two-second polling race in task_autonomy_test.dart. The minimum gate unblock replaces eight wall-clock polling calls with the existing TaskExecutor.drain() barrier, retaining every status assertion explicitly. No production behavior changes. Targeted tests pass 15/15; full runtime suite passes 4770 with its 10 configured skips. Full completion replay remains required.

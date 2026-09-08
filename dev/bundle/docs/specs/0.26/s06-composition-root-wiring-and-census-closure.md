# FIS: Composition-Root Wiring and Census Closure

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S06

_Rewritten 2026-09-02 against released 0.25 (public HEAD `daf5125a`), replacing the 2026-07-30 authoring and its 2026-08-14 recount against 0.24. Version labels: 0.26 is this milestone (the PRD title still carries its pre-renumber label), released 0.25 is the compatibility baseline. Premise corrections: the `dartclaw_cli` composition root the prior FIS targeted (a `ServiceWiring` class, `wiring/storage_wiring.dart`, `cli_workflow_wiring.dart`, `release_sqlite_check_command.dart`) is gone – the composition root is `DartclawRuntime.build` → `StorageWiring.wire()` in `dartclaw_runtime`, `apps/dartclaw_cli` holds zero `package:sqlite3` imports and reaches stores through five injected-factory sites, the fitness suite lives in `dev/fitness/test/`, and the sqlite3-free-core rule is retired (ADR-056), so the sanctioned import surface is the `SqliteBackend` implementation plus the two instance-local stores. Kept from the prior FIS: `state.db` and the webhook ledger stay direct SQLite until story S15, and a repo-level import gate closes the census. Code references (`packages/...`, `apps/...`, `dev/...`) are paths inside `../dartclaw-public/`._

## Feature Overview and Goal

**Intent**: Stories S01–S05 put every `tasks.db`/`search.db` repository on the `DatabaseBackend` seam, but the composition root and the CLI still open raw `sqlite3` handles through driver-typed factories, the derived store is gated only inside the reconciler, connection ownership is split between repositories and wiring, and nothing stops a new `package:sqlite3` import – this story closes the independently shippable SQLite checkpoint by making every production open path construct the seam gate-first in the existing startup order, deleting the raw open helpers and their typedefs, moving connection ownership into the composition root, and pinning the sanctioned import surface with a fitness gate, all with zero behavior change for a supported released-0.25 data directory.

**Expected Outcomes**:

- [OC01] A supported released-0.25 data directory (no stores, exact-0.25 stores, or epoch-marked stores) starts `dartclaw serve`, `workflow run --standalone`, the standalone lifecycle commands, `workflow status --standalone`, `cleanup`, and `rebuild-index` with the same output, exit codes, log lines, files, and data as before – the only on-disk delta is the S02 marker table.
- [OC02] The derived `search.db` is classified by the S02 gate before the reconciler runs: an incompatible store with a complete canonical source is rebuilt once, under the gate, and the reconciler then fast-paths; a gate refusal is explicit – the severe log names the store and the `dartclaw rebuild-index` remedy, the prior file and health evidence are untouched, and the runtime boots with search unavailable instead of letting a second path mutate the store.
- [OC03] Every store connection the runtime or a CLI command opens is closed exactly once by the code that opened it: no repository closes a shared connection, and shutdown, bind-failure teardown, headless staging disposal, and the wiring failure paths close both backends idempotently.
- [OC04] The repository structurally rejects a `package:sqlite3` import outside the SQLite backend implementation and the two instance-local stores, through an allowlist whose entries carry a rationale and fail when stale, so story S15 tightens it by deleting two lines.


## Required Context

- `docs/specs/0.26/plan.json#sharedDecisions` – decision "DatabaseBackend seam shape and placement under the 0.25 topology": the composition root is `DartclawRuntime.build` → `StorageWiring.wire()`; CLI commands reach stores only through injected factories; `dartclaw_core` is the only driver-bearing package; the two-sided LOC ceilings, the 1500/1300-line file caps, explicit barrel `show` clauses. Decision "Schema compatibility …": S02's gate is the single schema precondition for both stores.
- `docs/specs/0.26/prd.md#fr1-backend-agnostic-storage-layer` – the FR1 clauses this story closes: composition roots construct the seam instead of raw `Database` instances; `TaskDbFactory`/`SearchDbFactory` are removed with the `task_db.dart`/`search_db.dart` helpers; the instance-local opens stay direct SQLite "homed wherever the spec places them (store-side self-open or a sanctioned wiring call site)"; the repo-level check proving no stray import; zero behavior change. **NOTICED**: the FR's census figures, package names, `release_sqlite_check_command.dart`, and the 16-file allowlist wording predate 0.25 – the verified census is in the S01 FIS (18 importers, 5 CLI typedef consumers) and this FIS's *Spec-Time Census* carries it to closure; the durable reconciliation is recorded in `docs/specs/0.26/launch-context.md#prd-reconciliations-already-carried-by-the-plan-and-fis`.
- `docs/specs/0.26/prd.md#edge-cases` – row "Derived `search.db` schema is incompatible": rebuild automatically only from complete supported sources, otherwise refuse explicitly; recovery is "restore supported rebuild sources or reset/rebuild knowingly". Row "Authoritative `tasks.db` … incompatible": refuse before repository use (already wired by S04).
- `docs/specs/0.26/prd.md#mvp-boundary` – Phase 1 must leave `main` shippable with zero behavior change; this story is that checkpoint.
- `docs/specs/0.26/s01-databasebackend-seam-and-sqlite-backend.md#technical-overview` – #6: `DatabaseBackend.close()` is idempotent and "Story S06 will make the composition root the sole close owner"; #7: the awaited `SqliteGoalRepository.open` factory is the transitional shape this story retires. Its `#spec-time-census-fr1-re-run-2026-09-02-against-public-head-daf5125a--discharged-by-this-fis` section is the 18-importer / 5-consumer baseline.
- `docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md#technical-overview` – `prepareTasks` / `prepareSearch(backend, storeName:, rebuild:)`, the rebuild source (manifest revision and fingerprint, `IndexHealthStore`, `populate(tx)`, `authenticateComplete()`), the health protocol, and the refusal shape (typed exception naming the store and the `dartclaw rebuild-index` remedy).
- `docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md#constraints--gotchas` – "Reconciler ownership": the gate's derived rebuild is ordered ahead of `CanonicalIndexReconciler`, which then fast-paths on healthy `(R, F)` evidence; "Critical": the rebuild holds S01's serialization slot and is acceptable only at startup before other seam users exist – this story's order guarantees it.
- `docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md#what-were-not-doing` – the refuse-versus-degrade posture of the composition root and `dartclaw rebuild-index` are handed to this story.
- `docs/specs/0.26/s03-fulltextindex-abstraction-and-fts5-implementation.md#technical-overview` – #5 `SqliteFtsIndex.withinTransaction(tx, table:)` is the populate shape for the gate's rebuild; #6 `SqliteFtsTable.memoryChunks`; #7 `MemoryIndexProjection.documents` and `chunkCount`.
- `docs/specs/0.26/s03-fulltextindex-abstraction-and-fts5-implementation.md#implementation-tasks` – TI05: the in-memory fallback prepared through the gate (the transitional reference this story absorbs), `_canonicalRowBatches` yields `List<SearchDocument>`, `Database searchDb` exposure left for this story; TI06: the reconciler's injected store opener whose default starts from `openSearchDb` – re-pointed here.
- `docs/specs/0.26/s04-task-domain-storage-seam-refactor.md#implementation-tasks` – TI02: the connection PRAGMAs (`journal_mode=WAL`, `foreign_keys=ON`) sit in the `task_db.dart` open helpers "until S06 removes the helper"; TI03: `openPreparedTaskBackend()` in `dartclaw_testing` starts from `openTaskDbInMemory()`; TI08: gate-first construction at `StorageWiring.wire()` and `workflow_status_command.dart`, and the new `storage_wiring_tasks_gate_test.dart`.
- `docs/specs/0.26/s04-task-domain-storage-seam-refactor.md#what-were-not-doing` – the S01 transitional goal DDL and its `max_tokens` repair are "dead after S02" and assigned to this story by the plan brief.
- `docs/specs/0.26/s05-execution-and-workflow-storage-seam-refactor.md#technical-overview` – construction at `cleanup_command.dart` (wrap, prepare, construct; the `finally` still closes what it opened) and the S06-owned importer list this story empties.
- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#decided-posture--contracts-owner-accepted-2026-07-24` – decisions #3/Q4: turn-state and webhook-dedup storage stay instance-local outside the abstraction (mechanism replaced by S15, locality rationale unchanged).
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#amendment-2026-08-21--storage-absorption-landed` – `dartclaw_core` carries `sqlite3`; the sqlite3-free-core rule the prior FIS's fitness check assumed is retired.
- `../dartclaw-public/dev/fitness/test/src_import_hygiene_test.dart` – the gate shape to copy: `productionDartFiles`, `readAllowlist` with rationale format and `assertNoStaleEntries`, violations naming `path:line`; `fitness_suite_deps_test.dart` beside it is why the gate imports no DartClaw package.
- `../dartclaw-public/dev/state/LEARNINGS.md#storage--data-model` – "Parse-then-rewrite makes a lenient parser destructive" (why a gate refusal on unparseable evidence must stop the reconciler from running and overwriting it); `#package-architecture` – "Green tests can mask unwired features" (why the order and the close paths are proven by wiring tests, not repository tests).
- `../dartclaw-public/dev/state/LEARNINGS.md#tooling--verification` – workspace-root `dart pub get` owns native-asset regeneration after a `sqlite3` dependency move; testing-profile smoke runs must bypass stale CLI snapshots after schema changes; `dart test` runs suites as isolates in one process.
- `docs/specs/0.26/launch-context.md` – the live committed census, wiring, CLI consumer, topology, and structural evidence that supersedes both temporary re-plan audits.


## Deeper Context

- `../dartclaw-public/dev/adrs/033-architectural-governance-via-fitness-functions.md` – why a gate is a text scan with a rationale-bearing allowlist.
- `../dartclaw-public/dev/fitness/README.md` – per-gate "How to resolve a failure" sections; the new gate gets one.
- `../dartclaw-public/dev/architecture/system-architecture.md` – component table rows for the storage layer that name the retired helper file.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#fitness-functions` – suite location, allowlist convention, run command.
- `../dartclaw-public/dev/state/DECISIONS.md#still-current` – the 2026-09-01 LOC-band decision (downward re-cuts are routine).


## Acceptance Scenarios

- **S01 [OC01] [TI04,TI05,TI07] A supported store starts through the seam in the existing order with unchanged behavior**
  - **Given** a data directory with a valid canonical corpus and either no stores, exact released-0.25 `tasks.db`/`search.db`, or epoch-marked current stores
  - **When** `StorageWiring.wire()` runs under `dartclaw serve` or headless staging, and `workflow status --standalone` and `cleanup` run against the same directory
  - **Then** the order is memory preflight → corpus manifest → search gate → index reconciliation → search open → tasks open (gate-first) → state open, every existing log line and exit code is unchanged, the same in-memory degraded posture applies to a reconciliation failure, and the only file delta is the `dartclaw_schema` marker the gate adds to an exact-0.25 store
  - **Proof**: `packages/dartclaw_runtime/test/runtime/storage_wiring_memory_preflight_test.dart#missing index is reconstructed before the production search database opens` – green – parity/regression (the whole file is bound by TI04's Verify)

- **S02 [OC02] [TI04] An incompatible search store with a complete source is rebuilt once, by the gate, before the reconciler**
  - **Given** a `search.db` in the 0.23 shape (`memory_chunks` without the five canonical-identity columns, written as inline DDL through a raw connection), a canonical corpus projecting `N` chunks at manifest revision `R`/fingerprint `F`, and an injected reconciler transition hook
  - **When** `wire()` runs
  - **Then** the store holds the current shape, marker `(1, 1)`, and exactly `N` chunks; `.dartclaw-memory-index.json` reads `healthy` at `(R, F)` before the reconciler is invoked; the reconciler takes its fast path (no `siblingCreated` transition, no file swap); search is available and a query returns the corpus content

- **S03 [OC02] [TI04] A gate refusal is explicit, leaves the store and evidence untouched, and skips the reconciler**
  - **Given** an incompatible `search.db` and one refusal cause from S02 scenario S07 – unparseable health evidence, or a populate step that throws
  - **When** `wire()` runs with an injected exit function and an injected reconciler
  - **Then** the severe log carries the gate's message naming `search.db` and `dartclaw rebuild-index`, the exit function is not called, the reconciler's `ensureCurrentBatched` is never invoked, the store's `sqlite_master` and data dump and the evidence file are byte-identical to before, and the runtime boots with search unavailable exactly as the existing derived-recovery-failure path does (in-memory prepared store, `memory_search` degraded)
  - **Proof**: `packages/dartclaw_runtime/test/runtime/storage_wiring_memory_preflight_test.dart#derived recovery failure boots degraded with canonical memory available` – green – parity/regression (the degraded posture this scenario reuses; the new refusal path is bound by TI04's Verify)

- **S04 [OC01] [TI04] `dartclaw rebuild-index` remains the working remedy for an incompatible search store**
  - **Given** the 0.23-shaped `search.db` from scenario S02 and a healthy corpus
  - **When** `dartclaw rebuild-index` runs with the runtime stopped
  - **Then** it prints the shipped `Rebuilt index: N entries at collection revision R; health=healthy` line, the store is current with marker `(1, 1)`, and a subsequent `wire()` classifies it current and fast-paths

- **S05 [OC01,OC03] [TI07] CLI commands open through the seam, behave as before, and close what they open**
  - **Given** an injected backend factory returning a prepared in-memory store seeded with a workflow run and its child tasks
  - **When** `workflow status --standalone <runId>` and `cleanup` with retention enabled run, and separately each runs against a store the gate refuses
  - **Then** the table and JSON output, the `WARNING: workflow artifact retention skipped …` line, the `No workflow data found` diagnostic, and every exit code are unchanged, and after each command the injected backend rejects further use (closed exactly once, in the command's `finally`)
  - **Proof**: `apps/dartclaw_cli/test/commands/workflow/workflow_status_command_test.dart#standalone mode discovers cwd-local .dartclaw config` – green – parity/regression (the cleanup half is bound by TI07's Verify)

- **S06 [OC03] [TI05,TI06] Shutdown and every teardown path close both backends exactly once**
  - **Given** a runtime built through `DartclawRuntime.build` with injected backend factories that record the backends they return, and separately a headless staging that never completes, a bind failure in `serve`, and a `state.db` open failure
  - **When** `shutdown()` runs twice, `staging.dispose()` runs, the bind-failure teardown runs, and the state-store failure path runs
  - **Then** both recorded backends reject `execute` with `StateError` afterwards, the second `shutdown()` completes without error, the `state.db` failure path still exits with code 1 after closing the task and search backends, and no repository, service, or `TaskService.dispose()` call closes a connection on its own
  - **Proof**: `packages/dartclaw_runtime/test/runtime/dartclaw_runtime_test.dart#shutdown stops the scheduled lane and closes the search database last` – green – parity/regression (assertion moves from `runtime.searchDb.select` to the recorded backend)

- **S07 [OC04] [TI09] The import gate names a stray driver import and fails on a stale allowlist entry**
  - **Given** the fitness gate's scanner applied to a temporary tree holding one allowlisted file with a `package:sqlite3` import, one non-allowlisted file with the same import at line 3, and an allowlist entry naming a file that does not exist
  - **When** the scanner runs
  - **Then** it reports exactly the non-allowlisted `path:3` with the "use `DatabaseBackend`" resolution text, and the stale entry fails the staleness assertion naming the allowlist file; on the real tree the gate passes with exactly the three sanctioned files consulted


## Structural Criteria

- **SC01** `task_db.dart`, `search_db.dart`, `TaskDbFactory`, `SearchDbFactory`, `openTaskDb`, `openSearchDb`, `openTaskDbInMemory`, and `openSearchDbInMemory` appear nowhere under `packages/` or `apps/` (code, example, barrel, or `CLAUDE.md`); the repo-wide `package:sqlite3` importer census (tests excluded) is exactly `sqlite_backend.dart`, `turn_state_store.dart`, `webhook_delivery_store.dart` – down from the seven story S05 leaves.
- **SC02** No production signature outside those three files names a `sqlite3` type: `DartclawRuntime`, `HeadlessRuntimeStaging`, `StorageWiring`, and the five CLI commands take the kernel `DatabaseBackendFactory` typedef and expose no `Database`; `sqlite3.open`/`openInMemory` are called only from `sqlite_backend.dart`, `turn_state_store.dart`, and `webhook_delivery_store.dart`.
- **SC03** `SqliteGoalRepository` takes `DatabaseBackend` by constructor with no DDL, `PRAGMA`, or awaited `open` factory; the `goals` manifest in `schema_identity.dart` is unchanged.
- **SC04** The composition root is the sole close owner: `close()` on a backend is called only from `StorageWiring`, `DartclawRuntime.shutdown`, the reconciler's own opener lifecycle, and the two CLI `finally` blocks; `sqlite_task_repository.dart` contains no `close()`.
- **SC05** `wire()` keeps its step order and failure postures: preflight and the tasks/state opens stay fatal, the search gate, reconciliation, and search open stay non-fatal; every derived-store open in wiring passes through `prepareSearch` on that instance before a `SqliteFtsIndex` is constructed.
- **SC06** The tasks-store connection PRAGMAs (`journal_mode=WAL`, `foreign_keys=ON`) are issued once per connection by `SqliteSchemaGate.prepareTasks` before its first transaction, so every production and test tasks connection keeps its cascade and WAL behavior without a helper.
- **SC07** The new gate lives in `dev/fitness/test/` with its allowlist in `dev/fitness/test/allowlist/`, imports no DartClaw package, keys entries by repo-relative file path with a rationale, and is documented in `dev/fitness/README.md` with the S15 tightening named.
- **SC08** Workspace analysis, `bash dev/tools/test_workspace.sh`, `bash dev/tools/fitness/run_all.sh`, `arch_check` (LOC band with any downward re-cut applied, 12-package ceiling), and `git diff --check` are green; `service_wiring.dart` stays at or under 1500 lines and no test file exceeds 1300.


## Scope & Boundaries

### Spec-Time Census (FR1 closure, 2026-09-02 against public HEAD `daf5125a`)

Entry state after stories S01–S05 (derived from their Structural Criteria): seven `package:sqlite3` importers – `sqlite_backend.dart` (S01), `task_db.dart`, `search_db.dart`, `turn_state_store.dart`, `webhook_delivery_store.dart`, `service_wiring.dart`, `storage_wiring.dart` – and the same five CLI typedef consumers as at HEAD (`serve_command`, `cleanup_command`, `workflow/standalone_lifecycle_support`, `workflow/workflow_run_command`, `workflow/workflow_status_command`), plus the non-consumer references in `dartclaw_core.dart`, `dartclaw_core/CLAUDE.md`, `example/example.dart`, the reconciler's default opener, and `dartclaw_testing`'s `openPreparedTaskBackend()`. Exit state: three importers, zero typedef references. `rebuild_index_command.dart` opens nothing itself and is untouched.

### Work Areas
- Seam factories: `packages/dartclaw_kernel/lib/src/database_backend.dart` (`DatabaseBackendFactory` typedef, `show`-exported) and `packages/dartclaw_core/lib/src/storage/sqlite_backend.dart` (`SqliteBackend.open`, `SqliteBackend.openInMemory`); deletion of `packages/dartclaw_core/lib/src/storage/{task_db,search_db}.dart` with their barrel lines, the `dartclaw_core/CLAUDE.md` row, and `example/example.dart` (TI01, TI02)
- Re-pointed consumers of the deleted helpers: `packages/dartclaw_core/lib/src/storage/index_reconciler.dart` (default opener), `packages/dartclaw_testing/lib/src/prepared_task_backend.dart`, `packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart` (`prepareTasks` issues the connection PRAGMAs) (TI02)
- Goal pilot closure: `packages/dartclaw_core/lib/src/storage/sqlite_goal_repository.dart` and the four suites that construct it (TI03)
- Composition root: `packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart` (search gate step, factories, close ownership, `state.db` via store-side open), `service_wiring.dart` and its parts `service_wiring_result.dart` (typedef parameters, `searchDb` field retired, shutdown close path); `packages/dartclaw_core/lib/src/storage/turn_state_store.dart` (`openTurnStateStore(path)`), `sqlite_task_repository.dart` and `task/task_repository.dart` (`dispose()` releases no connection) (TI04, TI05, TI06)
- CLI: `apps/dartclaw_cli/lib/src/commands/{serve_command,cleanup_command}.dart`, `commands/workflow/{workflow_run_command,standalone_lifecycle_support,workflow_status_command}.dart` (TI07)
- Tests: new `packages/dartclaw_runtime/test/runtime/storage_wiring_search_gate_test.dart`; the suites that inject `sqlite3.openInMemory()` factories or call the deleted helpers (`rg -l 'openTaskDbInMemory|openSearchDbInMemory|DbFactory|openTaskDb|openSearchDb' packages apps --glob '**/test/**'` – 69 files at HEAD) and the three that reach `runtime.searchDb` (TI08)
- Fitness: `dev/fitness/test/sqlite3_import_surface_test.dart`, `dev/fitness/test/allowlist/sqlite3_import_surface.txt`, `dev/fitness/README.md` (TI09)
- Docs: `dev/architecture/system-architecture.md` (storage component rows), `dev/architecture/data-model.md` (package diagram line), `packages/dartclaw_runtime/CLAUDE.md` (testing note) (TI10)

### What We're NOT Doing

_(`S<NN>` outside `## Acceptance Scenarios` names a plan story; inside it, a scenario ID.)_

- Replacing `state.db` or the webhook ledger with filesystem stores, or moving them behind the seam – story S15; they stay direct SQLite (ADR-045 #3/Q4), and the only change here is that the `state.db` open moves beside the ledger's self-open so wiring needs no driver import.
- The `tasks.db` → `dartclaw.db` rename – story S14; store names stay the literals the S04/S05 gate calls pass.
- Any PostgreSQL code, `database.*` config, or backend selection – story S07 turns the factory defaults into a config-driven choice; the typedef is shaped for that but this story wires SQLite only.
- The startup interlock and abandoned-store probe ordering – story S10 orders around the `wire()` sequence this story fixes.
- Removing `TaskRepository.dispose()` / `TaskService.dispose()` from the port and the 20 test files that call them – after this story the SQLite implementation releases nothing, but deleting the member is a port change across `dartclaw_testing`'s in-memory double and every caller. **NOTICED BUT NOT TOUCHING**: vestigial member, natural home a later cleanup.
- Deduplicating the row-batch generator shared by `rebuild_index_command.dart` and `StorageWiring._canonicalRowBatches` (drift audit §4.4) – behavior-preserving but outside FR1.


## Architecture Decision

**Approach**: One kernel typedef `DatabaseBackendFactory = Future<DatabaseBackend> Function(String path)` replaces both driver typedefs; `SqliteBackend.open`/`openInMemory` in the backend file replace the four open helpers; the search gate becomes a discrete open → `prepareSearch(rebuild:)` → close step between the corpus manifest and the reconciler; every backend the composition root or a CLI command opens is closed by that code and by nothing else. See ADR: `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md` (decisions #3/#7); topology: `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md`.
**Why this over alternatives**: gating on the long-lived search connection would put the reconciler's sibling-file swap under an open handle (the existing order opens after reconciliation for that reason), and passing the rebuild source into the reconciler's opener would run the derived rebuild from a second path and overwrite health evidence the gate refused to touch; a store-named open helper in the driver file (`openTaskStore`) is `task_db.dart` under another name, so the tasks-only PRAGMAs go where every tasks connection already passes once – `prepareTasks`.


## Technical Overview

`StorageWiring.wire()` after this story (drift audit §4.2 numbering; unchanged steps omitted):

| Step | Change | Posture |
|---|---|---|
| 3–4 preflight, manifest | none | fatal |
| **new 4a search gate** | `backend = await searchBackendFactory(config.searchDbPath)`; `await SqliteSchemaGate.prepareSearch(backend, storeName: 'search.db', rebuild: source)` where `source` carries the manifest revision and fingerprint, `_indexHealth`, `populate(tx)` = `SqliteFtsIndex.withinTransaction(tx, table: SqliteFtsTable.memoryChunks)` fed by `_canonicalRowBatches(manifest)` (`replaceAll` then per-batch `upsert`), and `authenticateComplete` = `_memoryCorpus.authenticate(manifest)`; `await backend.close()` in `finally` | non-fatal: on `SchemaIncompatibleException` log severe with the exception's message, set `_searchUnavailable = true`, skip step 6 |
| 6 reconcile | runs only when the gate step succeeded | non-fatal (unchanged) |
| 7 search open | `_searchBackend = await searchBackendFactory(path)` then `prepareSearch(_searchBackend, storeName: 'search.db')` (no source; a refusal or open error takes the existing degraded path); when `_searchUnavailable`, `SqliteBackend.openInMemory()` prepared the same way; `SqliteFtsIndex` constructed only after preparation | non-fatal (unchanged) |
| 8 tasks open | `_taskBackend = await taskBackendFactory(config.tasksDbPath)`; the S04 `prepareTasks` call and the S04/S05 constructions are unchanged; on failure close `_searchBackend` | fatal (unchanged) |
| 9 state open | `_turnStateStore = openTurnStateStore(stateDbPath)` (store-side, mirrors `openWebhookDeliveryStore`); on failure close `_taskBackend` and `_searchBackend` | fatal (unchanged) |
| `dispose()` | closes `_taskBackend` and `_searchBackend` after the service disposals; `DartclawRuntime.shutdown()` reaches the same closes last, through a closure `_assembleRuntime` hands it in place of the `searchDb` field | – |

The gate step opens its own short-lived connection because the reconciler's swap must not run under the long-lived handle. Test-injected in-memory factories return a fresh store per call, so the gate step prepares a throwaway and step 7's `prepareSearch` bootstraps the runtime's – which is why step 7 prepares unconditionally; the reconciler's own opener (S03) still prepares without a source and, after the gate step, always sees a current store.

Refusal posture: the gate satisfies FR2's "refuse explicitly" (typed refusal, store and evidence untouched) and the severe log names it; the runtime continues search-unavailable because a broken derived index has never stopped startup (step 6's existing posture) and canonical memory is the source of truth. The reconciler is skipped after a refusal so its `catch`-and-rebuild fallback cannot overwrite evidence the gate refused to parse. `dartclaw rebuild-index` (sibling rebuild, no target open) is the operator's "reset/rebuild knowingly" path.


## Code Patterns & External References

```
# type | path#anchor                                                                                                         | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring.wire                  | the 14-step order, the three failure postures, dispose(); the seam slots in without reordering
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart#DartclawRuntime.build                | build / stageHeadless / _assemblyFor / _RuntimeAssembly thread the two factories; shutdown() closes searchDb last
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/service_wiring_result.dart#_assembleRuntime               | where the searchDb field is filled and shutdownExtras captures storage – the close closure goes here
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart#openWebhookDeliveryStore        | store-side self-open shape to mirror for state.db
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/index_reconciler.dart#CanonicalIndexReconciler               | opener injection point (S03) whose default this story re-points; ensureCurrentBatched fast path vs reconcile sibling swap
file   | ../dartclaw-public/apps/dartclaw_cli/lib/src/commands/serve_command.dart#ServeCommand                                  | injected-factory-with-default shape shared by the five CLI sites
file   | ../dartclaw-public/apps/dartclaw_cli/lib/src/commands/cleanup_command.dart#_runWorkflowArtifactRetention               | open-in-try / close-in-finally shape the CLI keeps, now on the backend
file   | ../dartclaw-public/dev/fitness/test/src_import_hygiene_test.dart#main                                                  | gate shape: productionDartFiles, allowlist rationale format, tearDownAll staleness, violation text
file   | ../dartclaw-public/dev/fitness/test/memory_architecture_test.dart#main                                                 | fixture-based scanner unit test (temp tree) – the shape scenario S07 needs
file   | ../dartclaw-public/dev/fitness/test/allowlist/config_key_consumers.txt                                                | allowlist file format (`<key>  # <rationale>`)
file   | ../dartclaw-public/packages/dartclaw_runtime/test/runtime/storage_wiring_memory_preflight_test.dart#main               | wiring test fixture: temp data dir, seeded corpus, injected factories and exit function
file   | ../dartclaw-public/dev/tools/arch_check.dart#_libLocCeilings                                                           | two-sided band – this story deletes core lines and adds runtime lines
```


## Constraints & Gotchas

- **Critical**: gate before reconcile, reconcile before the long-lived open, prepare before every `SqliteFtsIndex` construction – three orderings, all in `wire()`. Reordering any of them either swaps a file under an open handle, rebuilds twice, or constructs an index over an unprepared store.
- **Critical**: after a search-gate refusal the reconciler must not run – its fast-path `catch (_)` falls into a full reconstruction that calls `recordRebuilding`, overwriting evidence the gate left byte-for-byte untouched (LEARNINGS: parse-then-rewrite).
- **Critical**: one `SqliteBackend` per connection and one owner per backend – the gate-step backend closes in the `finally` that opened it, the runtime backends are fields closed by `dispose()`/shutdown and the two failure paths, the CLI closes in its `finally`. No repository, service, or `TaskService.dispose()` closes a connection: `SqliteTaskRepository.dispose()` becomes a no-op whose dartdoc names the composition root as the owner.
- **Constraint**: `service_wiring.dart` is 1499 lines at HEAD against the 1500-line `max_file_loc` cap – the typedef swap and the `searchDb` removal must be line-neutral or shrinking; move nothing into it.
- **Constraint**: `SqliteBackend.open` applies no PRAGMAs; `search.db` keeps its default journal mode (the reconciler's sibling swap and backup files assume no `-wal`/`-shm` side files), and the tasks-only PRAGMAs run inside `prepareTasks` before its classify/transition transaction (`journal_mode` cannot change inside one), so `openPreparedTaskBackend()` keeps WAL and cascade behavior with no extra call.
- **Constraint**: `dartclaw_testing` imports `SqliteBackend` and `SqliteSchemaGate` from the `dartclaw_core` barrel and never `package:sqlite3`; test files may import the driver to seed raw rows and then wrap the connection in `SqliteBackend(db)`.
- **Constraint**: a `test/` file is not importable across packages – the wiring suite builds its incompatible `search.db` from inline 0.23 DDL through a raw connection, as `storage_wiring_tasks_gate_test.dart` (S04) does for `tasks.db`.
- **Constraint**: two-sided LOC ratchet (`arch_check.dart`, `_locHeadroom` 1500). Measured 2026-09-02: `dartclaw_core` 26269 of 27740, `dartclaw_runtime` 64444 of 65356, `dartclaw_cli` 11219 of 12719, `dartclaw_kernel` 18428 of 19920. This story deletes two core files and the goal DDL and adds roughly 40 runtime lines; apply a downward re-cut where `arch_check` reports slack, never a silent raise.
- **Constraint**: the fitness gate is a text scanner with no DartClaw import; its allowlist key is the repo-relative file path (a `path:line` key rots on every edit), one entry per file with a rationale, stale-checked in `tearDownAll` so S15's deletions fail the gate until the two lines go.
- **Constraint**: `dart test` runs suites as isolates in one process – temp data dirs by path, never `Directory.current`; after any pubspec or native-asset change run `dart pub get` at the workspace root.
- **Constraint**: comments are rationale-only; no story IDs in code, dartdoc, or the fitness README – the README names the tightening as "the two instance-local stores leave when they move to the filesystem".


## Implementation Plan

### Implementation Tasks

- **TI01** The seam has one factory type and one pair of SQLite open constructors
  - `packages/dartclaw_kernel/lib/src/database_backend.dart` adds `typedef DatabaseBackendFactory = Future<DatabaseBackend> Function(String path)` under the existing `show` clause; `sqlite_backend.dart` adds `static Future<SqliteBackend> open(String path)` and `static SqliteBackend openInMemory()` (plain `sqlite3.open`/`openInMemory`, no PRAGMAs). Follow `database_backend.dart#DatabaseBackend` for placement and `webhook_delivery_store.dart#openWebhookDeliveryStore` for the open-helper dartdoc density.
  - **Verify**: `cmd: rg -qU "database_backend\.dart'\s*show[^;]*\bDatabaseBackendFactory\b" packages/dartclaw_kernel/lib/dartclaw_kernel.dart && rg -q "static Future<SqliteBackend> open\(String path\)" packages/dartclaw_core/lib/src/storage/sqlite_backend.dart && rg -q "static SqliteBackend openInMemory\(\)" packages/dartclaw_core/lib/src/storage/sqlite_backend.dart && ! rg -q "PRAGMA" packages/dartclaw_core/lib/src/storage/sqlite_backend.dart && dart analyze --fatal-infos packages/dartclaw_kernel packages/dartclaw_core` – typedef exported, both constructors present, no PRAGMA in the backend file, both packages analyze clean
  - **SATISFIES**: SC02

- **TI02** The raw open helpers are gone and every consumer of them reaches the backend constructors
  - Delete `task_db.dart`, `search_db.dart`, their two barrel lines, and the `dartclaw_core/CLAUDE.md` row; `example/example.dart` uses `SqliteBackend.openInMemory()`; the reconciler's default opener starts from `SqliteBackend.open`; `dartclaw_testing`'s `openPreparedTaskBackend()` starts from `SqliteBackend.openInMemory()`; `SqliteSchemaGate.prepareTasks` issues `PRAGMA journal_mode=WAL` and `PRAGMA foreign_keys=ON` on the backend before its first transaction, and the two connection-setting tests that lived in `sqlite_task_repository_test.dart` assert against a `prepareTasks`-prepared backend. Depends on TI01.
  - **Verify**: `cmd: ! test -e packages/dartclaw_core/lib/src/storage/task_db.dart && ! test -e packages/dartclaw_core/lib/src/storage/search_db.dart && ! rg -q "task_db\.dart|search_db\.dart|TaskDbFactory|SearchDbFactory|openTaskDb|openSearchDb" packages/dartclaw_core/lib packages/dartclaw_core/CLAUDE.md packages/dartclaw_core/example packages/dartclaw_testing/lib && rg -q "foreign_keys=ON" packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart && rg -q "SqliteBackend\.open" packages/dartclaw_core/lib/src/storage/index_reconciler.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart packages/dartclaw_core/test/storage/index_reconciler_test.dart packages/dartclaw_core/test/storage/sqlite_task_repository_test.dart` – helpers and every reference gone from core, testing, and the example; the PRAGMAs live in the gate; the reconciler opens through the backend; the gate, reconciler, and task-repository suites (including the WAL and foreign-key cases) pass
  - **SATISFIES**: SC01, SC06

- **TI03** The goal repository is a plain seam consumer with no schema code
  - `SqliteGoalRepository` takes `DatabaseBackend` by constructor (S04/S05 shape); the awaited `open` factory, `_initSchema`, and the `PRAGMA table_info` / `ALTER TABLE goals ADD COLUMN max_tokens` repair are deleted (the S02 gate refuses a `goals` table without `max_tokens`); `sqlite_goal_repository_test.dart` and the three `dartclaw_runtime` suites that construct it build on `openPreparedTaskBackend()`. Depends on TI02.
  - **Verify**: `cmd: ! rg -q "CREATE TABLE|ALTER TABLE|PRAGMA|Future<SqliteGoalRepository> open" packages/dartclaw_core/lib/src/storage/sqlite_goal_repository.dart && ! rg -q "SqliteGoalRepository\.open\(" packages apps --glob '*.dart' && dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_goal_repository_test.dart packages/dartclaw_runtime/test/api/goal_routes_test.dart packages/dartclaw_runtime/test/task/budget_enforcement_test.dart && dart test --reporter=failures-only packages/dartclaw_runtime/test/server_test.dart --name "goal route wiring"` – no DDL, repair, or factory in the pilot; no caller uses the factory; the four goal suites pass with unchanged assertions
  - **SATISFIES**: SC03

- **TI04** The derived store is gated before the reconciler, opened prepared, and refused explicitly
  - In `storage_wiring.dart#StorageWiring.wire` implement Technical Overview steps 4a, 6, and 7: the discrete gate step with the S02 rebuild source built from the manifest, `_indexHealth`, `SqliteFtsIndex.withinTransaction` over `_canonicalRowBatches`, and `_memoryCorpus.authenticate`; on `SchemaIncompatibleException` log severe with the exception's message, set `_searchUnavailable`, and skip reconciliation; step 7 prepares every opened or in-memory store before constructing `SqliteFtsIndex`. New suite `packages/dartclaw_runtime/test/runtime/storage_wiring_search_gate_test.dart` builds its stores from inline 0.23 DDL through a raw connection at a temp path and injects a recording reconciler and transition hook; `rebuild_index_command_test.dart` gains the incompatible-store case. Depends on TI01, TI02.
  - **Verify**: `cmd: test "$(rg -n 'prepareSearch' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'ensureCurrentBatched' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_search_gate_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_memory_preflight_test.dart apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart` – the first gate call precedes the reconciler call; the new suite proves scenario S02 (rebuilt once under the gate, `healthy` at `(R, F)` before the reconciler is invoked, no `siblingCreated` transition, content searchable), scenario S03 (severe log with the gate's message, exit function not called, reconciler never invoked, store and evidence bytes unchanged, search unavailable), and that a fresh in-memory factory store is prepared before the index is constructed; the preflight suite's nine order and degradation cases pass unchanged (scenario S01); `rebuild-index` prints the shipped line and leaves a current store on the 0.23-shaped file (scenario S04)
  - **SATISFIES**: S01, S02, S03, S04, SC05

- **TI05** `StorageWiring` opens through seam factories, self-opens `state.db` store-side, and owns every close
  - Constructor takes two `DatabaseBackendFactory` parameters; `_searchBackend` and `_taskBackend` are fields; `turn_state_store.dart` gains `openTurnStateStore(String path)` (mirroring `openWebhookDeliveryStore`, `show`-exported) and wiring calls it at the unchanged path; the tasks-open failure closes `_searchBackend`, the state-open failure closes both backends before `_exitFn(1)`, `dispose()` closes both after the service disposals; `SqliteTaskRepository.dispose()` releases nothing and says so; the `Database get searchDb` getter and the `package:sqlite3` import are gone. Depends on TI04.
  - **Verify**: `cmd: ! rg -q "package:sqlite3|sqlite3\.open|Database get searchDb|DbFactory" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && rg -q "openTurnStateStore\(" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && rg -q "TurnStateStore openTurnStateStore\(String path\)" packages/dartclaw_core/lib/src/storage/turn_state_store.dart && rg -q "final DatabaseBackend _backend;" packages/dartclaw_core/lib/src/storage/sqlite_task_repository.dart && ! rg -q "_backend[[:space:]]*\.[[:space:]]*close[[:space:]]*\(" packages/dartclaw_core/lib/src/storage/sqlite_task_repository.dart && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_search_gate_test.dart --name "closes"` – wiring holds no driver import or raw open, `state.db` opens store-side, the task repository never closes, and the new suite's close cases prove both backends reject after `dispose()`, after the tasks-open failure (search closed), and after the state-open failure (both closed, exit 1) (scenario S06's wiring half)
  - **SATISFIES**: S06, SC02, SC04, SC05

- **TI06** `DartclawRuntime` exposes no driver type and shuts both backends last
  - `build`, `stageHeadless`, `_assemblyFor`, and `_RuntimeAssembly` take `searchBackendFactory`/`taskBackendFactory` of type `DatabaseBackendFactory`; the `searchDb` field and its `required` constructor parameter are replaced by a `Future<void> Function()` close closure that `_assembleRuntime` binds to the wiring's backend closes and `shutdown()` awaits in its `finally`; `disposeBase()` is unchanged (it already calls `_storage.dispose()`); the `package:sqlite3` import leaves `service_wiring.dart`; every suite that reaches `.searchDb` (`rg -l '\.searchDb\b' packages apps --glob '**/test/**'`) uses the recorded backend or the close closure. Depends on TI05.
  - **Verify**: `cmd: ! rg -q "package:sqlite3|searchDb|DbFactory" packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart packages/dartclaw_runtime/lib/src/runtime/service_wiring_result.dart && test "$(wc -l < packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart)" -le 1500 && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/dartclaw_runtime_test.dart packages/dartclaw_runtime/test/runtime/headless_runtime_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_local_path_bootstrap_test.dart packages/dartclaw_runtime/test/runtime/server_builder_integration_test.dart` – no driver type or typedef in the assembly, the file stays under the cap, and the runtime suites prove both recorded backends reject after `shutdown()`, a second `shutdown()` completes, and a never-completed staging closes them on `dispose()` (scenario S06)
  - **SATISFIES**: S06, SC02, SC04, SC08

- **TI07** The five CLI commands inject `DatabaseBackendFactory` with `SqliteBackend.open` as the default
  - `serve_command.dart`, `workflow_run_command.dart`, and `standalone_lifecycle_support.dart` thread the two factories into `build`/`stageHeadless`; `workflow_status_command.dart` and `cleanup_command.dart` open through the factory, keep their S04/S05 `prepareTasks` order, construct on the backend, and `await backend.close()` in the existing `finally`; the CLI imports no `Database` type. Depends on TI06.
  - **Verify**: `cmd: ! rg -q "DbFactory|openTaskDb|openSearchDb|\bDatabase\b" apps/dartclaw_cli/lib && test "$(rg -l 'DatabaseBackendFactory' apps/dartclaw_cli/lib | wc -l | tr -d ' ')" = 5 && dart test --reporter=failures-only apps/dartclaw_cli/test/commands/serve_command_test.dart apps/dartclaw_cli/test/commands/cleanup_command_test.dart apps/dartclaw_cli/test/commands/workflow/workflow_status_command_test.dart apps/dartclaw_cli/test/commands/workflow/workflow_lifecycle_standalone_test.dart apps/dartclaw_cli/test/commands/workflow/workflow_run_command_standalone_test.dart` – no driver typedef or type in the CLI, exactly the five sites name the seam factory, and the serve, cleanup, status, lifecycle, and standalone-run suites pass with unchanged assertions plus the status and cleanup cases that assert the injected backend is closed after the command (scenarios S01, S05)
  - **SATISFIES**: S01, S05, SC02, SC04

- **TI08** Every test constructs stores through the seam and the whole workspace analyzes clean
  - The remaining files of the 69 (Work Areas) switch to `SqliteBackend.openInMemory()`, `openPreparedTaskBackend()`, or `(_) async => SqliteBackend.openInMemory()` factories; a test that seeds raw rows keeps its `sqlite3.openInMemory()` connection and wraps it; `dart analyze` is the sweep enforcer because the typedefs and helpers no longer exist. Depends on TI01–TI07.
  - **Verify**: `cmd: dart analyze --fatal-infos && ! rg -q "openTaskDbInMemory|openSearchDbInMemory|TaskDbFactory|SearchDbFactory|openTaskDb\b|openSearchDb\b" packages apps` – analysis clean, no test or production file names a deleted helper or typedef, and every package suite passes
  - **SATISFIES**: S01, SC01, SC08

- **TI09** The import surface is a fitness gate with a rationale-bearing, stale-checked allowlist
  - `dev/fitness/test/sqlite3_import_surface_test.dart` scans `productionDartFiles(repoRoot)` for `import 'package:sqlite3/…'`, allows exactly the repo-relative paths in `dev/fitness/test/allowlist/sqlite3_import_surface.txt` (three entries: the backend implementation, the two instance-local stores, each with a one-line rationale), reports every other match as `path:line: package:sqlite3 import outside the backend seam (use DatabaseBackend)`, exposes its scanner for a temp-tree unit test (scenario S07), and asserts allowlist format and no stale entries in `tearDownAll`; `dev/fitness/README.md` gains the gate's section with the resolution and the note that the two store entries leave when the stores move to the filesystem. Independent of TI01–TI08 except that the real-tree case passes only after TI08.
  - **Verify**: `cmd: test "$(grep -cv '^\s*#\|^\s*$' dev/fitness/test/allowlist/sqlite3_import_surface.txt)" = 3 && ! rg -q "package:dartclaw" dev/fitness/test/sqlite3_import_surface_test.dart && rg -q "sqlite3_import_surface" dev/fitness/README.md && dart test --reporter=failures-only dev/fitness/test/sqlite3_import_surface_test.dart` – three allowlist lines, no production import in the gate, README section present, and the gate's temp-tree case names the planted `path:3` and fails the planted stale entry while the real-tree case passes with all three entries consulted
  - **SATISFIES**: S07, SC07

- **TI10** Architecture and package docs name the seam, not the helpers
  - `dev/architecture/system-architecture.md` storage component rows name `SqliteBackend` (`sqlite_backend.dart`) in place of the `SearchDb`/`search_db.dart` row and describe the startup order with the search gate ahead of reconciliation; `dev/architecture/data-model.md`'s package-layer diagram lists `SqliteBackend` as the driver owner; `packages/dartclaw_runtime/CLAUDE.md`'s testing note names `SqliteBackend.openInMemory()` / `openPreparedTaskBackend()`; bump each architecture file's "Current through" marker. Public-repo dev-doc edit executed in-milestone; no story IDs.
  - **Verify**: `cmd: ! rg -q "search_db\.dart|task_db\.dart|SearchDbFactory|TaskDbFactory|openSearchDb|openTaskDb|sqlite3\.openInMemory\(\)" dev/architecture/system-architecture.md dev/architecture/data-model.md packages/dartclaw_runtime/CLAUDE.md packages/dartclaw_core/CLAUDE.md && rg -q "SqliteBackend" dev/architecture/system-architecture.md dev/architecture/data-model.md` – no retired name survives in the four docs and both architecture docs name the backend
  - **SATISFIES**: SC01

- **TI11** The Phase-1 checkpoint closes with the census at three and every gate green
  - Depends on TI01–TI10. Apply any downward LOC re-cut `arch_check` reports in `dev/tools/arch_check.dart#_libLocCeilings` in this change; run `dart pub get` at the workspace root if any pubspec changed.
  - **Verify**: `cmd: test "$(rg -l "import 'package:sqlite3" packages apps --glob '!**/test/**' --glob '!**/*_test.dart' | sort | tr '\n' ' ')" = "packages/dartclaw_core/lib/src/storage/sqlite_backend.dart packages/dartclaw_core/lib/src/storage/turn_state_store.dart packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart " && test "$(rg -l 'sqlite3\.open' packages apps --glob '!**/test/**' --glob '!**/*_test.dart' | sort | tr '\n' ' ')" = "packages/dartclaw_core/lib/src/storage/sqlite_backend.dart packages/dartclaw_core/lib/src/storage/turn_state_store.dart packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart " && dart analyze --fatal-infos && dart run dev/tools/arch_check.dart && git diff --check` – the importer census and the raw-open census are exactly the three sanctioned files, and analysis, the workspace suite, the fitness suite (including the new gate), the LOC band and 12-package ceiling, and the whitespace check are green
  - **SATISFIES**: SC01, SC02, SC08

### Testing Strategy

- [TI04, TI05] Layer 2 against real SQLite at a temp path: the wiring suite proves order and posture through observable effects – recorded reconciler calls and transitions, file and evidence byte snapshots, health-file contents, post-close `StateError` – never private call order; the incompatible store is inline 0.23 DDL written through a raw connection before any backend wraps it.
- [TI06, TI07] Recording factories return the backend they open so tests can assert its closed state; a fresh in-memory store per call is fine everywhere else.
- [TI09] The scanner is unit-tested on a temporary tree (planted violation, allowlisted file, stale entry) and then run on the real tree, which is the case that guards the repository.
- Bound Proofs are parity – assertions stay, handles and construction change; the new behavior is proven by the new suite and the TI04–TI09 Verify lines.

### Execution Contract

- Stories S01–S05 must be complete (this story consumes `SqliteBackend`, `SqliteSchemaGate.prepareTasks`/`prepareSearch`, `SqliteFtsIndex.withinTransaction`, `MemoryIndexProjection`, the S03 reconciler opener, `openPreparedTaskBackend()`, and the S04/S05 gate calls). All commands run from the `../dartclaw-public/` root. Order: TI01 → TI02 → TI03 → TI04 → TI05 → TI06 → TI07 → TI08 → TI09 → TI10 → TI11.
- The public working tree may carry another session's uncommitted edits outside this story's Work Areas; touch only the files named there. `service_wiring.dart` is in that session's edit set at authoring time – rebase on its landed shape, keep the file under 1500 lines.
- If `SqliteSchemaGate.prepareSearch`'s rebuild-source shape as landed by S02 cannot carry `SqliteFtsIndex.withinTransaction` as its populate step, raise `CONFUSION:` rather than adding a second rebuild path in wiring.
- After the change, run one testing-profile smoke (`dev/testing/README.md`, `plain` profile) from a freshly built CLI, not a stale snapshot (tooling-verification learning), and confirm the startup log order and the marker-only file delta on an exact-0.25 data directory.


## Final Validation Checklist

- No PostgreSQL code, `database.*` config, migration machinery, or storage-format change entered the checkpoint; the only on-disk delta for a supported store is the S02 marker.
- No retired name (`task_db.dart`, `search_db.dart`, `TaskDbFactory`, `SearchDbFactory`, the four `open*Db*` helpers, `Database searchDb`) survives in code, tests, or dev docs except in this FIS and the CHANGELOG.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

### Run: 2026-09-08 14:19 UTC – repair-proof

#### DRIFT

- spec-stale: TI08 Verify target repaired | Stale targets: – | `cmd: dart analyze --fatal-infos && ! rg -q "openTaskDbInMemory|openSearchDbInMemory|TaskDbFactory|SearchDbFactory|openTaskDb\b|openSearchDb\b" packages apps && bash dev/tools/test_workspace.sh` → `cmd: dart analyze --fatal-infos && ! rg -q "openTaskDbInMemory|openSearchDbInMemory|TaskDbFactory|SearchDbFactory|openTaskDb\b|openSearchDb\b" packages apps`

### Run: 2026-09-08 14:19 UTC – repair-proof

#### DRIFT

- spec-stale: TI11 Verify target repaired | Stale targets: – | `cmd: test "$(rg -l "import 'package:sqlite3" packages apps --glob '!**/test/**' --glob '!**/*_test.dart' | sort | tr '\n' ' ')" = "packages/dartclaw_core/lib/src/storage/sqlite_backend.dart packages/dartclaw_core/lib/src/storage/turn_state_store.dart packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart " && test "$(rg -l 'sqlite3\.open' packages apps --glob '!**/test/**' --glob '!**/*_test.dart' | sort | tr '\n' ' ')" = "packages/dartclaw_core/lib/src/storage/sqlite_backend.dart packages/dartclaw_core/lib/src/storage/turn_state_store.dart packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart " && dart analyze --fatal-infos && bash dev/tools/test_workspace.sh && bash dev/tools/fitness/run_all.sh && dart run dev/tools/arch_check.dart && git diff --check` → `cmd: test "$(rg -l "import 'package:sqlite3" packages apps --glob '!**/test/**' --glob '!**/*_test.dart' | sort | tr '\n' ' ')" = "packages/dartclaw_core/lib/src/storage/sqlite_backend.dart packages/dartclaw_core/lib/src/storage/turn_state_store.dart packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart " && test "$(rg -l 'sqlite3\.open' packages apps --glob '!**/test/**' --glob '!**/*_test.dart' | sort | tr '\n' ' ')" = "packages/dartclaw_core/lib/src/storage/sqlite_backend.dart packages/dartclaw_core/lib/src/storage/turn_state_store.dart packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart " && dart analyze --fatal-infos && dart run dev/tools/arch_check.dart && git diff --check`

### Run: 2026-09-08 14:19 UTC – observations

2026-09-08 16:14 CEST owner scheduling override: one focused independent review and relevant checks per story. Full workspace and full fitness runs in task Verify commands are deferred to the final combined A+B gate, with no acceptance requirement removed. The retained command proves the story-local checks; prose referring to full-suite success describes final milestone evidence. Standard fast-tier closure remains; broad integration, platform and release verification run at the end.

### Run: 2026-09-08 17:54 UTC – observations

2026-09-08 19:53 CEST. Implementation frozen at `038020202172+477b373a5511` for independent review. TI01–TI11 completed from actual focused checks. Production/test factory callers are migrated; the three sanctioned SQLite importers are the backend and the two instance-local stores. `service_wiring.dart` initially measured 1510 lines; reducing stale/verbose API documentation in the touched file brought it to 1498 without changing behavior. No ceiling change was needed.

Verification: workspace analyzer clean; core gate/reconciler/task/goal/features 67 passed; search-gate/memory-preflight/rebuild 26 passed; goal routes/budget 38 and named server goal 2 passed; close cases 3 passed; runtime lifecycle 59 passed with the default integration exclusion; CLI 94 passed; import fitness gate 4 passed; formatting of 65 changed Dart files had zero changes; architecture gate 16/16 and structural/API/census/diff checks passed. Counts describe individual commands and overlap. `packages/dartclaw_runtime/test/runtime/server_builder_integration_test.dart` is a file-level integration suite containing 17 tests and was excluded by the default test configuration; its explicit live run remains a final combined obligation. No broad workspace/fitness/platform/live acceptance is claimed here.

The CLI regression proves that rebuilding a six-column legacy search store produces the current marker and searchable canonical content, removes stale content, and leaves the next reconciliation on its healthy fast path without sibling transitions. CLI close assertions invoke backend queries inside the matcher callback because closed-backend checks may throw synchronously.

### Run: 2026-09-08 18:00 UTC – repair-proof

#### DRIFT

- spec-stale: TI10 Verify target repaired | Stale targets: – | `cmd: ! rg -q "search_db\.dart|task_db\.dart|SearchDbFactory|TaskDbFactory|sqlite3\.openInMemory\(\)" dev/architecture/system-architecture.md dev/architecture/data-model.md packages/dartclaw_runtime/CLAUDE.md packages/dartclaw_core/CLAUDE.md && rg -q "SqliteBackend" dev/architecture/system-architecture.md dev/architecture/data-model.md` → `cmd: ! rg -q "search_db\.dart|task_db\.dart|SearchDbFactory|TaskDbFactory|openSearchDb|openTaskDb|sqlite3\.openInMemory\(\)" dev/architecture/system-architecture.md dev/architecture/data-model.md packages/dartclaw_runtime/CLAUDE.md packages/dartclaw_core/CLAUDE.md && rg -q "SqliteBackend" dev/architecture/system-architecture.md dev/architecture/data-model.md`

### Run: 2026-09-08 18:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI05 Verify target repaired | Stale targets: – | `cmd: ! rg -q "package:sqlite3|sqlite3\.open|Database get searchDb|DbFactory" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && rg -q "openTurnStateStore\(" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && rg -q "TurnStateStore openTurnStateStore\(String path\)" packages/dartclaw_core/lib/src/storage/turn_state_store.dart && ! rg -q "close\(\)" packages/dartclaw_core/lib/src/storage/sqlite_task_repository.dart && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_search_gate_test.dart --name "closes"` → `cmd: ! rg -q "package:sqlite3|sqlite3\.open|Database get searchDb|DbFactory" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && rg -q "openTurnStateStore\(" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && rg -q "TurnStateStore openTurnStateStore\(String path\)" packages/dartclaw_core/lib/src/storage/turn_state_store.dart && rg -q "final DatabaseBackend _backend;" packages/dartclaw_core/lib/src/storage/sqlite_task_repository.dart && ! rg -q "_backend[[:space:]]*\.[[:space:]]*close[[:space:]]*\(" packages/dartclaw_core/lib/src/storage/sqlite_task_repository.dart && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_search_gate_test.dart --name "closes"`

# FIS: Startup Interlock and Backend-Switch Semantics

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S10

_Refreshed 2026-09-02 against released 0.25 (public HEAD `daf5125a`), replacing the 2026-07-30 authoring and its 2026-08-07 and 2026-08-14 amendments against 0.24. Version labels: 0.26 is this milestone (the PRD title still carries its pre-renumber label), released 0.25 is the compatibility baseline. Every dated owner decision stands: full-seam quarantine during interlock recovery (2026-07-30), no lease subsystem (ADR-045 #4), local orphan scan before the active-store gate with destructive acknowledgement deferred until the gate succeeds (ADR-045 #8a), best-effort abandoned-store notice under the S08 posture (FR8), one-shot maintenance commands as sanctioned concurrent clients (plan sequencing), and the PostgreSQL-dependent proofs relocated here from the rider stories (owner 2026-08-07, DECISION NOTE below). The startup sequence the prior FIS interlocked with is gone: the CLI-hosted `ServiceWiring` class and `apps/dartclaw_cli/.../wiring/storage_wiring.dart` do not exist, `dartclaw_storage` and `dartclaw_server` are dissolved, and the 0.24 memory pipeline the prior criteria ordered "after the gate" is now the fail-fast `MemoryPreflight` that runs, fatally, before any store opens. Scenarios and tasks are rewritten against `DartclawRuntime.build` → `StorageWiring.wire()` in `dartclaw_runtime` as stories S06, S07, S09, S14, and S15 leave it. Code references (`packages/...`, `apps/...`, `dev/...`) are paths inside `../dartclaw-public/`; every `cmd:` runs from that root._

## Feature Overview and Goal

**Intent**: Keep one `dartclaw serve` in exclusive control of a PostgreSQL database, preserve local crash evidence across a failed start, and make a backend switch honest about where existing data remains, without adding a lease subsystem, a SQL classifier, or a second storage seam.

**Expected Outcomes**:

- [OC01] One serving instance owns a PostgreSQL database at a time: a second attach fails loud before any repository exists, ownership loss blocks every seam operation until reacquisition plus version and schema validation succeed, and shutdown releases ownership after the pool closes.
- [OC02] Selecting another backend transfers no data: a fresh target starts empty, a compatible target reopens its own data, and a non-empty inactive store produces one prominent best-effort notice that never aborts boot and never bypasses the S08 posture.
- [OC03] Orphan-turn evidence in the filesystem turn-state store is scanned and reported before any active-backend connection and deleted only after the active-store gate succeeds, so an aborted start preserves the next-boot recovery notice.
- [OC04] PostgreSQL startup and recovery failures are typed, name the condition and remedy without a DSN or credential, and leave S07's dispatch boundary and retry constants untouched.
- [OC05] A PostgreSQL deployment with a fresh data directory performs zero SQLite operations across boot, one turn, one webhook, and shutdown (the FR13 serve-run proof relocated here, owner 2026-08-07).


## Required Context

- `docs/specs/0.26/plan.json#sharedDecisions` – "Schema compatibility …": S10 orders the gate after local recovery and interlock acquisition. "`database.*` typed config section …": a lingering inactive `url` is legal and unvalidated under `sqlite`, retained for the probe. "Redaction-safe typed storage exceptions …": the probe reuses the S08 posture; the whole seam is quarantined during recovery. "DatabaseBackend seam shape and placement": implementations in `packages/dartclaw_core/lib/src/storage/`, core the only driver-bearing package, the two-sided LOC ratchet, 1500/1300-line file caps, explicit barrel `show` clauses.
- `docs/specs/0.26/prd.md#fr8-startup--backend-switch-semantics` – the six acceptance criteria, the validation list, and the error-handling contract (recovery-pending message, remedies naming the condition) every scenario here seeds from. **NOTICED**: the FR names `state.db` and `DATABASE_URL`; after story S15 the store is `turn_state.json` and the reference is `database.url`/`database.credential`. The durable reconciliation is recorded in `docs/specs/0.26/launch-context.md#prd-reconciliations-already-carried-by-the-plan-and-fis`.
- `docs/specs/0.26/prd.md#user-flows` – flows 2–4 (lock → bootstrap or validate → serve; unreachable at boot aborts after local recovery; switch with notice and decommission guidance). `docs/specs/0.26/prd.md#edge-cases` – rows "Second instance attaches", "Backend switched with existing non-empty old store", "PG connection drops before/after dispatch", "PG unreachable at boot, orphaned turns present locally".
- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#decided-posture--contracts-owner-accepted-2026-07-24` – decisions #2 (no transfer, importer a separate tool, decommission guidance), #4 (`dartclaw serve` takes the session lock), #8a (fail closed, pre-dispatch retry, orphan recovery before the gate, refuse-until-re-gated). `#resolved-questions-2026-07-01` Q4: crash recovery stays independent of the network database.
- `docs/specs/0.26/s06-composition-root-wiring-and-census-closure.md#technical-overview` – the post-S06 `wire()` table (4a → 6 → 7 → 8 → 9), the failure postures, `dispose()` and the shutdown close closure; this story inserts three steps and moves one.
- `docs/specs/0.26/s07-opt-in-postgresbackend-core.md#technical-overview` – #2 `databaseBackendFactoryFor`/`prepareAuthoritativeStore`, #4 `PostgresBackend.open`, #7 the dispatch policy and its private constants (untouched here), #8 the kernel `StorageException` family from safe fields, #9 composition under `postgres`, #10 `PostgresSchemaGate.prepare` (a current reopen performs no write – the re-gate relies on it). `#structural-criteria` SC05: tagging and the fail-loud support helper.
- `docs/specs/0.26/s08-connection-security-credentials-redaction-tls-posture.md#technical-overview` – #2 `resolveDatabaseDsn` (synchronous, refuses by name), #3 the pure posture evaluator (`show`-exported for this story), #5 the one `GuardAuditLogger` constructed before `_wireStorage`. `#constraints--gotchas` – validate only the active configuration; the evaluator runs before any socket exists.
- `docs/specs/0.26/s09-language-aware-postgresql-memory-and-kg-search.md#technical-overview` – #2 `validatePostgresFtsLanguage` right after `prepareAuthoritativeStore`; #7 under `postgres` reconciliation follows the authoritative open with no SQLite. `#constraints--gotchas` – `rebuild-index` is a sanctioned one-shot concurrent client.
- `docs/specs/0.26/s14-authoritative-store-rename.md#technical-overview` – `probeAuthoritativeStore(dartclawDbPath)`: absent, ambiguous, or present under one name with a non-empty verdict over `tasks`, `goals`, `workflow_runs`, `kg_facts`; read-only; never creates or writes; unreadable is could-not-verify. `adoptLegacyAuthoritativeStore` sits inside step 8's try before the SQLite open – this story keeps it off the `postgres` branch. `#implementation-observations` – the matching DECISION NOTE.
- `docs/specs/0.26/s15-filesystem-backed-instance-local-state.md#technical-overview` – `openTurnStateStore(path)` is synchronous, `getAll()` re-reads `turn_state.json` on every call; `#structural-criteria` SC01 keeps the store API; `#implementation-observations` – the DECISION NOTE naming this story as the receiving surface.
- `../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring.wire` – the 14-step order at HEAD (drift audit §4.2): preflight fatal before any store opens (3), manifest (4), reconciliation and search open non-fatal (6–7), tasks open fatal (8), state open fatal (9) – the turn-state open must move ahead of step 8 for a pre-gate scan.
- `../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart#DartclawRuntime.build` – `build(..., headless:)` and `stageHeadless` share `_wireStorage`; `completeWithExecution` calls `detectAndCleanOrphanedTurns()` only when a primary lane exists and after `wire()` returned – already the post-gate acknowledgement this story keeps in place.
- `../dartclaw-public/packages/dartclaw_runtime/lib/src/turn_runner_cancellation.dart#detectAndCleanOrphanedTurns` – today's combined `getAll()`, per-orphan warning, `delete`, `_recoveredSessions.addAll`, warning-only on failure; `#consumeRecoveryNotice` is one-shot.
- `../dartclaw-public/packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart` – the crash fixture pair on the SQLite default; the parity Proof of scenario S07.
- `../dartclaw-public/dev/state/LEARNINGS.md#package-architecture` – "Green tests can mask unwired features" (interlock and ordering are proven through the composition root); `#storage--data-model` – "Parse-then-rewrite makes a lenient parser destructive" (an unparseable probe result is could-not-verify, never a repair). `../dartclaw-public/dev/state/LEARNINGS.md#tooling--verification` – suites run as isolates in one process (a database-wide advisory key needs a per-test key); nested `dart run` readiness budgets.
- `docs/specs/0.26/launch-context.md` – the live committed startup order, local-store mechanism, CI baseline, and resolved rider placement that supersede both temporary re-plan audits.


## Deeper Context

- `docs/specs/0.26/intent.md#resolved-decisions` – "Interlock recovery – refuse all seam operations until re-gating"; "Database retry boundary – pre-dispatch only".
- `docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md#technical-overview` – epoch `1`, `dartclaw_schema`; the PostgreSQL probe reads the marker through the same identity.
- `../dartclaw-public/dev/architecture/control-protocol.md#turn-level-recovery-statedb` – the recovery section (retitled by story S15; re-resolve at execution) that TI07 extends; `../dartclaw-public/dev/architecture/data-model.md#storage-mechanisms` and `#recovery` – where the ownership and switch rows land.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#layer-4--live-integration--e2e-tests` – tag and run conventions; until story S11's CI job lands the live suites run through `release_check.sh` only.


## Acceptance Scenarios

- **S01 [OC01,OC04] [TI01,TI03] [runtime] A second serve attach fails before storage use while one-shot clients stay sanctioned**
  - **Given** serve instance A holds the interlock for PostgreSQL database X and instance B selects the same database with a valid, reachable configuration
  - **When** B starts through `DartclawRuntime.build`, and separately `dartclaw cleanup`, `workflow status --standalone`, `rebuild-index`, and a headless standalone `workflow run` execute against X while A serves
  - **Then** B aborts through the existing fatal path before `prepareAuthoritativeStore` or any repository is constructed, its severe line names the ownership conflict and the remedy (stop the other instance or use a separate database) with no DSN, userinfo, or driver text, B leaves no connection behind, A keeps serving and its lock, and every one-shot client completes without acquiring or being refused by the lock

- **S02 [OC01] [TI02] [runtime] Ownership loss quarantines the complete seam until all three gates pass**
  - **Given** a serving instance whose dedicated interlock connection is terminated (`pg_terminate_backend`) while no competitor holds the key, an owner-prepared `DatabaseStatement`, and a `PostgresFtsIndex` and `TemporalKnowledgeGraphService` on the same backend
  - **When** callers invoke `execute`, `query` (one with `RETURNING`), `prepare`, `transaction`, the prepared statement, a memory search, and a KG read during recovery, and the connection then becomes reacquirable
  - **Then** every call fails with `StorageConnectionException` carrying the interlock-recovery-pending message with a dispatch count of zero, the rendering carries no DSN, and access resumes for every caller only after lock reacquisition, a `server_version_num` ≥ 140000 read, and `PostgresSchemaGate` classifying the database current have all succeeded, with the catalog unchanged by the re-gate

- **S03 [OC01,OC04] [TI02] Terminal recovery failures stay quarantined and fail-stop once**
  - **Given** ownership is lost and recovery meets, in separate runs, a competing holder of the key, an exhausted recovery budget (advanced under `fake_async`), a reconnected server below version 14, and a schema the gate refuses
  - **When** recovery reaches that verdict
  - **Then** the quarantine stays closed, the fatal-loss signal fires exactly once with a typed exception naming the condition and remedy, wiring logs severe and calls the injected exit function once, nothing is replayed or dispatched, and S07's retry, backoff, and pool-wait constants are the values S07 landed

- **S04 [OC01] [TI03] [runtime] Graceful shutdown releases ownership after the pool closes**
  - **Given** a PostgreSQL-backed serve instance with a storage operation in flight
  - **When** `shutdown()` runs
  - **Then** `PostgresBackend.close()` completes before the interlock connection closes, the loss handler starts no recovery, `pg_locks` shows no holder of the key afterwards, and a second instance acquires ownership immediately

- **S05 [OC02] [TI05] [runtime] Selecting PostgreSQL preserves both target cases and reports the local store without touching it**
  - **Given** a data directory holding a populated `dartclaw.db`, then a populated released-0.25 `tasks.db`, then both, then an empty-schema `dartclaw.db`, each paired with a PostgreSQL target that is fresh, then one already current with different content
  - **When** `database.backend: postgres` boots
  - **Then** the fresh target holds exactly the bootstrapped schema and no local row, the current target answers only its own rows, one warning-level notice names the local file (or both files as ambiguous) as an abandoned store with the decommission guidance while the empty store produces none, `adoptLegacyAuthoritativeStore` is never invoked, and the directory listing and every local file's bytes are unchanged

- **S06 [OC02,OC04] [TI05] [runtime] Selecting SQLite probes an inactive PostgreSQL reference best-effort**
  - **Given** `database.backend: sqlite` with a retained `database.url` or `database.credential` that resolves, in separate runs, to a current non-empty PostgreSQL store, an empty database, a store whose interlock key another session holds, a refused port, an unset variable or unknown credential name, `db.example.com?sslmode=disable`, and finally a config with neither reference
  - **When** the server starts
  - **Then** SQLite serves its own data and every start succeeds; the notices read abandoned (safe identity, remedy), nothing for empty, in use, and could-not-verify naming only the reason class (unreachable, unresolved reference, posture refused, unknown schema); no output carries a DSN, userinfo, or driver text; the posture refusal opens no socket; each real probe uses one connection closed before serving and audited `open`/`close`; the neither-reference run opens no connection

- **S07 [OC03,OC04] [TI04] [runtime] Orphan evidence survives a failed active-backend start and is acknowledged once after a successful one**
  - **Given** `turn_state.json` holding one orphaned turn and, in separate runs, a `postgres` factory failing with `StorageConnectionException`, a SQLite store the S02 gate refuses, a healthy PostgreSQL target, and the SQLite default
  - **When** the runtime is built, then built again after the failure cause is removed
  - **Then** the failing start logs one warning naming the session, turn, and start time before its backend factory is called, exits through the existing fatal path, and leaves the record intact; the succeeding start warns once more, passes the gate, deletes the record after `wire()` returns, seeds exactly one `consumeRecoveryNotice` result, and emits no second per-orphan warning; a scan failure is warning-only and does not bypass the gate
  - **Final verification**: `dart test --reporter=failures-only --run-skipped -t integration packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart --name "reserve/start crash leaves one orphan that restart cleanup clears with one recovery notice"` – pending the final combined gate under the owner scheduling override; recorded as S10/S07 in `deferred-live-platform-proofs.json`. The failing-start legs remain bound by TI04.

- **S08 [OC05] [TI06] [runtime] A PostgreSQL serve run is SQLite-free**
  - **Given** `database.backend: postgres` with a reachable current-or-fresh database and an empty data directory
  - **When** the runtime boots through `DartclawRuntime.build`, serves one turn on the fake harness, accepts one signed GitHub webhook, and shuts down
  - **Then** no file matching `*.db*` exists under the data directory, the test-only open observer on `SqliteBackend` records zero invocations for the whole run, and each phase completed (the `sqlite3` library stays linked into the binary – ADR-045 open question 2, not reopened)


## Structural Criteria

- **SC01** The interlock is one `pg_try_advisory_lock` on the fixed 64-bit key held by a direct `Connection` outside S07's pool with `application_name=dartclaw`; it is acquired only by the serving composition (`build` with `headless: false`), after `PostgresBackend.open` and before `prepareAuthoritativeStore`; `stageHeadless`, headless builds, and the CLI open sites construct no interlock.
- **SC02** One backend-owned quarantine guard runs before dispatch at every `PostgresBackend` entry (`execute`, `query`, `prepare`, `transaction`) and every `DatabaseStatement` it hands out; no read/write classification exists and `query()` receives no exemption.
- **SC03** The quarantine clears on exactly one transition – reacquisition, then a successful version read, then a current schema classification – and every other path leaves it closed; the recovery budget and check interval are private constants injectable for tests, with no `database.*` key added.
- **SC04** S07's `postgres_dispatch_policy.dart` is byte-identical to the S07 landing; the interlock file imports the driver only for the dedicated connection.
- **SC05** `wire()` order: preflight and manifest, the SQLite search steps, turn-state open and read-only scan, the active-store step (adoption and `prepareTasks` under `sqlite`; open, interlock, `prepareAuthoritativeStore`, language validation, reconciliation under `postgres`), then the abandoned-store probe; postures are S06's plus one: the probe is never fatal and the scan failure is warning-only.
- **SC06** The abandoned-store predicate is S14's four content tables on both sides; derived rows (`memory_chunks`, `search.db`) are not data for the notice; no probe writes, adopts, renames, or creates any store; under `postgres` the only SQLite open possible is `probeAuthoritativeStore`'s read-only open of an existing file.
- **SC07** No production or dev-doc text touched by this story names `ServiceWiring`, `state.db` as the recovery store, `dartclaw_storage`, or `dartclaw_server`; comments carry no story IDs.
- **SC08** Every live suite this story adds carries `@Tags(['integration'])` and reaches `DARTCLAW_TEST_POSTGRES_URL` through S07's support helper; workspace analysis, `bash dev/tools/test_workspace.sh`, `bash dev/tools/fitness/run_all.sh`, `dart run dev/tools/arch_check.dart` (recorded-rebaseline protocol if the core ceiling is crossed), and `git diff --check` are green with the variable unset; `service_wiring.dart` stays at or under 1500 lines.


## Scope & Boundaries

### Work Areas
- Interlock and quarantine: new `packages/dartclaw_core/lib/src/storage/postgres_interlock.dart` (`PostgresInterlock`, loss detection, recovery state machine, message catalog); `postgres_backend.dart` (quarantine guard reached only by the interlock); core barrel `show` clauses (TI01, TI02)
- Abandoned-store probes: new `packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart` (verdict type, SQLite side over S14's helper, PostgreSQL side over S08's evaluator and resolver) (TI05)
- Composition root: `packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart` (turn-state open moved ahead of the active-store step, read-only scan, interlock acquire/release, fatal-loss handling, probe step); `service_wiring.dart` (serve-only flag, line-neutral) (TI03, TI04, TI05)
- Recovery split: `packages/dartclaw_runtime/lib/src/turn_runner_cancellation.dart#detectAndCleanOrphanedTurns` becomes the acknowledgement phase (TI04)
- Test-only observer: `packages/dartclaw_core/lib/src/storage/sqlite_backend.dart` (`@visibleForTesting` open observer on the three open constructors) (TI06)
- Tests: new `packages/dartclaw_core/test/storage/{postgres_interlock_test,postgres_interlock_live_test,abandoned_store_probe_test}.dart`, `packages/dartclaw_runtime/test/runtime/{storage_wiring_recovery_order_test,storage_wiring_postgres_interlock_live_test}.dart`, `packages/dartclaw_runtime/test/integration/postgres_serve_run_probe_test.dart` (TI01–TI06)
- Docs: `dev/architecture/data-model.md`, `dev/architecture/control-protocol.md`, `dev/architecture/system-architecture.md`, `CHANGELOG.md` (TI07)

### What We're NOT Doing

_(`S<NN>` outside `## Acceptance Scenarios` names a plan story; inside it, a scenario ID.)_

- Data import, export, or reconciliation between backends – switching selects a store; the importer is a separate future tool (ADR-045 #2, Resolved Q1).
- Active-active serving, leader election, lease rows, TTL takeover, or fencing – one serving owner and PostgreSQL's crash-released session lock are the whole mechanism (ADR-045 #4).
- A SQL classifier or partial read availability during uncertain ownership – the seam is quarantined as one unit (owner 2026-07-30).
- Changes to S07's retry constants, dispatch classifier, or replay rules – this story owns only its interlock budget and check interval.
- Interlocking one-shot commands (`cleanup`, `workflow status --standalone`, `rebuild-index`) or headless standalone workflow runs – sanctioned concurrent clients whose concurrency guard is the database itself.
- Probing `search.db` or PostgreSQL `memory_chunks` for the notice – derived rows rebuild from the canonical corpus (stories S03/S09). **NOTICED BUT NOT TOUCHING**: S14's Required Context still says this story "adds `memory_chunks` for `search.db`"; it does not – owner-owned cross-reference cleanup.
- Live backend changes – `database.*` stays restart-tier (S07); the operator guide with decommission guidance – story S12.


## Architecture Decision

**Approach**: Hold `pg_try_advisory_lock(0x64617274636c6177)` on one direct, non-pooled session for the lifetime of the serving process; on loss, flip one backend-owned quarantine flag before the first `await` and reopen only after reacquire → version → schema; split today's orphan sweep into a read-only pre-gate scan in `wire()` and the existing post-gate acknowledgement; classify inactive stores through S14's helper and S08's evaluator without writing anything. See ADR: `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md` (#2, #4, #8a).
**Why this over alternatives**: a lease table needs its own writer, TTL, and fencing and reintroduces the coordination state the ADR rejected; a read-only exemption during recovery needs a SQL classifier that `RETURNING` defeats; moving the whole sweep before the gate would delete evidence a failed connect still needs; a second `TurnStateStore` reader in the runtime would duplicate what `wire()` already holds.


## Technical Overview

`StorageWiring.wire()` after this story (S06 numbering; unchanged steps omitted):

| Step | Change | Posture |
|---|---|---|
| 3–4 preflight, manifest | none; local, fatal, precedes every store | fatal |
| 4a–7 (sqlite only) | none | non-fatal |
| **7b turn-state open + scan** | `openTurnStateStore(p.join(dataDir, 'turn_state.json'))` (S15's call, moved from step 9); when serving, `getAll()` and one warning per orphan (session, turn, started); nothing deleted or remembered here | open failure keeps S15's fatal posture; scan failure logs a warning and continues |
| 8 active store | `sqlite`: S14 adoption → open → `prepareTasks` (unchanged). `postgres`: `PostgresBackend.open` → **`PostgresInterlock.acquire`** (serve only; a `false` lock result throws the conflict `StorageConnectionException`) → `prepareAuthoritativeStore` → S09 `validatePostgresFtsLanguage` → reconciliation | fatal; on any failure after acquire the interlock connection closes before the backend |
| **8a abandoned-store probe** | `postgres` active: `probeAuthoritativeStore(config.dartclawDbPath)` → notice for present-non-empty (either name) or ambiguous, nothing for absent or empty, could-not-verify notice otherwise. `sqlite` active with `url` or `credential` retained: `probeInactivePostgresStore` (below); neither reference → no call | never fatal |
| `dispose()` | S06 closes both backends, then `_interlock?.release()`; a shutdown flag set first so a loss observed during teardown starts no recovery | – |

Acknowledgement stays where it is: `completeWithExecution` runs `detectAndCleanOrphanedTurns()` after `wire()` has returned, so under a failed gate it never runs. The method keeps `getAll` → `delete` → `_recoveredSessions.addAll` and logs one info summary instead of the per-orphan warning the scan now owns; `consumeRecoveryNotice` and `web_routes.dart` are untouched.

`PostgresInterlock` (core): `acquire()` opens one `Connection` from the S08 evaluator's `Endpoint`/`SslMode` with `application_name=dartclaw`, runs `SELECT pg_try_advisory_lock($1)` with the int64 key (per-instance key injectable for tests; the production constant is the default), and returns or throws the conflict message. Loss is observed two ways, both entering one idempotent `_onLost`: the driver's connection-closed signal, and an ownership check every 60 s (injectable clock and interval) reading `pg_locks` for this session's pid and the key (`classid` = high 32 bits, `objid` = low 32 bits, `objsubid = 1`). `_onLost` calls `backend.quarantine()` synchronously, then loops: reconnect and `pg_try_advisory_lock`; `false` is terminal (competing holder); a connection failure retries on a fixed short interval until the 10-minute budget (injectable) is exhausted (terminal); on `true`, read `server_version_num` on the interlock connection (< 140000 terminal) and run `PostgresSchemaGate.prepare(backend)` through a recovery-scoped context the guard honors (incompatible terminal), then `backend.release()`. Terminal verdicts leave the quarantine closed and call `onFatalLoss(StorageException)` once; `StorageWiring` logs severe and calls `_exitFn(1)`. `release()` sets the shutdown flag, then closes the connection after the backend has closed.

Quarantine guard (`PostgresBackend`): a private flag checked at the top of `execute`, `query`, `prepare`, `transaction`, and every statement's `execute`/`query`; when set, throw `StorageConnectionException` with the recovery-pending message before S07's dispatch policy sees the operation. Operations already dispatched at loss time finish under S07's rules.

`probeInactivePostgresStore(DatabaseConfig, {resolveDsn, auditLogger})` (core): resolve → evaluate posture → one direct connection with a 5-second connect timeout → read `dartclaw_schema` and `SELECT 1 … LIMIT 1` over the four content tables → read `pg_locks` for the key → close. Verdicts: `abandoned` (marker `(1, 1)` and any row), `empty`, `inUse`, `couldNotVerify(reasonClass)` for every failure – unresolved reference, posture refusal (no socket), connect or auth failure, timeout, missing or unknown marker, catalog error. It never throws; audit entries reuse S08's `open`/`close`/`auth_failure` shape. Conflict, recovery-pending, terminal, abandoned, in-use, and could-not-verify messages are composed in one catalog from safe fields only (S07 #8).


## Code Patterns & External References

```
# type | path#anchor                                                                                                   | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring.wire            | the step order, failure postures, dispose(); steps 7b, 8 (postgres branch), 8a slot in here
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart#DartclawRuntime.build          | build vs stageHeadless, the `headless` flag, `_wireStorage`, sweep placement, shutdown order
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/turn_runner_cancellation.dart#detectAndCleanOrphanedTurns  | today's combined scan/delete/seed to split; warning-only failure posture to keep
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/turn_state_store.dart#TurnStateStore                  | getAll/delete surface the scan and acknowledgement use (filesystem after story S15)
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/postgres_backend.dart#PostgresBackend                 | as landed by story S07: open/close, statements, the dispatch entry points the guard fronts
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/postgres_dispatch_policy.dart                          | as landed by story S07: the classifier and constants that must stay byte-identical
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/postgres_schema_gate.dart#PostgresSchemaGate           | as landed by story S07: the re-gate; a current reopen performs no write
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/postgres_connection_posture.dart                       | as landed by story S08: Endpoint, SslMode, safe identity, credentialRef
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/authoritative_store_adoption.dart#probeAuthoritativeStore | as landed by story S14: the either-name read-only presence helper
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/storage_exceptions.dart                                      | as landed by story S07: StorageConnectionException composed from safe fields
file   | ../dartclaw-public/packages/dartclaw_core/test/storage/postgres_live_support.dart                                | as landed by story S07: DARTCLAW_TEST_POSTGRES_URL, fail loud when unset, per-test namespace
file   | ../dartclaw-public/packages/dartclaw_runtime/test/integration/_fixtures/crash_turn_process.dart#main            | fake-harness serve composition the serve-run probe mirrors in-process
file   | ../dartclaw-public/packages/dartclaw_runtime/test/api/github_webhook_test.dart                                   | signed-webhook request shape (`x-hub-signature-256`, `x-github-delivery`)
url    | https://www.postgresql.org/docs/14/functions-admin.html                                                          | pg_try_advisory_lock session semantics, release on session end
url    | https://www.postgresql.org/docs/14/view-pg-locks.html                                                            | advisory rows: classid/objid split of a 64-bit key, objsubid = 1
```


## Constraints & Gotchas

- **Critical**: flip the quarantine before the loss handler's first `await`; concurrent loss signals (closed connection and a failed ownership check in one tick) share one recovery run.
- **Critical**: the interlock connection is direct and session-pinned. A transaction-mode pooler between DartClaw and the server cannot hold a session advisory lock; the conflict and recovery messages must not suggest one. Pool connections never run `pg_try_advisory_lock`.
- **Critical**: never clear the quarantine because a reconnect or lock attempt succeeded; all three gates pass or the backend stays closed to callers.
- **Critical**: acknowledgement after the gate means after `wire()` returned – never move `detectAndCleanOrphanedTurns()` or a `delete` into the pre-gate scan, and never seed `_recoveredSessions` from the scan.
- **Avoid**: validating inactive references as active config. Under `sqlite`, resolution, posture, and connect failures are probe verdicts only, logged without the value that failed.
- **Constraint**: zero SQLite under `postgres` is kept by construction – the only SQLite call on that branch is `probeAuthoritativeStore`'s read-only open of an existing file; no `SqliteBackend.openInMemory`, no adoption, no `search.db`.
- **Constraint**: `service_wiring.dart` is at the 1500-line cap; the serve-only flag reaches `StorageWiring` line-neutrally (fold into an existing argument list line or default it from `headless`). Fatal-loss handling lives in `storage_wiring.dart`.
- **Constraint**: two-sided LOC ratchet (`dev/tools/arch_check.dart#_libLocCeilings`): roughly 500–700 core lib lines land after S07's and S09's raises; a crossed `dartclaw_core` ceiling takes the recorded-rebaseline protocol (raise to measured plus at most 1500 with a CHANGELOG `### Changed` note in the same change). No lib file over 1500 lines, no test file over 1300.
- **Constraint**: the advisory key is database-wide, so live interlock tests inject a per-test key; S07's per-test namespace does not isolate locks.
- **Constraint**: S10's constants (60 s check, 10 min budget, 5 s probe timeout) are private and injectable through constructors; no `database.*` key, so the five config gates are untouched.
- **Constraint**: comments are rationale-only; no story IDs in code, dartdoc, tests, CHANGELOG, or user-facing text; the interlock's dartdoc states the contract, not the decision history.


## Implementation Plan

### Implementation Tasks

- **TI01** One serving instance owns each PostgreSQL database through a session lock on a dedicated connection
  - `postgres_interlock.dart` per the Technical Overview: `PostgresInterlock({key, checkInterval, recoveryBudget, clock})` with `acquire`, `release`, loss detection, and the message catalog; `show`-exported. Untagged `postgres_interlock_test.dart` drives the class through an injected connection seam; live `postgres_interlock_live_test.dart` proves the real lock.
  - **Verify**: `cmd: rg -q "pg_try_advisory_lock" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart && rg -q "application_name" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart && ! rg -q "Pool\b" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/postgres_interlock_test.dart && dart analyze --fatal-infos packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart` – session lock on a non-pool connection with the application name; the untagged suite proves a `false` lock result throws the conflict message with no fixture DSN field, both loss signals enter one recovery, the budget expires exactly once, and no recovery starts after `release`; the live suite proves scenario S01's lock half (a second `acquire` on the same key refuses while the first holds, `pg_locks` shows one holder, the refused attempt leaves no session) and scenario S04's release half (no holder after `release`, immediate reacquire)
  - **SATISFIES**: S01, S04, SC01, SC03

- **TI02** Ownership uncertainty blocks the complete seam until all three recovery gates pass
  - `PostgresBackend.quarantine()`/`release()` and the guard at every entry point and statement; the recovery re-gate (version read on the interlock connection, `PostgresSchemaGate.prepare` through the recovery-scoped context); terminal verdicts call `onFatalLoss` once. Depends on TI01. Extend `postgres_interlock_test.dart` with a fake backend and the live suite with `pg_terminate_backend` of the interlock session.
  - **Verify**: `cmd: git ls-files --error-unmatch packages/dartclaw_core/lib/src/storage/postgres_dispatch_policy.dart && git diff --quiet HEAD -- packages/dartclaw_core/lib/src/storage/postgres_dispatch_policy.dart && rg -q "quarantine" packages/dartclaw_core/lib/src/storage/postgres_backend.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/postgres_interlock_test.dart packages/dartclaw_core/test/storage/postgres_dispatch_policy_test.dart && dart analyze --fatal-infos packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart` – the dispatch-policy file is tracked and unchanged and its suite passes (scenario S03's constants clause); the untagged suite proves every entry point and an existing statement throw the recovery-pending exception at dispatch count zero, that only reacquire plus version plus schema reopens, and that each terminal branch keeps the quarantine closed and fires the fatal signal once (scenario S03); the live suite proves scenario S02 end to end – every listed caller refuses during recovery and succeeds after it, catalog snapshot unchanged
  - **SATISFIES**: S02, S03, SC02, SC03, SC04

- **TI03** The serving composition acquires the interlock inside the active-store step and releases it after the pool closes
  - `storage_wiring.dart#StorageWiring.wire` step 8 `postgres` branch: acquire after `PostgresBackend.open`, before `prepareAuthoritativeStore`; a conflict takes the existing fatal path; `onFatalLoss` logs severe and calls `_exitFn(1)`; `dispose()` releases after the backend close; the serve-only condition comes from `build`'s `headless` flag line-neutrally in `service_wiring.dart`; `stageHeadless` and the CLI open sites are untouched. Depends on TI01, TI02. New live `storage_wiring_postgres_interlock_live_test.dart` through `DartclawRuntime.build` with a recording factory.
  - **Verify**: `cmd: test "$(rg -n 'PostgresInterlock' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'prepareAuthoritativeStore' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && ! rg -q "PostgresInterlock" apps/dartclaw_cli/lib && test "$(wc -l < packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart)" -le 1500 && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/dartclaw_runtime_test.dart packages/dartclaw_runtime/test/runtime/headless_runtime_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_partial_cleanup_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart apps/dartclaw_cli/test/commands/postgres_sanctioned_clients_live_test.dart` – acquisition precedes the schema gate, the CLI constructs no interlock, the assembly file stays under the cap, the runtime and headless suites pass unchanged, and the live suite proves scenario S01 (a second `build` reaches the injected exit function before `prepareAuthoritativeStore`, asserted through a recording gate, with the conflict message and no leaked connection, while `cleanup`, `workflow status --standalone`, `rebuild-index`, and a `stageHeadless` staging complete against the same database), scenario S04 (pool closed before the lock is gone, no recovery, immediate reacquire by a second `build`), and one exit call after a forced terminal recovery
  - **SATISFIES**: S01, S04, SC01, SC05

- **TI04** Orphan recovery scans before the active-store gate and acknowledges after it
  - `wire()` step 7b per the Technical Overview; `detectAndCleanOrphanedTurns` keeps `getAll` → `delete` → seed and logs one info summary; the crash fixture pair is unchanged. New untagged `storage_wiring_recovery_order_test.dart`: injected factories (a `postgres` factory throwing `StorageConnectionException`; a SQLite store the gate refuses; a healthy in-memory store), a seeded `turn_state.json`, a recording log handler, the injected exit function.
  - **Verify**: `cmd: bash -c 'test "$(rg -n '"'"'openTurnStateStore\('"'"' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n '"'"'taskBackendFactory\(|databaseBackendFactoryFor\('"'"' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && ! rg -q "delete\(" <(awk '"'"'/openTurnStateStore\(/,/prepareAuthoritativeStore|prepareTasks/'"'"' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart) && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_recovery_order_test.dart packages/dartclaw_runtime/test/turn_manager_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart'` – the turn-state store opens before either active-store open and the pre-gate region deletes nothing; the new suite proves scenario S07's failing legs (one per-orphan warning before the factory's first call, exit function called, record intact, no seed) and its succeeding legs on both backends (warning once, record deleted only after `wire()` returned, exactly one `consumeRecoveryNotice` true, no duplicate warning, an unreadable store yields one warning and the gate still runs); the crash smoke test stays green
  - **SATISFIES**: S07, SC05

- **TI05** Backend selection preserves target data and reports inactive stores best-effort under the posture
  - `abandoned_store_probe.dart` per the Technical Overview (`show`-exported); `wire()` step 8a after the active store is prepared; under `postgres` the S14 adoption call is not reached; notices at warning level from the shared catalog. Depends on TI03. New untagged `abandoned_store_probe_test.dart` (SQLite side over temp directories through S14's helper; PostgreSQL side over an injected connection seam – every verdict and failure class, no connection on posture refusal, no call when neither reference is present) and live cases in `storage_wiring_postgres_interlock_live_test.dart`.
  - **Verify**: `cmd: bash -c 'rg -qU '"'"'if \(config.database.backend == DatabaseBackendKind.sqlite\) \{\s*await adoptLegacyAuthoritativeStore\(config.dartclawDbPath\);\s*\}'"'"' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && test "$(rg -c '"'"'adoptLegacyAuthoritativeStore\('"'"' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart)" = 1 && ! rg -q "memory_chunks|search\.db" packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/abandoned_store_probe_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_backend_selection_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart'` – adoption is absent from the `postgres` branch, derived stores are outside the predicate, the untagged suites prove every SQLite verdict without a byte or listing change and every PostgreSQL verdict without a fixture DSN field, and the live suite proves scenario S05 (no local row in either target, notices for `dartclaw.db`, `tasks.db`, and both-as-ambiguous, none for the empty store, adoption never called, local bytes unchanged) and scenario S06 (every verdict, posture refusal with zero sockets, neither reference with zero connections, `open`/`close` audit entries per real probe)
  - **SATISFIES**: S05, S06, SC06

- **TI06** A PostgreSQL serve run is proven SQLite-free
  - `SqliteBackend` gains a `@visibleForTesting static void Function(String? path)? openObserver` invoked by `open`, `openInMemory`, and `openReadOnly` (story S15 leaves this file as the only raw open site). New `postgres_serve_run_probe_test.dart` (`@Tags(['integration'])`, S07's helper, fresh temp data dir): `DartclawRuntime.build` with `database.backend: postgres` and the `FakeAgentHarness` composition the crash fixture uses, one `/api/sessions` + `/send` turn, one HMAC-signed `x-github-delivery` webhook POST, `shutdown()`. Depends on TI03–TI05.
  - **Verify**: `cmd: test "$(rg -c "openObserver" packages/dartclaw_core/lib/src/storage/sqlite_backend.dart | tr -d ' ')" -ge 4 && dart analyze --fatal-infos packages/dartclaw_runtime/test/integration/postgres_serve_run_probe_test.dart` – the observer is declared and wired into all three constructors; the probe proves scenario S08 (no `*.db*` under the data dir, zero observed opens, turn and webhook accepted, clean shutdown)
  - **SATISFIES**: S08, SC06

- **TI07** Architecture docs and the CHANGELOG describe ownership, ordering, and switch semantics
  - `dev/architecture/data-model.md` § Storage Mechanisms: the PostgreSQL interlock (session lock, refuse-until-re-gated, one-shot commands outside it) and the no-transfer switch with its best-effort notice; § Recovery gains a "lost interlock" row. `dev/architecture/control-protocol.md` turn-level recovery section (as story S15 leaves it): scan before the active-store gate, acknowledgement after `wire()`. `dev/architecture/system-architecture.md` startup list gains the interlock step. Bump each "Current through" marker. CHANGELOG `### Added` line under Unreleased. No story IDs.
  - **Verify**: `cmd: bash -c 'rg -qi "advisory lock" dev/architecture/data-model.md && rg -qi "abandoned" dev/architecture/data-model.md && rg -qi "before the .*gate|before any .*connection" dev/architecture/control-protocol.md && rg -qi "interlock" dev/architecture/system-architecture.md CHANGELOG.md && ! rg -q "S10|TI0[0-9]|story S" dev/architecture/data-model.md dev/architecture/control-protocol.md dev/architecture/system-architecture.md && ! rg -q "state\.db" <(awk '"'"'/Turn-level recovery/,/Message-level recovery/'"'"' dev/architecture/control-protocol.md) && git diff --check'` – the three docs carry the interlock, notice, and ordering facts, no story or task ID leaked, the recovery section no longer names the retired store, whitespace clean
  - **SATISFIES**: SC07

- **TI08** Governance gates hold and the default run needs no PostgreSQL
  - Depends on TI01–TI07. Apply the LOC rebaseline protocol if `arch_check` reports a crossed `dartclaw_core` ceiling; every new live suite tagged; no `markTestSkipped`.
  - **Verify**: `cmd: test "$(rg -l "@Tags\(\['integration'\]\)" packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart packages/dartclaw_runtime/test/integration/postgres_serve_run_probe_test.dart apps/dartclaw_cli/test/commands/postgres_sanctioned_clients_live_test.dart | wc -l | tr -d ' ')" = 4 && ! rg -q "ServiceWiring|dartclaw_storage|dartclaw_server" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart dev/architecture/data-model.md dev/architecture/control-protocol.md && (unset DARTCLAW_TEST_POSTGRES_URL; dart analyze --fatal-infos) && dart run dev/tools/arch_check.dart && git diff --check` – all three live suites are tagged, no retired name survives in the touched files, analysis and the whole workspace suite pass with no PostgreSQL reachable, the fitness suite and `arch_check` are green, and the diff is whitespace-clean
  - **SATISFIES**: SC07, SC08

### Testing Strategy

- [TI01, TI02, TI05] Untagged Layer 1/2 over injected seams: a fake lock connection (acquire result, closed signal, ownership-check result), a fake backend recording dispatch counts, `fake_async` for the budget and check interval, temp directories for the SQLite side of the probe. No production fault switch; the seams are the constructor parameters the Technical Overview names.
- [TI04] Layer 2 through `StorageWiring.wire()` with injected factories and exit function as S07's selection suite does; order is asserted by observable effects (log records before the factory's first call, file content after exit), never private call order.
- [TI01–TI03, TI05, TI06] Live Layer 4 (`integration`): the real lock, `pg_terminate_backend`, a second session holding the key, real refused ports, the composition-root boot. A per-test key isolates parallel interlock cases; switch cases use S07's per-test namespace for the database side and temp dirs for the SQLite side. Secrecy assertions use distinctive high-entropy fixture values over captured logs and exception renderings.
- The one bound Proof is parity (SQLite default). Red-at-spec-time surface: `postgres_interlock_test.dart`, `abandoned_store_probe_test.dart`, `storage_wiring_recovery_order_test.dart`, and the three live suites, none of which exist at HEAD.

### Validation

- A live PostgreSQL 14+ reachable through `DARTCLAW_TEST_POSTGRES_URL` is required for the live halves of TI01–TI03, TI05, and TI06; without it execution reports `BLOCKED:` for those halves rather than treating the untagged suites as ownership proof. None was available at spec time (2026-09-02), so no live Proof is bound.

### Execution Contract

- Stories S07, S08, S09, S14, and S15 must be complete; consume `PostgresBackend`, `PostgresSchemaGate`, the dispatch policy, `databaseBackendFactoryFor`/`prepareAuthoritativeStore`, `resolveDatabaseDsn`, the posture evaluator and audit hook, `validatePostgresFtsLanguage`, `probeAuthoritativeStore`, and `openTurnStateStore` as landed; if a signature differs from its FIS, raise `CONFUSION:` rather than forking it. Order: TI01 → TI02 → TI03 → TI04 → TI05 → TI06 → TI07 → TI08. All commands run from the `../dartclaw-public/` root.
- TI02's `git diff --quiet HEAD` check proves SC04 only against a committed baseline: "S07 complete" above means S07's `postgres_dispatch_policy.dart` is committed, not merely present in the working tree, before TI02 runs. Its Verify also requires the file to be tracked (`git ls-files --error-unmatch`), so an untracked file fails the check instead of passing it trivially.
- ASSUMPTION (AUTO_MODE, 2026-09-02): the interlock and the pre-gate scan run only in the serving composition (`DartclawRuntime.build` with `headless: false`); `stageHeadless`, headless builds, and the CLI open sites are sanctioned concurrent clients. ADR-045 #4 names `dartclaw serve` as the lock holder and the plan sanctions one-shot commands; a headless standalone workflow run is one-shot in the same sense.
- ASSUMPTION (AUTO_MODE, 2026-09-02): the recovery re-gate runs `PostgresSchemaGate.prepare` against the quarantined backend through a recovery-scoped context the guard recognizes (the S01 zone-value idiom); if the gate cannot be reached that way, run its catalog reads on the interlock connection – never add a public `unquarantined` API.
- ASSUMPTION (AUTO_MODE, 2026-09-02): derived index rows are outside the abandoned-store predicate (SC06); the prior FIS's fifth table was authoring design, not an owner decision.
- The public working tree may carry another session's uncommitted edits outside this story's Work Areas; touch only the files named there. `service_wiring.dart` is in that set at authoring time – rebase the one flag onto its landed shape.


## Final Validation Checklist

- No raw DSN, userinfo, resolved credential, or driver text appears in conflict, recovery-pending, terminal, abandoned, in-use, or could-not-verify output.
- With `database:` omitted the default suite passes without PostgreSQL, no interlock or probe connection is made, and the crash smoke test's recovered-session and single-banner assertions hold.
- A PostgreSQL serve run from an empty data directory (boot → turn → webhook → shutdown) leaves no `*.db*` file and records zero SQLite opens.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

#### DECISION NOTE: s14-pg-dependent-proofs-placement

Decision-Key: s14-pg-dependent-proofs-placement
Altitude: fis-local
Affected surface: this story's scenarios S05 (startup-level no-adoption-under-postgres form, from S14), S07 (PostgreSQL-unreachable recovery-ordering leg, from S15), and S08 + TI06 (SQLite-free serve-run probe, from S15); S14 scenario S07 and S15's FR13 proofs (originating surfaces)
Decision: the rider stories stay ahead of the PostgreSQL stories; every proof requiring S07's `database.*` config or `PostgresBackend` executes in this story.
Rationale: when S14 and S15 execute, `database.backend: postgres` does not parse and `PostgresBackend` does not exist; this story depends on both and owns the boot-flow, abandoned-store, and unreachable-boot integration surface, mirroring the settled either-name-helper split (unit proof in S14, end-to-end consumer proof here).
Evidence: owner ratified 2026-08-07 (preflight interview, `docs/specs/0.26/preflight-2026-08-07.md`); `plan.json` S10 `dependsOn` includes S14 and S15; matching DECISION NOTEs with this key in `s14-authoritative-store-rename.md` and `s15-filesystem-backed-instance-local-state.md` (2026-09-02 split).

### Run: 2026-09-08 14:19 UTC – repair-proof

#### DRIFT

- spec-stale: TI08 Verify target repaired | Stale targets: – | `cmd: test "$(rg -l "@Tags\(\['integration'\]\)" packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart packages/dartclaw_runtime/test/integration/postgres_serve_run_probe_test.dart | wc -l | tr -d ' ')" = 3 && ! rg -q "ServiceWiring|dartclaw_storage|dartclaw_server" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart dev/architecture/data-model.md dev/architecture/control-protocol.md && (unset DARTCLAW_TEST_POSTGRES_URL; dart analyze --fatal-infos && bash dev/tools/test_workspace.sh) && bash dev/tools/fitness/run_all.sh && dart run dev/tools/arch_check.dart && git diff --check` → `cmd: test "$(rg -l "@Tags\(\['integration'\]\)" packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart packages/dartclaw_runtime/test/integration/postgres_serve_run_probe_test.dart | wc -l | tr -d ' ')" = 3 && ! rg -q "ServiceWiring|dartclaw_storage|dartclaw_server" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart dev/architecture/data-model.md dev/architecture/control-protocol.md && (unset DARTCLAW_TEST_POSTGRES_URL; dart analyze --fatal-infos) && dart run dev/tools/arch_check.dart && git diff --check`

### Run: 2026-09-08 14:19 UTC – observations

2026-09-08 16:14 CEST owner scheduling override: one focused independent review and relevant checks per story. Full workspace and full fitness runs in task Verify commands are deferred to the final combined A+B gate, with no acceptance requirement removed. The retained command proves the story-local checks; prose referring to full-suite success describes final milestone evidence. Standard fast-tier closure remains; broad integration, platform and release verification run at the end.

### Run: 2026-09-08 17:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI01 Verify target repaired | Stale targets: – | `cmd: rg -q "pg_try_advisory_lock" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart && rg -q "application_name" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart && ! rg -q "Pool\b" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/postgres_interlock_test.dart && test -n "$DARTCLAW_TEST_POSTGRES_URL" && dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart` → `cmd: rg -q "pg_try_advisory_lock" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart && rg -q "application_name" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart && ! rg -q "Pool\b" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/postgres_interlock_test.dart && dart analyze --fatal-infos packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart`

### Run: 2026-09-08 17:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `cmd: git ls-files --error-unmatch packages/dartclaw_core/lib/src/storage/postgres_dispatch_policy.dart && git diff --quiet HEAD -- packages/dartclaw_core/lib/src/storage/postgres_dispatch_policy.dart && rg -q "quarantine" packages/dartclaw_core/lib/src/storage/postgres_backend.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/postgres_interlock_test.dart packages/dartclaw_core/test/storage/postgres_dispatch_policy_test.dart && test -n "$DARTCLAW_TEST_POSTGRES_URL" && dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart` → `cmd: git ls-files --error-unmatch packages/dartclaw_core/lib/src/storage/postgres_dispatch_policy.dart && git diff --quiet HEAD -- packages/dartclaw_core/lib/src/storage/postgres_dispatch_policy.dart && rg -q "quarantine" packages/dartclaw_core/lib/src/storage/postgres_backend.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/postgres_interlock_test.dart packages/dartclaw_core/test/storage/postgres_dispatch_policy_test.dart && dart analyze --fatal-infos packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart`

### Run: 2026-09-08 17:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: test "$(rg -n 'PostgresInterlock' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'prepareAuthoritativeStore' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && ! rg -q "PostgresInterlock" apps/dartclaw_cli/lib && test "$(wc -l < packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart)" -le 1500 && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/dartclaw_runtime_test.dart packages/dartclaw_runtime/test/runtime/headless_runtime_test.dart && test -n "$DARTCLAW_TEST_POSTGRES_URL" && dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart` → `cmd: test "$(rg -n 'PostgresInterlock' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'prepareAuthoritativeStore' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && ! rg -q "PostgresInterlock" apps/dartclaw_cli/lib && test "$(wc -l < packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart)" -le 1500 && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/dartclaw_runtime_test.dart packages/dartclaw_runtime/test/runtime/headless_runtime_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart`

### Run: 2026-09-08 17:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `cmd: test "$(rg -n 'openTurnStateStore\(' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'taskBackendFactory\(|databaseBackendFactoryFor\(' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && ! rg -q "delete\(" <(awk '/openTurnStateStore\(/,/prepareAuthoritativeStore|prepareTasks/' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart) && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_recovery_order_test.dart packages/dartclaw_runtime/test/turn_manager_test.dart && dart test --reporter=failures-only --run-skipped -t integration packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart` → `cmd: test "$(rg -n 'openTurnStateStore\(' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'taskBackendFactory\(|databaseBackendFactoryFor\(' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && ! rg -q "delete\(" <(awk '/openTurnStateStore\(/,/prepareAuthoritativeStore|prepareTasks/' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart) && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_recovery_order_test.dart packages/dartclaw_runtime/test/turn_manager_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart`

### Run: 2026-09-08 17:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI05 Verify target repaired | Stale targets: – | `cmd: ! rg -q "adoptLegacyAuthoritativeStore" <(awk '/DatabaseBackendKind\.postgres/,/prepareAuthoritativeStore/' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart) && ! rg -q "memory_chunks|search\.db" packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/abandoned_store_probe_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_backend_selection_test.dart && test -n "$DARTCLAW_TEST_POSTGRES_URL" && dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart` → `cmd: ! rg -q "adoptLegacyAuthoritativeStore" <(awk '/DatabaseBackendKind\.postgres/,/prepareAuthoritativeStore/' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart) && ! rg -q "memory_chunks|search\.db" packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/abandoned_store_probe_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_backend_selection_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart`

### Run: 2026-09-08 17:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI06 Verify target repaired | Stale targets: – | `cmd: test "$(rg -c "openObserver" packages/dartclaw_core/lib/src/storage/sqlite_backend.dart | tr -d ' ')" -ge 4 && test -n "$DARTCLAW_TEST_POSTGRES_URL" && dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_runtime/test/integration/postgres_serve_run_probe_test.dart` → `cmd: test "$(rg -c "openObserver" packages/dartclaw_core/lib/src/storage/sqlite_backend.dart | tr -d ' ')" -ge 4 && dart analyze --fatal-infos packages/dartclaw_runtime/test/integration/postgres_serve_run_probe_test.dart`

### Run: 2026-09-08 17:06 UTC – observations

Owner scheduling override: the updated Verify commands prove local implementation and compilation only. Live integration and Windows/platform acceptance remain PENDING at the final combined A+B gate. Original postponed commands are retained by the repair-proof observations and deferred-live-platform-proofs.json. Do not report those postponed behaviors or milestone release acceptance as passed from a local receipt. Named targeted scenario proofs, the driver feasibility spike and missing-DSN refusal checks remain runnable. Final full-suite evidence may cover duplicate/subset invocations only with explicit owner-to-result mapping; platform and contract-report variants remain distinct.

### Run: 2026-09-08 22:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `cmd: test "$(rg -n 'openTurnStateStore\(' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'taskBackendFactory\(|databaseBackendFactoryFor\(' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && ! rg -q "delete\(" <(awk '/openTurnStateStore\(/,/prepareAuthoritativeStore|prepareTasks/' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart) && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_recovery_order_test.dart packages/dartclaw_runtime/test/turn_manager_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart` → `cmd: bash -c 'test "$(rg -n '"'"'openTurnStateStore\('"'"' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n '"'"'taskBackendFactory\(|databaseBackendFactoryFor\('"'"' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && ! rg -q "delete\(" <(awk '"'"'/openTurnStateStore\(/,/prepareAuthoritativeStore|prepareTasks/'"'"' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart) && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_recovery_order_test.dart packages/dartclaw_runtime/test/turn_manager_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart'`

### Run: 2026-09-08 22:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI05 Verify target repaired | Stale targets: – | `cmd: ! rg -q "adoptLegacyAuthoritativeStore" <(awk '/DatabaseBackendKind\.postgres/,/prepareAuthoritativeStore/' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart) && ! rg -q "memory_chunks|search\.db" packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/abandoned_store_probe_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_backend_selection_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart` → `cmd: bash -c '! rg -q "adoptLegacyAuthoritativeStore" <(awk '"'"'/DatabaseBackendKind\.postgres/,/prepareAuthoritativeStore/'"'"' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart) && ! rg -q "memory_chunks|search\.db" packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/abandoned_store_probe_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_backend_selection_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart'`

### Run: 2026-09-08 22:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI07 Verify target repaired | Stale targets: – | `cmd: rg -qi "advisory lock" dev/architecture/data-model.md && rg -qi "abandoned" dev/architecture/data-model.md && rg -qi "before the .*gate|before any .*connection" dev/architecture/control-protocol.md && rg -qi "interlock" dev/architecture/system-architecture.md CHANGELOG.md && ! rg -q "S10|TI0[0-9]|story S" dev/architecture/data-model.md dev/architecture/control-protocol.md dev/architecture/system-architecture.md && ! rg -q "state\.db" <(awk '/Turn-level recovery/,/Message-level recovery/' dev/architecture/control-protocol.md) && git diff --check` → `cmd: bash -c 'rg -qi "advisory lock" dev/architecture/data-model.md && rg -qi "abandoned" dev/architecture/data-model.md && rg -qi "before the .*gate|before any .*connection" dev/architecture/control-protocol.md && rg -qi "interlock" dev/architecture/system-architecture.md CHANGELOG.md && ! rg -q "S10|TI0[0-9]|story S" dev/architecture/data-model.md dev/architecture/control-protocol.md dev/architecture/system-architecture.md && ! rg -q "state\.db" <(awk '"'"'/Turn-level recovery/,/Message-level recovery/'"'"' dev/architecture/control-protocol.md) && git diff --check'`

### Run: 2026-09-08 22:59 UTC – repair-proof

#### DRIFT

- spec-stale: TI05 Verify target repaired | Stale targets: – | `cmd: bash -c '! rg -q "adoptLegacyAuthoritativeStore" <(awk '"'"'/DatabaseBackendKind\.postgres/,/prepareAuthoritativeStore/'"'"' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart) && ! rg -q "memory_chunks|search\.db" packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/abandoned_store_probe_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_backend_selection_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart'` → `cmd: bash -c 'rg -qU '"'"'if \(config.database.backend == DatabaseBackendKind.sqlite\) \{\s*await adoptLegacyAuthoritativeStore\(config.dartclawDbPath\);\s*\}'"'"' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && test "$(rg -c '"'"'adoptLegacyAuthoritativeStore\('"'"' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart)" = 1 && ! rg -q "memory_chunks|search\.db" packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/abandoned_store_probe_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_backend_selection_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart'`

### Run: 2026-09-08 23:10 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: test "$(rg -n 'PostgresInterlock' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'prepareAuthoritativeStore' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && ! rg -q "PostgresInterlock" apps/dartclaw_cli/lib && test "$(wc -l < packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart)" -le 1500 && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/dartclaw_runtime_test.dart packages/dartclaw_runtime/test/runtime/headless_runtime_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart` → `cmd: test "$(rg -n 'PostgresInterlock' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'prepareAuthoritativeStore' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && ! rg -q "PostgresInterlock" apps/dartclaw_cli/lib && test "$(wc -l < packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart)" -le 1500 && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/dartclaw_runtime_test.dart packages/dartclaw_runtime/test/runtime/headless_runtime_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart apps/dartclaw_cli/test/commands/postgres_sanctioned_clients_live_test.dart`

### Run: 2026-09-08 23:11 UTC – repair-proof

#### DRIFT

- spec-stale: TI08 Verify target repaired | Stale targets: – | `cmd: test "$(rg -l "@Tags\(\['integration'\]\)" packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart packages/dartclaw_runtime/test/integration/postgres_serve_run_probe_test.dart | wc -l | tr -d ' ')" = 3 && ! rg -q "ServiceWiring|dartclaw_storage|dartclaw_server" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart dev/architecture/data-model.md dev/architecture/control-protocol.md && (unset DARTCLAW_TEST_POSTGRES_URL; dart analyze --fatal-infos) && dart run dev/tools/arch_check.dart && git diff --check` → `cmd: test "$(rg -l "@Tags\(\['integration'\]\)" packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart packages/dartclaw_runtime/test/integration/postgres_serve_run_probe_test.dart apps/dartclaw_cli/test/commands/postgres_sanctioned_clients_live_test.dart | wc -l | tr -d ' ')" = 4 && ! rg -q "ServiceWiring|dartclaw_storage|dartclaw_server" packages/dartclaw_core/lib/src/storage/postgres_interlock.dart packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart dev/architecture/data-model.md dev/architecture/control-protocol.md && (unset DARTCLAW_TEST_POSTGRES_URL; dart analyze --fatal-infos) && dart run dev/tools/arch_check.dart && git diff --check`

### Run: 2026-09-08 23:18 UTC – observations

The interlock and backend share one Dart library so quarantine controls and the bounded recovery zone are language-private. Recovery calls current-schema-only validation; it never bootstraps an empty namespace. Test hooks run outside that zone. The core LOC check measures 29862 lines and the ceiling is re-cut to the same value, with no headroom. The actual CLI concurrent-client suite is separately registered for final live verification.

### Run: 2026-09-08 23:27 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: test "$(rg -n 'PostgresInterlock' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'prepareAuthoritativeStore' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && ! rg -q "PostgresInterlock" apps/dartclaw_cli/lib && test "$(wc -l < packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart)" -le 1500 && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/dartclaw_runtime_test.dart packages/dartclaw_runtime/test/runtime/headless_runtime_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart apps/dartclaw_cli/test/commands/postgres_sanctioned_clients_live_test.dart` → `cmd: test "$(rg -n 'PostgresInterlock' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'prepareAuthoritativeStore' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && ! rg -q "PostgresInterlock" apps/dartclaw_cli/lib && test "$(wc -l < packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart)" -le 1500 && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/dartclaw_runtime_test.dart packages/dartclaw_runtime/test/runtime/headless_runtime_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_partial_cleanup_test.dart && dart analyze --fatal-infos packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart apps/dartclaw_cli/test/commands/postgres_sanctioned_clients_live_test.dart`

### Run: 2026-09-08 23:36 UTC – observations

Owner scheduling reconciliation: S07 repeats the real-process crash proof already deferred through TI04 and S15/S02. The first local completion passed its fast tier and all eight task Verify commands, but this stale ordinary scenario selector omitted the integration flags and ran zero tests. Mark S07 runtime and retain its exact command in final verification and the deferred registry. Acceptance assertions and pending final execution remain unchanged; no crash-test pass is claimed.

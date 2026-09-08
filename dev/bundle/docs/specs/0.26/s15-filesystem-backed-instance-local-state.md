# FIS: Filesystem-Backed Instance-Local State

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S15

_Authored 2026-09-02 against released 0.25 (public HEAD `daf5125a`) as the FR13 half of the former S14 "Instance-local storage hygiene" FIS (2026-08-07), which the plan split: the `tasks.db` → `dartclaw.db` rename is story S14, this story is the two filesystem stores. Version labels: 0.26 is this milestone (the PRD title still carries its pre-renumber label), released 0.25 is the compatibility baseline. Both stores are byte-identical 0.24 → 0.25 → HEAD and now live in `dartclaw_core` (`packages/dartclaw_storage`, `packages/dartclaw_server`, and `apps/dartclaw_cli/.../wiring/storage_wiring.dart` cited by the prior FIS are gone); `release_sqlite_check_command.dart`, which the prior allowlist named, is gone too. Code references (`packages/...`, `apps/...`, `dev/...`, `docs/guide/...`) are paths inside `../dartclaw-public/`._

## Feature Overview and Goal

**Intent**: The two instance-local stores – active-turn crash-recovery state in `state.db` and the webhook dedup ledger in `webhook_deliveries.db` – are serve-process-only, small, transient, and single-writer, so their SQLite leg carries no load yet keeps a PostgreSQL deployment touching SQLite at runtime and forces the import census to sanction two exceptions (TD-115); replacing the mechanism with plain files, with the locality rationale of ADR-045 decisions #3/Q4 intact, removes that leg without changing what any consumer observes.

**Expected Outcomes**:

- [OC01] Orphan-turn crash recovery behaves identically from `<dataDir>/turn_state.json`: the same recovered-session list and per-orphan warnings, still before the backend gate, with `state.db` no longer created and a leftover one ignored.
- [OC02] Webhook replay protection behaves identically from `<dataDir>/webhook_deliveries/`: the same three-outcome reservation machine (`reservedNew`, `reservedReclaimed`, `duplicate`) plus the `releasePending` transition, TTL purge, and anchor-moves-forward-on-commit rule, with `webhook_deliveries.db` no longer created and a leftover one ignored.
- [OC03] Interrupted writes, crashes between operations, purge races, and hostile delivery ids never corrupt either store or escape its directory, on POSIX and on Windows.


## Required Context

- `docs/specs/0.26/plan.json#sharedDecisions` – decision "DatabaseBackend seam shape and placement under the 0.25 topology": storage implementations live in `packages/dartclaw_core/lib/src/storage/`; two-sided LOC ceiling for `dartclaw_core` (27705), 1500/1300-line file caps, explicit barrel `show` clauses.
- `docs/specs/0.26/prd.md#fr13-filesystem-backed-instance-local-state-rider-2026-08-07--td-115` – the acceptance clauses this FIS proves; two are relocated by owner decision: the PostgreSQL zero-runtime-SQLite integration test executes in story S10 (see the DECISION NOTE under Implementation Observations), and the FR10 storage-tiers table is authored by story S12, which depends on this story. The clause's "sqlite-specific release tooling" carve-out is void at 0.25 – that command no longer exists.
- `docs/specs/0.26/prd.md#decisions-log` – rider row (owner 2026-08-07): why plain files win over instance-local SQLite and over the shared database.
- `docs/specs/0.26/s06-composition-root-wiring-and-census-closure.md#technical-overview` – step 9: wiring calls `openTurnStateStore(path)` store-side and closes what it opens; this story changes the path and the file behind that call, not the call shape or its fatal posture.
- `docs/specs/0.26/s06-composition-root-wiring-and-census-closure.md#structural-criteria` – SC01/SC02: the three-file `package:sqlite3` census (`sqlite_backend.dart`, `turn_state_store.dart`, `webhook_delivery_store.dart`) this story reduces to one; SC07: the gate's allowlist location, rationale format, and stale-entry check.
- `docs/specs/0.26/s06-composition-root-wiring-and-census-closure.md#implementation-tasks` – TI09: the gate file, its three-entry allowlist, and the README sentence promising that the two store entries leave when the stores move to the filesystem.
- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#decided-posture--contracts-owner-accepted-2026-07-24` – decision #3 (ledger stays instance-local SQLite, "same reasoning as `state.db`"); `#resolved-questions-2026-07-01` Q4 (`state.db` stays instance-local SQLite: per-instance semantics, recovery independent of the network database). This story amends the mechanism sentences of both and leaves the rationale.
- `../dartclaw-public/dev/state/TECH-DEBT-BACKLOG.md#td-115--residual-sqlite-on-postgresql-deployments-statedb--webhook-ledger` – the item this story closes; its status line and affects-list were corrected 2026-09-03 to point at this story and at `packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart`, so closure here only adds the `CLOSED <date>` status.
- `../dartclaw-public/dev/state/TECH-DEBT-BACKLOG.md#td-135--the-unit-suite-cannot-execute-on-windows-while-windows-semantics-tests-live-inside-it` – why Windows evidence needs its own proof path: source-mode `dart test` on Windows dies at the first `sqlite3` FFI call, not at import (`process_lifecycle_test.dart`, which opens no database, passes there). Both store suites are sqlite-free after this story, so they run on the Windows VM.
- `../dartclaw-public/dev/state/LEARNINGS.md#storage--data-model` – "Webhook pending-state TTL must move forward on successful commit" (the parity gate for the dedup store); "A write that becomes read-modify-write needs `secureWriteFile`" (the sanctioned temp-flush-rename helper); "Parse-then-rewrite makes a lenient parser destructive" (an unparseable state file is quarantined, never rewritten).
- `../dartclaw-public/dev/state/LEARNINGS.md#testing` – "Fixtures built by the code under test never exercise its parser" (torn and corrupt fixtures are raw literals); "Bound-asserting tests must enumerate the set".
- `../dartclaw-public/dev/state/LEARNINGS.md#workflow-engine` – "Multi-flag idempotency persists are crash-windows": each marker carries one phase field, `state`, never two flags.
- `../dartclaw-public/dev/state/LEARNINGS.md#tooling--verification` – `dart test` runs suites as isolates in one process (temp dirs by path, never `Directory.current`); nested `dart run` readiness budgets (the crash smoke test); workspace-root `dart pub get` after any pubspec change; a `.ps1` interpolating `$name:` needs `${name}`.
- `docs/specs/0.26/launch-context.md#live-storage-baseline` – the live instance-local store mechanisms, wiring, and rider baseline that supersede both temporary re-plan audits; current store code remains authoritative for method-level behavior.


## Deeper Context

- `docs/specs/0.26/plan.json#stories` – S10 consumes this story's filesystem turn state for recovery-before-gate and carries the relocated serve-run probe; S12 authors the storage-tiers table; S14 (sibling rider) renames `tasks.db` and touches neither store.
- `docs/specs/0.26/s10-startup-interlock-and-backend-switch-semantics.md#acceptance-scenarios` – S07 (orphan evidence survives an aborted PostgreSQL boot) and S08 (SQLite-free serve run): the receiving surface for the relocated proofs; S10 is refreshed after this FIS and re-resolves its `turn_state.json` references.
- `../dartclaw-public/dev/architecture/control-protocol.md#turn-level-recovery-statedb` and `../dartclaw-public/dev/architecture/session-state-architecture.md#turnstatestore` – the mechanism descriptions (with the SQL DDL) this story rewrites; S10's Deeper Context anchors the first and re-resolves after the heading changes.
- `../dartclaw-public/dev/architecture/data-model.md#overview`, `#by-access-pattern`, `#recovery` – the data-dir tree, the access-pattern table (`state.db` under relational queries), and the corruption-recovery row.
- `../dartclaw-public/docs/guide/architecture.md#sqlite` and `#crash-recovery`; `../dartclaw-public/docs/guide/workspace.md`; `../dartclaw-public/dev/architecture/system-architecture.md`; `../dartclaw-public/dev/state/STACK.md` – the remaining `state.db` mentions.
- `../dartclaw-public/dev/fitness/test/_internal/fitness_test_utils.dart#readAllowlist` – allowlist parsing and `assertNoStaleEntries`, the reason the two retired entries must be deleted, not left.
- `../dartclaw-public/dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md#parallels-windows-vm` – `parallels_windows.sh powershell <host script> [args]` translates the host script path into the guest; the Windows proof runs through it.


## Acceptance Scenarios

- **S01 [OC01] [TI01] Turn state round-trips through `turn_state.json` behind the unchanged API**
  - **Given** a store opened with `openTurnStateStore(<dir>/turn_state.json)` on an empty directory
  - **When** `set` is called for two sessions in descending id order, one is overwritten with a new turn id, and one is deleted
  - **Then** `getAll()` returns the surviving record with the newer turn id and start time, keys in ascending session-id order, read from the file on every call (a record written by a second store instance on the same path is visible without reopening), and a `set` whose future is not awaited is already in the file when the call returns
  - **Proof**: `packages/dartclaw_core/test/storage/turn_state_store_test.dart#set and getAll round-trip` – green – parity/regression (the suite's three SQLite-schema and dispose cases are replaced by TI01's filesystem cases)

- **S02 [OC01] [TI03] [runtime] Orphan recovery across a real process crash is unchanged, and no SQLite file appears**
  - **Given** the crash fixture pair (`crash_turn_process.dart`, `crash_recovery_smoke_test.dart`) with their store construction changed to the filesystem path and nothing else, and a stale `state.db` copied into the data dir beforehand
  - **When** the child serves a turn, is killed, and is restarted against the same data dir
  - **Then** the restart reports exactly the one orphaned session, the test process's own store instance observes the child's write and then the empty store, the one-time recovery banner renders once, the stale `state.db` is byte-identical afterwards, and the data dir holds `turn_state.json` and no `state.db-wal`/`-shm` or new `state.db`
  - **Final verification**: `dart test --reporter=failures-only --run-skipped -t integration packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart --name "reserve/start crash leaves one orphan that restart cleanup clears with one recovery notice"` – pending the final combined gate under the owner scheduling override; recorded as S15/S02 in `deferred-live-platform-proofs.json`.

- **S03 [OC03] [TI01] An interrupted or corrupted turn-state file never breaks recovery**
  - **Given** a directory holding a leftover `turn_state.json.<suffix>.tmp` from a killed write, and separately a `turn_state.json` whose bytes are not a JSON object (raw literal fixture)
  - **When** `openTurnStateStore` runs, then `set` and `getAll`
  - **Then** the `.tmp` file is deleted at open; the unparseable file is moved aside to `turn_state.json.corrupt-<utc-timestamp>` with one warning naming it, the store starts empty, and the subsequent `set` and `getAll` succeed; a file made unreadable after open makes `set`/`getAll` throw so the existing call-site warnings fire, as today's store failure does

- **S04 [OC02] [TI02] The three-outcome reservation machine, the `releasePending` transition, and the TTL anchor survive the filesystem store**
  - **Given** a store opened on `<dir>/webhook_deliveries/` with an injected clock, a stale `webhook_deliveries.db` beside the directory, and a marker in `pending` state older than `stalePendingAfter`
  - **When** the same id is reserved again, committed, the clock advances past the purge interval, and another id is reserved
  - **Then** the reservation reports `reservedReclaimed` (not `duplicate`), the commit resets both `inserted_at` and `updated_at`, the purge after commit leaves the marker in place, a further reservation of the id reports `duplicate`; a fresh `pending` marker reports `duplicate`; a released pending marker leaves no file so a retry is `reservedNew`; a `processed` marker older than the 7-day TTL is deleted by the next purge; the leftover `.db` file is untouched and never opened
  - **Proof**: `packages/dartclaw_core/test/storage/webhook_delivery_store_test.dart#stale pending is reclaimed and commit refreshes the TTL anchor` – green – parity/regression (its SQL `UPDATE` aging becomes clock injection; the handler-level parity case `github_webhook_test.dart#accepted run stays deduped after processed-state commit failure and pending reclaim`, green at HEAD, is bound by TI03's Verify)

- **S05 [OC03] [TI02] A torn or bodyless marker is reclaimable, never delivered**
  - **Given** a marker file for an id whose body is empty, and another whose body is truncated JSON (both raw literal fixtures, as a crash between claim and body write leaves them), and a leftover `<name>.<suffix>.tmp` in the directory
  - **When** the store is opened and each id is reserved
  - **Then** both reservations report `reservedReclaimed` and the markers now carry a complete `pending` body, the `.tmp` file was swept at open and is never listed as a marker, and no other marker was modified

- **S06 [OC03] [TI02] Hostile and case-variant delivery ids stay inside the marker directory**
  - **Given** delivery ids `../../pwned`, a 400-character id, `CON`, `Abc-1` and `abc-1`
  - **When** each is reserved and committed
  - **Then** every marker is a file directly inside `webhook_deliveries/` named by the lowercase SHA-256 hex of the id, nothing outside the directory is created or modified, no `FileSystemException` escapes, and the two case-variant ids are two distinct `processed` markers on a case-insensitive filesystem

- **S07 [OC03] [TI05] [runtime] Both stores behave under Windows file semantics**
  - **Given** the two store suites run on the Windows VM in source mode
  - **When** a `processed` marker older than the TTL is held open by a `RandomAccessFile` while a reservation triggers purge, and separately a commit rewrites an existing marker and a turn-state `set` rewrites `turn_state.json`
  - **Then** on Windows the held marker survives, the reservation completes without throwing, and every other stale marker is deleted (on POSIX the held marker is deleted too – the same test asserts per platform); both rename-over-existing writes succeed; every other case in both suites passes on Windows


## Structural Criteria

- **SC01** `TurnStateStore` keeps `set`, `delete`, `getAll`, and `dispose` with their current signatures and `Future` types, `openTurnStateStore(String path)` is its only construction path, and `turn_runner.dart`, `turn_runner_cancellation.dart`, and `github_webhook.dart` are byte-identical to before this story.
- **SC02** `WebhookDeliveryStore` keeps `reservePending(id, {stalePendingAfter})`, `commitProcessed`, `releasePending`, and the three-outcome `WebhookDeliveryReservation` (`reservedNew`, `reservedReclaimed`, `duplicate`) unchanged; `registerIfNew` (no production consumer) and `openWebhookDeliveryStoreInMemory` are gone; `openWebhookDeliveryStore(String directoryPath, {DateTime Function()? now})` is the construction path.
- **SC03** Layout: `<dataDir>/turn_state.json` is one JSON object keyed by session id; `<dataDir>/webhook_deliveries/<sha256-hex>` markers carry a JSON body with exactly `state`, `inserted_at`, `updated_at`; temp files end in `.tmp`, are never listed as markers, and are swept at open; neither store creates a `.db` file or opens `package:sqlite3`.
- **SC04** Every rewrite of an existing file in either store goes through `secureWriteFileSync(…, restrictPermissions: false)` (flush, then rename); turn-state mutation bodies are synchronous end to end (decision D1, Execution Contract); a marker claim is `createSync(exclusive: true)`.
- **SC05** The production `package:sqlite3` importer census over `packages/` and `apps/` (tests excluded) is exactly `packages/dartclaw_core/lib/src/storage/sqlite_backend.dart`; the gate allowlist has one entry; `storage_wiring.dart` and `server.dart` contain no `state.db` or `webhook_deliveries.db` literal; `dartclaw_core` declares `crypto`.
- **SC06** ADR-045 decisions #3 and Q4 carry a dated mechanism amendment with the locality rationale unchanged; TD-115 is marked closed with the `docs/specs/0.26/` pointer and the `dartclaw_runtime` wiring path; the architecture docs, user guide, and STACK name `turn_state.json` and `webhook_deliveries/`, with `state.db` and `webhook_deliveries.db` surviving only as leftover-deletable notes; each touched architecture doc's "Current through" marker is bumped.
- **SC07** Workspace analysis, `bash dev/tools/test_workspace.sh`, `bash dev/tools/fitness/run_all.sh`, `dart run dev/tools/arch_check.dart`, and `git diff --check` are green; no test file exceeds 1300 lines; `dev/testing/.gitignore` ignores the new artifacts and no longer re-includes `profiles/visual/data/state.db`, which is deleted.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_core/lib/src/storage/turn_state_store.dart` – filesystem reimplementation behind the existing API; `pubspec.yaml` of `dartclaw_core` gains `crypto` (TI01, TI02)
- `packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart` – file-per-id reimplementation with the reservation machine; `packages/dartclaw_core/lib/dartclaw_core.dart` `show` clauses (TI02)
- Construction sites: `packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart` (step 9 path), `packages/dartclaw_runtime/lib/src/server.dart` (webhook store directory), the two crash fixtures, `packages/dartclaw_runtime/test/api/github_webhook_test.dart`, and nine other `dartclaw_runtime` suites that construct `TurnStateStore` directly – one (`turn_runner_timeout_context_test.dart`) via `TurnStateStore(sqlite3.openInMemory())`, eight via a named `Database` variable (`turn_runner_test.dart`, `turn_contract_threading_test.dart`, `turn_runner_daily_log_test.dart`, `turn_runner_acp_test.dart`, `turn_manager_test.dart`, `turn_runner_rate_limit_test.dart`, `turn_runner_budget_test.dart`, `turn_runner_loop_detection_test.dart`) – `rg -l 'TurnStateStore\(' packages --glob '**/test/**'` is the inventory (12 files total, also matching this story's own `turn_state_store_test.dart` suite and the two crash fixtures already named) (TI03)
- Store suites: `packages/dartclaw_core/test/storage/turn_state_store_test.dart`, `webhook_delivery_store_test.dart` – filesystem, fault-injection, hostile-id, and Windows cases; `dev/tools/run_windows_tests.ps1` and `dev/tools/parallels_windows.sh` for the Windows run (TI01, TI02, TI05)
- Fitness: `dev/fitness/test/allowlist/sqlite3_import_surface.txt`, `dev/fitness/README.md` (TI04)
- Docs and records: `dev/adrs/045-pluggable-database-backend.md`, `dev/state/TECH-DEBT-BACKLOG.md`, `dev/architecture/{data-model,control-protocol,session-state-architecture,system-architecture}.md`, `dev/state/STACK.md`, `docs/guide/{architecture,workspace}.md` (TI06)
- Test-data hygiene: `dev/testing/.gitignore`, `dev/testing/profiles/visual/data/state.db` (tracked fixture of the retired store) (TI07)

### What We're NOT Doing

_(`S<NN>` outside `## Acceptance Scenarios` names a plan story; inside it, a scenario ID.)_

- The `tasks.db` → `dartclaw.db` rename, its adoption step, and the either-name presence helper – story S14 (the other half of the split); `search.db` and PostgreSQL are untouched here.
- The PostgreSQL serve-run probe proving zero SQLite operations, and the recovery-before-gate leg with PostgreSQL unreachable – story S10, by the owner decision recorded under Implementation Observations; at this story's position no `database.backend: postgres` path exists.
- The storage-tiers-at-a-glance table – story S12 depends on this story and authors the deployment guide it lives in.
- Migrating leftover `state.db` / `webhook_deliveries.db` contents – transient data (recovery state is meaningful across one crash-restart; markers expire in 7 days); leftovers are ignored and documented as deletable.
- Resolving TD-135 (a Windows-capable unit suite or sqlite provisioning) – this story proves its own two suites on the VM because they no longer touch SQLite; the suite-wide decision stays with the backlog item.
- A glossary entry for either store – the S12 glossary sync covers the storage vocabulary once the milestone's names are final.


## Architecture Decision

**Approach**: Reimplement both stores in place behind their public methods – turn state as one whole-file JSON object rewritten atomically (temp, flush, rename) with synchronous mutation bodies; dedup as one file per delivery id named by SHA-256, claimed with an exclusive create and transitioned by atomic rewrite, purged on a bounded cadence – so every consumer, the crash fixtures, and the handler tests keep their assertions while the `package:sqlite3` import surface shrinks to `SqliteBackend`. See ADR: `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md` (decisions #3/Q4, mechanism amended by TI06).
**Why this over alternatives**: moving either store behind `DatabaseBackend` couples crash recovery and per-instance dedup to the network database's availability, which ADR-045 rejected and the PRD rider reaffirmed; an in-memory dedup set loses replay protection across restart; keeping the SQLite leg is exactly the smell TD-115 names.


## Technical Overview

| Store | On disk | Mutation | Read |
|---|---|---|---|
| Turn state | `<dataDir>/turn_state.json` – `{"<sessionId>": {"turnId": …, "startedAt": ISO-8601}}`; `{}` written at open when absent | `set`/`delete` read the file, apply, and rewrite via `secureWriteFileSync` synchronously – the returned future is already complete | `getAll` parses the file on every call and returns keys in ascending order |
| Webhook dedup | `<dataDir>/webhook_deliveries/<sha256-hex-of-id>` – `{"state": "pending"|"processed", "inserted_at": ISO, "updated_at": ISO}` | claim: `createSync(exclusive: true)` then write the body into the new file with `flush: true` (a crash between the two leaves a bodyless marker, read as a stale claim); reclaim/commit: rewrite via `secureWriteFileSync`; release: delete when `pending` or bodyless | `reservePending` parses the marker; bodyless or unparseable counts as `pending` older than `stalePendingAfter` |

Open (`openTurnStateStore(path)`, `openWebhookDeliveryStore(dir, {now})`) is synchronous: create the file or directory, delete `*.tmp` siblings, and for turn state validate the existing file – unparseable content is renamed to `turn_state.json.corrupt-<utc-timestamp>` with a warning. An unwritable location throws from open, which is wiring step 9's existing fatal path. `dispose()` on the turn-state store releases nothing and stays for the composition root's disposal order (the same no-op posture S06 gives `SqliteTaskRepository.dispose()`).

Purge runs inside `reservePending` on the first call after open and thereafter when at least one hour of the injected clock has passed since the last purge; it deletes `processed` markers whose `inserted_at` is older than 7 days, keeps `pending` and bodyless markers (today's SQL also purges only `processed` rows), skips a marker whose unlink fails and leaves it for the next cycle, and never sleeps or retries inside the synchronous API. `commitProcessed` on an unknown id creates the marker (today's upsert).


## Code Patterns & External References

```
# type | path#anchor                                                                                          | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/turn_state_store.dart#TurnStateStore        | the API and semantics to preserve: upsert on set, ORDER BY session_id ASC in getAll, Future-returning surface
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart#reservePending  | the three-outcome machine plus the releasePending transition, stalePendingAfter measured on updated_at, both timestamps reset by commitProcessed
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/atomic_write.dart#secureWriteFileSync      | the sanctioned temp-flush-rename helper (restrictPermissions: false preserves mode and spawns no chmod); its .<rand>.tmp naming is the sweep pattern
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/kv_service.dart#KvService                    | whole-file JSON document store shape (read, apply, atomic rewrite)
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/api/github_webhook.dart#GitHubWebhookHandler     | the only dedup consumer: x-github-delivery is non-empty-checked only; reservedNew/reservedReclaimed/duplicate/releasePending branching stays
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/turn_runner_cancellation.dart#detectAndCleanOrphanedTurns | orphan scan: getAll then delete per orphan, errors swallowed with a warning – the observable outcome S02 preserves
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring.wire   | step 9: the open call, the fatal failure path, dispose order
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/server.dart#_buildGitHubWebhookHandler           | the ledger self-open site (dataDir-guarded) that becomes a directory open
file   | ../dartclaw-public/packages/dartclaw_runtime/test/integration/_fixtures/crash_turn_process.dart#main | crash fixture whose assertions must hold with only its store construction changed
file   | ../dartclaw-public/dev/fitness/test/allowlist/config_key_consumers.txt                                 | allowlist line format (`<key>  # <rationale>`)
file   | ../dartclaw-public/dev/tools/parallels_windows.sh#usage                                                | `powershell <host script> [args]` – the Windows proof runner
```


## Constraints & Gotchas

- **Critical**: atomicity is rename-based and the helper already flushes: `secureWriteFileSync` writes the temp file, `flushSync`, closes, then `renameSync` over the target – the prior FIS's "the helper does not flush" note is stale at 0.25. The un-fsynced directory entry is the accepted residual: the guarantee is crash-atomicity (no torn read after process death), not power-loss durability, which the SQLite stores' default `synchronous` did not fully give either.
- **Critical**: the Windows exposure is not rename-over-existing (Dart's `rename` uses `MOVEFILE_REPLACE_EXISTING`, and `atomicWriteJson` already ships that on the Windows release baseline). It is that Windows refuses to delete or rename a file another handle holds open without `FILE_SHARE_DELETE`, which `dart:io` never sets. Only purge can meet a foreign handle (backup or antivirus tooling); it skips and moves on. Within the serve process nothing holds a marker open across a purge, because every read is `readAsStringSync`.
- **Constraint**: the marker name is the lowercase SHA-256 hex of the delivery id (`package:crypto`, added to `dartclaw_core`'s pubspec – `dependency_direction_test` requires declared and imported dependencies to match). The header is unsigned (the HMAC covers the body only) and unvalidated beyond non-empty; raw use admits traversal, over-length name components, Windows reserved names, and case-folding collapse on APFS/NTFS. Hex is length-fixed and case-free.
- **Constraint**: both timestamps live in the marker body, not filesystem metadata: purge keys on `inserted_at`, staleness on `updated_at`, and `commitProcessed` resets both – conflating them reintroduces the LEARNINGS trap (marker purged right after reclaim-then-commit). mtime is unfit as a semantic carrier (coarse on some filesystems, rewritten by copy and restore tools).
- **Constraint**: the dedup API is synchronous today and stays synchronous; every filesystem call in that store is the `Sync` variant, and no sleep, retry loop, or `Future` enters it. The clock is injected (`now`) so staleness, TTL, and purge cadence are tested without editing files.
- **Constraint**: tests build stores in a per-test `Directory.systemTemp.createTempSync` deleted in `tearDown`; never `Directory.current`. Corrupt, torn, and bodyless fixtures are written as raw string literals, not through the store.
- **Constraint**: two-sided LOC ratchet (`dev/tools/arch_check.dart`): `dartclaw_core` measured 26269 of 27740 on 2026-09-02 before S06's deletions; this story replaces two files at roughly equal size – apply any downward re-cut `arch_check` reports, never a silent raise. Run `dart pub get` at the workspace root after the pubspec edit.
- **Constraint**: comments are rationale-only and carry no story IDs; the ADR amendment, backlog closure, and README are development documents and may name the story.


## Implementation Plan

### Implementation Tasks

- **TI01** Turn state is a whole-file JSON store with synchronous, durable-at-return mutations
  - `turn_state_store.dart` implements Technical Overview row 1 and the open behaviour (create `{}`, sweep `*.tmp`, quarantine an unparseable file with one warning, throw on an unwritable path); `openTurnStateStore(String path)` is the constructor path; `dispose()` is a documented no-op; no `package:sqlite3` import. `turn_state_store_test.dart` replaces its schema, WAL, and dispose cases with: round-trip and ascending order, cross-instance visibility, not-awaited `set` already on disk, `.tmp` sweep, corrupt-file quarantine (raw literal), post-open unreadable file throwing.
  - **Verify**: `cmd: ! rg -q "sqlite3" packages/dartclaw_core/lib/src/storage/turn_state_store.dart && rg -q "TurnStateStore openTurnStateStore\(String path\)" packages/dartclaw_core/lib/src/storage/turn_state_store.dart && rg -q "secureWriteFileSync" packages/dartclaw_core/lib/src/storage/turn_state_store.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/turn_state_store_test.dart` – no driver, the pinned open signature, the sanctioned writer, and the suite proves S01 (order, re-read, durable at return) and S03 (sweep, quarantine sibling named `turn_state.json.corrupt-`, recovery continues, post-open failure throws)
  - **SATISFIES**: S01, S03, SC01, SC03, SC04

- **TI02** Webhook dedup is a file-per-id store with the reservation machine and TTL anchor intact
  - `webhook_delivery_store.dart` implements Technical Overview row 2, the open behaviour, the purge cadence, and the injected clock; `registerIfNew` and `openWebhookDeliveryStoreInMemory` are deleted, the barrel `show` clause follows; `crypto` is declared in `packages/dartclaw_core/pubspec.yaml`. `webhook_delivery_store_test.dart` rewrites the `registerIfNew` and legacy-row cases onto `reservePending`/`commitProcessed`, ages markers through the clock, and adds the S05 torn/bodyless/`.tmp` cases, the S06 id set, and the purge-under-open-handle case with per-platform assertions (S07). Depends on TI01 for nothing; independent.
  - **Verify**: `cmd: ! rg -q "sqlite3|registerIfNew|openWebhookDeliveryStoreInMemory" packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart packages/dartclaw_core/lib/dartclaw_core.dart && rg -q "createSync\(exclusive: true\)" packages/dartclaw_core/lib/src/storage/webhook_delivery_store.dart && rg -q "^  crypto:" packages/dartclaw_core/pubspec.yaml && dart test --reporter=failures-only packages/dartclaw_core/test/storage/webhook_delivery_store_test.dart` – no driver or dead surface, the exclusive claim, the declared dependency, and the suite proves S04 (all three outcomes plus the `releasePending` transition, anchor refresh, TTL deletion, leftover `.db` untouched), S05, S06, and the POSIX branch of S07
  - **SATISFIES**: S04, S05, S06, SC02, SC03, SC04

- **TI03** Every composition site and test constructs the stores by path, and the crash fixtures pass unchanged
  - `storage_wiring.dart` step 9 opens `p.join(dataDir, 'turn_state.json')` through `openTurnStateStore` with its fatal posture and dispose order unchanged (log text names the turn state store, not a database); `server.dart` opens `p.join(dataDir, 'webhook_deliveries')`; the crash fixtures, `github_webhook_test.dart` (its `_CommitFailingWebhookDeliveryStore` subclass takes a directory), and the nine other `dartclaw_runtime` suites that construct `TurnStateStore` directly switch to `openTurnStateStore(<tempDir>/turn_state.json)`, dropping `package:sqlite3` imports that served only these stores. Depends on TI01, TI02. TI01's `openTurnStateStore(String path)` as the sole constructor (SC01) makes the eight suites still on the retired `TurnStateStore(<Database>)` form fail to compile if left unconverted, so the Verify's grep needs only catch the one still-`sqlite3`-literal suite; `dart test packages/dartclaw_runtime` is what catches the rest.
  - **Verify**: `cmd: ! rg -q "state\.db|webhook_deliveries\.db|sqlite3" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart packages/dartclaw_runtime/lib/src/server.dart packages/dartclaw_runtime/test/integration/_fixtures/crash_turn_process.dart packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart && ! rg -q "TurnStateStore\(sqlite3|openWebhookDeliveryStoreInMemory" packages apps && git diff --quiet -- packages/dartclaw_runtime/lib/src/turn_runner.dart packages/dartclaw_runtime/lib/src/turn_runner_cancellation.dart packages/dartclaw_runtime/lib/src/api/github_webhook.dart && dart test --reporter=failures-only packages/dartclaw_runtime && dart analyze --fatal-infos packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart` – no `.db` literal or driver at the sites, no SQLite-built store anywhere, the three consumers untouched, the runtime suite green, and the smoke test proves S02 (one recovered session, empty store after, banner once) with a stale `state.db` seeded in `setUp` and asserted byte-identical; the grep's `TurnStateStore\(sqlite3` clause covers the one literal construction site and the compile break covers the remaining eight, per this task's description
  - **SATISFIES**: S02, SC01, SC05

- **TI04** The import gate sanctions `SqliteBackend` alone
  - Delete the two store lines from `dev/fitness/test/allowlist/sqlite3_import_surface.txt` (S06 TI09), leaving the backend entry with its rationale; rewrite the README section's tightening sentence to describe the single entry. Depends on TI01, TI02.
  - **Verify**: `cmd: test "$(grep -cv '^\s*#\|^\s*$' dev/fitness/test/allowlist/sqlite3_import_surface.txt)" = 1 && test "$(rg -l "import 'package:sqlite3" packages apps --glob '!**/test/**' --glob '!**/*_test.dart' | tr '\n' ' ')" = "packages/dartclaw_core/lib/src/storage/sqlite_backend.dart " && rg -q "sqlite_backend\.dart" dev/fitness/README.md && ! rg -q "turn_state_store\.dart|webhook_delivery_store\.dart" dev/fitness/README.md && dart test --reporter=failures-only dev/fitness/test/sqlite3_import_surface_test.dart` – one allowlist line, the importer census is exactly the backend file, the README's gate section names only `sqlite_backend.dart` and no longer names either retired store, and the gate (including its stale-entry assertion) passes
  - **SATISFIES**: SC05

- **TI05** Both store suites pass on Windows through a repeatable runner
  - Add `dev/tools/run_windows_tests.ps1`: resolves the repo root from `$PSScriptRoot`, runs `dart test --reporter=failures-only` over the test paths given as arguments, exits with dart's code (`${var}` interpolation; parsed by the CI PowerShell job). Run it on the VM through `parallels_windows.sh powershell` and record the run's output summary in Implementation Observations. Depends on TI01, TI02.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/turn_state_store_test.dart packages/dartclaw_core/test/storage/webhook_delivery_store_test.dart` – exit 0 with both suites passing on Windows, including the purge-under-open-handle case in its Windows branch (S07)
  - **SATISFIES**: S07

- **TI06** The decision record, backlog, and docs describe the filesystem mechanism
  - ADR-045: dated amendment to decision #3 and Resolved Q4 (mechanism now files, locality rationale unchanged, TD-115, owner 2026-08-07) plus a Status-line entry, and the Neutral consequence naming `state.db` as SQLite updated. TD-115: status `CLOSED <date>` in the TD-065 style; pointer (`docs/specs/0.26/s15-filesystem-backed-instance-local-state.md`) and affects-list (`packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart`) are already correct as of 2026-09-03, so this task only sets the status. Docs: `data-model.md` (tree, access-pattern rows – turn state under atomic documents, markers as a new row – package diagram, recovery row), `control-protocol.md` (turn-level recovery section retitled and rewritten without SQL; steps ③ and ㉓), `session-state-architecture.md` (diagram and `TurnStateStore` section), `system-architecture.md` (diagram, storage table, startup list), `STACK.md` SQLite row, `docs/guide/architecture.md` (tree, SQLite table, crash-recovery paragraph, plus one sentence that leftover `state.db`/`webhook_deliveries.db` files are ignored and may be deleted), `docs/guide/workspace.md`; bump each architecture doc's "Current through". Public-repo dev-doc edits executed in-milestone.
  - **Verify**: `cmd: rg -q "turn_state\.json" dev/adrs/045-pluggable-database-backend.md dev/architecture/data-model.md dev/architecture/control-protocol.md dev/architecture/session-state-architecture.md dev/architecture/system-architecture.md dev/state/STACK.md docs/guide/architecture.md docs/guide/workspace.md && rg -q "webhook_deliveries/" dev/adrs/045-pluggable-database-backend.md dev/architecture/data-model.md docs/guide/architecture.md && rg -q "TD-115 – CLOSED" dev/state/TECH-DEBT-BACKLOG.md && rg -q "specs/0.26/s15-filesystem-backed-instance-local-state" dev/state/TECH-DEBT-BACKLOG.md && ! rg -q "CREATE TABLE.*turn_state|instance-local SQLite always" dev/architecture/control-protocol.md dev/architecture/session-state-architecture.md dev/adrs/045-pluggable-database-backend.md && test "$(rg -c "state\.db" dev/architecture docs/guide dev/state/STACK.md | rg -v ':0$' | wc -l | tr -d ' ')" -le 2` – every named doc names the new files, the backlog item is closed with the corrected pointer, no doc carries the SQL DDL or the "SQLite always" wording, and `state.db` survives in at most the guide's leftover note and data-model's recovery row
  - **SATISFIES**: SC06

- **TI07** Test data and the workspace gates are clean
  - `git rm dev/testing/profiles/visual/data/state.db` and drop its `!profiles/visual/data/state.db` re-include; add `turn_state.json*` and `webhook_deliveries/` to `dev/testing/.gitignore` beside `state.db*` (in-place profiles write to the tracked tree). Apply any `arch_check` downward re-cut. Depends on TI01–TI06.
  - **Verify**: `cmd: ! git ls-files --error-unmatch dev/testing/profiles/visual/data/state.db 2>/dev/null && rg -q "^turn_state\.json\*$" dev/testing/.gitignore && rg -q "^webhook_deliveries/$" dev/testing/.gitignore && dart analyze --fatal-infos && dart run dev/tools/arch_check.dart && git diff --check` – fixture gone, ignores present, and analysis, the workspace suite, the fitness suite (including the tightened gate and the 1300-line cap), the LOC band, and the whitespace check are green
  - **SATISFIES**: SC07

### Testing Strategy

- [TI01, TI02] Layer 1 against real temp directories: outcomes are observed through the public API and the on-disk bytes (file names, JSON bodies, sibling files), never private state; failure fixtures are raw literals so the parser is exercised on foreign input.
- [TI02] The clock seam replaces the SQL `UPDATE` aging in the current suite; purge cadence is exercised by advancing the clock past one hour, not by exposing an interval parameter.
- [TI03] Bound Proofs are parity: assertions stay, construction changes; the smoke test additionally seeds a stale `state.db` to prove the leftover-ignore clause across a real restart.
- [TI05] The Windows run is the only proof for S07's Windows branch; the same test's POSIX branch runs in the workspace suite so the case cannot silently vanish.

### Validation

- From `../dartclaw-public/`: `dart test --reporter=failures-only --run-skipped -t integration packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart` (the workspace suite skips it), then TI07's gate list, then one `plain` testing-profile smoke from a freshly built CLI (`dev/testing/README.md`) confirming the data dir holds `turn_state.json` and `webhook_deliveries/` and no new `.db`.

### Execution Contract

- Story S06 must be complete (`openTurnStateStore` exists, the gate and its three-entry allowlist exist, wiring holds no driver import). Story S14 is independent and may land in either order; neither touches the other's files. Order: TI01 and TI02 (independent) → TI03 → TI04 → TI05 → TI06 → TI07. All commands run from the `../dartclaw-public/` root.
- The public working tree may carry another session's uncommitted edits outside this story's Work Areas; touch only the files named there. `server.dart` is in that session's edit set at authoring time – rebase the one-line directory open onto its landed shape.
- **Resolved decision (owner, 2026-08-07) – D1: turn-state writes are synchronous.** `TurnStateStore` mutation bodies use synchronous `dart:io` (read, apply, `secureWriteFileSync`) so `set()` is durable at return, exactly as the SQLite `stmt.execute` body was. Every production call site is fire-and-forget (`turn_runner.dart` at turn start and release, `turn_runner_cancellation.dart` on cancel), so durability-at-return is the only shape that preserves the store's guarantee: an orphan record exists before a crash can happen. This keeps the method signatures and every consumer, restores exact crash parity, and makes a write-serialization chain unnecessary (synchronous calls on a single-threaded event loop cannot interleave). Cost accepted: one small blocking write at turn boundaries (ADR-045 Q4: turn-boundary frequency, not hot-path). Rejected: awaiting at call sites (changes consumers, forbidden here); async-with-chain (narrows the durability window – contradicts OC01/FR13 parity and weakens the product guarantee). Still valid at 0.25: the call sites are unchanged and the atomic-write and single-phase-field learnings reinforce it.
- PostgreSQL-dependent proofs execute in story S10 – see the DECISION NOTE below; do not add a `backend: postgres` path or probe here.
- If the Windows VM is unavailable at execution time, TI05 blocks rather than being attested by inspection: S07 is `[runtime]`.


## Final Validation Checklist

- A full SQLite-backend serve run creates neither `state.db` nor `webhook_deliveries.db`, and a data dir carrying stale copies of both starts cleanly with them untouched.
- No production or test file names `state.db` or `webhook_deliveries.db` except the smoke test's leftover fixture and the docs' leftover-deletable notes.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

#### DECISION NOTE: s14-pg-dependent-proofs-placement

Decision-Key: s14-pg-dependent-proofs-placement
Altitude: fis-local
Affected surface: this story's FR13 proofs (the SQLite-free serve-run probe, the PostgreSQL-unreachable recovery-ordering leg of scenario S02); S10 scenarios S07/S08 + TI07 (receiving surface)
Decision: the rider story stays ahead of the PostgreSQL stories; every proof requiring S07's `database.*` config or PostgresBackend executes in S10.
Rationale: at this story's position `database.backend: postgres` does not parse and PostgresBackend does not exist; S10 depends on this story and owns the boot-flow, abandoned-store, and unreachable-boot integration tests.
Evidence: owner ratified 2026-08-07 (preflight interview, `docs/specs/0.26/preflight-2026-08-07.md`); carried over from the former S14 FIS at the 2026-09-02 split with the key unchanged so S10's matching note still resolves.

### Run: 2026-09-08 14:19 UTC – repair-proof

#### DRIFT

- spec-stale: TI07 Verify target repaired | Stale targets: – | `cmd: ! git ls-files --error-unmatch dev/testing/profiles/visual/data/state.db 2>/dev/null && rg -q "^turn_state\.json\*$" dev/testing/.gitignore && rg -q "^webhook_deliveries/$" dev/testing/.gitignore && dart analyze --fatal-infos && bash dev/tools/test_workspace.sh && bash dev/tools/fitness/run_all.sh && dart run dev/tools/arch_check.dart && git diff --check` → `cmd: ! git ls-files --error-unmatch dev/testing/profiles/visual/data/state.db 2>/dev/null && rg -q "^turn_state\.json\*$" dev/testing/.gitignore && rg -q "^webhook_deliveries/$" dev/testing/.gitignore && dart analyze --fatal-infos && dart run dev/tools/arch_check.dart && git diff --check`

### Run: 2026-09-08 14:19 UTC – observations

2026-09-08 16:14 CEST owner scheduling override: one focused independent review and relevant checks per story. Full workspace and full fitness runs in task Verify commands are deferred to the final combined A+B gate, with no acceptance requirement removed. The retained command proves the story-local checks; prose referring to full-suite success describes final milestone evidence. Standard fast-tier closure remains; broad integration, platform and release verification run at the end.

### Run: 2026-09-08 17:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: ! rg -q "state\.db|webhook_deliveries\.db|sqlite3" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart packages/dartclaw_runtime/lib/src/server.dart packages/dartclaw_runtime/test/integration/_fixtures/crash_turn_process.dart packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart && ! rg -q "TurnStateStore\(sqlite3|openWebhookDeliveryStoreInMemory" packages apps && git diff --quiet -- packages/dartclaw_runtime/lib/src/turn_runner.dart packages/dartclaw_runtime/lib/src/turn_runner_cancellation.dart packages/dartclaw_runtime/lib/src/api/github_webhook.dart && dart test --reporter=failures-only packages/dartclaw_runtime && dart test --reporter=failures-only --run-skipped -t integration packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart` → `cmd: ! rg -q "state\.db|webhook_deliveries\.db|sqlite3" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart packages/dartclaw_runtime/lib/src/server.dart packages/dartclaw_runtime/test/integration/_fixtures/crash_turn_process.dart packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart && ! rg -q "TurnStateStore\(sqlite3|openWebhookDeliveryStoreInMemory" packages apps && git diff --quiet -- packages/dartclaw_runtime/lib/src/turn_runner.dart packages/dartclaw_runtime/lib/src/turn_runner_cancellation.dart packages/dartclaw_runtime/lib/src/api/github_webhook.dart && dart test --reporter=failures-only packages/dartclaw_runtime && dart analyze --fatal-infos packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart`

### Run: 2026-09-08 17:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI05 Verify target repaired | Stale targets: – | `cmd: bash dev/tools/parallels_windows.sh powershell dev/tools/run_windows_tests.ps1 packages/dartclaw_core/test/storage/turn_state_store_test.dart packages/dartclaw_core/test/storage/webhook_delivery_store_test.dart` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/turn_state_store_test.dart packages/dartclaw_core/test/storage/webhook_delivery_store_test.dart`

### Run: 2026-09-08 17:06 UTC – observations

Owner scheduling override: the updated Verify commands prove local implementation and compilation only. Live integration and Windows/platform acceptance remain PENDING at the final combined A+B gate. Original postponed commands are retained by the repair-proof observations and deferred-live-platform-proofs.json. Do not report those postponed behaviors or milestone release acceptance as passed from a local receipt. Named targeted scenario proofs, the driver feasibility spike and missing-DSN refusal checks remain runnable. Final full-suite evidence may cover duplicate/subset invocations only with explicit owner-to-result mapping; platform and contract-report variants remain distinct.

### Run: 2026-09-08 19:09 UTC – observations

spec-stale: S04 scenario Proof targets `stale pending is reclaimed and commit refreshes the TTL anchor` in webhook_delivery_store_test.dart. The filesystem rewrite replaced the old SQL-aging test named `committing reclaimed pending rows refreshes the dedupe TTL`; the new test retains stale pending reclaim, commit and dedup after purge, and directly verifies both refreshed timestamps. This is a selector correction, not an acceptance change. Installed ops repair-proof handles task Verify targets only; the scenario selector was changed exactly and is included in the focused review closure.

### Run: 2026-09-08 19:53 UTC – observations

2026-09-08 owner scheduling override reconciliation: S02 repeats TI03's real-process crash proof, already deferred to the final combined A+B gate. Its stale ordinary Proof selector ran without the required integration flags and found no tests. Mark S02 runtime and explicitly map it to the existing final crash-suite command (owners S10/TI04, S15/TI03, S15/S02). Acceptance assertions and the executable scenario remain unchanged; no runtime pass is claimed by local completion.

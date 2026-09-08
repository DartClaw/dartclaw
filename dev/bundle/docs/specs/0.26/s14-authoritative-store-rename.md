# FIS: Authoritative Store Rename

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S14

_Split and refreshed 2026-09-02 against released 0.25 (public HEAD `daf5125a`) from the 2026-08-07 FIS that covered this rider together with the filesystem-backed instance-local stores (now story S15). Version labels: 0.26 is this milestone (the PRD's FR12 text still carries its pre-renumber labels), released 0.25 is the compatibility baseline, so the supported transition is 0.25 → 0.26. Premise check: the store is still `tasks.db` (`DartclawConfig.tasksDbPath` in `dartclaw_kernel`), it is read at exactly three production sites, and 0.25 changed nothing this story touches – the drift audit marks the story paths-only. Retired names that appear in the prior FIS – `dartclaw_config`, `dartclaw_storage/CLAUDE.md`, `release_sqlite_check_command.dart`, `ServiceWiring`, `CliWorkflowWiring` – are gone from the tree and from this FIS. Code paths (`packages/...`, `apps/...`, `dev/...`, `docs/guide/...`) are inside `../dartclaw-public/`; every `cmd:` runs from that root._

## Feature Overview and Goal

**Intent**: The authoritative SQLite store is named `tasks.db`, a name that predates goals, agent executions, workflow runs, turn traces, and `kg_facts` and now misleads operators about what the file holds – this story renames it to `dartclaw.db` while the milestone's transition machinery exists, so the rename costs a released-0.25 operator nothing.

**Expected Outcomes**:

- [OC01] The authoritative SQLite store is `dartclaw.db` everywhere: fresh bootstrap creates it, and serve, the standalone workflow commands, `cleanup`, and `workflow status` all resolve it through one config accessor.
- [OC02] A released-0.25 data directory holding `tasks.db` is adopted automatically before any open for use – WAL checkpointed, one atomic rename, spent sidecars gone – with every committed row intact and no operator action.
- [OC03] Ambiguity and failure are loud: both files present refuses startup naming both with keep/remove guidance; a failed checkpoint or rename aborts before any open for use, with no committed data lost, no `dartclaw.db` created, and `tasks.db` still authoritative.
- [OC04] Store naming is truthful: gate refusals and open-failure diagnostics name the file on disk, and one presence helper reports a local authoritative store under either name, with or without data, without creating, opening for write, or renaming anything – the surface story S10's abandoned-store notice consumes.


## Required Context

- `docs/specs/0.26/plan.json#sharedDecisions` – decision "DatabaseBackend seam shape and placement under the 0.25 topology": the composition root is `DartclawRuntime.build` → `StorageWiring.wire()`, CLI commands reach stores only through injected factories, `dartclaw_core` is the only driver-bearing package, two-sided LOC ceilings, explicit barrel `show` clauses. Decision "Schema compatibility …": S14's renamed store consumes the S02 identity unchanged – the gate takes its store name from the caller.
- `docs/specs/0.26/prd.md#fr12-authoritative-store-rename--tasksdb--dartclawdb-rider-2026-08-07` – the acceptance contract this FIS seeds: one accessor, checkpoint-first automatic adoption (owner decision 2026-08-07), both-present refusal with keep/remove guidance, truthful store names in the FR2 gate and FR8 notice, doc sync (`data-model.md`, user-guide storage/backup references, glossary), failed rename aborts before open with the file-level error. **NOTICED**: the FR labels the transition "0.24 → 0.25"; read it as released 0.25 → 0.26 per the plan overview. The PRD amendment is owner-owned.
- `docs/specs/0.26/prd.md#edge-cases` – rows "0.24 data dir with `tasks.db` on first 0.25 start" (adopt, then FR2 adoption runs) and "Both `dartclaw.db` and legacy `tasks.db` present" (refuse, operator keeps one) fix the two postures; same label caveat.
- `docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md#technical-overview` – `prepareTasks(backend, storeName:)` classifies and adopts the schema; its refusal names the store by the caller-supplied name, which is why this story changes no gate code and passes the basename of the resolved path.
- `docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md#constraints--gotchas` – "refusal messages are assembled from the caller-supplied store name … never embed a path the caller did not pass (S14 renames the file)".
- `docs/specs/0.26/s06-composition-root-wiring-and-census-closure.md#technical-overview` – the post-S06 `wire()` table: step 8 opens the tasks store through `taskBackendFactory(config.tasksDbPath)` with fatal posture (close the search backend, log severe, `_exitFn(1)`); this story's adoption step slots immediately before it. Step 9 (`state.db`) is story S15's and stays untouched.
- `docs/specs/0.26/s06-composition-root-wiring-and-census-closure.md#implementation-tasks` – TI01 gives `SqliteBackend.open`/`openInMemory` (plain opens, no PRAGMAs) – the read-only sibling this story adds lives beside them; TI07 pins the five CLI sites: `serve`, `workflow run`, and the standalone lifecycle commands hand factories to `build`/`stageHeadless` and therefore open through `wire()`, while `workflow status --standalone` and `cleanup` open on their own – so the production open surface this story guards is exactly three call sites. TI09: the `package:sqlite3` import gate with its three-entry allowlist, which this story leaves at three.
- `docs/specs/0.26/s10-startup-interlock-and-backend-switch-semantics.md#technical-overview` – the content-table predicate the presence helper implements: non-empty means at least one row in `tasks`, `goals`, `workflow_runs`, or `kg_facts`; absent tables count as empty; a probe error is could-not-verify, never a failure; existing files open read-only and are never created.
- `../dartclaw-public/dev/state/LEARNINGS.md#storage--data-model` – "Durable knowledge graph facts belong in `tasks.db`" is a line this story updates to the new name; `../dartclaw-public/dev/state/LEARNINGS.md#tooling--verification` – testing-profile smoke runs must run from a fresh build, not a cached CLI snapshot, after storage changes.
- `docs/specs/0.26/launch-context.md` – the live authoritative-store path, wiring, CLI consumer and package topology, replacing temporary re-plan audit inputs.


## Deeper Context

- `docs/specs/0.26/prd.md#decisions-log` – the rider row: why rename now (pre-release, transition machinery exists) and the rejected alternatives.
- `docs/specs/0.26/plan.json#stories` – story S15's brief, the sibling rider: `state.db` and the webhook ledger leave the data directory there, not here.
- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md` – decision record; its `tasks.db` mentions denote the store under its pre-rename name (the PRD's terminology note) and are not edited by this story.
- `../dartclaw-public/dev/state/TECH-DEBT-BACKLOG.md#td-135--the-unit-suite-cannot-execute-on-windows-while-windows-semantics-tests-live-inside-it` – why no Windows unit run is required here.
- `../dartclaw-public/dev/testing/README.md` – profiles run against a writable temp copy of their seed directory; the visual profile's tracked seed store is renamed by TI04.


## Acceptance Scenarios

- **S01 [OC01] [TI01,TI03] A fresh data directory bootstraps under the new name**
  - **Given** an empty data directory (or one holding only an orphan `tasks.db-wal`/`tasks.db-shm` with no `tasks.db`)
  - **When** `dartclaw serve` starts, or `workflow status --standalone` / `cleanup` runs
  - **Then** `<dataDir>/dartclaw.db` is created and prepared by the S02 gate; no `tasks.db` is created; the orphan sidecars are ignored and left alone

- **S02 [OC02] [TI02,TI03] A released-0.25 store is adopted with WAL-resident data intact**
  - **Given** a data directory holding a populated exact-released-0.25 `tasks.db` in WAL mode whose latest committed task row lives only in `tasks.db-wal` (no checkpoint since the write), with `tasks.db-shm` present, and no `dartclaw.db`
  - **When** startup runs
  - **Then** before any open for use the WAL is checkpointed into the main file and one rename produces `dartclaw.db`; no `tasks.db`, `tasks.db-wal`, or `tasks.db-shm` remains; the S02 gate then adopts the schema (marker only) and the WAL-resident row is readable through the task repository; no operator action and no second store file

- **S03 [OC02] [TI02] Adoption without sidecars leaves the same content under the new name**
  - **Given** a data directory with only a clean-shutdown `tasks.db` (no `-wal`/`-shm`) and no `dartclaw.db`
  - **When** adoption runs
  - **Then** `tasks.db` no longer exists, `dartclaw.db` holds byte-identical page content, and a second adoption call is a no-op

- **S04 [OC03] [TI02,TI03] Both files present refuses before opening either**
  - **Given** a data directory holding both `dartclaw.db` and `tasks.db`
  - **When** startup runs (and separately `cleanup` and `workflow status --standalone`)
  - **Then** the process refuses before either file is opened; the error names both files with their byte sizes, states the store identity is ambiguous, and tells the operator to keep the file holding their data and remove or archive the other; neither file's bytes change; serve exits 1 through the existing fatal path, the CLI commands print the message and exit 1

- **S05 [OC03] [TI02] A failed checkpoint or rename aborts with committed legacy data intact**
  - **Given** a populated `tasks.db` and either (a) a data directory the process cannot write (rename refused by the OS) or (b) another connection holding the legacy store open so `PRAGMA wal_checkpoint(TRUNCATE)` reports busy
  - **When** adoption runs
  - **Then** it throws before any open for use; no `dartclaw.db` exists; `tasks.db` remains authoritative and all committed data remains readable; checkpointing may change the main file and sidecar bytes before refusal; the message carries the file-level error in case (a) and names the store as in use by another process in case (b)

- **S06 [OC04] [TI03,TI04] Refusals and diagnostics name the file on disk**
  - **Given** an adopted or fresh `dartclaw.db` the S02 gate refuses (for example a `goals` table without `max_tokens`)
  - **When** `wire()`, `cleanup`, and `workflow status --standalone` each hit the refusal
  - **Then** the gate's message names `dartclaw.db`, the wiring severe line names the `dartclaw.db` path, and the literal `tasks.db` appears in none of them

- **S07 [OC04] [TI02] The presence helper reports a store under either name without touching it**
  - **Given** a data directory holding a populated `tasks.db` (adoption not invoked), then one holding a populated `dartclaw.db`, then one holding an empty-schema `dartclaw.db`, then one holding both files, then an empty directory
  - **When** the presence helper probes each
  - **Then** it reports, respectively: present under `tasks.db` and non-empty; present under `dartclaw.db` and non-empty; present under `dartclaw.db` and empty; ambiguous naming both; absent – and in every case no file is created, renamed, or written (directory listing and every file's bytes unchanged), and a store whose content tables cannot be read yields could-not-verify rather than an exception. The startup-level form of this scenario (a `database.backend: postgres` boot never invokes adoption) executes in story S10 (owner decision 2026-08-07, see Implementation Observations).

- **S08 [OC01,OC02] [TI03] The maintenance command's existence probe respects adoption**
  - **Given** retention enabled and a data directory holding only a released-0.25 `tasks.db` with a terminal workflow run older than the retention window
  - **When** `dartclaw cleanup` runs
  - **Then** the store is adopted first, the run is pruned from `dartclaw.db`, and the command does not report "no store" or skip retention; a corrupt `dartclaw.db` still degrades to the retention-skipped warning and exit 1 exactly as today
  - **Proof**: `apps/dartclaw_cli/test/commands/cleanup_command_test.dart#a corrupt authoritative store degrades to a skip warning and exit 1 instead of crashing` – green – parity/regression (the degrade path; the adoption case is bound by TI03's Verify)


## Structural Criteria

- **SC01** `search.db` keeps its name and behavior; `state.db` and the webhook ledger are not touched (story S15 retires them); no PostgreSQL source or `database.*` config changes.
- **SC02** One accessor `DartclawConfig.dartclawDbPath` resolves `<dataDir>/dartclaw.db`; `tasksDbPath` exists nowhere under `packages/`, `apps/`, `dev/`, or `docs/`; the literal `tasks.db` appears in production code only inside the adoption module, and in `dartclaw_testing` nowhere.
- **SC03** The `package:sqlite3` import surface is unchanged from story S06: the adoption module and the presence helper reach SQLite through `SqliteBackend` (a read-only open constructor added beside `open`/`openInMemory`), so `dev/fitness/test/allowlist/sqlite3_import_surface.txt` keeps exactly its three entries.
- **SC04** No tracked file named `tasks.db` remains; the visual profile's seed store is `dev/testing/profiles/visual/data/dartclaw.db` and `dev/testing/.gitignore` un-ignores it under the new name.
- **SC05** `dev/architecture/data-model.md`, `system-architecture.md`, `task-execution-architecture.md`, `observability-operations-architecture.md`, `configuration-architecture.md`, `docs/guide/{architecture,configuration,getting-started,workspace}.md`, `dev/state/STACK.md`, `dev/state/LEARNINGS.md`, and `packages/dartclaw_core/CLAUDE.md` name `dartclaw.db`; any remaining `tasks.db` mention sits on a line that also names `dartclaw.db` (transition context); the glossary carries an Authoritative Store entry; the generated region of `docs/guide/configuration.md` is untouched; `CHANGELOG.md` records the rename and the automatic adoption under Unreleased.
- **SC06** Workspace analysis, `bash dev/tools/test_workspace.sh`, `bash dev/tools/fitness/run_all.sh`, `arch_check` (two-sided LOC band, 12-package ceiling), and `git diff --check` are green.


## Scope & Boundaries

### Work Areas
- Config accessor: `packages/dartclaw_kernel/lib/src/dartclaw_config.dart` (`dartclawDbPath` replacing `tasksDbPath`) and its two test expectations (`dartclaw_config_test.dart`, `init_command_test.dart`) (TI01)
- Adoption module and presence helper: new `packages/dartclaw_core/lib/src/storage/authoritative_store_adoption.dart` (`adoptLegacyAuthoritativeStore`, `probeAuthoritativeStore`, `AuthoritativeStoreAdoptionException`), `show`-exported from `dartclaw_core.dart`; `SqliteBackend.openReadOnly` in `sqlite_backend.dart`; new suite `packages/dartclaw_core/test/storage/authoritative_store_adoption_test.dart` (TI02)
- The three production open sites: `packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart` (`wire()` step 8), `apps/dartclaw_cli/lib/src/commands/cleanup_command.dart` (`_runWorkflowArtifactRetention`), `apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart`; their `storeName:` labels; the S04 suite `storage_wiring_tasks_gate_test.dart` and the two CLI suites gain adoption cases; `packages/dartclaw_testing/lib/src/prepared_task_backend.dart`'s label (TI03)
- Literal sweep: dartdoc in `task_event_service.dart` and `turn_trace_service.dart`, the comment in `cleanup_command.dart`, the two CLI tests that build a path from `tasksDbPath` (`cleanup_command_test.dart`, `workflow_lifecycle_standalone_test.dart`), the tracked seed `dev/testing/profiles/visual/data/tasks.db` (`git mv`) and `dev/testing/.gitignore` (TI04)
- Docs: the architecture and guide files in SC05, the glossary, `CHANGELOG.md` (TI05)
- Closing gates and the visual-profile smoke (TI06)

### What We're NOT Doing

_(`S<NN>` outside `## Acceptance Scenarios` names a plan story; inside it, a scenario ID.)_

- Renaming `search.db` – accurately named; outside the owner decision.
- Touching `state.db` or the webhook ledger – story S15 replaces both with filesystem stores; here they keep their names and their direct opens.
- Any PostgreSQL change or `database.*` config – the operator names the database via the DSN (S07); the adoption step sits beside the SQLite tasks open so a later backend branch in `wire()` carries it along.
- The FR8 abandoned-store notice and the postgres-boot "never adopts" proof – story S10 builds the notice on this story's presence helper (owner decision 2026-08-07).
- Editing ADR-045, the CHANGELOG's released sections, the visual seed's session/artifact text, or the S02/S04/S06 test suites that pass `'tasks.db'` as an arbitrary caller-supplied store label or build legacy-shaped fixtures – dated records and label-agnostic tests; the gate does not care what the label says.
- A general file-migration mechanism – one bounded rename inside the supported 0.25 → 0.26 transition, in the spirit of S02's single adoption path.


## Architecture Decision

**Approach**: One pre-open adoption step in front of the three production opens of the authoritative store – classify presence, checkpoint the legacy file through a short-lived `SqliteBackend`, close, one `File.rename`, delete spent `tasks.db-*` remnants, refuse when both names exist – plus a config accessor rename; the S02 gate keeps taking a store name from its caller. The presence helper is a read-only classification over the same two names, exported for story S10.
**Why this over alternatives**: the rename belongs at the only layer that knows file paths (config plus the composition root and the two self-opening CLI commands); routing the checkpoint through `SqliteBackend` keeps the driver import surface at S06's three files instead of adding an allowlist entry; a multi-file rename (main plus sidecars) would need orphan-state recovery that the checkpoint-first decision makes unnecessary.


## Technical Overview

`adoptLegacyAuthoritativeStore(String dartclawDbPath)` derives the legacy path as the sibling `tasks.db` of the given path – the only place the legacy literal lives – and runs: (1) classify: `dartclaw.db` present and `tasks.db` absent → return (already adopted or fresh; an orphan `tasks.db-wal`/`-shm` without a main file is ignored); both present → throw `AuthoritativeStoreAdoptionException` naming both files with byte sizes, the word "ambiguous", and keep/remove guidance; neither → return (fresh bootstrap is the gate's job); only `tasks.db` → adopt. (2) Checkpoint: `SqliteBackend.open(legacyPath)`, `query('PRAGMA wal_checkpoint(TRUNCATE)')`, and if the returned `busy` column is non-zero throw the typed exception naming the store as in use; `close()` – the last connection's close removes the live `-wal`/`-shm`. (3) `File(legacyPath).renameSync(dartclawDbPath)`; on an OS error re-classify – `dartclaw.db` present and `tasks.db` absent means a concurrent adopter won, return; otherwise rethrow as the typed exception carrying the OS error. (4) Delete any stale `tasks.db-wal`/`tasks.db-shm` left beside the renamed file (spent by the checkpoint).

`probeAuthoritativeStore(String dartclawDbPath)` returns one of absent, ambiguous (both names), or present under one name with a non-empty verdict: `SqliteBackend.openReadOnly(path)` (`sqlite3.open(path, mode: OpenMode.readOnly)` – added in `sqlite_backend.dart`, the driver's home), `SELECT 1` bounded by `LIMIT 1` over each of `tasks`, `goals`, `workflow_runs`, `kg_facts` (an absent table counts as empty), `close()`; any open or read failure yields could-not-verify with the error attached. It never creates the store file; SQLite's transient `-shm` beside a WAL-mode file is removed on close.

Call sites pass `p.basename(config.dartclawDbPath)` as the S02 `storeName:`. In `wire()` the adoption call sits inside step 8's try before `taskBackendFactory(config.dartclawDbPath)`, so its exception takes the existing fatal path (close the search backend, log severe with the exception's message, `_exitFn(1)`). In `cleanup` it runs after the retention-disabled early return and before the existence probe on `config.dartclawDbPath`, and its exception is written through the existing "retention skipped" warning with exit 1; in `workflow status --standalone` it runs before the open and its exception prints the message and exits 1.


## Code Patterns & External References

```
# type | path#anchor                                                                                                  | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/dartclaw_config.dart#DartclawConfig                       | the derived path getters block (searchDbPath, tasksDbPath, kvPath) – rename in place, same dartdoc density
file   | ../dartclaw-public/packages/dartclaw_kernel/test/dartclaw_config_test.dart#main                                | the derived-getters table test whose tasksDbPath row becomes the dartclawDbPath row
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring.wire            | step 8's try block and its fatal catch – the adoption call goes first inside it
file   | ../dartclaw-public/apps/dartclaw_cli/lib/src/commands/cleanup_command.dart#_runWorkflowArtifactRetention       | the existsSync probe on the store path that a bare accessor rename would silently turn into "skip"
file   | ../dartclaw-public/apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart#WorkflowStatusCommand | the standalone open and its "No workflow data found" diagnostic path
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/index_reconciler.dart#IndexHealthStore                | dartdoc density and typed-failure shape for a small file-level module in this package
file   | ../dartclaw-public/dev/testing/.gitignore                                                                      | the tasks.db* ignore and the !profiles/visual/data/tasks.db exception to mirror for dartclaw.db
file   | ../dartclaw-public/dev/state/UBIQUITOUS_LANGUAGE.md#conversation--session                                      | table row shape (Term, Definition, Avoid) beside the Database Backend and Schema Compatibility Gate rows
```


## Constraints & Gotchas

- **Constraint**: adoption must precede every production access to the authoritative store, including existence probes – `cleanup` gates on `File(path).existsSync()`, which a bare accessor rename turns into "no store, skip retention" on an un-adopted directory; a path that opens before adoption bootstraps an empty `dartclaw.db` beside live legacy data, which is exactly the both-present hazard scenario S04 guards. TI01 and TI03 therefore land in one change.
- **Constraint**: "no open before adoption" means no open *for use* – the checkpoint open is adoption. It goes through `SqliteBackend.open` (no PRAGMAs; the file's persisted WAL mode is what matters) and `query()` for the PRAGMA, never a raw driver call, so the import census stays at three.
- **Constraint**: the checkpoint's `busy` result is the concurrency guard – SQLite has no equivalent of S10's interlock and one-shot maintenance commands are sanctioned concurrent clients. A busy checkpoint refuses; two adopters that both checkpoint cleanly race on the rename and the loser proceeds as already adopted (Execution Contract decision).
- **Constraint**: on Windows a rename fails while another handle holds the file; the adoption connection is closed before the rename and a foreign holder is caught by `busy`, so no extra handling exists. TD-135 keeps the unit suite off Windows hosts; the `windows-runtime` profile's fresh-directory serve covers scenario S01 there.
- **Constraint**: the wiring severe line keeps its wording ("Cannot open task database at …") – S04's gate suite asserts it – and only its path changes; the CLI diagnostics likewise keep their existing wording.
- **Constraint**: two-sided LOC ratchet (`dev/tools/arch_check.dart`): measured 2026-09-02 `dartclaw_core` 26269 of 27740, `dartclaw_kernel` 18428 of 19920 – this story adds one small core module and is line-neutral elsewhere; apply a downward re-cut only where `arch_check` reports slack.
- **Constraint**: comments are rationale-only, no story IDs in code, dartdoc, tests, or the CHANGELOG; the adoption module's dartdoc states the contract (checkpoint-first, refuse-if-ambiguous), not the decision history.
- **Constraint**: `dart test` runs suites as isolates in one process – temp data directories by path, never `Directory.current`; a WAL-resident fixture is produced by copying `tasks.db` and `tasks.db-wal` while the writing connection is still open (closing the last connection checkpoints and deletes the WAL).
- **Constraint**: `AuthoritativeStoreAdoptionException` stays in `dartclaw_core`, not the kernel `StorageException` family (S07 SC03) – that family exists to redact untrusted driver/DSN text to allow-listed safe fields, while this exception's message is built entirely from filesystem facts (paths, byte sizes) the module already controls, so the redaction contract does not apply.
- **Constraint**: the public working tree may carry another session's uncommitted edits outside this story's Work Areas; touch only the files named there.


## Implementation Plan

### Implementation Tasks

- **TI01** The authoritative store resolves as `dartclaw.db` through one accessor
  - `DartclawConfig.dartclawDbPath` returns `p.join(server.dataDir, 'dartclaw.db')` in the derived-getters block of `dartclaw_config.dart#DartclawConfig`; `tasksDbPath` is deleted; the four production and test call sites switch (analysis is the sweep enforcer); the `dartclaw_config_test.dart` derived-getters row and the `init_command_test.dart` expectation assert the new path. Lands together with TI03 (Constraints).
  - **Verify**: `cmd: ! rg -q "tasksDbPath" packages apps && rg -q "String get dartclawDbPath => p.join\(server.dataDir, 'dartclaw.db'\)" packages/dartclaw_kernel/lib/src/dartclaw_config.dart && dart test --reporter=failures-only packages/dartclaw_kernel/test/dartclaw_config_test.dart apps/dartclaw_cli/test/commands/init/init_command_test.dart` – the old accessor is gone from code and tests, the new one joins `dartclaw.db` under `dataDir`, and both suites pass with the new expectation (scenario S01's naming half)
  - **SATISFIES**: S01, SC02

- **TI02** Legacy stores adopt checkpoint-first, ambiguity and failure refuse, and presence is reported under either name
  - `packages/dartclaw_core/lib/src/storage/authoritative_store_adoption.dart` implements the Technical Overview (`adoptLegacyAuthoritativeStore`, `probeAuthoritativeStore`, `AuthoritativeStoreAdoptionException`), `show`-exported from `dartclaw_core.dart`; `SqliteBackend.openReadOnly(String path)` is added beside S06's `open`/`openInMemory`. New suite `packages/dartclaw_core/test/storage/authoritative_store_adoption_test.dart` builds fixtures through raw `sqlite3` connections wrapped in `SqliteBackend` and asserts file listings and byte snapshots. Depends on TI01 for the path name only.
  - **Verify**: `cmd: ! rg -q "package:sqlite3" packages/dartclaw_core/lib/src/storage/authoritative_store_adoption.dart && rg -q "openReadOnly" packages/dartclaw_core/lib/src/storage/sqlite_backend.dart && rg -qU "authoritative_store_adoption\.dart'\s*show[^;]*\badoptLegacyAuthoritativeStore\b" packages/dartclaw_core/lib/dartclaw_core.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/authoritative_store_adoption_test.dart` – no driver import in the module, the read-only constructor exists, the export carries a `show` clause, and the suite proves scenarios S02 (WAL-resident row readable after adoption, no `tasks.db*` left), S03 (byte-identical content, second call a no-op), S04 (refusal text contains `dartclaw.db`, `tasks.db`, both sizes, "ambiguous", "keep", "remove"; bytes unchanged), S05 (read-only directory with WAL-resident data: OS error in the message, no `dartclaw.db`, committed rows remain readable and adoption succeeds on retry; clean-store refusal preserves bytes; open second connection inside a read transaction: "in use" refusal, nothing renamed), S07 (five directory states, could-not-verify on an unreadable store, listing and bytes unchanged), the orphan-sidecar-only case, and that two adopters started concurrently on one directory (`Isolate.run` × 2) both complete without error with exactly one `dartclaw.db` afterwards
  - **SATISFIES**: S02, S03, S04, S05, S07, SC03

- **TI03** Every production open of the authoritative store adopts first and labels the gate with the file on disk
  - `storage_wiring.dart#StorageWiring.wire` calls `adoptLegacyAuthoritativeStore(config.dartclawDbPath)` first inside step 8's try, then `taskBackendFactory(config.dartclawDbPath)` and `prepareTasks(backend, storeName: p.basename(config.dartclawDbPath))`; `cleanup_command.dart#_runWorkflowArtifactRetention` adopts after the retention-disabled return and before its `existsSync` probe, its exception joining the "retention skipped" warning path; `workflow_status_command.dart` adopts before its open, printing the message and exiting 1 on failure; `prepared_task_backend.dart` labels its in-memory store `dartclaw.db`. `storage_wiring_tasks_gate_test.dart` (S04) gains the fresh, adopted, and both-present boots; `cleanup_command_test.dart` gains the un-adopted-directory retention case; `workflow_status_command_test.dart` gains the both-present case. Depends on TI01, TI02.
  - **Verify**: `cmd: test "$(rg -l 'adoptLegacyAuthoritativeStore\(' packages apps --glob '!**/test/**' --glob '!packages/dartclaw_core/lib/src/storage/authoritative_store_adoption.dart' | sort | tr '\n' ' ')" = "apps/dartclaw_cli/lib/src/commands/cleanup_command.dart apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart " && test "$(rg -n 'adoptLegacyAuthoritativeStore' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'taskBackendFactory\(' packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart | head -1 | cut -d: -f1)" && test "$(rg -n 'adoptLegacyAuthoritativeStore' apps/dartclaw_cli/lib/src/commands/cleanup_command.dart | head -1 | cut -d: -f1)" -lt "$(rg -n 'existsSync' apps/dartclaw_cli/lib/src/commands/cleanup_command.dart | head -1 | cut -d: -f1)" && ! rg -q "storeName: 'tasks\.db'" packages apps --glob '!**/test/**' && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_tasks_gate_test.dart apps/dartclaw_cli/test/commands/cleanup_command_test.dart apps/dartclaw_cli/test/commands/workflow/workflow_status_command_test.dart` – exactly the three sites adopt, each before its open or probe, no production site labels the gate `tasks.db`, and the suites prove scenario S01 (fresh boot creates `dartclaw.db`, no `tasks.db`), S02 (the wiring boot adopts then gate-adopts, row readable), S04 (both present: wiring takes the fatal path with the refusal in the severe log and both files unchanged; the two commands print it and exit 1), S06 (a refused `dartclaw.db` yields gate and severe messages naming `dartclaw.db` and never `tasks.db`), and S08 (retention runs against the adopted store; the corrupt-store degrade case unchanged)
  - **SATISFIES**: S01, S02, S04, S06, S08, SC02

- **TI04** No stray legacy name survives in code, test paths, `dartclaw_testing`, or tracked files
  - Update the dartdoc in `task_event_service.dart` and `turn_trace_service.dart` and the comment in `cleanup_command.dart`; the two CLI tests build their path from `dartclawDbPath`; `git mv dev/testing/profiles/visual/data/tasks.db dev/testing/profiles/visual/data/dartclaw.db` after confirming the committed file opens with its rows present without its untracked sidecars; `dev/testing/.gitignore` ignores `dartclaw.db*` and un-ignores `profiles/visual/data/dartclaw.db`. Test suites that pass `'tasks.db'` as an arbitrary gate label or name a legacy fixture are out of scope (What We're NOT Doing). Depends on TI03.
  - **Verify**: `cmd: test "$(rg -l 'tasks\.db' packages apps --glob '!**/test/**' --glob '!**/CHANGELOG.md' --glob '!**/CLAUDE.md' | sort | tr '\n' ' ')" = "packages/dartclaw_core/lib/src/storage/authoritative_store_adoption.dart " && ! rg -q "tasks\.db|tasksDbPath" packages/dartclaw_testing apps/dartclaw_cli/test/commands/cleanup_command_test.dart apps/dartclaw_cli/test/commands/workflow/workflow_lifecycle_standalone_test.dart && ! git ls-files | rg -q '(^|/)tasks\.db' && git ls-files --error-unmatch dev/testing/profiles/visual/data/dartclaw.db && rg -q '^!profiles/visual/data/dartclaw\.db$' dev/testing/.gitignore && rg -q '^dartclaw\.db\*$' dev/testing/.gitignore` – the adoption module is the only production file naming the legacy store outside `CLAUDE.md`, which TI05 clears; the testing package and the two path-building CLI tests are clean, no tracked `tasks.db` remains, the seed store is tracked under the new name, and the ignore rules mirror the old ones
  - **SATISFIES**: S06, SC02, SC04

- **TI05** Documentation, glossary, and CHANGELOG name the authoritative store `dartclaw.db`
  - In the SC05 files replace `tasks.db` with `dartclaw.db` in data-directory listings, storage tables, backup and recovery commands, the `configuration-architecture.md` getter list, the `LEARNINGS.md` KG line, and `packages/dartclaw_core/CLAUDE.md`; add one transition note to `data-model.md`'s backup/recovery section and one to `docs/guide/architecture.md`'s SQLite table (an existing `tasks.db` is adopted automatically on first start; both present refuses with keep/remove guidance) – the only lines that keep naming `tasks.db`; bump each architecture file's "Current through" marker; add an Authoritative Store row (`dartclaw.db`, retired synonym `tasks.db`) beside the Database Backend row in `dev/state/UBIQUITOUS_LANGUAGE.md` with a dated changelog line at its foot; add an Unreleased CHANGELOG entry for the rename and the automatic adoption. Public-repo doc edits executed in-milestone; no story IDs.
  - **Verify**: `cmd: ! rg -q 'tasks\.db' docs/guide/configuration.md docs/guide/getting-started.md docs/guide/workspace.md dev/state/STACK.md dev/state/LEARNINGS.md dev/architecture/system-architecture.md dev/architecture/task-execution-architecture.md dev/architecture/observability-operations-architecture.md dev/architecture/configuration-architecture.md packages/dartclaw_core/CLAUDE.md && ! rg -n 'tasks\.db' dev/architecture/data-model.md docs/guide/architecture.md | rg -qv 'dartclaw\.db' && rg -q 'dartclaw\.db' dev/architecture/data-model.md docs/guide/architecture.md docs/guide/getting-started.md dev/state/UBIQUITOUS_LANGUAGE.md CHANGELOG.md && rg -q '^\*\*Current through\*\*: 0\.26' dev/architecture/data-model.md && dart run dev/tools/render_config_reference.dart --check` – the listed files no longer name the legacy store, every remaining `tasks.db` line in the two transition-bearing docs also names `dartclaw.db`, the new name reaches the guide, glossary, and CHANGELOG, the data-model marker is bumped, and the generated config reference shows no drift
  - **SATISFIES**: SC05

- **TI06** The story closes with every gate green and one profile smoke from a fresh build
  - Depends on TI01–TI05. Run the visual profile from source (`bash dev/testing/profiles/visual/run.sh`, not the `DARTCLAW_TEST_USE_SNAPSHOT` path) and confirm the Tasks page renders the seeded tasks with no adoption logged; then with `DARTCLAW_VISUAL_DATA_DIR` pointing at a directory seeded from `git show HEAD:dev/testing/profiles/visual/data/tasks.db` (the pre-rename revision) confirm one adoption, the seeded tasks rendered, and `dartclaw.db` with no `tasks.db*` in that directory afterwards.
  - **Verify**: `cmd: dart analyze --fatal-infos && dart run dev/tools/arch_check.dart && git diff --check && test "$(grep -cv '^\s*#\|^\s*$' dev/fitness/test/allowlist/sqlite3_import_surface.txt)" = 3` – analysis, the workspace suite, the fitness suite, the LOC band and package ceiling, and the whitespace check are green, and the import allowlist still has three entries
  - **SATISFIES**: SC01, SC03, SC06

### Testing Strategy

- [TI02] Layer 2 against real SQLite at temp paths: fixtures are written through raw `sqlite3` connections (WAL mode set by PRAGMA, rows inserted) and snapshotted by copying `tasks.db` plus `tasks.db-wal` while the writer is still open, so the WAL-resident row is genuine; assertions are directory listings, `File.readAsBytesSync()` equality, and rows read back through `SqliteBackend` – never private call order. The read-only-directory case sets mode `0500` on the temp directory and is skipped when the process runs as root.
- [TI03] The wiring suite injects the exit function and a recording factory as S04's suite already does; the CLI suites drive the real commands against temp data directories.
- The bound Proof is parity – the degrade assertion stays; the adoption case is new coverage in the same file.

### Execution Contract

- Stories S02 and S06 must be complete (this story consumes `SqliteBackend.open`, `prepareTasks(storeName:)`, `DatabaseBackendFactory`, and the S06 wiring shape). Order: TI01 → TI02 → TI03 → TI04 → TI05 → TI06, with TI01 and TI03 committed as one change.
- **Resolved decision (owner, 2026-08-07) – adoption is checkpoint-first**: open the legacy `tasks.db` solely as part of adoption, run `PRAGMA wal_checkpoint(TRUNCATE)`, close (SQLite removes the live `-wal`/`-shm` on close), then one atomic single-file rename to `dartclaw.db`; any stale `tasks.db-*` remnant left after the successful rename is spent and is deleted. This makes adoption genuinely atomic at the filesystem level with no orphan-state machinery. The "adoption precedes every open" constraint is accordingly "no open *for use* before adoption" – the checkpoint open is adoption. Concurrency settles the same way: two concurrent adopters both checkpoint safely; the rename loser that finds `dartclaw.db` present and `tasks.db` absent treats the store as already adopted and proceeds, rather than aborting on `ENOENT`.
- **Resolved decision (owner, 2026-08-07 preflight) – PostgreSQL-dependent proofs execute in S10**: this story does not depend on S07, so no `database.backend: postgres` path exists when it executes; the startup-level no-adoption-under-postgres form of scenario S07 and the FR8 notice built on the presence helper execute in story S10, which depends on this story and owns the boot-flow and abandoned-store integration surface. The FR13 SQLite-free serve-run probe relocated by the same decision now belongs to the S15/S10 pair. This story keeps everything executable on the SQLite path: the presence-helper unit proof and every adoption scenario.
- Story S02's scenario S04 already names the store "by the name the caller supplied (`tasks.db` today; S14 passes the renamed file)"; no S02 text or test changes are needed – only the production call sites' labels change (TI03).


## Final Validation Checklist

- A copy of the released-0.25 visual seed directory under its old store name round-trips: adopt → serve → seeded tasks visible, with zero operator action (TI06's second run).
- No production literal `tasks.db` outside the adoption module; `search.db`, `state.db`, and the ledger untouched.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

#### DECISION NOTE: s14-pg-dependent-proofs-placement

Decision-Key: s14-pg-dependent-proofs-placement
Altitude: fis-local
Affected surface: S14 scenario S07 (startup-level no-adoption-under-postgres form), the FR8 notice consumer; S10 scenario S08 + TI07 (receiving surface); the FR13 SQLite-free serve-run probe now split to S15/S10
Decision: every proof requiring S07's `database.*` config or PostgresBackend (the startup-level no-adoption-under-postgres form, the FR8 abandoned-store notice, the SQLite-free serve-run probe) executes in S10.
Rationale: S14 does not depend on S07, so `database.backend: postgres` does not parse and PostgresBackend does not exist when S14 executes; S10 depends on S14 and owns the boot-flow, abandoned-store, and unreachable-boot integration tests, mirroring the settled either-name-helper split ("end-to-end consumer proof remains in S10").
Evidence: Owner ratified 2026-08-07 (preflight interview, `docs/specs/0.26/preflight-2026-08-07.md`); `plan.json` S10 `dependsOn` includes S14 and S15 and S10's `sequencing` names the presence helper as consumed.

### Run: 2026-09-08 14:19 UTC – repair-proof

#### DRIFT

- spec-stale: TI06 Verify target repaired | Stale targets: – | `cmd: dart analyze --fatal-infos && bash dev/tools/test_workspace.sh && bash dev/tools/fitness/run_all.sh && dart run dev/tools/arch_check.dart && git diff --check && test "$(grep -cv '^\s*#\|^\s*$' dev/fitness/test/allowlist/sqlite3_import_surface.txt)" = 3` → `cmd: dart analyze --fatal-infos && dart run dev/tools/arch_check.dart && git diff --check && test "$(grep -cv '^\s*#\|^\s*$' dev/fitness/test/allowlist/sqlite3_import_surface.txt)" = 3`

### Run: 2026-09-08 14:19 UTC – observations

2026-09-08 16:14 CEST owner scheduling override: one focused independent review and relevant checks per story. Full workspace and full fitness runs in task Verify commands are deferred to the final combined A+B gate, with no acceptance requirement removed. The retained command proves the story-local checks; prose referring to full-suite success describes final milestone evidence. Standard fast-tier closure remains; broad integration, platform and release verification run at the end.

### Run: 2026-09-08 18:46 UTC – observations

spec-stale: S08 scenario Proof now targets the preserved cleanup regression under its new name, `a corrupt authoritative store degrades to a skip warning and exit 1 instead of crashing`. The required legacy-name sweep renamed the test; its corrupt-store warning, exit and non-crash assertions remain. Acceptance unchanged. The installed ops repair-proof verb handles task Verify targets only; this scenario selector was updated exactly and is covered by the current independent story gate.

### Run: 2026-09-08 19:36 UTC – observations

#### DRIFT
- spec-stale: S05 physical byte identity contradicted FR12's explicit owner decision2026-08-07 and the FIS Technical Overview: checkpoint WAL into main, then one atomic rename. Independent source-hierarchy review2026-09-08 classified this as a uniquely determined FIS overconstraint, requiring no new product decision. S05 now preserves committed data under the legacy name and refuses before use; checkpointed bytes may differ. Both-present/no-op byte guarantees remain unchanged. The WAL-resident rename-refusal regression proves readable committed data, no new filename and successful retry. | Stale targets: S14 S05/TI02 | –

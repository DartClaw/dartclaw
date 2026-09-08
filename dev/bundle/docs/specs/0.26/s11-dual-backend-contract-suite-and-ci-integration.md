# FIS: Dual-Backend Contract Suite and CI Integration

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S11

_Refreshed 2026-09-02 against released 0.25 (public HEAD `daf5125a`), after the 2026-07-30 authoring against 0.24. Version labels: 0.26 is this milestone (the PRD title still carries its pre-renumber label), released 0.25 is the compatibility baseline. The contract-suite half stands (set-membership-only parity, the divergence whitelist, the explicit required-group manifest – dated owner decisions). The CI half is rewritten: the prior FIS assumed a CI service container, tagged-test execution in CI, and a branch-protection rule on `main`; none exists. Verified 2026-09-02: `ci.yml` has jobs `check`/`Check`, `powershell`/`PowerShell scripts`, `container`/`Container boundary` and no `services:` block; `test_workspace.sh` runs `dart test` per package with no tag selector, so `integration`-tagged suites never run in GitHub Actions; `release_check.sh` gate 10 requires jobs by name from a literal three-name list; GitHub `main` is unprotected (API 404) and the only ruleset protects release tags. The `dartclaw_storage` package the prior FIS targeted is gone. Code references (`packages/...`, `apps/...`, `dev/...`, `.github/...`) are paths inside `../dartclaw-public/`; every command runs from that root._

## Feature Overview and Goal

**Intent**: Make SQLite and PostgreSQL storage behavior one enforceable contract, and make the live PostgreSQL path a check that runs on every push and that a release cannot pass without, so backend drift and silently skipped live coverage cannot masquerade as a safe change.

**Expected Outcomes**:

- [OC01] One authored contract proves portable CRUD, transaction semantics, schema preparation (including orphan-column tolerance), search set membership, and tenant isolation on both backends, and every seam-backed repository family completes one real write/read round trip on PostgreSQL.
- [OC02] Every push runs the named PostgreSQL suites against a live service container in a CI job named `PostgreSQL contract`; the job fails when the service is unavailable, when any listed suite fails, or when the JSON report's passing contract-group set differs from the checked-in manifest.
- [OC03] The release gate cannot report green without a green `PostgreSQL contract` job, and the one-time operator step that makes the check required on GitHub `main` is documented as the milestone's recorded external gate.


## Required Context

- `docs/specs/0.26/plan.json#sharedDecisions` – "DatabaseBackend seam shape and placement under the 0.25 topology": the suite lives in `packages/dartclaw_core/test/`, `dartclaw_testing` may not take a driver dependency, no test file over 1300 lines. "Async transaction and nested-transaction contract": what `backend.transaction` proves. "FullTextIndex contract": `user_id` scopes search/upsert/delete, canonical identity as metadata, `error` role outside the searchable set. "Schema compatibility: exact released 0.25 baseline, required-object manifests": the orphan `external_artifact_mount` column is tolerated by construction – the suite proves it on both backends.
- `docs/specs/0.26/prd.md#fr9-dual-backend-contract-test-suite` – the acceptance criteria seeded here: coverage list, set-membership-only parity with the four divergence-neutral fixture rules and the durable whitelist, `@Tags(['integration'])` for the live path, SQLite in the default suite, job id `postgres_contract` / name `PostgreSQL contract`, JSON-report comparison against an explicit required-group manifest, unavailability fails. **NOTICED**: the FR still says "confirmed as a required branch-protection check"; no protection surface exists at HEAD, so the in-repo gate is `release_check.sh` gate 10 and the branch rule is the documented operator step (decision-validity audit § 9). The PRD amendment is owner-owned.
- `docs/specs/0.26/s01-databasebackend-seam-and-sqlite-backend.md#technical-overview` – the pinned seam contract the shared groups assert verbatim: canonical scalars (#2), `transaction()` semantics with zone-matched join and `NestedTransactionError` (#3), transaction-bound statements (#4), affected rows and `RETURNING` (#5), idempotent `close()` (#6).
- `docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md#technical-overview` – classification empty / current / released-unmarked / incompatible, marker `(1, 1)`, required-only manifests; `#work-areas` – `schema_fixtures.dart` (verbatim released-0.25 DDL and the 0.24-upgraded orphan-column variant) and `failing_database_backend.dart` (Nth-statement failing decorator), both in `packages/dartclaw_core/test/storage/` and importable by this suite (same package).
- `docs/specs/0.26/s03-fulltextindex-abstraction-and-fts5-implementation.md#technical-overview` – the port contract (#1–#3) the `fts.*` groups exercise; `SqliteFtsIndex(backend, table: SqliteFtsTable.memoryChunks)` and the `bm25()` score sign.
- `docs/specs/0.26/s04-task-domain-storage-seam-refactor.md#constraints--gotchas` – a `test/` file is not importable across packages; `dartclaw_testing` reaches core through the barrel only (its `openPreparedTaskBackend()` is the SQLite prepared-store idiom).
- `docs/specs/0.26/s05-execution-and-workflow-storage-seam-refactor.md#technical-overview` – the cluster classes take `DatabaseBackend` by constructor; `SqliteWorkflowRunRepository` lives in `dartclaw_workflow` (tier T2).
- `docs/specs/0.26/s07-opt-in-postgresbackend-core.md#technical-overview` – `PostgresBackend.open`, `PostgresSchemaGate.prepare` (fresh / current / incompatible, type mapping), the dispatch policy's injectable driver seam (#7); `#work-areas` – `test/storage/postgres_live_support.dart` (reads `DARTCLAW_TEST_POSTGRES_URL`, fails naming the variable, per-test isolated namespace) and the live suites `postgres_backend_live_test.dart`, `postgres_schema_gate_live_test.dart`, `storage_wiring_postgres_live_test.dart`; `#structural-criteria` SC05 – live suites tagged `integration`, no `markTestSkipped`.
- `docs/specs/0.26/s08-connection-security-credentials-redaction-tls-posture.md#testing-strategy` – ASSUMPTION: loopback with omitted `sslmode` keeps the driver default `require`; the stock `postgres` image serves no TLS, so the CI service URL carries `?sslmode=disable`.
- `docs/specs/0.26/s09-language-aware-postgresql-memory-and-kg-search.md#constraints--gotchas` – the documented divergences that justify whitelist entries (stemming, stopwords, diacritics, `websearch_to_tsquery` negation and phrases); `#work-areas` – the five live suites this story's CI script also runs.
- `../dartclaw-public/packages/dartclaw_core/test/search/search_backend_contract.dart#searchBackendContractTests` – the parameterized contract-suite shape to copy (factory callbacks, `group('$name contract')`); called from `search_backend_test.dart`.
- `../dartclaw-public/.github/workflows/ci.yml#jobs.container` – the job to mirror: pinned actions with SHA plus `# vX` comment, Dart `3.13.0`, `--enforce-lockfile`, `embed_assets.dart` before anything loads the runtime, and deliberately **no** fork-PR `if:` guard (no secret, no model turn).
- `../dartclaw-public/dev/tools/release_check.sh#10. Green CI run on this exact commit` – the literal required-job list and its `grep -qx "$required_job=success"` match; `../dartclaw-public/dev/tools/release_check_test.sh` – the existing static-assertion test seam (grep contracts against `ci.yml` and `release_check.sh`).
- `../dartclaw-public/dev/tools/test_workspace.sh` – the developer-tools block (`release_check_test.sh` etc.) where a new bash test registers, and the per-package `dart test` loop with no tag selector.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#test-configuration` – `integration` skipped by default, `contract` a selector only; `#live-integration-tests` – the `--run-skipped -t integration` idiom; `#fitness-functions` – `max_test_file_loc` (1300), `no_duplicate_local_fakes`, `testing_package_deps`.
- `../dartclaw-public/dev/state/LEARNINGS.md#testing` – bound-asserting tests enumerate the set (`unorderedEquals`, never `isNot(contains(…))`); the 1300-line cap: a new group goes in a sibling file with its own `setUp`.
- `../dartclaw-public/dev/state/LEARNINGS.md#tooling--verification` – `dart test` runs suites as isolates in one process (`Directory.current` shared); the host `libsqlite3` masks a skipped build hook, so real CI is the evidence; Dart tests never spawn `dart run <workspace script>` (bash tests may).
- `docs/specs/0.26/launch-context.md#live-structural-constraints` – the live CI jobs, release gate and package ceilings that supersede both temporary re-plan audits.


## Deeper Context

- `docs/specs/0.26/prd.md#non-functional-requirements` – Testability row: PostgreSQL path exercised on every PR, cannot silently skip.
- `docs/specs/0.26/s06-composition-root-wiring-and-census-closure.md#technical-overview` – `DatabaseBackendFactory`, `SqliteBackend.open`/`openInMemory`, the tasks-only PRAGMAs inside `prepareTasks`.
- `docs/specs/0.26/s14-authoritative-store-rename.md#feature-overview-and-goal` – the store name passes through the gate from its caller; the suite passes a literal and needs no change at the rename.
- `../dartclaw-public/dev/guidelines/RELEASE_PREPARATION.md` – names the three required jobs and explains why a green local run is not CI; the fourth job and the operator step land here.
- `../dartclaw-public/dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md#ci-equivalent-gate` – the command block that mirrors `ci.yml`.
- `../dartclaw-public/dev/package_tiers.txt` – "a `dev_dependencies:` entry is not an edge at all and stays legal" (why core's test tree may reach `dartclaw_workflow` for the workflow-run family).
- `../dartclaw-public/dev/fitness/test/allowlist/max_test_file_loc.txt` – the ratcheted allowlist format; this story adds no entry.
- `https://dart.dev/go/test-docs/json_reporter.md` – `testStart` (`test.name`, `test.metadata.skip`) and `testDone` (`result`, `hidden`, `skipped`) events the proof tool reads.


## Acceptance Scenarios

- **S01 [OC01] [TI01,TI02,TI03,TI04,TI05] SQLite proves its complete contract set in the default workspace suite**
  - **Given** no PostgreSQL process and `DARTCLAW_TEST_POSTGRES_URL` unset
  - **When** `bash dev/tools/test_workspace.sh` runs
  - **Then** the untagged SQLite contract entry runs every `shared` and `sqlite` group ID from the manifest and passes; no PostgreSQL type is constructed and no connection is attempted; the `postgres` entry is skipped by the `integration` tag, not by any code path

- **S02 [OC01] [TI02] Portable CRUD and transaction ownership behave identically where shared**
  - **Given** each backend with a prepared current authoritative store (SQLite via the S02 gate on `SqliteBackend.openInMemory()`, PostgreSQL via `PostgresSchemaGate.prepare` in an isolated namespace)
  - **When** the `backend.crud` and `backend.transaction` groups run
  - **Then** on both backends every canonical scalar round-trips, `UPDATE` resolves to its affected-row count, `INSERT … RETURNING id` returns the id, an owner statement executes twice and closes twice, rollback removes every body write and rethrows the body's error object, nested `transaction()` on `tx` and on the owner throws `NestedTransactionError` promptly, zone-matched owner writes inside the body vanish with the rollback, a `tx`-prepared statement rejects `execute`/`query` with `StateError` after both commit and rollback and closes twice without error, and a concurrent outside write issued mid-body (via `Completer` handshake) persists and never observes uncommitted rows; only the `backend.sqlite_completion_order` group asserts that the outside write completes after `transaction()`'s future

- **S03 [OC01] [TI03] Schema preparation is exact on both backends and tolerates the orphan column**
  - **Given** per backend: an empty store; a current store; a current store with the additional nullable column `workflow_step_executions.external_artifact_mount` and an unrelated user table; stores with epoch `0`, `2`, an absent/duplicated/non-integer marker, and epoch `1` with a required table, column, or index missing; and a failure injected after each bootstrap statement through S02's failing decorator
  - **When** the `schema.*` groups run
  - **Then** the empty store bootstraps in one transaction to every required object plus marker `(1, 1)` and a second prepare is a no-op; the current store reopens with no write (snapshot equal before and after); the orphan column and the foreign table are neither required nor rejected (`schema.orphan_column_tolerance`); every incompatible shape throws `SchemaIncompatibleException` before any repository is constructed with the store unchanged; every injected failure leaves the pre-transition snapshot intact and a clean retry on the same backend converges; and only SQLite runs `schema.sqlite_derived_rebuild` (incompatible `search.db` rebuilt from a complete source, refused with the prior file intact otherwise)

- **S04 [OC01] [TI04] Search membership parity is strict and tenant-scoped on both engines**
  - **Given** the checked-in divergence-neutral corpus under `english`, each fixture term proven neutral live (PostgreSQL: `to_tsvector('english', term)` yields exactly the term as its single lexeme; SQLite: the term indexed alone is found by itself), documents with the same id under users `u-alpha` and `u-beta`, and an empty divergence whitelist
  - **When** `fts.membership` and `fts.tenancy` run through `FullTextIndex` on `SqliteFtsIndex` and `PostgresFtsIndex`
  - **Then** for every fixture query the returned id set equals the expected set exactly on both engines with no score or order assertion; a fixture term that fails the neutrality check fails the suite unless the whitelist names it with evidence; and neither user's `search`, `listRecent`, `fetch`, `count`, `upsert`, or `delete` can observe or mutate the other's document

- **S05 [OC01] [TI05] [runtime] Every seam-backed repository family round-trips through live PostgreSQL**
  - **Given** one prepared `PostgresBackend` and the production repository classes from `dartclaw_core` and `dartclaw_workflow`
  - **When** task (with artifact), goal, agent-execution, workflow-step-execution, workflow-run, task-event, turn-trace, and KG-fact families each write one record and read it back
  - **Then** every returned domain value equals the written value, `addFact` returns the engine-assigned id, and raw seam probes show booleans stored as integer `0/1` and timestamps as ISO8601 text

- **S06 [OC02] [TI06] The PostgreSQL entry cannot skip missing infrastructure**
  - **Given** `DARTCLAW_TEST_POSTGRES_URL` unset, and separately set to an unreachable host
  - **When** `dart test --run-skipped -t integration packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart` runs
  - **Then** the process exits non-zero, the failure names `DARTCLAW_TEST_POSTGRES_URL`, and the JSON report contains no skipped contract test and no passing contract group

- **S07 [OC02] [TI07,TI08] [runtime] The CI job proves execution against the manifest and fails closed**
  - **Given** a push to any branch with the `postgres` service container healthy
  - **When** job `postgres_contract` (`PostgreSQL contract`) runs `bash dev/tools/postgres_contract.sh`
  - **Then** the script runs the SQLite entry and checks its report against `shared + sqlite`, runs the PostgreSQL entry plus every named upstream live suite with `--run-skipped -t integration --file-reporter=json:…`, and checks the PostgreSQL report against `shared + postgres`; the job is green only when every invocation exits 0 and both set comparisons are exact; an unhealthy service, an unreachable URL, a failed or skipped group, an unregistered group ID, a missing report, or a malformed report fails the job by name

- **S08 [OC03] [TI09,TI10] The release gate refuses a run without a green PostgreSQL contract job**
  - **Given** `release_check.sh` gate 10 and `ci.yml`
  - **When** `bash dev/tools/release_check_test.sh` runs
  - **Then** the test proves the gate-10 required-job list equals the set of job display names declared in `ci.yml` (`Check`, `Container boundary`, `PowerShell scripts`, `PostgreSQL contract`) so a job added to either file without the other fails the test


## Structural Criteria

- **SC01** One checked-in JSON manifest classifies every group ID exactly once: shared `backend.crud`, `backend.transaction`, `schema.fresh_bootstrap`, `schema.compatible_reopen`, `schema.orphan_column_tolerance`, `schema.incompatible_refusal`, `schema.bootstrap_rollback`, `fts.membership`, `fts.tenancy`, `repository.task`, `repository.goal`, `repository.agent_execution`, `repository.workflow_step_execution`, `repository.workflow_run`, `repository.task_event`, `repository.turn_trace`, `repository.kg_fact`; SQLite-only `backend.sqlite_completion_order`, `schema.sqlite_derived_rebuild`; PostgreSQL-only `backend.ambiguous_dispatch_no_replay`. Every group name in the suite begins with `[contract:<id>]`; the proof tool has no count or threshold option.
- **SC02** The divergence whitelist is a checked-in file whose every entry names query, document id, engine, engine-level evidence, and a review date; a stale entry (never exercised by the fixtures) fails the suite; the initial whitelist is empty.
- **SC03** The SQLite entry carries no `integration` tag and imports no PostgreSQL type; the PostgreSQL entry carries `@Tags(['integration'])`, uses S07's `postgres_live_support.dart`, and calls no `markTestSkipped`; `packages/dartclaw_testing/pubspec.yaml` `dependencies:` is unchanged (`testing_package_deps` green).
- **SC04** `.github/workflows/ci.yml` declares job key `postgres_contract` with `name: PostgreSQL contract`, a `postgres` service pinned like the actions (major tag `14` plus digest), a `pg_isready` health check, `DARTCLAW_TEST_POSTGRES_URL` carrying `?sslmode=disable`, no fork-PR `if:` guard, and one test step that runs `bash dev/tools/postgres_contract.sh`; no other job changes.
- **SC05** `release_check.sh` gate 10's `for required_job in` list contains `"PostgreSQL contract"`, and `release_check_test.sh` asserts that list equals `ci.yml`'s job display names.
- **SC06** The story's diff touches only test trees, `dev/tools/`, `.github/workflows/ci.yml`, `dev/guidelines/`, and `packages/dartclaw_core/pubspec.yaml` `dev_dependencies:`; no `lib/` file changes; no file added by this story exceeds 1300 lines; every test double introduced has a workspace-unique name (`no_duplicate_local_fakes`); the fitness suite, `arch_check`, and `git diff --check` are green.


## Scope & Boundaries

### Work Areas
- Shared suite under `../dartclaw-public/packages/dartclaw_core/test/storage/contract/`: `database_backend_contract.dart` (CRUD, transaction, completion-order, ambiguous-dispatch groups), `schema_contract.dart`, `fts_contract.dart` (membership, tenancy, neutrality check, whitelist reader), `repository_contract.dart`, `contract_groups.json` (manifest), `fts_divergence_whitelist.json`, and the entries `sqlite_backend_contract_test.dart` and `postgres_backend_contract_test.dart` (TI01–TI06)
- `../dartclaw-public/packages/dartclaw_core/pubspec.yaml` `dev_dependencies:` gains `dartclaw_workflow` (the workflow-run family) (TI05)
- Proof tool and its test: `../dartclaw-public/dev/tools/contract_groups_check.dart`, `../dartclaw-public/dev/tools/contract_groups_check_test.sh`; registration in `../dartclaw-public/dev/tools/test_workspace.sh`'s developer-tools block (TI07)
- CI runner script and job: `../dartclaw-public/dev/tools/postgres_contract.sh`, `../dartclaw-public/.github/workflows/ci.yml` (TI08)
- Release gate: `../dartclaw-public/dev/tools/release_check.sh` gate 10, `../dartclaw-public/dev/tools/release_check_test.sh` (TI09)
- Docs: `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md`, `RELEASE_PREPARATION.md`, `KEY_DEVELOPMENT_COMMANDS.md` (TI10)

### What We're NOT Doing

_(`S<NN>` outside `## Acceptance Scenarios` names a plan story; inside it, a scenario ID.)_

- Cross-backend rank or score parity – `bm25()` and `ts_rank` differ by design (ADR-045 #8, owner decision).
- Swedish morphology, stopword, or diacritic assertions – story S09's backend-specific fixtures own them; here they are the classes a whitelist entry may cite.
- Production fixes for a failing pinned assertion – the finding returns to its owning predecessor story; the shared expectation is not weakened and no whitelist entry is added without engine evidence.
- Repository-settings automation (`gh api … /protection`, rulesets API, a workflow that edits settings) – rejected by the PRD; the operator performs the step in the GitHub UI and the plan close-out records it. This story writes the instructions only; no task waits for the operator.
- A second SQLite CI job or a `postgres` test tag – SQLite stays in the default `check` job; the live path is selected by explicit file list, not by a new tag convention.
- Verifying gate 10's `gh` behavior end to end in a unit test – it would need a fake `gh` behind gates 2–9; the static list-equality test plus the release process itself is the proof.


## Architecture Decision

**Approach**: One parameterized `databaseBackendContractTests` library in `dartclaw_core`'s test tree, split by concern under the 1300-line cap, driven by two thin entries; stable `[contract:<id>]` group tokens connect the JSON report to a checked-in manifest that a dependency-free Dart tool compares by exact set equality; one bash script owns the explicit live invocation for CI and developers alike; the job is registered in gate 10 with a test that ties the list to `ci.yml`. See ADR: `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md` (#8: set-membership parity, fail-closed contracts).
**Why this over alternatives**: separate per-backend expectations or a pass-count threshold pass while a required behavior disappears; a tag-based CI selector would either drag every `integration` suite (provider binaries, Docker) into the job or add a tag convention for one consumer; putting the live invocation in `ci.yml` alone leaves developers with no equivalent command and lets the job and the docs drift.


## Technical Overview

1. **Harness**: `databaseBackendContractTests({required String name, required Future<ContractBackend> Function() open, required Set<String> enabledGroups})` where `ContractBackend` bundles the prepared `DatabaseBackend`, a `FullTextIndex` factory (`(backend) => SqliteFtsIndex(…memoryChunks)` / `PostgresFtsIndex(…, language: 'english')`), a schema-operations adapter (`prepare`, `snapshot`, `corruptEpoch(int?)`, `dropRequiredObject`, `addOrphanColumn`, `fresh()` returning an empty store), an optional live-neutrality probe (`lexemeOf(term)`), and `close`. Each concern file exports one `void …Groups(ContractBackend Function() current, Set<String> enabled)`; a group is declared under `group('[contract:<id>] <title>')` and is skipped from declaration (never `markTestSkipped`) when its id is not in `enabled`.
2. **Entries**: `sqlite_backend_contract_test.dart` (untagged; `enabled = shared ∪ sqlite`; stores via `SqliteBackend.openInMemory()` prepared by `SqliteSchemaGate.prepareTasks`/`prepareSearch`, fixtures from `schema_fixtures.dart`). `postgres_backend_contract_test.dart` (`@Tags(['integration'])`; `enabled = shared ∪ postgres`; one `PostgresBackend` per test in the namespace S07's helper allocates; `fresh()` drops and recreates the namespace). Both read the manifest file to derive `enabled`, so the manifest is the single source.
3. **Manifest**: `contract_groups.json` – `{"shared": [...], "sqlite": [...], "postgres": [...]}`. The entries assert at load that the three arrays are disjoint and that every group the harness can declare is classified.
4. **Neutrality and whitelist**: the parity corpus is a `const` list of `(id, text)` pairs plus `(query, expectedIds)` pairs; every distinct fixture term is ASCII `[a-z0-9]+`, and `fts.membership` first asserts `lexemeOf(term) == term` on the engine under test (PostgreSQL: `SELECT to_tsvector('english', ?)` yields the single lexeme `term`; SQLite: a document holding only `term` is returned by `search(term)`). A term failing neutrality or a membership difference is compared against `fts_divergence_whitelist.json` (`[{query, documentId, engine, evidence, reviewedOn}]`); a matching entry removes that pair from the comparison; an entry matching nothing fails as stale; the file starts as `[]`.
5. **Repository families** (`repository.*`): the landed production classes over the supplied backend – `SqliteTaskRepository`, `SqliteGoalRepository`, `SqliteAgentExecutionRepository`, `SqliteWorkflowStepExecutionRepository`, `SqliteWorkflowRunRepository` (from `package:dartclaw_workflow`, a `dev_dependencies:` edge core may take), `TaskEventService`, `TurnTraceService`, `TemporalKnowledgeGraphService` (default substring strategy; no `search:` call, since `instr()` is SQLite-only until S09's dialect is injected). Domain equality first, then a raw `backend.query` probe of the stored boolean and timestamp columns.
6. **Ambiguous dispatch** (`backend.ambiguous_dispatch_no_replay`, PostgreSQL set): runs S07's dispatch classifier over S07's counting fake driver seam (same package test tree) – post-send and post-`COMMIT` transport loss dispatch once and throw `StorageUnknownOutcomeException`; proven pre-dispatch failure retries. No server needed; enabled only by the PostgreSQL entry so the SQLite report never carries a PostgreSQL id.
7. **Proof tool** (`dev/tools/contract_groups_check.dart`, `dart:io` + `dart:convert` only, like `arch_check.dart`): `--manifest <path> --expect <set,set> --report <path> [--report …]`; reads the JSON reporter stream, pairs `testStart`/`testDone` by id, extracts `[contract:<id>]` from the full test name, ignores `hidden` tests, and marks an id passing only when it has at least one visible test and every visible test is `success` and not `skipped`. Exit 0 only when the passing set equals the union of the expected manifest sets exactly; any missing, failed, skipped, unregistered, or doubly-classified id, an absent or unparseable report, or an unknown `--expect` name exits 1 with the offending ids on stderr.
8. **Runner script** (`dev/tools/postgres_contract.sh`): requires `DARTCLAW_TEST_POSTGRES_URL` (exits 2 naming it otherwise); writes reports under `build/postgres-contract/` (gitignored); runs, in order and each from its package directory: the SQLite entry with `--file-reporter=json:` then the check against `shared,sqlite`; in `dartclaw_core` one `dart test --run-skipped -t integration --reporter=failures-only --file-reporter=json:…` over the explicit list – the PostgreSQL entry, `postgres_backend_live_test.dart`, `postgres_schema_gate_live_test.dart`, `search/postgres_fts_index_live_test.dart`, `knowledge/postgres_fact_search_live_test.dart`, `storage/index_reconciler_postgres_live_test.dart`; in `dartclaw_runtime` with `--concurrency=1` the two `storage_wiring_postgres*_live_test.dart` suites; in `apps/dartclaw_cli` `rebuild_index_command_postgres_live_test.dart`; then the check of the core report against `shared,postgres`. Every `dart test` exit code propagates (`set -euo pipefail`), so a renamed or failing upstream suite fails the script even though only the contract entry carries manifest ids.
9. **CI job**: `postgres_contract` / `PostgreSQL contract`, `runs-on: ubuntu-latest`, no `if:`; `services.postgres` with `image: postgres:14@sha256:<digest> # 14` (re-resolve like the actions), `env: POSTGRES_PASSWORD`, `POSTGRES_DB: dartclaw_test`, `ports: ['5432:5432']`, `options: --health-cmd pg_isready --health-interval 10s --health-timeout 5s --health-retries 5`; job `env: DARTCLAW_TEST_POSTGRES_URL: postgres://postgres:<password>@localhost:5432/dartclaw_test?sslmode=disable`; steps: checkout, setup Dart `3.13.0`, `dart pub get --enforce-lockfile`, `dart run dev/tools/embed_assets.dart`, `bash dev/tools/postgres_contract.sh`. An unhealthy service fails the job before the first step.
10. **Gate 10**: `"PostgreSQL contract"` appended to the literal list; the section comment gains one sentence naming the PostgreSQL job as the fourth host-uncovered check. `release_check_test.sh` extracts every `^    name: ` value under `jobs:` in `ci.yml` and the quoted names of the `for required_job in` line, sorts both, and fails on any difference.


## Code Patterns & External References

```
# type | path#anchor                                                                                                   | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_core/test/search/search_backend_contract.dart#searchBackendContractTests    | parameterized contract-suite shape: factory callbacks, group naming
file   | ../dartclaw-public/packages/dartclaw_core/test/search/search_backend_test.dart                                    | entry-point pattern calling a shared contract library
file   | ../dartclaw-public/packages/dartclaw_core/test/storage/schema_fixtures.dart                                       | as landed by story S02: verbatim released-0.25 DDL and the orphan-column variant (absent at HEAD)
file   | ../dartclaw-public/packages/dartclaw_core/test/storage/failing_database_backend.dart                              | as landed by story S02: Nth-statement failing decorator for schema.bootstrap_rollback (absent at HEAD)
file   | ../dartclaw-public/packages/dartclaw_core/test/storage/postgres_live_support.dart                                 | as landed by story S07: DSN from the env var, fail-loud, per-test namespace (absent at HEAD)
file   | ../dartclaw-public/packages/dartclaw_core/test/storage/postgres_dispatch_policy_test.dart                         | as landed by story S07: the counting fake driver seam the ambiguous-dispatch group reuses (absent at HEAD)
file   | ../dartclaw-public/packages/dartclaw_testing/lib/src/prepared_task_backend.dart                                  | as landed by story S04: the prepared-SQLite idiom (absent at HEAD)
file   | ../dartclaw-public/.github/workflows/ci.yml#jobs.container                                                        | job skeleton to mirror: pins, SDK, lockfile, embed_assets, no fork guard
file   | ../dartclaw-public/dev/tools/release_check.sh#10. Green CI run on this exact commit                              | the required-job loop to extend
file   | ../dartclaw-public/dev/tools/release_check_test.sh                                                                | static grep-contract test seam to extend
file   | ../dartclaw-public/dev/tools/fitness/test_check_task_executor_workflow_refs.sh                                    | bash test driving a dev/tools Dart script against temp fixtures (the proof-tool test pattern)
file   | ../dartclaw-public/dev/tools/arch_check.dart                                                                      | dependency-free dev tool idiom (dart:io only, run via dart run)
file   | ../dartclaw-public/dev/fitness/test/allowlist/max_test_file_loc.txt                                              | ratchet-and-stale-entry discipline the whitelist mirrors
url    | https://dart.dev/go/test-docs/json_reporter.md                                                                    | testStart/testDone event shapes, hidden and skipped flags
url    | https://docs.github.com/en/actions/using-containerized-services/creating-postgresql-service-containers            | services.postgres, ports mapping to localhost, health-check options
```


## Constraints & Gotchas

- **Critical**: `integration` is skipped by default and `test_workspace.sh` passes no tag, so nothing tagged runs in the `check` job. Every live invocation lives in `postgres_contract.sh` with `--run-skipped -t integration` and explicit files; never select by tag over a whole package (that would pull provider-binary and Docker suites into the job).
- **Critical**: a group id is incomplete until the manifest classifies it in the same change; exact set equality rejects a missing id and an unregistered one alike, so adding a group without the manifest line fails CI by design.
- **Critical**: the whitelist is not a waiver for unexplained drift – an entry needs query, document id, engine, engine-level evidence, and a review date, and a stale entry fails; parity assertions stay exact set equality on the remaining pairs.
- **Critical**: the loopback URL must carry `?sslmode=disable` (S08 assumption: omitted mode on loopback keeps the driver default `require`, and the stock image serves no TLS). Omitting it makes every live suite fail at handshake, which reads as an infrastructure outage.
- **Constraint**: one database, sequential packages. Core suites isolate through S07's per-test namespace; the runtime and CLI suites boot the composition root on the default schema and run with `--concurrency=1`; each composition-root suite owns its own preconditions (S07/S09 contract). The script does not reset the database. If two upstream suites cannot share the database, that is a finding returned to their story, not a reset added here.
- **Constraint**: 1300-line cap and the plan's file rule apply to every file under `test/storage/contract/`, library files included; concern files each carry their own `setUp`. Test doubles introduced here get workspace-unique names (`no_duplicate_local_fakes`); `FailingDatabaseBackend` and the S07 fake seam are reused, not redeclared.
- **Constraint**: `dartclaw_core` → `dartclaw_workflow` is a `dev_dependencies:` entry only (legal per `dev/package_tiers.txt`); the import appears in `repository_contract.dart` and nowhere under `lib/`.
- **Constraint**: S02's fixtures, S07's live support, and S07's fake seam are in `dartclaw_core/test/` and importable only from the same package – which is why the whole suite lives there.
- **Constraint**: `dart test` runs suites as isolates in one process – never touch `Directory.current`; reports are written by `--file-reporter` to paths the script resolves from the repo root.
- **Gotcha**: the JSON reporter emits `testDone` for hidden setup tests and for tests skipped at declaration (`skip:`); the tool must ignore `hidden` and treat `skipped: true` as failing for a required id. A group whose id is disabled is never declared, so it produces no event at all.
- **Gotcha**: the image digest, like the action SHAs, is re-resolved by hand; document the command beside the pin in `ci.yml`'s header comment.
- **Constraint**: comments are rationale-only; no story IDs in code, test names, `ci.yml`, or the guidelines; en dashes in prose.


## Implementation Plan

### Implementation Tasks

- **TI01** The contract harness, manifest, and both entries exist and drive group selection from one file
  - `database_backend_contract.dart` exports `databaseBackendContractTests` and `ContractBackend` per Technical Overview #1; `contract_groups.json` lists the SC01 sets; both entries load it and assert disjointness and full classification; `postgres_backend_contract_test.dart` is `@Tags(['integration'])` over S07's helper and throws naming `DARTCLAW_TEST_POSTGRES_URL` when unset. Follow `search_backend_contract.dart#searchBackendContractTests`.
  - **Verify**: `cmd: bash -c 'test -f packages/dartclaw_core/test/storage/contract/contract_groups.json && rg -q "@Tags\(\['"'"'integration'"'"'\]\)" packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart && ! rg -q "@Tags|Postgres" packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart && ! rg -q "markTestSkipped" packages/dartclaw_core/test/storage/contract && (unset DARTCLAW_TEST_POSTGRES_URL; out="$(dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart 2>&1)"; test $? -ne 0 && rg -q "DARTCLAW_TEST_POSTGRES_URL" <<< "$out")'` – manifest present, tags as pinned, no skip call, the PostgreSQL entry fails by name without the variable (scenario S06's unset half)
  - **SATISFIES**: S06, SC01, SC03

- **TI02** Shared CRUD and transaction groups assert the S01 contract, with completion order SQLite-only and ambiguous dispatch PostgreSQL-only
  - `backend.crud`, `backend.transaction`, `backend.sqlite_completion_order` (Completer handshake, completion order asserted, never a delay), and `backend.ambiguous_dispatch_no_replay` (Technical Overview #6 over S07's fake seam) in `database_backend_contract.dart`. Depends on TI01.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:backend." && test "$(rg -oF "[contract:backend.crud]" packages/dartclaw_core/test/storage/contract/database_backend_contract.dart | wc -l | tr -d " ")" = 1 && test "$(rg -oF "[contract:backend.transaction]" packages/dartclaw_core/test/storage/contract/database_backend_contract.dart | wc -l | tr -d " ")" = 1 && test "$(rg -oF "[contract:backend.sqlite_completion_order]" packages/dartclaw_core/test/storage/contract/database_backend_contract.dart | wc -l | tr -d " ")" = 1 && test "$(rg -oF "[contract:backend.ambiguous_dispatch_no_replay]" packages/dartclaw_core/test/storage/contract/database_backend_contract.dart | wc -l | tr -d " ")" = 1` – scenario S02's transaction clauses pass on SQLite (rollback and rethrow of the same error object, `NestedTransactionError` on both paths, zone-matched owner writes rolled back, `tx` statement `StateError` after commit and rollback with idempotent close, concurrent outside write persisted), the crud group round-trips every canonical scalar with affected rows and `RETURNING id`, and `rg -c "\[contract:backend\." packages/dartclaw_core/test/storage/contract/database_backend_contract.dart` shows all four ids declared once
  - **SATISFIES**: S01, S02

- **TI03** Schema groups prove fresh, current, orphan-tolerant, incompatible, and rolled-back states through a backend-supplied adapter
  - `schema_contract.dart` per scenario S03 using the adapter's `fresh`/`snapshot`/`corruptEpoch`/`dropRequiredObject`/`addOrphanColumn`; SQLite fixtures from `schema_fixtures.dart`; rollback through `FailingDatabaseBackend` over `1..N`; `schema.sqlite_derived_rebuild` reuses S02's rebuild source shape. Depends on TI01.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:schema."` – a current store with the added nullable `external_artifact_mount` column and a foreign table classifies current and reopens with an identical snapshot; the sibling schema groups prove bootstrap to marker `(1, 1)`, no-write reopen, typed refusal with unchanged store for every incompatible shape, and snapshot-preserving rollback with converging retry
  - **SATISFIES**: S01, S03

- **TI04** Search membership parity and tenancy share one strict, whitelist-governed expectation
  - `fts_contract.dart` per Technical Overview #4: the neutral corpus, expected id sets, the live neutrality probe, `fts_divergence_whitelist.json` (initially `[]`) with format, staleness, and evidence checks, and same-id isolation for every port operation. Depends on TI01.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:fts." && test "$(tr -d '[:space:]' < packages/dartclaw_core/test/storage/contract/fts_divergence_whitelist.json)" = "[]"` – every fixture query's id set equals the expectation with no score or order assertion; every fixture term passes the neutrality probe; the group's negative case feeds a whitelist entry naming a pair no fixture exercises and asserts the stale-entry failure; `[contract:fts.tenancy]` proves read, overwrite, and delete isolation as three separate assertions; and `test "$(tr -d '[:space:]' < packages/dartclaw_core/test/storage/contract/fts_divergence_whitelist.json)" = "[]"` holds
  - **SATISFIES**: S01, S04, SC02

- **TI05** Every repository family round-trips on both backends through the landed production classes
  - `repository_contract.dart` per Technical Overview #5; `dartclaw_workflow` added to `packages/dartclaw_core/pubspec.yaml` `dev_dependencies:` followed by `dart pub get` at the workspace root. Depends on TI01.
  - **Verify**: `cmd: bash -c 'rg -q "^  dartclaw_workflow:" <(sed -n '"'"'/^dev_dependencies:/,$p'"'"' packages/dartclaw_core/pubspec.yaml) && ! rg -q "dartclaw_workflow" packages/dartclaw_core/lib && test "$(rg -o "\[contract:repository\.[a-z_]+\]" packages/dartclaw_core/test/storage/contract/repository_contract.dart | sort -u | wc -l | tr -d '"'"' '"'"')" = 8 && dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart'` – the dev edge exists and `lib/` never imports the workflow package; all eight family ids are declared; the SQLite entry passes end to end (scenario S01); the fitness suite accepts the dev edge
  - **SATISFIES**: S01, S05, SC06

- **TI06** [runtime] The PostgreSQL entry passes its complete set against live PostgreSQL 14 and never skips
  - Enabled set `shared ∪ postgres`; `fresh()` recreates the namespace; the neutrality probe runs `to_tsvector`. Depends on TI02–TI05 and on live PostgreSQL through `DARTCLAW_TEST_POSTGRES_URL`.
  - **Verify**: `cmd: (cd packages/dartclaw_core && dart test --reporter=failures-only --file-reporter=json:../../build/postgres-contract/verify-sqlite.json test/storage/contract/sqlite_backend_contract_test.dart) && dart run dev/tools/contract_groups_check.dart --manifest packages/dartclaw_core/test/storage/contract/contract_groups.json --expect shared,sqlite --report build/postgres-contract/verify-sqlite.json && dart analyze --fatal-infos packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart` – every shared and PostgreSQL group passes live (scenarios S02–S05 on PostgreSQL, including all eight repository families and the ambiguous-dispatch group) and the report's passing set equals `shared + postgres` exactly
  - **SATISFIES**: S02, S03, S04, S05, S06

- **TI07** The proof tool compares the JSON report against the manifest by exact set equality and is tested from bash
  - `dev/tools/contract_groups_check.dart` per Technical Overview #7; `dev/tools/contract_groups_check_test.sh` builds JSON-reporter fixtures in a temp dir (exact success; missing id; failed test; `skipped: true`; unregistered id; doubly-classified manifest; empty report; absent file; malformed JSON; unknown `--expect`) following `test_check_task_executor_workflow_refs.sh`; the test is added to the developer-tools block of `test_workspace.sh`.
  - **Verify**: `cmd: bash -c 'bash dev/tools/contract_groups_check_test.sh && rg -q "contract_groups_check_test.sh" dev/tools/test_workspace.sh && test "$(rg -c "^import '"'"'dart:" dev/tools/contract_groups_check.dart | tr -d '"'"' '"'"')" -ge 2 && ! rg -q "^import '"'"'package:" dev/tools/contract_groups_check.dart && ! rg -qi "threshold|min-groups|count" <(rg -o "'"'"'--[a-z-]+'"'"'" dev/tools/contract_groups_check.dart)'` – the bash test passes every case, the test is registered, the tool imports only `dart:` libraries, and no count or threshold option exists
  - **SATISFIES**: S07, SC01

- **TI08** [runtime] One script owns the explicit live invocation and CI runs it in the named job against a service container
  - `dev/tools/postgres_contract.sh` per Technical Overview #8 and the `ci.yml` job per #9 (mirroring `jobs.container`; `ci.yml` header comment extended with the image re-resolve command). Depends on TI06, TI07.
  - **Verify**: `cmd: bash -c 'rg -q "^  postgres_contract:$" .github/workflows/ci.yml && rg -q "^    name: PostgreSQL contract$" .github/workflows/ci.yml && rg -q "image: postgres:14@sha256:" .github/workflows/ci.yml && rg -q "pg_isready" .github/workflows/ci.yml && rg -q "sslmode=disable" .github/workflows/ci.yml && rg -q "bash dev/tools/postgres_contract.sh" .github/workflows/ci.yml && ! rg -q "if:" <(awk '"'"'/^  postgres_contract:$/,/^  [a-z]+:$/'"'"' .github/workflows/ci.yml | sed '"'"'1d;$d'"'"') && rg -q -- "--run-skipped -t integration" dev/tools/postgres_contract.sh && rg -q -- "--expect shared,sqlite" dev/tools/postgres_contract.sh && rg -q -- "--expect shared,postgres" dev/tools/postgres_contract.sh && (unset DARTCLAW_TEST_POSTGRES_URL; bash dev/tools/postgres_contract.sh; test $? = 2)'` – job key, name, pinned image, health check, `sslmode=disable`, and the script step exist with no fork guard in the job block; the script carries both checks and the tagged invocation, exits 2 by name without the variable, and passes end to end against live PostgreSQL (scenario S07's local half; the service-container half is proven by the first green `PostgreSQL contract` run on the pushed branch, whose run id and SHA are recorded in Implementation Observations)
  - **SATISFIES**: S07, SC04

- **TI09** Gate 10 requires the PostgreSQL job and a test ties its list to the workflow
  - `"PostgreSQL contract"` appended to the `for required_job in` list in `release_check.sh` with one added comment sentence; `release_check_test.sh` gains the list-equality assertion of Technical Overview #10. Depends on TI08.
  - **Verify**: `cmd: bash -c 'rg -q '"'"'for required_job in .*"PostgreSQL contract"'"'"' dev/tools/release_check.sh && bash dev/tools/release_check_test.sh && diff <(rg -o '"'"'^    name: .*'"'"' .github/workflows/ci.yml | sed '"'"'s/^    name: //'"'"' | sort) <(rg -o '"'"'for required_job in .*; do'"'"' dev/tools/release_check.sh | rg -o '"'"'"[^"]+"'"'"' | tr -d '"'"'"'"'"' | sort)'` – the literal is registered, the extended test passes, and the two name sets are identical at HEAD (scenario S08)
  - **SATISFIES**: S08, SC05

- **TI10** Developer and release guidelines describe the live path, the manifest and whitelist discipline, and the operator step
  - `TESTING-STRATEGY.md` § Live Integration Tests gains a "PostgreSQL contract" subsection: start a local server (`docker run --rm -e POSTGRES_PASSWORD=… -p 5432:5432 postgres:14`), export `DARTCLAW_TEST_POSTGRES_URL=postgres://postgres:…@localhost:5432/dartclaw_test?sslmode=disable`, run `bash dev/tools/postgres_contract.sh`; how a new group is added (group token plus manifest line in one change); how a whitelist entry is justified (engine evidence, review date, stale entries fail). `RELEASE_PREPARATION.md` names four required jobs and adds the one-time operator step under its own heading: on GitHub open Settings → Rules → Rulesets, create a branch ruleset targeting `main` (none exists as of 2026-09-02), enable "Require status checks to pass" and add the exact check `PostgreSQL contract` (the other three gate-10 names alongside it keep the ruleset and gate 10 identical), save, reopen the ruleset and confirm the check is listed; record the confirmation date and check name in the 0.26 entry of `dev/state/ROADMAP.md` at the milestone close-out – repository settings are never automated. `KEY_DEVELOPMENT_COMMANDS.md#ci-equivalent-gate` gains the script line with its environment prerequisite. No story IDs.
  - **Verify**: `cmd: rg -q "postgres_contract.sh" dev/guidelines/TESTING-STRATEGY.md dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md && rg -q "sslmode=disable" dev/guidelines/TESTING-STRATEGY.md && rg -q "PostgreSQL contract" dev/guidelines/RELEASE_PREPARATION.md && rg -qi "ruleset" dev/guidelines/RELEASE_PREPARATION.md && rg -q "contract_groups.json" dev/guidelines/TESTING-STRATEGY.md && rg -qi "whitelist" dev/guidelines/TESTING-STRATEGY.md && ! rg -q "S11|TI0[0-9]|TI10" dev/guidelines/TESTING-STRATEGY.md dev/guidelines/RELEASE_PREPARATION.md dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md && git diff --check` – the three guidelines name the script, the URL shape, the manifest and whitelist rules, the fourth job, and the ruleset step; no story or task ids leaked; whitespace clean
  - **SATISFIES**: S08, SC06

### Testing Strategy

- [TI02–TI05] Layer 2 on real in-memory SQLite prepared by the S02 gate, no mocks; the PostgreSQL entry is Layer 4 (`integration`) on a real server. The `--plain-name` Verify targets use the `[contract:backend.`, `[contract:schema.`, and `[contract:fts.` family prefixes so each task runs every sibling group its proof claims.
- [TI04] Read, overwrite, and delete isolation are three assertions; membership assertions use `unorderedEquals` on id sets; the negative whitelist case is a stale entry, since every fixture term is neutral by construction on both engines.
- [TI06, TI08] Live PostgreSQL 14 is required; without it those tasks report `BLOCKED:` rather than treating the SQLite entry as evidence. None was reachable at spec time (2026-09-02), so no live Proof is bound; the red-at-spec-time surface is `postgres_backend_contract_test.dart`, `contract_groups_check_test.sh`, and the extended `release_check_test.sh`.
- [TI08] ASSUMPTION (AUTO_MODE, 2026-09-02): the job runs the S07/S08/S09 live suites alongside the contract entry. FR9 requires the PostgreSQL-live path to run against a service container on every PR and the plan's sequencing gives no other job that could run them; only the contract entry carries manifest ids, so upstream suites contribute through the exit code alone. If the orchestrator narrows the job to the contract entry, delete the five upstream lines from the script and nothing else changes.
- The proof tool is tested only from bash (`test_workspace.sh` runs it sequentially before any package suite); a Dart test spawning `dart run` is forbidden by the tooling learnings.

### Execution Contract

- Stories S02, S03, S04, S05, S07, and S09 must be complete; consume their fixtures, helpers, repositories, indexes, and gate APIs as-is. A pinned assertion that fails on one backend is returned to that backend's story with the failing group id – do not weaken the group or add a whitelist entry without engine evidence.
- Order: TI01 → TI02 ∥ TI03 ∥ TI04 ∥ TI05 → TI06 → TI07 → TI08 → TI09 → TI10. All commands run from the `../dartclaw-public/` root.
- The public working tree may carry another session's uncommitted edits outside this story's Work Areas; touch only the files named there.
- External gate, not a task: the operator's ruleset step and its `ROADMAP.md` record belong to the milestone close-out (plan owner). This story is complete when TI01–TI10 verify; the first green `PostgreSQL contract` run on the pushed branch is recorded in Implementation Observations.


## Final Validation Checklist

- With `DARTCLAW_TEST_POSTGRES_URL` unset: `bash dev/tools/test_workspace.sh`, `dart analyze --fatal-infos`, `bash dev/tools/fitness/run_all.sh`, `dart run dev/tools/arch_check.dart` are green and no PostgreSQL connection is attempted.
- No `lib/` file changed; no production source reads the manifest, the whitelist, or the report.
- No retired package or file name (`dartclaw_storage`, `dartclaw_config`, `dartclaw_server`, `memory_service.dart`) appears in files this story adds or edits.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart#[contract:backend.transaction]` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --name "[contract:backend.transaction]"`

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart#[contract:schema.orphan_column_tolerance]` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --name "[contract:schema.orphan_column_tolerance]"`

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart#[contract:fts.membership]` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --name "[contract:fts.membership]"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --name "[contract:backend.transaction]"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:backend.transaction]"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --name "[contract:schema.orphan_column_tolerance]"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:schema.orphan_column_tolerance]"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --name "[contract:fts.membership]"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:fts.membership]"`

### Run: 2026-09-05 08:40 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:backend.transaction]"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:backend."`

### Run: 2026-09-05 08:40 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:schema.orphan_column_tolerance]"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:schema."`

### Run: 2026-09-05 08:40 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:fts.membership]"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:fts."`

### Run: 2026-09-05 08:42 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:backend."` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:backend." && test "$(rg -oF "[contract:backend.crud]" packages/dartclaw_core/test/storage/contract/database_backend_contract.dart | wc -l | tr -d " ")" = 1 && test "$(rg -oF "[contract:backend.transaction]" packages/dartclaw_core/test/storage/contract/database_backend_contract.dart | wc -l | tr -d " ")" = 1 && test "$(rg -oF "[contract:backend.sqlite_completion_order]" packages/dartclaw_core/test/storage/contract/database_backend_contract.dart | wc -l | tr -d " ")" = 1 && test "$(rg -oF "[contract:backend.ambiguous_dispatch_no_replay]" packages/dartclaw_core/test/storage/contract/database_backend_contract.dart | wc -l | tr -d " ")" = 1`

### Run: 2026-09-05 08:42 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:fts."` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart --plain-name "[contract:fts." && test "$(tr -d '[:space:]' < packages/dartclaw_core/test/storage/contract/fts_divergence_whitelist.json)" = "[]"`

### Run: 2026-09-08 14:19 UTC – repair-proof

#### DRIFT

- spec-stale: TI05 Verify target repaired | Stale targets: – | `cmd: rg -q "^  dartclaw_workflow:" <(sed -n '/^dev_dependencies:/,$p' packages/dartclaw_core/pubspec.yaml) && ! rg -q "dartclaw_workflow" packages/dartclaw_core/lib && test "$(rg -o "\[contract:repository\.[a-z_]+\]" packages/dartclaw_core/test/storage/contract/repository_contract.dart | sort -u | wc -l | tr -d ' ')" = 8 && dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart && bash dev/tools/fitness/run_all.sh` → `cmd: rg -q "^  dartclaw_workflow:" <(sed -n '/^dev_dependencies:/,$p' packages/dartclaw_core/pubspec.yaml) && ! rg -q "dartclaw_workflow" packages/dartclaw_core/lib && test "$(rg -o "\[contract:repository\.[a-z_]+\]" packages/dartclaw_core/test/storage/contract/repository_contract.dart | sort -u | wc -l | tr -d ' ')" = 8 && dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart`

### Run: 2026-09-08 14:19 UTC – observations

2026-09-08 16:14 CEST owner scheduling override: one focused independent review and relevant checks per story. Full workspace and full fitness runs in task Verify commands are deferred to the final combined A+B gate, with no acceptance requirement removed. The retained command proves the story-local checks; prose referring to full-suite success describes final milestone evidence. Standard fast-tier closure remains; broad integration, platform and release verification run at the end.

### Run: 2026-09-08 17:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI06 Verify target repaired | Stale targets: – | `cmd: test -n "$DARTCLAW_TEST_POSTGRES_URL" && (cd packages/dartclaw_core && dart test --run-skipped -t integration --reporter=failures-only --file-reporter=json:../../build/postgres-contract/verify.json test/storage/contract/postgres_backend_contract_test.dart) && dart run dev/tools/contract_groups_check.dart --manifest packages/dartclaw_core/test/storage/contract/contract_groups.json --expect shared,postgres --report build/postgres-contract/verify.json` → `cmd: (cd packages/dartclaw_core && dart test --reporter=failures-only --file-reporter=json:../../build/postgres-contract/verify-sqlite.json test/storage/contract/sqlite_backend_contract_test.dart) && dart run dev/tools/contract_groups_check.dart --manifest packages/dartclaw_core/test/storage/contract/contract_groups.json --expect shared,sqlite --report build/postgres-contract/verify-sqlite.json && dart analyze --fatal-infos packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart`

### Run: 2026-09-08 17:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI08 Verify target repaired | Stale targets: – | `cmd: rg -q "^  postgres_contract:$" .github/workflows/ci.yml && rg -q "^    name: PostgreSQL contract$" .github/workflows/ci.yml && rg -q "image: postgres:14@sha256:" .github/workflows/ci.yml && rg -q "pg_isready" .github/workflows/ci.yml && rg -q "sslmode=disable" .github/workflows/ci.yml && rg -q "bash dev/tools/postgres_contract.sh" .github/workflows/ci.yml && ! rg -q "if:" <(awk '/^  postgres_contract:$/,/^  [a-z]+:$/' .github/workflows/ci.yml | sed '1d;$d') && rg -q -- "--run-skipped -t integration" dev/tools/postgres_contract.sh && rg -q -- "--expect shared,sqlite" dev/tools/postgres_contract.sh && rg -q -- "--expect shared,postgres" dev/tools/postgres_contract.sh && (unset DARTCLAW_TEST_POSTGRES_URL; bash dev/tools/postgres_contract.sh; test $? = 2) && test -n "$DARTCLAW_TEST_POSTGRES_URL" && bash dev/tools/postgres_contract.sh` → `cmd: rg -q "^  postgres_contract:$" .github/workflows/ci.yml && rg -q "^    name: PostgreSQL contract$" .github/workflows/ci.yml && rg -q "image: postgres:14@sha256:" .github/workflows/ci.yml && rg -q "pg_isready" .github/workflows/ci.yml && rg -q "sslmode=disable" .github/workflows/ci.yml && rg -q "bash dev/tools/postgres_contract.sh" .github/workflows/ci.yml && ! rg -q "if:" <(awk '/^  postgres_contract:$/,/^  [a-z]+:$/' .github/workflows/ci.yml | sed '1d;$d') && rg -q -- "--run-skipped -t integration" dev/tools/postgres_contract.sh && rg -q -- "--expect shared,sqlite" dev/tools/postgres_contract.sh && rg -q -- "--expect shared,postgres" dev/tools/postgres_contract.sh && (unset DARTCLAW_TEST_POSTGRES_URL; bash dev/tools/postgres_contract.sh; test $? = 2)`

### Run: 2026-09-08 17:06 UTC – observations

Owner scheduling override: the updated Verify commands prove local implementation and compilation only. Live integration and Windows/platform acceptance remain PENDING at the final combined A+B gate. Original postponed commands are retained by the repair-proof observations and deferred-live-platform-proofs.json. Do not report those postponed behaviors or milestone release acceptance as passed from a local receipt. Named targeted scenario proofs, the driver feasibility spike and missing-DSN refusal checks remain runnable. Final full-suite evidence may cover duplicate/subset invocations only with explicit owner-to-result mapping; platform and contract-report variants remain distinct.

### Run: 2026-09-08 22:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI05 Verify target repaired | Stale targets: – | `cmd: rg -q "^  dartclaw_workflow:" <(sed -n '/^dev_dependencies:/,$p' packages/dartclaw_core/pubspec.yaml) && ! rg -q "dartclaw_workflow" packages/dartclaw_core/lib && test "$(rg -o "\[contract:repository\.[a-z_]+\]" packages/dartclaw_core/test/storage/contract/repository_contract.dart | sort -u | wc -l | tr -d ' ')" = 8 && dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart` → `cmd: bash -c 'rg -q "^  dartclaw_workflow:" <(sed -n '"'"'/^dev_dependencies:/,$p'"'"' packages/dartclaw_core/pubspec.yaml) && ! rg -q "dartclaw_workflow" packages/dartclaw_core/lib && test "$(rg -o "\[contract:repository\.[a-z_]+\]" packages/dartclaw_core/test/storage/contract/repository_contract.dart | sort -u | wc -l | tr -d '"'"' '"'"')" = 8 && dart test --reporter=failures-only packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart'`

### Run: 2026-09-08 22:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI07 Verify target repaired | Stale targets: – | `cmd: bash dev/tools/contract_groups_check_test.sh && rg -q "contract_groups_check_test.sh" dev/tools/test_workspace.sh && test "$(rg -c "^import 'dart:" dev/tools/contract_groups_check.dart | tr -d ' ')" -ge 2 && ! rg -q "^import 'package:" dev/tools/contract_groups_check.dart && ! rg -qi "threshold|min-groups|count" <(rg -o "'--[a-z-]+'" dev/tools/contract_groups_check.dart)` → `cmd: bash -c 'bash dev/tools/contract_groups_check_test.sh && rg -q "contract_groups_check_test.sh" dev/tools/test_workspace.sh && test "$(rg -c "^import '"'"'dart:" dev/tools/contract_groups_check.dart | tr -d '"'"' '"'"')" -ge 2 && ! rg -q "^import '"'"'package:" dev/tools/contract_groups_check.dart && ! rg -qi "threshold|min-groups|count" <(rg -o "'"'"'--[a-z-]+'"'"'" dev/tools/contract_groups_check.dart)'`

### Run: 2026-09-08 22:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI08 Verify target repaired | Stale targets: – | `cmd: rg -q "^  postgres_contract:$" .github/workflows/ci.yml && rg -q "^    name: PostgreSQL contract$" .github/workflows/ci.yml && rg -q "image: postgres:14@sha256:" .github/workflows/ci.yml && rg -q "pg_isready" .github/workflows/ci.yml && rg -q "sslmode=disable" .github/workflows/ci.yml && rg -q "bash dev/tools/postgres_contract.sh" .github/workflows/ci.yml && ! rg -q "if:" <(awk '/^  postgres_contract:$/,/^  [a-z]+:$/' .github/workflows/ci.yml | sed '1d;$d') && rg -q -- "--run-skipped -t integration" dev/tools/postgres_contract.sh && rg -q -- "--expect shared,sqlite" dev/tools/postgres_contract.sh && rg -q -- "--expect shared,postgres" dev/tools/postgres_contract.sh && (unset DARTCLAW_TEST_POSTGRES_URL; bash dev/tools/postgres_contract.sh; test $? = 2)` → `cmd: bash -c 'rg -q "^  postgres_contract:$" .github/workflows/ci.yml && rg -q "^    name: PostgreSQL contract$" .github/workflows/ci.yml && rg -q "image: postgres:14@sha256:" .github/workflows/ci.yml && rg -q "pg_isready" .github/workflows/ci.yml && rg -q "sslmode=disable" .github/workflows/ci.yml && rg -q "bash dev/tools/postgres_contract.sh" .github/workflows/ci.yml && ! rg -q "if:" <(awk '"'"'/^  postgres_contract:$/,/^  [a-z]+:$/'"'"' .github/workflows/ci.yml | sed '"'"'1d;$d'"'"') && rg -q -- "--run-skipped -t integration" dev/tools/postgres_contract.sh && rg -q -- "--expect shared,sqlite" dev/tools/postgres_contract.sh && rg -q -- "--expect shared,postgres" dev/tools/postgres_contract.sh && (unset DARTCLAW_TEST_POSTGRES_URL; bash dev/tools/postgres_contract.sh; test $? = 2)'`

### Run: 2026-09-08 22:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI09 Verify target repaired | Stale targets: – | `cmd: rg -q 'for required_job in .*"PostgreSQL contract"' dev/tools/release_check.sh && bash dev/tools/release_check_test.sh && diff <(rg -o '^    name: .*' .github/workflows/ci.yml | sed 's/^    name: //' | sort) <(rg -o 'for required_job in .*; do' dev/tools/release_check.sh | rg -o '"[^"]+"' | tr -d '"' | sort)` → `cmd: bash -c 'rg -q '"'"'for required_job in .*"PostgreSQL contract"'"'"' dev/tools/release_check.sh && bash dev/tools/release_check_test.sh && diff <(rg -o '"'"'^    name: .*'"'"' .github/workflows/ci.yml | sed '"'"'s/^    name: //'"'"' | sort) <(rg -o '"'"'for required_job in .*; do'"'"' dev/tools/release_check.sh | rg -o '"'"'"[^"]+"'"'"' | tr -d '"'"'"'"'"' | sort)'`

### Run: 2026-09-08 23:51 UTC – repair-proof

#### DRIFT

- spec-stale: TI01 Verify target repaired | Stale targets: – | `cmd: test -f packages/dartclaw_core/test/storage/contract/contract_groups.json && rg -q "@Tags\(\['integration'\]\)" packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart && ! rg -q "@Tags|Postgres" packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart && ! rg -q "markTestSkipped" packages/dartclaw_core/test/storage/contract && (unset DARTCLAW_TEST_POSTGRES_URL; out="$(dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart 2>&1)"; test $? -ne 0 && rg -q "DARTCLAW_TEST_POSTGRES_URL" <<< "$out")` → `cmd: bash -c 'test -f packages/dartclaw_core/test/storage/contract/contract_groups.json && rg -q "@Tags\(\['"'"'integration'"'"'\]\)" packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart && ! rg -q "@Tags|Postgres" packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart && ! rg -q "markTestSkipped" packages/dartclaw_core/test/storage/contract && (unset DARTCLAW_TEST_POSTGRES_URL; out="$(dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart 2>&1)"; test $? -ne 0 && rg -q "DARTCLAW_TEST_POSTGRES_URL" <<< "$out")'`

### Run: 2026-09-08 23:51 UTC – observations

The manifest is the expected group inventory, not a filter that suppresses declarations. Shared tests register unconditionally and backend-specific groups use the backend kind; the exact JSON report check rejects omitted or unexpected groups. The five review fixes also require exact schema/marker and write-free current reopen, full WorkflowRun round trips, an outside-transaction uniqueness conflict, and complete successful reporter termination. All PostgreSQL live and platform acceptance remains pending final combined verification. TI01 explicitly uses bash for its here-string.

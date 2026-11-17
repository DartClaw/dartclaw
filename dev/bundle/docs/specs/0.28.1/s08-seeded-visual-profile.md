# Seeded Visual Profile

**Plan**: dev/bundle/docs/specs/0.28.1/plan.json
**Story-ID**: S08

## Feature Overview and Goal

**Intent**: The `visual` profile claims seeded Tasks and Workflows content but writes no task or run rows since 0.27 moved the server to PostgreSQL, so the factory screens cannot be captured against realistic states.

**Expected Outcomes**:

- [OC01] Starting `visual` shows tasks in `accepted`, `failed` and `review`, each with a detail page that renders.
- [OC02] Starting `visual` shows workflow runs in `completed`, `failed` and `awaitingApproval`, each with step tasks, and the awaiting run's detail shows its pending approval message.
- [OC03] A storage schema change the seed no longer satisfies fails a test, not a capture.
- [OC04] The profile's launcher, README, testing README and `.gitignore` describe only data the profile has.


## Required Context

Paths are relative to the public repo root (`../dartclaw-public/` from the private repo), where this FIS executes from its exported copy and where `cmd:` proofs run; `docs/specs/` and `docs/research/` paths name this plan's private sources, exported to `dev/bundle/docs/`.

- `docs/specs/0.28.1/prd.md#fr10-seeded-visual-profile` – the contract and acceptance criteria.
- `docs/specs/0.28.1/prd.md#data-requirements` – rows to write and the `_approval.pending.stepId` context key.
- `packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring` – how the server builds its schema gate, repositories and transactor (the `serving` branch of its task-database open); the seed builds the same ones.
- `packages/dartclaw_workflow/lib/src/workflow/workflow_task_factory.dart#createWorkflowTaskTriple` – the write order for a workflow step: agent execution, task, step execution, in one transaction.
- `packages/dartclaw_workflow/lib/src/workflow/approval_step_runner.dart` – the run, error message and context keys the server writes when a run parks at an approval step; the awaiting run must match them.
- `dev/testing/scenarios/web-ui-visual-smoke-desktop.md#s5-verify-tasks-list-and-seeded-task-detail` – navigates to task `8e7eeab8-8e32-4f14-8687-0378f4591b2e`, so that id stays seeded.


## Acceptance Scenarios

- **S01 [OC01] [runtime] Tasks page shows each seeded state**
  - **Given** `bash dev/testing/profiles/visual/run.sh` has started against its disposable PostgreSQL
  - **When** the Tasks page and each seeded task's detail page are opened with the profile token
  - **Then** the list contains tasks in `accepted`, `failed` and `review`, every detail page renders its task rather than a missing-state fallback, and `/tasks/8e7eeab8-8e32-4f14-8687-0378f4591b2e` is the `review` task

- **S02 [OC02] [runtime] Workflows page shows each seeded run with its step tasks**
  - **Given** the profile has started
  - **When** the Workflows page and each seeded run's detail page are opened
  - **Then** runs appear as `completed`, `failed` and `awaitingApproval`, each detail lists its step tasks with matching step statuses, and the awaiting run's detail shows its approval request message with the approval step named

- **S03 [OC03] [runtime] Seed reads back through the server's repositories**
  - **Given** a PostgreSQL namespace prepared from the current storage schema
  - **When** the seed runs and its rows are read back through the task, workflow run and step execution repositories
  - **Then** each seeded task and run reads back in its state, the awaiting run's pending step id names an approval step of its stored definition, and every step task has a step execution row; a seed column the schema no longer has fails the run with the database's error

- **S04 [OC01,OC02] [runtime] Starting again on an already seeded database**
  - **Given** a persistent `DARTCLAW_POSTGRES_URL` database that already holds the seed
  - **When** the seed runs a second time
  - **Then** it completes without error and the task and run counts are unchanged


## Structural Criteria

- **SC01** The seed writes only through the server's repositories, transactor and schema gate, with no SQL of its own, so a schema change surfaces as one failure, not a second encoding to maintain.
- **SC02** Every committed `data/tasks/<id>/artifacts` directory and every committed session keyed `agent:main:task:<id>` belongs to a seeded task of that id, with the artifact row naming the file and the session id on the task's agent execution row, so no fixture is orphaned.
- **SC03** Workflow definitions in seeded runs come from the shipped built-in definitions, parsed by the shipped parser, so a definition-shape change breaks the seed test, not the page.
- **SC04** The seed adds no workspace dependency and respects `dev/package_tiers.txt`.
- **SC05** `dev/testing/.gitignore` has no re-include for the deleted `profiles/visual/data/dartclaw.db`, and the profile docs name only data the seed and committed fixtures provide.


## Scope & Boundaries

### Work Areas
- `apps/dartclaw_cli/tool/seed_visual_profile.dart` – new: `seedVisualProfile` library function plus a `main` entry.
- `apps/dartclaw_cli/test/tool/seed_visual_profile_live_test.dart` – new live PostgreSQL test.
- `dev/testing/profiles/visual/run.sh` – seeds before `serve`.
- `dev/tools/postgres_contract.sh` – runs the new test in the CLI group of the plain lane.
- `dev/testing/profiles/visual/README.md`, `dev/testing/README.md`, `dev/testing/.gitignore` – accurate descriptions.

### What We're NOT Doing
- A new profile or a checked-in database dump – the owner decided the seed is restored in `visual` (PRD Decisions Log), and a dump rots with the schema.
- Seeding `plain`, `governance` or other profiles – FR10 names `visual` only.
- Seeded live execution: runs are rows, nothing resumes or advances them – workflow execution belongs to the `workflows` profile.
- A `dartclaw` CLI command for seeding – the entry stays a `tool/` script, as the memory-seed entry in `dartclaw_testing` is (`dartclaw_testing` cannot depend on the workflow package, and a shipped hidden command is bloat).
- Edits to the visual smoke scenarios, `CHANGELOG.md`, `DECISIONS.md` or LEARNINGS – story S09 closes documentation.


## Architecture Decision

**Approach**: `tool/seed_visual_profile.dart` loads the profile config as `serve` does, opens the PostgreSQL backend from it, runs `PostgresSchemaGate.prepare`, then writes through `DatabaseAgentExecutionRepository`, `DatabaseTaskRepository`, `DatabaseWorkflowStepExecutionRepository`, `DatabaseWorkflowRunRepository` and `DatabaseExecutionRepositoryTransactor`. `run.sh` calls it between PostgreSQL start and `serve`.
**Why this over the floor**: the floor is leaving the profile unseeded, which FR10 rules out. Of the seed shapes, `StorageWiring` itself is not used because its non-serving, non-standalone mode also wires personal memory (workspace directories and indexes) the seed has no use for; the repositories are the same objects it hands the server, so drift still surfaces at the same SQL.
**Flow**: `run.sh` starts PostgreSQL, generates embedded assets, runs the seed against the copied data directory's config, then `serve`. The seed closes its backend before `serve` takes the serving interlock.


## Constraints & Gotchas

- **Constraint**: `run.sh` runs `embed_assets.dart` only after its snapshot branch, and the seed imports the generated `embeddedWorkflowAssets` – Workaround: run `embed_assets.dart` before the seed so both launch branches have it.
- **Constraint**: the live test needs a disposable PostgreSQL 14 through `DARTCLAW_TEST_POSTGRES_URL` and is integration-tagged, so the `fast` and `full` tiers skip it – the PostgreSQL contract gate is where it fails on drift. Provide the database as `dev/guidelines/TESTING-STRATEGY.md` § PostgreSQL contract describes.
- **Constraint**: the seed is re-run on persistent data (`DARTCLAW_VISUAL_DATA_DIR`, or a persistent `DARTCLAW_POSTGRES_URL`), and rows have fixed ids, so it must detect its own earlier rows (S04).
- **Constraint**: timestamps derive from an injectable `now` (default the seed time), so pages show recent activity and the test stays deterministic.


## Implementation Plan

### Implementation Tasks

- **TI01** `seedVisualProfile` writes three standalone tasks, each with an agent execution row: `accepted` (`35deacb6-7c33-47db-8dc6-4bf1a2a68dc8`, with its committed artifact), `failed` (`157dc0bb-7c00-4a3a-8d26-8a99d4b7aad6`), and `review` (`8e7eeab8-8e32-4f14-8687-0378f4591b2e`)
  - Timestamps, `completedAt` and transitions follow `Task.transition`; titles and descriptions match the first message of each task's committed session.
  - Sessions and artifacts link per SC02: artifact `path` is the absolute file under the data directory `run.sh` serves from, as `task_review_service.dart`'s artifact persistence records it.
  - **Verify**: `cmd: cd apps/dartclaw_cli && dart test --run-skipped -t integration test/tool/seed_visual_profile_live_test.dart` – with `DARTCLAW_TEST_POSTGRES_URL` set; the tasks read back with those ids and statuses, artifact rows and session ids resolving to existing files and sessions.
  - **SATISFIES**: S01, S03, SC01, SC02

- **TI02** `seedVisualProfile` writes three workflow runs from built-in definitions: `completed`, `failed`, and `awaitingApproval` parked at an approval step, each with step tasks and step execution rows written in the factory's order
  - The awaiting run is `implement-prd` (`plan-approval` step, `PLAN_REVIEW` true) with the context and `errorMessage` the approval runner writes, and step tasks only for steps before the gate. The failed run has one failed step task and a `failed` run error message.
  - Parse definitions from `embeddedWorkflowAssets` with `WorkflowDefinitionParser` and store `toJson()` as `definitionJson`.
  - The remaining committed task-session and artifact ids (`8d9f1f64-81a1-4ac1-be99-0dead1379c02`, `c27b0349-b3ef-44ee-b6ae-6fc004c662d0`, `41111111-1111-4111-8111-000000000010`, `42222222-2222-4222-8222-000000000010`, `43333333-3333-4333-8333-000000000005`) become step tasks of these runs at any step index their definition has, so SC02 holds.
  - **Verify**: `cmd: cd apps/dartclaw_cli && dart test --run-skipped -t integration test/tool/seed_visual_profile_live_test.dart` – with `DARTCLAW_TEST_POSTGRES_URL` set; run statuses, per-run step task counts and statuses, each run's stored definition parses, the awaiting run's `_approval.pending.stepId` names an approval step and its `<step>.approval.message` is non-empty.
  - **SATISFIES**: S02, S03, SC01, SC02, SC03

- **TI03** A second `seedVisualProfile` call on a seeded database is a no-op
  - **Verify**: `cmd: cd apps/dartclaw_cli && dart test --run-skipped -t integration test/tool/seed_visual_profile_live_test.dart` – with `DARTCLAW_TEST_POSTGRES_URL` set; second call completes and task and run counts equal the first call's.
  - **SATISFIES**: S04

- **TI04** `main` of `seed_visual_profile.dart` takes `--config`, opens PostgreSQL from that config (`loadCliConfig`, `postgresBackendFactory` with `resolveDatabaseDsn`), prepares the schema, seeds with the config's data directory, closes the backend, and exits non-zero with the error on failure
  - **Verify**: `cmd: dart analyze apps/dartclaw_cli` – clean; the runtime run in the Final Validation Checklist exercises `main`.
  - **SATISFIES**: SC01, SC04

- **TI05** `seed_visual_profile_live_test.dart` seeds a `withPostgresBackend` namespace (`packages/dartclaw_core/test/storage/postgres_live_support.dart`) and asserts S01, S02, S03, S04 and SC02 through the repositories, including that every `data/tasks/<id>` directory and task-keyed session in the committed visual data has a seeded task
  - Pattern: `apps/dartclaw_cli/test/commands/rebuild_index_command_postgres_live_test.dart` (`@Tags(['integration'])`, the shared support import).
  - **Verify**: `cmd: cd apps/dartclaw_cli && dart test --run-skipped -t integration test/tool/seed_visual_profile_live_test.dart` – with `DARTCLAW_TEST_POSTGRES_URL` set; passes, and a temporarily renamed seeded column in the seed makes it fail on the database error (revert after).
  - **SATISFIES**: S03, SC02

- **TI06** `run.sh` runs `embed_assets.dart`, then the seed against `${CONFIG}` after `profile_postgres_start`, before either `serve` branch, and a seed failure aborts the launcher
  - **Verify**: `inspect: dev/testing/profiles/visual/run.sh:1` – the seed precedes the snapshot branch and the source branch; S01 and S02 close on the Final Validation run.
  - **SATISFIES**: S01, S02, S04

- **TI07** `dev/tools/postgres_contract.sh` runs `seed_visual_profile_live_test.dart` in the CLI group of the plain lane
  - **Verify**: `cmd: git grep -q seed_visual_profile_live_test -- dev/tools/postgres_contract.sh && bash dev/tools/postgres_contract_test.sh` – the script names the test and its own stubbed harness test still passes.
  - **SATISFIES**: S03

- **TI08** The profile docs and ignore file describe only existing data: `run.sh` header and `visual/README.md` (§ Seeded Coverage) name the seeded task and run states and the PostgreSQL seed step; the `dev/testing/README.md` `visual` row says the same; the stale `!profiles/visual/data/dartclaw.db` re-include is gone
  - **Verify**: `cmd: test -z "$(git grep -n 'profiles/visual/data/dartclaw.db' -- dev/testing/.gitignore)" && dart test dev/fitness/test/dependency_direction_test.dart` – no stale re-include, tier direction holds; README and `run.sh` prose are read against the seed (`inspect: dev/testing/profiles/visual/README.md:1`).
  - **SATISFIES**: SC04, SC05


## Final Validation Checklist

- Run `bash dev/testing/profiles/visual/run.sh`, then with the token from `dev/testing/profiles/visual/data/gateway_token` open `/tasks`, each seeded task's detail, `/workflows` and each seeded run's detail (visual validation per `dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md`). Every state in S01 and S02 is visible, no page shows a missing-state fallback, the awaiting run shows its approval message, `/tasks/8e7eeab8-8e32-4f14-8687-0378f4591b2e` renders, and server startup logs no schema or seed error.

## Discovered Requirements

- **Seed authority**. **Description**: S03 exposes an execution-surface task hold through internal `configJson` and protects workflow approval markers from step outputs; public task input still rejects client underscore keys. **Rationale**: The seed runs after those ownership guards exist. **Interpretation**: Use the server storage layer as specified. If a fixture needs an internal task hold, write it through host-owned storage, never client input or model-result merge. Do not add a new seeded state: the existing accepted/failed/review and completed/failed/awaitingApproval scope remains. **Traced from**: S03/TI04, S03/TI07. **Date**: 2026-11-17.

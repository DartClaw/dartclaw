# S25 — Level-2 Fitness Functions (6 tests) + TD-046 + TD-074

**Plan**: ../plan.md
**Story-ID**: S25

## Feature Overview and Goal

Author six Level-2 fitness test files at `packages/dartclaw_testing/test/fitness/` (the L1 location S10 froze) plus an integration crash-recovery smoke test (TD-046) that asserts reserve/start → hard kill → restart → orphan cleanup → recovery notice; revalidate the Homebrew/archive asset path against the current 0.16.4+ layout (TD-074); and audit every governance script under `dev/tools/` for path-stale silent passes (the failure mode that masked TD-099/100/101 on `main`). The L2 suite is the cross-package invariant net — dependency direction, src-import hygiene, testing-package deps shape, barrel-export ceilings, cross-consumer enum exhaustiveness, per-file method-count ceiling — runnable on every PR within the ≤5 min budget.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S25 — Level-2 Fitness Functions (6 tests) + TD-046 + TD-074" entry under Story-Scoped File Map; Shared Decisions #4, #10, #11, #16, #20, #21; Binding PRD Constraints #2, #21, #38, #40, #70, #83, #84)_

## Required Context

### From `prd.md` — "FR6: Fitness Functions + Dartdoc Governance" (L2 list)
<!-- source: ../prd.md#fr6-fitness-functions--dartdoc-governance -->
<!-- extracted: e670c47 -->
> **Level-2 (≤5 min, every PR):**
> 1. `dependency_direction_test.dart` — encode allowed pkg edges as data; reject violations
> 2. `src_import_hygiene_test.dart` — no cross-pkg `src/` imports
> 3. `testing_package_deps_test.dart` — testing pkg only depends on core/models/security (+ http if needed)
> 4. `barrel_export_count_test.dart` — per-pkg soft caps (core ≤80, config ≤50, workflow ≤35, others ≤25)
> 5. `enum_exhaustive_consumer_test.dart` — runtime scan over SSE serializers, AlertClassifier/Formatter, UI badge maps, CLI status renderers asserting every `WorkflowRunStatus` / `TaskStatus` / equivalent sealed-enum value is handled
> 6. `max_method_count_per_file_test.dart` — per-file ≤40 public+private methods (allowlist current offenders with explicit shrink targets)

### From `plan.md` — "S25: Level-2 Fitness Functions (6 tests)"
<!-- source: ../plan.md#s25-level-2-fitness-functions-6-tests -->
<!-- extracted: e670c47 -->
> **Scope**: Add 6 Level-2 fitness functions as `test/fitness/*.dart` files plus one cross-package smoke test (TD-046). (a) `dependency_direction_test.dart` — encode allowed package edges as data (map from package name to set of allowed dependencies in both library and test scope), fail on any `import 'package:X/...'` in `packages/Y/lib/` that violates. This table accepts the 0.16.4 surgical release-gate edge `dartclaw_workflow -> dartclaw_security`, while S12 still removes the separate `dartclaw_workflow -> dartclaw_storage` runtime edge. (b) `src_import_hygiene_test.dart` — no file in `packages/<X>/lib/` may `import 'package:<Y>/src/...'` where X != Y. (c) `testing_package_deps_test.dart` — assert `dartclaw_testing/pubspec.yaml` lists only core/models/security (+ http if needed) — enforces S11 post-state. (d) `barrel_export_count_test.dart` — per-package soft limits (core ≤80, config ≤50, workflow ≤35, others ≤25). Catches CRP drift. **(e) `enum_exhaustive_consumer_test.dart`** — runtime scan over SSE envelope serializers, `AlertClassifier`, `AlertFormatter`, UI badge maps, and CLI status renderers asserting that every `WorkflowRunStatus` / `TaskStatus` / equivalent sealed-enum value is handled by each consumer. **(f) `max_method_count_per_file_test.dart`** — per-file ceiling of ≤40 public + private methods (allowlist current offenders with explicit shrink targets). The FIS should also extend either `dependency_direction_test.dart` or a small workflow-specific companion check so production workflow runtime files cannot import `SqliteWorkflowRunRepository` after S12.
>
> **TD-046 — Crash-recovery smoke test**: integration smoke at `packages/dartclaw_server/test/integration/crash_recovery_smoke_test.dart` that exercises reserve/start → hard kill → restart → orphan cleanup + recovery notice. Tag `@Tags(['integration'])` so it gates release-prep, not every-PR.
>
> **TD-074 — Homebrew/asset/archive revalidation**: dry-run the archive/Homebrew path against current 0.16.4+ asset layout. Verify the unpacked archive contains the expected embedded templates, static assets, DC-native skill sources, and runtime-provisioning hooks. Update formula/archive docs if path drift appears; otherwise record the pass and delete TD-074 at closeout.
>
> **Acceptance Criteria**:
> - [ ] 6 fitness-function test files exist and pass (must-be-TRUE)
> - [ ] Allowed-edges table for `dependency_direction_test.dart` is a committed data file with rationale comments (must-be-TRUE)
> - [ ] `testing_package_deps_test.dart` rejects any addition of `dartclaw_server` to testing's pubspec (must-be-TRUE)
> - [ ] `enum_exhaustive_consumer_test.dart` covers `WorkflowRunStatus` + at least one other sealed-enum type; allowlist documents any unhandled consumer with rationale (must-be-TRUE)
> - [ ] `max_method_count_per_file_test.dart` applies ≤40 methods/file; `task_executor.dart` and `foreach_iteration_runner.dart` entries in allowlist have explicit shrink targets (must-be-TRUE)
> - [ ] Workflow runtime files have a fitness guard against concrete `SqliteWorkflowRunRepository` imports after S12 (must-be-TRUE)
> - [ ] **TD-046** Crash-recovery smoke test exists and exercises reserve/start → hard kill → restart → orphan cleanup + recovery notice; gated by `@Tags(['integration'])` (must-be-TRUE)
> - [ ] TD-046 entry deleted from public `dev/state/TECH-DEBT-BACKLOG.md` at sprint close
> - [ ] **TD-074** Homebrew/archive asset revalidation dry-run recorded; formula/archive docs updated if needed; TD-074 deleted or narrowed (must-be-TRUE)
> - [ ] **Fitness-script blackout audit** — scan every governance script under `dev/tools/` and any CI-invoked workspace script for path-stale silent passes; record findings (any other script that was silently passing because its inputs no longer existed) and either fix or file as new TDs (must-be-TRUE)
> - [ ] CI pipeline runs Level-2 suite on every PR (can be separate job from Level-1 for parallelism)
> - [ ] Level-2 suite total runtime ≤5 min

### From `.technical-research.md` — Shared Architectural Decision #4 (S10 + S11 → S25)
<!-- source: ../.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> **4. S10 + S11 → S25 — L2 fitness contract** — 6 L2 tests at the same fitness directory. `dependency_direction_test.dart` encodes allowed pkg edges as committed data with rationale; accepts surgical `dartclaw_workflow → dartclaw_security` edge, rejects `dartclaw_workflow → dartclaw_storage` post-S12. `testing_package_deps_test.dart` enforces `dartclaw_testing/pubspec.yaml` lists only core/models/security (+ http if needed). `barrel_export_count_test.dart` per-pkg soft caps: core ≤80, config ≤50, workflow ≤35, others ≤25. PRODUCERS: S10 (test directory + allowlist conventions); S11 (final post-extraction `dartclaw_testing` deps shape). CONSUMER: S25.

### From `.technical-research.md` — Binding PRD Constraints (S25-applicable)
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #2 (Constraint): "No new dependencies in any package. Fitness functions use existing `test` + `analyzer` + `package_config`." — Applies to all stories.
> #21 (FR3): "`testing_package_deps_test.dart` + `no_cross_package_env_plan_duplicates_test.dart` fitness functions pass." — S10/S25/S32 (S25 ships `testing_package_deps_test.dart`).
> #38 (FR6): "L2 fitness: `dependency_direction_test.dart`, `src_import_hygiene_test.dart`, `testing_package_deps_test.dart`, `barrel_export_count_test.dart`, `enum_exhaustive_consumer_test.dart`, `max_method_count_per_file_test.dart`." — S25.
> #40 (FR6): "Tests + dartdoc lint documented in `TESTING-STRATEGY.md`." — S10, S25, S37.
> #70 (NFR Performance): "Level-1 checks ≤30s; Level-2 suite ≤5 min." — S10, S25.
> #83 (FR6): "Each fitness function has a documented 'how to resolve a failure' section in its own `README.md` or in `TESTING-STRATEGY.md`." — S10, S25.
> #84 (Data Requirements): "Fitness-function allowlists are plain-text files under `test/fitness/allowlist/`." — S10, S25.

### From `.technical-research.md` — Cross-cutting Decisions #10, #11, #16, #20, #21
<!-- source: ../.technical-research.md#cross-cutting-non-arrow-shared-decisions -->
<!-- extracted: e670c47 -->
> **10. Fitness test location** — `packages/dartclaw_testing/test/fitness/**/*.dart` is the single source of truth. Established by S10, reused by S25, referenced by S28.
> **11. Allowlist file shape** — committed plain-text under `packages/dartclaw_testing/test/fitness/allowlist/<test-name>.txt`. Each line: `pattern  # rationale-or-shrink-target`. Rationale comment mandatory.
> **16. Sealed events / `DartclawEvent`** — `sealed class DartclawEvent` with exhaustive `switch (event)` expressions in `AlertClassifier`/`AlertFormatter` (and per S25 `enum_exhaustive_consumer_test.dart` — UI badge maps, SSE serializers, CLI status renderers).
> **20. Public API barrels** — every `export 'src/...'` uses `show` post-S09 + S10. Per-pkg soft caps (S25): `dartclaw_core ≤80`, `dartclaw_config ≤50`, `dartclaw_workflow ≤35`, others ≤25.
> **21. Fitness function "how to resolve" docs** — each L1/L2 fitness has documented resolution in its own `README.md` next to the test or in `docs/guidelines/TESTING-STRATEGY.md`.

### From `dev/state/TECH-DEBT-BACKLOG.md` — TD-046 + TD-074 entries
<!-- source: ../../../state/TECH-DEBT-BACKLOG.md#td-046--killrestart-crash-recovery-scenario-lacks-automated-validation -->
<!-- extracted: e670c47 -->
> **TD-046**: "Add an integration or smoke test that exercises reserve/start -> hard kill -> restart -> orphan cleanup/recovery notice. Prefer a scripted CLI/profile test over a unit test so real persistence and startup wiring are covered." Affects: `packages/dartclaw_server/lib/src/turn_runner.dart`, `apps/dartclaw_cli/lib/src/commands/service_wiring.dart`, `packages/dartclaw_storage/lib/src/storage/turn_state_store.dart`. Trigger: "Before calling the operational-hygiene hardening fully closed, before SDK publish, or whenever crash-recovery behavior is touched again."
>
> **TD-074**: "dry-run a Homebrew install from a local tap; verify the unpacked archive contains the expected skill source / template / static-asset trees; update the formula if any path drift surfaced." Affects: `dev/tools/build.sh`, asset-bundling path, Homebrew formula, archive packaging.

## Deeper Context

- `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` — reference Dart-only fitness style (regex import scanning, `dart:io` directory walk, repo-root resolution, `package:test` usage). **Mirror this style for all six new tests.** Already includes its own `_knownViolations` allowlist pattern + a "How to resolve a legitimate violation" docstring header that S25 should emulate.
- `packages/dartclaw_testing/test/fitness/allowlist/` — the directory S10 establishes; S25 adds six more `<test-name>.txt` files alongside.
- `packages/dartclaw_testing/test/fitness/README.md` (created by S10) — extend with one section per L2 test in the same shape.
- `dev/tools/arch_check.dart:13-54` — existing dependency-graph allowlist as committed data; S25 ports this pattern into `dependency_direction_test.dart`. **Read first** to seed the data table; do not call into `arch_check.dart` from the test.
- `dev/tools/run-fitness.sh` (created by S10) — entry point; `dart test packages/dartclaw_testing/test/fitness/` already runs both L1 and L2 by default. The `@Tags(['integration'])` filter is what splits TD-046 off the per-PR run.
- `dev/tools/fitness/check_workflow_server_imports.sh` — to be retired or audited as part of the fitness-script blackout audit; S28's `workflow_task_boundary_test.dart` covers the workflow→server import dimension. The blackout-audit task is what decides the fate of every other `dev/tools/*.sh` / `dev/tools/fitness/*.{sh,dart}` governance script.
- `packages/dartclaw_models/lib/src/workflow_run.dart:170-197` — `WorkflowRunStatus` enum (7 values: `pending`, `running`, `paused`, `awaitingApproval`, `completed`, `failed`, `cancelled`) — the canonical sealed-enum target for `enum_exhaustive_consumer_test.dart`.
- `packages/dartclaw_core/lib/src/task/task_status.dart:1-59` — `TaskStatus` enum (9 values: `draft`, `queued`, `running`, `interrupted`, `review`, `accepted`, `rejected`, `cancelled`, `failed`) — second sealed-enum target.
- `packages/dartclaw_server/lib/src/templates/workflow_detail.dart` + `apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart` — known consumer surfaces of `WorkflowRunStatus.*` patterns; the test scans these for switch coverage.
- `dev/state/TECH-DEBT-BACKLOG.md` — TD-046 entry at line 649; TD-074 entry at line 433. Sprint-close hygiene removes both.
- `dev/specs/0.16.5/plan.md` line 19 + 894 — fitness-script blackout audit context; the audit must enumerate `dev/tools/` governance scripts and cross-check that each is still operating on inputs that exist on `main`.

## Success Criteria (Must Be TRUE)

- [ ] Six Dart L2 fitness test files exist at `packages/dartclaw_testing/test/fitness/`: `dependency_direction_test.dart`, `src_import_hygiene_test.dart`, `testing_package_deps_test.dart`, `barrel_export_count_test.dart`, `enum_exhaustive_consumer_test.dart`, `max_method_count_per_file_test.dart` — and all six pass `dart test packages/dartclaw_testing/test/fitness/` against current `main`. **Proof**: TI01–TI06 Verify lines + Scenario "Happy L2 run".
- [ ] Allowed-edges table for `dependency_direction_test.dart` is a committed data file at `packages/dartclaw_testing/test/fitness/allowlist/dependency_direction.txt` with one rationale comment per edge. **Baseline-discovery sub-step (per cross-cutting review F3)**: TI01 first reads the actual sanctioned-deps from `dev/tools/arch_check.dart:13-54` (`_expectedWorkspaceDependencies`) AND each `packages/<pkg>/pubspec.yaml`. The allowlist mirrors that observed set verbatim — every entry justified with a rationale comment. The surgical `dartclaw_workflow → dartclaw_security` edge lands ONLY if observed in source (not assumed from Shared Decision wording). The post-S12 invariant `dartclaw_workflow → dartclaw_storage` MUST NOT appear; verify S12 has shipped before measuring. **Proof**: TI01 Verify line + Scenario "New edge added must be data-file update".
- [ ] `testing_package_deps_test.dart` rejects any addition of `dartclaw_server` to `packages/dartclaw_testing/pubspec.yaml` `dependencies:` block. **Proof**: TI03 Verify line — inject + remove `dartclaw_server: path: ../dartclaw_server` and confirm failure.
- [ ] `enum_exhaustive_consumer_test.dart` covers `WorkflowRunStatus` (7 values) and `TaskStatus` (9 values) with a documented set of consumer surfaces (SSE envelope serializers, `AlertClassifier`/`AlertFormatter` if/where they reference these enums, UI badge maps in `packages/dartclaw_server/lib/src/templates/`, CLI status renderers in `apps/dartclaw_cli/lib/src/commands/workflow/`); allowlist `enum_exhaustive_consumer.txt` documents any deliberately-unhandled consumer with rationale (e.g. JSON serializer that round-trips by name and does not enumerate values). **Proof**: TI05 Verify line + Scenario "Cross-consumer enum-exhaustiveness regression caught".
- [ ] `max_method_count_per_file_test.dart` enforces ≤40 public + private methods per file under `packages/<X>/lib/src/` and `apps/<X>/lib/src/`; allowlist `max_method_count_per_file.txt` lists `packages/dartclaw_server/lib/src/task/task_executor.dart` and `packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart` with **explicit shrink targets** ("≤40 by 0.16.6 once S33/S16 binding-coordinator extraction settles" and "≤40 by 0.16.6 once S15 state-machine extraction settles", respectively). **Proof**: TI06 Verify line.
- [ ] `dependency_direction_test.dart` (or a small companion check inside the same file) explicitly fails on any `import 'package:dartclaw_storage/src/...sqlite_workflow_run_repository...';` from production workflow code (`packages/dartclaw_workflow/lib/`); allowlist for this rule is intentionally empty post-S12. **Proof**: TI01 Verify line — synthetic injection of a `SqliteWorkflowRunRepository` import in a workflow lib file fails the test.
- [ ] **TD-046** integration smoke test exists at `packages/dartclaw_server/test/integration/crash_recovery_smoke_test.dart`, tagged `@Tags(['integration'])`, that scripts: (1) reserve a turn; (2) start it; (3) hard-kill the process before completion; (4) restart the server; (5) assert orphan-turn detection + cleanup from the SQLite `turn_state_store`; (6) assert the one-time recovery notice is emitted exactly once. **Proof**: TI08 Verify line + Scenario "TD-046 reserve/start → hard kill → restart".
- [ ] TD-046 entry deleted from `dev/state/TECH-DEBT-BACKLOG.md` at sprint close (sprint-close hygiene step — Implementation Observations records the closure commit). **Proof**: TI14 Verify line.
- [ ] **TD-074** Homebrew/archive revalidation dry-run executed and recorded under `dev/specs/0.16.5/.technical-research.md` § "S25 — TD-074 dry-run record" (or in this FIS's Implementation Observations); formula or archive docs updated if any path drift surfaced; otherwise TD-074 entry deleted from `TECH-DEBT-BACKLOG.md`. **Proof**: TI09 Verify line + TI14.
- [ ] Fitness-script blackout audit completed: every script under `dev/tools/` (top-level) and `dev/tools/fitness/` is enumerated; for each, recorded whether it is invoked by CI / `release_check.sh` / a dev workflow, and whether its input paths still exist post-restructure. Any script silently passing on missing inputs is either fixed in this story (if trivial) or filed as a new TD entry. The audit log lives in this FIS's Implementation Observations. **Proof**: TI10 Verify line.
- [ ] CI pipeline (the same surface used by `dev/tools/run-fitness.sh` from S10) runs the L2 suite on every PR; total wall-clock for L2 ≤5 min on a clean checkout (Constraint #70). The crash-recovery smoke test runs as a separate `dart test -t integration` job, not on every PR. **Proof**: TI11 + TI12 Verify lines.
- [ ] Each L2 fitness test has a "How to resolve a failure" section in `packages/dartclaw_testing/test/fitness/README.md` (extending the L1 README authored by S10), naming the allowlist file and the rationale-comment requirement. **Proof**: TI13 Verify line.
- [ ] No new package dependencies added to any `pubspec.yaml`; the L2 tests use only `dart:io` + `package:test` + regex (mirroring `workflow_task_boundary_test.dart`) — Binding Constraint #2. **Proof**: TI11 Verify line — `git diff packages/*/pubspec.yaml apps/*/pubspec.yaml` clean.
- [ ] CHANGELOG `0.16.5 - Unreleased` `### Added` gains a bullet naming the six L2 fitness tests + crash-recovery smoke test; `### Changed` notes the TD-074 dry-run record. **Proof**: TI13 Verify line.

### Health Metrics (Must NOT Regress)

- [ ] `dart test` workspace-wide passes (the new L2 tests are additive; no behavioural regressions to existing tests)
- [ ] `dart analyze --fatal-warnings --fatal-infos` clean
- [ ] L1 fitness suite (S10) wall-clock ≤30s — adding L2 must not couple to or slow L1 (each test file initialises its own state)
- [ ] `arch_check.dart` continues to pass (L2 fitness tests are at a complementary tier — `arch_check.dart` has its own dep-graph + LOC ratchet checks; do not couple)
- [ ] `release_check.sh` invocation surface unchanged
- [ ] L2 suite total wall-clock ≤5 min on dev machine; if exceeded, profile per-test timing (likely long pole: `dependency_direction_test.dart` running `dart pub deps --json` and `barrel_export_count_test.dart` walking every `lib/<X>.dart` barrel — each acceptable up to ~30s)

## Scenarios

### Happy: developer runs the L2 fitness suite locally and it completes ≤5 min green
- **Given** a clean checkout of `main` after S25 has shipped, with S10 (L1 fitness location + allowlist convention) and S11 (post-extraction `dartclaw_testing` deps shape — only `dartclaw_core` under `dependencies:`) both `Implemented`
- **When** the developer runs `dart test packages/dartclaw_testing/test/fitness/` (or `bash dev/tools/run-fitness.sh` which wraps it)
- **Then** wall-clock duration ≤5 min, exit code 0, stdout reports each of the 6 L2 tests + 6 L1 tests as passing, the integration smoke test (`crash_recovery_smoke_test`) is **skipped** by default (`@Tags(['integration'])` not selected), and no allowlist self-test reports a malformed line

### A new package edge requires a committed data-file update
- **Given** S25 shipped; `dependency_direction.txt` allowlist contains the surgical `dartclaw_workflow → dartclaw_security` edge with rationale and rejects `dartclaw_workflow → dartclaw_storage`
- **When** a contributor adds `import 'package:dartclaw_security/dartclaw_security.dart';` to `packages/dartclaw_workflow/lib/src/foo.dart` (already-allowed edge — no failure) but separately adds `import 'package:dartclaw_storage/dartclaw_storage.dart';` to `packages/dartclaw_workflow/lib/src/bar.dart` (forbidden edge)
- **Then** `dependency_direction_test.dart` fails with output naming the offender file:line: `packages/dartclaw_workflow/lib/src/bar.dart:<line>: dartclaw_workflow → dartclaw_storage edge not in allowed-edges table; see test/fitness/allowlist/dependency_direction.txt`, and the failure message points the contributor at the README "How to resolve" section explaining: (1) if the edge is intentional, add a line to `dependency_direction.txt` with a rationale comment; (2) the rationale comment is mandatory and reviewed at code-review time

### Cross-consumer enum-exhaustiveness regression caught
- **Given** S25 shipped; `enum_exhaustive_consumer_test.dart` enumerates 7 `WorkflowRunStatus` values across N consumer surfaces (SSE serializers, UI badge maps, CLI status renderers); all surfaces handle every value
- **When** a contributor adds a new value `WorkflowRunStatus.archived` to `packages/dartclaw_models/lib/src/workflow_run.dart` and updates the SSE serializer but forgets the UI badge map at `packages/dartclaw_server/lib/src/templates/workflow_detail.dart`
- **Then** `enum_exhaustive_consumer_test.dart` fails with `WorkflowRunStatus.archived not handled in packages/dartclaw_server/lib/src/templates/workflow_detail.dart (badge-map consumer)` — catches the "renders as Unknown" failure mode the plan calls out

### TD-046 — reserve/start → hard kill → restart → orphan cleanup
- **Given** a server profile with `state.db` and `turn_state_store`; an active workflow harness reserves a turn (status `reserved`) and starts it (status `running`)
- **When** the server process is killed with SIGKILL mid-turn (no graceful shutdown), then restarted from the same `state.db`
- **Then** on startup, the server detects the orphan turn (`running` status with no live process), removes it from `turn_state_store`, fires the one-time recovery notice (a `RecoveryNoticeEvent` or equivalent — verify exactly one fires), and the server reaches a healthy idle state. The test asserts the post-restart `turn_state_store` row count for that turn is 0; asserts the recovery notice fired exactly once (not zero, not two — the rollback-leak fix is what this TD validates); and confirms `dart analyze` of the server package remains clean

### Method-count regression on a previously-clean file is caught
- **Given** S25 shipped; `max_method_count_per_file.txt` allowlist contains `task_executor.dart` and `foreach_iteration_runner.dart` with shrink targets; all other files under `packages/<X>/lib/src/` and `apps/<X>/lib/src/` are ≤40 methods
- **When** a contributor adds 5 new private helpers to `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart`, pushing it from 38 to 43 methods (not on the allowlist)
- **Then** `max_method_count_per_file_test.dart` fails with `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart: 43 methods (limit 40); see allowlist/max_method_count_per_file.txt for shrink-target convention`

### Fitness-script blackout audit surfaces a stale silent-passing script
- **Given** during the blackout audit, the contributor enumerates `dev/tools/fitness/check_no_workflow_private_config.sh` and discovers that one of its `ALLOWED_FILES` paths references `lib/src/old_path.dart` which was renamed during the 0.16.4 restructure to `lib/src/new_path.dart`
- **When** the contributor records the finding in the audit log
- **Then** either: (a) the script is fixed in this PR (path correction, one-line edit), OR (b) a new TD entry is filed against `TECH-DEBT-BACKLOG.md` with severity, affected files, fix shape, and trigger — and the FIS Implementation Observations section captures both the finding and the disposition

## Scope & Boundaries

### In Scope

- Author six Dart L2 test files at `packages/dartclaw_testing/test/fitness/` per the file map in `.technical-research.md` § "S25"
- Author six allowlist files at `packages/dartclaw_testing/test/fitness/allowlist/<test-name>.txt` with rationale-comment line format (same shape as L1, established by S10)
- Author the integration smoke test for TD-046 at `packages/dartclaw_server/test/integration/crash_recovery_smoke_test.dart` with `@Tags(['integration'])`
- Execute the TD-074 Homebrew/archive revalidation dry-run; record findings; update formula/archive docs only if path drift surfaced
- Execute the fitness-script blackout audit; record per-script findings (invoked-by, input-paths-exist, silent-pass-risk); fix trivial findings in this PR; file new TD entries for non-trivial findings
- Extend `packages/dartclaw_testing/test/fitness/README.md` (created by S10) with one section per L2 test
- Add CI step (the existing surface `dev/tools/run-fitness.sh` already runs `dart test` against the fitness directory — L2 tests pick up automatically); ensure the integration smoke test is excluded from the per-PR L2 run via the `@Tags(['integration'])` filter
- CHANGELOG entry under `## 0.16.5 - Unreleased` `### Added`
- Sprint-close hygiene: delete TD-046 + TD-074 entries from `dev/state/TECH-DEBT-BACKLOG.md` (or narrow TD-074 if path drift surfaced)

### What We're NOT Doing

- Authoring any L1 fitness test — that is **S10's** scope; this story extends the directory + allowlist convention S10 froze. Do not duplicate L1 work or re-author the README scaffolding.
- Changing existing fitness conventions (allowlist file shape, fitness-test directory location, README format, "rationale comment mandatory" rule) — those are frozen by S10 + Shared Decisions #10 + #11. **Inherit verbatim.**
- Auto-fixing existing intentional violators in `task_executor.dart` and `foreach_iteration_runner.dart` to drop them below 40 methods — those are **S33/S16/S15's** scope; this story **allowlists** them with explicit shrink-target rationale, it does not refactor.
- Migrating release-prep tooling beyond the TD-074 Homebrew/archive dry-run (e.g. building a CI-driven Homebrew tap test, automating archive-content assertions). The TD-074 ask is "dry-run + record + update if drift", not "build a permanent automation harness".
- Adding a new package dependency (Binding Constraint #2). The 6 tests + crash-recovery smoke run on `dart:io` + `package:test` + regex; if a check seems to require AST parsing, **stop and escalate** — do not silently add `package:analyzer`.
- Authoring a separate `workflow_storage_isolation_test.dart` standalone file — the SqliteWorkflowRunRepository import guard is folded into `dependency_direction_test.dart` (the broader edge-table check) per the plan's "extend either `dependency_direction_test.dart` or a small workflow-specific companion check" wording. One file is simpler.
- Adding/changing the runtime contract of `WorkflowRunStatus` or `TaskStatus` — this story only **scans** consumer coverage; enum changes are S35/S22 territory.

### Agent Decision Authority

- **Autonomous**: For each L2 test file, choose the simplest implementation (regex line scanning, mirroring `workflow_task_boundary_test.dart`) over AST parsing where both work. The plan's "use `package:analyzer`" mention is permissive, not mandatory.
- **Autonomous**: Choose which `dev/tools/*.sh` / `dev/tools/fitness/*.{sh,dart}` scripts can be retired vs. fixed vs. filed-as-TD as part of the blackout audit. Default: minimum-disruption — fix trivial path drift in-place; file new TDs for anything that looks like it needs requirements input.
- **Autonomous**: Decide whether to fold the SqliteWorkflowRunRepository import guard into `dependency_direction_test.dart` (default, simpler) or split it into a `workflow_storage_isolation_test.dart` companion file. **Default: fold into `dependency_direction_test.dart`** — keeps the L2 surface to 6 files, not 7.
- **Autonomous**: Where the TD-074 dry-run discovers no drift, record the pass and delete the TD entry; where it surfaces drift, record findings + update formula/docs in-scope, then narrow TD-074 to the surviving residual.
- **Escalate**: If `enum_exhaustive_consumer_test.dart` cannot reliably enumerate consumer surfaces with regex (e.g. switch-expression coverage on `WorkflowRunStatus` requires AST to verify exhaustiveness vs. just "value name appears in file"), stop and surface — adding `package:analyzer` is a Binding Constraint #2 question. **Likely outcome**: regex-based "every enum value name appears textually in each consumer file" is sufficient because the **compiler** already enforces switch-expression exhaustiveness for enums (and S01 enforces it for sealed events); the L2 test only needs to assert that **all** known consumer files reference each value, catching the "forgot to update the badge map" pattern.
- **Escalate**: If the TD-046 smoke test cannot reliably script "hard-kill the process and restart" within the test framework's reach, stop and surface — the plan permits a "scripted CLI/profile path" alternative; do not fall back to a unit test that fakes the kill (defeats the purpose).
- **Escalate**: If the L2 suite wall-clock exceeds 5 min on the dev machine even with regex-based scanning, stop and profile — do not allowlist away tests to hit the budget.

## Architecture Decision

**We will**: host the 6 L2 fitness tests at the same `packages/dartclaw_testing/test/fitness/*.dart` location as L1 (Shared Decision #10); tag the integration smoke test (TD-046) with `@Tags(['integration'])` so it gates release-prep, not every-PR (mirrors the existing integration-tag convention in `dartclaw_core` and `dartclaw_workflow`); make the allowed-edges table for `dependency_direction_test.dart` a committed plain-text data file with rationale comments (same shape S10 froze, Shared Decision #11); fold the SqliteWorkflowRunRepository import guard into `dependency_direction_test.dart` (one extra check inside the broader edge-table walk, no separate file); run the fitness-script blackout audit once during this story's execution (one-shot; findings either fixed or filed as new TDs); reuse `dart:io` + `package:test` + regex (mirroring `workflow_task_boundary_test.dart`) — no `package:analyzer`.

**Rationale**:

1. *Same fitness directory* — Shared Decision #10 names this as the single source of truth; S28 + S10 already populate it; splitting L2 to `dev/tools/fitness/` would force every contributor to look in two places and would lose `package:test` reporting (timing, fail-fast, isolated test groups).
2. *Integration tag for crash-recovery* — the TD-046 ask is "scripted CLI/profile test" with real persistence + startup wiring. That cost (multi-second startup, real SQLite, real process kill) belongs on a separate per-PR-skipped track. `@Tags(['integration'])` is the established convention.
3. *Allowed-edges table as committed data* — generated tables rot silently; plain-text forces every entry through code review with mandatory rationale comments. The S10-frozen convention (`pattern  # rationale`) carries unchanged.
4. *SqliteWorkflowRunRepository guard folded into dep-direction* — the workflow→storage edge is already represented as data in `dependency_direction.txt`; a concrete-class import guard is a one-line extension of the same walk. Splitting to a separate file adds a 7th L2 file for a 1-line check.
5. *No `package:analyzer`* — Binding Constraint #2 forbids new deps; the existing fitness test pattern (regex import scanning) handles every L2 check straightforwardly because the compiler already enforces switch exhaustiveness — the L2 test only needs textual coverage of consumer files.
6. *Blackout audit one-shot* — recurring-script blackout protection is the L2 suite itself (a Dart test under `package:test` cannot silently pass on missing files — failed regex matches surface as test failures, not exit-0). The audit fixes the legacy state once.

**Alternatives considered**:

1. **Separate `workflow_storage_isolation_test.dart` file** — rejected: a 7th L2 file for a 1-line check inflates the file count without adding diagnostic value.
2. **Crash-recovery as a unit test with mocked process kill** — rejected: defeats the purpose of TD-046 (real persistence + startup wiring); the plan and TD-046 entry both call for "scripted CLI/profile" coverage.
3. **`enum_exhaustive_consumer_test.dart` using `package:analyzer` AST** — rejected per Binding Constraint #2; the compiler already enforces switch exhaustiveness for enums and sealed types (S01), so the L2 test's job is to catch "added a value but forgot a non-switch consumer" (UI badge map, CLI string renderer) — regex coverage of "value name appears in known consumer files" is sufficient.
4. **TD-074 as a permanent automated harness** — rejected: the TD entry asks for a one-shot dry-run + formula update; building a CI Homebrew tap test is out-of-scope expansion.
5. **Convert all `dev/tools/fitness/*.sh` scripts to Dart in this story** — rejected: scope creep; the blackout audit only fixes path-drift trivially, files non-trivial findings as TDs, and lets future stories migrate scripts to Dart on need.

## Technical Overview

### Integration Points

- **Producers**:
  - S10 (Spec Ready) freezes the `test/fitness/` directory + `allowlist/<test-name>.txt` convention + the README "How to resolve" pattern → S25 inherits all three verbatim
  - S11 (Spec Ready) finalises `packages/dartclaw_testing/pubspec.yaml` shape (only `dartclaw_core` under `dependencies:`, plus `http`/`path`) → S25's `testing_package_deps_test.dart` baseline asserts that exact set
  - S12 (presumed shipped pre-S25) removes the `dartclaw_workflow → dartclaw_storage` runtime edge → S25's `dependency_direction.txt` excludes that edge from the allowed table
- **Consumers**:
  - The 0.16.5 release gate — L2 fitness on every PR catches drift before tag time
  - Future milestones — the L2 surface is the regression net for ongoing structural work
- **Existing infrastructure reused**:
  - `dev/tools/run-fitness.sh` (S10) — `dart test packages/dartclaw_testing/test/fitness/` picks up the new L2 files automatically
  - `dev/tools/release_check.sh` — runs `dart test` workspace-wide; the L2 tests are included
  - `arch_check.dart` — continues to run unchanged at the repo-tooling tier

### Data Models (Allowlist file format — inherited from S10)

Each `packages/dartclaw_testing/test/fitness/allowlist/<test-name>.txt`:

- Lines starting with `#` (after optional leading whitespace) are full-line comments
- Blank lines ignored
- Each non-comment, non-blank line: `<pattern>  # <rationale-or-shrink-target>` (two spaces, hash, one space — mandatory; rationale non-empty)
- `<pattern>` semantics per L2 test:
  - `dependency_direction.txt`: `<from-package> -> <to-package>` (e.g. `dartclaw_workflow -> dartclaw_security  # 0.16.4 release-gate edge — security guard wiring; preserved`)
  - `src_import_hygiene.txt`: empty on green (no cross-pkg `src/` imports allowed)
  - `testing_package_deps.txt`: empty on green (`pubspec.yaml` only lists `dartclaw_core`, `http`, `path` post-S11 — any other entry is a violation)
  - `barrel_export_count.txt`: empty on green; entries `<package>  # <reason for breaching cap>` only when temporarily breached
  - `enum_exhaustive_consumer.txt`: `<consumer-file>:<enum-name>  # <rationale>` (e.g. `packages/dartclaw_server/lib/src/templates/foo.dart:WorkflowRunStatus  # round-trip JSON serializer, no per-value rendering`)
  - `max_method_count_per_file.txt`: `<relative-path>  # <method-count> methods; shrink to ≤40 by <story/version>` (two baseline entries)
- The L1 self-test (S10 TI01) parses every allowlist; S25 extends the same self-test to cover the six new files (no new self-test infrastructure)

### CI integration shape

- `bash dev/tools/run-fitness.sh` → invokes `dart test packages/dartclaw_testing/test/fitness/` → picks up L1 + L2 automatically; integration smoke test is **not** invoked (no `-t integration` flag)
- `dart test packages/dartclaw_server/test/integration/crash_recovery_smoke_test.dart -t integration` → runs the TD-046 smoke as part of release-prep (manually invoked, or via `release_check.sh` integration block)
- Format gate (S10) and arch_check (existing) continue to run unchanged

## Code Patterns & External References

```
# type | path/url                                                                                | why needed
file   | packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart                 | Reference pattern for Dart-only fitness tests (regex scan, dart:io walk, _findRepoRoot helper, _knownViolations allowlist, "How to resolve" docstring header). Mirror style for all six L2 tests.
file   | packages/dartclaw_testing/test/fitness/allowlist/                                       | Directory established by S10; S25 adds 6 new <test-name>.txt files alongside L1's six.
file   | packages/dartclaw_testing/test/fitness/README.md                                        | Created by S10; S25 extends with one section per L2 test using the same shape.
file   | dev/tools/arch_check.dart:13-54                                                         | _expectedWorkspaceDependencies map — seed data for dependency_direction.txt allowed-edges table. Read first; do NOT call into arch_check.dart from the test (one parse per test, both run independently).
file   | dev/tools/run-fitness.sh                                                                | Created by S10; the L2 tests pick up automatically via dart test packages/dartclaw_testing/test/fitness/. No edits needed.
file   | packages/dartclaw_models/lib/src/workflow_run.dart:170-197                              | WorkflowRunStatus enum — first sealed-enum target for enum_exhaustive_consumer_test.dart. 7 values: pending, running, paused, awaitingApproval, completed, failed, cancelled.
file   | packages/dartclaw_core/lib/src/task/task_status.dart:1-59                               | TaskStatus enum — second target. 9 values: draft, queued, running, interrupted, review, accepted, rejected, cancelled, failed.
file   | packages/dartclaw_server/lib/src/templates/workflow_detail.dart                         | Known WorkflowRunStatus consumer (UI badge map / status renderer). Verify it appears in enum_exhaustive_consumer_test.dart's consumer list.
file   | apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart                | Known WorkflowRunStatus consumer (CLI status renderer). Verify it appears in the consumer list.
file   | packages/dartclaw_server/lib/src/task/task_executor.dart                                | ~28 methods on first regex pass + many private helpers; baseline candidate for max_method_count_per_file allowlist with shrink target "≤40 by 0.16.6".
file   | packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart               | 1,630 LOC; baseline candidate for max_method_count_per_file allowlist with shrink target "≤40 by 0.16.6 once S15 state-machine extraction settles".
file   | packages/dartclaw_testing/pubspec.yaml                                                  | Post-S11 should list only dartclaw_core (+ http/path); testing_package_deps_test.dart asserts this exact set.
file   | packages/dartclaw_server/lib/src/turn_runner.dart                                       | TD-046 affected file — the source of the rollback-leak fix in releaseTurn() that the smoke test validates.
file   | packages/dartclaw_storage/lib/src/storage/turn_state_store.dart                         | TD-046 affected file — the orphan-turn detection + cleanup target.
file   | dev/tools/build.sh                                                                      | TD-074 affected — Homebrew/archive build path; dry-run validates expected templates/static-asset/skill-source/runtime-provisioning trees.
file   | dev/tools/fitness/check_no_workflow_private_config.sh                                   | Blackout-audit subject — verify input paths still exist; example of a script that could silently pass.
file   | dev/state/TECH-DEBT-BACKLOG.md                                                          | TD-046 (line 649) + TD-074 (line 433) — sprint-close hygiene removes both.
file   | dev/guidelines/TESTING-STRATEGY.md                                                      | S10 added "## Fitness Functions" section; S25 extends one paragraph naming the L2 surface.
```

## Constraints & Gotchas

- **Constraint (Binding #2)**: No new dependencies. Use `dart:io` + `package:test` + regex. Plan/PRD wording about `package:analyzer` is permissive ("if needed"); regex over `readAsLinesSync()` handles every L2 check based on `workflow_task_boundary_test.dart` evidence. **Escalate** if a check truly requires AST.
- **Constraint (Binding #3)**: Workspace-wide strict-casts and strict-raw-types remain on. Test files conform; do not add `// ignore:` directives.
- **Constraint (Binding #70)**: L2 suite ≤5 min total. Each test should walk `lib/` recursively at most once; avoid re-running `dart pub deps --json` per test (multi-second). `dependency_direction_test.dart` runs `dart pub deps --json` once at suite start (cached as a top-level `late final` if multiple tests in the same file need it).
- **Constraint (Binding #84)**: Allowlists are plain-text under `test/fitness/allowlist/`. Same shape as L1, no schema variants.
- **Constraint (S25 dependency on S11)**: S11's post-state — `packages/dartclaw_testing/pubspec.yaml` lists only `dartclaw_core` + `http` + `path` under `dependencies:` — must be **shipped** before S25's `testing_package_deps_test.dart` baseline is measured. **Verify before TI03**: `cat packages/dartclaw_testing/pubspec.yaml` and confirm only those entries; if S11 has not landed, surface as a blocker.
- **Constraint (S25 dependency on S12)**: S12 removes `dartclaw_workflow → dartclaw_storage` runtime edge. **Verify before TI01**: `rg "package:dartclaw_storage" packages/dartclaw_workflow/lib/` returns zero matches; if not, surface as a blocker (cannot encode the post-S12 baseline if S12 hasn't shipped).
- **Avoid**: Coupling allowlist parsing to a custom YAML/JSON schema. The plain-text `pattern  # rationale` shape is intentionally trivial. Reuse the helper from S10 (TI01) — extract to `_internal/` only if duplication crosses 4 sites (3 from S10 + 6 from S25 = 9, so likely yes — extract once, used by all 12 L1+L2 files). **Default**: extract `parseAllowlist(File f) -> Map<String, String>` to `packages/dartclaw_testing/test/fitness/_internal/allowlist_parser.dart` in TI02 if not already done by S10.
- **Avoid**: Re-parsing `dart pub deps --json` per test. Cache the parse result as a top-level `late final Map<String, Set<String>> _packageDeps` in `dependency_direction_test.dart`.
- **Avoid**: Writing the TD-046 smoke as a unit test with mocked `Process.kill`. The plan + TD entry both call for real persistence + startup wiring; `@Tags(['integration'])` is the gate.
- **Avoid**: Re-implementing `arch_check.dart`'s dep-graph walk. Read its `_expectedWorkspaceDependencies` as **seed data** for `dependency_direction.txt`; the test's own logic is "diff observed-edges against allowed-edges from the data file", not "call into arch_check.dart".
- **Critical**: The fitness-script blackout audit must enumerate every script under `dev/tools/` (top-level `*.sh` + `dev/tools/fitness/`) — not just the obvious ones. The failure mode that masked TD-099/100/101 was a `find`-then-grep script whose source path no longer existed: zero matches → exit 0 → silent pass. Look for: hardcoded path literals in scripts, missing `set -euo pipefail`, missing "fail if no matches" assertions.
- **Critical**: `enum_exhaustive_consumer_test.dart` must enumerate consumer surfaces in **data**, not magic-discover them. Hardcode the consumer file list (e.g. `_workflowRunStatusConsumers = ['packages/dartclaw_server/lib/src/templates/workflow_detail.dart', 'apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart', ...]`) with rationale comments. Otherwise the test silently passes when a new consumer file appears that doesn't reference the enum yet.
- **Gotcha**: `max_method_count_per_file_test.dart` regex must distinguish methods from getters/setters/operators (Dart syntax: `Type get name => ...`, `set name(value) {...}`, `operator +(other) ...`). Count all of them as "methods" for the ≤40 ceiling — the spirit is "concerns per file", not "named function signatures".
- **Gotcha**: `barrel_export_count_test.dart` cap on `dartclaw_workflow ≤35` aligns with S09's narrowing (Binding Constraint #11). Verify S09 has shipped before measuring; if the workflow barrel is still >35, surface as a blocker.
- **Gotcha**: `crash_recovery_smoke_test.dart` will likely need a temp data dir under `Directory.systemTemp.createTempSync()` and a real `dartclaw serve` invocation via `Process.start`. `tearDownAll` must `Process.kill` and `Directory.delete(recursive: true)` cleanly even on failure. Mirror existing integration test patterns in `packages/dartclaw_server/test/integration/` (audit at TI08 for the closest analog).

## Implementation Plan

> **Vertical slice ordering**: TI01 builds the first L2 test (`dependency_direction`) including the allowed-edges data file + companion SqliteWorkflowRunRepository guard + README "How to resolve" section + allowlist-parser extraction (if not already done by S10) — proves the end-to-end pattern. TI02–TI06 add the remaining five L2 tests against the same scaffolding. TI07 verifies the L2 suite picks up automatically via the existing `run-fitness.sh`. TI08 authors the TD-046 smoke. TI09 executes the TD-074 dry-run. TI10 executes the fitness-script blackout audit. TI11 validates workspace-wide. TI12 measures L2 wall-clock. TI13 documents (README + TESTING-STRATEGY.md + CHANGELOG). TI14 sprint-close hygiene.

### Implementation Tasks

- [ ] **TI01** `dependency_direction_test.dart` exists at `packages/dartclaw_testing/test/fitness/`, walks every `packages/<X>/lib/**/*.dart` + `apps/<X>/lib/**/*.dart` file, regex-extracts each `import 'package:<dep>/...'` line, asserts every `<X> → <dep>` edge is present in the allowed-edges data file `allowlist/dependency_direction.txt`. Allowed-edges file baseline mirrors `dev/tools/arch_check.dart:13-54`'s `_expectedWorkspaceDependencies` map, with one entry per allowed edge in `from -> to  # rationale` form. Includes the surgical `dartclaw_workflow -> dartclaw_security  # 0.16.4 release-gate edge — security guard wiring; preserved` entry; **excludes** `dartclaw_workflow -> dartclaw_storage` (verify pre-TI01: `rg "package:dartclaw_storage" packages/dartclaw_workflow/lib/` returns zero — S12 baseline). Also includes a folded SqliteWorkflowRunRepository import guard: any `import 'package:dartclaw_storage/.*sqlite_workflow_run_repository.*';` from `packages/dartclaw_workflow/lib/` fails the test (allowlist for this rule is intentionally empty). Allowlist-parser helper extracted to `packages/dartclaw_testing/test/fitness/_internal/allowlist_parser.dart` if not already extracted by S10 (verify first; if duplicated inline across S10's 6 tests, extract here as Boy-Scout cleanup; if S10 already extracted, reuse).
  - Pattern reference: `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart:71-119` for the test() body shape; `:124-134` for `_findRepoRoot()`.
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/dependency_direction_test.dart` passes against current `main`; `git diff packages/dartclaw_testing/test/fitness/allowlist/dependency_direction.txt` shows N entries each with `  # ` + non-empty rationale; injecting `import 'package:dartclaw_storage/dartclaw_storage.dart';` into `packages/dartclaw_workflow/lib/src/foo.dart` fails with `packages/dartclaw_workflow/lib/src/foo.dart:<line>: dartclaw_workflow → dartclaw_storage edge not in allowed-edges table`; injecting `import 'package:dartclaw_storage/src/storage/sqlite_workflow_run_repository.dart';` fails with the SqliteWorkflowRunRepository-specific message; revert all injections.

- [ ] **TI02** `src_import_hygiene_test.dart` exists, walks every `packages/<X>/lib/**/*.dart` + `apps/<X>/lib/**/*.dart` file, regex-finds every `import 'package:<Y>/src/...'` where `<X>` (the file's owning package) ≠ `<Y>`, fails on any match. Allowlist `allowlist/src_import_hygiene.txt` baseline empty. Reuses the allowlist parser from TI01.
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/src_import_hygiene_test.dart` passes against current `main`; injecting `import 'package:dartclaw_core/src/internal_thing.dart';` into `packages/dartclaw_workflow/lib/src/foo.dart` fails with `packages/dartclaw_workflow/lib/src/foo.dart:<line>: cross-package src/ import to dartclaw_core (use barrel)`; revert.

- [ ] **TI03** `testing_package_deps_test.dart` exists, parses `packages/dartclaw_testing/pubspec.yaml` (literal-string regex over the `dependencies:` block — no `package:yaml` dep), asserts the set of top-level `dependencies:` keys is exactly `{dartclaw_core, http, path}` (post-S11; **verify pre-TI03** that S11 has shipped). Any deviation fails. Allowlist `allowlist/testing_package_deps.txt` baseline empty.
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/testing_package_deps_test.dart` passes; injecting a fake line `dartclaw_server: path: ../dartclaw_server` under `dependencies:` (NOT `dev_dependencies:`) fails with `packages/dartclaw_testing/pubspec.yaml: unexpected dependency 'dartclaw_server' under dependencies: (allowed: dartclaw_core, http, path)`; revert.

- [ ] **TI04** `barrel_export_count_test.dart` exists, walks every `packages/<X>/lib/<X>.dart` barrel, counts `^export ` lines, asserts per-package soft caps: `dartclaw_core ≤80`, `dartclaw_config ≤50`, `dartclaw_workflow ≤35`, all others ≤25. Allowlist `allowlist/barrel_export_count.txt` baseline empty (any breach is either a real growth in design surface — bump the cap with rationale — or unintentional CRP drift to fix). **Verify pre-TI04**: `rg -c "^export " packages/dartclaw_workflow/lib/dartclaw_workflow.dart` returns ≤35 (S09 baseline).
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/barrel_export_count_test.dart` passes against current `main`; the per-package counts at the time of authoring are recorded as a debug-print line one-time during TI04 (for FIS Implementation Observations); injecting `export 'src/junk.dart';` × 10 into the workflow barrel pushes count to 45 and fails with `packages/dartclaw_workflow/lib/dartclaw_workflow.dart: 45 exports (limit 35)`; revert.

- [ ] **TI05** `enum_exhaustive_consumer_test.dart` exists with two enum-target groups encoded as data: `WorkflowRunStatus` (7 values from `packages/dartclaw_models/lib/src/workflow_run.dart:170-197`) and `TaskStatus` (9 values from `packages/dartclaw_core/lib/src/task/task_status.dart:1-59`). For each enum, a hardcoded list of consumer files (e.g. `packages/dartclaw_server/lib/src/templates/workflow_detail.dart`, `apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart` — discovered via `rg -l "WorkflowRunStatus\." packages apps`). For each (consumer, enum-value), assert the textual presence of `<EnumName>.<value>` in the consumer file. Allowlist `allowlist/enum_exhaustive_consumer.txt` documents any consumer that legitimately doesn't enumerate values (e.g. JSON name-roundtrip serializer) with rationale.
  - **Verify pre-TI05**: enumerate consumer surfaces via `rg -l "WorkflowRunStatus\." packages/dartclaw_server packages/dartclaw_workflow apps/dartclaw_cli` and `rg -l "TaskStatus\." packages apps` — record the list. The test's hardcoded consumer-file list IS this enumeration with deliberate scope (not all matches; only files that render or branch on the value).
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/enum_exhaustive_consumer_test.dart` passes; deleting one `WorkflowRunStatus.cancelled` reference from `packages/dartclaw_server/lib/src/templates/workflow_detail.dart` (or whichever known consumer file is enumerated) fails with `WorkflowRunStatus.cancelled not handled in <consumer-file>`; revert.

- [ ] **TI06** `max_method_count_per_file_test.dart` exists, walks every `packages/<X>/lib/src/**/*.dart` + `apps/<X>/lib/src/**/*.dart` file, regex-extracts method declarations (counting public + private methods + getters + setters + operators), asserts ≤40 per file. Allowlist `allowlist/max_method_count_per_file.txt` baseline two entries: `packages/dartclaw_server/lib/src/task/task_executor.dart  # <observed-count> methods; shrink to ≤40 by 0.16.6 once S33/S16 binding-coordinator extraction completes` and `packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart  # <observed-count> methods; shrink to ≤40 by 0.16.6 once S15 state-machine extraction completes`. Method counting strategy: scan each file for `^\s+(static\s+|external\s+)?(\w+\s+)?(get|set|operator|\w+)\s+\w+\s*[\(<]` patterns; **if the regex is unreliable on edge cases (function-typed fields, getters with `=>`)**, surface — do NOT silently switch to AST.
  - **Verify pre-TI06**: `rg -c "^\s+(Future|void|String|bool|int|double|Map|List|Set|Stream|FutureOr|num|dynamic|T|R|E)" <file>` for the two known offenders to seed the observed-count rationale comments.
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/max_method_count_per_file_test.dart` passes against current `main`; deliberately adding 5 throwaway private methods to `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart` (currently <40) fails with `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart: <count> methods (limit 40)`; revert.

- [ ] **TI07** Verify the L2 suite picks up automatically via `dev/tools/run-fitness.sh` (S10) — no script edits needed. The default `dart test packages/dartclaw_testing/test/fitness/` already runs L1 + L2; integration tests are excluded by default (`@Tags` filter not selected).
  - **Verify**: `bash dev/tools/run-fitness.sh` exits 0 against current main; output names all 12 test files (6 L1 + 6 L2) as passing; integration smoke (TI08) is reported as `skipped` (`@Tags(['integration'])` not selected).

- [ ] **TI08** TD-046 crash-recovery integration smoke at `packages/dartclaw_server/test/integration/crash_recovery_smoke_test.dart` exists, opens with `@Tags(['integration'])` directive at top of file. Test scripts: (1) create temp data dir under `Directory.systemTemp.createTempSync()`; (2) start `dartclaw serve` via `Process.start` with that data dir; (3) reserve + start a turn (via API client or direct repository write — whichever matches existing integration-test pattern); (4) `Process.kill(pid, ProcessSignal.sigkill)` mid-turn; (5) start a new server process from the same data dir; (6) assert the orphan turn is removed from `turn_state_store` (via direct `sqlite3` open of the data dir's `state.db`); (7) assert exactly one recovery notice was emitted (via SSE event capture or log-line scan, matching the existing `RecoveryNoticeEvent` shape if defined, or `_log.warning('recovery: ...')` if log-based); (8) `tearDownAll` cleanly kills any surviving processes and deletes the temp dir.
  - Pattern reference: audit existing integration tests under `packages/dartclaw_server/test/integration/` at TI08 — find the closest analog and mirror the lifecycle harness shape. If no analog exists, the smoke test is the first integration test in that directory; mirror the `@Tags(['integration'])` opening from `packages/dartclaw_core/test/` or `packages/dartclaw_workflow/test/` integration tests.
  - **Verify**: `dart test packages/dartclaw_server/test/integration/crash_recovery_smoke_test.dart -t integration` passes; `dart test packages/dartclaw_server/test/integration/crash_recovery_smoke_test.dart` (no `-t` flag) reports the test as `skipped`; the test takes no longer than 60s on the dev machine; `dart analyze packages/dartclaw_server` clean.

- [ ] **TI09** TD-074 Homebrew/archive revalidation dry-run executed: (1) `bash dev/tools/build.sh` (or whatever produces the archive — verify pre-TI09); (2) extract the resulting archive to a scratch dir; (3) verify the unpacked tree contains the expected paths: embedded templates (e.g. `templates/`), static assets (e.g. `static/`), DC-native skill sources (e.g. `skills/dartclaw-*/`), runtime-provisioning hooks (whatever `bash dev/tools/build.sh` documents); (4) if a Homebrew formula exists in this repo or a known sibling, dry-run `brew install` from a local tap; (5) record findings in this FIS's Implementation Observations under `### TD-074 dry-run record`. If path drift surfaced, update the formula and/or `dev/tools/build.sh` in this PR; if no drift, prepare to delete TD-074 at TI14.
  - **Verify**: archive content matches expected layout; either no docs changes (record clean dry-run) or formula/build.sh updated with a one-line CHANGELOG note under `### Changed`.

- [ ] **TI10** Fitness-script blackout audit executed: (1) enumerate every script under `dev/tools/` (top-level `*.sh` + `*.dart`) and `dev/tools/fitness/` (`*.sh` + `*.dart`); (2) for each, record in this FIS's Implementation Observations under `### Fitness-script blackout audit` a row `<script> | invoked-by: <CI/release_check.sh/manual> | input-paths: <still-exist|drift|missing> | risk: <silent-pass|surfaces-error|N/A> | disposition: <fix-in-PR|file-TD|no-action>`; (3) for trivial path-drift findings (one-line edits), fix in this PR; (4) for non-trivial findings, file a new TD entry in `dev/state/TECH-DEBT-BACKLOG.md` with severity, affected files, fix shape, trigger.
  - **Verify**: audit log present in Implementation Observations covering at minimum: `dev/tools/check_git_process_usage.sh` (already retired by S10), `dev/tools/check_versions.sh`, `dev/tools/release_check.sh`, `dev/tools/test_workspace.sh`, `dev/tools/validate_pana.sh`, `dev/tools/arch_check.dart`, `dev/tools/fitness/check_no_workflow_private_config.sh`, `dev/tools/fitness/check_workflow_server_imports.sh`, `dev/tools/fitness/check_task_executor_workflow_refs.dart`, `dev/tools/fitness/run_all.sh`, `dev/tools/fitness/test_check_no_workflow_private_config.sh`. Findings + dispositions recorded.

- [ ] **TI11** Workspace validation: `dart format --set-exit-if-changed packages apps`, `dart analyze --fatal-warnings --fatal-infos`, `dart test`, `bash dev/tools/run-fitness.sh`, `dart dev/tools/arch_check.dart` all pass. **`git diff packages/*/pubspec.yaml apps/*/pubspec.yaml`** shows zero changes (no new deps).
  - **Verify**: All five commands exit 0; pubspec diff clean.

- [ ] **TI12** L2 suite wall-clock measurement: time `dart test packages/dartclaw_testing/test/fitness/` on the dev machine (excludes integration tag by default). Target ≤5 min per Binding Constraint #70. If exceeded, profile with `dart test --reporter json packages/dartclaw_testing/test/fitness/` per-test timing and surface as a finding (likely long pole: `dependency_direction_test.dart` — acceptable up to ~30s of that budget).
  - **Verify**: `time bash dev/tools/run-fitness.sh` on dev machine reports total wall-clock ≤5 min (typically L1 ≤30s + L2 ≤4 min headroom).

- [ ] **TI13** Documentation: `packages/dartclaw_testing/test/fitness/README.md` extended with one section per L2 test (six new sections, mirroring the L1 shape S10 established) — each with 1-line "what it enforces", 1-line "why", `### How to resolve a failure` subsection naming the allowlist file and the rationale-comment requirement. `dev/guidelines/TESTING-STRATEGY.md` § "Fitness Functions" gains one additional paragraph naming the L2 6-test surface (cross-link to the README; don't duplicate per-test content). CHANGELOG `## 0.16.5 - Unreleased` `### Added` gains: `Level-2 governance suite — six L2 fitness test files at packages/dartclaw_testing/test/fitness/ (dependency direction, src-import hygiene, testing-package deps shape, barrel-export ceilings, cross-consumer enum exhaustiveness, per-file method-count ceiling). Crash-recovery integration smoke test at packages/dartclaw_server/test/integration/crash_recovery_smoke_test.dart (closes TD-046).`; `### Changed` gains the TD-074 dry-run note if formula/build.sh touched.
  - **Verify**: `rg "## .*Fitness" dev/guidelines/TESTING-STRATEGY.md` shows L2 paragraph; `cat packages/dartclaw_testing/test/fitness/README.md` shows 12 sections (6 L1 + 6 L2); CHANGELOG entry exists in the `0.16.5` block.

- [ ] **TI14** Sprint-close hygiene: delete TD-046 entry from `dev/state/TECH-DEBT-BACKLOG.md` (resolved by TI08); delete or narrow TD-074 entry (TI09 — delete on clean dry-run, narrow on residual). New TD entries filed in TI10 stay. Update this FIS's Implementation Observations to record the closure commit.
  - **Verify**: `rg "TD-046\|TD-074" dev/state/TECH-DEBT-BACKLOG.md` returns zero matches (or only TD-074 if narrowed); the FIS Implementation Observations records the deletions.

### Testing Strategy

> Each L2 fitness test IS the test for the success criterion it enforces — there are no separate unit tests for these test files. Verification of behaviour is via the Verify lines (positive: green against `main`; negative: temporary injection of a violator triggers the expected failure). The TD-046 smoke test IS the test for the crash-recovery success criterion.

- [TI01] Scenario "New edge added must be data-file update" → inject + remove a `dartclaw_workflow → dartclaw_storage` edge; SqliteWorkflowRunRepository import injection
- [TI02] Verify line proves both directions (positive on main; negative on synthetic cross-pkg `src/` import)
- [TI03] Verify line — inject + remove `dartclaw_server` under `dependencies:` and confirm failure
- [TI04] Verify line — inject + remove 10 throwaway exports in workflow barrel
- [TI05] Scenario "Cross-consumer enum-exhaustiveness regression caught" → delete + restore one enum-value reference in a known consumer
- [TI06] Scenario "Method-count regression on a previously-clean file is caught" → inject + remove 5 private methods in `workflow_executor.dart`
- [TI08] Scenario "TD-046 reserve/start → hard kill → restart" → smoke test IS the scenario; runs only via `-t integration`
- [TI09] No external scenario; dry-run record IS the proof
- [TI10] Scenario "Fitness-script blackout audit surfaces a stale silent-passing script" → audit log IS the proof
- [TI13] No new test; manual review of README + TESTING-STRATEGY.md + CHANGELOG

### Validation

- Standard exec-spec validation gates apply (build/test/analyze + 1-pass remediation).
- Feature-specific: wall-clock measurement of `bash dev/tools/run-fitness.sh` on the dev machine — target ≤5 min for L1+L2 combined (L1 ≤30s + L2 ≤4.5 min headroom). If exceeded, profile with `dart test --reporter json` per-test timing and surface as a finding. The crash-recovery smoke test is excluded from this budget (runs under `-t integration`).
- TD-046 specific: confirm the smoke test actually exercises a hard-kill (not a graceful shutdown) and that the recovery notice fires exactly **once** (not zero — the rollback-leak fix; not two — the at-most-once invariant). The "exactly once" assertion is what makes the test prove TD-046's resolution.
- TD-074 specific: dry-run record must enumerate every expected path category (templates, static assets, DC-native skill sources, runtime-provisioning hooks) — vague "looks fine" findings are insufficient.

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding.
- Prescriptive details (file paths, allowlist file shape `pattern  # rationale`, the six L2 test names, the two enum targets `WorkflowRunStatus` + `TaskStatus`, the two `max_method_count` baseline entries with shrink targets, the `@Tags(['integration'])` gate for crash-recovery smoke, the SqliteWorkflowRunRepository fold-into-dependency-direction decision) are exact — implement them verbatim.
- The "no new dependencies" constraint is hard. If a task seems to require `package:analyzer` or `package:yaml`, **stop and escalate** — do not silently add it.
- S11 + S12 dependency: verify both have shipped before TI01 / TI03 baseline measurement. If not, surface as a blocker.
- Mark task checkboxes immediately upon completion — do not batch.

## Final Validation Checklist

- [ ] All Success Criteria met (14 must-be-TRUE items + 6 Health Metrics)
- [ ] All TI01–TI14 tasks fully completed, verified, and checkboxes checked
- [ ] No regressions: `dart test` workspace-wide passes; `dart analyze --fatal-warnings --fatal-infos` clean; `arch_check.dart` continues to pass
- [ ] No new package dependencies — `git diff packages/*/pubspec.yaml apps/*/pubspec.yaml` clean
- [ ] L2 suite wall-clock ≤5 min on dev machine
- [ ] TD-046 + TD-074 entries deleted (or TD-074 narrowed) from `dev/state/TECH-DEBT-BACKLOG.md`
- [ ] Fitness-script blackout audit log present in Implementation Observations
- [ ] CHANGELOG entry present; README extended with 6 L2 sections; TESTING-STRATEGY.md L2 paragraph added

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._

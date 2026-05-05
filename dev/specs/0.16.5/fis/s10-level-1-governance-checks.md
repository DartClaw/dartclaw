# S10 — Level-1 Governance Checks (6 tests + format gate)

**Plan**: ../plan.md
**Story-ID**: S10

## Feature Overview and Goal

Install six Level-1 fitness test files at `packages/dartclaw_testing/test/fitness/` plus a `dart format --set-exit-if-changed` CI gate so every commit (≤30s total) is screened against the architectural drift classes 0.16.4 surfaced — barrel hygiene, file-LOC ceilings, package cycles, ctor parameter explosion, `ProcessEnvironmentPlan` duplication regression, and raw `git` subprocess use. Allowlists are committed plain-text under `test/fitness/allowlist/<test-name>.txt` with rationale comments so every intentional waiver is auditable. Decisions Log row 79 retires the originally-planned `alertable_events_test.dart`; S01's compiler-enforced exhaustive `switch` over `sealed DartclawEvent` supersedes it.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S10 — Level-1 Governance Checks" entry under Story-Scoped File Map; Shared Decisions #2, #10, #11, #12, #16, #21; Binding PRD Constraints #2, #21, #29, #37, #40, #70, #82, #83, #84)_

## Required Context

### From `prd.md` — "FR6: Fitness Functions + Dartdoc Governance" (L1 list)
<!-- source: ../prd.md#fr6-fitness-functions--dartdoc-governance -->
<!-- extracted: e670c47 -->
> **Description**: Thirteen governance checks in CI prevent recurrence of every drift class surfaced by this sprint, plus `public_member_api_docs` lint flip in four near-clean packages (S37). Level-1 consists of six fitness test files plus one format gate; Level-2 consists of six fitness test files.
>
> **Level-1 (≤30s, every commit):**
> 1. `barrel_show_clauses_test.dart` — every `export 'src/...'` has `show`
> 2. `max_file_loc_test.dart` — no `lib/src/**/*.dart` > 1,500 LOC
> 3. `package_cycles_test.dart` — zero cycles in pkg graph
> 4. `constructor_param_count_test.dart` — no public ctor > 12 params
> 5. `dart format --set-exit-if-changed` gate
> 6. `no_cross_package_env_plan_duplicates_test.dart` — `ProcessEnvironmentPlan implements` clauses only inside `dartclaw_security` (or allowlisted credential-carrying impls) — catches S32 regression
> 7. `safe_process_usage_test.dart` — Dart-native promotion of `dev/tools/check_git_process_usage.sh`; zero raw `Process.run('git', ...)` in production code
>
> Removed candidate: `alertable_events_test.dart`; S01 now uses compiler-enforced exhaustive switch expressions on the sealed event hierarchy instead of a runtime fitness test.
>
> **Acceptance Criteria** (S10-applicable subset):
> - [ ] All 7 L1 governance checks green; allowlists reflect intentional remaining violators
> - [ ] Tests + dartdoc lint documented in `TESTING-STRATEGY.md`

### From `plan.md` — "S10: Level-1 Governance Checks (6 tests + format gate)"
<!-- source: ../plan.md#s10-level-1-governance-checks-6-tests--format-gate -->
<!-- extracted: e670c47 -->
> **Scope**: Add 6 Level-1 fitness test files plus a CI format gate, hosted in `packages/dartclaw_testing/test/fitness/`. A tiny workspace-root helper script (`dev/tools/run-fitness.sh`) wraps `dart test packages/dartclaw_testing/test/fitness/` so CI and local contributors invoke one command; `dart format --set-exit-if-changed packages apps` runs as the seventh Level-1 governance check in CI, **not** as a test file. Rationale frozen here so S25 (Level-2) uses the same fitness-test location. (a) `barrel_show_clauses_test.dart` — allowlist current exceptions, fail on new. (b) `max_file_loc_test.dart` — no `lib/src/**/*.dart` > 1,500 LOC; baseline allowlist covers current intentional violators with explicit shrink targets. (c) `package_cycles_test.dart` — zero cycles in workspace package graph. (d) `constructor_param_count_test.dart` — no public ctor > 12 params; allowlist `DartclawServer` until S18 lands. (e) `no_cross_package_env_plan_duplicates_test.dart` — assert `ProcessEnvironmentPlan implements` clauses appear only inside `dartclaw_security`, except for implementations that add concrete credential fields (allowlist: `GitCredentialPlan` in `dartclaw_server`). Catches regression of S32 at PR time. (f) `safe_process_usage_test.dart` — Dart-native promotion of `dev/tools/check_git_process_usage.sh`. **Framing updated 2026-04-30**: 0.16.4 S47 + S39 already drove production-code occurrences of raw `Process.run('git', ...)` / `Process.start('git', ...)` to zero. This fitness test **freezes that post-S47 baseline** as a regression guard (allowlist: `SafeProcess` itself, `WorkflowGitPort` impl). Removed candidate: `alertable_events_test.dart`; S01 now uses compiler-enforced exhaustive switch expressions instead of a runtime enumeration test. All test files use existing deps (`package:test`, `package:analyzer`, `package:package_config`) — no new dependencies.
>
> **Acceptance Criteria**:
> - [ ] 6 Level-1 fitness test files exist and pass; the format gate runs separately in CI (must-be-TRUE)
> - [ ] Allowlists are explicit files committed to the repo with rationale comments (must-be-TRUE)
> - [ ] CI pipeline runs the Level-1 fitness suite and format gate on every commit (must-be-TRUE)
> - [ ] Each fitness function has a documented "how to resolve a failure" section in its own `README.md` or in `TESTING-STRATEGY.md`
> - [ ] Adding a new wholesale `export 'src/...'` or a 1,501-LOC file fails the build locally
>
> **Key Scenarios**:
> - Happy: developer runs `dev/tools/run-fitness.sh` locally, suite completes in ≤30s, all green
> - Edge: developer legitimately needs a 1,600-LOC file; allowlist update process is documented
> - Error: a sneaky `export 'src/foo.dart';` in a new PR → `barrel_show_clauses_test.dart` fails with file + line

### From `.technical-research.md` — Binding PRD Constraints (S10-applicable)
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #2 (Constraint): "No new dependencies in any package. Fitness functions use existing `test` + `analyzer` + `package_config`." — Applies to all stories.
> #21 (FR3): "`testing_package_deps_test.dart` + `no_cross_package_env_plan_duplicates_test.dart` fitness functions pass." — Applies to S10, S25, S32 (S10 ships `no_cross_package_env_plan_duplicates_test.dart`; S25 ships `testing_package_deps_test.dart`).
> #29 (FR4): "`max_file_loc_test.dart` and `constructor_param_count_test.dart` fitness functions pass." — Applies to S10, S15, S16, S18.
> #37 (FR6): "L1 governance: 6 fitness test files + format gate. Removed candidate: `alertable_events_test.dart`." — Applies to S10.
> #40 (FR6): "Tests + dartdoc lint documented in `TESTING-STRATEGY.md`." — Applies to S10, S25, S37.
> #70 (NFR Performance): "Level-1 checks ≤30s; Level-2 suite ≤5 min." — Applies to S10, S25.
> #82 (FR6): "Adding a new wholesale `export 'src/...'` or a 1,501-LOC file fails the build locally." — Applies to S10.
> #83 (FR6): "Each fitness function has a documented 'how to resolve a failure' section in its own `README.md` or in `TESTING-STRATEGY.md`." — Applies to S10, S25.
> #84 (Data Requirements): "Fitness-function allowlists are plain-text files under `test/fitness/allowlist/`." — Applies to S10, S25.
> #79 (Decisions Log): "Compiler-exhaustive switch over `sealed DartclawEvent` in S01 replaces the originally-planned custom `alertable_events_test.dart` runtime test." — Applies to S01, S10.

### From `.technical-research.md` — Shared Architectural Decisions (S10-applicable)
<!-- source: ../.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> **2. S01 + S09 → S10 — L1 fitness baseline contract** — 6 fitness test files at `packages/dartclaw_testing/test/fitness/*.dart` + `dart format --set-exit-if-changed packages apps` CI gate (NOT a 7th test file). Allowlists committed plain-text at `packages/dartclaw_testing/test/fitness/allowlist/<test-name>.txt`, each line `pattern  # rationale`. No `alertable_events_test.dart` — S01 supersedes via compiler. PRODUCERS: S01 freezes "no runtime exhaustiveness test"; S09 freezes barrel-show baseline (≤35 exports with `show`). CONSUMER: S10 (writes the 6 tests + format gate).
>
> **10. Fitness test location** — `packages/dartclaw_testing/test/fitness/**/*.dart` is the single source of truth. Established by S10, reused by S25, referenced by S28 (`workflow_task_boundary_test.dart`). Helper script `dev/tools/run-fitness.sh` wraps `dart test packages/dartclaw_testing/test/fitness/`.
>
> **11. Allowlist file shape** — committed plain-text under `packages/dartclaw_testing/test/fitness/allowlist/<test-name>.txt`. Each line: `pattern  # rationale-or-shrink-target`. Rationale comment mandatory.
>
> **12. Process Environment Plan canonical types** — `InlineProcessEnvironmentPlan` (public class) and `ProcessEnvironmentPlan.empty` live in `dartclaw_security/lib/src/process/inline_process_environment_plan.dart` (or `safe_process.dart`) post-S32. Stories must not reinvent — `no_cross_package_env_plan_duplicates_test.dart` (S10) catches regressions; allowlist exempts only `GitCredentialPlan` in `dartclaw_server` (genuine credential-carrying impl).
>
> **16. Sealed events / `DartclawEvent`** — `sealed class DartclawEvent` with exhaustive `switch (event)` expressions in `AlertClassifier`/`AlertFormatter`. S01 supersedes the originally-planned runtime exhaustiveness test for L1.
>
> **21. Fitness function "how to resolve" docs** — each L1/L2 fitness has documented resolution in its own `README.md` next to the test or in `docs/guidelines/TESTING-STRATEGY.md`.

## Deeper Context

- `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` — reference pattern for a Dart-only fitness test (regex import scanning, `dart:io`, `package:test`); reuse the `_findWorkflowLib()` / `_relativeTo()` repo-root walk pattern. **Mirror this style; do NOT introduce `package:analyzer` ASTs unless absolutely required.**
- `packages/dartclaw_testing/CLAUDE.md` § "Conventions" — fitness tests under `test/fitness/` are package-local checks; new fakes register in `public_api_test.dart`; fitness tests don't.
- `dev/tools/check_git_process_usage.sh` — bash equivalent of `safe_process_usage_test.dart`; this story promotes the check to Dart for structured diagnostics, retiring the bash wrapper at the same time it lands (Boy-Scout cleanup).
- `dev/tools/arch_check.dart` — existing repo-root fitness tooling: dependency-graph allowlist (`_expectedWorkspaceDependencies`), barrel-export ceiling, cross-package src-import check. Reuse the workspace-walking helpers (`_workspaceMembers`, `_packageMembers`) as a pattern; do NOT extract them — duplication across two fitness scripts is acceptable until S25 unifies.
- `dev/tools/fitness/check_workflow_server_imports.sh` — to be retired; S28 replaced its workflow scope with a Dart fitness test, and S10 establishes the Dart fitness suite as the single source of truth (per S28 plan note line 317).
- `dev/specs/0.16.5/prd.md#decisions-log` row "Compiler-exhaustive switch over `sealed DartclawEvent`…" — explicit retirement of `alertable_events_test.dart`.
- `dev/guidelines/TESTING-STRATEGY.md` — currently has no "Fitness functions" section. This story adds one (per Binding Constraint #40 / #83 — own `README.md` per test OR `TESTING-STRATEGY.md` covers all six).

## Success Criteria (Must Be TRUE)

- [ ] Six Dart test files exist at `packages/dartclaw_testing/test/fitness/`: `barrel_show_clauses_test.dart`, `max_file_loc_test.dart`, `package_cycles_test.dart`, `constructor_param_count_test.dart`, `no_cross_package_env_plan_duplicates_test.dart`, `safe_process_usage_test.dart` — and all six pass `dart test packages/dartclaw_testing/test/fitness/` against current `main`
- [ ] `dart format --set-exit-if-changed packages apps` runs as a separate CI step (the "format gate") on every commit, **not** as a 7th test file
- [ ] Allowlists are plain-text files under `packages/dartclaw_testing/test/fitness/allowlist/<test-name>.txt`; each non-empty, non-comment line has the form `pattern  # rationale-or-shrink-target` (rationale mandatory) — verifiable by a self-test inside the suite
- [ ] `dev/tools/run-fitness.sh` wrapper exists, executable, and a single invocation runs the entire L1 fitness suite + format gate, exits 0 on green, exits non-zero with file:line diagnostics on red
- [ ] CI pipeline (existing CI surface — see Code Patterns; release-check uses `release_check.sh`, regular CI uses GitHub Actions if present) invokes `dev/tools/run-fitness.sh` plus the format gate on every commit; total wall-clock for the L1 suite ≤30s on a clean checkout (Constraint #70)
- [ ] Adding a new wholesale `export 'src/foo.dart';` (no `show` clause) anywhere in `packages/*/lib/*.dart` causes `barrel_show_clauses_test.dart` to fail locally with `file:line: wholesale export 'src/...' missing show clause`
- [ ] Adding a new file >1,500 LOC under `packages/<X>/lib/src/` causes `max_file_loc_test.dart` to fail locally with `<relative-path>: <LOC> lines (limit 1500)`
- [ ] Each of the 6 fitness tests has a documented "How to resolve a failure" section — either in a sibling `packages/dartclaw_testing/test/fitness/README.md` (one section per test) OR in a new `## Fitness Functions` section in `dev/guidelines/TESTING-STRATEGY.md` (Constraint #40 / #83). One canonical home per test, not both.
- [ ] Allowlist `barrel_show_clauses.txt` baseline reflects post-S09 state: zero `dartclaw_workflow` wholesale exports, plus the surviving wholesale exports in other package barrels (~41 lines based on pre-S09 measurement minus S09's ~34)
- [ ] Allowlist `max_file_loc.txt` baseline lists exactly the two known >1,500 LOC files (`packages/dartclaw_config/lib/src/config_parser.dart` 1,644 → ≤1,200 by S13, `packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart` 1,630 → ≤900 by S15) with shrink-target rationale
- [ ] Allowlist `constructor_param_count.txt` lists `DartclawServer._` (in `packages/dartclaw_server/lib/src/server.dart`) with rationale "S18 dep-group struct refactor" — and only that entry (verify no other public ctor exceeds 12 params)
- [ ] Allowlist `no_cross_package_env_plan_duplicates.txt` lists the two confirmed pre-S32 duplicates (`_InlineProcessEnvironmentPlan` in `project_service_impl.dart` and `remote_push_service.dart`) with shrink-target "S32 promotion" plus the genuine `GitCredentialPlan` exception with rationale "credential-carrying impl"; entries auto-shrink as S32 lands (the two `_InlineProcessEnvironmentPlan` lines drop in the same PR that promotes them)
- [ ] Allowlist `safe_process_usage.txt` lists `SafeProcess.git` callsite (the canonical wrapper itself) and the `WorkflowGitPort` concrete impl with rationale "canonical implementation — must invoke `Process.start('git'…)` to actually spawn git"
- [ ] No new dependencies added to any package's `pubspec.yaml` (Binding Constraint #2 verified by `git diff packages/*/pubspec.yaml apps/*/pubspec.yaml` showing only path/`yaml`/`http` if anything; nothing else)
- [ ] Workspace-wide strict-casts and strict-raw-types remain on (Binding Constraint #3 — fitness tests do not relax `analysis_options.yaml`)
- [ ] `dev/tools/check_git_process_usage.sh` deleted (replaced by `safe_process_usage_test.dart`); `dev/tools/fitness/check_workflow_server_imports.sh` deleted only if its scope is fully covered by `workflow_task_boundary_test.dart` (S28) — verify by reading both first
- [ ] CHANGELOG `0.16.5 - Unreleased` gains a `### Added` bullet naming the six L1 fitness checks + format gate; wording mentions allowlist convention

### Health Metrics (Must NOT Regress)

- [ ] `dart test` workspace-wide passes (no behavioural regressions to existing tests)
- [ ] `dart analyze --fatal-warnings --fatal-infos` clean
- [ ] `arch_check.dart` continues to pass against current main (the new fitness tests are additive, not a replacement; `arch_check.dart` itself stays — its checks are at L2 / repo-tooling tier, complementary to L1 test files)
- [ ] `release_check.sh` invocation surface unchanged (the fitness step plugs into the existing `dart test` block, not a new top-level gate)
- [ ] `dart format` over the new files leaves zero drift (the test files themselves pass the format gate they enforce)

## Scenarios

### Developer runs the L1 fitness suite locally and it completes ≤30s green
- **Given** a clean checkout of `main` after S10 has shipped
- **When** the developer runs `dev/tools/run-fitness.sh`
- **Then** wall-clock duration is ≤30s, exit code is 0, stdout reports each of the six tests as passing, and no allowlist self-test reports a malformed line

### A sneaky `export 'src/foo.dart';` in a new PR fails with file:line
- **Given** S10 has shipped and `barrel_show_clauses_test.dart` is green against `main`
- **When** a contributor adds `export 'src/secret_helper.dart';` (no `show` clause) to `packages/dartclaw_core/lib/dartclaw_core.dart` and runs `dart test packages/dartclaw_testing/test/fitness/barrel_show_clauses_test.dart`
- **Then** the test fails with output that names the file and line: `packages/dartclaw_core/lib/dartclaw_core.dart:<line>: wholesale export 'src/secret_helper.dart' missing show clause` and the failure points the contributor at `test/fitness/README.md` (or `TESTING-STRATEGY.md`) "How to resolve" section

### A new 1,501-LOC `lib/src/` file fails the build locally
- **Given** S10 shipped; `max_file_loc.txt` allowlist contains only the two known offenders (`config_parser.dart` 1,644, `foreach_iteration_runner.dart` 1,630) with shrink-target rationales
- **When** a contributor adds `packages/dartclaw_workflow/lib/src/big_new_module.dart` at 1,501 LOC
- **Then** `max_file_loc_test.dart` fails with `packages/dartclaw_workflow/lib/src/big_new_module.dart: 1501 lines (limit 1500)` and the test's failure message names the allowlist update process

### Legitimate 1,600-LOC need follows the documented allowlist update process
- **Given** a contributor has a defensible reason to land a 1,600-LOC file (e.g. a generated parser table)
- **When** they consult the documented "How to resolve a failure" section
- **Then** the doc instructs: (1) add the file path to `packages/dartclaw_testing/test/fitness/allowlist/max_file_loc.txt` with format `<relative-path>  # <rationale-and-shrink-target-or-permanent-justification>`; (2) the rationale comment is mandatory and reviewed at code-review time; (3) re-run the test to confirm green

### S32 regression scenario — a cross-package `_InlineProcessEnvironmentPlan` re-introduction fails
- **Given** S32 has landed (the two pre-existing `_InlineProcessEnvironmentPlan` impls in `dartclaw_server` deleted) and the S10 allowlist updated to drop those two entries (leaves only `GitCredentialPlan` exempt)
- **When** a future PR re-introduces a `final class _MyPlan implements ProcessEnvironmentPlan` outside `dartclaw_security` without adding the GitCredential-style "carries credentials" justification
- **Then** `no_cross_package_env_plan_duplicates_test.dart` fails with `<file>:<line>: ProcessEnvironmentPlan implementation outside dartclaw_security; allowlist GitCredentialPlan only`

### Raw `Process.run('git'…)` re-introduction is caught
- **Given** post-0.16.4 baseline has zero raw `Process.run('git'…)` / `Process.start('git'…)` in production code (only `SafeProcess.git` and `WorkflowGitPort` concrete impl invoke git)
- **When** a contributor adds `await Process.run('git', ['status']);` to `packages/dartclaw_server/lib/src/foo.dart`
- **Then** `safe_process_usage_test.dart` fails with `packages/dartclaw_server/lib/src/foo.dart:<line>: raw git Process.run; use SafeProcess.git`

## Scope & Boundaries

### In Scope

- Author six Dart test files at `packages/dartclaw_testing/test/fitness/` per the file map in `.technical-research.md` § "S10"
- Author six allowlist files at `packages/dartclaw_testing/test/fitness/allowlist/<test-name>.txt` with rationale-comment line format
- Author `dev/tools/run-fitness.sh` wrapper script (bash, executable, invokes `dart test` + format gate)
- Add CI step (the existing CI workflow file under `.github/workflows/` if present, or `release_check.sh` if CI uses that) to invoke `run-fitness.sh` and the format gate on every commit. **If a CI workflow file does not exist** in this repo (verify first), defer the CI wiring to whatever automation surface does run on every commit (`release_check.sh` already runs `dart format --set-exit-if-changed` — this story makes the fitness suite likewise required at that surface).
- Add "How to resolve a failure" docs — single canonical home: `packages/dartclaw_testing/test/fitness/README.md` (one section per test). `TESTING-STRATEGY.md` gains one paragraph cross-linking to the README rather than duplicating content.
- CHANGELOG entry under `## 0.16.5 - Unreleased` `### Added`
- Delete `dev/tools/check_git_process_usage.sh` (replaced by `safe_process_usage_test.dart`)
- Boy-Scout: delete `dev/tools/fitness/check_workflow_server_imports.sh` ONLY if its scope is fully covered by `workflow_task_boundary_test.dart` (verify by reading both); if it covers anything S28 doesn't, leave it alone

### What We're NOT Doing

- Authoring the L2 fitness suite (`dependency_direction_test.dart`, `src_import_hygiene_test.dart`, `testing_package_deps_test.dart`, `barrel_export_count_test.dart`, `enum_exhaustive_consumer_test.dart`, `max_method_count_per_file_test.dart`) — that is **S25's** scope; this story freezes the directory + allowlist conventions S25 reuses
- Authoring `alertable_events_test.dart` — explicitly retired (Decisions Log row 79; Binding Constraint #79). S01's compiler-enforced exhaustive `switch` over `sealed DartclawEvent` supersedes it. **Do not silently reintroduce it as a 7th L1 file.**
- Fixing the existing intentional violators (`config_parser.dart` shrink to ≤1,200 LOC is S13; `foreach_iteration_runner.dart` shrink to ≤900 is S15; `DartclawServer._` ctor reduction is S18; `_InlineProcessEnvironmentPlan` deletion is S32) — this story **allowlists** them with shrink-target rationale; it does not move their LOC or param counts
- Authoring a fitness-script blackout audit / inventory — that is an **S25** acceptance criterion (S25's L2 suite enumerates which `dev/tools/fitness/*.sh` scripts get retired). S10 only retires the one `check_git_process_usage.sh` script that `safe_process_usage_test.dart` directly supersedes.
- Adding any new package dependency — Binding Constraint #2 forbids. The plan/PRD wording "uses existing `package:test` + `package:analyzer` + `package:package_config`" is read here as "uses what is already reachable from `dartclaw_testing`'s pubspec," which is `dart:io` + `package:test` + regex (mirroring `workflow_task_boundary_test.dart`). If a check genuinely needs `package:analyzer` AST parsing, **stop and surface as a blocker** rather than silently adding the dep.
- Tuning ratchets in `arch_check.dart` (the `_coreLocCeiling` / `_barrelExportCeiling` / `_workspacePackageCeiling`) — those are repo-tooling-tier and orthogonal to the L1 test files

### Agent Decision Authority

- **Autonomous**: For each test file, choose the simplest implementation that passes the Verify line — prefer regex line scanning over AST parsing where both work (the existing `workflow_task_boundary_test.dart` pattern). The plan's "use `package:analyzer`" mention is permissive, not mandatory.
- **Autonomous**: Choose the README vs. `TESTING-STRATEGY.md` location for "How to resolve" docs. Default: `packages/dartclaw_testing/test/fitness/README.md` per-test sections; one cross-linking paragraph in `TESTING-STRATEGY.md` § new "Fitness Functions" subsection.
- **Autonomous**: Decide which `dev/tools/fitness/*.sh` scripts are fully superseded by S10 and can be retired in this story (only those whose scope is 100% covered; partial overlap → leave alone for S25).
- **Escalate**: If a check genuinely requires `package:analyzer` (e.g. `constructor_param_count_test.dart` cannot reliably count named/positional params with regex on multi-line ctor declarations), stop and surface — adding `analyzer` as a dev dep is a Binding Constraint #2 question that needs explicit approval, not a silent decision. **Likely outcome**: regex with multi-line read-ahead is sufficient for `DartclawServer._` and similar; analyzer is unnecessary.
- **Escalate**: If `package_cycles_test.dart` discovers any actual cycle on `main` (it shouldn't — `arch_check.dart`'s expected-deps graph is acyclic), do not paper over with an allowlist — surface the cycle as a real architectural finding.

## Architecture Decision

**We will**: host all six L1 fitness tests at `packages/dartclaw_testing/test/fitness/*.dart` (single source of truth, established by S28 + reused by S25); run the `dart format --set-exit-if-changed packages apps` gate as a separate CI step (not a 7th test file — wraps a plain CLI exit code, doesn't model as a `test()` block); commit allowlists plain-text under `test/fitness/allowlist/<test-name>.txt` with `pattern  # rationale` line format; reuse existing `package:test` + `dart:io` + regex (mirroring `workflow_task_boundary_test.dart`); the originally-planned `alertable_events_test.dart` is **dropped** — Decisions Log row 79 explicitly notes S01's compiler-enforced exhaustive `switch` over `sealed DartclawEvent` supersedes it (no runtime test needed).

**Rationale**:

1. *Single fitness directory* — S28 has already landed `workflow_task_boundary_test.dart` at this path; `arch_check.dart`'s checks are repo-tooling, complementary not overlapping. Splitting between `test/fitness/` and a separate hierarchy would force every future contributor to look in two places.
2. *Format gate as a CI step, not a test file* — `dart format --set-exit-if-changed` is a CLI invocation that already exits non-zero on drift. Wrapping it as `test('format passes', () { Process.runSync(...) })` adds noise (test runner setup cost, log churn, can't run in parallel with other format runs) for zero diagnostic gain. The plan explicitly calls this out: "the seventh Level-1 governance check in CI, not as a test file."
3. *Plain-text allowlists with rationale comments* — generated allowlists rot silently; plain-text files force every entry through code review. The rationale comment is the forcing function for the conversation: "why is this here?" "what's the shrink target?" The Shared Decision #11 contract pins the line shape.
4. *Reuse existing deps, no `package:analyzer`* — Binding Constraint #2 forbids new deps; the existing fitness test pattern (regex import scanning) handles every L1 check straightforwardly. AST parsing is overkill for "does this line have `show`" / "does this file have >1,500 lines" / "does this declaration `implements ProcessEnvironmentPlan`."
5. *No `alertable_events_test.dart`* — Decisions Log row 79 makes this explicit. Adding it back as a 7th file is **wrong** — it solves a problem the compiler now solves directly, and the plan/PRD/research all converge on its retirement.

**Alternatives considered**:

1. **Fitness tests inside `dev/tools/fitness/`** — rejected: divides the suite between `dart test` (workflow-task-boundary, S25) and an ad-hoc bash runner; doubles the CI setup; loses `package:test` reporting (timing, fail-fast, isolated test groups).
2. **`dart format` as a 7th test file** — rejected: adds a `Process.runSync` wrapper for a one-line CLI invocation already in `release_check.sh`; complicates parallelism (the format walk is workspace-wide and slow-to-start).
3. **Generated allowlists** (e.g. `dart run dev/tools/regenerate_allowlists.dart`) — rejected: loses the "rationale comment forces conversation" property; allowlist drift becomes invisible to reviewers.
4. **Add `package:analyzer` as a dev dep** — rejected per Binding Constraint #2; regex on `dart:io.readAsLinesSync()` is sufficient for every L1 check.
5. **Keep `alertable_events_test.dart`** — rejected per Decisions Log row 79: redundant with S01's compiler-enforced exhaustive `switch`; running both is belt-and-braces redundant.

## Technical Overview

### Integration Points

- **Producers**:
  - S01 (Spec Ready) freezes the "compiler-enforced exhaustive `switch` over `sealed DartclawEvent`" baseline → S10 omits `alertable_events_test.dart`
  - S09 (Spec Ready) narrows `dartclaw_workflow` barrel to ≤35 `show`-clause exports → S10's `barrel_show_clauses.txt` allowlist starts from the post-S09 baseline (zero workflow-package wholesale exports)
- **Consumers (downstream of S10)**:
  - S22 (model migration) uses `max_file_loc_test.dart` + `package_cycles_test.dart` + `barrel_show_clauses_test.dart` as a regression net
  - S25 (L2 fitness) reuses `test/fitness/` directory + allowlist convention; encodes its own allowed-pkg-edges table after S11 lands
  - S32 (`ProcessEnvironmentPlan` promotion) auto-shrinks `no_cross_package_env_plan_duplicates.txt` (drops the two `_InlineProcessEnvironmentPlan` entries) in the same PR that promotes them — S10's test must remain green throughout
  - S13/S15/S18 each shrink one allowlist entry as their LOC/ctor-param targets are met
- **Existing infrastructure reused**:
  - `dev/tools/release_check.sh` already runs `dart format --set-exit-if-changed packages apps` — S10 ensures the L1 fitness suite runs at the same surface
  - `arch_check.dart` continues unchanged at the repo-tooling tier (its dep-graph + core-LOC ratchet checks are complementary)

### Data Models (Allowlist file format)

Each `packages/dartclaw_testing/test/fitness/allowlist/<test-name>.txt`:

- Lines starting with `#` (after optional leading whitespace) are full-line comments — informational
- Blank lines are ignored
- Each non-comment, non-blank line: `<pattern>  # <rationale-or-shrink-target>` — the `  # ` separator (two spaces, hash, one space) is mandatory; rationale is everything after
- `<pattern>` semantics depend on the test:
  - `barrel_show_clauses.txt`: `<package>/<barrel-rel-path>:<line-number>` or `<package>/<barrel-rel-path>` to allowlist the whole barrel (file-level)
  - `max_file_loc.txt`: `<relative-path-from-repo-root>` (e.g. `packages/dartclaw_config/lib/src/config_parser.dart`)
  - `package_cycles.txt`: should be empty on green (no cycles allowed); if non-empty surface as architectural finding
  - `constructor_param_count.txt`: `<class>.<ctor-name>` or `<class>` for default ctor (e.g. `DartclawServer._`)
  - `no_cross_package_env_plan_duplicates.txt`: `<class>` (e.g. `GitCredentialPlan`)
  - `safe_process_usage.txt`: `<relative-path>:<line>` or `<relative-path>` for whole-file (e.g. the canonical `SafeProcess.git` callsite)
- A self-test inside the suite (one extra `test(...)` block, can live in `_allowlist_format_test.dart` or be folded into each test file's `setUpAll`) parses every allowlist file and asserts every non-comment line has `  # ` and a non-empty rationale; this prevents drift to "uncommented allowlist entries"

### CI integration shape

Two-step gate per commit (or one wrapper script that runs both):
1. `bash dev/tools/run-fitness.sh` → invokes `dart test packages/dartclaw_testing/test/fitness/`; exit code propagates
2. `dart format --set-exit-if-changed packages apps` → format gate (already in `release_check.sh`; ensure also in any per-commit CI surface)

`run-fitness.sh` body sketch (no implementation in this spec — keep it tiny, ~10 lines, sets `cd` to repo root, then `exec dart test --reporter expanded packages/dartclaw_testing/test/fitness/`).

## Code Patterns & External References

```
# type | path/url                                                                                | why needed
file   | packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart                 | Reference pattern for Dart-only fitness tests: regex import scanning, dart:io directory walk, _findWorkflowLib / _relativeTo helpers, package:test usage. Mirror style for all six new tests.
file   | dev/tools/check_git_process_usage.sh                                                    | Bash logic to port to Dart for safe_process_usage_test.dart; delete after porting
file   | dev/tools/arch_check.dart:13-54                                                         | Workspace-walking pattern — _expectedWorkspaceDependencies, _workspaceMembers, _packageMembers helpers. Reuse the patterns; don't extract a shared util in this story
file   | dev/tools/release_check.sh                                                               | Existing surface that runs `dart format --set-exit-if-changed` — extend to also call run-fitness.sh
file   | packages/dartclaw_server/lib/src/server.dart:158                                         | DartclawServer._ ctor (high param count) — confirm allowlist target; constructor_param_count_test.dart must allowlist this exact class+ctor name
file   | packages/dartclaw_config/lib/src/config_parser.dart                                      | 1,644 LOC — first allowlist entry for max_file_loc.txt (shrink target: ≤1,200 by S13)
file   | packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart                | 1,630 LOC — second allowlist entry for max_file_loc.txt (shrink target: ≤900 by S15)
file   | packages/dartclaw_server/lib/src/project/project_service_impl.dart                       | _InlineProcessEnvironmentPlan duplicate #1 — allowlist with shrink target "S32 promotion"
file   | packages/dartclaw_server/lib/src/task/remote_push_service.dart                           | _InlineProcessEnvironmentPlan duplicate #2 — same
file   | packages/dartclaw_server/lib/src/task/git_credential_env.dart                            | GitCredentialPlan — allowlist with rationale "credential-carrying impl, exempt"
file   | dev/guidelines/TESTING-STRATEGY.md                                                       | Add a `## Fitness Functions` section cross-linking to test/fitness/README.md
file   | packages/dartclaw_testing/CLAUDE.md                                                      | "Conventions" section: document the new allowlist convention in one line under existing fitness test bullet
```

## Constraints & Gotchas

- **Constraint (Binding #2)**: No new dependencies in any package. The plan/PRD wording about `package:analyzer` + `package:package_config` is permissive ("if needed"); regex over `dart:io.readAsLinesSync()` handles every L1 check based on `workflow_task_boundary_test.dart` evidence. **Do not add deps silently** — escalate if a check truly needs AST.
- **Constraint (Binding #3)**: Workspace-wide strict-casts and strict-raw-types remain on. Test files conform; do not add `// ignore:` directives to bypass.
- **Constraint (Binding #70)**: L1 suite ≤30s. Each test should walk `lib/src/` recursively at most once; avoid re-running `dart pub deps --json` per test (that alone is multi-second). `package_cycles_test.dart` runs `dart pub deps --json` once at suite start (or reuses the cached output from `arch_check.dart` if both run together — but DO NOT couple to `arch_check.dart` for execution).
- **Constraint (Binding #82)**: Adding a new wholesale `export 'src/...'` or a 1,501-LOC file fails build locally — verified via the two negative-path scenarios above. The "fails build locally" wording specifically means `dart test packages/dartclaw_testing/test/fitness/` from a fresh checkout.
- **Avoid**: Coupling allowlist parsing to a custom YAML/JSON schema. The plain-text `pattern  # rationale` shape is intentionally trivial and grep-friendly. Do not over-engineer.
- **Avoid**: Introducing `package:analyzer`. The plan mentions it as permitted-if-needed; reuse `workflow_task_boundary_test.dart`'s regex pattern instead. Adding `analyzer` as a dev dep is a non-trivial scope expansion and would complicate Constraint #2 verification.
- **Avoid**: Putting the format gate inside a `test()` block. The plan and Decision #2 both call this out — separate CI step.
- **Avoid**: Silently re-introducing `alertable_events_test.dart`. Decisions Log row 79 + Binding Constraint #79 + plan scope text all retire it. **If during implementation a "wouldn't this also be useful?" instinct surfaces, refer back to S01's compiler-enforced switch** — the language solves it.
- **Critical**: `safe_process_usage_test.dart` must allowlist the canonical `SafeProcess` class itself (where the `Process.start('git'…)` lives) and `WorkflowGitPort` concrete impl in `dartclaw_server`. **Verify the current production-code state matches the "post-S47 baseline = zero raw `Process.run('git'…)` outside these two"** before declaring the test green; if anything else still uses raw git, that's a 0.16.4 cleanup gap and should be surfaced, not allowlisted.
- **Gotcha**: `dart pub deps --json` output schema for cycle detection: traverse the `packages` array; for each workspace member, follow `directDependencies` recursively, fail on revisit. `arch_check.dart:96-178` parses the same JSON for layering checks — read it as a reference but don't share state (one parse per process; both `arch_check.dart` and S10's `package_cycles_test.dart` run independently).
- **Gotcha**: `barrel_show_clauses_test.dart` must be aware of S09's post-narrowing baseline. Run S09's verification (`rg "^export 'src/" packages/dartclaw_workflow/lib/dartclaw_workflow.dart | rg -v ' show '` returns zero) before starting; otherwise the allowlist baseline will be wrong by ~34 entries.
- **Gotcha**: `umbrella_exports_test.dart` (in `packages/dartclaw/test/`) is unrelated — that's S09's umbrella check; do not duplicate.

## Implementation Plan

> **Vertical slice ordering**: TI01 builds the first fitness test (`barrel_show_clauses`) including the allowlist parser, README "How to resolve" section, and CI invocation — proving the end-to-end pattern. TI02–TI06 add the remaining five tests against the same scaffolding. TI07 wires the runner script. TI08 retires the superseded bash script. TI09 documents in `TESTING-STRATEGY.md` + CHANGELOG.

### Implementation Tasks

- [ ] **TI01** `barrel_show_clauses_test.dart` exists at `packages/dartclaw_testing/test/fitness/`, walks every `packages/<X>/lib/<X>.dart` barrel, asserts every `^export 'src/...'` line carries a `show` clause, with allowlist exemptions read from `packages/dartclaw_testing/test/fitness/allowlist/barrel_show_clauses.txt`. Allowlist parser is a small private helper inside this test file (~20 lines: read lines, strip blank/`#`-prefixed, split on `  # `, return `Map<String, String>` of pattern→rationale, fail if any non-comment line lacks the `  # ` separator or has empty rationale). README "How to resolve" section authored simultaneously.
  - Pattern reference: `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart:71-119` for the test() body shape; `:124-134` for the `_findRepoRoot()` walk.
  - Baseline allowlist: post-S09 wholesale exports in non-workflow barrels (count via `rg "^export 'src/" packages/*/lib/*.dart apps/*/lib/*.dart | rg -v ' show '`). Each entry: `<package>/<barrel-rel-path>:<line>  # <rationale-or-shrink-target>`. **Verify the test fails before writing the allowlist** (TDD red state) by deleting one allowlist entry temporarily and confirming the test reports `<file>:<line>: wholesale export 'src/...' missing show clause`.
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/barrel_show_clauses_test.dart` passes; `git diff packages/dartclaw_testing/test/fitness/allowlist/barrel_show_clauses.txt` shows N entries each with `  # ` + non-empty rationale; injecting a new `export 'src/foo.dart';` (no `show`) into `packages/dartclaw_core/lib/dartclaw_core.dart` and re-running the test fails with output naming the offender file:line; allowlist self-test (the parser fails on missing rationale) is exercised by an in-test temporary file under `Directory.systemTemp.createTempSync()`.

- [ ] **TI02** `max_file_loc_test.dart` exists at the same directory, walks every `packages/<X>/lib/src/**/*.dart`, asserts each file's `readAsLinesSync().length` ≤ 1,500, with allowlist exemptions from `allowlist/max_file_loc.txt`. Two baseline entries: `packages/dartclaw_config/lib/src/config_parser.dart  # 1,644 LOC; shrink to ≤1,200 by S13 (YamlTypeSafeReader)` and `packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart  # 1,630 LOC; shrink to ≤900 by S15 (state-machine extraction)`. Reuse the allowlist parser helper from TI01 (extract to a small `_test_helpers.dart` private file under `test/fitness/_internal/` IF and only if duplication crosses 3 sites; otherwise inline-duplicate per "duplication is fine until S25 unifies" — Boy-Scout extraction is S25's call).
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/max_file_loc_test.dart` passes against current `main`; allowlist file lists exactly those two entries; injecting a 1,501-line throwaway file under `packages/dartclaw_core/lib/src/temp_big.dart` and re-running fails with `packages/dartclaw_core/lib/src/temp_big.dart: 1501 lines (limit 1500)`; remove the throwaway after verification.

- [ ] **TI03** `package_cycles_test.dart` exists at the same directory, runs `dart pub deps --json` from repo root once, parses the workspace member subgraph (filter to packages with `dartclaw_` prefix + `dartclaw` umbrella + `dartclaw_cli`), DFS to detect cycles, fails if any cycle found. Allowlist `allowlist/package_cycles.txt` exists but is **empty** on green (current main has zero cycles per `arch_check.dart`'s expected-deps graph). The test reads the allowlist parser's "0 entries OK" path correctly.
  - Pattern reference: `dev/tools/arch_check.dart:96-178` for the `dart pub deps --json` parse pattern; do NOT call into `arch_check.dart` — implement the cycle DFS independently (~30 LOC).
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/package_cycles_test.dart` passes against current `main`; manually constructing a synthetic cycle (e.g. add a `dartclaw_security` dep on `dartclaw_server` in a temporary pubspec edit) makes the test fail with `cycle detected: dartclaw_server -> dartclaw_security -> dartclaw_server`; revert the synthetic edit.

- [ ] **TI04** `constructor_param_count_test.dart` exists at the same directory, walks `packages/<X>/lib/src/**/*.dart` + `apps/<X>/lib/src/**/*.dart`, finds every public class declaration and its public ctors via regex (multi-line match: `(?<class>class|abstract class|final class|sealed class|interface class|mixin class)\s+(\w+)` followed by ctor declarations matching `^\s+(const\s+)?(factory\s+)?\1[._]?\w*\s*\(`), counts named + positional parameters in each ctor, fails if any > 12, with allowlist `allowlist/constructor_param_count.txt`. Baseline single entry: `DartclawServer._  # ~30 named params; reduces to ≤12 via S18 dep-group structs (_ServerCoreDeps, _ServerTurnDeps, …)`.
  - Counting strategy: read the file as a single string, find each ctor opening `(`, scan forward to the matching `)` (track paren depth, skip strings + comments), split on top-level `,`, count entries. **If regex multi-line ctor parsing turns out unreliable in spot-check** (e.g. fails on the `DartclawServer._` ctor itself), surface as a blocker — do NOT silently add `package:analyzer` as a dev dep without escalation.
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/constructor_param_count_test.dart` passes against current `main`; the test correctly identifies `DartclawServer._` as having >12 params and only that ctor (no false positives); allowlist file has the one entry with rationale; injecting a 13-param public ctor anywhere fails the test with `<file>:<line>: <Class>.<ctor> has 13 parameters (limit 12)`.

- [ ] **TI05** `no_cross_package_env_plan_duplicates_test.dart` exists, walks `packages/<X>/lib/**/*.dart` + `apps/<X>/lib/**/*.dart`, finds every `class\s+(\w+)\s+(?:extends\s+\w+\s+)?implements\s+[^{]*\bProcessEnvironmentPlan\b` declaration, fails if the file's package is not `dartclaw_security` AND the class name is not allowlisted. Baseline allowlist `allowlist/no_cross_package_env_plan_duplicates.txt` has three entries: `_InlineProcessEnvironmentPlan@packages/dartclaw_server/lib/src/project/project_service_impl.dart  # S32 promotion: delete in same PR`, `_InlineProcessEnvironmentPlan@packages/dartclaw_server/lib/src/task/remote_push_service.dart  # S32 promotion: delete in same PR`, `GitCredentialPlan@packages/dartclaw_server/lib/src/task/git_credential_env.dart  # credential-carrying impl, exempt — see Shared Decision #12`.
  - Pattern key: `<class-name>@<relative-file-path>` (the `@` separator distinguishes class name + file when the class name is reused).
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/no_cross_package_env_plan_duplicates_test.dart` passes; the three allowlisted impls are all marked allowed; injecting a new `final class _MyPlan implements ProcessEnvironmentPlan` in `packages/dartclaw_workflow/lib/src/foo.dart` fails with `packages/dartclaw_workflow/lib/src/foo.dart:<line>: ProcessEnvironmentPlan implementation outside dartclaw_security; allowlist GitCredentialPlan only`.

- [ ] **TI06** `safe_process_usage_test.dart` exists, walks `packages/<X>/lib/**/*.dart` + `apps/<X>/lib/**/*.dart` (production code only — exclude `**/test/**`), regex-scans for `Process\.(run|start)\s*\(\s*['"]git\b`, fails on any match outside the allowlist `allowlist/safe_process_usage.txt`. Baseline two entries: `packages/dartclaw_security/lib/src/process/safe_process.dart  # canonical SafeProcess.git wrapper, must spawn git` and `packages/dartclaw_server/lib/src/task/<workflow-git-port-impl-file>.dart  # WorkflowGitPort concrete impl, see ADR-023` (verify the exact filename via `rg -l "class.*WorkflowGitPort.*implements\|implements.*WorkflowGitPort" packages/dartclaw_server/lib/src/task/`).
  - **Verify before writing allowlist**: `rg -n "Process\.(run|start)\s*\(\s*['\"]git" packages apps --glob '!**/test/**'` returns ONLY the two known sites. If any other site appears, that's a 0.16.4 cleanup gap — surface it, do not silently allowlist.
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/safe_process_usage_test.dart` passes; injecting `await Process.run('git', ['status']);` in `packages/dartclaw_server/lib/src/foo.dart` fails with `packages/dartclaw_server/lib/src/foo.dart:<line>: raw git Process.run; use SafeProcess.git`.

- [ ] **TI07** `dev/tools/run-fitness.sh` exists, executable (`chmod +x`), bash, ≤15 LOC, sets `set -euo pipefail`, `cd` to repo root (relative-from-script-path pattern; mirror `dev/tools/check_git_process_usage.sh:4`), then `exec dart test --reporter expanded packages/dartclaw_testing/test/fitness/`. Existing CI surface (`dev/tools/release_check.sh` already runs `dart format --set-exit-if-changed packages apps`) is extended: add a `run-fitness.sh` invocation step alongside the format gate. **If a separate `.github/workflows/*.yml` per-commit CI workflow exists**, also add the two steps there.
  - Verify before extending CI: `cat dev/tools/release_check.sh` to confirm the format gate is already present (Constraint: format gate runs as separate CI step, not as a test file); locate the test-running block and add a `bash dev/tools/run-fitness.sh || exit 1` step right before it (or inside the same `dart test` invocation if `release_check.sh` runs workspace-wide).
  - **Verify**: `bash dev/tools/run-fitness.sh` exits 0 against current main, wall-clock ≤30s on the dev machine; `bash dev/tools/release_check.sh` (or its `--quick` variant) succeeds and includes the new fitness step in its output; `dart format --set-exit-if-changed packages apps` continues to run as a separate CLI step (not from inside a Dart test).

- [ ] **TI08** Boy-Scout retire `dev/tools/check_git_process_usage.sh` (fully superseded by TI06's `safe_process_usage_test.dart`) — `git rm` it. Audit `dev/tools/fitness/check_workflow_server_imports.sh`: read both it and `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` and confirm S28's test fully covers the bash script's scope; if YES, `git rm` it; if NO (e.g. it scans something the Dart test doesn't), leave it and note in CHANGELOG.
  - **Verify**: `git status` shows `dev/tools/check_git_process_usage.sh` deleted; any other deletion is supported by an explicit scope-comparison note in the PR description.

- [ ] **TI09** `packages/dartclaw_testing/test/fitness/README.md` exists with one section per L1 fitness test (six sections), each containing: 1-line "what it enforces", 1-line "why", and a "How to resolve a failure" subsection that names the allowlist file and the rationale-comment requirement. `dev/guidelines/TESTING-STRATEGY.md` gains a new `## Fitness Functions` section (≤30 lines) cross-linking to that README and naming the L1 6+1 split (six tests + format gate). CHANGELOG `## 0.16.5 - Unreleased` `### Added` gains: `Level-1 governance suite — six fitness test files at packages/dartclaw_testing/test/fitness/ + dart format CI gate; allowlists at test/fitness/allowlist/<test-name>.txt with rationale comments. See packages/dartclaw_testing/test/fitness/README.md.`
  - **Verify**: `rg "## .*Fitness" dev/guidelines/TESTING-STRATEGY.md` finds the new section; `cat packages/dartclaw_testing/test/fitness/README.md` shows six test-named sections, each with a `### How to resolve a failure` subheading; CHANGELOG entry exists in the `0.16.5` block.

- [ ] **TI10** Workspace validation: `dart format --set-exit-if-changed packages apps`, `dart analyze --fatal-warnings --fatal-infos`, `dart test`, `bash dev/tools/run-fitness.sh`, `dart dev/tools/arch_check.dart` all pass.
  - **Verify**: All five commands exit 0; total wall-clock for `run-fitness.sh` ≤30s; `arch_check.dart` continues to pass (the new fitness tests are additive, not a replacement).

### Testing Strategy

> Each L1 fitness test IS the test for the success criterion it enforces — there are no separate unit tests for these test files. Verification of behaviour is via the Verify lines (positive: green against `main`; negative: temporary injection of a violator triggers the expected failure).

- [TI01] Scenario "Sneaky `export 'src/foo.dart';` fails" → inject + remove a wholesale export, confirm failure output names file:line
- [TI02] Scenario "1,501-LOC file fails build locally" → inject + remove a 1,501-line throwaway file, confirm failure
- [TI02] Scenario "Legitimate 1,600-LOC need follows the documented allowlist update process" → README "How to resolve" section text is the proof (TI09)
- [TI03] Scenario coverage indirect — package_cycles_test.dart green on main, synthetic cycle injection during TI03 verify proves the negative path
- [TI04] No external scenario; Verify line proves both positive (DartclawServer._ allowlisted) and negative (13-param injection)
- [TI05] Scenario "S32 regression — cross-package _InlineProcessEnvironmentPlan re-introduction fails" → inject + remove
- [TI06] Scenario "Raw `Process.run('git'…)` re-introduction is caught" → inject + remove
- [TI07] Scenario "Developer runs the L1 fitness suite locally and it completes ≤30s green" → time `bash dev/tools/run-fitness.sh` on dev machine
- [TI09] No new test; manual review of README + TESTING-STRATEGY.md + CHANGELOG

### Validation

- Standard exec-spec validation gates apply (build/test/analyze + 1-pass remediation).
- Feature-specific: wall-clock measurement of `bash dev/tools/run-fitness.sh` on the dev machine — target ≤30s (Binding Constraint #70); if exceeded, profile with `dart test --reporter json` per-test timing and surface as a finding (likely `package_cycles_test.dart`'s `dart pub deps --json` invocation is the long pole — acceptable up to ~5s of that budget).

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding.
- Prescriptive details (file paths, allowlist file shape `pattern  # rationale`, the six test names, the "format gate as separate CI step not test file" decision, the explicit retirement of `alertable_events_test.dart`) are exact — implement them verbatim.
- The "no new dependencies" constraint is hard. If a task seems to require `package:analyzer`, **stop and escalate** — do not silently add it.
- Allowlist baseline counts (especially `barrel_show_clauses.txt`) depend on S09's post-narrowing state; verify S09 is `Implemented` before measuring the baseline. If S09 hasn't landed yet at execution time, surface as a blocker.
- Mark task checkboxes immediately upon completion — do not batch.

## Final Validation Checklist

- [ ] All Success Criteria met (12 must-be-TRUE items + 5 Health Metrics)
- [ ] All TI01–TI10 tasks fully completed, verified, and checkboxes checked
- [ ] No regressions: `dart test` workspace-wide passes; `dart analyze --fatal-warnings --fatal-infos` clean; `arch_check.dart` continues to pass
- [ ] No new package dependencies — `git diff packages/*/pubspec.yaml apps/*/pubspec.yaml` clean
- [ ] `alertable_events_test.dart` is NOT among the test files (Decisions Log row 79)
- [ ] `bash dev/tools/run-fitness.sh` wall-clock ≤30s
- [ ] CHANGELOG entry present; README authored; TESTING-STRATEGY.md cross-links

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._

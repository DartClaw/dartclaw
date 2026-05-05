# S23 — Housekeeping Sweep + Tech-Debt Mop-Up

**Plan**: ../plan.md
**Story-ID**: S23

## Feature Overview and Goal

Bundle the 0.16.5 housekeeping mop-up into one sweep: pubspec/format/catch hygiene, test-pattern unification (`pumpEventQueue`, `expandHome`), 0.16.4 review-driven cleanup (R-L1/L2/L6/M7/M8), TD closures (TD-054/055/056/060/061/073/085 + S30 residue), `SkillProvisioner` argument-injection defence (SP-1/SP-2), delta-review adds (DR-M3/M2/L2), explicit triage decisions for advisory carry-overs (TD-069/090/089/086), and one stretch (TD-029). Each item is mechanical and individually scoped; bundled per Decisions Log "Housekeeping sweep bundled in Block G" so 0.16.5 ships one coherent CHANGELOG block.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S23 — Housekeeping Sweep + Tech-Debt Mop-Up" entry under per-story File Map)_

## Required Context

### From `plan.md` — "S23: Housekeeping Sweep + Tech-Debt Mop-Up" (scope, base + review-driven + TD mop-up)
<!-- source: ../plan.md#s23-housekeeping-sweep--tech-debt-mop-up -->
<!-- extracted: e670c47 -->
> **Scope** (housekeeping base): (a) Run `dart format packages apps`; verify with `dart format --set-exit-if-changed packages apps` and fix any residual drift. Add a CI `dart format --set-exit-if-changed` step if not added by S10. (b) Align pubspec deps: `yaml: ^3.1.3` everywhere; `path: ^1.9.1` everywhere. Add `dev/tools/check-deps.sh` as a workspace-dep consistency asserter. (c) Audit the 22 production `catch (_)` sites: each gets either `_log.fine(...)` for visibility or a one-line "why silent is appropriate" comment. Special-case `workflow_executor.dart`'s `_maybeCommitArtifacts`/`_cleanupWorkflowGit`/`_initializeWorkflowGit` broad-catch blocks (0.16.4 review H4): narrow to specific exception types (git-spawn failures, worktree-lock issues) and let unexpected errors bubble through `_failRun`. (d) Replace 23 `await Future.delayed(Duration.zero)` in tests with `await pumpEventQueue()`; document the rationale in `TESTING-STRATEGY.md`. (e) Replace 2 `throw Exception('...')` in `schedule_service.dart:246` and `project_service_impl.dart:619` with typed exceptions (`ScheduleTurnFailureException`, `GitFetchException`). (f) Adopt `super.` parameters in `claude_code_harness.dart` + `codex_harness.dart`; drop the `// ignore: use_super_parameters` comments. (g) Add focused unit tests for `expandHome` in `dartclaw_security/test/path_utils_test.dart` (happy path, env missing, `~` alone, `~/` prefix).
>
> **Scope** (0.16.4 review-driven cleanup — breaking changes acceptable per early-stage policy):
> - **R-L2 — Delete `@Deprecated` shims**. 13 symbols/params confirmed unused by production wiring: `WorkflowRegistry.listBuiltIn()` alias, top-level `deliverResult()` (`scheduling/delivery.dart:221-256`), 7 `@Deprecated dynamic` params on `ChannelManager` ctor (`channel_manager.dart:49-55`), 3 `@Deprecated EventBus?` params on `SlashCommandHandler`/`taskRoutes`/`ScheduledTaskRunner`. Update any test-only callers; add a CHANGELOG entry under "Breaking changes". Excludes the `TemplateLoaderService` `@Deprecated` shim being introduced by stretch TD-029.
> - **R-L6 — Add `WorkflowStep.copyWith`**. The resolver at `workflow_definition_resolver.dart:107-140` manually reconstructs `WorkflowStep` via a ~30-argument positional-and-named constructor call. A new step field silently drops from the resolver round-trip. Add `copyWith` covering every field; migrate the resolver. Optional: round-trip fitness test.
> - **R-L1 — ADR-022 step-outcome observability**. When the `<step-outcome>` marker is missing on a non-`emitsOwnOutcome` step, `WorkflowExecutor` increments `workflow.outcome.fallback` silently. Per ADR-022 ("logs a warning"), add a `_log.warning` at the step level naming the run ID and step ID.
> - **R-M7 — Workflow test path helpers**. Consolidate 12 verbatim helper copies across `packages/dartclaw_workflow/test/workflow/`: `_fixturesRoot()` (7 copies), `_definitionsDir()` (3 copies), `_codexAvailable()` (2 copies). Place in `packages/dartclaw_workflow/test/workflow/_support/workflow_test_paths.dart`.
> - **R-M8 — `TaskExecutorTestHarness`**. `setUp`/`tearDown` pairs in `task_executor_test`/`retry_enforcement_test`/`budget_enforcement_test` construct the same topology. Extract into `packages/dartclaw_testing/lib/src/harnesses/task_executor_test_harness.dart`. Cuts ~50 lines per test file.
>
> **Scope** (tech-debt mop-up — each item closes a `TD-NNN`):
> - **TD-054** — Remove settings page badge variant round-trip; delete `_badgeVariantFromClass()`.
> - **TD-055** — Collapse `_readSessionUsage` default-record duplication in `web_routes.dart`. Net ~40-line reduction.
> - **TD-056** — Extract shared `cleanupWorktree(WorktreeManager? mgr, TaskFileGuard? guard, String taskId)` utility and replace the 3 near-identical implementations in `task_routes.dart` + `project_routes.dart` + `task_review_service.dart`.
> - **TD-060** — `dartclawVersion` auto-sync with `pubspec.yaml`: prefer a pre-compile `dev/tools/sync-version.dart` invoked by `dev/tools/build.sh`. If the pre-compile step is >30 LOC, fall back to a release-checklist bullet. Record the chosen path in the FIS.
> - **TD-061** — Surface Codex stderr in logs: pipe stderr through `LineSplitter` and log each line via `_log.warning` (or `_log.fine`).
> - **TD-073** — `externalArtifactMount` collision fail-fast: validator-time detection of duplicate destination paths and runtime fail-fast before overwrite.
> - **TD-085** — `SchemaValidator` supported-subset guard: implement low-cost keywords (`pattern`, `minLength`, `maxLength`, `minItems`, `uniqueItems`) or reject unsupported keywords at validator-load time with a clear "supported subset" diagnostic. Do not silently green-light `oneOf` / `anyOf` / `not` unless implemented.

### From `plan.md` — "S23" (delta-review additions + 0.16.4 deeper-review + triage + stretch + ACs)
<!-- source: ../plan.md#s23-housekeeping-sweep--tech-debt-mop-up -->
<!-- extracted: e670c47 -->
> **Scope** (2026-04-21 delta-review additions):
> - **DR-M3 — Consolidate `FakeProcess` redeclarations** (revised 2026-04-30: **9 redeclarations**). Confirmed sites: `dartclaw_core/test/harness/claude_code_harness_test.dart:22`, `…/claude_hook_events_test.dart:13`, `…/harness_isolation_test.dart:120`, `…/merge_resolve_env_contract_test.dart:31`, `dartclaw_security/test/claude_binary_classifier_test.dart:10`, `dartclaw_signal/test/signal_cli_manager_test.dart:12`, `dartclaw_whatsapp/test/gowa_manager_test.dart:12`, `dartclaw_server/test/container/container_manager_test.dart:419`, plus `_FakeProcessRunner` shims in `service_wiring_andthen_skills_test.dart:278` and `skill_provisioner_test.dart:550` (different shape — runner vs Process — evaluate per-site). Delete locals where shape matches; `import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess, CapturingFakeProcess;`. Extend canonical helper if a local copy diverges. Saves ~250 LOC.
> - **DR-M2 — Delete `resolveGitCredentialEnv` dead wrapper** at `git_credential_env.dart:88-102`; drop from `task_exports.dart:12` `show` list. Keep `resolveGitCredentialPlan` + `GitCredentialPlan`.
> - **DR-L2 — Dead-private-method sweep on rapid-churn files**: grep `foreach_iteration_runner.dart`, `context_extractor.dart`, `workflow_executor_helpers.dart`, `task_executor.dart`, `workflow_cli_runner.dart` for `Future<\w+>\s+_\w+` and `\w+\s+_\w+\(` declarations with zero call sites. Delete.
>
> **Scope** (2026-04-30 deeper-review additions — `SkillProvisioner` ref-injection defence):
> - **SP-1 — `SkillProvisioner` ref shape validation + `--` separators**. `skill_provisioner.dart:307-334` (`_checkout`) and `:316-323` (`_resolveCachedRef` rev-parse) interpolate operator-supplied `config.ref` into `git checkout <ref>` and `git rev-parse origin/$ref` with no `--` separator and no shape validation. Add `^[A-Za-z0-9_./-]+$` validation (raise `SkillProvisionConfigException` on mismatch) and `--` separators on every `git` subcommand that takes a ref argument. Pure argument-injection close (not signature/SHA pinning).
> - **SP-2 — Cached-source origin URL re-validation**. `skill_provisioner.dart:325`: validate cached `origin` URL against config on every startup, regardless of network mode; fail fast if drifted.
>
> **Scope** (2026-04-30 additions — TD triage decisions + ledger residue):
> - **TD-069 advisory triage decisions** — record decisions inline for the six 0.16.4 advisory DECIDE items: H1 (`paused`-as-success policy), H2 (functional-bug-fix verification), M6 (`_ensureKnownDefectsBacklogEntries` mutates cloned fixture), M11 (token metrics on `task.configJson` — already split as TD-066), M12 (`stepDefaults` validator literal-vs-glob workaround), M13 (hardcoded `dart format/analyze/test` in built-in YAMLs vs project_index routing). Removes TD-069 or narrows it.
> - **TD-090 / TD-089 / TD-086 residual triage** — TD-090: validation-time rejection of parallel groups with multiple approval-emitting peers (preferred) or future N-pending model. TD-089: `WorkflowService` dependency value objects → 0.16.5 stretch or 0.17 stabilization. TD-086 residuals: duplicate YAML key policy, parser max-depth/max-bytes guard, parser-vs-validator home for semantic checks, gate-expression diagnostic posture.
> - **S30 residue — error-builder helpers in validator rules**: introduce `_err(type, message, {stepId, loopId})` / `_warn(...)` / `_refErr(stepId, message)` / `_contextErr(stepId, message)` helpers in `packages/dartclaw_workflow/lib/src/workflow/validation/`; migrate the 63 call sites previously cited under retired S30.
> - **Pre-existing test-suite failures from 0.16.4 S67/S68** — verify the "15 known pre-existing failures" are still present and either fix-forward or update STATE.md / CHANGELOG to confirm acceptance.
>
> **Stretch (if capacity, P2)**:
> - **TD-029** — Introduce `TemplateLoaderService` as an injectable parameter in `templates/loader.dart`; keep the global `templateLoader` as a back-compat shim annotated `@Deprecated('use injected TemplateLoaderService')`.
>
> **Acceptance Criteria** (verbatim, all must-be-TRUE except where noted):
> - `dart format --set-exit-if-changed packages apps` green
> - `yaml` and `path` deps aligned across all pubspecs
> - `dev/tools/check-deps.sh` exists and asserts alignment
> - All 22 production `catch (_)` sites have log or comment
> - 23 test `Future.delayed(Duration.zero)` replaced with `pumpEventQueue()`
> - 2 typed exceptions added; 2 `throw Exception` removed
> - `claude_code_harness.dart` + `codex_harness.dart` use super-parameters
> - `expandHome` unit tests exist and pass
> - `TESTING-STRATEGY.md` has `pumpEventQueue` rationale section
> - **TD-054** settings-page round-trip removed; `_badgeVariantFromClass()` deleted
> - **TD-055** `_readSessionUsage` default record DRY'd; net line reduction
> - **TD-056** `cleanupWorktree` shared utility in use at 3 sites
> - **TD-060** auto-sync OR release-checklist entry landed; decision recorded in FIS
> - **TD-061** Codex stderr lines appear in logs at `WARNING` / `FINE`; no regression
> - **TD-073** duplicate destination paths fail at validation or runtime before overwrite; regression test landed
> - **TD-085** Unsupported keywords no longer silently green; supported-subset diagnostic or implementation tested
> - **TD-029** (stretch) seam exists OR carry-forward updated
> - Public `dev/state/TECH-DEBT-BACKLOG.md` updated: resolved entries deleted
> - **R-L2** All 13 `@Deprecated` shims removed; CHANGELOG "Breaking changes" entry landed
> - **R-L6** `WorkflowStep.copyWith` exists and is used by `WorkflowDefinitionResolver`
> - **R-L1** Step-outcome warning log fires on missing marker for non-`emitsOwnOutcome` steps
> - **R-M7** 12 duplicated test-path helpers collapsed into `workflow_test_paths.dart`
> - **R-M8** `TaskExecutorTestHarness` lives in `dartclaw_testing`; 3 task-executor tests use it
> - **DR-M3** All 9 `FakeProcess`-style redeclarations resolved; all 9 test files import from `dartclaw_testing`
> - **DR-M2** `resolveGitCredentialEnv` + `show` entry deleted
> - **DR-L2** Zero uncalled private methods in `foreach_iteration_runner.dart`, `context_extractor.dart`, `workflow_executor_helpers.dart`, `task_executor.dart`, `workflow_cli_runner.dart`
> - **TD-069** all six advisory DECIDE items have a recorded decision; TD-069 deleted or narrowed
> - **TD-090 / TD-089 / TD-086 residuals** decisions recorded; backlog entries deleted, implemented, or narrowed
> - **S30 residue** error-builder helpers exist and are used; 63-call-site migration complete
> - **SP-1** ref shape validated; every `git` subcommand using ref or url uses `--`; injection regression test landed
> - **SP-2** Cached-source `origin` URL re-validated on every startup; mismatched cache fails fast
> - Pre-existing 15 known failures either fixed or formally accepted with rationale recorded

### From `prd.md` — "FR8: Housekeeping Sweep + Tech-Debt Mop-Up" (functional intent)
<!-- source: ../prd.md#fr8-housekeeping-sweep--tech-debt-mop-up -->
<!-- extracted: e670c47 -->
> **Description**: Bundle a single mechanical-mop-up sweep covering `dart format`, pubspec dep alignment, `catch (_)` audit, `pumpEventQueue` test-pattern unification, super-parameters, typed exceptions, and consolidation of duplicate testing helpers. Closes named TD entries and absorbs 0.16.4 review-driven cleanup. **Constraint**: zero new dependencies; zero behavioural change beyond documented breaking deletions.

### From `.technical-research.md` — "Binding PRD Constraints" (S23-applicable rows #2, #57-69, #71, #75)
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #2 (Constraint): "No new dependencies in any package." — Applies to all stories; this story adds no deps.
> #57 (FR8): "Adopt `super.` parameters in `claude_code_harness.dart` + `codex_harness.dart`; drop the `// ignore: use_super_parameters` comments." — S23.
> #58 (FR8): "22 production `catch (_)` sites each have `_log.fine(...)` or a one-line rationale comment." — S23.
> #59 (FR8): "23 test `await Future.delayed(Duration.zero)` → `await pumpEventQueue()`; `TESTING-STRATEGY.md` updated." — S23.
> #60 (FR8): "2 `throw Exception('...')` replaced with typed exceptions (`ScheduleTurnFailureException`, `GitFetchException`)." — S23.
> #61 (FR8): "`expandHome` unit tests added in `dartclaw_security`." — S23.
> #62 (FR8): "Pubspec alignment: `yaml ^3.1.3` + `path ^1.9.1` everywhere; `dev/tools/check-deps.sh` asserter script added." — S23.
> #63 (FR8): "Nine `FakeProcess`-style redeclarations resolved." — S23.
> #64 (FR8): "`resolveGitCredentialEnv` dead wrapper deleted." — S23.
> #65 (FR8): "Dead-private-method sweep on rapid-churn files." — S23.
> #66-69 (FR8 / TD-054/055/056/061): per-TD closures. — S23.
> #71 (NFR Reliability): "Behavioural regressions post-decomposition: Zero — every existing test remains green." — Applies to all code-touching stories; S23 must not regress behaviour.
> #75 (FR8): "`SidebarDataBuilder` extracted; 6 call sites collapsed." — **S24**, NOT S23 (cross-listed only — out of scope here).

### From `plan.md` — Inline ADR summary "ADR-022 — Workflow Run Status Split + Step Outcome Protocol" (R-L1 contract)
<!-- source: ../plan.md#adr-022--workflow-run-status-split--step-outcome-protocol -->
<!-- extracted: e670c47 -->
> If the marker is missing, the executor falls back to task lifecycle status, **logs a warning, and increments `workflow.outcome.fallback`** (the missing-warning behaviour is what S23 R-L1 closes).

## Deeper Context

- `../plan.md#dependency-graph` — S23 is independent ([P]); concurrent with S24 + S35 in W5.
- `../plan.md#story-consolidation-note` — "Tech-debt items inside S23 stay inside S23's FIS (as enumerated sub-checklist items) rather than separate files — they are too small to warrant per-item FIS overhead."
- `../plan.md#decisions-log` (referenced in plan header) — "Housekeeping sweep bundled in Block G" justifies the size of this story.
- `dev/state/SPEC-LIFECYCLE.md` — `dev/specs/` files are temporary; deleted before `main` merge.
- `dev/state/TECH-DEBT-BACKLOG.md` — "Open items only" policy on line 3; resolved entries are deleted, not marked resolved.
- `dev/guidelines/TESTING-STRATEGY.md` — target file for `pumpEventQueue` rationale section (housekeeping item d).
- `packages/dartclaw_testing/lib/src/fake_process.dart` — canonical `FakeProcess` + `CapturingFakeProcess` helper (DR-M3 target).
- `dev/state/STATE.md` — source of "15 known pre-existing failures" claim to verify.

## Success Criteria (Must Be TRUE)

> Each criterion below has a proof path: a Scenario or task Verify line. Grouped by category for readability; ordering matches plan ACs verbatim.

### Housekeeping base (a)–(g)

- [ ] HK-A: `dart format --set-exit-if-changed packages apps` exits 0 (must-be-TRUE; plan AC #1)
- [ ] HK-A: A CI step running `dart format --set-exit-if-changed packages apps` is present (added here if not by S10)
- [ ] HK-B: `yaml: ^3.1.3` and `path: ^1.9.1` appear in every workspace `pubspec.yaml` that depends on them; no other versions of those two pins remain (must-be-TRUE; plan AC #2)
- [ ] HK-B: `dev/tools/check-deps.sh` exists, is executable, and exits non-zero when run against a deliberately drifted pubspec; exits 0 against the post-alignment tree (must-be-TRUE; plan AC #3)
- [ ] HK-C: All 22 production `catch (_)` sites either log via `_log.fine(...)`/`_log.warning(...)` or carry a one-line "why silent is appropriate" comment on the catch line; the `workflow_executor.dart` `_maybeCommitArtifacts` / `_cleanupWorkflowGit` / `_initializeWorkflowGit` blocks catch a named exception type (e.g. `ProcessException`, `FileSystemException`) and let unexpected errors bubble through `_failRun` (plan AC #4 + scope c)
- [ ] HK-D: Zero `await Future.delayed(Duration.zero)` patterns remain in test files under `packages/**/test/` (must-be-TRUE; plan AC #5)
- [ ] HK-D: `dev/guidelines/TESTING-STRATEGY.md` has a section explaining the `pumpEventQueue` choice (plan AC #9)
- [ ] HK-E: `ScheduleTurnFailureException` and `GitFetchException` exist as typed exceptions co-located with their throw sites; the 2 `throw Exception('...')` calls at `schedule_service.dart:246` and `project_service_impl.dart:619` are removed (must-be-TRUE; plan AC #6)
- [ ] HK-F: `claude_code_harness.dart` and `codex_harness.dart` constructors use `super.` parameters; the `// ignore: use_super_parameters` comments are deleted (plan AC #7)
- [ ] HK-G: `packages/dartclaw_security/test/path_utils_test.dart` covers `expandHome` for: happy path (`~/foo` with `HOME` set), env missing (no `HOME`), `~` alone, `~/` prefix; all assertions pass (plan AC #8)

### 0.16.4 review-driven cleanup

- [ ] RV-R-L2: All 13 `@Deprecated` shims removed (`WorkflowRegistry.listBuiltIn()`, top-level `deliverResult()`, 7 `ChannelManager` ctor params, 3 `EventBus?` params); CHANGELOG `0.16.5 - Unreleased` carries a "Breaking changes" entry naming each removal (must-be-TRUE; plan AC #18)
- [ ] RV-R-L6: `WorkflowStep.copyWith({...})` covers every field; `workflow_definition_resolver.dart:107-140` uses it instead of the ~30-arg ctor call (must-be-TRUE; plan AC #19)
- [ ] RV-R-L1: When a non-`emitsOwnOutcome` step finishes without a `<step-outcome>` marker, `WorkflowExecutor` logs at WARNING with both run id and step id, alongside the existing `workflow.outcome.fallback` increment (must-be-TRUE; plan AC #20)
- [ ] RV-R-M7: `packages/dartclaw_workflow/test/workflow/_support/workflow_test_paths.dart` exposes `workflowFixturesRoot()`, `workflowDefinitionsDir()`, `codexAvailable()`, plus `findAncestorDir(List<String>)`; the 12 inline copies are deleted (must-be-TRUE; plan AC #21)
- [ ] RV-R-M8: `packages/dartclaw_testing/lib/src/harnesses/task_executor_test_harness.dart` exists; `task_executor_test`, `retry_enforcement_test`, `budget_enforcement_test` use it (plan AC #22)

### TD mop-up

- [ ] TD-054: `_badgeVariantFromClass()` is deleted from the settings template module; settings-page callers pass variant strings directly using the existing `ChannelStatus` enum (must-be-TRUE; plan AC #10)
- [ ] TD-055: `_readSessionUsage` default record is a single file-private constant or one-shot helper; net file LOC reduced (plan AC #11)
- [ ] TD-056: `cleanupWorktree(WorktreeManager? mgr, TaskFileGuard? guard, String taskId, {Project? project})` exists once under `packages/dartclaw_server/lib/src/task/`; `task_routes.dart`, `project_routes.dart`, `task_review_service.dart` call the shared utility instead of three near-identical local copies (must-be-TRUE; plan AC #12)
- [ ] TD-060: Either `dev/tools/sync-version.dart` regenerates `version.dart` from `pubspec.yaml` and is invoked by `dev/tools/build.sh` (preferred), OR — if the script would exceed 30 LOC — a release-checklist bullet is added to `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`; the chosen path is recorded in this FIS' Implementation Observations (plan AC #13)
- [ ] TD-061: Codex stderr lines appear in app logs at WARNING (or FINE for benign lines) via `_log` in `codex_harness.dart`; existing codex harness tests still pass (must-be-TRUE; plan AC #14)
- [ ] TD-073: Workflows with two steps writing the same `externalArtifactMount` destination fail at validator load time with a diagnostic, OR — if the collision can only be detected at runtime — the executor fails fast before overwriting; a regression test covers the rejection path (must-be-TRUE; plan AC #15)
- [ ] TD-085: `SchemaValidator` either (a) implements `pattern`, `minLength`, `maxLength`, `minItems`, `uniqueItems` keywords with passing unit tests, OR (b) rejects unsupported JSON-Schema keywords (`oneOf`, `anyOf`, `not`, etc.) at validator-load time with a "supported subset" diagnostic. Silent validation-green is no longer possible for unsupported keywords (must-be-TRUE; plan AC #16)
- [ ] TD-029 (stretch): Either `TemplateLoaderService` exists as an injectable seam with `@Deprecated('use injected TemplateLoaderService') final templateLoader` retained as global shim, OR the TD-029 backlog entry is updated with a new "Trigger" pointer (plan AC #17)
- [ ] TD-backlog: Resolved TD entries (TD-029 if shipped, TD-054, TD-055, TD-056, TD-060, TD-061, TD-073, TD-085) are deleted from `dev/state/TECH-DEBT-BACKLOG.md` per its "Open items only" policy (plan AC #43-style closer)

### `SkillProvisioner` argument-injection defence

- [ ] SP-1: `SkillProvisioner` raises `SkillProvisionConfigException` if `config.ref` does not match `^[A-Za-z0-9_./-]+$`; every `git` subcommand using `config.ref` or a URL passes a `--` separator before the ref/URL argument; an injection regression test (e.g. `ref: --upload-pack=…`) asserts the exception (must-be-TRUE; plan AC #29)
- [ ] SP-2: On startup, `SkillProvisioner` reads each cached source's `origin` URL via `git config --get remote.origin.url` (or equivalent) and compares against the configured `git_url`; mismatched cache fails fast with a clear diagnostic — regardless of `andthen.network: disabled` (must-be-TRUE; plan AC #30)

### Delta-review additions

- [ ] DR-M3: All 9 `FakeProcess`-style redeclarations resolved — local copies deleted where shape matches; canonical `dartclaw_testing` helper extended with any missing knobs (e.g. `pid`-override, `killResult`) where shapes diverge; all 9 test files now `import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess, CapturingFakeProcess;` (must-be-TRUE; plan AC #23)
- [ ] DR-M2: `resolveGitCredentialEnv` is deleted from `git_credential_env.dart`; the `show` entry in `task_exports.dart:12` is removed; `resolveGitCredentialPlan` + `GitCredentialPlan` survive (must-be-TRUE; plan AC #24)
- [ ] DR-L2: Zero uncalled private methods remain in `foreach_iteration_runner.dart`, `context_extractor.dart`, `workflow_executor_helpers.dart`, `task_executor.dart`, `workflow_cli_runner.dart` (must-be-TRUE; plan AC #25)

### Triage decisions (recorded inline; no behavioural flips beyond mechanical pieces)

- [ ] TR-TD-069: All six 0.16.4 advisory DECIDE items (H1, H2, M6, M11, M12, M13) have a one-paragraph decision recorded in this FIS' Implementation Observations during execution; TD-069 entry deleted or narrowed in `dev/state/TECH-DEBT-BACKLOG.md` (must-be-TRUE; plan AC #26)
- [ ] TR-TD-090: A 0.16.5 decision is recorded for parallel-group multi-approval-emission (preferred: validation-time rejection); backlog entry deleted, implemented, or narrowed (must-be-TRUE; plan AC #27)
- [ ] TR-TD-089: A 0.16.5 decision is recorded for `WorkflowService` dependency value objects (stretch in 0.16.5 vs 0.17 stabilization); the nullable-but-required ctor contract is explained or eliminated; backlog entry deleted, implemented, or narrowed (must-be-TRUE; plan AC #27)
- [ ] TR-TD-086: 0.16.5 decisions recorded for duplicate YAML key policy, parser max-depth/max-bytes guard, parser-vs-validator semantic-checks home, and gate-expression diagnostic posture; mechanical pieces that fit ride along; otherwise TD-086 narrowed to named residuals (must-be-TRUE; plan AC #27)
- [ ] TR-S30-residue: `_err` / `_warn` / `_refErr` / `_contextErr` helpers exist under `packages/dartclaw_workflow/lib/src/workflow/validation/`; the 63 previously-cited call sites use them (must-be-TRUE; plan AC #28)

### Test-suite acceptance

- [ ] TS-Pre: The 15 pre-existing test failures noted in `dev/state/STATE.md` (`workflow_builtin_integration_test` + `built_in_workflow_contracts_test`) are either fixed-forward (preferred) or formally accepted with one-paragraph rationale recorded in CHANGELOG / STATE.md (plan AC #31)

### Health Metrics (Must NOT Regress)

- [ ] `dart analyze` workspace-wide: 0 warnings, 0 errors (binding constraint #73)
- [ ] `dart test` workspace-wide passes (modulo pre-existing 15-failure baseline above) (binding constraint #71)
- [ ] No new dependencies in any pubspec (binding constraint #2)
- [ ] JSON wire formats and SSE envelopes unchanged (binding constraint #76)
- [ ] No security regression: guard chain, credential proxy, audit logging tests stay green (binding constraint #72)

## Scenarios

### Format gate green after sweep
- **Given** `dart format --set-exit-if-changed packages apps` exited non-zero on at least one drifted file before this sweep
- **When** all S23 tasks are complete
- **Then** the same command exits 0 with no diff output, AND the CI workflow contains a step running this command on every PR

### Codex stderr surfaces in logs (TD-061)
- **Given** an operator launches Codex with an invalid model name so the harness child process emits a stderr line such as `Error: model 'invalid-model' not recognised`
- **When** the harness runs and exits
- **Then** the dartclaw application log contains a record at WARNING level whose message contains `model 'invalid-model' not recognised`, sourced from `codex_harness.dart`

### Unsupported JSON-Schema keyword no longer silently green (TD-085)
- **Given** a workflow author registers a structured-output schema using `oneOf` (and `oneOf` has not been implemented)
- **When** the workflow is validated at load time
- **Then** validation fails with a diagnostic naming the unsupported keyword (`oneOf`) and listing the supported subset, instead of silently passing

### `SkillProvisioner` rejects shape-violating ref (SP-1)
- **Given** an `andthen` skill source config with `ref: --upload-pack=/tmp/pwn.sh`
- **When** `SkillProvisioner` provisions or refreshes the source
- **Then** it throws `SkillProvisionConfigException` naming the `ref` field and the validation regex; no `git` subprocess is spawned with the malformed ref; an integration test asserts both behaviours

### Step-outcome warning fires on missing marker (R-L1)
- **Given** a workflow step that is not opted out via `emitsOwnOutcome: true` and whose final task output omits the `<step-outcome>` marker
- **When** `WorkflowExecutor` finalises the step
- **Then** a WARNING-level log line names the run id and step id alongside the existing `workflow.outcome.fallback` counter increment

### `FakeProcess` consolidation across 9 test files (DR-M3)
- **Given** prior to the sweep, 9 test files declared their own `class FakeProcess implements Process` (or `_FakeProcess` / `_ClaudeFakeProcess`)
- **When** the sweep is complete
- **Then** `rg "class\s+_?(?:Claude|Capturing)?FakeProcess(?!Runner)\s+implements\s+Process" packages apps` returns zero matches outside `packages/dartclaw_testing/lib/src/fake_process.dart`, AND each of the 9 affected test files imports `FakeProcess` (and where applicable `CapturingFakeProcess`) from `package:dartclaw_testing/dartclaw_testing.dart`

### Pubspec drift detector (HK-B)
- **Given** a contributor edits a single workspace pubspec to depend on `yaml: ^3.1.0` (drifted)
- **When** they run `bash dev/tools/check-deps.sh`
- **Then** the script exits non-zero and prints the offending pubspec path + the drifted constraint vs the workspace baseline

## Scope & Boundaries

### In Scope

- All housekeeping items (a)–(g) from plan §S23 base scope
- All 5 review-driven items (R-L1, R-L2, R-L6, R-M7, R-M8)
- All 7 named TD closures (TD-054, TD-055, TD-056, TD-060, TD-061, TD-073, TD-085)
- Stretch TD-029 (gated on capacity)
- All 3 delta-review additions (DR-M2, DR-M3, DR-L2)
- Both `SkillProvisioner` defences (SP-1, SP-2)
- All triage decisions (TD-069, TD-090, TD-089, TD-086, S30 residue) recorded inline in Implementation Observations
- Pre-existing 15 test failures: verify, fix-forward where mechanical, otherwise formally accept with rationale
- `dev/state/TECH-DEBT-BACKLOG.md` deletion of resolved entries
- CHANGELOG `0.16.5 - Unreleased` "Breaking changes" entry for R-L2 deletions; "Housekeeping & tech debt" block for the rest

### What We're NOT Doing

- **`SidebarDataBuilder` extraction** — owned by S24, not this story (binding constraint #75 maps to S24)
- **Structural refactoring of rapid-churn files** beyond the dead-method sweep — `foreach_iteration_runner.dart` decomposition is S15; `task_executor.dart` ctor reduction is S16; this FIS only deletes uncalled private methods
- **New tests beyond those required for R-M7/R-M8 helpers, `expandHome`, SP-1 injection regression, TD-073 collision regression, TD-085 unsupported-keyword diagnostic** — broader test-coverage uplift is out of scope
- **Signature/SHA pinning of skill sources** — explicitly deferred per PRD Decisions Log "AndThen source-authenticity pinning"; SP-1 is argument-injection close only
- **New dependencies** — binding constraint #2; the housekeeping sweep introduces zero new pubspec deps
- **Renaming any public symbols** — that is S22 (model migration) / S36 (naming batch); R-L2 is deletion-only, not renames
- **Touching `_workflow*` task config keys, model migration, or enum work** — owned by S22 / S34 / S35
- **Behaviour change beyond the documented R-L2 deletions** — every other item is mechanical; existing tests must stay green

### Agent Decision Authority

- **Autonomous**: Per-`catch (_)` site, choose between `_log.fine(...)` and a one-line rationale comment based on whether the exception carries diagnostic value (e.g. cleanup paths → comment; protocol parse errors → log).
- **Autonomous**: Per-`Future.delayed(Duration.zero)` site, the replacement is mechanical — `await pumpEventQueue()` from `package:test/test.dart`.
- **Autonomous**: For TD-085, choose between (a) implementing the 5 low-cost keywords or (b) the supported-subset diagnostic, based on which is smaller in LOC. Record the choice in Implementation Observations.
- **Autonomous**: For TD-060, choose `dev/tools/sync-version.dart` (preferred) unless the script would exceed 30 LOC — then fall back to a release-checklist bullet. Record the choice in Implementation Observations.
- **Autonomous**: For pre-existing 15 failures, attempt fix-forward first; if a failure is genuinely intractable in the sweep's scope, record the formal acceptance with rationale.
- **Escalate**: If TD-069/090/089/086 triage reveals an item requires architectural decision (e.g. parallel-group N-pending model), escalate before flipping behaviour — record the deferral in TECH-DEBT-BACKLOG.md and narrow the entry rather than implementing it here.
- **Escalate**: If `dart analyze` reveals R-L2 deletion of a `@Deprecated` symbol breaks a non-test caller, surface for orchestrator review (the plan's "confirmed unused by production wiring" assertion would then be wrong).

## Architecture Decision

**We will**: Bundle the housekeeping mop-up into one story whose tasks are independently sequenceable but ship as one CHANGELOG block ("Housekeeping & tech debt") under the v0.16.5 release; record TD-069/090/089/086 advisory triage decisions inline in this FIS' Implementation Observations during execution — per Decisions Log "Housekeeping sweep bundled in Block G". No new ADR; SP-1/SP-2 are mechanical hardening within the existing `SkillProvisioner` contract; R-L1 closes a pre-existing ADR-022 commitment.

If any triage decision flips observable behaviour beyond the documented R-L2 deletions (e.g. TD-069 H1 `paused`-as-success policy change in the release gate), append a short ADR-023 sibling note (private repo) and cross-link from the Implementation Observations entry.

## Technical Overview

> Detailed file inventory in `.technical-research.md` § "S23 — Housekeeping Sweep + Tech-Debt Mop-Up". Highlights only here.

### Data Models

- New typed exceptions: `ScheduleTurnFailureException` (co-located with `schedule_service.dart`) and `GitFetchException` (co-located with `project_service_impl.dart`). Both extend `Exception` (or a project-local base if convention exists locally — verify before adding); both carry `String message` and `Object? cause`.
- `WorkflowStep.copyWith({...})`: covers every field on `WorkflowStep`; nullable params override; non-nullable params default to current value via the `_unset` sentinel pattern if needed for nullable fields. Verify against existing `copyWith` patterns in `dartclaw_models`.
- No model migrations; no DB schema changes.

### Integration Points

- `SkillProvisioner._checkout` and `._resolveCachedRef`: add `_validateRef(String)` helper; call before any `git` subprocess; insert `--` between subcommand options and ref/URL arguments.
- `codex_harness.dart`: stderr stream piped through `utf8.decoder.bind(...).transform(LineSplitter())` and fed to `_log.warning` (or `_log.fine` for benign lines matching a small allowlist) — mirror the existing `claude_code_harness.dart` pattern (file:line per `.technical-research.md`).
- `WorkflowExecutor` step finalisation: warn-log at the existing `workflow.outcome.fallback`-increment site.
- `cleanupWorktree` shared utility under `packages/dartclaw_server/lib/src/task/` (canonical home of `WorktreeManager`).

## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart                    | Stderr-line-logging pattern to mirror in codex_harness.dart (TD-061)
file   | packages/dartclaw_testing/lib/src/fake_process.dart                                | Canonical FakeProcess + CapturingFakeProcess (DR-M3 target)
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_definition_resolver.dart:107-140 | Site that switches to WorkflowStep.copyWith (R-L6)
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart                 | _maybeCommitArtifacts / _cleanupWorkflowGit / _initializeWorkflowGit broad-catch narrowing (HK-C); step-outcome warn-log site (R-L1)
file   | packages/dartclaw_workflow/lib/src/workflow/skill_provisioner.dart:307-334,316-323,325 | SP-1 / SP-2 sites
file   | packages/dartclaw_workflow/lib/src/workflow/validation/                            | _err / _warn / _refErr / _contextErr helper home (S30 residue)
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_registry.dart:171-172         | listBuiltIn() @Deprecated alias removal (R-L2)
file   | packages/dartclaw_server/lib/src/scheduling/delivery.dart:221-256                  | top-level deliverResult() removal (R-L2)
file   | packages/dartclaw_server/lib/src/channels/channel_manager.dart:49-55               | 7 @Deprecated dynamic ctor params removal (R-L2)
file   | packages/dartclaw_server/lib/src/scheduling/schedule_service.dart:246              | throw Exception → ScheduleTurnFailureException (HK-E)
file   | packages/dartclaw_server/lib/src/project/project_service_impl.dart:619             | throw Exception → GitFetchException (HK-E)
file   | packages/dartclaw_server/lib/src/web/web_routes.dart                               | _readSessionUsage default-record DRY (TD-055)
file   | packages/dartclaw_server/lib/src/api/task_routes.dart                              | cleanupWorktree call site (TD-056)
file   | packages/dartclaw_server/lib/src/api/project_routes.dart:354,397                   | cleanupWorktree call site + duplicate impl removal (TD-056)
file   | packages/dartclaw_server/lib/src/task/task_review_service.dart:298,356,584         | cleanupWorktree call site + duplicate impl removal (TD-056)
file   | packages/dartclaw_server/lib/src/task/git_credential_env.dart:88-102               | resolveGitCredentialEnv removal (DR-M2)
file   | packages/dartclaw_server/lib/src/task/task_exports.dart:12                         | show-list entry removal for resolveGitCredentialEnv (DR-M2)
file   | packages/dartclaw_server/lib/src/templates/loader.dart                             | TemplateLoaderService injectable seam (TD-029 stretch)
file   | packages/dartclaw_security/lib/src/path_utils.dart                                 | expandHome under test (HK-G)
file   | packages/dartclaw_workflow/test/workflow/                                          | 12 helper duplicates → workflow_test_paths.dart (R-M7)
file   | packages/dartclaw_server/test/task/{task_executor_test,retry_enforcement_test,budget_enforcement_test}.dart | 3 setUp/tearDown sites for TaskExecutorTestHarness (R-M8)
file   | packages/dartclaw_workflow/lib/src/workflow/validation/schema_validator.dart       | Supported-subset diagnostic or keyword impl (TD-085)
doc    | dev/guidelines/TESTING-STRATEGY.md                                                 | Add pumpEventQueue rationale section (HK-D)
doc    | dev/state/TECH-DEBT-BACKLOG.md                                                     | Delete resolved entries; narrow others (FN bookkeeping)
doc    | CHANGELOG.md                                                                       | "Breaking changes" R-L2 + "Housekeeping & tech debt" sweep block
url    | https://api.dart.dev/stable/dart-async/StreamTransformer-class.html                | LineSplitter ref for TD-061 stderr piping
```

## Constraints & Gotchas

- **Constraint**: Zero new dependencies in any pubspec — Workaround: re-use `package:logging`, `package:test` (`pumpEventQueue`), `dart:convert` (`LineSplitter`); all already in dev_dependencies or transitive.
- **Constraint**: Workspace strict-casts on (per `analysis_options.yaml`) — all changes must compile with strict casts; `WorkflowStep.copyWith` must be field-exhaustive, no `dynamic` collapses.
- **Avoid**: Treating R-L2 deletions as non-breaking just because the symbols carry `@Deprecated` — they ARE breaking; CHANGELOG must list each one under "Breaking changes".
- **Avoid**: Silent `catch (_)` even after the sweep — if a new `catch (_)` lands without a log or rationale comment, the format/lint pass should reject it; consider `// ignore_for_file: avoid_catches_without_on_clauses` only where genuinely intentional.
- **Avoid**: Changing semantics of `_isWorkflowOrchestrated`/`_executeWorkflowOneShotTask` paths during the dead-method sweep — DR-L2 is delete-only; ADR-023 names these as intentional.
- **Critical**: `WorkflowStep.copyWith` MUST round-trip every field including future-added ones — a missed field reintroduces the silent-drop defect that R-L6 closes. Optional round-trip fitness test is recommended.
- **Critical**: SP-1 ref-shape regex `^[A-Za-z0-9_./-]+$` rejects valid-but-unusual refs like spaces or parentheses — verify against Dart's own ref conventions and the `andthen` source spec; if a real-world ref is rejected, widen the regex with explicit allowlist additions, never with a `.*` wildcard.
- **Gotcha**: TD-073 collision detection — a workflow can legitimately mount the same external artifact at the same path across mutually-exclusive branches of a `parallel`/`gate` step; the collision check must scope by reachable-step-pair, not by absolute path equality across the whole workflow.

## Implementation Plan

> **Vertical slice ordering**: Independent items first (format gate, pubspec deps), then per-package mechanical sweeps grouped to minimise re-test cost, then triage decisions and bookkeeping last. Each TI is independently completable; no hidden cross-task dependencies beyond those stated.

### Implementation Tasks

- [ ] **TI01** Format gate green + CI step in place
  - Run `dart format packages apps`; verify `dart format --set-exit-if-changed packages apps` exits 0; ensure CI workflow runs the same command on every PR (add step if S10 hasn't already).
  - **Verify**: `dart format --set-exit-if-changed packages apps; echo $?` prints `0`; `rg -n 'dart format --set-exit-if-changed' .github/workflows/ dev/tools/` shows at least one CI invocation.

- [ ] **TI02** Pubspec dep alignment + drift asserter
  - Bump every `yaml` constraint to `^3.1.3` and every `path` constraint to `^1.9.1` across `packages/*/pubspec.yaml` and `apps/*/pubspec.yaml`. Add executable `dev/tools/check-deps.sh` that exits non-zero if any pubspec drifts from these baselines.
  - **Verify**: `rg "^\s*yaml:\s*\^?[0-9.]+" packages apps --no-heading | rg -v 'yaml: \^3\.1\.3'` returns zero matches; same for `path: \^1\.9\.1`. `bash dev/tools/check-deps.sh; echo $?` prints `0`; running it after a deliberate downgrade exits non-zero with the offending file path.

- [ ] **TI03** Production `catch (_)` sweep (HK-C) + workflow_executor broad-catch narrowing
  - Audit all 22 production `catch (_)` sites (`rg "catch \(_\)" packages apps --type dart -l` then iterate). Each gets `_log.fine(...)` (preferred when the exception carries diagnostic value) or a one-line rationale comment on the catch line. For `workflow_executor.dart` `_maybeCommitArtifacts`/`_cleanupWorkflowGit`/`_initializeWorkflowGit`: replace `catch (_)` with `on ProcessException catch (e)` (or `FileSystemException`) and re-raise unexpected types via `_failRun`.
  - **Verify**: `rg "catch \(_\)" packages apps --type dart` lists at most the audited sites, each with a sibling `_log.` call within ±1 line OR a comment containing `// silent:` or equivalent rationale on the same line; `dart analyze` clean.

- [ ] **TI04** Test `Future.delayed(Duration.zero)` → `pumpEventQueue()` (HK-D)
  - Mechanical replacement across `packages/**/test/`. Add `import 'package:test/test.dart' show pumpEventQueue;` where missing. Update `dev/guidelines/TESTING-STRATEGY.md` with a "When to use `pumpEventQueue`" section explaining the rationale (microtask-flushing semantics, intent-clarity).
  - **Verify**: `rg "Future\.delayed\(Duration\.zero\)" packages --type dart -g 'test/**'` returns zero; `rg -n 'pumpEventQueue' dev/guidelines/TESTING-STRATEGY.md` shows the new section.

- [ ] **TI05** Typed exceptions for 2 `throw Exception` sites (HK-E)
  - Add `ScheduleTurnFailureException` co-located with `schedule_service.dart`; replace `throw Exception('...')` at `:246`. Add `GitFetchException` co-located with `project_service_impl.dart`; replace at `:619`. Both extend `Exception`; both carry `String message` and `Object? cause`. Update any catchers — none expected, but `rg` to confirm.
  - **Verify**: `rg "throw Exception\('" packages/dartclaw_server/lib/src/scheduling/schedule_service.dart packages/dartclaw_server/lib/src/project/project_service_impl.dart` returns zero; `rg "ScheduleTurnFailureException|GitFetchException" packages` shows both class declarations + throw sites.

- [ ] **TI06** Super-parameters in claude/codex harness (HK-F) + `expandHome` tests (HK-G)
  - Convert constructors in `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart` and `codex_harness.dart` to `super.` parameters; delete the `// ignore: use_super_parameters` comments. Add `packages/dartclaw_security/test/path_utils_test.dart` covering `expandHome` for: `~/foo` with `HOME` set; `HOME` unset; `~` alone; `~/` prefix.
  - **Verify**: `rg "use_super_parameters" packages/dartclaw_core/lib/src/harness/` returns zero; `dart test packages/dartclaw_security/test/path_utils_test.dart` passes with ≥4 assertions; `dart analyze` clean.

- [ ] **TI07** R-L2 — Delete 13 `@Deprecated` shims; CHANGELOG breaking entry
  - Delete: `WorkflowRegistry.listBuiltIn()` alias; top-level `deliverResult()` (`scheduling/delivery.dart:221-256`); 7 `@Deprecated dynamic` ctor params on `ChannelManager` (`channel_manager.dart:49-55`); 3 `@Deprecated EventBus?` params on `SlashCommandHandler`/`taskRoutes`/`ScheduledTaskRunner`. Update test-only callers. Add CHANGELOG `0.16.5 - Unreleased` "Breaking changes" entry naming each removal. Excludes the TD-029 stretch's intentional new `@Deprecated`.
  - **Verify**: `rg "@Deprecated" packages/dartclaw_workflow/lib/src/workflow/workflow_registry.dart packages/dartclaw_server/lib/src/scheduling/delivery.dart packages/dartclaw_server/lib/src/channels/channel_manager.dart` returns zero matches for the named symbols; CHANGELOG `### Breaking changes` block names all 13; `dart analyze` clean.

- [ ] **TI08** R-L6 — `WorkflowStep.copyWith` + resolver migration
  - Add `WorkflowStep.copyWith({...})` covering every field; migrate `workflow_definition_resolver.dart:107-140` to use it. Optional: add a round-trip fitness test that constructs a `WorkflowStep`, copies it, and asserts field equality.
  - **Verify**: `rg "WorkflowStep\(" packages/dartclaw_workflow/lib/src/workflow/workflow_definition_resolver.dart` shows zero ~30-arg ctor calls (only `.copyWith(...)` calls); the optional round-trip test (if added) passes.

- [ ] **TI09** R-L1 — Step-outcome warning log on missing marker
  - At the `WorkflowExecutor` site that increments `workflow.outcome.fallback`: add `_log.warning('Step outcome marker missing: run=${run.id} step=${step.id}')` (or equivalent) before the increment. Cite ADR-022 in a one-line comment.
  - **Verify**: A unit test that runs a workflow step without `<step-outcome>` marker asserts both the WARNING log line and the counter increment fire.

- [ ] **TI10** R-M7 + R-M8 test consolidation
  - R-M7: Create `packages/dartclaw_workflow/test/workflow/_support/workflow_test_paths.dart` exposing `workflowFixturesRoot()`, `workflowDefinitionsDir()`, `codexAvailable()`, `findAncestorDir(List<String>)`. Replace the 12 inline copies. R-M8: Create `packages/dartclaw_testing/lib/src/harnesses/task_executor_test_harness.dart`; migrate `task_executor_test`, `retry_enforcement_test`, `budget_enforcement_test`. Add `dartclaw_testing` to `budget_enforcement_test`'s import chain if missing.
  - **Verify**: `rg "_fixturesRoot\(\)|_definitionsDir\(\)|_codexAvailable\(\)" packages/dartclaw_workflow/test` returns zero outside `_support/`; `dart test packages/dartclaw_workflow packages/dartclaw_server/test/task/` passes; `wc -l` on the 3 task-executor test files shows ≥40 lines reduced each.

- [ ] **TI11** TD-054, TD-055, TD-056 server-side cleanups
  - **TD-054**: Delete `_badgeVariantFromClass()` in `templates/settings.dart`; update `settings_page.dart` callers to pass `ChannelStatus` enum directly. **TD-055**: Extract the 5-field default record in `web_routes.dart`'s `_readSessionUsage` to a single file-private constant or one-shot helper; collapse 4 fallback branches to one. **TD-056**: Add `cleanupWorktree(WorktreeManager? mgr, TaskFileGuard? guard, String taskId, {Project? project})` under `packages/dartclaw_server/lib/src/task/`; replace the 3 near-identical impls in `task_routes.dart`, `project_routes.dart`, `task_review_service.dart`.
  - **Verify**: `rg "_badgeVariantFromClass" packages/dartclaw_server` returns zero; `wc -l` on `web_routes.dart` shows net reduction of ≥20 lines; `rg "_cleanupWorktree" packages/dartclaw_server/lib/src/{api,task}/` returns zero (only the shared `cleanupWorktree` symbol remains); `dart test packages/dartclaw_server` passes.

- [ ] **TI12** TD-060 dartclawVersion auto-sync (decision recorded)
  - Attempt path A: `dev/tools/sync-version.dart` regenerates `packages/dartclaw_server/lib/src/version.dart` from `packages/dartclaw_server/pubspec.yaml`; invoked by `dev/tools/build.sh`. If the script exceeds 30 LOC, fall back to path B: a release-checklist bullet in `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`. Record the chosen path in this FIS' Implementation Observations.
  - **Verify**: Either `dart run dev/tools/sync-version.dart` regenerates `version.dart` byte-identically against the current pubspec, AND `bash dev/tools/build.sh` invokes it before AOT compile; OR `KEY_DEVELOPMENT_COMMANDS.md` carries the bullet and Implementation Observations records the fallback.

- [ ] **TI13** TD-061 Codex stderr piping
  - In `codex_harness.dart`, attach `utf8.decoder.bind(process.stderr).transform(const LineSplitter())` to a listener that calls `_log.warning(line)` for each line (or `_log.fine` for benign lines matching a small allowlist; mirror `claude_code_harness.dart`'s pattern).
  - **Verify**: A unit test launching a stub Codex process whose stderr emits `Error: model 'invalid-model' not recognised` asserts a `LogRecord` at `Level.WARNING` with the message; existing codex harness tests stay green.

- [ ] **TI14** TD-073 externalArtifactMount collision + TD-085 SchemaValidator subset
  - **TD-073**: Add validator-time detection of duplicate `externalArtifactMount` destinations across reachable step pairs (scope by reachable-step-pair, not whole workflow); plus runtime fail-fast before overwrite. Add a regression test. **TD-085**: Either implement `pattern`/`minLength`/`maxLength`/`minItems`/`uniqueItems` (option a, with unit tests) OR add a load-time "supported subset" diagnostic rejecting unsupported keywords (option b). Record the choice in Implementation Observations.
  - **Verify**: TD-073 regression test asserts a workflow with 2 same-destination mounts fails at validation OR at runtime before overwrite; TD-085 test asserts an `oneOf` schema either validates correctly (option a) OR fails at load with a diagnostic naming `oneOf` and listing the supported subset (option b).

- [ ] **TI15** SP-1 + SP-2 SkillProvisioner hardening
  - **SP-1**: Add `_validateRef(String)` raising `SkillProvisionConfigException` if `^[A-Za-z0-9_./-]+$` does not match; call before each `git` subcommand using `config.ref`. Insert `--` between subcommand options and ref/URL arguments at `skill_provisioner.dart:307-334` (`_checkout`) and `:316-323` (`_resolveCachedRef`). **SP-2**: At provisioner startup, for each cached source, read `git config --get remote.origin.url` and compare against the configured `git_url`; fail fast on mismatch — regardless of `andthen.network: disabled`. Add an integration test for both paths (SP-1 injection regression; SP-2 cached-origin drift).
  - **Verify**: `rg "git checkout" packages/dartclaw_workflow/lib/src/workflow/skill_provisioner.dart | rg -v ' -- '` returns zero (every checkout uses `--`); SP-1 test asserts `SkillProvisionConfigException` raised for `ref: --upload-pack=…`; SP-2 test asserts startup-time failure when cached origin differs from config.

- [ ] **TI16** Delta-review consolidations (DR-M3, DR-M2, DR-L2)
  - **DR-M3**: Delete `FakeProcess` redeclarations across the 9 named test files; import canonical from `dartclaw_testing`; extend canonical helper with any missing knobs (`pid` override, `killResult`, claude-specific shape) where needed. **DR-M2**: Delete `resolveGitCredentialEnv` from `git_credential_env.dart:88-102`; remove from `task_exports.dart:12` `show` list; keep `resolveGitCredentialPlan` + `GitCredentialPlan`. **DR-L2**: Run `dart analyze --fatal-infos` (or LSP call-hierarchy) over `foreach_iteration_runner.dart`, `context_extractor.dart`, `workflow_executor_helpers.dart`, `task_executor.dart`, `workflow_cli_runner.dart`; delete every uncalled private method.
  - **Verify**: `rg "class\s+_?(?:Claude|Capturing)?FakeProcess(?!Runner)\s+implements\s+Process" packages apps` returns matches only in `packages/dartclaw_testing/lib/src/fake_process.dart`; `rg "resolveGitCredentialEnv" packages` returns zero; `dart analyze --fatal-infos` reports zero `unused_element` for the 5 named files.

- [ ] **TI17** S30 residue error-builder helpers + TD-069/090/089/086 triage decisions
  - Add `_err(type, message, {stepId, loopId})` / `_warn(...)` / `_refErr(stepId, message)` / `_contextErr(stepId, message)` helpers under `packages/dartclaw_workflow/lib/src/workflow/validation/` (private mixin or class extension). Migrate the 63 call sites. Record one-paragraph triage decisions in this FIS' Implementation Observations for: TD-069 H1/H2/M6/M11/M12/M13; TD-090 (preferred: validation-time rejection of multi-approval-emitting parallel peers); TD-089 (`WorkflowService` value objects in 0.16.5 stretch vs 0.17); TD-086 (duplicate-key policy, max-depth/max-bytes guard, parser-vs-validator home, gate-expression diagnostics) — implement mechanical pieces that fit, narrow others.
  - **Verify**: `rg "^\s+_err\(|^\s+_warn\(|^\s+_refErr\(|^\s+_contextErr\(" packages/dartclaw_workflow/lib/src/workflow/validation/ | wc -l` returns ≥63; Implementation Observations has one entry per advisory item (10 items minimum: 6 TD-069 sub-items + TD-090 + TD-089 + TD-086 + S30-residue note); `dev/state/TECH-DEBT-BACKLOG.md` is updated (entries deleted or narrowed).

- [ ] **TI18** TD-029 stretch + Bookkeeping (CHANGELOG + TECH-DEBT-BACKLOG + STATE.md acceptance of pre-existing failures)
  - **TD-029 (stretch, gated on capacity)**: Rework `templates/loader.dart` so the rendering path accepts an injected `TemplateLoaderService`; keep global `templateLoader` annotated `@Deprecated('use injected TemplateLoaderService')`. **Bookkeeping**: Append "Housekeeping & tech debt" block to CHANGELOG `0.16.5 - Unreleased` enumerating every closed item; ensure R-L2 entries appear under "Breaking changes". Delete resolved entries from `dev/state/TECH-DEBT-BACKLOG.md` (TD-029 if shipped, TD-054, TD-055, TD-056, TD-060, TD-061, TD-073, TD-085); narrow TD-069/090/089/086 to named residuals where applicable. **Pre-existing 15 failures**: re-run `dart test packages/dartclaw_workflow/test/workflow/built_in_workflow_contracts_test.dart` and the integration test; if any are mechanical, fix-forward; otherwise record formal acceptance with one-paragraph rationale in CHANGELOG / STATE.md.
  - **Verify**: CHANGELOG carries both blocks with each TD/TI named; `dev/state/TECH-DEBT-BACKLOG.md` no longer lists the resolved IDs; `dart test` workspace-wide either passes fully or matches the formally-accepted baseline; if TD-029 shipped, `rg "@Deprecated\('use injected TemplateLoaderService'\)" packages/dartclaw_server/lib/src/templates/loader.dart` matches.

### Testing Strategy

Derive test cases from Scenarios; tag with task ID(s) the test proves.

- [TI01] Format gate green after sweep → `dart format --set-exit-if-changed packages apps` exits 0; CI step present
- [TI02] Pubspec drift detector → `bash dev/tools/check-deps.sh` exits 0 on aligned tree, non-zero on deliberate downgrade
- [TI04] `pumpEventQueue` adoption → `rg "Future\.delayed\(Duration\.zero\)" packages --type dart -g 'test/**'` returns zero
- [TI05] Typed exceptions in place → `dart test` covers a path that raises `ScheduleTurnFailureException` and `GitFetchException` (use existing test or add a smoke test for each)
- [TI06] `expandHome` unit tests → 4 assertions (happy / env-missing / `~` alone / `~/` prefix) pass
- [TI07] R-L2 deletion regression → `dart analyze` workspace-wide clean; no test still calls deleted symbols
- [TI08] `WorkflowStep.copyWith` round-trip → optional fitness test asserting field equality across copy
- [TI09] R-L1 step-outcome warning → unit test asserts `LogRecord` at WARNING + counter increment
- [TI10] R-M7/R-M8 helpers in use → `rg` for inline-helper signatures returns zero outside `_support/` / `dartclaw_testing/`
- [TI11] TD-056 cleanupWorktree → existing tests for task lifecycle, project deletion, task review pass; the 3 `_cleanupWorktree` private impls are gone
- [TI13] TD-061 Codex stderr → unit test asserts WARNING log line on stub stderr emission
- [TI14] TD-073 collision → regression test asserts validation/runtime rejection of duplicate-mount workflow; TI14 TD-085 → test asserts diagnostic OR keyword impl
- [TI15] SP-1 injection regression → asserts `SkillProvisionConfigException` raised for crafted ref; SP-2 cache-drift → asserts startup-time failure on mismatched origin
- [TI16] DR-M3 consolidation → `rg` for `FakeProcess`-implementing classes returns canonical only; affected test files still pass
- [TI17] S30 residue helpers → all 63 call sites compile; existing validator unit tests stay green

### Validation

- Standard exec-spec validation (build/test/lint) covers most of this story.
- Feature-specific: rerun `bash dev/tools/release_check.sh --quick` after the sweep; the format + analyzer + test gates must all pass before bookkeeping (TI18).

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (file paths, regex `^[A-Za-z0-9_./-]+$`, line-number references, exception class names) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs (documentation lookup, build troubleshooting); spawn in background where possible.
- After all tasks: run `dart format --set-exit-if-changed packages apps`, `dart analyze --fatal-warnings --fatal-infos`, `dart test`, and `bash dev/tools/check-deps.sh`. Keep `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean for net-new code (pre-existing markers in untouched files are not in scope here).
- Mark task checkboxes immediately upon completion — do not batch.
- For the bundled triage decisions in TI17/TI18: append one Implementation Observations entry per decision item *during* execution, not after. Use AUTO_MODE conservative-default rules if running headless.

## Final Validation Checklist

- [ ] **All success criteria** met (housekeeping, review-driven, TD mop-up, SP, delta-review, triage, test-suite acceptance)
- [ ] **All 18 tasks** fully completed, verified, and checkboxes checked
- [ ] **No regressions** beyond the documented R-L2 breaking deletions
- [ ] **CHANGELOG** carries the "Housekeeping & tech debt" block and (separately) the R-L2 "Breaking changes" entries
- [ ] **TECH-DEBT-BACKLOG.md** is up-to-date per "Open items only" policy
- [ ] **Implementation Observations** records: TD-060 path choice, TD-085 path choice, TD-069 (6 sub-items), TD-090, TD-089, TD-086 decisions, plus any pre-existing-failure formal-acceptance rationale

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only. Tag semantics: see [`data-contract.md`](${CLAUDE_PLUGIN_ROOT}/references/data-contract.md) (FIS Mutability Contract, tag definitions). AUTO_MODE assumption-recording: see [`automation-mode.md`](${CLAUDE_PLUGIN_ROOT}/references/automation-mode.md). Spec authors: leave this section empty._

_No observations recorded yet._

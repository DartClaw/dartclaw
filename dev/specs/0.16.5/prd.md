# Product Requirements Document: DartClaw 0.16.5 — Stabilisation & Hardening

> **Context**: This PRD and [`plan.md`](./plan.md) are the implementation source of truth for 0.16.5. Provenance: findings trace to the 2026-04-17 unified architecture/docs/refactor/dead-code reviews, the 2026-04-21 delta architecture/refactor/Effective Dart/readability reviews, the 2026-04-30 PRD/plan doc-review, the 2026-04-30 deeper `dartclaw_workflow` red-team review, and the missing-file workflow package architecture follow-up — all consolidated into this PRD/plan and the `0.16.4 consolidated review` (spec history in private repo: `docs/specs/0.16.4/0.16.4-consolidated-review.md`). The ID glossary for `Asset refs` citations lives in `plan.md` "Source Reviews & Finding ID Conventions". The 0.16.4 final workflow remediation follow-up (2026-04-30) absorbs its workflow/task-boundary carry-overs (TD-070) into existing S15/S31/S34 scope (executor LOC closure is conditional on S15's decomposition outcome — see plan S15 AC); AndThen source-authenticity pinning stays out of 0.16.5 as pre-production hardening because AndThen is currently first-party and may later be forked/vendor-owned by DartClaw.
> **Related Assets**: 0.16.4 plan (private repo: `docs/specs/0.16.4/plan.md`) · 0.16.6 (next) — Web UI Stimulus Adoption (private repo: `docs/specs/0.16.6/prd.md`) · ADR-008 — SDK publishing strategy (see "Inline Reference Summaries" appendix below; full rationale in private repo `docs/adrs/008-sdk-publishing-strategy.md`) · [Tech Debt Backlog](../../state/TECH-DEBT-BACKLOG.md) · Architecture deep-dives (system / workflow / security) live in private repo `docs/architecture/` · [Ubiquitous language](../../state/UBIQUITOUS_LANGUAGE.md)
>
> **2026-04-30 baseline-overlap audit**: After 0.16.4 closed, an audit of this PRD vs the actually-shipped state retired **S30** (validator already split by 0.16.4 S44; current `workflow_definition_validator.dart` = 136 LOC, six rule files in `validation/`) and re-scoped **S15 / S16**. The original `workflow_executor.dart` and `task_executor.dart` ≤1,500 LOC targets are **already met** by 0.16.4 S45/S46: current `workflow_executor.dart` = 844 LOC, `task_executor.dart` = 790 LOC. The remaining over-threshold files are `config_parser.dart` (1,648 LOC; S13) and `foreach_iteration_runner.dart` (1,624 LOC; S15); adjacent complexity hotspots are `context_extractor.dart` (960 LOC) and `workflow_executor_helpers.dart` (773 LOC), also handled by S15. S16 narrows to constructor-parameter reduction (still ~28 named params) and `_workflowSharedWorktrees*` map removal (the latter via S33's coordinator). **TD-052** is effectively closed by 0.16.4 S46 and is removed from the backlog at sprint close. **TD-059** (already marked Resolved-by-S42 inside its own entry) is also deleted. The audit also folds **TD-046** (kill/restart e2e crash-recovery test) into S25, **TD-069** (six 0.16.4 advisory DECIDE items) into S23 as triage decisions, and **TD-072** doc residuals into S03 (item 2 glossary) and S29 (item 1 standalone bootstrap). A same-day tech-debt triage pass folds the directly actionable fresh backlog into this milestone instead of leaving it as open-ended debt: TD-073 and TD-085 into S23, TD-074 into S25/release closeout, TD-082 and TD-088 into S15, and the mechanical parser-coercion slice of TD-086 into S13; TD-089/TD-090/TD-086 residuals require explicit 0.16.5 decisions. Current scope below reflects this audit; pre-audit LOC figures are retained only as historical evidence.
>
> **2026-05-04 post-tag reconciliation** (after `v0.16.4` was tagged on `main` 2026-05-04): a follow-up audit against the as-shipped public repo found additional 0.16.5-PRD assumptions had already been satisfied during 0.16.4 release prep, and that some baselines had drifted in flight. Adjustments folded into the existing scope without adding new stories:
>   - **S03 doc-currency scope reduced** — `AGENTS.md` already mirrors `CLAUDE.md` post-0.16.4 (multi-harness Claude+Codex language present, no `0.9 Phase A` / `Bun standalone` residue, all 12 packages listed). Remaining S03(a) work is the **explicit "Current milestone: 0.16.5" line** plus the **"AGENTS.md is standard for ALL non-Claude-Code agents" assertion**. **README banner v0.16.4 already shipped** — S03(b) is essentially complete (verify wording matches FR7). Remaining S03 surface is unchanged: the four guide fixes (Deno worker, `agent.claude_executable`, WhatsApp port, customization Guard example), `architecture.md` "eleven packages" → "twelve", and the three `UBIQUITOUS_LANGUAGE.md` drift items.
>   - **TD-063 already closed** (FR3 acceptance criterion partially met) — `dartclaw_testing/pubspec.yaml` no longer declares `dartclaw_server` (only `dartclaw_core`). The remaining FR3 work is the actual interface extraction (`TurnManager`, `TurnRunner`, `HarnessPool`, `GoogleJwtVerifier`) into `dartclaw_core` plus the `WorkflowRunRepository`/`ProcessEnvironmentPlan`/`WorkflowTaskBindingCoordinator` promotions. Delete TD-063 at sprint close (alongside TD-052/TD-059) as 0.16.4-closure backlog hygiene.
>   - **S33 partially landed in 0.16.4** — concrete `WorkflowWorktreeBinder` class already extracted to `packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart`; `TaskExecutor` no longer holds the three shared-worktree maps directly (delegates to `_worktreeBinder`). Remaining S33 scope narrows to: **abstract interface in `dartclaw_core`**, **fake in `dartclaw_testing`**, and the redundant `workflowRunId` callback parameter cleanup. Risk drops from Medium → Low.
>   - **S12 partially landed in 0.16.4** — a `WorkflowRunRepositoryPort` exists in `packages/dartclaw_workflow/lib/src/workflow/workflow_runner_types.dart` but is a `dynamic`-wrapped wrapper, not a proper abstract interface, and lives in the wrong package. Remaining S12 scope: **promote to `dartclaw_core`**, replace the `dynamic` delegate with a typed abstract interface, migrate `TaskExecutor` (still types ctor field as concrete `SqliteWorkflowRunRepository?` at `task_executor.dart:113`) and the two call sites at `task_executor.dart:127,1438`.
>   - **WorkflowGitPort extraction already shipped** — STATE.md confirms `WorkflowGitPort extraction is closed.` Files: `workflow_git_port.dart` (124 LOC) in `dartclaw_workflow` + `workflow_git_port_process.dart` (237 LOC) in `dartclaw_server`. No additional 0.16.5 work needed here; the TD-070 carry-over note that S15 acts on is the executor LOC reduction, not the git-port extraction.
>   - **Stale baselines refreshed for success-metrics table**:
>     - `dart format` drifted files: 11 → **0-1** (essentially clean)
>     - `dartclaw_models` baseline: 3,005 LOC → **3,555 LOC** (grew during 0.16.4 — `workflow_definition.dart` alone is 1,349 LOC; ≤1,200 LOC target unchanged but migration scope is larger)
>     - `dartclaw_workflow` wholesale `export 'src/...'`: 26 → **34** (target ≤35 with `show` clauses still applies; allowlist baseline shifts)
>     - `cli_workflow_wiring.dart`: "350-LOC twin" → **945 LOC** (grew during 0.16.4 — S17 effort doubles)
>     - `context_extractor.dart`: 960 LOC → **1,414 LOC** (grew during 0.16.4 — folded into S15's hotspot list, target ≤600 LOC unchanged but reduction is larger; also raises priority of TD-088 / TD-082 closures riding S15)
>   - **TD-099/100/101 plan reference is stale** — these IDs were restructured during 0.16.4 release prep into the surviving **TD-102** (`dartclaw_core/lib/` 12,437 LOC vs 12,000 ratchet; ceiling temporarily raised to 13,000) and **TD-103** (server-side `_workflow*` typed accessor). TD-101 (workflow-refs allowlist drift) was resolved inside the 0.16.4 release-prep window. **TD-102 attractor**: S22 (model migration is the natural place to move non-primitive material out of `dartclaw_core` to drive the ceiling back below 12,000). **TD-103 attractor**: S34 Part D (workflow task-config typed accessors — already enumerates the same `_workflow*` keys; add `_workflowNeedsWorktree` to the typed surface and migrate the two server reads at `task_config_view.dart:52,54` + `workflow_one_shot_runner.dart:77`).

## Key Definitions

| Term | Definition |
|------|------------|
| **Release floor** | The non-negotiable minimum required to tag 0.16.5: Blocks A+B (S01, S02, S03, S05, S09, S10, S27, S28, S29, S37). These are the only rows in the success-metrics table that use the `Release floor` gate. |
| **Planned target** | Work planned for the 0.16.5 stabilisation milestone but not part of the release floor. Planned-target work should ship in 0.16.5 when capacity allows; if it slips, it moves forward to 0.16.6 or later by explicit scope decision. |
| **Slip candidate** | A planned-target story pre-approved as low enough risk to move forward under scope pressure. For this PRD, only S35, S36, and S38 are slip candidates. S32, S33, and S34 are not slip candidates because they unblock structural stories. |
| **MVP boundary** | The release-floor boundary for this stabilisation milestone, not a separate product MVP. It answers "what blocks the 0.16.5 tag?" rather than "what is the full 0.16.5 plan?" |
| **Must / P0** | Story priority language meaning "required for the planned 0.16.5 scope." It does not override the release-floor/planned-target/slip-candidate gate on success metrics. |
| **Orphan emitted sealed event** | A `DartclawEvent` subtype emitted by production code with no production listener, alert route, SSE formatter, metrics subscriber, or documented `NOT_ALERTABLE` justification. |
| **Production listener** | A runtime consumer that handles an event outside tests, such as alert routing, SSE delivery, a direct service subscriber, or metrics instrumentation. Test-only subscribers do not count. |
| **Level-1 governance check** | A fast every-commit guard: six fitness test files plus the workspace `dart format --set-exit-if-changed` gate. Target runtime is <=30 seconds. |
| **Level-2 fitness function** | A slower every-PR governance test that checks cross-package or cross-consumer architecture constraints. Target runtime is 1-5 minutes for the suite. |
| **Soft re-export** | A temporary compatibility export from the old package location after a type moves. It should be documented, deprecated when appropriate, and removed in a later breaking-change window. |
| **Public top-level type** | A non-private class, enum, extension, typedef, or mixin visible from a package's public `lib/` API surface, including declarations re-exported through barrels. |

## Executive Summary

- **Problem**: 22 milestones after MVP, the codebase is functionally healthy (`dart analyze` clean, zero production TODOs, no package cycles) but has accumulated drift: one Critical safety gap in alert classification, 7 sealed events emitted with no listener, remaining execution/config hotspots after the 0.16.4 executor splits, one package with 34 wholesale un-narrowed barrel exports, a test-package boundary that still needs stable interfaces even though its direct server dependency was removed in 0.16.4, a 3,555 LOC "shared kernel" models package, and SDK docs still pitching an unpublished "0.9.0 imminent release" while the code sits at 0.16.4. Historical doc-currency findings around `AGENTS.md` and the README banner have mostly been satisfied by 0.16.4 release prep; the remaining 0.16.5 scope is the narrower additive S03/S19 doc-currency pass captured below. The 2026-04-21 delta review added: cross-package `ProcessEnvironmentPlan` duplication introduced by the Archon hardening work, `TaskExecutor` leaking concrete sqlite repo type (ADX-01), 100 LOC of byte-identical Claude-settings helpers already drifted between the harness and the workflow CLI runner, post-plan-lock workflow complexity that now lives in the foreach/context/helper successor files, if-is ladders on `sealed DartclawEvent` that should be compiler-exhaustive switches, stringly-typed workflow flags, `k`-prefix public constants, and 26 undocumented public types in `dartclaw_server`. Without a consolidation sprint, these issues compound and block a clean 1.0 boundary.
- **Vision**: Ship a stabilisation release that closes the safety finding, wires every orphan event, reduces the remaining post-0.16.4 execution/config hotspots along their natural seams, formalises barrel discipline and test/server boundaries, extracts turn/pool/harness interfaces into `dartclaw_core` (plus `ProcessEnvironmentPlan` promotion and a `WorkflowTaskBindingCoordinator` seam from the delta review), extracts a shared `ClaudeSettingsBuilder`, relocates domain models out of `dartclaw_models`, flips `public_member_api_docs` on in the four near-clean packages, introduces enums for stringly-typed workflow flags, renames `k`-prefix constants and `get*` methods per Effective Dart, installs 13 governance checks in CI (6 Level-1 fitness test files + 1 Level-1 format gate + 6 Level-2 fitness test files) to prevent recurrence, and brings every user-facing document in line with 0.16.x reality. Zero new user-facing features.
- **Target Users**:
  - **Operators**: get alerts for safety events they previously missed (`LoopDetectedEvent`, `EmergencyStopEvent`).
  - **Non-Claude-Code agents (Codex, future harnesses)**: read an `AGENTS.md` that stays aligned with current multi-harness reality and the 0.16.5 milestone callouts.
  - **SDK consumers**: see honest placeholder framing in `docs/sdk/` instead of "0.9.0 imminent".
  - **Contributors & future maintainers**: work in a codebase where the remaining over-threshold files have explicit shrink targets, public API is intentionally narrowed, and CI guards against drift re-accumulation.
- **Success Metrics**:

| Metric | Target | Gate |
|---|---|---|
| Critical safety findings open | **0** (from 1) | Release floor |
| Orphan emitted sealed events (emitted, zero production listeners) | **0** (from 7) | Release floor |
| Wholesale `export 'src/...'` barrel statements | **0** (from 34 in `dartclaw_workflow` &Dagger;) | Release floor |
| Files in `lib/src/**` over 1,500 LOC &dagger; | **0** (from 2 current post-audit files: `config_parser.dart`, `foreach_iteration_runner.dart`) | Planned target |
| `dartclaw_testing → dartclaw_server` library edge | **removed** (already met by 0.16.4; verify at closeout) | Planned target |
| `TaskExecutor` concrete `SqliteWorkflowRunRepository` dep | **removed** (via abstract interface) | Planned target |
| Cross-package `ProcessEnvironmentPlan` duplicates | **0** (from 3) | Planned target |
| Claude-settings helper duplication (`claude_code_harness` ↔ `workflow_cli_runner`) | **removed** (single `ClaudeSettingsBuilder` source) | Planned target |
| Public doc Critical findings open | **0** (from 3) | Release floor |
| Level-1 governance checks in CI | **7** (6 fitness test files + format gate) | Release floor |
| Level-2 fitness functions in CI | **6** (from 4 originally planned) | Planned target |
| `dartclaw_models` scope | **≤1,200 LOC** (from 3,555 &Dagger;) | Planned target |
| Undocumented public top-level types in `dartclaw_server/lib/` | **0** (from 26) | Release floor |
| Packages with `public_member_api_docs` lint enabled | **4** (`dartclaw_models`, `_storage`, `_security`, `_config`) | Release floor |
| Stringly-typed public workflow flags | **0** (from 4) — replaced by enums | Slip candidate |
| Public `k`-prefix constants + `get*` methods on services | **0** (from 16) — batched with S22 break | Slip candidate |
| Analyzer warnings / errors | **0** (maintained) | Release floor |
| Format drift (`dart format --set-exit-if-changed`) | **0 files** (from 0-1 &Dagger;) | Release floor |
| Workspace-wide test suite (`dart test`) | **green per wave** | Release floor |
| Tech-debt items closed by 0.16.5 stories (public `dev/state/TECH-DEBT-BACKLOG.md`) | **≥17** (TD-046 in S25, TD-053 in S22/FR5, TD-054/055/056/060/061/069/073/085 in S23, TD-063 in S11/FR3 — already-met-by-0.16.4 cleanup, TD-072 split S03/S29, TD-074 in S25 release closeout, TD-082/088 in S15, **TD-102 in S22, TD-103 in S34 Part D — absorbed 2026-05-04**). _Earlier "TD-099/100/101 pending triage" referenced in prior plan revisions has been resolved: those IDs were restructured during 0.16.4 release prep into the surviving TD-102/TD-103 listed above (TD-101 was resolved within the 0.16.4 window)._ | Planned target |
| Tech-debt items narrowed by explicit 0.16.5 decision | **≥3** (TD-086 mechanical parser-coercion slice closed in S13, semantic residuals narrowed; TD-089 triage decision in S16/S23; TD-090 triage decision in S23) | Planned target |
| Tech-debt items deleted at sprint close as 0.16.4-closure backlog hygiene (NOT counted toward 0.16.5 closure) | **2** (TD-052 already closed by 0.16.4 S46; TD-059 already marked Resolved by 0.16.4 S42 in its own entry) | Planned target |
| Tech-debt items closed (stretch) | **+1 if TD-029 lands** (TemplateLoaderService seam, P2 in S23) | Stretch |
| New user guide pages (gap-fill) | **2 of 5 candidates** | Stretch |

&dagger; Pre-audit historical baseline (wc -l): `workflow_executor.dart` (3,855), `task_executor.dart` (1,787), `config_parser.dart` (1,551). Current post-0.16.4 ground truth: `workflow_executor.dart` (891) and `task_executor.dart` (790) are already below threshold; `config_parser.dart` and `foreach_iteration_runner.dart` remain over 1,500 LOC and are the active shrink targets.

&Dagger; Refreshed 2026-05-04 against tagged `v0.16.4`: original PRD baselines drifted in flight as 0.16.4 absorbed Workflow Execution + Archon hardening + AgentExecution decomposition; figures above reflect actual on-`main` state at sprint start. Notably `dartclaw_models` *grew* (3,005 → 3,555 LOC) rather than shrinking, raising S22's migration surface; `cli_workflow_wiring.dart` doubled (350 → 945 LOC), raising S17's effort; `dartclaw_workflow` wholesale exports went from 26 → 34 as new internal types were added inline; `context_extractor.dart` grew (960 → 1,414 LOC), raising S15's reduction target. All target columns unchanged.

## Problem Definition

### Problem Statement

Quality drift has accumulated in the public DartClaw codebase across four measurable dimensions:

1. **Safety**: `AlertClassifier.classifyAlert` covers 7 event types but silently ignores two safety-relevant events, and 7 sealed events overall are emitted with zero production listeners. Operators relying on alert routing are blind to loop-detection and emergency-stop signals.
2. **Structure**: The original `workflow_executor.dart` and `task_executor.dart` file-size findings were closed by 0.16.4, but the complexity surface moved rather than disappeared. Current over-threshold files are `config_parser.dart` and `foreach_iteration_runner.dart`; adjacent execution hotspots (`context_extractor.dart`, `workflow_executor_helpers.dart`), `service_wiring.dart#wire()`, and `server.dart`'s 60+ required ctor fields still make review noisy and merge conflicts likely.
3. **Boundaries**: The `dartclaw_workflow` barrel leaks 34 wholesale `export 'src/...'` lines (every internal type is public API by accident). `canvas_exports.dart` re-exports 11 advisor internals that nothing consumes. `dartclaw_testing` no longer declares `dartclaw_server` directly, but still needs stable test-facing interfaces extracted from server-owned implementations. `dartclaw_models` has grown to 3,555 LOC by absorbing workflow/project/task-event/turn-trace/skill-info models.
4. **Currency**: 0.16.4 release prep already brought `AGENTS.md` and the README banner mostly current; remaining 0.16.5 currency work is additive and verification-oriented: the explicit 0.16.5 milestone line, the non-Claude-agent instruction-file assertion, four guide fixes, package-tree count cleanup, SDK placeholder framing, recipe key drift, and `UBIQUITOUS_LANGUAGE.md` terminology fixes.

Failure mode if nothing changes: next milestone's feature work lands in the same hotspots, the 0.16.5/0.16.6 line continues without a clean 1.0 boundary, non-Claude agents receive systematically wrong project context, and the next safety-relevant event added will likely repeat the orphan-wiring pattern.

### Evidence & Context

- Four parallel reviews (architecture, documentation, refactor/quality, dead-code) conducted 2026-04-17 converged on the same hotspots (`workflow_executor.dart` flagged by all three code-review paths; `AGENTS.md` drift flagged independently by doc and dead-code reviews).
- `dart analyze` is clean, zero production TODOs, strict-casts + strict-raw-types on. This is *not* a defect-repair sprint — the codebase passes every tool the Dart community knows about. The findings come from human-eye review of structure, boundaries, and currency.
- Prerequisite 0.16.4 (CLI Operations & Connected Workflows) closed all 81 stories (72 catalogued in `0.16.4/plan.md` + 9 in the `agent-resolved-merge/` sub-plan) by the 2026-04-30 pre-tag pass; the original 2026-04-15 plan-lock at 13 stories grew in flight as Workflow Execution, Archon-Informed Hardening, AgentExecution Decomposition, and the late control-flow correctness hotfix (S78) were folded in. Current phase in public `dev/state/STATE.md` is planning for 0.16.5.
- Sequencing: 0.16.5 (stabilisation) must complete before 0.16.6 (Web UI Stimulus Adoption) so the Stimulus work builds on a clean structural baseline.

## Scope

### In Scope

**Code**
- Safety fix for alert classification of `LoopDetectedEvent`, `EmergencyStopEvent` — via exhaustive `switch` expression on `sealed DartclawEvent` (compiler-enforced, replaces the originally-planned custom runtime exhaustiveness test)
- SSE wiring + alert mapping for all 7 orphan sealed events (`AdvisorInsightEvent`, `LoopDetectedEvent`, `EmergencyStopEvent`, `TaskReviewReadyEvent`, `CompactionStartingEvent`, `MapIterationCompletedEvent`, `MapStepCompletedEvent`)
- Barrel narrowing of `dartclaw_workflow` (≤35 curated exports with `show` clauses)
- Removal of `canvas_exports.dart` advisor re-export block (11 orphan exports)
- Interface extraction of `TurnManager`, `TurnRunner`, `HarnessPool`, `GoogleJwtVerifier` to `dartclaw_core`; removal of `dartclaw_testing → dartclaw_server` edge
- `WorkflowRunRepository` interface added to `dartclaw_core` — **extended scope**: `TaskExecutor` also migrates off the concrete `SqliteWorkflowRunRepository` type (delta-review ADX-01)
- **Promotion of `InlineProcessEnvironmentPlan` + `ProcessEnvironmentPlan.empty` to `dartclaw_security`** — eliminates 3 cross-package duplicates (`_InlineProcessEnvironmentPlan` × 2 in server; `_EmptyProcessEnvironmentPlan` in workflow executor)
- **`WorkflowTaskBindingCoordinator` extraction** — lifts the workflow-shared-worktree registry + hydrate callback out of `TaskExecutor`; unblocks S16 decomposition
- **`ClaudeSettingsBuilder` extraction to `dartclaw_core`** — collapses 100 LOC of byte-identical helpers duplicated between `claude_code_harness.dart` and `workflow_cli_runner.dart`; aligns token-parser helpers on `intValue` / `stringValue`; shared `normalizeDynamicMap` utility
- **Workflow task-config typed accessors/constants** — centralise `_workflow*` / `_dartclaw.internal.*` task-config keys used across workflow/server boundaries so no new underscored workflow task-config key is added without a typed surface
- DRY helpers pre-decomposition: `mergeContextPreservingPrivate`, `fireStepCompleted`, promoted `truncate()` in `dartclaw_core`
- `YamlTypeSafeReader` helpers in `dartclaw_config`; convert 51 inline type-warning sites; apply the same typed-coercion pattern to the workflow YAML parser's raw `TypeError` / `ArgumentError` paths where mechanical
- `foreach_iteration_runner.dart`, `context_extractor.dart`, and `workflow_executor_helpers.dart` reduction after the 0.16.4 workflow-executor split; preserve the existing dispatcher/node-runner architecture
- Workflow iteration/runtime correctness closures that naturally ride the decomposition: map/foreach resume-cursor recovery (TD-088) and `_waitForTaskCompletion` early-completion race removal (TD-082)
- Task-executor residual cleanup after the 0.16.4 split: constructor dep-grouping, `_markFailedOrRetry` unification if any duplicates remain, and workflow-shared-worktree map removal via S33
- Split `service_wiring.dart#wire()` and **`cli_workflow_wiring.dart#wire()`** (350-LOC twin) per subsystem
- Collapse `DartclawServer.compose()` into builder; 60+ fields → 6 dep-group structs
- Migration of workflow/project/task-event/turn-trace/skill-info models out of `dartclaw_models` to their owning packages
- **Enum conversion of 4 stringly-typed public workflow flags** (`WorkflowStep.type → taskType: WorkflowTaskType`, `WorkflowGitWorktreeStrategy.mode`, `WorkflowGitExternalArtifactMount.mode`, `identifierPreservation`) — JSON wire format unchanged
- **Public API naming batch** (`k`-prefix drop × 6 constants, `get*` rename × 10 methods) batched with S22 migration for one coherent CHANGELOG break
- **Dartdoc sweep for `dartclaw_server`** (26 undocumented public types) + **`public_member_api_docs` lint flip** in 4 near-clean packages
- **Readability pack**: `_logRun` helper + severity drop for workflow executor per-step progression; typed `Task.worktree` helper; dir-naming conventions documented; `TaskExecutorLimits` record
- `externalArtifactMount` collision validation/runtime fail-fast (TD-073), `SchemaValidator` unsupported-keyword diagnostics or implementation (TD-085), and Homebrew/archive asset revalidation before release (TD-074)
- Housekeeping sweep (format, pubspec align, `catch (_)` audit, `Future.delayed → pumpEventQueue`, typed exceptions, super-parameters, `expandHome` tests, **9 `FakeProcess`-style redeclarations consolidated**, **`resolveGitCredentialEnv` dead wrapper deleted**, **dead-private-method sweep on rapid-churn files**)
- `SidebarDataBuilder` extraction in `web_routes.dart`
- 13 governance checks in CI (6 Level-1 fitness test files + format gate, 6 Level-2 fitness test files) — **up from 10 checks**: adds `no_cross_package_env_plan_duplicates`, `safe_process_usage`, `enum_exhaustive_consumer`, `max_method_count_per_file`

**Documentation (public repo)**
- Add the remaining `AGENTS.md` post-0.16.4 assertions: explicit "Current milestone: 0.16.5" line and "AGENTS.md is standard for ALL non-Claude-Code agents"
- Verify `README.md` already carries the v0.16.4 banner and refresh surrounding description only if wording still conflicts with FR7
- Package trees updated in README + `architecture.md` (add `dartclaw_workflow`, `dartclaw_testing`, `dartclaw_config`; bump "eleven packages" → "twelve")
- Four high-user-impact fixes (Deno worker, `agent.claude_executable`, WhatsApp port, Guard API example)
- `CHANGELOG.md` 0.16.4 entry corrections (skill count 14, removed 0.16.1 workflow packs)
- SDK 0.9.0 framing → `0.0.1-dev.1` placeholder acknowledgement with ADR-008 reference
- `configuration.md` schema sync (scheduling, `channels.google_chat`, env-vars, recipe key replacement)
- Per-package README expansion (`dartclaw_workflow`, `dartclaw_config`); refresh `apps/dartclaw_cli/README.md` command list

### Out of Scope

- **New user-facing features.** No new CLI commands, channels, workflow step types, or MCP tools.
- **Breaking protocol changes.** JSONL control protocol, REST API payload shapes, SSE envelope formats unchanged.
- **Config-section read-only interfaces** (SAP pass against `dartclaw_config` Zone-of-Pain). Large cascade-recompile scope; defer to dedicated FIS in a later sprint.
- **Further god-file splits**: `WorkflowDefinitionValidator` (1,239 LOC, cohesive), `AdvisorSubscriber` per-trigger split (824 LOC), `ClaudeCodeHarness` framing/lifecycle split (1,108 LOC). Deliver opportunistically with feature work.
- **Full `WorkflowCliRunner` harness-dispatched refactor**. Tied to eventual plugin/provider expansion. 0.16.5 still records the ownership/seam decision via S31/S34; it does not move workflow one-shot execution onto the normal harness-pool turn path.
- **AndThen source-authenticity pinning / signature verification.** Current 0.16.4 remediation already validates URL shape and closes git argument-injection risk. Because AndThen is first-party and may later be forked/vendor-owned by DartClaw, immutable SHA/signature enforcement is pre-production hardening rather than a 0.16.5 stabilisation requirement.
- **Google Chat outbound attachments implementation**. Ship decision: switch log-and-drop to a hard error now; implement later.
- **Pub.dev real-release publish.** Depends on public-repo-open decision.
- **Private-repo cleanups beyond pre-sprint doc currency fixes.** Other private-repo work tracked separately.

### MVP Boundary

The release floor is Blocks A + B (Safety, Quick Wins, Governance Rails) — **10 stories** (S01, S02, S03, S05, S09, S10, S27, S28, S29, S37). The project is not releasable without them. The remaining Blocks C–G (**19 planned-target stories** including delta-review adds S32/S33/S34/S35/S36/S38; S30 retired 2026-04-30) are the consolidation bulk; they should ship in 0.16.5, but planned-target work can move forward to 0.16.6 by explicit scope decision if capacity forces it. Block H (stretch new docs) is explicitly skippable.

**Scope-size exception**: 29 planned-target stories (Block A+B 10 + Block C–F 12 + Block G 7) exceeds the 10–14/milestone retro guidance; stabilisation releases warrant an exception. Three planned composite FIS groupings (doc currency, DRY helpers, doc closeout) were consolidated into single stories on 2026-04-21 to align with the 1:1 story↔FIS invariant enforced by `dartclaw-plan` — see plan.md §Story Consolidation Note. If execution capacity becomes the blocker, the three lowest-urgency delta-review adds (S35 enums, S36 naming batch, S38 readability pack) are the pre-approved slip candidates for 0.16.6, not a patch release; they don't block 0.16.6's Stimulus adoption. S32/S33/S34 are structural prerequisites and NOT slip candidates.

## Functional Requirements

### User Stories

Stabilisation sprint stories are framed from engineering and operational perspectives:

| ID | Story | Acceptance Criteria | Priority |
|----|-------|---------------------|----------|
| US01 | As an operator, I want an alert when the loop detector or emergency stop fires, so I know the runtime caught a safety signal. | Alert is routed to the configured alert target with critical severity for both event types. | Must / P0 |
| US02 | As a developer wiring a new sealed event, I want CI to fail if I forget to classify it, so orphan events can't accumulate. | Fitness test iterates every `DartclawEvent` subtype and fails if any is unclassified and lacks a `NOT_ALERTABLE` annotation. | Must / P0 |
| US03 | As a non-Claude-Code agent (Codex, ...), I want `AGENTS.md` to describe the current architecture, so my context is accurate. | `AGENTS.md` matches `CLAUDE.md` in scope and currency; says "Current milestone: 0.16.5" and mentions multi-harness model. | Must / P0 |
| US04 | As a contributor reviewing a PR, I want the remaining post-audit `lib/src/**/*.dart` hotspots under control so diffs are tractable. | `config_parser.dart` and `foreach_iteration_runner.dart` are under 1,500 LOC; `context_extractor.dart` and `workflow_executor_helpers.dart` meet their plan targets; `max_file_loc_test.dart` enforces the hard ceiling. | Must / P0 |
| US05 | As a package consumer, I want `dartclaw_workflow`'s public API to be intentional, so renames don't break me unexpectedly. | Barrel has ≤35 exports, every `export 'src/...'` uses `show`; fitness function enforces. | Must / P0 |
| US06 | As a test author using `dartclaw_testing`, I want its deps to be stable (core/models/security only), so test-helper updates don't pull in server churn. | `dartclaw_testing/pubspec.yaml` no longer lists `dartclaw_server`; fitness function enforces. | Must / P0 |
| US07 | As an SDK-curious developer, I want `docs/sdk/` to describe real pub.dev state, so I don't chase a "0.9.0 imminent" narrative for months. | `docs/sdk/quick-start.md` and `packages.md` describe the `0.0.1-dev.1` placeholder state with ADR-008 reference. | Must / P0 |
| US08 | As a new contributor scanning the codebase, I want models in `dartclaw_models` to be cross-cutting types only, so I can find workflow types in `dartclaw_workflow`. | `dartclaw_models` ≤1,200 LOC; workflow/project/task-event/turn-trace/skill-info moved to owning packages. | Must / P1 |
| US09 | As a user following a recipe, I want config keys to match the current parser, so my YAML doesn't produce deprecation warnings. | All recipes + `examples/personal-assistant.yaml` use `memory.max_bytes` (not deprecated `memory_max_bytes`). | Must / P0 |
| US10 | As a dashboard viewer, I want workflow map-iteration and step-completion events visible in real time, so progress is observable. | `MapIterationCompletedEvent` + `MapStepCompletedEvent` routed through SSE in `workflow_routes.dart` mirroring sibling events. | Must / P0 |

### Feature Specifications

#### FR1: Safety & Observability Completeness

**Description**: Every sealed `DartclawEvent` subtype must either be classified by `AlertClassifier` or carry an explicit `NOT_ALERTABLE: reason` annotation, and every event emitted in production must have at least one consumer (alert routing, SSE, direct handler, or metrics subscriber).

**Acceptance Criteria**:
- [ ] `AlertClassifier.classifyAlert` handles `LoopDetectedEvent` (critical) and `EmergencyStopEvent` (critical)
- [ ] `AlertClassifier` + `AlertFormatter` use exhaustive `switch (event)` expressions — compiler enforces coverage of every `sealed DartclawEvent` subtype (no runtime exhaustiveness test needed)
- [ ] All 7 orphan events wired: `EmergencyStopEvent`, `LoopDetectedEvent`, `TaskReviewReadyEvent`, `AdvisorInsightEvent` (SSE + warn/critical on `status: stuck|concerning`), `CompactionStartingEvent`, `MapIterationCompletedEvent`, `MapStepCompletedEvent`
- [ ] Any new `DartclawEvent` subtype without coverage fails `dart analyze` (compile-time, not runtime)

**Error Handling**: Unclassified event causes a non-exhaustive switch diagnostic from the analyzer at the classifier site — build fails with the event class name + file location.

**Priority**: Must / P0

#### FR2: Barrel & Public-API Discipline

**Description**: Every `export 'src/...'` in a package barrel uses a `show` clause. Known over-exported types (canvas advisor re-exports, channel-package typedefs) are demoted.

**Acceptance Criteria**:
- [ ] `dartclaw_workflow` barrel has ≤35 exports with `show` clauses
- [ ] `canvas_exports.dart` advisor re-export block deleted; `AdvisorSubscriber` direct-imported by `service_wiring.dart`
- [ ] `barrel_show_clauses_test.dart` fitness function passes

**Error Handling**: Fitness function allowlist frozen at current intentional violators; any new wholesale export fails build.

**Priority**: Must / P0

#### FR3: Package Boundary Corrections

**Description**: Extract abstractions that currently sit in the server package's concrete implementation so stable packages depend on interfaces, not volatile impls. **Note (2026-05-04 reconciliation)**: TD-063's pubspec edge was already removed during 0.16.4 (`dartclaw_testing/pubspec.yaml` lists only `dartclaw_core` under `dependencies:`); the entry will be deleted at sprint close as 0.16.4-closure backlog hygiene rather than counting toward 0.16.5 closure. The actual interface-extraction work (the substantive part of FR3) is unchanged. **Extended by delta review** with `ProcessEnvironmentPlan` promotion (S32) and `WorkflowTaskBindingCoordinator` extraction (S33).

**Acceptance Criteria**:
- [ ] `TurnManager`, `TurnRunner`, `HarnessPool`, `GoogleJwtVerifier` interfaces in `dartclaw_core` (`src/turn/`, `src/auth/`); concrete impls stay in server
- [ ] `FakeTurnManager`, `FakeGoogleJwtVerifier` in `dartclaw_testing` bind to the interfaces
- [x] `dartclaw_testing/pubspec.yaml` drops `dartclaw_server` dependency (closes TD-063) — **already met by 0.16.4**; verify still met at sprint close and delete TD-063 entry
- [ ] `WorkflowRunRepository` abstract interface in `dartclaw_core`; sqlite impl in `dartclaw_storage` (the existing `WorkflowRunRepositoryPort` in `dartclaw_workflow` is a `dynamic`-wrapped placeholder — promote it, type it properly, then delete the placeholder)
- [ ] **`TaskExecutor` accepts `WorkflowRunRepository?` (abstract), not `SqliteWorkflowRunRepository?`** (delta-review ADX-01 closed) — current ctor field type at `task_executor.dart:113` still concrete
- [ ] **`InlineProcessEnvironmentPlan` + `ProcessEnvironmentPlan.empty` promoted to `dartclaw_security`**; the 2 confirmed cross-package duplicates (`_InlineProcessEnvironmentPlan` in `project_service_impl.dart:48` and `remote_push_service.dart:181`) deleted (the third originally-cited duplicate `_EmptyProcessEnvironmentPlan` in `workflow_executor.dart` is already gone post-0.16.4 S45/S47 + WorkflowGitPort)
- [ ] **`WorkflowTaskBindingCoordinator` abstract interface in `dartclaw_core`** with concrete impl in `dartclaw_server` (promote/rebrand the existing `WorkflowWorktreeBinder` already extracted in 0.16.4) and fake in `dartclaw_testing`; `TaskExecutor` no longer holds the `_workflowSharedWorktrees*` maps **(already met by 0.16.4 — maps live on the binder, TaskExecutor delegates via `_worktreeBinder`)**
- [ ] `testing_package_deps_test.dart` + `no_cross_package_env_plan_duplicates_test.dart` fitness functions pass

**Priority**: Must / P0

#### FR4: Structural Decomposition of Remaining Hotspots

**Description**: The post-0.16.4 baseline already split `workflow_executor.dart` and `task_executor.dart`; this sprint now shrinks the remaining over-threshold/configuration and execution hotspots along their natural ownership boundaries. `config_parser.dart` moves to typed reader helpers, `foreach_iteration_runner.dart` / `context_extractor.dart` / `workflow_executor_helpers.dart` reduce to focused collaborators, the CLI's `service_wiring.dart#wire()` (678-line method) splits per subsystem, and the server's composition root collapses `compose()` into the builder with grouped dep structs. TD-052 is already effectively closed by 0.16.4 S46 and is removed from the public tech-debt backlog at sprint close.

**Acceptance Criteria**:
- [ ] `foreach_iteration_runner.dart` ≤900 LOC after extracting foreach/promotion/merge-resolve state-machine collaborators
- [ ] `context_extractor.dart` ≤600 LOC after structured-output schema validation and helpers move to sibling modules
- [ ] `workflow_executor_helpers.dart` ≤400 LOC or deleted with helpers absorbed into owning runners
- [ ] `task_executor.dart` constructor takes ≤12 parameters via dep-group structs; `_workflowSharedWorktrees*` fields removed through S33; any surviving `_markFailedOrRetry` duplicates unified
- [ ] `config_parser.dart` ≤1,200 LOC using new `YamlTypeSafeReader` helpers (51 inline warnings consolidated)
- [ ] `service_wiring.dart#wire()` (in `apps/dartclaw_cli/`) split into per-subsystem `_wireXxx()` methods with a `WiringContext` struct
- [ ] `DartclawServer` ctor takes 6 dep-group structs, not 60+ scalars; `compose()` removed
- [ ] `max_file_loc_test.dart` and `constructor_param_count_test.dart` fitness functions pass

**Priority**: Must / P0

#### FR5: Model Package Cleanup

**Description**: `dartclaw_models` shrinks to a true shared kernel (Session, Message, SessionKey, ChannelType, AgentDefinition, MemoryChunk). Domain models move to their owning packages. Migration also closes tech-debt [TD-053](../../state/TECH-DEBT-BACKLOG.md#td-053--taskeventkind-sealed-class-should-be-an-enum) (convert `TaskEventKind` sealed class to enum while moving).

**Acceptance Criteria**:
- [ ] `WorkflowDefinition`, `WorkflowStep`, `WorkflowRun`, `WorkflowExecutionCursor` moved to `dartclaw_workflow`
- [ ] `Project`, `CloneStrategy`, `PrStrategy`, `PrConfig` moved to `dartclaw_config` (or new `dartclaw_project` sub-module)
- [ ] `TaskEvent` + 9 subtypes moved to `dartclaw_core` (where `Task` lives); `TaskEventKind` sealed class converted to enum (closes TD-053)
- [ ] `TurnTrace`, `TurnTraceSummary`, `ToolCallRecord` moved to `dartclaw_core`
- [ ] `SkillInfo` moved to `dartclaw_workflow`
- [ ] `dartclaw_models` ≤1,200 LOC
- [ ] CHANGELOG entry notes the public-API migration

**Priority**: Must / P0 (gated by metrics table; tag upgraded from P1 to reflect release-gate requirement)

#### FR6: Fitness Functions + Dartdoc Governance

**Description**: Thirteen governance checks in CI prevent recurrence of every drift class surfaced by this sprint, plus `public_member_api_docs` lint flip in four near-clean packages (S37). Level-1 consists of six fitness test files plus one format gate; Level-2 consists of six fitness test files.

**Level-1 (≤30s, every commit):**
1. `barrel_show_clauses_test.dart` — every `export 'src/...'` has `show`
2. `max_file_loc_test.dart` — no `lib/src/**/*.dart` > 1,500 LOC
3. `package_cycles_test.dart` — zero cycles in pkg graph
4. `constructor_param_count_test.dart` — no public ctor > 12 params
5. `dart format --set-exit-if-changed` gate
6. `no_cross_package_env_plan_duplicates_test.dart` — `ProcessEnvironmentPlan implements` clauses only inside `dartclaw_security` (or allowlisted credential-carrying impls) — catches S32 regression
7. `safe_process_usage_test.dart` — Dart-native promotion of `dev/tools/check_git_process_usage.sh`; zero raw `Process.run('git', ...)` in production code

Removed candidate: `alertable_events_test.dart`; S01 now uses compiler-enforced exhaustive switch expressions on the sealed event hierarchy instead of a runtime fitness test.

**Level-2 (every PR, 1–5 min):**
8. `dependency_direction_test.dart` — allowed pkg edges as data
9. `src_import_hygiene_test.dart` — no cross-pkg `src/` imports
10. `testing_package_deps_test.dart` — testing pkg deps restricted
11. `barrel_export_count_test.dart` — per-pkg soft caps
12. `enum_exhaustive_consumer_test.dart` — runtime scan over SSE envelopes, alert classifiers, UI badge maps, CLI status renderers; every `WorkflowRunStatus`/`TaskStatus`/equivalent sealed-enum value handled by each consumer
13. `max_method_count_per_file_test.dart` — per-file ≤40 public+private methods; complements L1 LOC ceiling

**Dartdoc lint (from S37):**
- `public_member_api_docs` enabled in `dartclaw_models`, `dartclaw_storage`, `dartclaw_security`, `dartclaw_config` `analysis_options.yaml`; zero undocumented public top-levels in `dartclaw_server/lib/`.

**Acceptance Criteria**:
- [ ] All 7 L1 governance checks green; allowlists reflect intentional remaining violators
- [ ] All 6 L2 functions green
- [ ] `public_member_api_docs` enabled in 4 near-clean packages; zero undocumented public top-levels in `dartclaw_server/lib/`
- [ ] Tests + dartdoc lint documented in `TESTING-STRATEGY.md`

**Priority**: Must / P0 (L1 + dartdoc lint) / P1 (L2)

#### FR7: Documentation Currency

**Description**: Every user-facing document reflects 0.16.4 reality.

**Acceptance Criteria**:
- [ ] `AGENTS.md` already mirrors current `CLAUDE.md`; add/verify the explicit 0.16.5 milestone line, non-Claude-agent standard-file assertion, multi-harness model, 12 packages, and absence of "Bun standalone binary" / "0.9 Phase A in progress"
- [ ] `README.md` banner already reads `v0.16.4`; verify description matches 0.16.4 reality and refresh only stale surrounding text
- [ ] Package trees in README + `architecture.md` include `dartclaw_workflow` + `_testing` + `_config`; count bumped to 12
- [ ] 4 fixes: Deno worker, `agent.claude_executable`, WhatsApp port 3000→3333, Guard API example
- [ ] `CHANGELOG.md` 0.16.4 entry skill count → 14; note 0.16.1 workflow packs absorbed into consolidation
- [ ] `docs/sdk/*` describes `0.0.1-dev.1` placeholder per ADR-008
- [ ] `configuration.md` scheduling schema reconciled; `channels.google_chat` fields complete; `DARTCLAW_DB_PATH` fixed or removed
- [ ] All recipes + `examples/personal-assistant.yaml` use `memory.max_bytes`
- [ ] `dartclaw_workflow` and `dartclaw_config` READMEs match other package-README structure; `dartclaw_cli` README command list current

**Priority**: Must / P0 (critical items) / P1 (rest)

#### FR10: API Polish & Readability (delta-review additions)

**Description**: Batch of Effective-Dart and readability improvements surfaced by the 2026-04-21 delta review. Not new features — renames, enums for stringly-typed flags, helper extraction, and small readability wins. Breaking public-API renames batch with FR5 (S22) for one coherent CHANGELOG migration entry.

**Acceptance Criteria**:
- [ ] **S34 — `ClaudeSettingsBuilder`**: pure-utility class in `dartclaw_core/harness/`; both `claude_code_harness.dart` and `workflow_cli_runner.dart` delete their private helpers and import it (≥100 LOC duplication removed)
- [ ] **S34 — token-parse helper alignment**: `_parseClaude` / `_parseCodex` use `intValue` / `stringValue` from `base_protocol_adapter.dart`; zero inline `(x as num?)?.toInt()` remaining; cross-reference to private repo `docs/specs/0.16.4/fis/s43-token-tracking-cross-harness-consistency.md` for the correctness fix itself
- [ ] **S34 — shared `normalizeDynamicMap` helper**: 3 sites (`_stringifyDynamicMap` in harness + runner; `_normalizeWorkflowOutputs` in workflow executor) route through one canonical utility
- [ ] **S34 — workflow task-config accessors/constants**: `_workflowFollowUpPrompts`, `_workflowStructuredSchema`, `_workflowMergeResolveEnv`, `_dartclaw.internal.validationFailure`, and token-metric keys route through a central typed/constant surface; new underscored workflow task-config keys require extending that surface
- [ ] **S34 — task-config policy enforcement**: a short architecture note (or barrel-level dartdoc on the typed surface) records the rule "new underscored workflow task-config keys must be added to the typed surface rather than ad hoc literals" so the In-Scope promise above is auditable
- [ ] **S35 — enums for stringly-typed flags**: `WorkflowTaskType`, `WorkflowExternalArtifactMountMode`, `WorkflowGitWorktreeMode`, `IdentifierPreservationMode` — each with `fromJsonString(String)` factory throwing `FormatException` on unknown values; JSON wire format byte-compatible
- [ ] **S36 — public naming batch**: zero `k`-prefix public identifiers in `dartclaw_security` + `dartclaw_workflow` barrels; `get*` methods on public service interfaces renamed or converted to getters (`getDefaultProject` → getter `defaultProject`, `getLocalProject` → getter `localProject`, etc.); CHANGELOG under S22 banner
- [ ] **S38 — readability pack**: `_logRun(run, msg)` helper replaces 12+ inline prefix calls in `workflow_executor.dart`; per-step progression logs drop `info` → `fine`; typed `Task.worktree` getter; `WorkflowStep.type` renamed to `taskType` (old field deprecated); dir-naming conventions documented in `dartclaw_core` barrel; `TaskExecutor.workspaceDir` → `workspaceRoot`; `TaskExecutorLimits` record drops ctor param count below 12

**Error Handling**: Stringly-typed-flag enum factories throw `FormatException` listing all valid values on unknown input — improves error-message quality from the current silent-branch behavior.

**Priority**: Planned target / P0 (S34) / slip candidate (S35, S36, S38 if scope pressure bites)

#### FR8: Housekeeping Sweep + Tech-Debt Mop-Up

**Description**: Mechanical hygiene across the workspace bundled with small-scoped items from [`TECH-DEBT-BACKLOG.md`](../../state/TECH-DEBT-BACKLOG.md) that align with the sprint's goals (safety, observability, DRY, maintainability). Items are grouped by nature; each is small enough to batch with the sweep.

**Acceptance Criteria** (housekeeping):
- [ ] `dart format packages apps` clean (from 0-1 drifted files at sprint start)
- [ ] Pubspec alignment: `yaml ^3.1.3` + `path ^1.9.1` everywhere; `dev/tools/check-deps.sh` asserter script added
- [ ] 22 production `catch (_)` sites each have `_log.fine(...)` or a one-line rationale comment
- [ ] 23 test `await Future.delayed(Duration.zero)` → `await pumpEventQueue()`; `TESTING-STRATEGY.md` updated
- [ ] 2 `throw Exception('...')` replaced with typed exceptions (`ScheduleTurnFailureException`, `GitFetchException`)
- [ ] Super-parameters adopted in `claude_code_harness.dart` + `codex_harness.dart`; `// ignore: use_super_parameters` removed
- [ ] `expandHome` unit tests added in `dartclaw_security`
- [ ] `SidebarDataBuilder` extracted; 6 call sites collapsed
- [ ] **Nine `FakeProcess`-style redeclarations resolved** across `dartclaw_core` + `_security` + `_signal` + `_whatsapp` + `_server` tests; matching process fakes import the canonical `dartclaw_testing` helper and divergent runner shims are either consolidated or explicitly kept with rationale
- [ ] **`resolveGitCredentialEnv` dead wrapper deleted** (only `show` reference in `task_exports.dart`; zero production callers)
- [ ] **Dead-private-method sweep** on `workflow_executor.dart` / `task_executor.dart` / `context_extractor.dart` / `workflow_cli_runner.dart` — zero uncalled `_methodName` declarations

**Acceptance Criteria** (tech-debt mop-up — each resolves a `TD-NNN` entry):
- [ ] **TD-054**: Settings page badge variant round-trip removed — callers pass variant strings directly; `_badgeVariantFromClass()` deleted
- [ ] **TD-055**: `_readSessionUsage` default-record duplication collapsed (four branches → single constant or early return)
- [ ] **TD-056**: Duplicated `_cleanupWorktree` across `task_routes.dart` + `project_routes.dart` + `task_review_service.dart` → shared utility in `dartclaw_server/lib/src/task/` (or `dartclaw_core` if cross-package value)
- [ ] **TD-060**: `dartclawVersion` auto-derivation from `pubspec.yaml` at build time *or* a release-checklist entry added to `docs/guidelines/KEY_DEVELOPMENT_COMMANDS.md` (pick derivation if the pre-compile step is ≤20 LOC)
- [ ] **TD-061**: Codex stderr logged at `WARNING` / `FINE` via `_log` in `codex_harness.dart`, mirroring `ClaudeCodeHarness` pattern (provider errors visible in logs)
- [ ] **TD-029** *(stretch if capacity — if skipped, re-trigger note added to TD-029)*: `TemplateLoaderService` parameter introduced so template rendering accepts a per-server/test-scoped loader; global accessor retained as back-compat shim with `@Deprecated`

**TD entries closed elsewhere in 0.16.5**: TD-052 was already closed by 0.16.4 S46 and is removed from the public backlog at sprint close; TD-053 by FR5 (`TaskEventKind` → enum during model migration), TD-063 by FR3 (`dartclaw_testing` → `dartclaw_server` edge removed).

**Priority**: Must / P0 (baseline housekeeping + TD-054/055/056/060/061) / P2 (TD-029 stretch)

#### FR9 (Stretch): Documentation Gap-Fill

**Description**: Pick 2 of 5 candidate gap-fill pages if capacity permits.

**Acceptance Criteria** (pick 2 of 5):
- [ ] Promote `recipes/08-crowd-coding.md` → `docs/guide/crowd-coding.md` + link from Features table, OR
- [ ] New `docs/guide/governance.md` (rate limits, budgets, loop detection, `/stop`/`/pause`/`/resume`), OR
- [ ] New `docs/guide/skills.md` (SkillRegistry source priority, frontmatter schema, user vs managed skills), OR
- [ ] Workflow Triggers section in `workflows.md` (chat commands, web launch forms, GitHub PR webhook + HMAC), OR
- [ ] Alert Routing + Compaction Observability sections under `web-ui-and-api.md` or new `observability.md`

**Priority**: Should / P2 (stretch only)

### User Flows

Stabilisation sprint has no user-interaction flows per se. The two observable flows it affects:

1. **Alert delivery flow** (gap close): event emitted → `EventBus` → `AlertRouter` → `AlertClassifier.classifyAlert()` → non-null verdict → routed to alert target. Today: `LoopDetectedEvent` / `EmergencyStopEvent` fall through to null and silently drop. After: both classify to critical severity and reach operators.
2. **SSE observability flow** (gap close): event emitted → subscribed route handler → formatted as SSE event → browser dashboard/task timeline. Today: `TaskReviewReadyEvent`, `AdvisorInsightEvent`, `CompactionStartingEvent`, `MapIterationCompletedEvent`, `MapStepCompletedEvent` emit without SSE listeners. After: all 5 appear in real-time UI.

### Data Requirements

No new data entities. Models relocate packages (FR5); their persistence shape is unchanged. Fitness-function allowlists are plain-text files under `test/fitness/allowlist/` (format TBD per story).

## Non-Functional Requirements

| Category | Requirement | Threshold / Target |
|----------|-------------|--------------------|
| Performance | Governance suite total runtime | Level-1 checks ≤30s; Level-2 suite ≤5 min |
| Reliability | Behavioural regressions post-decomposition | Zero — every existing test remains green; new tests added only for extracted helpers |
| Security | No regression in guard chain, credential proxy, audit logging | All existing security tests pass; no new surface introduced |
| Compatibility | Breaking change to public SDK API | FR5 model migration is visible; CHANGELOG documents and (optionally) one-release soft re-export from `dartclaw_models` |
| Developer experience | `dart analyze` workspace-wide | 0 warnings (maintained) |
| Dependency discipline | No new `pubspec.yaml` `dependencies:` entries in any workspace package | Zero net-new runtime deps (dev-dependencies excluded; reuse-only) |
| Observability | Sealed events with production consumers | 100% (every emitted event has at least one listener or documented `NOT_ALERTABLE` justification) |

## Edge Cases

| Scenario | Expected Behavior |
|----------|-------------------|
| New contributor adds a sealed `DartclawEvent` subtype without a classifier arm | `dart analyze` fails with a non-exhaustive-switch diagnostic at the `AlertClassifier.classifyAlert` / `AlertFormatter._body` sites; no separate runtime fitness test needed (compiler-enforced per S01) |
| Contributor adds a new `lib/src/**/*.dart` over 1,500 LOC | CI build fails; must split or allowlist-with-justification |
| Contributor adds an `export 'src/...'` without `show` | CI build fails on `barrel_show_clauses_test.dart` |
| External consumer pinned to `package:dartclaw_models/dartclaw_models.dart show WorkflowDefinition` after FR5 ships | Breaks; mitigated by CHANGELOG migration note and (optional) soft re-export. Risk low because pub.dev is placeholder-only today. |
| Mid-sprint: Block E runs long | Block G items (S22 model migration, S23 housekeeping + tech-debt mop-up, S35/S36/S38 polish) can move to 0.16.6 by explicit scope decision if the sprint window is tight; Blocks A+B remain the release floor. DartClaw does not ship patch releases — slip is always forward to the next minor. |
| Workflow decomposition introduces a latent defect | Existing workflow tests (2,382 LOC) catch at unit level; integration proof via `plan-and-implement` E2E scenario |
| `AdvisorInsightEvent` wiring doubles delivery (canvas already renders + new SSE) | Intentional — canvas is the persistent shared surface, SSE is real-time dashboard. No dedup needed. |

## Constraints & Assumptions

### Constraints

- **Public repo only.** All code/doc changes land in `dartclaw-public`. Private-repo updates (doc currency, spec hygiene) happen during planning or as explicit user-approved commits per `CLAUDE.md` rules.
- **No new user-facing features.** Any feature-shaped work defers to 0.16.6+.
- **No breaking protocol changes.** JSONL control protocol, REST payloads, SSE envelope format all stable.
- **No new dependencies** in any package. Fitness functions use existing `test` + `analyzer` + `package_config`.
- **Workspace-wide strict-casts + strict-raw-types** must remain on throughout.

### Assumptions

- Existing test coverage is sufficient to protect structural refactors (validated: 2,382 LOC of workflow tests + full task-executor integration tests + 1,828 LOC of config-parser tests).
- Pub.dev state is `0.0.1-dev.1` placeholder at sprint start and will remain so through sprint (no real publish during stabilisation).
- No external SDK consumers exist today. FR5 public-API migration is safe to ship with only a CHANGELOG note.
- Safety-event wiring to SSE uses patterns already established in `workflow_routes.dart` for sibling events. No design work needed.
- 0.16.6 (Stimulus Adoption) waits for this sprint. Stimulus work would otherwise bake against the pre-decomposition hotspots.

### Dependencies

| Dependency | Why It Matters |
|------------|----------------|
| 0.16.4 shipped | Prerequisite. All 81 stories completed by the 2026-04-30 pre-tag pass (72 catalogued in `0.16.4/plan.md` + 9 in the `agent-resolved-merge/` sub-plan). The 2026-04-15 plan-lock at 13 stories grew in flight; final shape captured in `0.16.4/0.16.4-consolidated-review.md`. |
| ADR-008 (SDK publishing strategy) | FR7 SDK framing work references this ADR as the authoritative narrative. |
| Existing fitness-test infrastructure | Level-1 + Level-2 fitness test files use `package:test` + `package:analyzer`; the Level-1 format gate uses `dart format` — no new deps. |
| `docs/guidelines/TESTING-STRATEGY.md` | Gets updates from FR8 (`pumpEventQueue` pattern codified). |
| Private-repo `CLAUDE.md` + `MEMORY.md` | Already refreshed pre-sprint (skill count 10→14, architecture count 11→12). |

## Decisions Log

| Decision | Rationale | Alternatives Considered |
|----------|-----------|-------------------------|
| Ship stabilisation as 0.16.5, bump Stimulus Adoption to 0.16.6 | Stimulus work wants a clean structural baseline; stabilisation work is dependency-free and unblocks everything downstream. | Ship Stimulus as 0.16.5 and stabilisation as 0.16.6 (rejected — Stimulus would bake against god files). Ship stabilisation as 0.17.0 (rejected — it's backwards-compatible structural work). |
| Wire all 7 orphan events (not delete) | Events carry semantic payload; SSE + alert wiring is same effort as deletion across the class hierarchy + emission sites; matches sibling-event pattern in `workflow_routes.dart`. | Delete orphan events (rejected for this sprint — may reconsider per-event if advisor subsystem gets rethought). |
| `AdvisorInsightEvent` wires to SSE + severity-aware alert on `status: stuck\|concerning` | Advisor feature is fully wired via canvas + channels; event carries useful semantic data (status field) that should reach dashboard + on-call. | Delete (rejected — feature is not half-finished). |
| SDK 0.9.0 framing → path (a) acknowledge placeholder | Publishing requires public-repo-open which is out of sprint scope; path (a) gets docs honest immediately. | Path (b) accelerate real publish (rejected — depends on repo-open decision). |
| FR5 model migration promoted from stretch to planned target | Pub.dev is placeholder-only, no external consumers, safe window to ship the move; cascade-recompile cost worth removing now. | Defer to 0.16.7 (rejected as the default — would require a second sprint to absorb the CHANGELOG migration note; still available if the planned target is explicitly narrowed). |
| Target sprint size 29 planned-target stories + 1 stretch | Ambitious but safe: blocks are independent + parallelisable; 0.16.4 ultimately closed 81 stories (across the main plan + the agent-resolved-merge sub-plan), proving the workspace can sustain a high-throughput sprint when stories are independent + parallelisable; delta-review adds are each Small/Low-risk and concentrate in Block C/D/G where the waves already run parallel. Stabilisation releases warrant an exception to the 10–14/milestone retro guidance. | Minimum viable release floor (10 stories, Blocks A+B including S37) — available as fallback if Blocks C+ slip. Slip S35/S36/S38 forward to 0.16.6 (retained as the pre-approved capacity-pressure fallback per MVP Boundary). |
| Governance checks at both Level-1 and Level-2 | L1 alone doesn't catch dep-direction or testing-pkg-dep regressions; both together prevent all drift classes surfaced by this review. | L1 only (rejected — insufficient for FR3 guarantees). |
| Housekeeping sweep bundled in Block G | Small, independent, mechanical items don't warrant individual stories; one sweep story with enumerated check-list is cleaner. | 7 separate sub-stories (rejected — over-granular). |
| Pre-sprint private-repo fixes: CLAUDE.md + arch-count refreshed during planning (2026-04-17) | Stale counts (10 skills → 14, 11 architecture docs → 12) were misleading agents reading CLAUDE.md at session start; 30-second fix not worth a formal sprint story. | Include in sprint as story (rejected — too small, already applied). |
| Remove already-closed TD-052/TD-059 at sprint close; fold tech-debt items TD-053/054/055/056/060/061/063 into sprint FRs; defer TD-058/062/064 | Items chosen are small-scoped, align with "safety / observability / DRY" themes, and ride on refactors already planned (FR3/4/5). Deferred items require new deps (TD-058 `package:timezone`) or feature work (TD-062, TD-064 Codex upstream). TD-052 and TD-059 are cleanup deletions because prior 0.16.4 work already resolved them. | Include all open TD (rejected — violates "no new deps" + "no new features" constraints). |
| Stretch TD-029 (template loader service) included but marked P2 | Reduces global-state coupling that the fitness-function work will otherwise protect in amber; small enough to piggyback on Block G if capacity remains. | Must-ship (rejected — pulls scope into ambiguous territory; skip is safe). |
| No 0.16.5.1 patch — slip scope forward to 0.16.6 | DartClaw has never shipped a patch release (0.8 → 0.14.2 → 0.16.4 all minors); patch tooling does not exist; the Stimulus milestone can absorb overflow. | Ship a first patch (rejected — would invent a release-track with no tooling for <1 story of overflow). |
| Fold 2026-04-21 delta-review adds (S32–S38, 7 new stories) into 0.16.5 | Churn from S36–S40 Archon hardening / status-redesign / credential-preflight work (landed post-plan-lock) needs to ship alongside the structural consolidation, not in a parallel 0.17 pass. S32/S33/S34 are prerequisites/enablers for the existing S11/S15/S16 decomposition work; delaying them would leak structural debt into 0.16.6's Stimulus baseline. S35/S36/S38 are low-cost polish with high payoff for future contributors. | Defer all 7 to 0.17 (rejected — S32/S33/S34 directly unblock 0.16.5 structural work). Defer only S35/S36/S38 (available as fallback slip candidates per MVP Boundary). |
| Compiler-exhaustive switch over `sealed DartclawEvent` in S01 replaces the originally-planned custom `alertable_events_test.dart` runtime test | Sealed hierarchy + exhaustive `switch` expression gives compiler-enforced coverage with zero runtime cost, better error messages (file:line from the analyzer), and idiomatic Dart 3.x. The custom fitness test was solving a problem the language now solves directly. | Keep the custom runtime test (rejected — adds maintenance burden for no extra correctness vs. the compiler). Run both belt-and-braces (rejected — redundant). |

### Superseded Historical Guidance (durable rules)

These rules emerged across the 2026-04-17 / 2026-04-21 / 2026-04-30 review consolidation passes and are kept as project-wide guardrails for the remainder of 0.16.5:

- The original "five god files" framing (workflow_executor / task_executor / config_parser / service_wiring / server) is **not current scope**. Retained only as historical evidence of why this stabilisation sprint exists. Current structural targets are enumerated in FR4 + the 2026-04-30 / 2026-05-04 audit blocks above.
- `dart format --set-exit-if-changed` counts as a **Level-1 governance check**, not a Level-1 fitness test file. The L1 count is "6 fitness test files + 1 format gate", not "7 fitness test files".
- Do not create private-repo shadows of public canonical docs. State, learnings, tech debt, ubiquitous language, and code-touching guidelines live under `dev/state/` and `dev/guidelines/` in this (public) repo.
- Do not run `/dartclaw-exec-spec` against planned FIS filenames until those FIS files actually exist; the plan's `fis/sNN-*.md` entries are *target* names until generated by the spec/plan workflow.
- Do not route scope pressure to a `0.16.5.1` patch release. DartClaw does not ship patch releases; deferred work moves forward into 0.16.6 or later (see Decisions Log row "No 0.16.5.1 patch — slip scope forward to 0.16.6" above).

## Related Documents

- Source-review provenance: see [`plan.md`](./plan.md) "Source Reviews & Finding ID Conventions"
- 0.16.4 consolidated review (parallel provenance for cross-milestone findings): private repo `docs/specs/0.16.4/0.16.4-consolidated-review.md`
- Related 0.16.4 FIS (out-of-band token correctness fix, not 0.16.5 scope): private repo `docs/specs/0.16.4/fis/s43-token-tracking-cross-harness-consistency.md`
- Tech-debt source: [`dev/state/TECH-DEBT-BACKLOG.md`](../../state/TECH-DEBT-BACKLOG.md)
- ADR-008 — SDK publishing strategy (referenced by FR7 SDK framing): see "Inline Reference Summaries" appendix below; full rationale in private repo `docs/adrs/008-sdk-publishing-strategy.md`
- Next milestone: `0.16.6/prd.md` — Web UI Stimulus Adoption (private repo: `docs/specs/0.16.6/prd.md`)

---

## Inline Reference Summaries

The references below summarise load-bearing private-repo artefacts that this PRD depends on. They are integrated here so a reader of the public spec can understand the substance without crossing into the private repo. Each summary ends with a pointer to the canonical source.

### ADR-008 — SDK Publishing Strategy

Status: Accepted (revised 2026-03-12). Decision: name-squat the `dartclaw` package on pub.dev as `0.0.1-dev.1` (published 2026-03-01, transferred to verified publisher), with the first real release at `0.5.0` once `InputSanitizer`, `MessageRedactor`, and `UsageTracker` join the public API surface. The 2026-03-12 revision publishes **all** workspace packages — including `dartclaw_server` and `dartclaw_cli` — as **reference implementations** under the "build your own agent" philosophy: SDK packages (`dartclaw_core`, `dartclaw_models`, `dartclaw_storage`) are composable building blocks, while server and CLI are *one composition* developers can study, fork, or extend. Proprietary integrations (custom channels, guards, deployment configs) live in **separate private repos as overlays** that depend on the published packages — they extend via abstract interfaces (`Channel`, `Guard`, `SearchBackend`) rather than modifying the public packages. Versioning follows the Dart pre-1.0 convention (`0.BREAKING.FEATURE`), all packages share a coordinated version. The 0.5 core/storage split landed 2026-03-03: sqlite3 cleanly isolated to `dartclaw_storage` (2 source files), `dartclaw_core` is sqlite3-free, and the `dartclaw` umbrella re-exports both. (Full rationale, alternatives considered, and revision history: private repo `docs/adrs/008-sdk-publishing-strategy.md`.)


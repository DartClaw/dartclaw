# Implementation Plan: DartClaw 0.16.5 — Stabilisation & Hardening

> **PRD**: [`prd.md`](./prd.md)
>
> **References**:
> - [`.technical-research.md`](./.technical-research.md) — supporting technical research for plan/FIS authoring
> - [`TECH-DEBT-BACKLOG.md`](../../state/TECH-DEBT-BACKLOG.md) — tech-debt items folded into this sprint or explicitly narrowed (full closure list in Overview below)
> - [Source Reviews & Finding ID Conventions](#source-reviews--finding-id-conventions) — ID glossary for `Asset refs:` citations across stories
> - [Inline Reference Summaries](#inline-reference-summaries) — ADR-008, ADR-021, ADR-022, ADR-023 summarised in-document; canonical sources live in private repo `docs/adrs/`
> - Architecture deep-dives — private repo `docs/architecture/{system,workflow,security}-architecture.md`; §13 of `workflow-architecture.md` is the load-bearing section for this milestone (substance captured by ADR-023)
> - Next milestone — 0.16.6 — Web UI Stimulus Adoption (private repo `docs/specs/0.16.6/prd.md`)

## Overview

- **Total stories**: 29 planned-target + 1 stretch (30 total) — _down from 30 planned-target stories to 29 after the 2026-04-30 0.16.4-overlap audit retired S30 (validator already split by 0.16.4 S44) and re-scoped S15/S16 (executor + task-executor file-LOC targets already met by 0.16.4 S45/S46; remaining work narrows to new hotspots). Release-floor breakdown: Block A+B 10; planned-target remainder: Block C–F 12 + Block G 7; Block H stretch S26 = 1._
- **Phases**: 8 (Block A Safety + Quick Wins → Block B Governance Rails → Block C Interface Extraction → Block D Pre-decomposition Helpers → Block E Structural Decomposition → Block F Doc + Hygiene Closeout → Block G Model & Observability Closeout → Block H Stretch Docs Gap-Fill)
- **Waves**: 7 (W1 … W7) — S09, S27, S28, S29 in W1
- **Tech-debt items closed by 0.16.5 stories**: 17 planned-target — TD-046 (S25), TD-053 (S22/FR5), TD-054/055/056/060/061/069/073/085 (S23), TD-063 (S11/FR3 — already met by 0.16.4; counted as cleanup), TD-072 item 2 (S03; item 1 retired by the data-dir skill-provisioning reconciliation), TD-074 (S25 release closeout), TD-082/088 (S15), **TD-102** (S22 — absorbed 2026-05-04), **TD-103** (S34 Part D — absorbed 2026-05-04). **Narrowed by explicit decision** (3): TD-086 mechanical parser-coercion slice closed in S13 with semantic residuals narrowed; TD-089 triaged in S16/S23; TD-090 triaged in S23. **Stretch** (+1): TD-029 in S23. **Backlog hygiene at sprint close (NOT counted toward 0.16.5 closure)**: delete TD-052 (closed by 0.16.4 S46) and TD-059 (already marked Resolved by 0.16.4 S42) per the "Open items only" policy — these are 0.16.4-closure residue that escaped the previous milestone's hygiene pass, not 0.16.5 work. See PRD FR3/4/5/8.
- **Additional TDs surfaced during 0.16.4 restructure (2026-05-02 → 2026-05-04 reconciliation)** — folded into existing stories:
  - **TD-102** (`dartclaw_core/lib/` 12437 LOC vs 12000 ratchet; ceiling temporarily raised to 13000 to unblock release) → folded into **S22 (`dartclaw_models` Grab-Bag Migration)**. The natural attractor is to migrate non-runtime-primitive material out of `dartclaw_core` to `dartclaw_models` / `dartclaw_config` while S22 is already restructuring this surface; once below 12000 LOC, lower the ratchet back down.
  - **TD-103** (server-side `_workflow*` task-config reads behind a typed accessor) → folded into **S34 Part D (Workflow task-config accessors/constants)**. S34 already enumerates `_workflowFollowUpPrompts`, `_workflowStructuredSchema`, `_workflowMergeResolveEnv`, `_dartclaw.internal.validationFailure`, and the token-metric keys; add `_workflowNeedsWorktree` (and `_workflowMergeResolveEnv` if not already covered) to the typed surface and migrate the two server reads at `task_config_view.dart:52,54` + `workflow_one_shot_runner.dart:77`. Then drop those entries from `ALLOWED_FILES` in `dev/tools/fitness/check_no_workflow_private_config.sh`.
  - **TD-099 / TD-100 / TD-101** (the original 2026-05-02 surfacing IDs cited in earlier plan revisions) — restructured during 0.16.4 release prep into the surviving TD-102 / TD-103 above. TD-101 (`task_executor.dart` workflow-refs allowlist drift) was resolved within the 0.16.4 release-prep window. No outstanding action under the original IDs.
- **0.16.4-already-shipped reconciliation (2026-05-04)** — items the original PRD/plan flagged for 0.16.5 but which actually landed during 0.16.4 release prep, with remaining-scope notes:
  - **AGENTS.md major rewrite** (S03 Part a) — already mirrors `CLAUDE.md` (multi-harness Claude+Codex language, all 12 packages, no `0.9 Phase A`, no `Bun standalone binary`). Remaining S03(a): the explicit "Current milestone: 0.16.5" line + "AGENTS.md is standard for ALL non-Claude-Code agents" assertion only.
  - **README banner v0.16.4** (S03 Part b) — already shipped on `main`. Remaining S03(b): verify wording matches FR7 and refresh tone if needed.
  - **`dartclaw_testing → dartclaw_server` pubspec edge** (FR3 / S11 sub-scope) — already removed (TD-063 effectively closed). Remaining S11: just the actual interface extraction (`TurnManager`, `TurnRunner`, `HarnessPool`, `GoogleJwtVerifier` → `dartclaw_core`).
  - **WorkflowGitPort extraction** — already shipped (124 LOC port + 237 LOC process impl). No 0.16.5 work.
  - **WorkflowWorktreeBinder concrete extraction** (S33 heavy lifting) — already shipped at `packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart`. Remaining S33: abstract interface in `dartclaw_core` + fake in `dartclaw_testing` + redundant `workflowRunId` callback param cleanup. Risk drops Medium → Low.
  - **WorkflowRunRepositoryPort placeholder** (S12 partial) — exists at `workflow_runner_types.dart:69` as a `dynamic`-wrapped wrapper inside `dartclaw_workflow`. Remaining S12: promote to `dartclaw_core`, replace `dynamic` delegate with proper abstract interface, migrate `TaskExecutor.workflowRunRepository` field (still `SqliteWorkflowRunRepository?` at line 113).
  - **Stale baseline corrections**: `dart format` drift 11 → 0-1; `dartclaw_models` LOC 3,005 → **3,555** (grew); `dartclaw_workflow` wholesale exports 26 → **34**; `cli_workflow_wiring.dart` 350 → **945 LOC**; `context_extractor.dart` 960 → **1,414 LOC**. Targets unchanged; effort estimates increase for S15/S17/S22.
- **Architectural hygiene**: S27 (ADR-023 workflow↔task boundary) and S28 (workflow↔task import fitness test) formalise the behavioural contract that ADR-021 and ADR-022 established at the data layer; the 2026-04-28 workflow-package architecture review is folded into S12 (typed workflow repository port), S15 (executor logical-library decomposition), and S25 (fitness-function hardening); the 2026-04-30 0.16.4 remediation follow-up adds TD-070 placement decisions to S15 (executor decomposition), S31 (`WorkflowCliRunner` ownership) and S34 (typed task-config keys); TD-065 tracks the optional polymorphic `TaskExecutionStrategy` refactor as conditional follow-up.
- **Approach**: Land quick wins (safety, barrel cleanup, doc currency) and governance rails (fitness functions) first, so the structural work that follows has safety nets. Interface extraction and DRY helpers precede the big decompositions. God-file splits and package boundary corrections land in parallel-safe waves. Doc and hygiene closeout runs late so all code changes are reflected. Model migration ships late in the planned-target band with a CHANGELOG migration note. Tech-debt mop-up rides with the structural work so resolved items ship in the same commit chain as the refactor that unblocks them.
- **Scope-size note**: 29 planned-target stories still exceeds the 10–14-per-milestone guidance from prior retros, and this is a deliberate exception for the stabilisation release. Seven stories (S32–S38) were added on 2026-04-21 from the post-plan-lock delta review to capture churn introduced by S36–S40 Archon hardening + status redesign + credential preflight. Three planned composite FIS groupings (doc currency, DRY helpers, doc closeout) were consolidated into single stories (S03, S13, S19) on 2026-04-21 to align with the 1:1 story↔FIS invariant enforced by `dartclaw-plan` (AndThen 0.14.0 re-port). If execution capacity becomes a blocker, S35/S36/S38 are the pre-approved slip candidates for 0.16.6; DartClaw does not use a 0.16.5.1 patch path.

## Source Reviews & Finding ID Conventions

Per-story `Asset refs:` lines below cite findings by short ID (e.g. `ARCH-001`, `H-D3`, `SR-11`). The IDs trace to the source reviews that fed this PRD/plan; the source review files were removed at consolidation but the ID conventions are preserved here so future readers can still parse the citations.

| ID prefix | Source review (lens, date) |
|---|---|
| `ARCH-*` (e.g. `ARCH-001`..`ARCH-009`) | 2026-04-17 architecture review — package boundaries, decomposition candidates, fitness-function proposals |
| `ADX-*` (e.g. `ADX-01`..`ADX-06`) | 2026-04-21 delta architecture review — post-plan-lock findings + seams A–C |
| `C1` / `C2` / `C3` / `H4` / `H5` / `H6` / `H7` / `H8` / `H9` / `M1` / `M2` / `M6` / `M8` / `M10` / `M11` / `W15` / `W16` (in doc-related `Asset refs`) | 2026-04-17 documentation review — user-facing doc drift + missing-doc inventory |
| `H1`..`H5` / `M1`..`M7` / `SR-1`..`SR-14` / `L1`..`L5` / `Theme 1`..`Theme 4` (in code-related `Asset refs`) | 2026-04-17 refactor + dead-code/gaps review — code-quality and orphan-event findings |
| `H-1` / `H-2` / `M-5` / `Gaps M-*` / `Unified C-*` (gaps lens) | 2026-04-17 gaps + dead-code review — orphan events, dead exports, alerting gap |
| `H-D*` / `M-D*` / `L-D*` (delta lens) | 2026-04-21 delta refactor review — post-plan-lock code-quality deltas |
| `Effective Dart A*/B*/C*` | 2026-04-21 Effective Dart delta review — public-API hygiene findings |
| `Readability *.* ` (e.g. `Readability 1.1`, `3.3`) | 2026-04-21 delta readability review — API ergonomics improvements |
| `FF-DELTA-1`..`FF-DELTA-4` | 2026-04-21 delta architecture review — extra fitness-function proposals |
| `2026-04-30 deeper workflow review H*/M*` | 2026-04-30 `dartclaw_workflow` package-wide red-team review (claude/codex) — folded post-S78 hotfix into 0.16.5 S15 / S23; absorbed into `../0.16.4/0.16.4-consolidated-review.md` "Sources Absorbed" |

The 0.16.4 milestone-level consolidated review at `../0.16.4/0.16.4-consolidated-review.md` is a parallel provenance source for findings that crossed the 0.16.4 → 0.16.5 milestone boundary; it remains in place since 0.16.4 closure citations still reference it.

## Story Catalog

| ID | Name | Phase | Wave | Dependencies | Parallel | Risk | Status | FIS |
|----|------|-------|------|--------------|----------|------|--------|-----|
| S01 | AlertClassifier Safety Fix + Event Exhaustiveness Test | A: Safety + Quick Wins | W1 | – | [P] | Low | Done | `fis/s01-alert-classifier-safety.md` |
| S02 | canvas_exports Advisor Re-export Cleanup | A: Safety + Quick Wins | W1 | – | [P] | Low | Done | `fis/s02-canvas-exports-advisor-cleanup.md` |
| S03 | Doc Currency Critical Pass (AGENTS.md + README + guide fixes + package trees) | A: Safety + Quick Wins | W1 | – | [P] | Low | Done | `fis/s03-doc-currency-critical.md` |
| S05 | Wire 7 Orphan Sealed Events (SSE + Alert Mapping) | A: Safety + Quick Wins | W2 | S01 | No | Medium | Done | `fis/s05-wire-orphan-sealed-events.md` |
| S09 | dartclaw_workflow Barrel Narrowing | B: Governance Rails | W1 | – | [P] | Medium | Spec Ready | `fis/s09-dartclaw-workflow-barrel-narrowing.md` |
| S10 | Level-1 Governance Checks (6 tests + format gate) | B: Governance Rails | W3 | S01, S09 | No | Medium | Spec Ready | `fis/s10-level-1-governance-checks.md` |
| S11 | Turn/Pool/Harness Interface Extraction to dartclaw_core | C: Interface Extraction | W3 | – | [P] | High | Spec Ready | `fis/s11-turn-pool-harness-interface-extraction.md` |
| S12 | WorkflowRunRepository Interface in dartclaw_core | C: Interface Extraction | W3 | – | [P] | Low | Done | `fis/s12-workflow-run-repository-interface.md` |
| S13 | Pre-Decomposition DRY Helpers (context-merge, fire-step, truncate, YamlTypeSafeReader) | D: Helpers | W3 | – | [P] | Low | Spec Ready | `fis/s13-pre-decomposition-helpers.md` |
| S15 | Workflow Executor Logical-Library Reduction (post-0.16.4-S45 hotspots) | E: Structural Decomposition | W4 | S13 | No | Medium | Spec Ready (re-scoped 2026-04-30) | `fis/s15-workflow-executor-logical-library-reduction.md` |
| S16 | Task Executor Residual Cleanup (ctor params + binding handoff) | E: Structural Decomposition | W4 | S33 | No | Low | Spec Ready (re-scoped 2026-04-30) | `fis/s16-task-executor-residual-cleanup.md` |
| S17 | service_wiring.dart#wire() Per-Subsystem Split | E: Structural Decomposition | W4 | – | [P] | Low | Spec Ready | `fis/s17-service-wiring-per-subsystem-split.md` |
| S18 | DartclawServer Dep-Group Structs + Builder Collapse | E: Structural Decomposition | W4 | – | [P] | Low | Spec Ready | `fis/s18-dartclaw-server-dep-group-structs.md` |
| S19 | Doc + Hygiene Closeout (SDK framing, configuration.md schema, package READMEs) | F: Doc + Hygiene Closeout | W5 | – | [P] | Low | Spec Ready | `fis/s19-doc-closeout.md` |
| S22 | dartclaw_models Grab-Bag Migration | G: Model & Observability Closeout | W5 | S10 | No | High | Spec Ready | `fis/s22-dartclaw-models-grab-bag-migration.md` |
| S23 | Housekeeping Sweep (format/deps/catch/tests/exceptions/super-params) | G: Model & Observability Closeout | W5 | – | [P] | Low | Spec Ready | `fis/s23-housekeeping-sweep-and-td-mop-up.md` |
| S24 | SidebarDataBuilder Extraction | G: Model & Observability Closeout | W5 | – | [P] | Low | Spec Ready | `fis/s24-sidebar-data-builder-extraction.md` |
| S25 | Level-2 Fitness Functions (6 tests) | G: Model & Observability Closeout | W6 | S10, S11, S12 | No | Medium | Spec Ready | `fis/s25-level-2-fitness-functions.md` |
| S26 | Docs Gap-Fill (pick 2 of 5 pages) | H: Stretch Docs | W7 | S01, S02, S03, S05, S09, S10, S11, S12, S13, S15, S16, S17, S18, S19, S22, S23, S24, S25, S27, S28, S29, S31, S32, S33, S34, S35, S36, S37, S38 | No | Low | Spec Ready | `fis/s26-docs-gap-fill.md` |
| S27 | Workflow↔Task Boundary ADR (ADR-023) | B: Governance Rails | W1 | – | [P] | Low | Spec Ready (awaiting commit) | `fis/s27-workflow-task-boundary-adr.md` |
| S28 | Workflow↔Task Import Fitness Test | B: Governance Rails | W1 | – | [P] | Low | Spec Ready (awaiting commit) | `fis/s28-workflow-task-import-fitness-test.md` |
| S29 | Workflow CLI Run-ID Command Base Class | A: Safety + Quick Wins | W1 | – | [P] | Low | Spec Ready | `fis/s29-workflow-cli-run-id-command-base.md` |
| S30 | ~~Workflow Validator Rule Extraction~~ — **retired 2026-04-30** (closed by 0.16.4 S44; error-builder helper residue folded into S23) | D: Pre-decomposition Helpers | W3 | – | – | – | Retired | – |
| S31 | CliProvider Interface for WorkflowCliRunner | C: Interface Extraction | W3 | – | [P] | Low | Spec Ready | `fis/s31-cli-provider-interface.md` |
| S32 | Promote `ProcessEnvironmentPlan.empty` + `InlineProcessEnvironmentPlan` to `dartclaw_security` | C: Interface Extraction | W3 | – | [P] | Low | Spec Ready | `fis/s32-process-environment-plan-promotion.md` |
| S33 | WorkflowTaskBindingCoordinator Extraction (interface + fake; concrete already extracted in 0.16.4) | D: Pre-decomposition Helpers | W3 | – | [P] | Low | Spec Ready (re-scoped 2026-05-04) | `fis/s33-workflow-task-binding-coordinator-extraction.md` |
| S34 | Extract `ClaudeSettingsBuilder` + token-parse helper consolidation | D: Pre-decomposition Helpers | W3 | – | [P] | Low | Spec Ready | `fis/s34-claude-settings-builder-and-token-parse.md` |
| S35 | Stringly-typed Workflow Flags → Enums | G: Model & Observability Closeout | W5 | S22 | No | Low | Spec Ready | `fis/s35-workflow-flags-to-enums.md` |
| S36 | Public API Naming Batch (`k`-prefix + `get*` renames) | G: Model & Observability Closeout | W5 | S22 | No | Low | Spec Ready | `fis/s36-public-api-naming-batch.md` |
| S37 | Dartdoc Sweep + `public_member_api_docs` Lint Flip + Internal Dartdoc Trim | B: Governance Rails | W3 | – | [P] | Low | Spec Ready | `fis/s37-dartdoc-sweep-and-lint-flip.md` |
| S38 | Readability Pack (logRun helper, typed Task.worktree, taskType rename, dir naming) | G: Model & Observability Closeout | W5 | S22, S35 | No | Low | Spec Ready | `fis/s38-readability-pack.md` |

> **Status tracking**: The Story Catalog above is authoritative for `Status` and `FIS`. Phase Breakdown story briefs intentionally do not repeat those fields — see each FIS for full Acceptance Criteria, Scenarios, and detailed Scope.

## Phase Breakdown

### Phase 1 (Block A): Safety + Quick Wins

_Parallel-friendly W1 cluster — each quick-win story is independent and can execute concurrently. S05 (event wiring) waits for S01 (classifier + exhaustiveness test) so the test harness is ready when S05's new mappings land._

#### [P] S01: AlertClassifier Safety Fix + Event Exhaustiveness Test
**Scope**: Extend `AlertClassifier.classifyAlert` to cover `LoopDetectedEvent` and `EmergencyStopEvent` at critical severity, and convert `classifyAlert` + `AlertFormatter._body`/`_details` from if-is ladders to exhaustive `switch` expressions over the `sealed DartclawEvent` hierarchy so compiler exhaustiveness replaces the planned runtime test. Non-alertable variants get a `// NOT_ALERTABLE: <reason>` annotation and the switch returns `null`.
**Source refs**: FR1 — [`prd.md`](./prd.md)
**Asset refs**: safety alerting rows (Unified C-1, Gaps C-1, Effective Dart C1; switch-expression replaces custom exhaustiveness test)

#### [P] S02: canvas_exports Advisor Re-export Cleanup
**Scope**: Delete the advisor re-export block at `packages/dartclaw_server/lib/src/canvas/canvas_exports.dart:1-14`, route `service_wiring.dart` to direct-import `AdvisorSubscriber`, and remove 10 orphan re-exports.
**Asset refs**: H-1 finding

#### [P] S03: Doc Currency Critical Pass
**Scope**: One coordinated currency sweep across four co-located public-repo doc surfaces (AGENTS.md, README banner/description, four high-impact user-guide fixes, package trees) plus a `UBIQUITOUS_LANGUAGE.md` glossary drift fix; consolidates the original S03/S04/S06/S07 stories under the 1:1 story↔FIS invariant. Excludes wholesale rewrites — most surfaces are additive verification after 0.16.4 release prep.
**Notes**:
- 2026-05-04 reconciliation: parts (a) AGENTS.md and (b) README were largely satisfied by 0.16.4 release prep — remaining work is small additive edits ((a) milestone line + assertion) and a final tone/content verification ((b)). Detail captured in [`fis/s03-doc-currency-critical.md`](./fis/s03-doc-currency-critical.md).
- TD-072 item 2 (UBIQUITOUS_LANGUAGE.md glossary drift — Task Project ID, Resolution Verification, Workflow Run Artifact) is owned by this story. Item 1 (`workflow show --resolved --standalone` first-contact bootstrap) was retired by the data-dir skill-provisioning reconciliation: standalone show now reads already-provisioned data-dir skill roots and docs direct operators to run `dartclaw serve` or `dartclaw workflow run --standalone` first on a fresh install.
**Source refs**: FR7 — [`prd.md`](./prd.md)
**Asset refs**: C1, C2, H4, H5, H6, H7, H9, M6 findings; `CLAUDE.md` as AGENTS.md mirror source; TD-072 item 2 (UBIQUITOUS_LANGUAGE.md drift)

#### S05: Wire 7 Orphan Sealed Events (SSE + Alert Mapping)
**Scope**: Wire SSE broadcast and (where applicable) `AlertClassifier` mappings for 7 orphan sealed events — `LoopDetectedEvent`, `EmergencyStopEvent`, `TaskReviewReadyEvent`, `AdvisorInsightEvent` (severity-by-status: warning on `stuck`, critical on `concerning`, info on `on_track`/`diverging`), `CompactionStartingEvent`, `MapIterationCompletedEvent`, `MapStepCompletedEvent`. Excludes new UI components.
**Source refs**: FR1 — [`prd.md`](./prd.md)
**Asset refs**: H-2 finding; `packages/dartclaw_server/lib/src/advisor/advisor_subscriber.dart:358-381` (reference wiring pattern for Advisor)

> **S04, S06, S07 consolidated into S03 (2026-04-21)** — the four doc-currency stories (S03 AGENTS.md, S04 README, S06 guide fixes, S07 package trees) previously shared a composite FIS (`s03-s04-s06-s07-doc-currency-critical.md`). Consolidated into a single S03 story under the 1:1 story↔FIS invariant enforced by `dartclaw-plan` (AndThen 0.14.0 re-port). FIS renamed to `s03-doc-currency-critical.md`.

> **S08 removed (2026-04-20)** — the CHANGELOG corrections this story proposed were fixed inline as part of the 0.16.4 closure pass: the 0.16.4 entry skill count reflects the 11-skill end state (S30 unified `review-code` / `review-doc` / `review-gap` into `dartclaw-review`; `spec-plan` was absorbed into `plan`) and the 0.16.3 entry gained the workflow-pack consolidation note. No remaining action for 0.16.5.

#### [P] S29: Workflow CLI Run-ID Command Base Class
**Scope**: Extract a `WorkflowRunIdCommand` abstract base for the workflow CLI commands (collapsing `pause`/`resume`/`retry` from ~85 LOC each to ~20 LOC), and move duplicated `_serverOverride()` and `_globalOptionString()` helpers into a shared `cli_global_options.dart`. Zero behaviour change.
**Notes**:
- 2026-05-06 data-dir provisioning reconciliation: S29 no longer owns first-contact AndThen bootstrapping for `workflow show --resolved --standalone`. That command intentionally reads data-dir native skill roots without provisioning; the operator path is documented in `docs/guide/workflows.md`.
**Asset refs**: 0.16.4 refactor-review finding H6 (duplicated workflow CLI commands across 7-8 files)

---

### Phase 2 (Block B): Governance Rails

_Sequential — S10 (fitness functions) waits for S01 (sets up the alertable-events test baseline) and S09 (establishes the barrel-show allowlist baseline). S09 itself has no deps._

#### [P] S09: dartclaw_workflow Barrel Narrowing
**Scope**: Add `show` clauses to every `export 'src/...'` in `packages/dartclaw_workflow/lib/dartclaw_workflow.dart`, target ≤35 curated public symbols, and fix downstream imports in `dartclaw_server` and `dartclaw_cli` that previously relied on wholesale exports.
**Source refs**: FR3 — [`prd.md`](./prd.md)
**Asset refs**: ARCH-001 finding

#### S10: Level-1 Governance Checks (6 tests + format gate)
**Scope**: Add 6 Level-1 fitness test files at `packages/dartclaw_testing/test/fitness/` (barrel show clauses, max file LOC, package cycles, ctor param count, no-cross-package env-plan duplicates, safe-process usage) plus a CI `dart format --set-exit-if-changed` gate, with a workspace-root `dev/tools/run-fitness.sh` wrapper. All test files use existing deps (`package:test`, `package:analyzer`, `package:package_config`).
**Notes**:
- 2026-04-30 framing update: the safe-process fitness test freezes the post-0.16.4-S47 baseline (zero raw `Process.run('git', ...)` outside `SafeProcess` and `WorkflowGitPort`) as a regression guard. Detail in [`fis/s10-level-1-governance-checks.md`](./fis/s10-level-1-governance-checks.md).
- The compile-time exhaustiveness used by S01 replaces the originally-planned `alertable_events_test.dart` runtime check.
**Source refs**: FR4 — [`prd.md`](./prd.md)
**Asset refs**: governance rails rows (architecture fitness proposals; PRD/plan H2 count correction)

#### [P] S37: Dartdoc Sweep + `public_member_api_docs` Lint Flip + Internal Dartdoc Trim
**Scope**: Three-part governance rail — Part A dartdoc sweep for `dartclaw_server` hot-spots (26 undocumented public types, worst cluster in `advisor_subscriber.dart`); Part B enable `public_member_api_docs` lint in the four near-clean packages (`dartclaw_models`, `dartclaw_storage`, `dartclaw_security`, `dartclaw_config`) and fix the residual ≤6 gaps; Part C internal-dartdoc proportionality + planning-history cleanup per the new Effective Dart guidelines on five packages.
**Notes**:
- Part C is the slip candidate within S37 — defers to 0.16.6 as a standalone cleanup if W3 budget tightens; Parts A + B are the non-negotiable governance rail. Detail in [`fis/s37-dartdoc-sweep-and-lint-flip.md`](./fis/s37-dartdoc-sweep-and-lint-flip.md).
**Asset refs**: Effective Dart B1 row; Part C illustrative example: `packages/dartclaw_workflow/lib/src/workflow/skill_prompt_builder.dart` (30-line class dartdoc + "(S01 integration)" planning leak)

#### [P] S27: Workflow↔Task Boundary ADR (ADR-023)
**Scope**: Author ADR-023 at private repo `docs/adrs/023-workflow-task-boundary.md` formalising three behavioural commitments (workflows compile to tasks; `TaskExecutor._isWorkflowOrchestrated` branching is intentional; `dartclaw_workflow` writes to `TaskRepository` directly inside `executionTransactor.transaction()` to atomically insert the three-row `Task` + `AgentExecution` + `WorkflowStepExecution` chain). Builds on ADR-021 and ADR-022.
**Asset refs**: ADR-021 · ADR-022 · private repo `docs/architecture/workflow-architecture.md` §13 · doc review private repo `docs/adrs/023-workflow-task-boundary-doc-review-codex-2026-04-21.md`

#### [P] S28: Workflow↔Task Import Fitness Test
**Scope**: Add a fitness test at `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` that scans `packages/dartclaw_workflow/lib/src/**` for forbidden `package:dartclaw_server/*` and `package:dartclaw_storage/*` imports; uses `dart:io` + `package:test` only, no new deps. Two known `dartclaw_storage` violations (`workflow_service.dart:26`, `workflow_executor.dart:54`) are documented in an explicit `_knownViolations` allowlist tagged for closure by S12.
**Asset refs**: ADR-023 (S27) · `dev/tools/arch_check.dart:47` · `dev/tools/fitness/check_workflow_server_imports.sh`

---

### Phase 3 (Block C): Interface Extraction

_Parallel-friendly W3 — both stories are independent but benefit from landing before the Block E decomposition so extracted interfaces are available for downstream refactors to depend on._

#### [P] S11: Turn/Pool/Harness Interface Extraction to dartclaw_core
**Scope**: Extract abstract interfaces for `TurnManager`, `TurnRunner`, `HarnessPool`, and `GoogleJwtVerifier` from `dartclaw_server` into `dartclaw_core` (`src/turn/`, `src/auth/`); concrete implementations stay in `dartclaw_server`; `dartclaw_testing` `FakeTurnManager` + `FakeGoogleJwtVerifier` rebind their `implements` clauses to the new interfaces.
**Notes**:
- 2026-05-04 reconciliation: `dartclaw_testing → dartclaw_server` pubspec edge was already removed during 0.16.4 release prep — TD-063 effectively closed; the entry will be deleted at sprint close as backlog hygiene rather than counting toward 0.16.5 closure. The actual interface-extraction work is unchanged.
**Source refs**: FR3 — [`prd.md`](./prd.md)
**Asset refs**: ARCH-002 row

#### [P] S12: WorkflowRunRepository Interface in dartclaw_core
**Scope**: Promote the existing `dynamic`-wrapped `WorkflowRunRepositoryPort` placeholder (in `dartclaw_workflow`) to a proper `abstract interface class WorkflowRunRepository` in `dartclaw_core/lib/src/workflow/`, retarget every consumer (`WorkflowService`, `WorkflowExecutor`, and `TaskExecutor`'s `workflowRunRepository` field) to the abstract interface, and lockstep-update S28's `_knownViolations` allowlist + `dev/tools/arch_check.dart:47` sanctioned-deps.
**Notes**:
- Without the `TaskExecutor` side of the migration, ADR-023's leaky-abstraction smell reappears one package lower (flagged in ADX-01).
**Source refs**: FR3 — [`prd.md`](./prd.md)
**Asset refs**: ARCH-009 finding; 0.16.4 refactor-review finding H2; ADX-01; ARCH-002

#### [P] S32: Promote `ProcessEnvironmentPlan.empty` + `InlineProcessEnvironmentPlan` to `dartclaw_security`
**Scope**: Promote `InlineProcessEnvironmentPlan` as a public class in `dartclaw_security` and add a `ProcessEnvironmentPlan.empty` factory (or `const EmptyProcessEnvironmentPlan()` singleton); promote `buildRemoteOverrideArgs` to a top-level function; delete the two confirmed `_InlineProcessEnvironmentPlan` duplicates (`project_service_impl.dart:48`, `remote_push_service.dart:168`) and retarget call sites. Credential resolution logic stays in `dartclaw_server`.
**Asset refs**: ADX-02 and Seam A; H-D3

#### [P] S31: CliProvider Interface for WorkflowCliRunner
**Scope**: Introduce abstract `CliProvider { Future<WorkflowCliTurnResult> run(CliTurnRequest request); }` with `ClaudeCliProvider` and `CodexCliProvider` implementations that own provider-specific command construction, stdin/stdout parsing, and temp-file cleanup; `WorkflowCliRunner.executeTurn` becomes a ≤60 LOC dispatcher over a `Map<String, CliProvider>`.
**Notes**:
- TD-070 ownership decision is recorded as a dated addendum to ADR-023 (private repo): `WorkflowCliRunner` remains in `dartclaw_server` as the concrete one-shot process adapter, while portable request/value/parsing/settings types move to `dartclaw_core`. A full harness-dispatched rewrite is out of scope.
**Asset refs**: 0.16.4 refactor-review finding M4; post-review file growth (+120 LOC in `d36b860`) raised urgency

---

### Phase 4 (Block D): Pre-decomposition Helpers

_Parallel-friendly W3 — these helper passes (S13 consolidated, plus S30/S33/S34) ship before Block E so the decomposition has less duplication to carry across the split._

#### [P] S13: Pre-Decomposition DRY Helpers + YamlTypeSafeReader
**Scope**: Two pure DRY passes — Part A four `workflow_executor` extractions (`mergeContextPreservingPrivate`, `_fireStepCompleted`/`WorkflowRunMutator`, promote `truncate` to `dartclaw_core/util`, `unwrapCollectionValue`); Part B `YamlTypeSafeReader` typed helpers in `dartclaw_config` + mechanical conversion of 51 inline "Invalid type for …" sites in `config_parser.dart` + the TD-086 mechanical workflow-parser coercion slice (typed reads + field-specific `FormatException`s).
**Notes**:
- Design-heavy TD-086 pieces (duplicate-key policy, max-depth/max-bytes limits, parser-vs-validator semantic-home decision, gate-expression diagnostics) defer to S23 triage unless mechanical during this pass.
- Previously S13 + S14 sharing a composite FIS; consolidated under the 1:1 story↔FIS invariant.
**Asset refs**: M1, M6, SR-6, SR-7, SR-8, SR-9, H5, M7; 0.16.4 review finding L5 (verbatim auto-unwrap duplication across map/foreach); TECH-DEBT-BACKLOG.md TD-086 mechanical parser/coercion slice

> **S14 consolidated into S13 (2026-04-21)** — previously shared composite FIS `s13-s14-pre-decomposition-helpers.md`. Consolidated under the 1:1 story↔FIS invariant enforced by `dartclaw-plan`. FIS renamed to `s13-pre-decomposition-helpers.md`.

#### [P] S33: WorkflowTaskBindingCoordinator Extraction
**Scope**: Lift the abstract `WorkflowTaskBindingCoordinator` interface from the existing concrete `WorkflowWorktreeBinder` into `dartclaw_core/lib/src/workflow/`, ensure `TaskExecutor` and `WorkflowService` depend on the interface, add a fake in `dartclaw_testing`, and drop the redundant `workflowRunId` callback parameter (and reduce its defensive `StateError` guard).
**Notes**:
- 2026-05-04 reconciliation: the bulk of S33's heavy lifting (concrete extraction + delegation from `TaskExecutor` via the `_worktreeBinder` field at `task_executor.dart:146`) already shipped in 0.16.4. Remaining 0.16.5 work narrows to interface lift, fake, and signature polish — risk drops Medium → Low.
- S16's "drop the workflow-shared-worktree concern" is already structurally true (the binder owns them); S16's residual is constructor-parameter reduction + dep-grouping only.
**Asset refs**: ADX-01 + ADX-03 + Seam B/C; M-D5 (growth vector of `TaskExecutor`)

#### [P] S34: Extract `ClaudeSettingsBuilder` + Token-Parse Helper Consolidation
**Scope**: Three consolidations around `workflow_cli_runner.dart` and `claude_code_harness.dart` — Part A extract a shared `ClaudeSettingsBuilder` (~100 LOC of byte-identical helpers) into `dartclaw_core/harness/`; Part B align `_parseClaude`/`_parseCodex` to use `intValue`/`stringValue` from `base_protocol_adapter.dart`; Part C extract a shared `normalizeDynamicMap` helper into a neutral `dartclaw_core` module covering three call sites. Part D centralises private workflow task-config keys (cross-package + workflow-internal + server-side reads) behind a typed/constant accessor surface.
**Notes**:
- Part B does NOT re-fix the Codex token-normalization correctness bug — that is covered by private 0.16.4 S43 FIS. Only the inline-cast → helper-call DRY gap is closed here.
- Part D closes [TD-103](../../state/TECH-DEBT-BACKLOG.md#td-103--refactor-server-side-_workflow-task-config-reads-behind-a-typed-accessor) and consolidates the typed-accessor pattern called out in the 2026-04-17 implementation note's "Out of Scope" section.
- The `permissionMode` drift between harness (accepts six values) and runner (rejects four interactive ones) is preserved: shared parser becomes canonical; runner's stricter validation stays as an explicitly-commented second pass.
**Asset refs**: H-D1, H-D2, L-D1, M-D5; cross-reference to private repo `docs/specs/0.16.4/fis/s43-token-tracking-cross-harness-consistency.md` for the underlying correctness fix

#### ~~S30: Workflow Validator Rule Extraction + Error Helpers~~ — **Retired 2026-04-30**
**Provenance**: Closed by 0.16.4 S44 (rule extraction shipped — six rule files exist under `packages/dartclaw_workflow/lib/src/workflow/validation/`; current `workflow_definition_validator.dart` = 136 LOC, well under the original 0.16.5 ≤400 LOC target). The only residual portion (optional `_err`/`_warn`/`_refErr`/`_contextErr` error-builder helpers) is folded into S23 as a single bullet rather than carrying a dedicated story.
**Asset refs**: 0.16.4 refactor-review findings H5, L4 (closed via S44)

---

### Phase 5 (Block E): Structural Decomposition

_Parallel-friendly W4 — S16, S17, S18 are independent files. S15 depends on S13 (its helper). Engineers/agents can take one each; merges collide only if two touch `server.dart` (S18 only)._

#### S15: Workflow Executor Logical-Library Reduction (post-0.16.4-S45 hotspots)
**Scope**: Post-0.16.4-S45 hotspot reduction across the workflow runtime — (a) `foreach_iteration_runner.dart` ≤900 LOC via `ForeachIterationScheduler` / `PromotionCoordinator` / `MergeResolveCoordinator` extraction (eliminates the eight near-identical recordFailure+persist+inFlightCount-- branches and the ~550 LOC merge-resolve FSM); (b) `context_extractor.dart` ≤600 LOC via 4-way split (filesystem-output resolver, project-index sanitizer, review-finding derivations); (c) `workflow_executor_helpers.dart` ≤400 LOC; (d) underscore-prefixed context-key contract docs; (e) TD-070 executor portion closure; (f) cancellation threading inside `_executeMapStep` / `_executeForeachStep` / `_executeParallelGroup` / `_executeLoop` (H4/H5); (g) `PromotionCoordinator` + `MergeResolveCoordinator` extraction (H10/H11/H12); (h) `execute()` ↔ `_PublicStepDispatcher.dispatchStep()` two-control-flow reconciliation (H1/H2); (i) TD-082 `_waitForTaskCompletion` race fix and TD-088 map/foreach resume audit. Uses S13 helpers; preserves all call sites and public API. **File code-freeze on `foreach_iteration_runner.dart`** during this story.
**Notes**:
- Re-scope rationale (2026-04-30): the original "workflow_executor.dart ≤1,500 LOC" target is already met (current 844 LOC after 0.16.4 S45). The remaining structural work narrows to the new hotspots (foreach runner / context extractor / helpers). 2026-04-30 deeper-review findings (H1/H2/H4/H5/H10/H11/H12/M40) are folded into the new scope. Detail in [`fis/s15-workflow-executor-logical-library-reduction.md`](./fis/s15-workflow-executor-logical-library-reduction.md).
**Asset refs**: ARCH-003 finding; H1 finding; Theme 1; ARCH-003; 2026-04-30 deeper workflow review findings H1, H2, H4, H5, H8, H10, H11, H12, H28, M40 (folded post-S78 hotfix); TECH-DEBT-BACKLOG.md TD-082 and TD-088; private repo `docs/specs/0.16.4/fis/s78-pre-tag-control-flow-correctness.md` (predecessor — S78 closes the four directly-shippable defects; S15 closes the structural tail)

#### S16: Task Executor Residual Cleanup (ctor params + binding handoff)
**Scope**: TaskExecutor residual cleanup — (a) group ~28 named constructor parameters into dep-group structs (`TaskExecutorServices`, `TaskExecutorRunners`, `TaskExecutorLimits` from S38) to reach the ≤12 ceiling enforced by S10's `constructor_param_count_test.dart`; (b) unify any surviving `_markFailedOrRetry` near-duplicates into one `_failForProject(project, reason)` helper; (c) once S33 lands `WorkflowTaskBindingCoordinator`, remove the three `_workflowSharedWorktrees*` maps + the defensive `StateError` callback guard, accepting the coordinator via constructor instead.
**Notes**:
- Re-scope rationale (2026-04-30): the original "task_executor.dart ≤1,500 LOC + decomposition" target is already met (current 790 LOC after 0.16.4 S46). TD-052 is effectively closed; backlog hygiene at sprint close removes the entry.
**Asset refs**: ARCH-004 finding; 0.16.4 S46 closure (`workflow-robustness-refactor/s46-task-executor-decomposition.md`); pairs with S33 (binding coordinator) and S38 (`TaskExecutorLimits` record)

#### [P] S17: service_wiring.dart + cli_workflow_wiring.dart Per-Subsystem Split
**Scope**: Two sibling CLI-side wiring god-method splits — primary `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` (1,415 LOC; `wire()` ~678 LOC) split into per-subsystem `_wireXxx` methods (storage, security, harness, channels, tasks, scheduling, observability, web UI) with a `WiringContext` struct, target ≤800 LOC and `wire()` ≤100 LOC; secondary `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` (945 LOC; `wire()` ~700 LOC) given the same treatment with a `CliWorkflowWiringContext` struct, target ≤600 LOC.
**Notes**:
- Mirrors the 0.12 Phase 0 server-side `ServiceWiring` decomposition (`SecurityWiring`/`ChannelWiring`/`TaskWiring`/`SchedulingWiring`/`StorageWiring`). 2026-05-04 rebaseline: secondary target grew from the original 350-LOC twin estimate during 0.16.4 final-remediation; effort roughly doubles.
**Asset refs**: ARCH-007 finding; H3 finding (SR-10); M-D4 (cli_workflow_wiring twin)

#### [P] S18: DartclawServer Dep-Group Structs + Builder Collapse
**Scope**: Collapse `DartclawServer.compose()` static factory into `DartclawServerBuilder` as the single construction path, replace the ~60 scalar required fields in the private constructor with 6 dep-group structs (suggested: `_ServerCoreDeps`, `_ServerTurnDeps`, `_ServerChannelDeps`, `_ServerTaskDeps`, `_ServerObservabilityDeps`, `_ServerWebDeps`), and bring `server.dart` ≤800 LOC.
**Asset refs**: H4 finding (SR-11)

---

### Phase 6 (Block F): Doc + Hygiene Closeout

_Parallel-friendly W5 — S19 (doc closeout) is a single consolidated story touching disjoint doc files. It lands after all code changes so the documentation reflects the shipped structural work._

#### [P] S19: Doc + Hygiene Closeout
**Scope**: Three independent doc-hygiene passes plus a glossary residual — Part A SDK 0.9.0 framing → `0.0.1-dev.1` placeholder acknowledgement across `docs/sdk/quick-start.md`, `docs/sdk/packages.md`, `examples/sdk/single_turn_cli/README.md`; Part B `docs/guide/configuration.md` schema sync (scheduling.jobs canonical form, channels.google_chat block, `DARTCLAW_DB_PATH` resolution, `memory_max_bytes` → `memory.max_bytes` recipe replacement); Part C per-package + CLI README expansion (`dartclaw_workflow`, `dartclaw_config`, `dartclaw_cli`); Part D `UBIQUITOUS_LANGUAGE.md` glossary residuals — Task Project ID, Resolution Verification, Workflow Run Artifact (TD-072 closure).
**Notes**:
- Lands after code changes so the documentation reflects the shipped 0.16.5 structural work. Consolidates the original S19/S20/S21 stories under the 1:1 story↔FIS invariant.
**Source refs**: FR7 — [`prd.md`](./prd.md)
**Asset refs**: C3, M10, H8, M1, M2, M8, W15, W16, M11 findings; ADR-008; TD-072 (glossary residuals from 0.16.4 final-remediation pass)

> **S20, S21 consolidated into S19 (2026-04-21)** — previously shared composite FIS `s19-s20-s21-doc-closeout.md`. Consolidated under the 1:1 story↔FIS invariant enforced by `dartclaw-plan`. FIS renamed to `s19-doc-closeout.md`.

---

### Phase 7 (Block G): Model & Observability Closeout

_Parallel-friendly W5 for S23 and S24 (hygiene + sidebar are independent). S22 depends on S10 (fitness tests catch regressions during model move). S25 (Level-2 fitness) depends on S10 + S11._

#### S22: dartclaw_models Grab-Bag Migration
**Scope**: Move domain-specific models out of `dartclaw_models` to their owning packages — workflow types (`WorkflowDefinition`, `WorkflowStep`, `WorkflowRun`, `WorkflowExecutionCursor`) → `dartclaw_workflow`; project types (`Project`, `CloneStrategy`, `PrStrategy`, `PrConfig`) → `dartclaw_config`; `TaskEvent` + 9 subtypes → `dartclaw_core` (converting `TaskEventKind` sealed class with 6 empty subclasses → enum with `String get name`, closing TD-053); `TurnTrace`, `TurnTraceSummary`, `ToolCallRecord` → `dartclaw_core`; `SkillInfo` → `dartclaw_workflow`. Bring `dartclaw_models` ≤1,200 LOC. Pair with TD-102 attractor: keep `dartclaw_core/lib/` ≤12,000 LOC by migrating non-runtime-primitive material out, then lower the ratchet back from 13,000 → 12,000 in `dev/tools/arch_check.dart`.
**Notes**:
- 2026-05-04 reconciliation: `dartclaw_models` has grown from 3,005 → 3,555 LOC (`workflow_definition.dart` alone is 1,349 LOC); migration surface is larger than originally scoped, but targets unchanged.
- CHANGELOG migration note required. Decision on a one-release soft re-export from `dartclaw_models.dart` is captured in the FIS.
**Source refs**: FR5 — [`prd.md`](./prd.md)
**Asset refs**: ARCH-005 finding; TD-102 (dartclaw_core ratchet)

#### [P] S23: Housekeeping Sweep + Tech-Debt Mop-Up
**Scope**: Single bundled sweep covering: (1) housekeeping base (format gate verification, `yaml`/`path` dep alignment, audit of 22 production `catch (_)` sites, replace 23 test `Future.delayed(Duration.zero)` with `pumpEventQueue()`, two typed exceptions, super-parameters, `expandHome` unit tests); (2) 0.16.4 review-driven cleanup (R-L1/L2/L6, R-M7/M8 — delete 13 `@Deprecated` shims, add `WorkflowStep.copyWith`, ADR-022 step-outcome warning, workflow test path helpers, `TaskExecutorTestHarness`); (3) tech-debt mop-up (TD-054/055/056/060/061/073/085); (4) delta-review additions (DR-M2/M3, DR-L2 — `FakeProcess` consolidation, `resolveGitCredentialEnv` deletion, dead-private-method sweep); (5) `SkillProvisioner` argument-injection defence (SP-1 ref-shape validation + `--` separators; SP-2 cached-source origin URL re-validation); (6) TD-069/090/089/086 residual triage decisions; (7) S30 error-builder helper residue (63 call sites). Stretch (P2): TD-029 `TemplateLoaderService` seam.
**Notes**:
- Each item is mechanical and individually scoped; the TD additions are filtered to small, independent items aligned with sprint goals (safety, observability, DRY, maintainability).
- Does NOT re-implement the 0.16.4 S43 token-correctness fix; only the DRY gap.
- Detail in [`fis/s23-housekeeping-sweep-and-td-mop-up.md`](./fis/s23-housekeeping-sweep-and-td-mop-up.md).
**Source refs**: FR8 — [`prd.md`](./prd.md)
**Asset refs**: SR-1..SR-5, L-2 findings; M-5 finding; public [`TECH-DEBT-BACKLOG.md`](../../state/TECH-DEBT-BACKLOG.md) TD-029, TD-054, TD-055, TD-056, TD-060, TD-061, TD-069, TD-073, TD-085, TD-086, TD-089, TD-090; 0.16.4 refactor-review findings L1, L2, L6, M7, M8, H4; M-D3, M-D2, L-D2; 0.16.4 closure ledger (TD-069 advisory cluster); 0.16.4 S44 (S30 residue); 2026-04-30 deeper workflow review (H17, H19-H23, H25, M20, M22, M25, H30, H31)

#### S35: Stringly-typed Workflow Flags → Enums
**Scope**: Replace four stringly-typed public flags with proper enums + `fromJsonString` factories that throw `FormatException` listing valid values — (a) `WorkflowStep.type: String` → `WorkflowTaskType` (typing the existing `type` field; S38 owns the later rename to `taskType`); (b) `WorkflowGitExternalArtifactMount.mode` → `WorkflowExternalArtifactMountMode`; (c) `WorkflowGitWorktreeStrategy.mode` → `WorkflowGitWorktreeMode`; (d) `TaskExecutor.identifierPreservation` → `IdentifierPreservationMode`. JSON wire format unchanged; `chat_card_builder.dart` Google Chat wire values explicitly out of scope.
**Asset refs**: Readability 1.1 row; S38 depends on this story for the `taskType` rename (order: S35 introduces enum and types the existing field; S38 renames the field); batch-ship with S22's migration wave for one coherent CHANGELOG entry

#### S36: Public API Naming Batch (`k`-prefix + `get*` renames)
**Scope**: Two Effective-Dart naming corrections batched into one CHANGELOG break — Part A drop `k`-prefix from 6 public constants in `dartclaw_security` (`safe_process.dart`) and `dartclaw_workflow` (`workflow_output_contract.dart`); Part B drop `get` prefix from 10 public methods on service interfaces (or convert to getters) — `ProjectService.getDefaultProject` / `getLocalProject`, `ProviderStatusService.getAll` / `getSummary`, `GowaManager.getLoginQr` / `getStatus`, `PubsubHealthReporter.getStatus`, etc. `getOrCreate*` factories intentionally retain their prefix. Part C ships under a shared "Breaking API Changes" CHANGELOG section with S22's model migration.
**Asset refs**: Effective Dart A1/A2 rows

#### S38: Readability Pack
**Scope**: Five low-cost, high-payoff readability wins bundled into one story — (a) `_logRun(run, msg)` helper in `workflow_executor.dart` collapsing 12+ inline `_log.info("Workflow '${run.id}': $msg")` calls and dropping per-step progression severity from `info` → `fine`; (b) typed `Task.worktree` read-only helper parsing the existing `worktreeJson` field; (c) rename `WorkflowStep.type → taskType` (consuming S35's enum) with `@Deprecated` on the old field and a glossary "Overloaded Terms" update; (d) document the three dir conventions (`dataDir`, `workspaceDir`/`workspaceRoot`, `projectDir`) in the `dartclaw_core` barrel dartdoc, rename `TaskExecutor.workspaceDir` → `workspaceRoot`; (e) `TaskExecutorLimits` record extraction (`compactInstructions`/`identifierPreservation`/`identifierInstructions`/`maxMemoryBytes`/`budgetConfig` quintet) dropping the ctor below S10's ≤12 params threshold.
**Asset refs**: Readability 1.2/1.3/2.1/2.2/3.2/3.3 rows; TD-070 (workflow architecture and fitness carry-overs)

#### [P] S24: SidebarDataBuilder Extraction
**Scope**: Extract a `SidebarDataBuilder` class in `packages/dartclaw_server/lib/src/web/web_routes.dart`, constructed once per-request context and exposing `Future<SidebarData> build({String? activeSessionId})`; inject via `PageContext`; collapse 6 `buildSidebarData(...)` call sites (each currently passing 7-10 named parameters) to `pageContext.sidebar.build(activeSessionId: id)`.
**Asset refs**: M5 finding (SR-14)

#### S25: Level-2 Fitness Functions (6 tests)
**Scope**: Add 6 Level-2 fitness functions as `test/fitness/*.dart` files — (a) `dependency_direction_test.dart` (allowed package edges as data); (b) `src_import_hygiene_test.dart` (no `package:Y/src/...` from `packages/X/lib/`); (c) `testing_package_deps_test.dart` (post-S11 invariant); (d) `barrel_export_count_test.dart` (per-package soft limits — core ≤80, config ≤50, workflow ≤35, others ≤25); (e) `enum_exhaustive_consumer_test.dart` (runtime scan over SSE serializers / `AlertClassifier` / UI badge maps for `WorkflowRunStatus`/`TaskStatus` coverage); (f) `max_method_count_per_file_test.dart` (≤40 methods/file ceiling). Plus TD-046 crash-recovery integration smoke (`@Tags(['integration'])`), TD-074 Homebrew/archive revalidation dry-run, and a fitness-script blackout audit for path-stale silent passes.
**Source refs**: FR4 — [`prd.md`](./prd.md)
**Asset refs**: governance rails rows (Level-2 checks, FF-DELTA-3, FF-DELTA-4)

---

### Phase 8 (Block H): Stretch Documentation Gap-Fill

_Stretch W7 — only if capacity remains after Blocks A–G. The user guide has real gaps but closing them is orthogonal to the stabilisation work._

#### S26: Docs Gap-Fill (pick 2 of 5)
**Scope**: Pick **2 of 5** candidate new or promoted user-guide pages — (a) promote `recipes/08-crowd-coding.md` to `docs/guide/crowd-coding.md`; (b) author `docs/guide/governance.md` (rate limits, budgets, loop detection, `/stop`/`/pause`/`/resume`); (c) author `docs/guide/skills.md` (`SkillRegistry` source priority, frontmatter schema, validation rules); (d) add Workflow Triggers section to `workflows.md`; (e) add Alert Routing + Compaction Observability sections under `web-ui-and-api.md` or new `docs/guide/observability.md`. The other 3 defer to a dedicated docs gap-fill milestone.
**Notes**:
- Concrete dependency list in the Story Catalog reflects "Blocks A–G complete" intent so dependency-aware workflow fan-out cannot start the W7 stretch story before sprint implementation state is current.
**Asset refs**: documentation missing-doc inventory rows

---

## Dependency Graph

```text
Dependency arrows:
S01 ──→ S05 (safety + exhaustiveness baseline feeds event wiring)
S01 + S09 ──→ S10 (L1 fitness functions need both baselines)
S10 ──→ S22 (model migration uses fitness tests as regression net)
S10 + S11 + S12 ──→ S25 (L2 fitness — dep-direction + testing-pkg-deps need stable state)
S13 ──→ S15 (workflow executor decomposition uses DRY helpers)
S22 ──→ S36 (naming batch ships with model migration for one CHANGELOG break)
S33 ──→ S16 (WorkflowTaskBindingCoordinator extraction enables task_executor ctor reduction + map removal)
S22 ──→ S35 (added per cross-cutting review F4: S22 moves WorkflowDefinition + WorkflowStep to dartclaw_workflow; S35 enum-types the migrated field)
S22 ──→ S38 (added per cross-cutting review F4: S38's field rename + dir-naming + TaskExecutorLimits all touch post-S22 file locations)
S35 ──→ S38 (S35 introduces enum and types existing field; S38 renames field to taskType)
Blocks A–G ──→ S26 (stretch docs need current reality — encoded as W7 placement)

Independent (no deps):
S02, S03, S09, S29                 (Block A doc/cleanup quick wins + S09 barrel narrowing + S29 CLI command base, all W1)
S11, S12, S13, S31, S32, S33, S34, S37  (Block C+D interfaces + helpers + delta-review adds — S30 retired)
S17, S18                           (Block E non-workflow splits — S16 now depends on S33)
S19                                (Block F doc closeout)
S23, S24                           (Block G hygiene + sidebar)
S27, S28                           (Block B architectural-hygiene: ADR-023 + boundary fitness test)

Wave assignments:
W1: S01 [P], S02 [P], S03 [P], S09 [P] (barrel narrowing — promoted from W2), S27 [P], S28 [P], S29 [P]
W2: S05 (depends on S01)
W3: S10 (depends on S01 + S09), S11 [P], S12 [P], S13 [P], S31 [P], S32 [P], S33 [P], S34 [P], S37 [P]   (~~S30~~ retired)
W4: S15 (depends on S13 — re-scoped to foreach_iteration_runner + context_extractor + helpers), S16 (depends on S33 — re-scoped to ctor reduction + map removal), S17 [P], S18 [P]
W5: S19 [P], S22 (depends on S10), S23 [P], S24 [P], S35 (depends on S22 — wave-internal ordering per F4), S38 (depends on S22 + S35), S36 (depends on S22)
W6: S25 (depends on S10 + S11 + S12)
W7: S26 (stretch — concrete deps include every non-retired Block A–G story)
```

## Risk Summary

| Story | Risk | Concern | Mitigation |
|-------|------|---------|------------|
| S05 | Medium | 7 events × variable wiring shapes (SSE vs alert vs both) — risk of partial wiring | Per-event wire-up checklist in FIS; exhaustiveness test from S01 prevents regression |
| S09 | Medium | Public API narrowing with downstream fallout in `dartclaw_server` + `dartclaw_cli` | Iterative: first add `show` clauses preserving all symbols, then curate internally-only candidates one at a time; `dart analyze` at each step |
| S10 | Medium | Allowlist shape decisions affect every future PR's feedback loop | Start with permissive allowlists (intentional violators frozen at current state); tighten over future releases; clear "how to resolve" docs per fitness function |
| S11 | High | Cross-package surface move; consumer compatibility risk across fakes + integration tests + server impls | FIS discovery phase: enumerate every consumer of each type via grep + Dart LSP call-hierarchy; derive interface from observed use, not from intuition |
| S15 | High | Most important execution path; defect would silently corrupt workflow state | Strong existing test coverage (2,382 LOC); decomposition preserves call sites; gap-review before merge; fitness functions from S10 catch surface regressions |
| S16 | Medium | Core task lifecycle; defect affects every coding task | Existing task integration tests; preserve call sites; dep-group struct lands atomically with ctor signature change |
| S22 | High | Visible public-API move; cross-package import fallout | Safe window (pub.dev placeholder only, no external consumers); consider one-release soft re-export from `dartclaw_models`; CHANGELOG migration note; S10 fitness tests catch incidental regressions |
| S25 | Medium | L2 fitness depends on post-S11 and post-S12 state; can't land before | Explicit dependency; allowlists let it ship incrementally even if Block G spans multiple sub-releases |

## Execution Guide

This plan ships fully specced — every story already has a FIS (see the `FIS` column).

**Pre-execution gate**: this checked-in plan is pre-FIS. The `dev/specs/0.16.5/fis/` files named in the catalog are planned target filenames and must be generated before any `/dartclaw-exec-spec` invocation. Until those files exist, run the plan/spec generation step rather than treating the paths below as executable commands. (FIS authoring lives in private repo `docs/specs/0.16.5/fis/` — files appear at the public `dev/specs/0.16.5/fis/` location once ported via the `dartclaw-spec-port-to-public` skill at the start of implementation.)

**Per-wave gate** (applies to every wave below): before marking a wave complete, `dart analyze` workspace-wide must show 0 warnings, `dart test` workspace-wide must pass, and `dart format --set-exit-if-changed packages apps` must exit clean. A red wave blocks the next — do not stack decompositions on an unverified base. For Block E waves that touch `foreach_iteration_runner.dart`, `context_extractor.dart`, `workflow_executor_helpers.dart`, or `task_executor.dart`, also run the targeted suites called out in each story's FIS before merging.

1. **Phase 1 (Block A)** — Execute W1 stories (S01, S02, S03, S09) in parallel; each is independent. S09 (barrel narrowing) is mechanical and promoted to W1 so it clears the runway for S10 in W3. Then W2 runs S05 alone (needs S01's test baseline).
2. **Phase 2 (Block B)** — S10 in W3 after S01 + S09 have landed. This is the only governance-rails story that waits.
3. **Phase 3–4 (Blocks C+D)** — W3 parallel cluster alongside S10: S11, S12, S13, S31, S32, S33, S34, and S37 are active; S30 is retired.
4. **Phase 5 (Block E)** — W4 structural decomposition. S15 needs S13; S16 needs S33; S17/S18 are independent. Run as many in parallel as file ownership allows: S15 owns `foreach_iteration_runner.dart`, `context_extractor.dart`, and `workflow_executor_helpers.dart`; S16 owns `task_executor.dart`; S18 owns `server.dart`.
5. **Phase 6 (Block F)** — W5 doc closeout; single consolidated story covering three disjoint doc areas.
6. **Phase 7 (Block G)** — W5 parallel S23+S24+S35, then S22 (needs S10 baseline in place), S38 after S35, and S25 in W6.
7. **Phase 8 (Block H stretch)** — W7 only if capacity remains. Pick 2 of 5 candidate pages based on highest-user-impact.
8. Run `/dartclaw-review --mode gap` after each block's stories complete (the old `andthen:review-gap` standalone skill was absorbed into `dartclaw-review` as a mode — there is no separate gap-only skill in DartClaw).
   - Example: `/dartclaw-review --mode gap dev/specs/0.16.5/plan.md`
9. At sprint close:
   - Update public `dev/state/STATE.md` via the `/dartclaw-update-state` skill: phase → "0.16.6 — Planned (Web UI Stimulus Adoption)"; status → "Planning"; note "0.16.5 Stabilisation & Hardening complete (<N> stories)". (DartClaw has no ported equivalent of `andthen:ops` — state updates use the DC-NATIVE `dartclaw-update-state` skill.)
   - Delete resolved entries from public `dev/state/TECH-DEBT-BACKLOG.md` per its "Open items only" policy (line 3): TD-046, TD-052, TD-053, TD-054, TD-055, TD-056, TD-059 (already resolved by 0.16.4 S42), TD-060, TD-061, TD-063, TD-069, TD-072, TD-073, TD-074, TD-085 at minimum; TD-082/088/090 if S15/S23 close them fully; TD-029 if stretch shipped. Narrow TD-086 and TD-089 to any explicitly-deferred residuals rather than carrying their broad current wording.
   - Update public `dev/state/LEARNINGS.md` with two non-obvious findings: (1) the 8-files claim in the architecture review vs. the current ground truth — a cautionary note about relying on review-reported LOC counts without a sanity check; (2) the 0.16.4-S52 "deferred to TECH-DEBT-BACKLOG" routing was not actioned — only TD-066–TD-072 (from parallel reviews) were filed, while four ledger-routed items (`S28-ARTIFACTS`, `S13-ASSETS`, `TOKEN-EFFICIENCY F4/F5`, `STRUCT-OUTPUT-COMPAT`) sat unbooked for 9 days. Lesson: when a closure-ledger says "routed to backlog", actually file the entry in the same commit.

> **MVP boundary**: The release gate requires Block A + Block B (S01, S02, S03, S05, S09, S10, S27, S28, S29, **S37** — 10 stories) as the release floor — safety, quick wins, governance rails (now including the dartdoc lint-flip), architectural hygiene (ADR-023 + workflow↔task boundary fitness test), CLI command cleanup. Block C–F (S11, S12, S13, S15–S19, S31, **S32, S33, S34** — 12 stories, S30 retired 2026-04-30) are the structural consolidation and should ship; the three delta-review adds (S32 env-plan promotion, S33 binding coordinator, S34 ClaudeSettingsBuilder) are direct pre-reqs or enablers for S11/S15/S16. Block G (S22–S25, **S35, S36, S38** — 7 planned-target stories) is ambitious but pubs-safe now (pub.dev placeholder only) and now also carries the tech-debt mop-up (TD-046/074 in S25; TD-053/054/055/056/060/061/063/069/072/073/085/090 across S11/S22/S23/S03; TD-082/088 in S15; TD-086 split between S13 and S23; TD-029 stretch under S23; TD-052 effectively closed by 0.16.4 S46), 0.16.4 review-driven cleanup items (R-L1/L2/L6, R-M7/M8 under S23), and delta-review Block-G adds (S35 enums, S36 naming, S38 readability). Block H (S26, stretch) is explicitly optional.
>
> **Slip candidates if scope pressure bites**: S35, S36, S38 are the three delta-review Block-G adds least critical to 0.16.6 (Stimulus adoption). If they slip, they move forward into 0.16.6 rather than a 0.16.5.1 patch. S32/S33/S34 are NOT slip candidates — they are structural pre-reqs.

## Story Consolidation Note

Three story groups were consolidated on 2026-04-21 to align with the 1:1 story↔FIS invariant enforced by `dartclaw-plan` (AndThen 0.14.0 re-port removed THIN/COMPOSITE/shared-FIS classification; every row in the Story Catalog is now a unique-key pairing of one story to one FIS). Each group consolidated had stories sharing implementation surface that the new Consolidation Pass would have merged at planning time:

- **S03** (Doc Currency Critical Pass) ← merge of the original S03/S04/S06/S07 (4 doc-edit stories touching top-level public-repo docs). Planned FIS: `fis/s03-doc-currency-critical.md`
- **S13** (Pre-Decomposition DRY Helpers + YamlTypeSafeReader) ← merge of the original S13/S14 (2 DRY-helper passes enabling Block E's decomposition). Planned FIS: `fis/s13-pre-decomposition-helpers.md`
- **S19** (Doc + Hygiene Closeout) ← merge of the original S19/S20/S21 (3 doc closeout passes landing after code changes). Planned FIS: `fis/s19-doc-closeout.md`

All other stories get their own dedicated FIS files, mapped to their story IDs. Tech-debt items inside S23 stay inside S23's FIS (as enumerated sub-checklist items) rather than separate files — they are too small to warrant per-item FIS overhead.

---

## Inline Reference Summaries

The summaries below capture load-bearing private-repo artefacts that this plan depends on. They are integrated here so a reader of the public spec can understand the substance without crossing into the private repo. Each summary ends with a pointer to the canonical source.

### ADR-008 — SDK Publishing Strategy

Status: Accepted (revised 2026-03-12). Decision: name-squat the `dartclaw` package on pub.dev as `0.0.1-dev.1` (published 2026-03-01, transferred to verified publisher), with the first real release at `0.5.0` once `InputSanitizer`, `MessageRedactor`, and `UsageTracker` join the public API surface. The 2026-03-12 revision publishes **all** workspace packages — including `dartclaw_server` and `dartclaw_cli` — as **reference implementations** under the "build your own agent" philosophy: SDK packages (`dartclaw_core`, `dartclaw_models`, `dartclaw_storage`) are composable building blocks, while server and CLI are *one composition* developers can study, fork, or extend. Proprietary integrations (custom channels, guards, deployment configs) live in **separate private repos as overlays** that depend on the published packages — they extend via abstract interfaces (`Channel`, `Guard`, `SearchBackend`) rather than modifying the public packages. Versioning follows the Dart pre-1.0 convention (`0.BREAKING.FEATURE`), all packages share a coordinated version. The 0.5 core/storage split landed 2026-03-03: sqlite3 cleanly isolated to `dartclaw_storage` (2 source files), `dartclaw_core` is sqlite3-free, and the `dartclaw` umbrella re-exports both. (Full rationale, alternatives considered, and revision history: private repo `docs/adrs/008-sdk-publishing-strategy.md`.)

### ADR-021 — AgentExecution Primitive

Status: Accepted — 2026-04-19. Decision: extract `AgentExecution` (provider/session/model/workspace/token-budget runtime state) and `WorkflowStepExecution` (workflow-only metadata) as first-class rows below `Task`, replacing the previous mix of task-owned columns, workflow-private `_workflow*` blobs persisted inside `Task.configJson`, and runtime-only state reconstructed inside `TaskExecutor`. The resulting structure is `Task → agentExecutionId → AgentExecution`; `Task → workflowStepExecution → WorkflowStepExecution`; `WorkflowStepExecution → agentExecutionId → AgentExecution`. `Task.toJson()` now exposes nested `agentExecution` and `workflowStepExecution` objects rather than duplicating those fields at the top level. Five fitness functions enforce the decomposition mechanically. Consequences: `Task` keeps task-owned lifecycle/review/artifact/worktree concerns; `AgentExecution` owns runtime metadata that can outlive any single task shape; `WorkflowStepExecution` owns workflow-only metadata that used to live in `_workflow*` task JSON; `TaskExecutor` no longer reconstructs workflow context from scattered task fields. (Full rationale and alternatives considered: private repo `docs/adrs/021-agent-execution-primitive.md`.)

### ADR-022 — Workflow Run Status Split + Step Outcome Protocol

Status: Accepted — 2026-04-20. Decision: two coupled changes. (1) Split workflow run status into `paused` (deliberate operator holds only), `awaitingApproval` (approval-gated and `needsInput` holds), and `failed` (runtime, gate, and step failures) — replacing the previous overloaded `paused` that conflated operator pauses, approval waits, and real failures. (2) Add a portable step-outcome protocol: the executor automatically appends a `<step-outcome>{"outcome":"succeeded|failed|needsInput","reason":"..."}</step-outcome>` instruction unless a step or skill opts out with `emitsOwnOutcome: true`. The executor writes semantic outcome state into workflow context as `step.<id>.outcome` and `step.<id>.outcome.reason`. If the marker is missing, the executor falls back to task lifecycle status, **logs a warning, and increments `workflow.outcome.fallback`** (the missing-warning behaviour is what S23 R-L1 closes). The protocol is portable across harnesses because it is plain text, not provider-specific structured-completion metadata. Consequences: failed runs gain an explicit retry path (`WorkflowService.retry`, HTTP route, CLI command, Retry UI); gate expressions reason about semantic step outcome without changing the gate evaluator; legacy persisted `paused` rows required a one-shot migration. (Full rationale and alternatives considered: private repo `docs/adrs/022-workflow-run-status-and-step-outcome-protocol.md`.)

### ADR-023 — Workflow ↔ Task Architectural Boundary

Status: Accepted — 2026-04-21. Context: DartClaw runs two orchestration subsystems on the same runtime — the workflow engine in `dartclaw_workflow` and the task orchestrator in `dartclaw_server/src/task/*`. ADR-021 reshaped the data layer (extracting `AgentExecution`/`WorkflowStepExecution` so workflow state no longer round-trips through `Task.configJson`); ADR-022 introduced the portable `<step-outcome>` protocol so gate evaluation does not infer intent from task lifecycle state. ADR-023 names the **behavioural** contract those data-layer ADRs depend on. Decision: three commitments are intentional, not refactor targets. (1) **Workflows compile to tasks.** Every workflow agent step creates a `Task`; the workflow engine does not own a parallel execution stack for agent work. `bash` and `approval` are zero-task by design. The `foreach` controller is also host-executed and zero-task, but its child agent steps still compile to tasks. (2) **`TaskExecutor` is workflow-aware and routes deliberately.** `_isWorkflowOrchestrated(task)` and the `_executeWorkflowOneShotTask()` path (via `WorkflowCliRunner`) are intentional — workflow-orchestrated tasks execute as one-shot CLI invocations rather than via the interactive harness pool because a workflow step is a bounded prompt-chain, not a long-lived conversation. The interactive path remains the default for everything else. (3) **`dartclaw_workflow` may write to `TaskRepository` directly.** `TaskService.create()` is intentionally bypassed for the narrow purpose of atomically inserting the three-row chain (`Task` + `AgentExecution` + `WorkflowStepExecution`) in a single transaction (`workflow_executor.dart:2585-2589`, inside `executionTransactor.transaction()`). All reads and lifecycle transitions still go through the narrow `WorkflowTaskService` interface defined in `dartclaw_core`; the direct-insert affordance is scoped to creation and must not be widened. Consequences: `TaskExecutor` carries two execution paths that must stay synchronized for cross-cutting concerns (cancellation, timeout, artifact capture, progress events); the direct-insert affordance is a narrow exception that needs a fitness function (S28) to stay narrow. (Full rationale and alternatives considered: private repo `docs/adrs/023-workflow-task-boundary.md`. Doc review: private repo `docs/adrs/023-workflow-task-boundary-doc-review-codex-2026-04-21.md`.)

### Architecture deep-dives (orientation only)

The plan header references `system-architecture.md`, `workflow-architecture.md`, and `security-architecture.md` for orientation only — none of those documents are load-bearing for any specific story in this milestone, with the single exception of `workflow-architecture.md` §13 (Relationship to Task Executor), whose substance is captured by ADR-023 above. The full architecture deep-dives live in private repo `docs/architecture/`.

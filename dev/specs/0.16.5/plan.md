# Implementation Plan: DartClaw 0.16.5 — Stabilisation & Hardening

> **PRD**: [`prd.md`](./prd.md)
> **Source review provenance**: see "Source Reviews & Finding ID Conventions" below for the ID glossary; original source-review files were consolidated into this PRD/plan and removed to prevent stale-report drift.
> **ADRs**: ADR-008 — SDK publishing strategy. Behavioural ADR-021 (AgentExecution primitive), ADR-022 (workflow run status + step-outcome protocol), and ADR-023 (workflow↔task architectural boundary) are also load-bearing for this milestone. All four are summarised in the "Inline Reference Summaries" appendix at the end of this plan; canonical sources live in private repo `docs/adrs/008-...`, `021-...`, `022-...`, `023-...`.
> **Tech debt**: [`TECH-DEBT-BACKLOG.md`](../../state/TECH-DEBT-BACKLOG.md) — expanded TD set folded into this sprint or explicitly narrowed (see PRD FR3/4/5/8 and S13/S15/S23/S25 below), plus the 0.16.4 final-remediation workflow/task-boundary carry-over (TD-070) absorbed into existing S15/S31/S34 scope without adding a new story (executor LOC closure is conditional on S15's decomposition outcome — see S15 AC)
> **Architecture**: deep-dive docs (system / workflow / security) live in private repo `docs/architecture/` — `system-architecture.md`, `workflow-architecture.md`, `security-architecture.md`. §13 of `workflow-architecture.md` is the load-bearing section for this milestone (workflow ↔ task relationship; its substance is captured by ADR-023 in the appendix below).
> **Technical Research**: [`.technical-research.md`](./.technical-research.md)
> **Next milestone**: 0.16.6 — Web UI Stimulus Adoption (private repo: `docs/specs/0.16.6/prd.md`)

## Overview

- **Total stories**: 29 planned-target + 1 stretch (30 total) — _down from 30 planned-target stories to 29 after the 2026-04-30 0.16.4-overlap audit retired S30 (validator already split by 0.16.4 S44) and re-scoped S15/S16 (executor + task-executor file-LOC targets already met by 0.16.4 S45/S46; remaining work narrows to new hotspots). Release-floor breakdown: Block A+B 10; planned-target remainder: Block C–F 12 + Block G 7; Block H stretch S26 = 1._
- **Phases**: 8 (Block A Safety + Quick Wins → Block B Governance Rails → Block C Interface Extraction → Block D Pre-decomposition Helpers → Block E Structural Decomposition → Block F Doc + Hygiene Closeout → Block G Model & Observability Closeout → Block H Stretch Docs Gap-Fill)
- **Waves**: 7 (W1 … W7) — S09, S27, S28, S29 in W1
- **Tech-debt items closed by 0.16.5 stories**: 17 planned-target — TD-046 (S25), TD-053 (S22/FR5), TD-054/055/056/060/061/069/073/085 (S23), TD-063 (S11/FR3 — already met by 0.16.4; counted as cleanup), TD-072 split across S03+S29, TD-074 (S25 release closeout), TD-082/088 (S15), **TD-102** (S22 — absorbed 2026-05-04), **TD-103** (S34 Part D — absorbed 2026-05-04). **Narrowed by explicit decision** (3): TD-086 mechanical parser-coercion slice closed in S13 with semantic residuals narrowed; TD-089 triaged in S16/S23; TD-090 triaged in S23. **Stretch** (+1): TD-029 in S23. **Backlog hygiene at sprint close (NOT counted toward 0.16.5 closure)**: delete TD-052 (closed by 0.16.4 S46) and TD-059 (already marked Resolved by 0.16.4 S42) per the "Open items only" policy — these are 0.16.4-closure residue that escaped the previous milestone's hygiene pass, not 0.16.5 work. See PRD FR3/4/5/8.
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
| S01 | AlertClassifier Safety Fix + Event Exhaustiveness Test | A: Safety + Quick Wins | W1 | – | [P] | Low | Spec Ready | `fis/s01-alert-classifier-safety.md` |
| S02 | canvas_exports Advisor Re-export Cleanup | A: Safety + Quick Wins | W1 | – | [P] | Low | Spec Ready | `fis/s02-canvas-exports-advisor-cleanup.md` |
| S03 | Doc Currency Critical Pass (AGENTS.md + README + guide fixes + package trees) | A: Safety + Quick Wins | W1 | – | [P] | Low | Spec Ready | `fis/s03-doc-currency-critical.md` |
| S05 | Wire 7 Orphan Sealed Events (SSE + Alert Mapping) | A: Safety + Quick Wins | W2 | S01 | No | Medium | Spec Ready | `fis/s05-wire-orphan-sealed-events.md` |
| S09 | dartclaw_workflow Barrel Narrowing | B: Governance Rails | W1 | – | [P] | Medium | Spec Ready | `fis/s09-dartclaw-workflow-barrel-narrowing.md` |
| S10 | Level-1 Governance Checks (6 tests + format gate) | B: Governance Rails | W3 | S01, S09 | No | Medium | Spec Ready | `fis/s10-level-1-governance-checks.md` |
| S11 | Turn/Pool/Harness Interface Extraction to dartclaw_core | C: Interface Extraction | W3 | – | [P] | High | Spec Ready | `fis/s11-turn-pool-harness-interface-extraction.md` |
| S12 | WorkflowRunRepository Interface in dartclaw_core | C: Interface Extraction | W3 | – | [P] | Low | Spec Ready | `fis/s12-workflow-run-repository-interface.md` |
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

## Phase Breakdown

### Phase 1 (Block A): Safety + Quick Wins

_Parallel-friendly W1 cluster — each quick-win story is independent and can execute concurrently. S05 (event wiring) waits for S01 (classifier + exhaustiveness test) so the test harness is ready when S05's new mappings land._

#### [P] S01: AlertClassifier Safety Fix + Event Exhaustiveness Test
**Status**: Spec Ready
**FIS**: `fis/s01-alert-classifier-safety.md`
**Phase**: Block A: Safety + Quick Wins
**Wave**: W1
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low
**Scope**: Extend `AlertClassifier.classifyAlert` in `packages/dartclaw_server/lib/src/alerts/alert_classifier.dart` to cover `LoopDetectedEvent` (critical severity) and `EmergencyStopEvent` (critical severity). **Convert the classifier body from the current if-is ladder to an exhaustive `switch (event)` expression** over the `sealed DartclawEvent` hierarchy — the compiler enforces exhaustiveness, eliminating the need for a custom runtime test. Apply the same switch-expression conversion to `AlertFormatter._body`/`_details` in `alert_formatter.dart`. Events that legitimately don't alert use a `// NOT_ALERTABLE: <reason>` annotation on the event class declaration, and the switch returns null for those variants. Excluded: alert body/severity tuning for other events (that's their individual stories).
**Acceptance Criteria**:
- [ ] `classifyAlert` returns a critical-severity `AlertClassification` for both `LoopDetectedEvent` and `EmergencyStopEvent` (must-be-TRUE)
- [ ] `classifyAlert` body is a `switch (event)` expression with one arm per `DartclawEvent` sealed subtype; compiler exhaustiveness applies (must-be-TRUE)
- [ ] `AlertFormatter._body` + `_details` use the same exhaustive switch-expression pattern (must-be-TRUE)
- [ ] Introducing a new `DartclawEvent` subtype without a switch arm fails compilation (not a runtime test — by design) (must-be-TRUE)
- [ ] `NOT_ALERTABLE` annotation comment present on every sealed subtype whose switch arm returns `null`, explaining why no alert
**Key Scenarios**:
- Happy: `EmergencyStopEvent` fires → `classifyAlert` returns critical → `AlertRouter` delivers to configured target
- Edge: a new `Foo*Event` added without switch coverage → `dart analyze` reports a non-exhaustive switch at the classifier site
- Error: a safety-event handler returning wrong severity is still possible — the unit test suite checks representative severities for the known safety events, but the "missing coverage" case is delegated to the compiler
**Asset refs**: safety alerting rows (Unified C-1, Gaps C-1, Effective Dart C1; switch-expression replaces custom exhaustiveness test)

#### [P] S02: canvas_exports Advisor Re-export Cleanup
**Status**: Spec Ready
**FIS**: `fis/s02-canvas-exports-advisor-cleanup.md`
**Phase**: Block A: Safety + Quick Wins
**Wave**: W1
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low
**Scope**: Delete the advisor re-export block at `packages/dartclaw_server/lib/src/canvas/canvas_exports.dart:1-14`. Update `service_wiring.dart` to direct-import `AdvisorSubscriber` from `src/advisor/advisor_subscriber.dart`. Remove the 10 orphan re-exports (`AdvisorOutput`, `AdvisorStatus`, `AdvisorTriggerContext`, `AdvisorTriggerType`, `CircuitBreaker`, `ContextEntry`, `SlidingContextWindow`, `TriggerEvaluator`, `AdvisorOutputParser`, `AdvisorOutputRouter`, `renderAdvisorInsightCard`). Verify no downstream consumer breaks via `dart analyze`.
**Acceptance Criteria**:
- [ ] `canvas_exports.dart` advisor re-export block is removed (must-be-TRUE)
- [ ] `service_wiring.dart` still imports and wires `AdvisorSubscriber` correctly (must-be-TRUE)
- [ ] `dart analyze` workspace-wide is clean (must-be-TRUE)
- [ ] No test failures in advisor-related suites
**Asset refs**: H-1 finding

#### [P] S03: Doc Currency Critical Pass
**Status**: Spec Ready
**FIS**: `fis/s03-doc-currency-critical.md`
**Phase**: Block A: Safety + Quick Wins
**Wave**: W1
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low
**Scope**: One coordinated currency sweep across four co-located top-level public-repo doc surfaces that all reflect the same 0.16.4 ground truth. Consolidates what were previously four separate stories (S03 AGENTS.md, S04 README, S06 guide fixes, S07 package trees) sharing a composite FIS — merged under the 1:1 story↔FIS invariant.
**Note (2026-05-04 reconciliation)**: parts (a) and (b) below were largely satisfied by 0.16.4 release-prep doc updates (2026-05-01 STATE entry: `CHANGELOG dartclaw_workflow version line corrected, STATE.md trimmed to released state, ROADMAP.md advanced to 0.16.5 active`, etc.). Remaining work for (a) is small additive edits, not a rewrite; remaining work for (b) is a final tone/content verification pass.
**(a) AGENTS.md** — `AGENTS.md` already mirrors `CLAUDE.md` in scope (multi-harness Claude + Codex language, all 12 workspace packages listed, no `0.9 Phase A` / `Bun standalone` residue). Remaining: (a1) **add** the explicit "Current milestone: 0.16.5 — Stabilisation & Hardening" line under the project overview (or wherever the milestone callout lives in `CLAUDE.md`); (a2) **add** the explicit assertion: "AGENTS.md is the standard instruction file for ALL non-Claude-Code agents, not DartClaw-specific." (a3) Verification grep pass: confirm no stale "0.9", "Bun standalone", or "Phase A" strings remain after the additions.
**(b) README refresh** — `README.md` banner already says `v0.16.4`. Remaining: (b1) verify the one-line description under the banner accurately reflects 0.16.4 scope (connected-by-default workflow execution, operational CLI command groups, workflow trigger surfaces — web launch forms, `/workflow` chat commands, GitHub PR webhooks); (b2) trim if drift snuck in.
**(c) Four high-impact guide fixes** — Targeted fixes in the user guide. (c1) `docs/guide/web-ui-and-api.md:548` — remove the "Deno worker" reference (NanoClaw-era artifact); describe the in-process MCP server inside the Dart host via JSONL control protocol. (c2) `docs/guide/configuration.md:467` — change `agent.claude_executable` → `providers.claude.executable`; drop the old key unless it's a documented back-compat alias. (c3) `docs/guide/whatsapp.md:51` — change pairing page port from `3000` to `3333`. (c4) `docs/guide/customization.md:91-107` — rewrite the custom-guard example against the real `Guard` + `GuardVerdict` API (sealed `GuardPass`/`GuardWarn`/`GuardBlock`), verify the snippet compiles.
**(d) Package tree updates** — Add missing package rows to public-repo package trees. `README.md:75-94` currently lists 9 packages — add `dartclaw_workflow`, `dartclaw_testing`, `dartclaw_config`. `docs/guide/architecture.md:99-142` currently says "eleven packages" and omits `dartclaw_workflow` from the tree — add the package row and bump count to "twelve packages".
**(e) UBIQUITOUS_LANGUAGE.md drift sweep** (added 2026-04-30 from TD-072 item 2) — three glossary entries in `dev/state/UBIQUITOUS_LANGUAGE.md` are stale post-0.16.4 S73/S74: (e1) "Task Project ID" still says workflow tasks "derive it from workflow-level or step-level project binding" — drop the "or step-level" clause; per-step `project:` was rejected in S74. (e2) "Resolution Verification" still describes "project format / analyze / test commands when declared", reflecting the pre-S73 verification config block that was removed in 0.16.4 — rewrite to match the S73 project-convention discovery + marker / `git diff --check` fallback contract. (e3) "Workflow Run Artifact" entry says "8-field record per merge-resolve invocation" but the shipped artifact is 9 fields per workflow-requirements-baseline §5 — update field count.
**Acceptance Criteria**:
- [ ] `AGENTS.md` says "Current milestone: 0.16.5 — Stabilisation & Hardening" (must-be-TRUE) — additive edit
- [x] Multi-harness model is described in `AGENTS.md` (Claude + Codex + HarnessFactory/HarnessPool) — **already met by 0.16.4** (verify only)
- [x] `AGENTS.md` lists all 12 packages + `dartclaw_cli` app — **already met by 0.16.4** (verify only)
- [x] No references remain in `AGENTS.md` to "Bun standalone binary", "0.9 Phase A", or pre-0.9 package layout — **already met by 0.16.4** (re-grep at FIS exec)
- [ ] `AGENTS.md` contains the explicit statement: "AGENTS.md is the standard instruction file for ALL non-Claude-Code agents" (must-be-TRUE) — additive edit
- [x] `README.md` line 8 shows `v0.16.4` — **already met by 0.16.4** (verify only)
- [ ] `README.md` description reflects 0.16.4 CLI-operations and connected-workflow scope (must-be-TRUE) — verify-and-trim pass
- [ ] Each of the 4 guide fixes (web-ui-and-api, configuration, whatsapp, customization) is applied (must-be-TRUE)
- [ ] `customization.md` guard example compiles against the real `dartclaw_security` API (test-compile during FIS execution) (must-be-TRUE)
- [ ] No stray references to removed patterns ("Deno worker", `agent.claude_executable`, port 3000 for pairing) remain
- [ ] `README.md` package tree lists all 12 packages + `dartclaw_cli` app (must-be-TRUE)
- [ ] `architecture.md` says "twelve packages" and shows `dartclaw_workflow` in the tree (must-be-TRUE)
- [ ] One-line descriptions for the added packages match their respective READMEs
- [ ] **UBIQUITOUS_LANGUAGE.md "Task Project ID"** entry no longer mentions "or step-level project binding" (must-be-TRUE)
- [ ] **UBIQUITOUS_LANGUAGE.md "Resolution Verification"** entry describes the S73 project-convention contract (no "format/analyze/test commands when declared") (must-be-TRUE)
- [ ] **UBIQUITOUS_LANGUAGE.md "Workflow Run Artifact"** entry says **9-field** record (not 8) (must-be-TRUE)
- [ ] TD-072 item 2 (glossary cluster) is closed; entry in public `dev/state/TECH-DEBT-BACKLOG.md` updated to remove the closed item (or deleted if both items 1+2 close together — see S29)
**Asset refs**: C1, C2, H4, H5, H6, H7, H9, M6 findings; `CLAUDE.md` as AGENTS.md mirror source; TD-072 item 2 (UBIQUITOUS_LANGUAGE.md drift)

#### S05: Wire 7 Orphan Sealed Events (SSE + Alert Mapping)
**Status**: Spec Ready
**FIS**: `fis/s05-wire-orphan-sealed-events.md`
**Phase**: Block A: Safety + Quick Wins
**Wave**: W2
**Dependencies**: S01
**Parallel**: No
**Risk**: Medium — cross-cutting change across AlertClassifier + workflow_routes + SSE envelope
**Scope**: Wire consumers for all 7 orphan sealed events. (a) `LoopDetectedEvent` — S01 handles classify; add SSE broadcast in the appropriate route. (b) `EmergencyStopEvent` — SSE broadcast + critical alert (via S01's classify path). (c) `TaskReviewReadyEvent` — SSE broadcast (the UI already renders; only the bridge is missing). (d) `AdvisorInsightEvent` — SSE broadcast + `classifyAlert` mapping: warning severity on `status: stuck`, critical on `concerning`, info on `on_track | diverging` (no delivery for info). (e) `CompactionStartingEvent` — SSE broadcast paired with existing `CompactionCompletedEvent`. (f) `MapIterationCompletedEvent` + (g) `MapStepCompletedEvent` — SSE broadcast via `workflow_routes.dart` mirroring existing `LoopIterationCompletedEvent` / `ParallelGroupCompletedEvent` handlers. Excludes: new UI components (SSE only; UI work deferred to Block H stretch if needed).
**Acceptance Criteria**:
- [ ] Every one of the 7 listed events has at least one production listener (SSE, alert, or both) (must-be-TRUE)
- [ ] Exhaustiveness test from S01 remains green (must-be-TRUE)
- [ ] `AdvisorInsightEvent` with `status: stuck` triggers a warning alert; `concerning` triggers critical; `on_track` / `diverging` do not alert (must-be-TRUE)
- [ ] `workflow_routes.dart` handles `MapIterationCompletedEvent` and `MapStepCompletedEvent` mirroring sibling events
- [ ] Existing SSE envelope format is unchanged (no breaking protocol change)
**Key Scenarios**:
- Happy: admin runs `/stop` → `EmergencyStopEvent` fires → classified critical → alert delivered + SSE broadcast → dashboard reflects
- Edge: advisor fires with `status: on_track` → SSE broadcast → no alert (info-only path)
- Error: workflow in map-step iteration fires `MapIterationCompletedEvent` → SSE subscribers receive in real time
**Asset refs**: H-2 finding; `packages/dartclaw_server/lib/src/advisor/advisor_subscriber.dart:358-381` (reference wiring pattern for Advisor)

> **S04, S06, S07 consolidated into S03 (2026-04-21)** — the four doc-currency stories (S03 AGENTS.md, S04 README, S06 guide fixes, S07 package trees) previously shared a composite FIS (`s03-s04-s06-s07-doc-currency-critical.md`). Consolidated into a single S03 story under the 1:1 story↔FIS invariant enforced by `dartclaw-plan` (AndThen 0.14.0 re-port). FIS renamed to `s03-doc-currency-critical.md`.

> **S08 removed (2026-04-20)** — the CHANGELOG corrections this story proposed were fixed inline as part of the 0.16.4 closure pass: the 0.16.4 entry skill count reflects the 11-skill end state (S30 unified `review-code` / `review-doc` / `review-gap` into `dartclaw-review`; `spec-plan` was absorbed into `plan`) and the 0.16.3 entry gained the workflow-pack consolidation note. No remaining action for 0.16.5.

#### [P] S29: Workflow CLI Run-ID Command Base Class
**Status**: Spec Ready
**FIS**: `fis/s29-workflow-cli-run-id-command-base.md`
**Phase**: Block A: Safety + Quick Wins
**Wave**: W1
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — mechanical CLI refactor, purely internal
**Scope**: Extract a `WorkflowRunIdCommand` abstract base in `apps/dartclaw_cli/lib/src/commands/workflow/`. Base owns `_config`, `_apiClient`, `_writeLine`, `_exitFn` fields, `_requireRunId()` (currently duplicated in 7 files), `_resolveApiClient()` (same), and a `runAgainstRun(String path, {String verb})` template method that performs the common POST + JSON-or-text output pattern. Collapse `workflow_pause_command.dart` (84 LOC), `workflow_resume_command.dart` (84 LOC), and `workflow_retry_command.dart` (85 LOC) to ~20 LOC each. Move file-private `_serverOverride()` and `_globalOptionString()` helpers (currently duplicated across 8 files) to a shared `cli_global_options.dart` library within `apps/dartclaw_cli/lib/src/commands/` and re-import from `workflow_cancel_command.dart`, `workflow_status_command.dart`, `workflow_show_command.dart`, `workflow_runs_command.dart` too (even where not fully collapsible, the shared helpers remove the file-local copies). Zero behaviour change.

**Added 2026-04-30 — TD-072 item 1**: While `workflow_show_command.dart` is being touched, route `WorkflowShowCommand._runStandalone(...)` through the same `bootstrapAndthenSkills(...)` helper used by `cli_workflow_wiring.dart:190–219` and `service_wiring.dart:196–230`. Currently `--resolved --standalone` builds a transient `SkillRegistryImpl` without provisioning AndThen on first contact, so on a freshly-installed instance where neither `dartclaw serve` nor `dartclaw workflow run` has run, `--resolved` output omits SKILL.md frontmatter defaults until any other workflow command provisions AndThen. Gate the bootstrap call on a `runAndthenSkillsBootstrap` flag for tests that opt out (mirror the `CliWorkflowWiring` pattern). Add a regression test asserting bootstrap fires on first `show --resolved --standalone` invocation.
**Acceptance Criteria**:
- [ ] `WorkflowRunIdCommand` base class exists; `pause`/`resume`/`retry` extend it (must-be-TRUE)
- [ ] `_requireRunId` / `_resolveApiClient` are defined once and shared (must-be-TRUE)
- [ ] `_serverOverride` / `_globalOptionString` live in a single `cli_global_options.dart` module (must-be-TRUE)
- [ ] Net LOC reduction ≥150 across the workflow CLI command files
- [ ] `dart test apps/dartclaw_cli` passes with zero test changes
- [ ] Existing `workflow {pause,resume,retry,cancel,status,show,runs}` CLI invocations produce identical output
- [ ] **TD-072 item 1**: `WorkflowShowCommand._runStandalone(...)` calls `bootstrapAndthenSkills(...)` with a test-gateable flag (must-be-TRUE)
- [ ] **TD-072 item 1**: Regression test asserts AndThen bootstrap fires on first `show --resolved --standalone` invocation on a fresh-install fixture (must-be-TRUE)
- [ ] TD-072 entry updated to remove item 1 (or deleted entirely if S03 closes item 2 in the same sprint)
**Key Scenarios**:
- Happy: `dartclaw workflow pause <run-id>` / `resume` / `retry` / `cancel` all behave identically before/after
- Happy (TD-072): freshly-installed instance runs `dartclaw workflow show --resolved --standalone <name>` first; AndThen provisioning runs; SKILL.md frontmatter defaults appear in resolved output
- Edge: missing run-id argument produces the same error message and exit code
- Error: server returns a non-2xx: same message surfaces to stderr with the same formatting
**Asset refs**: 0.16.4 refactor-review finding H6 (duplicated workflow CLI commands across 7-8 files); TD-072 item 1 (`workflow show --resolved --standalone` AndThen bootstrap)

---

### Phase 2 (Block B): Governance Rails

_Sequential — S10 (fitness functions) waits for S01 (sets up the alertable-events test baseline) and S09 (establishes the barrel-show allowlist baseline). S09 itself has no deps._

#### [P] S09: dartclaw_workflow Barrel Narrowing
**Status**: Spec Ready
**FIS**: `fis/s09-dartclaw-workflow-barrel-narrowing.md`
**Phase**: Block B: Governance Rails
**Wave**: W1 (promoted from W2 — mechanical, no deps, unblocks S10 sooner)
**Dependencies**: –
**Parallel**: [P]
**Risk**: Medium — public API tightening with downstream import fallout
**Scope**: Add `show` clauses to every `export 'src/...'` in `packages/dartclaw_workflow/lib/dartclaw_workflow.dart`. Target ≤35 curated public symbols. Remove candidates that are likely internal-only (e.g. `workflow_definition_source.dart`, `workflow_turn_adapter.dart`, `workflow_template_engine.dart`, `skill_registry_impl.dart`, `shell_escape.dart`, `map_step_context.dart`, `json_extraction.dart`, `dependency_graph.dart`, `duration_parser.dart` — already in `dartclaw_config`, `step_config_resolver.dart`). Fix downstream imports in `dartclaw_server` and `dartclaw_cli` that previously relied on the wholesale exports.
**Acceptance Criteria**:
- [ ] Every `export 'src/...'` in `dartclaw_workflow/lib/dartclaw_workflow.dart` uses a `show` clause (must-be-TRUE)
- [ ] Barrel exposes ≤35 public symbols (must-be-TRUE)
- [ ] `dart analyze` workspace-wide is clean after downstream import fixes (must-be-TRUE)
- [ ] `dart test` workspace-wide passes
**Asset refs**: ARCH-001 finding

#### S10: Level-1 Governance Checks (6 tests + format gate)
**Status**: Spec Ready
**FIS**: `fis/s10-level-1-governance-checks.md`
**Phase**: Block B: Governance Rails
**Wave**: W3
**Dependencies**: S01, S09
**Parallel**: No
**Risk**: Medium — allowlist shape decisions affect every future PR's feedback loop
**Scope**: Add 6 Level-1 fitness test files plus a CI format gate, hosted in `packages/dartclaw_testing/test/fitness/` where test-file checks live. A tiny workspace-root helper script (`dev/tools/run-fitness.sh`) wraps `dart test packages/dartclaw_testing/test/fitness/` so CI and local contributors invoke one command; `dart format --set-exit-if-changed packages apps` runs as the seventh Level-1 governance check in CI, not as a test file. Rationale frozen here so S25 (Level-2) uses the same fitness-test location. (a) `barrel_show_clauses_test.dart` — allowlist current exceptions, fail on new. (b) `max_file_loc_test.dart` — no `lib/src/**/*.dart` > 1,500 LOC; baseline allowlist covers current intentional violators with explicit shrink targets. (c) `package_cycles_test.dart` — zero cycles in workspace package graph. (d) `constructor_param_count_test.dart` — no public ctor > 12 params; allowlist `DartclawServer` until S18 lands. (e) `no_cross_package_env_plan_duplicates_test.dart` — assert `ProcessEnvironmentPlan implements` clauses appear only inside `dartclaw_security`, except for implementations that add concrete credential fields (allowlist: `GitCredentialPlan` in `dartclaw_server`). Catches regression of S32 at PR time. (f) `safe_process_usage_test.dart` — Dart-native promotion of `dev/tools/check_git_process_usage.sh` for structured diagnostics alongside the rest of the fitness suite. **Framing updated 2026-04-30**: 0.16.4 S47 (`WorkflowGitPort`) + S39 (Git Subprocess Env Centralization) already drove production-code occurrences of raw `Process.run('git', ...)` / `Process.start('git', ...)` to zero. This fitness test **freezes that post-S47 baseline** as a regression guard (allowlist: `SafeProcess` itself, `WorkflowGitPort` impl). Removed candidate: `alertable_events_test.dart`; S01 now uses compiler-enforced exhaustive switch expressions instead of a runtime enumeration test. All test files use existing deps (`package:test`, `package:analyzer`, `package:package_config`) — no new dependencies.
**Acceptance Criteria**:
- [ ] 6 Level-1 fitness test files exist and pass; the format gate runs separately in CI (must-be-TRUE)
- [ ] Allowlists are explicit files committed to the repo with rationale comments (must-be-TRUE)
- [ ] CI pipeline runs the Level-1 fitness suite and format gate on every commit (must-be-TRUE)
- [ ] Each fitness function has a documented "how to resolve a failure" section in its own `README.md` or in `TESTING-STRATEGY.md`
- [ ] Adding a new wholesale `export 'src/...'` or a 1,501-LOC file fails the build locally
**Key Scenarios**:
- Happy: developer runs `dev/tools/run-fitness.sh` locally, suite completes in ≤30s, all green
- Edge: developer legitimately needs a 1,600-LOC file; allowlist update process is documented
- Error: a sneaky `export 'src/foo.dart';` in a new PR → `barrel_show_clauses_test.dart` fails with file + line
**Asset refs**: governance rails rows (architecture fitness proposals; PRD/plan H2 count correction)

#### [P] S37: Dartdoc Sweep + `public_member_api_docs` Lint Flip + Internal Dartdoc Trim
**Status**: Spec Ready
**FIS**: `fis/s37-dartdoc-sweep-and-lint-flip.md`
**Phase**: Block B: Governance Rails
**Wave**: W3
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — docs-only; Part C is mechanical with per-package scoping; lint-flip catches Part A/B regressions at PR time; Part C trimming is Boy-Scout-style and safe to defer if scope tightens
**Scope**: Three-part governance-rail story. **Part A — dartdoc sweep for `dartclaw_server` hot-spots**: 26 undocumented public top-level types live in `packages/dartclaw_server/lib/`, with the worst cluster in `advisor_subscriber.dart:648,673,695,703,725` (`AdvisorTriggerType`, `AdvisorStatus`, `AdvisorOutput`, `AdvisorTriggerContext`, `ContextEntry`). Many of these leak through SSE/REST envelopes and into OpenAPI-shaped surfaces. Add one-sentence dartdoc summaries to each (third-person, starts with verb, uses `[Ref]` where a type is referenced). Target: 0 undocumented public top-level declarations in `dartclaw_server/lib/` after the sweep. CLI app (`apps/dartclaw_cli`) is explicitly **not** in scope — application code, not SDK surface. **Part B — enable `public_member_api_docs` in near-clean packages**: Four packages have ≤5 missing dartdoc each — flip the lint on in their `analysis_options.yaml`: `dartclaw_models` (0 missing — already exemplary), `dartclaw_storage` (0 missing), `dartclaw_security` (1 missing), `dartclaw_config` (5 missing). Fix the residual gaps (≤6 total). `dartclaw_core` is close (3 missing) but has a larger public surface — defer lint flip for `dartclaw_core` to 0.17 after a targeted sweep. `dartclaw_workflow` (3 missing) is similarly tractable — flip if time allows; otherwise defer. Each lint flip is a governance rail: new undocumented public declarations fail CI from day one. **Part C — internal dartdoc proportionality + planning-history cleanup**: Apply the new _Proportionality & Anti-Rot_ rules from `docs/guidelines/DART-EFFECTIVE-GUIDELINES.md` to `lib/src/` classes in the four packages touched by Part B, plus `dartclaw_workflow/lib/src/` (where the worst offenders are known to live — e.g. `skill_prompt_builder.dart` has a 30-line class-level dartdoc that restates the `switch` body below, and contains a stale "(S01 integration)" planning reference). Two mechanical passes: (1) **trim internal class/method dartdoc** in `lib/src/` to one-sentence summaries + non-obvious WHY, collapsing multi-case enumerations into named anchors the body references via `// Case N:` inline comments (pattern already present in several files); (2) **strip planning-history references, cleanup-leftover markers, unowned TODOs, and consumer-coupled docstrings** from `///` and `//` comments across all packages via grep — story IDs (`S\d+`), PR numbers (`#\d+`), sprint/wave labels, "added for the X flow", "used by Y flow", `// REMOVED …` / `// was:` / `// previously:` tombstones, bare `// TODO:` without owner or tracking link, and dartdoc paragraphs that document a consumer's behavior at the definition site (e.g. _"is rewrapped by `ServiceWiring.wire()`"_) — replacing durable-justification cases with ADR links. Not a wholesale rewrite: the goal is to remove the obvious bloat the guideline names, not to re-audit every file. Part C is the **slip candidate within S37** — if Parts A + B consume the wave-3 budget, Part C defers to 0.16.6 as a standalone cleanup story.
**Acceptance Criteria**:
- [ ] Zero undocumented public top-level types in `dartclaw_server/lib/` (grep-verified) (must-be-TRUE)
- [ ] `public_member_api_docs` enabled in `dartclaw_models`, `dartclaw_storage`, `dartclaw_security`, `dartclaw_config` `analysis_options.yaml` (must-be-TRUE)
- [ ] `dart analyze` clean in all 4 packages after the sweep (must-be-TRUE)
- [ ] Adding a new undocumented public class to any of the 4 near-clean packages fails `dart analyze` locally
- [ ] Each dartdoc summary is one sentence, third-person, starts with a verb (spot-check)
- [ ] Where a type is referenced by name in prose, it uses the `[TypeName]` bracket syntax (spot-check)
- [ ] `docs/guidelines/DART-EFFECTIVE-GUIDELINES.md` `### Proportionality & Anti-Rot` subsection covers each of: planning-history, control-flow restatement, identifier paraphrasing, multi-paragraph collapse, drift discipline, consumer-coupling, cleanup-leftover markers, unowned TODOs (must-be-TRUE)
- [ ] `rg "(S\d+ integration|S\d+ flow|for the .* flow|used by the .* flow)" packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` returns zero planning-history references in `///` comments (must-be-TRUE)
- [ ] `rg "//\s*(REMOVED|was:|previously:)" packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` returns zero cleanup-leftover markers (must-be-TRUE)
- [ ] `rg --pcre2 "(?<!/)//\s*TODO\b(?!\s*\([^)]+\))" packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` returns zero unowned `// TODO`s (must-be-TRUE; the lookbehind excludes `///` dartdoc, the lookahead matches `// TODO` not followed by `(name)` or `(#issue)` even with intervening whitespace)
- [ ] Consumer-coupled dartdoc paragraphs (documenting a caller's behavior at the definition site, e.g. _"is rewrapped by `ServiceWiring.wire()`"_) removed from `lib/src/` of the 5 targeted packages (spot-check)
- [ ] `skill_prompt_builder.dart` class-level dartdoc ≤ 8 lines; method dartdoc for `build()` ≤ 10 lines (spot-check — illustrative target, not a blanket LOC rule)
- [ ] No new planning-history references introduced (governance: the existing `andthen:quick-review` flow flags these in PR feedback; no new lint added)
**Key Scenarios**:
- Happy: contributor adds a new public class to `dartclaw_models` without dartdoc → CI fails with a pointer to `public_member_api_docs`
- Edge: `dartclaw_server` remains lint-off (too much surface to sweep in one sprint) — explicit scope boundary noted in `analysis_options.yaml`
- Sustainability: lint flip is the forcing function; individual sweeps are one-time cost
- Scope pressure: Parts A + B ship as the non-negotiable governance rail; Part C defers to 0.16.6 as standalone cleanup if W3 budget tightens
**Asset refs**: Effective Dart B1 row; Part C illustrative example: `packages/dartclaw_workflow/lib/src/workflow/skill_prompt_builder.dart` (30-line class dartdoc + "(S01 integration)" planning leak)

#### [P] S27: Workflow↔Task Boundary ADR (ADR-023)
**Status**: Spec Ready (awaiting commit)
**FIS**: `fis/s27-workflow-task-boundary-adr.md`
**Phase**: Block B: Governance Rails
**Wave**: W1 (docs-only, no deps)
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — docs-only ADR; one finding from doc review already addressed (`foreach` controller/child-step wording + fitness-function path correction)
**Scope**: Formalises the behavioural contract between `dartclaw_workflow` and the task orchestrator. Builds on ADR-021 (AgentExecution primitive) and ADR-022 (workflow run status + step outcome protocol), which defined the data-layer decomposition. ADR-023 names three behavioural commitments as intentional: (1) workflows compile to tasks (every agent step creates a `Task`; `bash` and `approval` are zero-task; `foreach` is a zero-task controller whose child agent steps do create tasks); (2) `TaskExecutor._isWorkflowOrchestrated` branching deliberately routes to `WorkflowCliRunner` one-shot execution instead of the interactive harness-pool path; (3) `dartclaw_workflow` writes to `TaskRepository` directly inside `executionTransactor.transaction()` (`workflow_executor.dart:2585-2589`) to atomically insert the three-row `Task` + `AgentExecution` + `WorkflowStepExecution` chain. Lives at private repo `docs/adrs/023-workflow-task-boundary.md`. Doc review report at private repo `docs/adrs/023-workflow-task-boundary-doc-review-codex-2026-04-21.md` — both findings (MEDIUM: foreach precision; LOW: fitness reference path) addressed inline.
**Acceptance Criteria**:
- [ ] `docs/adrs/023-workflow-task-boundary.md` exists in private repo and follows the ADR template (Status / Context / Decision / Consequences / Alternatives / References) (must-be-TRUE)
- [ ] ADR names all three commitments with concrete code-seam references (must-be-TRUE)
- [ ] `foreach` wording distinguishes the zero-task controller from its child agent steps that do create tasks (must-be-TRUE)
- [ ] Fitness-function reference resolves to the existing test at `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` (must-be-TRUE)
- [ ] ADR-021, ADR-022, private repo `docs/architecture/workflow-architecture.md` §13, and S28 fitness test are cross-referenced (must-be-TRUE)
- [ ] Status line reads "Accepted — 2026-04-21"
**Asset refs**: ADR-021 · ADR-022 · private repo `docs/architecture/workflow-architecture.md` §13 · doc review private repo `docs/adrs/023-workflow-task-boundary-doc-review-codex-2026-04-21.md`

#### [P] S28: Workflow↔Task Import Fitness Test
**Status**: Spec Ready (awaiting commit)
**FIS**: `fis/s28-workflow-task-import-fitness-test.md`
**Phase**: Block B: Governance Rails
**Wave**: W1 (independent of S10; uses simpler self-contained approach — no `package:analyzer` dep)
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — standalone test file with documented allowlist; no production-code changes
**Scope**: Enforces the ADR-023 import boundary as a fitness test at `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` (dartclaw-public). Scans every `.dart` file under `packages/dartclaw_workflow/lib/src/**` and asserts no `package:dartclaw_server/*` or `package:dartclaw_storage/*` imports. Uses `dart:io` + `package:test/test.dart` only — no new deps. Current baseline: zero `dartclaw_server` violations (clean); two `dartclaw_storage` violations (`workflow_service.dart:26`, `workflow_executor.dart:54`, both importing `SqliteWorkflowRunRepository`) documented in an explicit `_knownViolations` allowlist tagged for closure by S12. When S12 lands, the allowlist empties in the same PR that removes the imports; `dev/tools/arch_check.dart:47` tightens to drop `dartclaw_storage` from `dartclaw_workflow`'s sanctioned deps in lockstep. Consider retiring `dev/tools/fitness/check_workflow_server_imports.sh` once S10 establishes the Dart fitness suite as the single source of truth.
**Acceptance Criteria**:
- [ ] `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` exists and passes (must-be-TRUE)
- [ ] Zero `dartclaw_server` imports from `dartclaw_workflow/lib/src/**` (must-be-TRUE — clean baseline)
- [ ] `dartclaw_storage` allowlist is documented with file:line + remediation pointer to S12 (must-be-TRUE)
- [ ] `dart analyze packages/dartclaw_testing` clean; `dart format` applied
- [ ] File header comment links ADR-023 and explains how to resolve a legitimate violation (extract an interface to `dartclaw_core`)
**Key Scenarios**:
- Happy: `dart test packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` passes against current main
- Error: a new `import 'package:dartclaw_server/...'` in `dartclaw_workflow/lib/src/` fails with `src/.../file.dart:LINE: forbidden import ...` and an ADR-023 pointer
- Edge (post-S12): S12 removes the two `dartclaw_storage` imports; in the same commit the `_knownViolations` set in this test empties, and `dev/tools/arch_check.dart:47` drops `dartclaw_storage` from the workflow package's sanctioned deps
**Asset refs**: ADR-023 (S27) · `dev/tools/arch_check.dart:47` · `dev/tools/fitness/check_workflow_server_imports.sh`

---

### Phase 3 (Block C): Interface Extraction

_Parallel-friendly W3 — both stories are independent but benefit from landing before the Block E decomposition so extracted interfaces are available for downstream refactors to depend on._

#### [P] S11: Turn/Pool/Harness Interface Extraction to dartclaw_core
**Status**: Spec Ready
**FIS**: `fis/s11-turn-pool-harness-interface-extraction.md`
**Phase**: Block C: Interface Extraction
**Wave**: W3
**Dependencies**: –
**Parallel**: [P]
**Risk**: High — cross-package surface move; consumer compatibility risk
**Scope**: Extract abstract interfaces for `TurnManager`, `TurnRunner`, `HarnessPool`, and `GoogleJwtVerifier` from `dartclaw_server` into `dartclaw_core` (`src/turn/`, `src/auth/`). Concrete implementations remain in `dartclaw_server`. `dartclaw_testing` `FakeTurnManager` + `FakeGoogleJwtVerifier` rebind their `implements` clauses to the new interfaces. **Note (2026-05-04 reconciliation)**: `dartclaw_testing/pubspec.yaml`'s `dartclaw_server` dependency was already removed during 0.16.4 release prep — only `dartclaw_core` is listed under `dependencies:`. TD-063 ([linked](../../state/TECH-DEBT-BACKLOG.md#td-063--dartclaw_testing-depends-on-dartclaw_server)) is therefore effectively closed; the entry will be deleted at sprint close as backlog hygiene rather than counting toward 0.16.5 closure. The actual interface-extraction work is unchanged. Verify every consumer's expectations are met by the derived interface surface (grep + Dart LSP call-hierarchy over each type to enumerate method use).
**Acceptance Criteria**:
- [ ] Four abstract interfaces live in `dartclaw_core` with matching method signatures (must-be-TRUE)
- [x] `dartclaw_testing/pubspec.yaml` no longer declares `dartclaw_server` — **already met by 0.16.4**; verify still met at sprint close
- [ ] `FakeTurnManager` / `FakeGoogleJwtVerifier` implement the new interfaces (must-be-TRUE)
- [ ] `dart analyze` and `dart test` workspace-wide pass
- [ ] `testing_package_deps_test.dart` fitness function (S25) will validate this invariant; in this story, a minimal assertion in `dartclaw_testing/test/fitness_smoke_test.dart` or similar confirms the dep is gone
**Key Scenarios**:
- Happy: every consumer of `TurnManager` (production + fakes + tests) still works via the interface
- Edge: a consumer depends on a concrete method not captured by the interface — FIS discovery phase surfaces this and either widens the interface or narrows the consumer
**Asset refs**: ARCH-002 row

#### [P] S12: WorkflowRunRepository Interface in dartclaw_core
**Status**: Spec Ready
**FIS**: `fis/s12-workflow-run-repository-interface.md`
**Phase**: Block C: Interface Extraction
**Wave**: W3
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — mirrors existing `TaskRepository`/`GoalRepository` pattern
**Scope**: Add an abstract `WorkflowRunRepository` interface to `dartclaw_core` alongside `TaskRepository` and `GoalRepository`. Sqlite implementation (`SqliteWorkflowRunRepository`) remains in `dartclaw_storage`. Every consumer — `WorkflowService`, `WorkflowExecutor`, **and `TaskExecutor` (which currently accepts `SqliteWorkflowRunRepository?` at `task_executor.dart:54,113` and calls into the concrete API)** — depends on the abstract interface, not the concrete storage type. Without the TaskExecutor side of the migration, ADR-023's leaky-abstraction smell reappears one package lower (flagged in ADX-01).
**Note (2026-05-04 reconciliation)**: a partial port already exists at `packages/dartclaw_workflow/lib/src/workflow/workflow_runner_types.dart:69` as `WorkflowRunRepositoryPort` — but it's a `dynamic`-wrapped wrapper inside the wrong package, not a typed abstract interface. The 0.16.5 work is to (1) **promote/rewrite** it as a proper `abstract interface class WorkflowRunRepository` in `dartclaw_core/lib/src/workflow/`, (2) make `SqliteWorkflowRunRepository` `implements` the new interface, (3) migrate `dartclaw_workflow` consumers from the `dynamic`-wrapped port to the typed abstract interface, then (4) delete the placeholder port. `sqlite3` stays in `dartclaw_workflow`'s dev-dependencies for tests that need a real DB. **Fitness test wiring**: S28's `_knownViolations` allowlist empties in the same commit as this migration; `dev/tools/arch_check.dart:47` tightens to drop `dartclaw_storage` from `dartclaw_workflow`'s sanctioned deps in lockstep.
**Acceptance Criteria**:
- [ ] `WorkflowRunRepository` abstract interface in `dartclaw_core/lib/src/workflow/` (or similar) (must-be-TRUE)
- [ ] `SqliteWorkflowRunRepository` in `dartclaw_storage` implements the interface (must-be-TRUE)
- [ ] `dartclaw_workflow` imports `WorkflowRunRepository` from `dartclaw_core` only, not `SqliteWorkflowRunRepository` by name (must-be-TRUE)
- [ ] **`TaskExecutor` accepts `WorkflowRunRepository?` — not `SqliteWorkflowRunRepository?`; the constructor param type changes (currently typed concrete at `task_executor.dart:54,113`), and the two call sites (`task_executor.dart:127,1438`) migrate to the abstract API** (must-be-TRUE)
- [ ] The `dynamic`-wrapped `WorkflowRunRepositoryPort` at `workflow_runner_types.dart:69` is deleted (or, if a wrapper is still needed for staged migration, it `implements` the new typed abstract interface) (must-be-TRUE)
- [ ] S28's `workflow_task_boundary_test.dart` allowlist empties; `dev/tools/arch_check.dart:47` sanctioned-deps list drops `dartclaw_storage` for `dartclaw_workflow` (must-be-TRUE)
- [ ] `dart analyze` and `dart test` workspace-wide pass
**Asset refs**: ARCH-009 finding; 0.16.4 refactor-review finding H2; ADX-01; ARCH-002

#### [P] S32: Promote `ProcessEnvironmentPlan.empty` + `InlineProcessEnvironmentPlan` to `dartclaw_security`
**Status**: Spec Ready
**FIS**: `fis/s32-process-environment-plan-promotion.md`
**Phase**: Block C: Interface Extraction
**Wave**: W3
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — moves one public type + one sentinel; callers unchanged at call-site level
**Scope**: `SafeProcess.git(..., plan: ProcessEnvironmentPlan)` lives in `dartclaw_security`, but every caller that wants an "empty environment" currently has to reach for a sentinel that's stuck in `dartclaw_server` (`GitCredentialPlan` at `packages/dartclaw_server/lib/src/task/git_credential_env.dart:13`) or reinvent it. This has produced **two confirmed duplicates** (verified 2026-04-30): `_InlineProcessEnvironmentPlan` at `project_service_impl.dart:48`; `_InlineProcessEnvironmentPlan` at `remote_push_service.dart:168`. The `_EmptyProcessEnvironmentPlan` at `workflow_executor.dart:128-133` originally cited as a third duplicate **is already gone** as a side-effect of 0.16.4 S45 / S47 (workflow_executor now 835 LOC and uses `WorkflowGitPort` for git calls). Promote `InlineProcessEnvironmentPlan` as a public class in `dartclaw_security/lib/src/process/inline_process_environment_plan.dart` (or `safe_process.dart`), and add a `ProcessEnvironmentPlan.empty` factory (or a `const EmptyProcessEnvironmentPlan()` singleton) to the same library. Promote `buildRemoteOverrideArgs` to a top-level function in `git_credential_env.dart` (or `dartclaw_security` if a cleaner home exists). Delete the two duplicates; retarget call sites at the new public API. Credential *resolution* (`resolveGitCredentialPlan` + `CredentialsConfig` + askpass scripting) legitimately stays in `dartclaw_server` — this story moves only the adapter/sentinel, not the credential logic.
**Acceptance Criteria**:
- [ ] `InlineProcessEnvironmentPlan` exists as public class in `dartclaw_security` (must-be-TRUE)
- [ ] `ProcessEnvironmentPlan.empty` (or equivalent singleton) exists in `dartclaw_security` (must-be-TRUE)
- [ ] Zero `_InlineProcessEnvironmentPlan` private declarations remain outside `dartclaw_security` (must-be-TRUE) — both confirmed duplicates at `project_service_impl.dart:48` and `remote_push_service.dart:168` deleted
- [ ] `buildRemoteOverrideArgs` exists as top-level function in a neutral library; `project_service_impl.dart` + `remote_push_service.dart` both import it
- [ ] S10's `no_cross_package_env_plan_duplicates_test.dart` fitness test (added under S10 expansion) passes
- [ ] `dart analyze` and `dart test` workspace-wide pass
**Key Scenarios**:
- Happy: workflow executor needs empty env for a spawned git subprocess → imports from `dartclaw_security`, no private sentinel
- Edge: `GitCredentialPlan` in server continues to implement `ProcessEnvironmentPlan` directly (it adds credential fields, so it's not a duplicate — it's a genuine implementation)
**Asset refs**: ADX-02 and Seam A; H-D3

#### [P] S31: CliProvider Interface for WorkflowCliRunner
**Status**: Spec Ready
**FIS**: `fis/s31-cli-provider-interface.md`
**Phase**: Block C: Interface Extraction
**Wave**: W3
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — encapsulates an already-branching dispatch with no public-API change
**Scope**: `packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` grew from 515 → 635 LOC during 0.16.4 as Codex support matured; `executeTurn` now has 11 optional parameters and a per-provider switch that mixes process lifecycle, provider-specific command construction, and temp-file management. Introduce `abstract class CliProvider { Future<WorkflowCliTurnResult> run(CliTurnRequest request); }` plus `ClaudeCliProvider` and `CodexCliProvider` implementations. Each implementation owns its `_buildXxxCommand` logic (working-dir translation, container mount wiring, provider-specific stdin/stdout parsing) and temp-file cleanup. `WorkflowCliRunner.executeTurn` becomes a dispatcher on `Map<String, CliProvider>`. Keep `_WorkflowCliCommand` private helper type if still needed, or promote it to a `CliTurnRequest` value object. As part of TD-070, record the ownership decision explicitly: `WorkflowCliRunner` remains in `dartclaw_server` for now as the concrete one-shot process adapter, while portable request/value types and reusable parsing/settings helpers move to `dartclaw_core`; a full harness-dispatched rewrite remains out of scope.
**Acceptance Criteria**:
- [ ] `CliProvider` interface exists with `ClaudeCliProvider`/`CodexCliProvider` implementations (must-be-TRUE)
- [ ] `WorkflowCliRunner.executeTurn` ≤60 LOC and contains no provider-specific branching (must-be-TRUE)
- [ ] Ownership decision documented as a dated addendum section appended to `docs/adrs/023-workflow-task-boundary.md` (private repo; the canonical ADR-023 location): runner remains server-owned concrete adapter; core owns portable request/value/helper types; addendum is cross-referenced from public-repo `docs/architecture/workflow-architecture.md` so public readers can find it (must-be-TRUE)
- [ ] `workflow_cli_runner.dart` total LOC reduced from ~635 toward ~350 (must-be-TRUE)
- [ ] `dart test packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` passes; add a per-provider test where the existing test is implementation-agnostic
- [ ] Adding a future provider (e.g. Ollama) requires adding only a new `CliProvider` class — no edits to `WorkflowCliRunner` itself
**Asset refs**: 0.16.4 refactor-review finding M4; post-review file growth (+120 LOC in `d36b860`) raised urgency

---

### Phase 4 (Block D): Pre-decomposition Helpers

_Parallel-friendly W3 — these helper passes (S13 consolidated, plus S30/S33/S34) ship before Block E so the decomposition has less duplication to carry across the split._

#### [P] S13: Pre-Decomposition DRY Helpers + YamlTypeSafeReader
**Status**: Spec Ready
**FIS**: `fis/s13-pre-decomposition-helpers.md`
**Phase**: Block D: Pre-decomposition Helpers
**Wave**: W3
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — mechanical DRY extractions; `config_parser` portion covered by extensive tests (1,828 LOC)
**Scope**: Two pure DRY passes with no coupling between them, bundled as one story under the 1:1 story↔FIS invariant (previously S13+S14 sharing a composite FIS).

**Part A — workflow_executor DRY helpers** (four one-shot extractions). (a) `mergeContextPreservingPrivate(WorkflowRun run, WorkflowContext context) → Map<String, dynamic>` — replaces the 12–14 duplicated map-spreads in `workflow_executor.dart` that preserve underscore-prefixed internal metadata keys (`_map.current`, `_foreach.current`, `_loop.current`, `_parallel.*`) across context merges. (b) `_fireStepCompleted(stepIndex, success, result)` helper (or equivalent `WorkflowRunMutator.recordStepSuccess/Failure/Continuation`) — replaces 12 duplicated `WorkflowStepCompletedEvent(...)` constructions. (c) Promote `truncate(String, int, {suffix})` from `packages/dartclaw_server/lib/src/templates/helpers.dart` to a new `dartclaw_core/lib/src/util/string_util.dart`. Delete 4 char-count `_truncate` duplicates in favour of the core util. Keep UTF-8-aware byte-truncate variants as separate named functions (`truncateUtf8Bytes`) with clear semantics. (d) `unwrapCollectionValue(Object? raw, {required String stepId, required String mapOverKey}) → List<dynamic>?` — dedupes the two verbatim auto-unwrap switches in `workflow_executor.dart:3285-3303` (map) and `3707-3725` (foreach) that promote a single-entry `Map` with a list value into the iteration collection. Place alongside `mergeContextPreservingPrivate` in a file-local workflow helper module.

**Part B — YamlTypeSafeReader + config_parser conversion + workflow parser coercion (TD-086 mechanical slice)**. Add typed helpers to `packages/dartclaw_config/lib/src/` (likely a new `yaml_type_safe_reader.dart`): `readString`, `readInt`, `readBool`, `readMap`, `readStringList`, plus a generic `T? readField<T>(...)`. Each helper encapsulates the "type-check + warn-and-ignore" pattern. Mechanically convert the 51 inline "Invalid type for …" blocks in `config_parser.dart` to use these helpers. Target: cut `config_parser.dart` by ~300-400 LOC and keep it ≤1,200 LOC. Leave `_parseXxx` function structure unchanged (they just get terser). Also apply the same typed-coercion pattern inside `dartclaw_workflow` YAML parsing for the low-risk TD-086 defects: replace unguarded `as String?` / lazy `raw.cast<String>()` parser paths with eager typed reads that throw a friendly `FormatException` naming the offending field; normalize `extraction.type` / missing `pattern` errors away from `ArgumentError` / `TypeError`. Defer the design-heavy TD-086 pieces (duplicate-key policy, max-depth / max-bytes limits, parser-vs-validator semantic-home decision, and full gate-expression diagnostics) to S23 triage unless they prove mechanical during this pass.
**Acceptance Criteria**:
- [ ] `mergeContextPreservingPrivate` helper exists and is used at all duplicated sites in `workflow_executor.dart` (must-be-TRUE)
- [ ] `_fireStepCompleted` (or `WorkflowRunMutator` method) exists and is used at all 12 sites (must-be-TRUE)
- [ ] `truncate()` lives in `dartclaw_core`; 4 char-count `_truncate` duplicates removed (must-be-TRUE)
- [ ] UTF-8-aware variants remain as separately-named functions with documented byte-vs-char semantics
- [ ] `unwrapCollectionValue` replaces both map- and foreach-step auto-unwrap blocks (must-be-TRUE)
- [ ] `YamlTypeSafeReader` (or equivalent typed helpers) exists in `dartclaw_config` (must-be-TRUE)
- [ ] All 51 inline "Invalid type for …" sites in `config_parser.dart` replaced with helper calls (must-be-TRUE)
- [ ] **TD-086 mechanical parser slice**: workflow parser scalar/list/extraction errors use typed coercion and surface as field-specific `FormatException`s, not raw `TypeError` / `ArgumentError` (must-be-TRUE)
- [ ] `config_parser.dart` LOC reduced by ≥300 (must-be-TRUE)
- [ ] `dart test packages/dartclaw_workflow packages/dartclaw_config` passes without changes to test expectations
**Asset refs**: M1, M6, SR-6, SR-7, SR-8, SR-9, H5, M7; 0.16.4 review finding L5 (verbatim auto-unwrap duplication across map/foreach); TECH-DEBT-BACKLOG.md TD-086 mechanical parser/coercion slice

> **S14 consolidated into S13 (2026-04-21)** — previously shared composite FIS `s13-s14-pre-decomposition-helpers.md`. Consolidated under the 1:1 story↔FIS invariant enforced by `dartclaw-plan`. FIS renamed to `s13-pre-decomposition-helpers.md`.

#### [P] S33: WorkflowTaskBindingCoordinator Extraction
**Status**: Spec Ready
**FIS**: `fis/s33-workflow-task-binding-coordinator-extraction.md`
**Phase**: Block D: Pre-decomposition Helpers
**Wave**: W3
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — concrete extraction already done in 0.16.4; remaining work is interface lift + fake + signature cleanup, all with strong existing test coverage
**Scope**: **Note (2026-05-04 reconciliation)**: the bulk of S33's heavy lifting already landed during 0.16.4. The three workflow-shared-worktree maps and waiter set (`_workflowSharedWorktrees`, `_workflowSharedWorktreeBindings`, `_workflowSharedWorktreeWaiters`, `_workflowInlineBranchKeys`) and the `hydrateWorkflowSharedWorktreeBinding(...)` entry point were extracted from `task_executor.dart` into a concrete class `WorkflowWorktreeBinder` at `packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart`. `TaskExecutor` now delegates via a `_worktreeBinder` field (`task_executor.dart:146`). The inter-task-binding `StateError` defensive guard moved into `hydrateWorkflowSharedWorktreeBinding` on the binder.
The remaining 0.16.5 work narrows to the **interface + fake + signature polish**:
1. **Lift the abstract interface** from the concrete `WorkflowWorktreeBinder` into `dartclaw_core/lib/src/workflow/` as `abstract interface class WorkflowTaskBindingCoordinator { hydrate, get, put, waitFor }` — picking the surface that consumers actually need (drop public methods that callers don't reach for).
2. **Rename or wrap** the concrete class as `WorkflowTaskBindingCoordinatorImpl` (or keep the `WorkflowWorktreeBinder` filename and have it `implements WorkflowTaskBindingCoordinator`) so `TaskExecutor` and `WorkflowService` depend on the interface, not the concrete type.
3. **Add a fake** at `dartclaw_testing/lib/src/fake_workflow_task_binding_coordinator.dart`.
4. **Drop the redundant `workflowRunId` parameter** in the hydrate callback signature — the binding already carries it. Remove or reduce the defensive guard now that the param mismatch can't happen.

This extraction is what ARCH-004 anticipated; the unblock-S16 framing remains accurate, but S16's "drop the workflow-shared-worktree concern" is **already structurally true** (the binder owns them), so S16's residual is constructor-parameter reduction + dep-grouping only.
**Acceptance Criteria**:
- [ ] `WorkflowTaskBindingCoordinator` abstract interface class exists in `dartclaw_core` with the methods consumers actually need (must-be-TRUE)
- [ ] Existing `WorkflowWorktreeBinder` (or a renamed `WorkflowTaskBindingCoordinatorImpl`) in `dartclaw_server` `implements` the new interface; `TaskExecutor` types its field as the interface, not the concrete (must-be-TRUE)
- [ ] `FakeWorkflowTaskBindingCoordinator` in `dartclaw_testing` for unit-test use
- [x] `TaskExecutor` no longer holds `_workflowSharedWorktrees*` fields directly — **already met by 0.16.4** (delegates via `_worktreeBinder` field at `task_executor.dart:146`); verify still met
- [ ] Callback signature no longer carries the redundant `workflowRunId` parameter — only the binding itself
- [ ] Defensive `StateError` (now living on the binder) deleted or reduced once the signature change makes the mismatch impossible
- [ ] `dart analyze` and `dart test` workspace-wide pass; workflow-shared-worktree integration tests unchanged
- [ ] Unblocks S16: `_TaskPreflight` / `_TaskTurnRunner` / `_TaskPostProcessor` split no longer needs to carry the binding-coordinator concern
**Key Scenarios**:
- Happy: workflow run with `worktree: shared` spawns 3 child tasks → all three hydrate from the coordinator → identical worktree path returned
- Edge: concurrent hydrate attempts → coordinator serializes (mutex preserved from current `TaskExecutor` semantics)
- Error: persisted binding disagrees with requested `workflowRunId` → coordinator throws with explicit message (behavior equivalent to the deleted `StateError`, now centralized)
**Asset refs**: ADX-01 + ADX-03 + Seam B/C; M-D5 (growth vector of `TaskExecutor`)

#### [P] S34: Extract `ClaudeSettingsBuilder` + Token-Parse Helper Consolidation
**Status**: Spec Ready
**FIS**: `fis/s34-claude-settings-builder-and-token-parse.md`
**Phase**: Block D: Pre-decomposition Helpers
**Wave**: W3
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — pure DRY extraction; strong existing test coverage on both call sites
**Scope**: Three related consolidations around `workflow_cli_runner.dart` and `claude_code_harness.dart`.

**Part A — ClaudeSettingsBuilder**: Extract the 100 LOC of byte-identical helpers from `workflow_cli_runner.dart:497-627` and `claude_code_harness.dart:541-668` into a new `packages/dartclaw_core/lib/src/harness/claude_settings_builder.dart` (pure utility class, no Process I/O). Both call sites import it. Current duplicates already drifted on accepted `permissionMode` values (harness accepts all six; runner rejects the interactive four) — the shared parser becomes the canonical spec; the runner's stricter "reject interactive modes" validation stays as a second check layered on top, with an explicit comment explaining why.

**Part B — Token-parse helper alignment**: `WorkflowCliRunner._parseClaude` at `:387-392` and `_parseCodex` at `:420-428` reinvent `(x as num?)?.toInt()` / `(x as String?)` casts when `base_protocol_adapter.dart` already exports `intValue(x)` / `stringValue(x)` helpers. Replace the inline casts. **Note on correctness**: the token-normalization bug itself (Codex `input_tokens` not subtracting `cached_input_tokens`) is already covered by private repo `docs/specs/0.16.4/fis/s43-token-tracking-cross-harness-consistency.md` — **this story does not re-fix the correctness issue**; it only closes the remaining DRY gap (inline casts → helper calls; shared normalize-dynamic-map utility with Part A).

**Part C — Shared `normalizeDynamicMap` helper**: `_stringifyDynamicMap` in `claude_code_harness.dart:604-625`, `workflow_cli_runner.dart:561-598`, and `_normalizeWorkflowOutputs` in `workflow_executor.dart:2906-2992` all implement variants of "recursively walk a `Map<dynamic, dynamic>` → typed `Map<String, dynamic>`". Extract one canonical helper into `dartclaw_core/lib/src/util/dynamic_reader.dart` (or an equivalent neutral module) and route all three sites to it. Pair with S13's `YamlTypeSafeReader` (Part B) spiritually — this is the Process/JSON side of the same pattern.

**Part D — Workflow task-config accessors/constants (TD-070 + TD-066 + TD-103 bridge)**: Centralise the private workflow task-config keys shared between workflow/server/core boundaries. **Cross-package surface** (the original Part D scope): `_workflowFollowUpPrompts`, `_workflowStructuredSchema`, `_workflowMergeResolveEnv`, `_dartclaw.internal.validationFailure`, and the token-metric keys currently tracked by TD-066. **Workflow-internal surface** (added 2026-04-30 from `workflow-task-config-typed-accessors-implementation-note.md` "Out of Scope"): also include `_workflowGit`, `_workflowWorkspaceDir`, `_continueSessionId`, `_sessionBaselineTokens`, `_mapIterationIndex`. **Server-side reads (added 2026-05-04 — closes TD-103)**: also include `_workflowNeedsWorktree` and any other `_workflow*` literals enumerated in `dev/tools/fitness/check_no_workflow_private_config.sh` `ALLOWED_FILES`; migrate the two server reads at `task_config_view.dart:52,54` and `workflow_one_shot_runner.dart:77` to the typed accessor; drop those entries from `ALLOWED_FILES` once the migration is in place. The 2026-04-17 implementation note explicitly excluded these as "internal to `WorkflowExecutor`", but a unified DTO is cleaner now that S34 is touching this surface anyway, and prevents the typed-accessor pattern from immediately drifting back to ad-hoc literals at the next workflow change. The immediate goal is not a repository schema migration; it is to stop adding string literals by hand. Add a tiny typed/constant access surface in the owning package (or `dartclaw_core` if cross-package use demands it), route existing writers/readers through it, and document the rule: new underscored workflow task-config keys require extending the typed surface. Closes [TD-103](../../state/TECH-DEBT-BACKLOG.md#td-103--refactor-server-side-_workflow-task-config-reads-behind-a-typed-accessor).
**Acceptance Criteria**:
- [ ] `ClaudeSettingsBuilder` exists in `dartclaw_core/harness/`; two call sites delete their private helpers and import it (must-be-TRUE)
- [ ] `permissionMode` validation differences documented: shared parser accepts the full set; runner's "reject interactive" is a clearly-commented second-pass validation
- [ ] `_parseClaude` / `_parseCodex` use `intValue` / `stringValue` from `base_protocol_adapter.dart` for all JSON extractions; zero inline `(x as num?)?.toInt()` remaining (must-be-TRUE)
- [ ] `normalizeDynamicMap` helper exists in a neutral dartclaw_core (or equivalent) module; three call sites route through it (must-be-TRUE)
- [ ] Workflow task-config keys listed in Part D — **both cross-package** (`_workflowFollowUpPrompts`, `_workflowStructuredSchema`, `_workflowMergeResolveEnv`, `_dartclaw.internal.validationFailure`, token-metric keys) **and workflow-internal** (`_workflowGit`, `_workflowWorkspaceDir`, `_continueSessionId`, `_sessionBaselineTokens`, `_mapIterationIndex`) — have a central typed/constant accessor surface; no duplicated string literals remain at existing writer/reader call sites (must-be-TRUE)
- [ ] A short comment or architecture note states that new underscored workflow task-config keys must be added to the typed surface rather than ad hoc literals
- [ ] Net LOC reduction ≥150 across `workflow_cli_runner.dart` + `claude_code_harness.dart` + `workflow_executor.dart`
- [ ] `dart test packages/dartclaw_core packages/dartclaw_server packages/dartclaw_workflow` all pass
- [ ] `workflow_cli_runner_test.dart` continues to pass; no behavior change
**Key Scenarios**:
- Happy: workflow one-shot invokes Claude → settings built by `ClaudeSettingsBuilder` → result identical to pre-refactor
- Edge: interactive `permissionMode: 'ask'` reaches the runner → shared parser accepts, then runner's stricter validation rejects — error message is explicit about the interactive-mode restriction
- Boundary: S43 token-correctness fix and this DRY cleanup land independently; if S43 is merged first, Part B can be skipped for `_parseCodex` (only the DRY portion remains)
**Asset refs**: H-D1, H-D2, L-D1, M-D5; cross-reference to private repo `docs/specs/0.16.4/fis/s43-token-tracking-cross-harness-consistency.md` for the underlying correctness fix

#### ~~S30: Workflow Validator Rule Extraction + Error Helpers~~ — **Retired 2026-04-30**
**Status**: Retired (closed by 0.16.4 S44; error-builder helper residue folded into S23)
**Closure rationale**: 0.16.4 S44 (`workflow-robustness-refactor/s44-quick-wins-doc-sweep-validator-split.md`) shipped the rule extraction. Current `workflow_definition_validator.dart` = **136 LOC** (well under the 0.16.5 ≤400 LOC target). Six rule files exist under `packages/dartclaw_workflow/lib/src/workflow/validation/`: `workflow_step_type_rules.dart`, `workflow_structure_rules.dart`, `workflow_reference_rules.dart`, `workflow_git_strategy_rules.dart`, `workflow_gate_rules.dart`, `workflow_output_schema_rules.dart`. The only residual portion of S30's original scope is the optional `_err`/`_warn`/`_refErr`/`_contextErr` error-builder helper pass — that micro-DRY pass is folded into S23 (Housekeeping Sweep) as a single bullet rather than carrying a dedicated story.
**Asset refs**: 0.16.4 refactor-review findings H5, L4 (closed via S44)

---

### Phase 5 (Block E): Structural Decomposition

_Parallel-friendly W4 — S16, S17, S18 are independent files. S15 depends on S13 (its helper). Engineers/agents can take one each; merges collide only if two touch `server.dart` (S18 only)._

#### S15: Workflow Executor Logical-Library Reduction (post-0.16.4-S45 hotspots)
**Status**: Spec Ready
**FIS**: `fis/s15-workflow-executor-logical-library-reduction.md`
**Phase**: Block E: Structural Decomposition
**Wave**: W4
**Dependencies**: S13
**Parallel**: No (file lock on `foreach_iteration_runner.dart`)
**Risk**: Medium — workflow execution path; existing tests provide a strong net but the foreach/promotion state machine is the densest remaining surface
**Re-scope rationale (2026-04-30)**: The original "workflow_executor.dart ≤1,500 LOC" target is **already met**. 0.16.4 S45 (`workflow-robustness-refactor/s45-workflow-executor-decomposition.md`) shipped the dispatcher + per-node-kind runners; current `workflow_executor.dart` = **844 LOC**. The dispatcher (`step_dispatcher.dart`), per-kind runners (`bash_step_runner.dart`, `approval_step_runner.dart`, `loop_step_runner.dart`, `map_iteration_runner.dart`, `foreach_iteration_runner.dart`, `parallel_group_runner.dart`), `workflow_artifact_committer.dart`, `workflow_budget_monitor.dart`, `workflow_task_factory.dart`, and `step_outcome_normalizer.dart` already exist. The `_EmptyProcessEnvironmentPlan` adapter is gone. The raw three-step git commit flow has been lifted into `workflow_git_port.dart` (124 LOC) by 0.16.4 S47. Remaining structural work narrows to the **new hotspots** that emerged after the original decomposition.

**Scope** (current targets):
- (a) **`foreach_iteration_runner.dart` reduction** — 1,624 LOC, the new largest runner. Extract foreach/promotion/merge-resolve state-machine collaborators (e.g. `ForeachIterationScheduler`, `ForeachPromotionCoordinator`, `MergeResolveAttemptDriver`) rather than adding more `part` files. Target ≤900 LOC.
- (b) **`context_extractor.dart` reduction** — 950 LOC; extract structured-output schema validation and helpers into sibling files; target ≤600 LOC. Specific 4-way split candidate per 2026-04-30 review (M40): orchestrator + payload extraction in `context_extractor.dart` (~400 LOC); filesystem-output resolution + path safety (`_safeRelativeExistingFileClaim`, `_safeChangedFileSystemMatches`, `_existingSafeFileClaims`) → `filesystem_output_resolver.dart`; project-index sanitization (`_sanitizeProjectIndex`, `_sanitizeProjectRelativePath`) → `project_index_sanitizer.dart`; review-finding-count derivations → `review_finding_derivations.dart`. Path-safety is the most security-sensitive logic in the file and warrants a discoverable home.
- (c) **`workflow_executor_helpers.dart` reduction** — 762 LOC; reabsorb helpers into the runners that own the call (esp. provider-alias resolution at line 633) or split into purpose-named helper modules; target ≤400 LOC.
- (d) **Underscore-prefixed context-key contract documentation** — document the merge sites preserving keys prefixed with `_` plus scoped sub-namespaces (`_map.current`, `_foreach.current`, `_loop.current`, `_parallel.current.*`) in private repo `docs/architecture/workflow-architecture.md` or as an ADR-022 addendum. Mandatory first-commit doc.
- (e) **TD-070 executor carry-over closure** — confirm runners individually meet the fitness target after (a)–(c); update TD-070 with any specific residual surface that does not.
- (f) **Iteration-runner control-flow correctness (2026-04-30 review)** — beyond the 0.16.4 S78 hotfixes (parallel-group pause-as-failed, `Future.any`+1ms anti-pattern, serialize-remaining event idempotency, `mapAlias` resolver drop), thread cancellation through the inner bodies that S78 explicitly deferred: H4/H5 — `isCancelled` check inside `_executeMapStep` / `_executeForeachStep` / `_executeParallelGroup` / `_dispatchForeachIteration` / `_executeLoop`. Today the only cancellation honoured is the drain-via-task-status path for currently-in-flight tasks; a cancelled run with 30 pending iterations and 4 in-flight processes all 30. Fix folds naturally into the `ForeachIterationScheduler` / `MapIterationScheduler` extraction in (a).
- (g) **Promotion gate + merge-resolve coordinator extraction (2026-04-30 review H10/H11/H12)** — the promotion gate logic in `_dispatchForeachIteration` (≈eight near-identical recordFailure+persist+inFlightCount-- +fire-event branches at `foreach_iteration_runner.dart:567-833`) plus the equivalent in `map_iteration_dispatcher.dart:224-305` is the single biggest LoC reduction opportunity. Extract `PromotionCoordinator` returning a typed `PromotionOutcome` ADT, used by both. The merge-resolve FSM (~550 LoC at `:899-1456`) extracts to `MergeResolveCoordinator` with a typed `MergeResolveState` value object replacing the ~13 stringly-typed magic context keys (`_merge_resolve.<id>.<i>.pre_attempt_sha`, `serialize_remaining_phase`, `serializing_iter_index`, `failed_attempt_number`, `serialize_remaining_event_emitted`, …). Same treatment lets foreach + map share scheduler internals (H10 dedupe).
- (h) **Two-control-flow reconciliation (2026-04-30 review H1/H2)** — production `WorkflowExecutor.execute()` (615-line procedural switch) and `_PublicStepDispatcher.dispatchStep()` are two parallel implementations diverging in non-trivial ways: the public dispatcher does not persist `_parallel.current.stepIds` / `_parallel.failed.stepIds`, doesn't run `_maybeCommitArtifacts`, doesn't honour `step.onError == 'continue'` for action nodes, never runs the `promoteAfterSuccess` pass. Tests written against `dispatchStep` validate a strict subset of production behaviour. Either invert the relationship (have `execute()` loop via the dispatcher with hooks for production-only side effects) or rename the public surface to make the gap explicit (`dispatchStepForScenario`). Pick the smaller diff; document the choice. Also extract the open-coded context-filter-by-prefix policy that's duplicated 6+ times in `workflow_executor.dart` plus once in `parallel_group_runner.dart:131`.
- (i) **Resume/race correctness closures (TD-088 + TD-082)** — while the iteration runner and helper surfaces are open, close the two small correctness debts instead of leaving them as passive backlog. TD-088: audit whether production crash recovery always persists `executionCursor` for map/foreach; if yes, delete or assert the loop-only `_resumeCursor` fallback so map/foreach cannot silently restart from scratch; if no, add symmetric map/foreach reconstruction plus a regression test. TD-082: replace the `_waitForTaskCompletion` early-completion shortcut with a single-source-of-truth completer / serialized subscription path so completion and pause/abort events cannot race through `Future.any` ordering ambiguity.

Uses S13 helpers. Preserves all call sites and public API. **File code-freeze on `foreach_iteration_runner.dart`** during this story: bug-fix commits only.
**Acceptance Criteria**:
- [ ] `foreach_iteration_runner.dart` ≤900 LOC (must-be-TRUE)
- [ ] `context_extractor.dart` ≤600 LOC (must-be-TRUE)
- [ ] `workflow_executor_helpers.dart` ≤400 LOC OR file deleted with helpers absorbed (must-be-TRUE)
- [ ] Underscore-prefixed context-key contract documented (must-be-TRUE)
- [ ] TD-070 executor portion closed (entry deleted or narrowed to a specific named residue) (must-be-TRUE)
- [ ] Existing `dart test packages/dartclaw_workflow` passes with zero test changes (must-be-TRUE)
- [ ] Integration tests (`parallel_group_test.dart`, `map_step_execution_test.dart`, `loop_execution_test.dart`, `gate_evaluator_test.dart`) all pass
- [ ] Public API exposed by `dartclaw_workflow` barrel is unchanged (S09 narrowing already reflects intended surface)
- [ ] `max_file_loc_test.dart` (S10) passes without an allowlist entry for `foreach_iteration_runner.dart`
- [ ] **(f) cancellation threading** — `isCancelled` checked at the top of `_dispatchForeachIteration`, before each child dispatch in `_executeMapStep` / `_executeForeachStep` / `_executeLoop`, and before each peer dispatch in `_executeParallelGroup`. Regression test: cancelled run with 30 pending iterations + 4 in-flight does NOT process all 30 (must-be-TRUE)
- [ ] **(g) `PromotionCoordinator`** extracted; both foreach and map dispatchers consume it; the eight duplicated recordFailure+persist+inFlightCount-- +fire-event branches in `_dispatchForeachIteration` collapse to a single typed-outcome match (must-be-TRUE)
- [ ] **(g) `MergeResolveCoordinator`** extracted; `MergeResolveState` typed value object replaces the magic `_merge_resolve.*` context keys (must-be-TRUE)
- [ ] **(g) Foreach ↔ Map scheduler dedupe** — the two `_executeXxxStep` methods share a common scheduler internal so their dispatch loops are not byte-near-duplicates (must-be-TRUE)
- [ ] **(h) Two-control-flow reconciliation** — either `execute()` consumes the dispatcher OR the public surface is renamed to flag the scenario-only contract; context-filter-by-prefix policy lives in one helper (must-be-TRUE)
- [ ] **TD-088** map/foreach resume path either reconstructs from persisted state or fails fast with a regression test proving no silent restart-from-scratch (must-be-TRUE)
- [ ] **TD-082** `_waitForTaskCompletion` early-completion shortcut has no `Future.any` ordering race between task completion and pause/abort; regression test added (must-be-TRUE)
**Key Scenarios**:
- Happy: workflow with parallel groups + map iterations + loop exit gates runs identically before/after; all events fire in the same order with the same payloads
- Edge: cursor persistence across compaction boundary works identically; crash recovery resumes at the same step
- Edge (new): cancelled run with N pending iterations stops promptly without processing more than `min(maxParallel, in-flight)` additional iterations
- Error: synthesised workflow with a malformed node triggers the same validation error and message
**Asset refs**: ARCH-003 finding; H1 finding; Theme 1; ARCH-003; 2026-04-30 deeper workflow review findings H1, H2, H4, H5, H8, H10, H11, H12, H28, M40 (folded post-S78 hotfix); TECH-DEBT-BACKLOG.md TD-082 and TD-088; private repo `docs/specs/0.16.4/fis/s78-pre-tag-control-flow-correctness.md` (predecessor — S78 closes the four directly-shippable defects; S15 closes the structural tail)

#### S16: Task Executor Residual Cleanup (ctor params + binding handoff)
**Status**: Spec Ready (re-scoped 2026-04-30)
**FIS**: `fis/s16-task-executor-residual-cleanup.md`
**Phase**: Block E: Structural Decomposition
**Wave**: W4
**Dependencies**: S33 (binding-coordinator extraction lifts the `_workflowSharedWorktrees*` maps out)
**Parallel**: No (file lock during ctor signature change)
**Risk**: Low — scoped to constructor signature + uniform-fail helper; the file-LOC and decomposition work already shipped
**Re-scope rationale (2026-04-30)**: The original "task_executor.dart ≤1,500 LOC + decomposition" target is **already met**. 0.16.4 S46 (`workflow-robustness-refactor/s46-task-executor-decomposition.md`) shipped the decomposition; current `task_executor.dart` = **790 LOC** with `task_config_view`, `workflow_turn_extractor`, `task_read_only_guard`, `task_budget_policy`, `workflow_one_shot_runner`, and `workflow_worktree_binder` already extracted. **TD-052 is effectively closed** by 0.16.4 S46 — backlog cleanup at sprint close removes the entry. Remaining work narrows to:

**Scope** (current targets):
- (a) **Constructor parameter reduction** — current ctor still has ~28 named parameters; group into dep-group structs to reach ≤12 (S10's `constructor_param_count_test.dart` ceiling). Suggested groupings: `TaskExecutorServices` (repos + buses), `TaskExecutorRunners` (turn/harness/runner-pool), `TaskExecutorLimits` (already named in S38 — coordinate with that story); pair with S38 record extraction.
- (b) **`_markFailedOrRetry` unification** — verify whether the original 3 near-identical blocks survive 0.16.5 S46's split into the new helper modules; collapse any remaining near-duplicates into a single `_failForProject(project, reason)` helper.
- (c) **`_workflowSharedWorktrees*` field removal** — once S33 lands `WorkflowTaskBindingCoordinator`, delete the three maps + the defensive `StateError` callback guard from `task_executor.dart`; constructor accepts the coordinator instead.

Preserves all call sites and public API.
**Acceptance Criteria**:
- [ ] Constructor takes ≤12 parameters via dep-group structs (S10 ceiling) (must-be-TRUE)
- [ ] All near-identical `_markFailedOrRetry` blocks (if any survive in 790-LOC file) unified into one helper (must-be-TRUE)
- [ ] `_workflowSharedWorktrees*` fields removed; coordinator wired via constructor (depends on S33) (must-be-TRUE)
- [ ] `dart test packages/dartclaw_server/test/task` passes with zero test changes (must-be-TRUE)
- [ ] `constructor_param_count_test.dart` (S10) passes for this file (without allowlist)
- [ ] TD-052 entry deleted from public `dev/state/TECH-DEBT-BACKLOG.md` at sprint close
**Asset refs**: ARCH-004 finding; 0.16.4 S46 closure (`workflow-robustness-refactor/s46-task-executor-decomposition.md`); pairs with S33 (binding coordinator) and S38 (`TaskExecutorLimits` record)

#### [P] S17: service_wiring.dart + cli_workflow_wiring.dart Per-Subsystem Split
**Status**: Spec Ready
**FIS**: `fis/s17-service-wiring-per-subsystem-split.md`
**Phase**: Block E: Structural Decomposition
**Wave**: W4
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — mechanical refactor, no behaviour change
**Scope**: Two sibling god-method splits. **Primary target**: CLI-side wiring at `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` (**1,415 LOC total** as of 2026-05-04, grew from 1,235; `wire()` method still ~678 LOC) — NOT the server-side `ServiceWiring` that was already decomposed in 0.12 Phase 0 into `SecurityWiring`/`ChannelWiring`/`TaskWiring`/`SchedulingWiring`/`StorageWiring`. This story mirrors that 0.12 pattern for the CLI: split `wire()` into per-subsystem private methods. Based on the file's own numbered comment sections: `_wireStorage`, `_wireSecurity`, `_wireHarness`, `_wireChannels`, `_wireTasks`, `_wireScheduling`, `_wireObservability`, `_wireWebUi`, etc. Introduce a small `WiringContext` struct (or similar) for cross-cutting deps (eventBus, configNotifier, dataDir) rather than ambient closure capture. Target: `service_wiring.dart` ≤800 LOC, `wire()` ≤100 LOC.

**Secondary target (added 2026-04-21; rebaselined 2026-05-04)**: `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` is now **945 LOC total** (grew from "350-LOC twin" estimate), `wire()` method ~700 LOC. It has the same god-method shape with the same numbered-section structure (storage → task layer → harness → behaviour → artifact collector → workflow service → task executor) and grew further during the 0.16.4 final-remediation pass when `cli_workflow_wiring.dart` was routed through `bootstrapAndthenSkills(...)` and the runtime-cwd seam landed (S75). The two wirings already drift on which modules they set up; maintaining the same structural discipline on both sides is easier than patching divergences later. Apply the same treatment: per-section `_wireXxx()` methods, `CliWorkflowWiringContext` struct, target `cli_workflow_wiring.dart` ≤600 LOC. **Effort note**: roughly doubles vs. the original 0.16.5 estimate.
**Acceptance Criteria**:
- [ ] `service_wiring.dart#wire()` ≤100 LOC (must-be-TRUE)
- [ ] `service_wiring.dart` total ≤800 LOC (must-be-TRUE)
- [ ] `cli_workflow_wiring.dart#wire()` ≤100 LOC (must-be-TRUE)
- [ ] `cli_workflow_wiring.dart` total ≤600 LOC (must-be-TRUE)
- [ ] `WiringContext` / `CliWorkflowWiringContext` (or equivalents) encapsulate cross-cutting deps (must-be-TRUE)
- [ ] `dart test apps/dartclaw_cli` passes; `dart run dartclaw_cli:dartclaw serve --port 3333` starts and serves identical endpoints
- [ ] `dartclaw workflow run` standalone path works identically before/after (regression guard for CLI wiring)
- [ ] `server_builder_integration_test.dart` (which imports `service_wiring.dart` via `src/`) still passes
**Asset refs**: ARCH-007 finding; H3 finding (SR-10); M-D4 (cli_workflow_wiring twin)

#### [P] S18: DartclawServer Dep-Group Structs + Builder Collapse
**Status**: Spec Ready
**FIS**: `fis/s18-dartclaw-server-dep-group-structs.md`
**Phase**: Block E: Structural Decomposition
**Wave**: W4
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — constructor-only refactor
**Scope**: Collapse `DartclawServer.compose()` static factory into `DartclawServerBuilder` — single construction path. Replace the ~60 scalar required fields in the `DartclawServer._` private constructor with 6 dep-group structs (names TBD during implementation, suggested: `_ServerCoreDeps`, `_ServerTurnDeps`, `_ServerChannelDeps`, `_ServerTaskDeps`, `_ServerObservabilityDeps`, `_ServerWebDeps`). Each struct mirrors a section of `DartclawServerBuilder`'s existing groupings. Constructor takes 6 struct params instead of 60 scalars. Target: `server.dart` ≤800 LOC (from 1,063).
**Acceptance Criteria**:
- [ ] `DartclawServer._` constructor takes ≤6 parameters (must-be-TRUE)
- [ ] `compose()` static factory removed; `DartclawServerBuilder` is the single construction path (must-be-TRUE)
- [ ] 6 dep-group structs exist and are used (must-be-TRUE)
- [ ] `server.dart` ≤800 LOC
- [ ] `dart test packages/dartclaw_server` passes with zero test changes
- [ ] `constructor_param_count_test.dart` (S10) passes for this file (without allowlist)
**Asset refs**: H4 finding (SR-11)

---

### Phase 6 (Block F): Doc + Hygiene Closeout

_Parallel-friendly W5 — S19 (doc closeout) is a single consolidated story touching disjoint doc files. It lands after all code changes so the documentation reflects the shipped structural work._

#### [P] S19: Doc + Hygiene Closeout
**Status**: Spec Ready
**FIS**: `fis/s19-doc-closeout.md`
**Phase**: Block F: Doc + Hygiene Closeout
**Wave**: W5
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low
**Scope**: Three independent doc-hygiene passes touching disjoint files, bundled as one story under the 1:1 story↔FIS invariant (previously S19+S20+S21 sharing a composite FIS). All land after code changes so the documentation reflects the shipped 0.16.5 structural work.

**Part A — SDK 0.9.0 framing → placeholder acknowledgement**. Update `docs/sdk/quick-start.md`, `docs/sdk/packages.md`, and `examples/sdk/single_turn_cli/README.md` to describe the `0.0.1-dev.1` placeholder state instead of "upcoming 0.9.0 release imminent". Replace the pre-publication preview banner with an honest statement: "DartClaw is name-squatted on pub.dev as `0.0.1-dev.1`; the real publish is deferred until the public repo opens. Until then, use a git-pinned dependency or `dependency_overrides` against a local checkout (see ADR-008)." In `packages.md`, replace every `0.9.0 pending` table cell with `0.0.1-dev.1 (placeholder)` + a footnote pointing to ADR-008 (see Inline Reference Summaries appendix below; full rationale in private repo `docs/adrs/008-sdk-publishing-strategy.md`).

**Part B — configuration.md schema sync + recipe key replacement**. Bring `docs/guide/configuration.md` into alignment with the actual parser. (b1) Reconcile `scheduling.jobs` schema: `configuration.md` uses `id:` + `schedule: { type: cron, expression: ... }`; `scheduling.md` uses `name:` + `schedule: "..."`; `jobs create` CLI uses `--name`; the API uses `:name`. Pick the canonical form (likely `id:` + structured `schedule`), document the alternate as a compatibility alias if both parse, or make one authoritative and deprecate the other. (b2) Fill the `channels.google_chat:` block (lines 272-286) with the fields the channel actually parses: `bot_user`, `typing_indicator`, `quote_reply`, `reactions_auth`, `oauth_credentials`, `pubsub.*`, `space_events.*`. Or replace the block with "see the public [Google Chat guide](../../../docs/guide/google-chat.md) for full schema" if split is intentional. (b3) Resolve `DARTCLAW_DB_PATH` env-var reference (line 483): either remove, relabel to what it actually controls, or annotate "deprecated". (b4) Search/replace `memory_max_bytes` → `memory.max_bytes` (with correct YAML nesting) across `recipes/00`, `02`, `06`, `_common-patterns.md`, `_troubleshooting.md`, and `examples/personal-assistant.yaml`.

**Part C — per-package READMEs + CLI README refresh**. Expand stub/bare package READMEs. (c1) `packages/dartclaw_workflow/README.md` currently is one line — expand to match the other package-README structure (Quick Start, Key Types, Installation, When to Use, Related Packages, Documentation links). (c2) `packages/dartclaw_config/README.md` — currently adequate but bare; add Quick Start + Key Types sections. (c3) Refresh `apps/dartclaw_cli/README.md:16,27` — currently lists `serve, status, sessions, deploy, rebuild-index, token` — expand to cover `init`, `service` (install/start/stop/uninstall), `workflow` (run/runs/pause/resume/cancel/status/validate), operational groups (`agents`, `config`, `jobs`, `projects`, `tasks`, `sessions`, `traces`), utility commands (`token`, `rebuild-index`, `google-auth`). Link to `cli-reference.md` as the full source.

**Part D — UBIQUITOUS_LANGUAGE.md glossary residuals (TD-072 closure)**. Bring three co-located entries in `dev/state/UBIQUITOUS_LANGUAGE.md` into line with the post-S73/S74 contract. (d1) "Task Project ID" — drop pre-S74 step-level `project:` framing; describe project-id as task-level only, set per workflow run / per agent step via context, never as a per-step YAML key. (d2) "Resolution Verification" — replace the pre-S73 `verification.format/analyze/test` block description with the S73 project-convention paragraph (skill discovers project conventions from `package.json` / `pubspec.yaml` / etc.; no per-step verification block). (d3) "Workflow Run Artifact" — reconcile the 8-vs-9 field count to the shipped `WorkflowRunArtifact` shape (verify against `dartclaw_models` source; update either count or field list to match exactly). Keep entries in their existing alphabetical positions; no broader glossary restructure.
**Acceptance Criteria**:
- [ ] `quick-start.md` and `packages.md` describe the placeholder state (must-be-TRUE)
- [ ] Every `0.9.0 pending` reference is gone from the SDK docs (must-be-TRUE)
- [ ] ADR-008 is linked from all 3 SDK files (must-be-TRUE)
- [ ] `examples/sdk/single_turn_cli/README.md` version framing aligned
- [ ] `scheduling.jobs` schema is canonical in both `configuration.md` and `scheduling.md` — same keys, same structure (must-be-TRUE)
- [ ] `channels.google_chat` block in `configuration.md` covers `pubsub`, `space_events`, `reactions_auth`, `quote_reply`, `bot_user` (must-be-TRUE)
- [ ] No recipe or example uses `memory_max_bytes` (must-be-TRUE)
- [ ] `DARTCLAW_DB_PATH` either correctly describes the file it controls or is labelled deprecated
- [ ] Manual verification: copy a recipe snippet into a test config and load it without deprecation warnings
- [ ] `dartclaw_workflow/README.md` has Quick Start, Key Types, Installation, When to Use, Related Packages sections (must-be-TRUE)
- [ ] `dartclaw_config/README.md` has Quick Start + Key Types (must-be-TRUE)
- [ ] `dartclaw_cli/README.md` command list mirrors `cli-reference.md` top-level command families (must-be-TRUE)
- [ ] UBIQUITOUS_LANGUAGE.md "Task Project ID" entry no longer describes step-level `project:` (must-be-TRUE)
- [ ] UBIQUITOUS_LANGUAGE.md "Resolution Verification" entry uses S73 project-convention wording; no `verification.format|analyze|test` strings remain in the entry (must-be-TRUE)
- [ ] UBIQUITOUS_LANGUAGE.md "Workflow Run Artifact" field count matches the shipped `WorkflowRunArtifact` shape; the entry's count and listed fields are mutually consistent (must-be-TRUE)
- [ ] TD-072 in public `dev/state/TECH-DEBT-BACKLOG.md` is updated to either reflect closure of the three glossary residuals or list any remaining sub-item explicitly
**Asset refs**: C3, M10, H8, M1, M2, M8, W15, W16, M11 findings; ADR-008; TD-072 (glossary residuals from 0.16.4 final-remediation pass)

> **S20, S21 consolidated into S19 (2026-04-21)** — previously shared composite FIS `s19-s20-s21-doc-closeout.md`. Consolidated under the 1:1 story↔FIS invariant enforced by `dartclaw-plan`. FIS renamed to `s19-doc-closeout.md`.

---

### Phase 7 (Block G): Model & Observability Closeout

_Parallel-friendly W5 for S23 and S24 (hygiene + sidebar are independent). S22 depends on S10 (fitness tests catch regressions during model move). S25 (Level-2 fitness) depends on S10 + S11._

#### S22: dartclaw_models Grab-Bag Migration
**Status**: Spec Ready
**FIS**: `fis/s22-dartclaw-models-grab-bag-migration.md`
**Phase**: Block G: Model & Observability Closeout
**Wave**: W5
**Dependencies**: S10
**Parallel**: No
**Risk**: High — visible public-API move; cross-package import fallout
**Scope**: Move domain-specific models out of `dartclaw_models` to their owning packages. (a) `WorkflowDefinition` (1,349 LOC alone), `WorkflowStep`, `WorkflowRun`, `WorkflowExecutionCursor` → `dartclaw_workflow`. (b) `Project`, `CloneStrategy`, `PrStrategy`, `PrConfig` → `dartclaw_config` (already hosts `ProjectConfig`/`ProjectDefinition`) or a new `dartclaw_project` sub-module (decision during implementation). (c) `TaskEvent` + 9 subtypes → `dartclaw_core` (where `Task` lives); **during the move, convert `TaskEventKind` sealed class with 6 empty subclasses → `enum`** with `String get name` — pattern matching with `switch` continues to work (closes [TD-053](../../state/TECH-DEBT-BACKLOG.md#td-053--taskeventkind-sealed-class-should-be-an-enum)). (d) `TurnTrace`, `TurnTraceSummary`, `ToolCallRecord` → `dartclaw_core`. (e) `SkillInfo` → `dartclaw_workflow`. Update all import sites. `dartclaw_models` ends ≤1,200 LOC as the true shared kernel (Session, Message, SessionKey, ChannelType, AgentDefinition, MemoryChunk). Decide whether to ship a one-release soft re-export from `dartclaw_models.dart` for external consumers (record decision in FIS). Update `CHANGELOG.md` with a migration note.

**Note (2026-05-04 reconciliation)**: `dartclaw_models` total LOC has grown from the pre-audit 3,005 baseline to **3,555 LOC** as of `v0.16.4` (workflow_definition.dart alone is 1,349 LOC), so this story's migration surface is larger than originally scoped. Targets unchanged. Pair this with the **TD-102 attractor** decision (folded in 2026-05-04): `dartclaw_core/lib/` grew from 11,561 → 12,437 LOC during 0.16.4; the ratchet was temporarily raised from 12,000 → 13,000. Items (c) `TaskEvent` and (d) `TurnTrace`/`TurnTraceSummary`/`ToolCallRecord` migrate **into** `dartclaw_core` and would push it further over budget — so before/while landing those moves, identify non-runtime-primitive material in `dartclaw_core/lib/` that can move out (typically to `dartclaw_models` or `dartclaw_config`) to compensate. Net target: `dartclaw_core/lib/` returns ≤12,000 LOC, then lower the ratchet back down in `dev/tools/arch_check.dart` to keep the constraint biting. Closes [TD-102](../../state/TECH-DEBT-BACKLOG.md#td-102--trim-dartclaw_corelib-back-below-the-12000-line-ratchet) at the same commit chain.
**Acceptance Criteria**:
- [ ] `dartclaw_models` ≤1,200 LOC (must-be-TRUE)
- [ ] Workflow/project/task-event/turn-trace/skill-info models live in their owning packages (must-be-TRUE)
- [ ] `dart analyze` and `dart test` workspace-wide pass (must-be-TRUE)
- [ ] CHANGELOG migration note added
- [ ] Fitness functions from S10 remain green (model moves don't regress barrel hygiene or file size)
- [ ] **TD-102**: `dartclaw_core/lib/` total LOC ≤12,000; `_coreLocCeiling` in `dev/tools/arch_check.dart` lowered back from 13,000 → 12,000 in the same commit chain (must-be-TRUE)
- [ ] TD-102 entry deleted (or marked Resolved-by-S22) in public `dev/state/TECH-DEBT-BACKLOG.md`
**Asset refs**: ARCH-005 finding; TD-102 (dartclaw_core ratchet)

#### [P] S23: Housekeeping Sweep + Tech-Debt Mop-Up
**Status**: Spec Ready
**FIS**: `fis/s23-housekeeping-sweep-and-td-mop-up.md`
**Phase**: Block G: Model & Observability Closeout
**Wave**: W5
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low — each item is mechanical and individually scoped; the TD additions were filtered to small, independent items that align with sprint goals (safety, observability, DRY, maintainability) and respect the "no new features / no new deps" constraints.
**Scope** (housekeeping base): (a) Run `dart format packages apps`; the original 11-drifted-file baseline is essentially closed by 0.16.4 release prep (now 0–1 drifted on `main` at sprint start) — verify with `dart format --set-exit-if-changed packages apps` and fix any residual drift. Add a CI `dart format --set-exit-if-changed` step if not added by S10. (b) Align pubspec deps: `yaml: ^3.1.3` everywhere (currently 3.1.0/3.1.2/3.1.3); `path: ^1.9.1` everywhere (currently 1.9.0/1.9.1). Add `dev/tools/check-deps.sh` as a workspace-dep consistency asserter. (c) Audit the 22 production `catch (_)` sites: each gets either `_log.fine(...)` for visibility or a one-line "why silent is appropriate" comment. Special-case `workflow_executor.dart`'s `_maybeCommitArtifacts`/`_cleanupWorkflowGit`/`_initializeWorkflowGit` broad-catch blocks (0.16.4 review H4): narrow to specific exception types (git-spawn failures, worktree-lock issues) and let unexpected errors bubble through `_failRun`. (d) Replace 23 `await Future.delayed(Duration.zero)` in tests with `await pumpEventQueue()`; document the rationale in `TESTING-STRATEGY.md`. (e) Replace 2 `throw Exception('...')` in `schedule_service.dart:246` and `project_service_impl.dart:619` with typed exceptions (`ScheduleTurnFailureException`, `GitFetchException`). (f) Adopt `super.` parameters in `claude_code_harness.dart` + `codex_harness.dart`; drop the `// ignore: use_super_parameters` comments. (g) Add focused unit tests for `expandHome` in `dartclaw_security/test/path_utils_test.dart` (happy path, env missing, `~` alone, `~/` prefix).

**Scope** (0.16.4 review-driven cleanup — breaking changes acceptable per early-stage policy):
- **R-L2 — Delete `@Deprecated` shims**. 13 symbols/params confirmed unused by production wiring: `WorkflowRegistry.listBuiltIn()` alias (`workflow_registry.dart:171-172`), top-level `deliverResult()` (`scheduling/delivery.dart:221-256`), 7 `@Deprecated dynamic` params on `ChannelManager` ctor (`channel_manager.dart:49-55`), 3 `@Deprecated EventBus?` params on `SlashCommandHandler`/`taskRoutes`/`ScheduledTaskRunner`. Update any test-only callers that still pass the deprecated params; add a CHANGELOG entry under "Breaking changes". Excludes the `TemplateLoaderService` `@Deprecated` shim being *introduced* by stretch TD-029 (those are intentional forward shims, not legacy rot).
- **R-L6 — Add `WorkflowStep.copyWith`**. The resolver at `workflow_definition_resolver.dart:107-140` manually reconstructs `WorkflowStep` via a ~30-argument positional-and-named constructor call. A new step field silently drops from the resolver round-trip. Add `copyWith` covering every field; migrate the resolver to use it. Optional: add a `WorkflowStep` fitness test that round-trips through parser → resolver and asserts field equality.
- **R-L1 — ADR-022 step-outcome observability**. When the `<step-outcome>` marker is missing on a non-`emitsOwnOutcome` step, `WorkflowExecutor` currently increments `workflow.outcome.fallback` silently. Per ADR-022 ("logs a warning"), add a `_log.warning` at the step level naming the run ID and step ID — cheap but required for operators debugging a missing outcome.
- **R-M7 — Workflow test path helpers**. Consolidate 12 verbatim helper copies across `packages/dartclaw_workflow/test/workflow/`: `_fixturesRoot()` (7 copies), `_definitionsDir()` (3 copies), `_codexAvailable()` (2 copies). Place in `packages/dartclaw_workflow/test/workflow/_support/workflow_test_paths.dart` exposing `workflowFixturesRoot()`, `workflowDefinitionsDir()`, `codexAvailable()`, plus a shared `findAncestorDir(List<String> candidates)` primitive.
- **R-M8 — `TaskExecutorTestHarness`**. `setUp`/`tearDown` pairs in `packages/dartclaw_server/test/task/{task_executor_test,retry_enforcement_test,budget_enforcement_test}.dart` construct the same topology (tempDir + sessionsDir + workspaceDir, `SessionService` + `MessageService`, in-memory SQLite task repo, `TurnManager`-with-fake-worker, `ArtifactCollector`, optional `TaskExecutor`). Extract into `packages/dartclaw_testing/lib/src/harnesses/task_executor_test_harness.dart`. Add `dartclaw_testing` to `budget_enforcement_test.dart`'s import chain if not already present. Cuts ~50 lines per test file.

**Scope** (tech-debt mop-up — each item closes a `TD-NNN`):
- **TD-054** — Remove settings page badge variant round-trip: update `settings_page.dart` callers to pass variant strings directly (they already have the `ChannelStatus` enum); delete `_badgeVariantFromClass()` in `settings.dart` template module; drop the class-string → variant reverse parse.
- **TD-055** — Collapse `_readSessionUsage` default-record duplication in `web_routes.dart`: extract the five-field default record as a single file-private constant (or early-return helper); four fallback branches become one. Net ~40-line reduction.
- **TD-056** — Extract shared `cleanupWorktree(WorktreeManager? mgr, TaskFileGuard? guard, String taskId)` utility and replace the 3 near-identical implementations in `task_routes.dart` + `project_routes.dart` + `task_review_service.dart`. Place it where `WorktreeManager` lives (`dartclaw_server/lib/src/tasks/` seems right); keep try/catch semantics identical.
- **TD-060** — `dartclawVersion` auto-sync with `pubspec.yaml`: prefer a pre-compile `dev/tools/sync-version.dart` invoked by `dev/tools/build.sh` that regenerates `packages/dartclaw_server/lib/src/version.dart` from `packages/dartclaw_server/pubspec.yaml`. If the pre-compile step is >30 LOC, fall back to adding a release-checklist bullet in `docs/guidelines/KEY_DEVELOPMENT_COMMANDS.md` and remove the memory's "bumped on release" TODO. Record the chosen path in the FIS.
- **TD-061** — Surface Codex stderr in logs: in `codex_harness.dart`, pipe stderr through a `StreamTransformer<List<int>, String>` (LineSplitter) and log each line via `_log.warning` (or `_log.fine` for benign lines — the existing `ClaudeCodeHarness` pattern is the template). This unblocks diagnosing invalid model selection, API failures, and rate-limit errors that currently look like silent hangs.
- **TD-073** — `externalArtifactMount` collision fail-fast: add validator-time detection for obvious duplicate destination paths across steps that share a mount root, and runtime fail-fast before overwriting any existing mounted artifact path. Keep recovery policy simple for 0.16.5: no timestamp suffix / auto-rename; a collision is a workflow authoring error.
- **TD-085** — `SchemaValidator` supported-subset guard: either implement the missing low-cost keywords (`pattern`, `minLength`, `maxLength`, `minItems`, `uniqueItems`) or reject unsupported JSON-Schema keywords at validator-load time with a clear "supported subset" diagnostic. Do not silently green-light `oneOf` / `anyOf` / `not` unless actually implemented.

**Scope** (2026-04-21 delta-review additions):
- **DR-M3 — Consolidate `FakeProcess` redeclarations** (count revised 2026-04-30: **9 redeclarations**, not 6). Test files reimplement `class FakeProcess implements Process` despite the canonical `packages/dartclaw_testing/lib/src/fake_process.dart:6` being a dev-dep of all of them. Confirmed sites: `dartclaw_core/test/harness/claude_code_harness_test.dart:22` (`FakeProcess`), `dartclaw_core/test/harness/claude_hook_events_test.dart:13` (`FakeProcess`), `dartclaw_core/test/harness/harness_isolation_test.dart:120` (`_FakeProcess`), `dartclaw_core/test/harness/merge_resolve_env_contract_test.dart:31` (`_ClaudeFakeProcess`), `dartclaw_security/test/claude_binary_classifier_test.dart:10` (`FakeProcess`), `dartclaw_signal/test/signal_cli_manager_test.dart:12` (`FakeProcess`), `dartclaw_whatsapp/test/gowa_manager_test.dart:12` (`FakeProcess`), `dartclaw_server/test/container/container_manager_test.dart:419` (`_FakeProcess`), and the various `_FakeProcessRunner` shims in `apps/dartclaw_cli/test/commands/service_wiring_andthen_skills_test.dart:278` and `dartclaw_workflow/test/skills/skill_provisioner_test.dart:550` (different shape — runner vs Process — evaluate per-site whether canonical helper covers). Delete locals where shape matches; `import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess, CapturingFakeProcess;` in each. Extend canonical helper with any missing knobs (`pid`-override, `killResult`, claude-specific shape) if a local copy diverges. Saves ~250 LOC of stdio boilerplate across nine test files.
- **DR-M2 — Delete `resolveGitCredentialEnv` dead wrapper**. `packages/dartclaw_server/lib/src/task/git_credential_env.dart:88-102` — only reference is the `show` in `task_exports.dart:12`; no production or test caller. Delete function + drop from the `show` list. Keep `resolveGitCredentialPlan` + `GitCredentialPlan` (the richer successor).
- **DR-L2 — Dead-private-method sweep on rapid-churn files**. After S15/S16 decomposition (or in parallel if ordered safely), grep `workflow_executor.dart`, `task_executor.dart`, `context_extractor.dart`, `workflow_cli_runner.dart` for `Future<\w+>\s+_\w+` and `\w+\s+_\w+\(` method declarations with zero call sites. Delete. Example: `_extractLastAssistantContent` was removed reactively in commit b36ec8f (2026-04-17); more likely lurk. Use `dart analyze --fatal-infos` or an LSP call-hierarchy sweep.

**Scope** (2026-04-30 deeper-review additions — `SkillProvisioner` ref-injection defence):
- **SP-1 — `SkillProvisioner` ref shape validation + `--` separators**. `skill_provisioner.dart:307-334` (`_checkout`) and `:316-323` (`_resolveCachedRef` rev-parse) interpolate operator-supplied `config.ref` into `git checkout <ref>` and `git rev-parse origin/$ref` with no `--` separator and no shape validation. A ref like `--upload-pack=…` would be interpreted as an option. Add `^[A-Za-z0-9_./-]+$` validation (raise `SkillProvisionConfigException` on mismatch) and `--` separators on every `git` subcommand that takes a ref argument. **Note**: this is defensive coding (not signature/SHA pinning, which the 0.16.5 PRD explicitly defers as "pre-production hardening" — see Decisions Log row "AndThen source-authenticity pinning"). Pure argument-injection close.
- **SP-2 — Cached-source origin URL re-validation**. `skill_provisioner.dart:325`: `_validateGitUrl` runs only inside `_doNetworkClone` for fresh clones. Switching `andthen.network: disabled` with a freshly malicious config will reuse a cached source whose `origin` URL no longer matches the configured `git_url`. Validate cached `origin` URL against config on every startup, regardless of network mode; fail fast if drifted.

**Scope** (2026-04-30 additions — TD triage decisions + ledger residue):
- **TD-069 advisory triage decisions** — record decisions inline (or in a short ADR appendix to ADR-023 if any decision flips behaviour) for the six 0.16.4 advisory DECIDE items: H1 (`paused`-as-success policy in release gate), H2 (functional-bug-fix verification: diff-touches vs fixture regression test), M6 (`_ensureKnownDefectsBacklogEntries` mutates cloned fixture), M11 (token metrics on `task.configJson` — already split off as TD-066, cross-ref), M12 (`stepDefaults` validator literal-vs-glob workaround), M13 (hardcoded `dart format/analyze/test` in built-in YAMLs vs project_index verification routing). Each decision is one paragraph: chosen path, rationale, follow-up if any. Removes TD-069 from backlog or narrows it to whichever items the team explicitly chose to defer further.
- **TD-090 / TD-089 / TD-086 residual triage** — record explicit 0.16.5 decisions for the fresh workflow debt that is too semantic for silent mop-up. TD-090: choose between validation-time rejection of parallel groups with multiple approval-emitting peers (preferred if no product need exists) or a future N-pending approval model. TD-089: decide whether `WorkflowService` dependency value objects become a 0.16.5 stretch story or a 0.17 stabilization item; do not leave the nullable-but-required constructor contract unexplained. TD-086 residuals: choose duplicate YAML key policy, parser max-depth/max-bytes guard, parser-vs-validator home for semantic checks, and gate-expression diagnostic posture; implement any mechanical pieces that fit without expanding S23 materially, otherwise narrow TD-086 to the named residuals.
- **S30 residue — error-builder helpers in validator rules**: introduce `_err(type, message, {stepId, loopId})` / `_warn(type, message, {stepId, loopId})` / `_refErr(stepId, message)` / `_contextErr(stepId, message)` helpers in `packages/dartclaw_workflow/lib/src/workflow/validation/` (or as private mixin / class extension) and migrate the 63 call sites previously cited under retired S30. The rule extraction itself shipped via 0.16.4 S44; only the error-builder DRY pass remains and is small enough to ride here.
- **`workflow show --resolved --standalone` AndThen bootstrap** — see S29 (TD-072 item 1). Item is **owned by S29**; cross-listed here only for cross-ref.
- **Pre-existing test-suite failures from 0.16.4 S67/S68** — verify the "15 known pre-existing failures in `workflow_builtin_integration_test` + `built_in_workflow_contracts_test`" (per STATE.md) are still present and either fix-forward as part of this sweep or update STATE.md / CHANGELOG to confirm acceptance.

**Stretch (if capacity, P2)**:
- **TD-029** — Introduce `TemplateLoaderService` as an injectable parameter: rework `packages/dartclaw_server/lib/src/templates/loader.dart` so the rendering path accepts an instance (constructor-injected), keep the global `templateLoader` as a back-compat shim annotated `@Deprecated('use injected TemplateLoaderService')`. No consumer migration required in this sprint — just the seam.

**Acceptance Criteria**:
- [ ] `dart format --set-exit-if-changed packages apps` green (must-be-TRUE)
- [ ] `yaml` and `path` deps aligned across all pubspecs (must-be-TRUE)
- [ ] `dev/tools/check-deps.sh` exists and asserts alignment
- [ ] All 22 production `catch (_)` sites have log or comment
- [ ] 23 test `Future.delayed(Duration.zero)` replaced with `pumpEventQueue()`
- [ ] 2 typed exceptions added; 2 `throw Exception` removed
- [ ] `claude_code_harness.dart` + `codex_harness.dart` use super-parameters
- [ ] `expandHome` unit tests exist and pass
- [ ] `TESTING-STRATEGY.md` has `pumpEventQueue` rationale section
- [ ] **TD-054** settings-page round-trip removed; `_badgeVariantFromClass()` deleted
- [ ] **TD-055** `_readSessionUsage` default record DRY'd; net line reduction
- [ ] **TD-056** `cleanupWorktree` shared utility in use at 3 sites
- [ ] **TD-060** `dartclawVersion` auto-sync OR release-checklist entry landed; decision recorded in FIS
- [ ] **TD-061** Codex stderr lines appear in logs at `WARNING` / `FINE`; no regression in existing codex harness tests
- [ ] **TD-073** `externalArtifactMount` duplicate destination paths fail at validation or runtime before overwrite; regression test landed (must-be-TRUE)
- [ ] **TD-085** Unsupported JSON-Schema keywords no longer silently validate green; supported subset diagnostic or implementation tested (must-be-TRUE)
- [ ] **TD-029** (stretch) `TemplateLoaderService` seam exists — OR this item carries forward on the backlog with an updated "Trigger" field pointing to the next template/wiring refactor
- [ ] Public `dev/state/TECH-DEBT-BACKLOG.md` updated: resolved TD entries deleted per the "Open items only" policy on line 3
- [ ] **R-L2** All 13 `@Deprecated` shims removed; CHANGELOG "Breaking changes" entry landed (must-be-TRUE)
- [ ] **R-L6** `WorkflowStep.copyWith` exists and is used by `WorkflowDefinitionResolver` (must-be-TRUE)
- [ ] **R-L1** Step-outcome warning log fires on missing marker for non-`emitsOwnOutcome` steps (must-be-TRUE)
- [ ] **R-M7** 12 duplicated test-path helpers collapsed into `workflow_test_paths.dart` (must-be-TRUE)
- [ ] **R-M8** `TaskExecutorTestHarness` lives in `dartclaw_testing`; 3 task executor tests use it
- [ ] **DR-M3** All 9 `FakeProcess`-style redeclarations resolved (deleted where shape matches; canonical helper extended where it doesn't); all 9 test files import from `dartclaw_testing` (must-be-TRUE)
- [ ] **DR-M2** `resolveGitCredentialEnv` + its `show` entry deleted (must-be-TRUE)
- [ ] **DR-L2** Zero uncalled private methods in the post-0.16.4-S45/S46 successor files: `foreach_iteration_runner.dart`, `context_extractor.dart`, `workflow_executor_helpers.dart`, `task_executor.dart`, `workflow_cli_runner.dart` (must-be-TRUE) — _scope adjusted from original target list now that `workflow_executor.dart` is 844 LOC and `task_executor.dart` is 790 LOC._
- [ ] **TD-069** All six advisory DECIDE items have a recorded decision; TD-069 entry deleted or narrowed in public `dev/state/TECH-DEBT-BACKLOG.md` (must-be-TRUE)
- [ ] **TD-090 / TD-089 / TD-086 residuals** 0.16.5 triage decisions recorded; backlog entries either deleted, implemented, or narrowed to named 0.17+ residuals (must-be-TRUE)
- [ ] **S30 residue** Error-builder helpers exist and are used in the `validation/` rule files; 63-call-site migration complete (must-be-TRUE)
- [ ] **SP-1** `SkillProvisioner` validates `config.ref` shape; every `git` subcommand using a ref or url uses `--` separators; injection regression test landed (must-be-TRUE)
- [ ] **SP-2** Cached-source `origin` URL re-validated against `andthen.git_url` on every startup; mismatched cache fails fast (must-be-TRUE)
- [ ] Pre-existing 15 known failures in `workflow_builtin_integration_test` + `built_in_workflow_contracts_test` either fixed or formally accepted with rationale recorded
**Asset refs**: SR-1..SR-5, L-2 findings; M-5 finding; public [`TECH-DEBT-BACKLOG.md`](../../state/TECH-DEBT-BACKLOG.md) TD-029, TD-054, TD-055, TD-056, TD-060, TD-061, TD-069, TD-073, TD-085, TD-086, TD-089, TD-090; 0.16.4 refactor-review findings L1, L2, L6, M7, M8, H4; M-D3, M-D2, L-D2; 0.16.4 closure ledger (TD-069 advisory cluster); 0.16.4 S44 (S30 residue); 2026-04-30 deeper workflow review (H17, H19-H23, H25, M20, M22, M25, H30, H31)

#### S35: Stringly-typed Workflow Flags → Enums
**Status**: Spec Ready
**FIS**: `fis/s35-workflow-flags-to-enums.md`
**Phase**: Block G: Model & Observability Closeout
**Wave**: W5
**Dependencies**: S22
**Parallel**: No
**Risk**: Low — in-code type replacement; JSON wire format unchanged
**Scope**: Replace four stringly-typed public flags with proper enums + `fromJsonString` factories that throw `FormatException` naming the valid values. Keep JSON serialization unchanged via `toJson()/fromJson()` that returns/accepts the same strings. (a) `WorkflowStep.type: String` at `workflow_definition.dart:471` — introduce `WorkflowTaskType` enum and type the existing `type` field with it; S38 depends on this story and owns the later field rename to `taskType`. (b) `WorkflowGitExternalArtifactMount.mode` at `:806` (`'per-story-copy' | 'bind-mount'`) → `WorkflowExternalArtifactMountMode` enum. (c) `WorkflowGitWorktreeStrategy.mode` at `:869` (`'shared' | 'per-task' | 'per-map-item' | 'inline' | 'auto'`) → `WorkflowGitWorktreeMode` enum. (d) `TaskExecutor.identifierPreservation = 'strict'` → `IdentifierPreservationMode` enum (values TBD during implementation — likely `strict | lenient | off`). Reader impact: valid values become IDE-discoverable via autocomplete; typos become compile errors. Don't enum-ify `chat_card_builder.dart:338-380` status switches — those operate on Google Chat wire values already owned by upstream.
**Acceptance Criteria**:
- [ ] Four enums exist in their owning packages (`WorkflowTaskType` + `WorkflowExternalArtifactMountMode` + `WorkflowGitWorktreeMode` in `dartclaw_workflow`; `IdentifierPreservationMode` in `dartclaw_core` or `dartclaw_server`) (must-be-TRUE)
- [ ] Each enum has a `fromJsonString(String)` factory that throws `FormatException` listing valid values for unknown input (must-be-TRUE)
- [ ] Each enum has a `toJson()` / `name` getter returning the exact wire string
- [ ] `WorkflowStep.type` remains the field name in S35 and is typed `WorkflowTaskType`; S38 owns the follow-up rename to `taskType` (must-be-TRUE)
- [ ] YAML parser and validator use the enum-typed fields; JSON wire format is byte-compatible with the prior String representation
- [ ] `dart analyze` and `dart test` workspace-wide pass
- [ ] Changelog notes the internal type change (not a breaking wire change)
**Key Scenarios**:
- Happy: YAML says `mode: per-task` → parser resolves to `WorkflowGitWorktreeMode.perTask`; re-emitted YAML round-trips byte-identical
- Edge: YAML says `mode: typo-value` → parser raises `FormatException` listing all valid values in the error message
- Boundary: existing resolved-YAML baselines round-trip identically; new enum doesn't leak into public JSON responses
**Asset refs**: Readability 1.1 row; S38 depends on this story for the `taskType` rename (order: S35 introduces enum and types the existing field; S38 renames the field); batch-ship with S22's migration wave for one coherent CHANGELOG entry

#### S36: Public API Naming Batch (`k`-prefix + `get*` renames)
**Status**: Spec Ready
**FIS**: `fis/s36-public-api-naming-batch.md`
**Phase**: Block G: Model & Observability Closeout
**Wave**: W5
**Dependencies**: S22 (batch the breaking-change CHANGELOG entry with the model migration)
**Parallel**: No (batched with S22 for one coherent public API break)
**Risk**: Low — mechanical renames; analyzer catches every call site
**Scope**: Batch two Effective-Dart naming corrections into one CHANGELOG break, piggy-backing on S22's already-breaking API migration. **Part A — drop `k`-prefix from 6 public constants**: Effective Dart explicitly bans Hungarian/prefix notation. Rename: `kDefaultBashStepEnvAllowlist` → `defaultBashStepEnvAllowlist`; `kDefaultGitEnvAllowlist` → `defaultGitEnvAllowlist`; `kDefaultSensitivePatterns` → `defaultSensitivePatterns` (all in `packages/dartclaw_security/lib/src/safe_process.dart:5,27,41` + re-exports in `dartclaw_security.dart:23-25`); `kWorkflowContextTag/Open/Close` and `kStepOutcomeTag/Open/Close` → `workflowContextTag/Open/Close` and `stepOutcomeTag/Open/Close` (in `packages/dartclaw_workflow/lib/src/workflow/workflow_output_contract.dart:12,15,18,25,28,31`). Update 7 call sites in `apps/dartclaw_cli/lib/src/commands/wiring/{harness,task}_wiring.dart`, `workflow_executor.dart:53,2218`, `security_config.dart:9`, `prompt_augmenter.dart:40-113`. **Part B — drop `get` prefix from 10 public methods**: Rename per Effective Dart guidance. `ProjectService.getDefaultProject` → `defaultProject` (convert to getter if side-effect-free); `ProjectService.getLocalProject` → `localProject` (getter); `SessionService.getOrCreateMain` → `getOrCreateMainSession` (keeping `getOrCreate` prefix is acceptable — it communicates side effect; Effective Dart bans `get` not `getOrCreate`); `ProviderStatusService.getAll` → `all` (getter); `.getSummary` → `summary` (getter); `GowaManager.getLoginQr` → `loginQr` / `.getStatus` → `status`; `PubsubHealthReporter.getStatus` → `status`. Update every call site. **Part C — add CHANGELOG migration note** under a shared "Breaking API Changes" section that also houses S22's model migration, so consumers see one coherent break.
**Acceptance Criteria**:
- [ ] Zero `k[A-Z]` public identifiers in `dartclaw_security` + `dartclaw_workflow` barrel exports (`rg '^const k[A-Z]|^final k[A-Z]' packages/dartclaw_{security,workflow}` returns empty) (must-be-TRUE)
- [ ] `get[A-Z]*` methods on public service interfaces renamed or converted to getters per scope list (must-be-TRUE)
- [ ] Every call site updated; `dart analyze` workspace-wide clean (must-be-TRUE)
- [ ] `dart test` workspace-wide passes (must-be-TRUE)
- [ ] CHANGELOG entry ships under the S22 "Breaking API Changes" banner — single user-facing migration note
- [ ] `getOrCreateMain` intentionally retained with its prefix to communicate "factory with side effect"; decision recorded in the FIS
**Key Scenarios**:
- Happy: consumer reads `projectService.localProject` as a getter → no parentheses required; prior `getLocalProject()` call sites now fail `dart analyze` pointing to the rename
- Edge: `getOrCreate*` factories keep their prefix — Effective Dart's rule targets accessor-style `get` only
- Boundary: CHANGELOG under one unified break ships; no per-rename CHANGELOG entries
**Asset refs**: Effective Dart A1/A2 rows

#### S38: Readability Pack
**Status**: Spec Ready
**FIS**: `fis/s38-readability-pack.md`
**Phase**: Block G: Model & Observability Closeout
**Wave**: W5
**Dependencies**: S22, S35
**Parallel**: No
**Risk**: Low — five small, scoped changes; each individually low-risk
**Scope**: Bundle five low-cost, high-payoff readability wins into one ~4h story. (a) **`_logRun(run, msg)` helper + severity drop to `fine`** in `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart` — 12+ inline `_log.info("Workflow '${run.id}': $msg")` calls (lines 577, 588, 616, 681, 703, 715, 786, 816, 848, 912, …) collapse to `_logRun(run, msg)`; per-step progression events drop from `info` → `fine` (terminal status, errors, approval events stay `info`). Also unifies the `${run.id}` vs `${definition.name}` vs `(${run.id})` prefix inconsistency across lines 499, 523, 577. (b) **Typed `Task.worktree` read-only helper** in `packages/dartclaw_core/lib/src/task/task.dart` — add `({String? branch, String? path, DateTime? createdAt})? get worktree => …` that parses the `Map<String, dynamic>? worktreeJson` field. The map field stays for back-compat. (c) **Rename `WorkflowStep.type → taskType`** in `packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart:471` after S35 has introduced `WorkflowTaskType` on the existing `type` field — add `taskType` field; deprecate `type` with `@Deprecated('Use taskType')`; update public `dev/state/UBIQUITOUS_LANGUAGE.md` §"Overloaded Terms" to distinguish "step type" (kind: action/loop/parallel) from "task type" (coding/reading/analysis/etc). (d) **Document the three dir conventions** — add a dartdoc comment block in the `dartclaw_core` barrel clarifying: `dataDir` = `~/.dartclaw/` (instance root), `workspaceDir` / `workspaceRoot` = user's active project working tree, `projectDir` = clone under `$dataDir/projects/<id>/`. Rename `TaskExecutor.workspaceDir` → `workspaceRoot` to align with the glossary. (e) **`TaskExecutorLimits` record** — group the cohesive `compactInstructions` / `identifierPreservation` / `identifierInstructions` / `maxMemoryBytes` / `budgetConfig` quintet on `TaskExecutor.new` (`task_executor.dart:35-62`, currently ~23 named params) into a single record or class. This drops the ctor below S10's `≤12 params` fitness threshold and makes the cohesive-cluster-vs-one-off-flag distinction visible at the call site. (Similar `WebRoutesChannels` / `WorkflowBashSandbox` clusters are left for S18-adjacent future work — out of scope here.)
**Acceptance Criteria**:
- [ ] `_logRun` helper exists in `workflow_executor.dart`; all 12+ inline prefix calls migrated (must-be-TRUE)
- [ ] Per-step progression log calls at `fine` severity; terminal / error / approval at `info` (must-be-TRUE)
- [ ] `Task.worktree` typed getter exists; returns null when `worktreeJson` is null (must-be-TRUE)
- [ ] `WorkflowStep.taskType` field exists; `type` deprecated with `@Deprecated('Use taskType')` (must-be-TRUE)
- [ ] Glossary "Overloaded Terms" section distinguishes step type vs task type (must-be-TRUE)
- [ ] Dir-naming conventions documented in `dartclaw_core` barrel dartdoc (must-be-TRUE)
- [ ] `TaskExecutor.workspaceDir` renamed to `workspaceRoot`; all call sites updated
- [ ] `TaskExecutorLimits` record (or class) exists; `TaskExecutor.new` uses it; ctor param count drops below 12 (must-be-TRUE)
- [ ] `dart analyze` and `dart test` workspace-wide pass
**Key Scenarios**:
- Happy: reading `workflow_executor.dart` log lines, the per-step noise disappears at `info` level; terminal errors remain visible
- Edge: consumer code that reads `Task.worktreeJson['branch']` continues to work via the untouched map field; new code uses `task.worktree?.branch`
- Boundary: glossary + dartdoc are authoritative — future contributors reach for `workspaceRoot` not `workspaceDir` on new code
**Asset refs**: Readability 1.2/1.3/2.1/2.2/3.2/3.3 rows; TD-070 (workflow architecture and fitness carry-overs)

#### [P] S24: SidebarDataBuilder Extraction
**Status**: Spec Ready
**FIS**: `fis/s24-sidebar-data-builder-extraction.md`
**Phase**: Block G: Model & Observability Closeout
**Wave**: W5
**Dependencies**: –
**Parallel**: [P]
**Risk**: Low
**Scope**: Extract a `SidebarDataBuilder` class in `packages/dartclaw_server/lib/src/web/web_routes.dart`. Construct once per-request context, expose `Future<SidebarData> build({String? activeSessionId})`. Inject via `PageContext`. Collapse the 6 existing call sites (each currently passes 7-10 similar named parameters) to `pageContext.sidebar.build(activeSessionId: id)`.
**Acceptance Criteria**:
- [ ] `SidebarDataBuilder` exists as a dedicated class (must-be-TRUE)
- [ ] All 6 `buildSidebarData(...)` call sites collapsed to the builder invocation (must-be-TRUE)
- [ ] `dart test packages/dartclaw_server/test/web` passes
**Asset refs**: M5 finding (SR-14)

#### S25: Level-2 Fitness Functions (6 tests)
**Status**: Spec Ready
**FIS**: `fis/s25-level-2-fitness-functions.md`
**Phase**: Block G: Model & Observability Closeout
**Wave**: W6
**Dependencies**: S10, S11, S12
**Parallel**: No
**Risk**: Medium — cross-package invariants require a stable baseline
**Scope**: Add 6 Level-2 fitness functions as `test/fitness/*.dart` files plus one cross-package smoke test (TD-046). (a) `dependency_direction_test.dart` — encode allowed package edges as data (map from package name to set of allowed dependencies in both library and test scope), fail on any `import 'package:X/...'` in `packages/Y/lib/` that violates. This table accepts the 0.16.4 surgical release-gate edge `dartclaw_workflow -> dartclaw_security`, while S12 still removes the separate `dartclaw_workflow -> dartclaw_storage` runtime edge. (b) `src_import_hygiene_test.dart` — no file in `packages/<X>/lib/` may `import 'package:<Y>/src/...'` where X != Y. (c) `testing_package_deps_test.dart` — assert `dartclaw_testing/pubspec.yaml` lists only core/models/security (+ http if needed) — enforces S11 post-state. (d) `barrel_export_count_test.dart` — per-package soft limits (core ≤80, config ≤50, workflow ≤35, others ≤25). Catches CRP drift. **(e) `enum_exhaustive_consumer_test.dart`** (added 2026-04-21 delta) — runtime scan over SSE envelope serializers, `AlertClassifier`, `AlertFormatter`, UI badge maps, and CLI status renderers asserting that every `WorkflowRunStatus` / `TaskStatus` / equivalent sealed-enum value is handled by each consumer. Mirrors S01's compile-time enforcement at a different axis (cross-consumer, not just classifier-side). Catches the pattern where adding a new enum variant silently renders as "Unknown" in a UI badge or gets dropped from an SSE payload. **(f) `max_method_count_per_file_test.dart`** (added 2026-04-21 delta) — per-file ceiling of ≤40 public + private methods (allowlist current offenders with explicit shrink targets). Catches the "file shrinks below 1,500 LOC but concerns stay tangled" failure mode. Complements S10's `max_file_loc_test.dart`. The FIS should also extend either `dependency_direction_test.dart` or a small workflow-specific companion check so production workflow runtime files cannot import `SqliteWorkflowRunRepository` after S12.

**TD-046 — Crash-recovery smoke test** (added 2026-04-30): add an integration smoke at `packages/dartclaw_server/test/integration/crash_recovery_smoke_test.dart` (or under a scripted CLI/profile path) that exercises reserve/start → hard kill → restart → orphan cleanup + recovery notice. The operational-hygiene follow-up review (2026-03-15) flagged this as the missing automation around the rollback-leak fix in `releaseTurn()`; backlog says "Before calling the operational-hygiene hardening fully closed, before SDK publish, or whenever crash-recovery behavior is touched again." Fits 0.16.5's safety-and-observability theme; no new deps. Tag `@Tags(['integration'])` so it gates release-prep, not every-PR.

**TD-074 — Homebrew/asset/archive revalidation** (added 2026-04-30): add a release-prep verification step that dry-runs the archive/Homebrew path against the current 0.16.4+ asset layout. Verify the unpacked archive contains the expected embedded templates, static assets, DC-native skill sources, and runtime-provisioning hooks. Update formula/archive docs if path drift appears; otherwise record the pass in the release checklist and delete TD-074 at closeout.
**Acceptance Criteria**:
- [ ] 6 fitness-function test files exist and pass (must-be-TRUE)
- [ ] Allowed-edges table for `dependency_direction_test.dart` is a committed data file with rationale comments (must-be-TRUE)
- [ ] `testing_package_deps_test.dart` rejects any addition of `dartclaw_server` to testing's pubspec (must-be-TRUE)
- [ ] `enum_exhaustive_consumer_test.dart` covers `WorkflowRunStatus` + at least one other sealed-enum type; allowlist documents any unhandled consumer with rationale (must-be-TRUE)
- [ ] `max_method_count_per_file_test.dart` applies ≤40 methods/file; `task_executor.dart` and `foreach_iteration_runner.dart` entries in allowlist have explicit shrink targets (must-be-TRUE)
- [ ] Workflow runtime files have a fitness guard against concrete `SqliteWorkflowRunRepository` imports after S12 (must-be-TRUE)
- [ ] **TD-046** Crash-recovery smoke test exists and exercises reserve/start → hard kill → restart → orphan cleanup + recovery notice; gated by `@Tags(['integration'])` (must-be-TRUE)
- [ ] TD-046 entry deleted from public `dev/state/TECH-DEBT-BACKLOG.md` at sprint close
- [ ] **TD-074** Homebrew/archive asset revalidation dry-run recorded; formula/archive docs updated if needed; TD-074 deleted or narrowed (must-be-TRUE)
- [ ] **Fitness-script blackout audit** — scan every governance script under `dev/tools/` and any CI-invoked workspace script for path-stale silent passes during the pre-restructure window (the same failure mode that masked TD-099/100/101 on `main`); record findings (any other script that was silently passing because its inputs no longer existed) and either fix or file as new TDs (must-be-TRUE)
- [ ] CI pipeline runs Level-2 suite on every PR (can be separate job from Level-1 for parallelism)
- [ ] Level-2 suite total runtime ≤5 min
**Asset refs**: governance rails rows (Level-2 checks, FF-DELTA-3, FF-DELTA-4)

---

### Phase 8 (Block H): Stretch Documentation Gap-Fill

_Stretch W7 — only if capacity remains after Blocks A–G. The user guide has real gaps but closing them is orthogonal to the stabilisation work._

#### S26: Docs Gap-Fill (pick 2 of 5)
**Status**: Spec Ready
**FIS**: `fis/s26-docs-gap-fill.md`
**Phase**: Block H: Stretch Docs
**Wave**: W7
**Dependencies**: S01, S02, S03, S05, S09, S10, S11, S12, S13, S15, S16, S17, S18, S19, S22, S23, S24, S25, S27, S28, S29, S31, S32, S33, S34, S35, S36, S37, S38. This is the concrete dependency set behind the wider "Blocks A–G complete" intent. S03, S05, S19, and S22 are the substantive doc-content prerequisites; the full non-retired Block A–G list is also included so dependency-aware workflow fan-out cannot start the W7 stretch story before the sprint implementation state is current.
**Parallel**: No
**Risk**: Low
**Scope**: Pick **2 of 5** candidate new or promoted user-guide pages: (a) promote `recipes/08-crowd-coding.md` to `docs/guide/crowd-coding.md` + add row to `docs/guide/README.md` Features table; (b) author new `docs/guide/governance.md` (rate limits, budgets, loop detection, `/stop`/`/pause`/`/resume`, admin sender model); (c) author new `docs/guide/skills.md` (SkillRegistry source priority, frontmatter schema, validation rules, user vs managed skills, `.dartclaw-managed` marker); (d) add Workflow Triggers section to `workflows.md` (chat commands, web launch forms, GitHub PR webhook setup + HMAC secrets); (e) add Alert Routing + Compaction Observability sections under `web-ui-and-api.md` or new `docs/guide/observability.md`. The other 3 defer to a dedicated docs gap-fill milestone.
**Acceptance Criteria**:
- [ ] 2 of the 5 candidate pages exist and are internally consistent with 0.16.5 reality
- [ ] `docs/guide/README.md` Features table / index updated for the new page(s)
- [ ] Cross-references from related guide pages added
- [ ] A user-guide reader can get from `README.md` to the new pages within ≤2 clicks
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

**Pre-execution gate**: this checked-in plan is pre-FIS. The `dev/specs/0.16.5/fis/` files named in the catalog are planned target filenames and must be generated before any `/dartclaw-exec-spec` invocation. Until those files exist, run the plan/spec generation step rather than treating the paths below as executable commands. (FIS authoring lives in private repo `docs/specs/0.16.5/fis/` — files appear at the public `dev/specs/0.16.5/fis/` location once ported via the `dartclaw-spec-port-to-public` skill at the start of implementation.)

**Per-wave gate** (applies to every wave below): before marking a wave complete, `dart analyze` workspace-wide must show 0 warnings, `dart test` workspace-wide must pass, and `dart format --set-exit-if-changed packages apps` must exit clean. A red wave blocks the next — do not stack decompositions on an unverified base. For Block E waves that touch `foreach_iteration_runner.dart`, `context_extractor.dart`, `workflow_executor_helpers.dart`, or `task_executor.dart`, also run the targeted suites called out in each story's acceptance criteria before merging.

1. **Phase 1 (Block A)** — Execute W1 stories (S01, S02, S03, S09) in parallel; each is independent. S09 (barrel narrowing) is mechanical and promoted to W1 so it clears the runway for S10 in W3. Then W2 runs S05 alone (needs S01's test baseline).
   - Target FIS after generation: `dev/specs/0.16.5/fis/s03-doc-currency-critical.md`
   - Target FIS after generation: `dev/specs/0.16.5/fis/s01-alert-classifier-safety.md` (S01 FIS name follows "s01-" prefix convention)
2. **Phase 2 (Block B)** — S10 in W3 after S01 + S09 have landed. This is the only governance-rails story that waits.
   - Target FIS after generation: `dev/specs/0.16.5/fis/s10-level-1-governance-checks.md`
3. **Phase 3–4 (Blocks C+D)** — W3 parallel cluster alongside S10: S11, S12, S13, S31, S32, S33, S34, and S37 are active; S30 is retired.
   - Target FIS after generation: `dev/specs/0.16.5/fis/s13-pre-decomposition-helpers.md`
4. **Phase 5 (Block E)** — W4 structural decomposition. S15 needs S13; S16 needs S33; S17/S18 are independent. Run as many in parallel as file ownership allows: S15 owns `foreach_iteration_runner.dart`, `context_extractor.dart`, and `workflow_executor_helpers.dart`; S16 owns `task_executor.dart`; S18 owns `server.dart`.
5. **Phase 6 (Block F)** — W5 doc closeout; single consolidated story covering three disjoint doc areas.
   - Target FIS after generation: `dev/specs/0.16.5/fis/s19-doc-closeout.md`
6. **Phase 7 (Block G)** — W5 parallel S23+S24+S35, then S22 (needs S10 baseline in place), S38 after S35, and S25 in W6.
7. **Phase 8 (Block H stretch)** — W7 only if capacity remains. Pick 2 of 5 candidate pages based on highest-user-impact.
8. Run `/dartclaw-review --mode gap` after each block's stories complete (the old `andthen:review-gap` standalone skill was absorbed into `dartclaw-review` as a mode — there is no separate gap-only skill in DartClaw).
   - Example: `/dartclaw-review --mode gap dev/specs/0.16.5/plan.md`
9. At sprint close:
   - Update public `dev/state/STATE.md` via the `/dartclaw-update-state` skill: phase → "0.16.6 — Planned (Web UI Stimulus Adoption)"; status → "Planning"; note "0.16.5 Stabilisation & Hardening complete (<N> stories)". (DartClaw has no ported equivalent of `andthen:ops` — state updates use the DC-NATIVE `dartclaw-update-state` skill.)
   - Delete resolved entries from public `dev/state/TECH-DEBT-BACKLOG.md` per its "Open items only" policy (line 3): TD-046, TD-052, TD-053, TD-054, TD-055, TD-056, TD-059 (already resolved by 0.16.4 S42), TD-060, TD-061, TD-063, TD-069, TD-072, TD-073, TD-074, TD-085 at minimum; TD-082/088/090 if S15/S23 close them fully; TD-029 if stretch shipped. Narrow TD-086 and TD-089 to any explicitly-deferred residuals rather than carrying their broad current wording.
   - Update public `dev/state/LEARNINGS.md` with two non-obvious findings: (1) the 8-files claim in the architecture review vs. the current ground truth — a cautionary note about relying on review-reported LOC counts without a sanity check; (2) the 0.16.4-S52 "deferred to TECH-DEBT-BACKLOG" routing was not actioned — only TD-066–TD-072 (from parallel reviews) were filed, while four ledger-routed items (`S28-ARTIFACTS`, `S13-ASSETS`, `TOKEN-EFFICIENCY F4/F5`, `STRUCT-OUTPUT-COMPAT`) sat unbooked for 9 days. Lesson: when a closure-ledger says "routed to backlog", actually file the entry in the same commit.

> **Status tracking**: Keep the Story Catalog table and each story's `**Status**` field in sync. When each FIS is generated, update the story's `**FIS**` field and set `**Status**` to `Spec Ready`. When implementation starts, set `**Status**` to `In Progress`. After implementation and review, tick the acceptance criteria and set `**Status**` to `Done`.

> **MVP boundary**: The release gate requires Block A + Block B (S01, S02, S03, S05, S09, S10, S27, S28, S29, **S37** — 10 stories) as the release floor — safety, quick wins, governance rails (now including the dartdoc lint-flip), architectural hygiene (ADR-023 + workflow↔task boundary fitness test), CLI command cleanup. Block C–F (S11, S12, S13, S15–S19, S31, **S32, S33, S34** — 12 stories, S30 retired 2026-04-30) are the structural consolidation and should ship; the three delta-review adds (S32 env-plan promotion, S33 binding coordinator, S34 ClaudeSettingsBuilder) are direct pre-reqs or enablers for S11/S15/S16. Block G (S22–S25, **S35, S36, S38** — 7 planned-target stories) is ambitious but pubs-safe now (pub.dev placeholder only) and now also carries the tech-debt mop-up (TD-046/074 in S25; TD-053/054/055/056/060/061/063/069/072/073/085/090 across S11/S22/S23/S03/S29; TD-082/088 in S15; TD-086 split between S13 and S23; TD-029 stretch under S23; TD-052 effectively closed by 0.16.4 S46), 0.16.4 review-driven cleanup items (R-L1/L2/L6, R-M7/M8 under S23), and delta-review Block-G adds (S35 enums, S36 naming, S38 readability). Block H (S26, stretch) is explicitly optional.
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

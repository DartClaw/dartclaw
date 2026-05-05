# S15 — Workflow Executor Logical-Library Reduction (post-0.16.4-S45 hotspots)

**Plan**: ../plan.md
**Story-ID**: S15

## Feature Overview and Goal

Re-scoped continuation of the workflow-executor decomposition arc. `workflow_executor.dart` (≤1,500 LOC target) was already met by 0.16.4 S45 — current 891 LOC. Remaining structural debt has shifted to three new hotspots: `foreach_iteration_runner.dart` (1,630 LOC → ≤900), `context_extractor.dart` (1,414 LOC → ≤600), and `workflow_executor_helpers.dart` (781 LOC → ≤400 OR delete). The story bundles the structural extractions with the correctness debts that ride naturally with them: cancellation threading (H4/H5), the duplicated promotion-gate / merge-resolve coordinator extractions (H10/H11/H12), two-control-flow reconciliation between `execute()` and `_PublicStepDispatcher.dispatchStep()` (H1/H2), and the resume/race correctness closures (TD-082, TD-088). File code-freeze on `foreach_iteration_runner.dart` during this story — bug-fix commits only.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see § "S15 — Workflow Executor Logical-Library Reduction (post-0.16.4-S45 hotspots)" + Shared Decision #5 + Binding PRD Constraints rows 22–24, 29, 71, 75, 85)_


## Required Context

> Cross-doc reference rules: see [`fis-authoring-guidelines.md`](${CLAUDE_PLUGIN_ROOT}/references/fis-authoring-guidelines.md#cross-document-references).

### From `plan.md` — "S15: Workflow Executor Logical-Library Reduction (post-0.16.4-S45 hotspots) — Scope"
<!-- source: ../plan.md#s15-workflow-executor-logical-library-reduction-post-0164-s45-hotspots -->
<!-- extracted: e670c47 -->
> **(a)** `foreach_iteration_runner.dart` reduction — 1,624 LOC, the new largest runner. Extract foreach/promotion/merge-resolve state-machine collaborators (e.g. `ForeachIterationScheduler`, `ForeachPromotionCoordinator`, `MergeResolveAttemptDriver`) rather than adding more `part` files. Target ≤900 LOC.
> **(b)** `context_extractor.dart` reduction — 950 LOC; extract structured-output schema validation and helpers into sibling files; target ≤600 LOC. Specific 4-way split candidate per 2026-04-30 review (M40): orchestrator + payload extraction in `context_extractor.dart` (~400 LOC); filesystem-output resolution + path safety (`_safeRelativeExistingFileClaim`, `_safeChangedFileSystemMatches`, `_existingSafeFileClaims`) → `filesystem_output_resolver.dart`; project-index sanitization (`_sanitizeProjectIndex`, `_sanitizeProjectRelativePath`) → `project_index_sanitizer.dart`; review-finding-count derivations → `review_finding_derivations.dart`. Path-safety is the most security-sensitive logic in the file and warrants a discoverable home.
> **(c)** `workflow_executor_helpers.dart` reduction — 762 LOC; reabsorb helpers into the runners that own the call (esp. provider-alias resolution at line 633) or split into purpose-named helper modules; target ≤400 LOC.
> **(d)** Underscore-prefixed context-key contract documentation — document the merge sites preserving keys prefixed with `_` plus scoped sub-namespaces (`_map.current`, `_foreach.current`, `_loop.current`, `_parallel.current.*`) in private repo `docs/architecture/workflow-architecture.md` or as an ADR-022 addendum. Mandatory first-commit doc.
> **(e)** TD-070 executor carry-over closure — confirm runners individually meet the fitness target after (a)–(c); update TD-070 with any specific residual surface that does not.
> **(f)** Iteration-runner control-flow correctness — thread cancellation through the inner bodies that S78 explicitly deferred: H4/H5 — `isCancelled` check inside `_executeMapStep` / `_executeForeachStep` / `_executeParallelGroup` / `_dispatchForeachIteration` / `_executeLoop`. Today the only cancellation honoured is the drain-via-task-status path for currently-in-flight tasks; a cancelled run with 30 pending iterations and 4 in-flight processes all 30. Fix folds naturally into the `ForeachIterationScheduler` / `MapIterationScheduler` extraction in (a).
> **(g)** Promotion gate + merge-resolve coordinator extraction — the promotion gate logic in `_dispatchForeachIteration` (≈eight near-identical recordFailure+persist+inFlightCount-- +fire-event branches at `foreach_iteration_runner.dart:567-833`) plus the equivalent in `map_iteration_dispatcher.dart:224-305` is the single biggest LoC reduction opportunity. Extract `PromotionCoordinator` returning a typed `PromotionOutcome` ADT, used by both. The merge-resolve FSM (~550 LoC at `:899-1456`) extracts to `MergeResolveCoordinator` with a typed `MergeResolveState` value object replacing the ~13 stringly-typed magic context keys. Same treatment lets foreach + map share scheduler internals.
> **(h)** Two-control-flow reconciliation — production `WorkflowExecutor.execute()` (615-line procedural switch) and `_PublicStepDispatcher.dispatchStep()` are two parallel implementations diverging in non-trivial ways: the public dispatcher does not persist `_parallel.current.stepIds` / `_parallel.failed.stepIds`, doesn't run `_maybeCommitArtifacts`, doesn't honour `step.onError == 'continue'` for action nodes, never runs the `promoteAfterSuccess` pass. Either invert the relationship (have `execute()` loop via the dispatcher with hooks for production-only side effects) or rename the public surface to make the gap explicit (`dispatchStepForScenario`). Pick the smaller diff; document the choice. Also extract the open-coded context-filter-by-prefix policy that's duplicated 6+ times in `workflow_executor.dart` plus once in `parallel_group_runner.dart:131`.
> **(i)** Resume/race correctness closures (TD-088 + TD-082) — close the two small correctness debts instead of leaving them as passive backlog. TD-088: audit whether production crash recovery always persists `executionCursor` for map/foreach; if yes, delete or assert the loop-only `_resumeCursor` fallback so map/foreach cannot silently restart from scratch; if no, add symmetric map/foreach reconstruction plus a regression test. TD-082: replace the `_waitForTaskCompletion` early-completion shortcut with a single-source-of-truth completer / serialized subscription path so completion and pause/abort events cannot race through `Future.any` ordering ambiguity.
>
> Uses S13 helpers. Preserves all call sites and public API. **File code-freeze on `foreach_iteration_runner.dart`** during this story: bug-fix commits only.

### From `plan.md` — "S15 Acceptance Criteria"
<!-- source: ../plan.md#s15-workflow-executor-logical-library-reduction-post-0164-s45-hotspots -->
<!-- extracted: e670c47 -->
> - [ ] `foreach_iteration_runner.dart` ≤900 LOC (must-be-TRUE)
> - [ ] `context_extractor.dart` ≤600 LOC (must-be-TRUE)
> - [ ] `workflow_executor_helpers.dart` ≤400 LOC OR file deleted with helpers absorbed (must-be-TRUE)
> - [ ] Underscore-prefixed context-key contract documented (must-be-TRUE)
> - [ ] TD-070 executor portion closed (entry deleted or narrowed to a specific named residue) (must-be-TRUE)
> - [ ] Existing `dart test packages/dartclaw_workflow` passes with zero test changes (must-be-TRUE)
> - [ ] Integration tests (`parallel_group_test.dart`, `map_step_execution_test.dart`, `loop_execution_test.dart`, `gate_evaluator_test.dart`) all pass
> - [ ] Public API exposed by `dartclaw_workflow` barrel is unchanged (S09 narrowing already reflects intended surface)
> - [ ] `max_file_loc_test.dart` (S10) passes without an allowlist entry for `foreach_iteration_runner.dart`
> - [ ] **(f) cancellation threading** — `isCancelled` checked at the top of `_dispatchForeachIteration`, before each child dispatch in `_executeMapStep` / `_executeForeachStep` / `_executeLoop`, and before each peer dispatch in `_executeParallelGroup`. Regression test: cancelled run with 30 pending iterations + 4 in-flight does NOT process all 30 (must-be-TRUE)
> - [ ] **(g) `PromotionCoordinator`** extracted; both foreach and map dispatchers consume it; the eight duplicated recordFailure+persist+inFlightCount-- +fire-event branches in `_dispatchForeachIteration` collapse to a single typed-outcome match (must-be-TRUE)
> - [ ] **(g) `MergeResolveCoordinator`** extracted; `MergeResolveState` typed value object replaces the magic `_merge_resolve.*` context keys (must-be-TRUE)
> - [ ] **(g) Foreach ↔ Map scheduler dedupe** — the two `_executeXxxStep` methods share a common scheduler internal so their dispatch loops are not byte-near-duplicates (must-be-TRUE)
> - [ ] **(h) Two-control-flow reconciliation** — either `execute()` consumes the dispatcher OR the public surface is renamed to flag the scenario-only contract; context-filter-by-prefix policy lives in one helper (must-be-TRUE)
> - [ ] **TD-088** map/foreach resume path either reconstructs from persisted state or fails fast with a regression test proving no silent restart-from-scratch (must-be-TRUE)
> - [ ] **TD-082** `_waitForTaskCompletion` early-completion shortcut has no `Future.any` ordering race between task completion and pause/abort; regression test added (must-be-TRUE)

### From `.technical-research.md` — "Shared Decision #5: S13 → S15 DRY-helper contract"
<!-- source: ../.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> WHAT: S13 produces `mergeContextPreservingPrivate(WorkflowRun, WorkflowContext) → Map<String, dynamic>`, `_fireStepCompleted(stepIndex, success, result)` (or `WorkflowRunMutator.recordStepSuccess/Failure/Continuation`), `truncate()` in `dartclaw_core/lib/src/util/string_util.dart` (char-count; `truncateUtf8Bytes` separate), `unwrapCollectionValue(...)`. `YamlTypeSafeReader` in `dartclaw_config`.
> CONSUMER: S15.
> WHY: S15 carries duplication across the split without these.

### From `.technical-research.md` — "Shared Decision #14: Step-outcome marker / ADR-022"
<!-- source: ../.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> Every workflow step honours `<step-outcome>{"outcome":"succeeded|failed|needsInput","reason":"..."}</step-outcome>` unless `emitsOwnOutcome: true`. Executor writes `step.<id>.outcome` and `step.<id>.outcome.reason` into workflow context. **S15 must preserve this**; S23 R-L1 adds the missing `_log.warning` (run-id + step-id) when marker absent for non-`emitsOwnOutcome` steps, alongside the existing `workflow.outcome.fallback` increment.

### From `.technical-research.md` — "Shared Decision #15: `<workflow-context>` marker / ADR-023"
<!-- source: ../.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> Workflow↔task boundary marker. Constants `kWorkflowContextTag`/`Open`/`Close` live in `packages/dartclaw_workflow/lib/src/workflow/workflow_output_contract.dart`. Direct-insert affordance (`workflow_executor.dart:2585-2589`, inside `executionTransactor.transaction()`) is scoped to atomic three-row creation only; reads + lifecycle still go via narrow `WorkflowTaskService` interface in `dartclaw_core`. **S15 must preserve this transaction boundary unchanged.**

### From `.technical-research.md` — "Binding PRD Constraints (rows 1, 2, 3, 22–24, 29, 71, 75, 85)"
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #1: "JSONL control protocol, REST API payload shapes, SSE envelope formats unchanged."
> #2: "No new dependencies in any package."
> #3: "Workspace-wide strict-casts + strict-raw-types must remain on throughout."
> #22: "`foreach_iteration_runner.dart` ≤900 LOC after extracting foreach/promotion/merge-resolve state-machine collaborators."
> #23: "`context_extractor.dart` ≤600 LOC after structured-output schema validation and helpers move to sibling modules."
> #24: "`workflow_executor_helpers.dart` ≤400 LOC or deleted with helpers absorbed into owning runners."
> #29: "`max_file_loc_test.dart` and `constructor_param_count_test.dart` fitness functions pass."
> #71: "Behavioural regressions post-decomposition: Zero — every existing test remains green."
> #75: "Existing SSE envelope format is unchanged (no breaking protocol change)." _(restated for emphasis on event ordering)_
> #85: "Workflow decomposition introduces a latent defect → Existing workflow tests catch at unit level; integration proof via `plan-and-implement` E2E scenario."


## Deeper Context

- `dev/specs/0.16.5/fis/s13-pre-decomposition-helpers.md` — DRY helper contracts S15 consumes (`mergeContextPreservingPrivate`, `_fireStepCompleted` / `WorkflowRunMutator.recordStep*`, `truncate`, `unwrapCollectionValue`). S15 must use these where applicable rather than reinventing.
- `dev/specs/0.16.5/.technical-research.md#s15--workflow-executor-logical-library-reduction-post-0164-s45-hotspots` — file map (primary files + their LOC budgets + extraction targets).
- Private repo `docs/specs/0.16.4/fis/s78-pre-tag-control-flow-correctness.md` — predecessor that closed the four directly-shippable defects (parallel-group pause-as-failed, `Future.any`+1ms, serialize-remaining idempotency, `mapAlias` resolver drop). S15 closes the structural tail that S78 explicitly deferred.
- Private repo `docs/specs/0.16.4/fis/s45-workflow-executor-decomposition.md` — the prior decomposition that landed the dispatcher + per-node-kind runners; pattern continues here for `ForeachIterationScheduler` etc.
- Public `dev/state/TECH-DEBT-BACKLOG.md#td-070`, `#td-082`, `#td-088` — backlog entries this story closes/narrows.
- Public `docs/guide/architecture.md` — workflow architecture overview; the underscore-context-key contract doc (scope (d)) lives in the **private** repo `docs/architecture/workflow-architecture.md` per plan, with a brief pointer note from the public doc if cross-referenced.


## Success Criteria (Must Be TRUE)

### Structural targets (Plan ACs verbatim)
- [ ] `foreach_iteration_runner.dart` ≤900 LOC (Verify: `wc -l packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart`)
- [ ] `context_extractor.dart` ≤600 LOC (Verify: `wc -l packages/dartclaw_workflow/lib/src/workflow/context_extractor.dart`)
- [ ] `workflow_executor_helpers.dart` ≤400 LOC OR file deleted with helpers absorbed into the runner that owns the call (Verify: `wc -l` returns ≤400 OR file does not exist)
- [ ] Underscore-prefixed context-key contract documented (Verify: file exists at private repo `docs/architecture/workflow-architecture.md` ADR-022 addendum (or the agreed alternate) describing `_map.current`, `_foreach.current`, `_loop.current`, `_parallel.current.*` semantics, and the merge sites that preserve them)
- [ ] TD-070 executor portion closed: entry in `dev/state/TECH-DEBT-BACKLOG.md` either deleted or narrowed to a specific named residue with a follow-up issue link
- [ ] `dart test packages/dartclaw_workflow` passes **with zero test changes** to existing files (any test edit beyond additive new tests for cancellation/TD-082/TD-088 is a regression — Constraint #71)
- [ ] Integration tests pass: `parallel_group_test.dart`, `map_step_execution_test.dart`, `loop_execution_test.dart`, `gate_evaluator_test.dart`
- [ ] Public API exposed by `dartclaw_workflow` barrel is unchanged (S09 already narrowed the intended surface — diff `packages/dartclaw_workflow/lib/dartclaw_workflow.dart` shows zero export changes)
- [ ] `max_file_loc_test.dart` (S10 fitness) passes **without an allowlist entry for `foreach_iteration_runner.dart`**

### Correctness closures (Plan ACs verbatim — new in S15)
- [ ] **(f) cancellation threading**: `isCancelled` checked at the top of `_dispatchForeachIteration`, before each child dispatch in `_executeMapStep` / `_executeForeachStep` / `_executeLoop`, and before each peer dispatch in `_executeParallelGroup`. Regression test (additive): cancelled run with 30 pending iterations + 4 in-flight does NOT process all 30 — covered by Scenario "Cancelled run with pending iterations stops promptly"
- [ ] **(g) `PromotionCoordinator`** extracted; both foreach and map dispatchers consume it; the eight duplicated recordFailure+persist+inFlightCount-- +fire-event branches in `_dispatchForeachIteration` collapse to a single typed-`PromotionOutcome` match. Verify: `rg "inFlightCount--" packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart` returns ≤1 match (the coordinator call site)
- [ ] **(g) `MergeResolveCoordinator`** extracted; `MergeResolveState` typed value object replaces the ~13 stringly-typed `_merge_resolve.<id>.<i>.*` context keys (`pre_attempt_sha`, `serialize_remaining_phase`, `serializing_iter_index`, `failed_attempt_number`, `serialize_remaining_event_emitted`, …). Verify: `rg "_merge_resolve\." packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart` returns zero matches outside the coordinator's own internal serialization layer (one named module).
- [ ] **(g) Foreach ↔ Map scheduler dedupe**: the two dispatch loops share a common scheduler internal — `ForeachIterationScheduler` / `MapIterationScheduler` consume the same base or share a common helper; they are not byte-near-duplicates. Verify: a structural diff on the two dispatch loops shows ≤30% line overlap (qualitative review during PR).
- [ ] **(h) Two-control-flow reconciliation**: either `execute()` consumes the dispatcher OR the public surface is renamed to `dispatchStepForScenario` (or equivalent) to flag the scenario-only contract. Whichever is chosen, the **decision is recorded** in this FIS's Architecture Decision section and reflected in code. Context-filter-by-prefix policy (currently duplicated 6+ times in `workflow_executor.dart` + once in `parallel_group_runner.dart:131`) lives in **one helper** (Verify: `rg "startsWith\('_'\)" packages/dartclaw_workflow/lib/src/workflow/` count drops to ≤2 — the helper definition + at most one comment).
- [ ] **TD-088** map/foreach resume path either reconstructs from persisted `executionCursor` or fails fast with a regression test proving no silent restart-from-scratch (Verify: scenario "Cursor persistence across compaction").
- [ ] **TD-082** `_waitForTaskCompletion` early-completion shortcut has no `Future.any` ordering race between task completion and pause/abort; regression test added that exercises both completions firing in the same microtask tick.

### Health Metrics (Must NOT Regress)
- [ ] `dart analyze` workspace-wide: 0 warnings, 0 errors (Constraint #3 — strict-casts + strict-raw-types remain on)
- [ ] `dart test` workspace-wide passes
- [ ] No new dependencies in any pubspec (Constraint #2)
- [ ] JSONL control protocol, REST API payloads, SSE envelope formats byte-unchanged (Constraint #1) — verified by existing protocol/SSE tests passing unmodified
- [ ] ADR-022 step-outcome contract preserved: executor still writes `step.<id>.outcome` and `step.<id>.outcome.reason`; the `workflow.outcome.fallback` increment still fires
- [ ] ADR-023 workflow↔task boundary preserved: the direct-insert transaction at `workflow_executor.dart:2585-2589` (inside `executionTransactor.transaction()`) is unchanged in scope and contract
- [ ] Event ordering and payloads identical for the happy path (every `WorkflowStepCompletedEvent`, `WorkflowStepStartedEvent`, parallel/map/foreach iteration events fire in the same order with the same payloads pre/post-refactor)


## Scenarios

### Workflow with parallel groups + map iterations + loop exit gates runs identically (happy)
- **Given** a workflow definition that combines a parallel group (4 peers), a map step (10 items, max-parallel 4), and a loop step with an exit gate
- **When** the workflow runs to completion under the existing test harness
- **Then** the sequence of emitted events (`WorkflowStepStartedEvent`, `WorkflowStepCompletedEvent`, parallel-group iteration events, map-iteration events, loop-iteration events) is **identical** in order, count, and payload to the pre-refactor recording; final workflow context is byte-equivalent; SSE envelope format is unchanged.

### Cursor persistence across compaction boundary (edge — TD-088)
- **Given** a map step at iteration 7/10 (or a foreach step at iteration 5/8), with `executionCursor` persisted by the production crash-recovery path
- **When** the runtime restarts mid-run and resumes the workflow
- **Then** execution continues at iteration 7 (resp. 5) — not from scratch — and the regression test asserts the resumed iteration index matches the persisted cursor; if the audit reveals production does NOT persist the cursor for map/foreach, the implementation either adds symmetric reconstruction or fails fast with a clear error rather than silently restarting from zero.

### Cancelled run with pending iterations stops promptly (edge — H4/H5)
- **Given** a foreach step with 30 pending iterations and `maxParallel = 4` (so 4 are in flight, 26 pending), running under the production cancellation path
- **When** `isCancelled` flips to true while the 4 in-flight iterations are still active
- **Then** the executor processes at most `min(maxParallel, in-flight) = 4` additional iterations to drain the in-flight set, then halts; the remaining 22+ pending iterations are **not** dispatched. Regression test asserts iteration-dispatch count ≤ initial in-flight + already-completed.

### Pause/abort race against task completion (edge — TD-082)
- **Given** `_waitForTaskCompletion` awaiting a task that completes in the same microtask tick as a pause/abort signal
- **When** both completers fire under the new single-source-of-truth path
- **Then** the outcome is deterministic (one wins per a documented total ordering — completion-then-abort or abort-then-completion, whichever the new path encodes); regression test exercises both orderings and asserts no `Future.any`-style ambiguity (no flakiness across 100 runs).

### Malformed workflow node triggers identical validation error (error)
- **Given** a synthesised workflow definition with a malformed node (e.g. unknown step `type:`, missing required `mapOver:`, invalid `gate:` expression)
- **When** the executor attempts to load and run it
- **Then** the **same** `FormatException` / validation-failure event fires with the **same** message and field-pinpoint as before the refactor; existing validation tests pass unchanged.

### Negative path — empty foreach collection (boundary)
- **Given** a foreach step whose `_foreach.collection` evaluates to an empty list
- **When** the step executes
- **Then** zero iterations dispatch; the step completes with `outcome: succeeded` (or whatever the pre-refactor behaviour records); event ordering is identical pre/post-refactor.


## Scope & Boundaries

### In Scope
- (a) `foreach_iteration_runner.dart` reduction to ≤900 LOC via `ForeachIterationScheduler`, `PromotionCoordinator`, `MergeResolveCoordinator` extractions (no new `part` files).
- (b) `context_extractor.dart` 4-way split: orchestrator + payload extraction stay; new sibling files `filesystem_output_resolver.dart` (path-safety helpers `_safeRelativeExistingFileClaim`, `_safeChangedFileSystemMatches`, `_existingSafeFileClaims`), `project_index_sanitizer.dart` (`_sanitizeProjectIndex`, `_sanitizeProjectRelativePath`), `review_finding_derivations.dart` (review-finding-count derivations).
- (c) `workflow_executor_helpers.dart` reduction to ≤400 LOC OR deletion: provider-alias resolution at line 633 reabsorbed into the runner that owns the call (or moved to a purpose-named helper module).
- (d) Underscore-prefixed context-key contract doc at private repo `docs/architecture/workflow-architecture.md` (ADR-022 addendum form), enumerating `_map.current`, `_foreach.current`, `_loop.current`, `_parallel.current.*` and the merge sites that preserve them. **Mandatory first commit.**
- (e) TD-070 closure (entry deleted or narrowed to a specific named residue).
- (f) Cancellation threading at the documented sites; regression test (30 pending + 4 in-flight).
- (g) `PromotionCoordinator` + typed `PromotionOutcome` ADT, used by both foreach and map dispatchers; `MergeResolveCoordinator` + `MergeResolveState` typed value object replacing magic `_merge_resolve.*` context keys; foreach ↔ map scheduler dedupe.
- (h) Two-control-flow reconciliation between `WorkflowExecutor.execute()` and `_PublicStepDispatcher.dispatchStep()`; context-filter-by-prefix policy consolidated to one helper.
- (i) TD-088 map/foreach resume cursor closure; TD-082 `_waitForTaskCompletion` race fix.
- Use S13 helpers (`mergeContextPreservingPrivate`, `_fireStepCompleted` / `WorkflowRunMutator`, `unwrapCollectionValue`, `truncate`) wherever applicable in extracted modules.
- Update `dev/state/TECH-DEBT-BACKLOG.md` for TD-070 narrow/closure; mark TD-082 + TD-088 as Resolved-by-S15.

### What We're NOT Doing
- Introducing a new dispatch model — preserve dispatcher / per-node-kind runner architecture from 0.16.4 S45 (high-risk rewrite without test net for new design).
- Touching `step_outcome_normalizer.dart`, `workflow_artifact_committer.dart`, `workflow_budget_monitor.dart` — already extracted by 0.16.4 S45/S46.
- Changing semantics of the `_workflow*` task-config keys — S34 owns the typed-accessor surface for those.
- Deferring TD-082 / TD-088 — both ride naturally with this decomposition (in scope here per plan (i)).
- Modifying ADR-022 step-outcome semantics or ADR-023 workflow↔task boundary — both contracts preserved verbatim.
- Adding `_log.warning` for the missing step-outcome marker case — that's S23 R-L1's slice, deliberately out of S15's surface.
- Modifying public `dartclaw_workflow` barrel exports — S09 already settled the intended surface.

### Agent Decision Authority
- **Autonomous**: choice between `execute()`-consumes-dispatcher inversion (h) vs. public-surface rename (`dispatchStepForScenario`) — pick the smaller diff and document the choice in this FIS's Architecture Decision section before extending; choice of helper-module split for (c) (single ≤400-LOC file vs. deletion-with-absorption); naming of new `ForeachIterationScheduler` / `MapIterationScheduler` collaborators if the suggested names conflict with existing symbols.
- **Escalate**: any change that requires touching the public `dartclaw_workflow` barrel; any change that alters SSE/REST/JSONL envelopes; any test edit beyond additive new regression tests (Constraint #71); any choice that would push a runner over the LOC ceiling and require an allowlist entry.


## Architecture Decision

**We will**: preserve the existing dispatcher / per-node-kind runner architecture (from 0.16.4 S45) and extract additional collaborators — `ForeachIterationScheduler`, `PromotionCoordinator` (returning a typed `PromotionOutcome` ADT), `MergeResolveCoordinator`, and a typed `MergeResolveState` value object — rather than introduce a new dispatch model. For (h), reconcile `execute()` and `_PublicStepDispatcher.dispatchStep()` by **inverting the relationship** (have `execute()` loop via the dispatcher with hooks for production-only side effects: `_parallel.*` persistence, `_maybeCommitArtifacts`, `step.onError == 'continue'` for action nodes, `promoteAfterSuccess` pass) when the diff stays small; otherwise rename the public dispatcher to `dispatchStepForScenario` to flag the scenario-only contract. The implementing engineer picks based on diff size and records the choice in **Implementation Observations** at completion.

**Rationale**: the existing 2,382 LOC of workflow tests is written against the current call sites; preserving the architecture avoids regression risk. The collaborator extractions are pattern-continuations of S45's dispatcher/runner split — engineers and reviewers already have the muscle memory. The promotion-gate and merge-resolve extractions are the single biggest LoC reduction opportunity (≈8 near-identical branches in `_dispatchForeachIteration:567-833` plus the equivalent in `map_iteration_dispatcher.dart:224-305`); collapsing these into a typed-outcome match is mechanically obvious once the ADT exists. TD-082 + TD-088 ride with the iteration-runner work because the affected code paths (`_waitForTaskCompletion`, resume cursor read) are inside the methods being decomposed — closing them in-flight is cheaper than a separate story.

**Alternatives considered**:
1. **Rewrite executor entirely** — rejected: high risk, no test net for a new design; the prior dispatcher/runner architecture demonstrably works (0.16.4 S45 closed without behavioural regression).
2. **Defer correctness fixes (TD-082/088)** — rejected: TD-088 leaves a silent restart-from-scratch risk on map/foreach crash recovery, and TD-082 leaves a `Future.any` ordering race; both touch code paths being opened anyway by (a) and (g), so closing them in the same story is cheaper than two separate passes and removes the "drift while open" risk.
3. **Skip the foreach ↔ map scheduler dedupe** — rejected: the two `_executeXxxStep` methods are byte-near-duplicates today; leaving them duplicated post-extraction means future scheduler changes have to be applied in two places, defeating the decomposition's maintenance benefit.

References: ADR-022 (step-outcome contract — preserved), ADR-023 (workflow↔task boundary — preserved), 0.16.4 S45/S46 decomposition pattern (continued).


## Technical Overview

### Integration Points
- **Foreach runner** consumes `PromotionCoordinator`, `MergeResolveCoordinator`, `ForeachIterationScheduler`, S13 helpers (`mergeContextPreservingPrivate`, `_fireStepCompleted` / `WorkflowRunMutator.recordStep*`, `unwrapCollectionValue`).
- **Map iteration dispatcher** consumes the same `PromotionCoordinator` and shares scheduler internals with foreach (common base or shared helper; pick whichever yields the smaller diff).
- **Parallel group runner** consumes the consolidated context-filter-by-prefix helper (replacing its open-coded pass at line 131).
- **`workflow_executor.dart`** retains the ADR-023 direct-insert transaction at `:2585-2589` unchanged; consumes the consolidated context-filter-by-prefix helper at all 6+ duplicated sites; either consumes the dispatcher (option 1) or has its public surface renamed (option 2).
- **`context_extractor.dart`** retains orchestrator + payload extraction; delegates to three new sibling modules (`filesystem_output_resolver.dart`, `project_index_sanitizer.dart`, `review_finding_derivations.dart`) — no public-API change.
- **No barrel surface change**: all new collaborators are `lib/src/` internal types; the `dartclaw_workflow` barrel is untouched.

### Data Models
- `PromotionOutcome` — sealed/typed ADT with arms covering the eight near-identical foreach-promotion-gate branches: success-promote, failure-record, in-flight-decrement, fire-event, etc. Each arm carries the minimal payload the call site needs (run id, iteration index, reason, event payload). One canonical pattern-match at the call site replaces the eight inline branches.
- `MergeResolveState` — typed value object replacing the ~13 stringly-typed `_merge_resolve.<id>.<i>.*` context keys: fields for `preAttemptSha`, `serializeRemainingPhase` (likely an enum), `serializingIterIndex`, `failedAttemptNumber`, `serializeRemainingEventEmitted`, etc. Serialization layer at the coordinator boundary translates to/from the persisted context shape so the on-wire format is unchanged (Constraint #1).
- `MergeResolveCoordinator` — coordinator class wrapping the FSM logic currently spread across `foreach_iteration_runner.dart:899-1456`; exposes verbs for the FSM transitions, internalizes the `_merge_resolve.*` key shape.
- `ForeachIterationScheduler` (and `MapIterationScheduler`, sharing a base or helper) — schedules iteration dispatch under `maxParallel` constraints; honours `isCancelled` at each dispatch point per (f).


## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart                        | Target file (1,630 LOC → ≤900); contains the eight duplicated promotion-gate branches and the merge-resolve FSM
file   | packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart:567-833                | Eight near-identical recordFailure+persist+inFlightCount-- +fire-event branches → collapse via PromotionCoordinator + PromotionOutcome
file   | packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart:899-1456               | Merge-resolve FSM (~550 LOC) → MergeResolveCoordinator + MergeResolveState
file   | packages/dartclaw_workflow/lib/src/workflow/map_iteration_dispatcher.dart:224-305                | Promotion-gate equivalent → consume same PromotionCoordinator (dedupe)
file   | packages/dartclaw_workflow/lib/src/workflow/context_extractor.dart                               | Target file (1,414 LOC → ≤600); 4-way split target per plan (b) + technical research M40
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_executor_helpers.dart                       | Target file (781 LOC → ≤400 OR delete); provider-alias resolution at line 633 reabsorbs into the runner that owns the call
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart                               | Target file (891 LOC); retains ADR-023 transaction; consumes consolidated context-filter helper
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart:2585-2589                     | ADR-023 direct-insert transaction boundary — preserve scope and contract
file   | packages/dartclaw_workflow/lib/src/workflow/parallel_group_runner.dart:131                       | Open-coded context-filter-by-prefix duplicate → consume the one consolidated helper
file   | packages/dartclaw_workflow/lib/src/workflow/step_dispatcher.dart                                 | Architecture pattern from 0.16.4 S45 — continue the dispatcher/runner split style
file   | packages/dartclaw_workflow/lib/src/workflow/bash_step_runner.dart                                | Architecture pattern — small focused per-kind runner template
file   | packages/dartclaw_workflow/lib/src/workflow/loop_step_runner.dart                                | Sibling runner consuming S13 helpers; reference for cancellation site conventions
file   | dev/specs/0.16.5/fis/s13-pre-decomposition-helpers.md                                            | Helper contracts S15 consumes — read before extracting
file   | packages/dartclaw_testing/test/fitness/max_file_loc_test.dart                                    | S10 fitness test that must pass without an allowlist entry for foreach_iteration_runner.dart
file   | packages/dartclaw_workflow/test/workflow/parallel_group_test.dart                                | Integration test that must pass unchanged
file   | packages/dartclaw_workflow/test/workflow/map_step_execution_test.dart                            | Integration test that must pass unchanged
file   | packages/dartclaw_workflow/test/workflow/loop_execution_test.dart                                | Integration test that must pass unchanged
file   | packages/dartclaw_workflow/test/workflow/gate_evaluator_test.dart                                | Integration test that must pass unchanged
```


## Constraints & Gotchas

- **Constraint (Binding #1)**: SSE / REST / JSONL formats unchanged — verify by running existing protocol/SSE tests unmodified. The on-wire shape of persisted workflow context must also remain identical post-`MergeResolveState` extraction (the typed VO serialises through a translation layer; the persisted `_merge_resolve.*` keys keep their existing names and JSON shape).
- **Constraint (Binding #2)**: No new dependencies in any pubspec.
- **Constraint (Binding #3)**: Workspace strict-casts + strict-raw-types remain on; new types must satisfy them.
- **Constraint (Binding #71)**: Zero behavioural regressions — existing 2,382 LOC of workflow tests must pass **without test edits** beyond additive new regression tests for cancellation (f), TD-082, TD-088. Any edit to an existing test is a regression signal.
- **Constraint (ADR-022)**: step-outcome contract preserved — executor still writes `step.<id>.outcome` and `step.<id>.outcome.reason`; `workflow.outcome.fallback` increment still fires. Adding `_log.warning` for the missing-marker case is S23's slice, **not S15**.
- **Constraint (ADR-023)**: workflow↔task boundary preserved — direct-insert at `workflow_executor.dart:2585-2589` (inside `executionTransactor.transaction()`) keeps its scope (atomic three-row creation only); reads + lifecycle still go via the narrow `WorkflowTaskService` interface in `dartclaw_core`.
- **Constraint (file code-freeze)**: `foreach_iteration_runner.dart` is **frozen** during this story to bug-fix commits only — no concurrent feature edits should land in this file. Coordinate with any reviewer who has a parallel branch touching it.
- **Avoid**: adding more `part` files to `foreach_iteration_runner.dart` to "split" it — extract collaborators as separate `lib/src/workflow/*.dart` files instead (the plan is explicit on this).
- **Avoid**: changing the persisted on-wire `_merge_resolve.*` key names or JSON shape during the `MergeResolveState` extraction — this would silently break crash-recovery for in-flight workflows. Translation layer at the coordinator boundary keeps the on-wire shape identical.
- **Avoid**: reintroducing a runtime exhaustiveness check for the new `PromotionOutcome` ADT — sealed-class compiler exhaustiveness is the contract (matches the same pattern S01 establishes for `DartclawEvent`).
- **Critical**: cancellation threading must check `isCancelled` at the **top** of `_dispatchForeachIteration` (before any dispatch decisions), and **before each child dispatch** in `_executeMapStep` / `_executeForeachStep` / `_executeLoop`, and **before each peer dispatch** in `_executeParallelGroup` — anything coarser leaves the 30-pending-+-4-in-flight defect open. The regression test asserts the iteration-dispatch count.
- **Critical**: the underscore-prefixed context-key contract doc (scope (d)) is the **mandatory first commit** of this story per plan — it locks the contract before extractions can subtly drift it.


## Implementation Plan

> Vertical slice ordering: doc + helper extractions land first (cheapest to revert, unblock everything else); coordinators next; cancellation threading and reconciliation after coordinators exist; correctness closures last; final fitness + tests.

### Implementation Tasks

- [ ] **TI01** Underscore-prefixed context-key contract documented as ADR-022 addendum (mandatory first commit per plan (d))
  - Create or extend private repo `docs/architecture/workflow-architecture.md` (or write the addendum to the existing ADR-022 file in the private repo, whichever is the established home — confirm during implementation) enumerating `_map.current`, `_foreach.current`, `_loop.current`, `_parallel.current.*` semantics, the merge sites that preserve them, and the rule that new underscore-prefixed keys must extend the documented set.
  - **Verify**: doc file exists; `rg "_map\.current|_foreach\.current|_loop\.current|_parallel\.current" <doc-path>` finds each namespace explicitly described; commit lands before any code-extraction commit.

- [ ] **TI02** Extract `PromotionCoordinator` + typed `PromotionOutcome` ADT, used by both foreach and map dispatchers
  - New file `packages/dartclaw_workflow/lib/src/workflow/promotion_coordinator.dart`. `PromotionOutcome` is a sealed ADT covering the eight foreach-promotion-gate branches (`foreach_iteration_runner.dart:567-833`) plus the map equivalent (`map_iteration_dispatcher.dart:224-305`). Both call sites delegate to one coordinator method returning `PromotionOutcome`; one canonical pattern-match per call site replaces the eight inline branches. Use S13 `_fireStepCompleted` / `WorkflowRunMutator.recordStep*` for event firing.
  - **Verify**: `rg "inFlightCount--" packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart` returns ≤1 match (the coordinator call site); `rg "inFlightCount--" packages/dartclaw_workflow/lib/src/workflow/map_iteration_dispatcher.dart` returns ≤1; existing `parallel_group_test.dart`, `map_step_execution_test.dart`, `loop_execution_test.dart` pass unchanged.

- [ ] **TI03** Extract `MergeResolveCoordinator` + typed `MergeResolveState` value object replacing magic `_merge_resolve.*` context keys
  - New file `packages/dartclaw_workflow/lib/src/workflow/merge_resolve_coordinator.dart` wrapping the ~550 LOC FSM at `foreach_iteration_runner.dart:899-1456`. `MergeResolveState` typed VO replaces the ~13 magic context keys (`pre_attempt_sha`, `serialize_remaining_phase`, `serializing_iter_index`, `failed_attempt_number`, `serialize_remaining_event_emitted`, …). Translation layer at the coordinator boundary serialises VO ↔ persisted context map so on-wire JSON shape is **byte-identical** (Constraint #1).
  - **Verify**: `rg "_merge_resolve\." packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart` returns zero matches outside the coordinator; persisted-context fixtures (snapshot tests, if present) pass byte-identical; existing merge-resolve scenarios in `foreach_iteration_runner` tests pass unchanged.

- [ ] **TI04** Extract `ForeachIterationScheduler` + `MapIterationScheduler` sharing a common scheduler internal (foreach ↔ map dedupe per (g))
  - New files `foreach_iteration_scheduler.dart` + `map_iteration_scheduler.dart` (or a shared base / helper module — pick the smaller diff). Both schedulers honour `maxParallel`, drive iteration dispatch, and consume `PromotionCoordinator` from TI02. Dispatch loops are not byte-near-duplicates.
  - **Verify**: structural diff on the two scheduler dispatch loops shows ≤30% line overlap (qualitative review); `parallel_group_test.dart`, `map_step_execution_test.dart`, `loop_execution_test.dart` pass unchanged.

- [ ] **TI05** Cancellation threading at the documented sites (plan (f) — H4/H5)
  - Add `isCancelled` checks at: top of `_dispatchForeachIteration`; before each child dispatch in `_executeMapStep` / `_executeForeachStep` / `_executeLoop`; before each peer dispatch in `_executeParallelGroup`. Folds naturally into `ForeachIterationScheduler` / `MapIterationScheduler` extractions from TI04.
  - **Verify**: new regression test exercises a cancelled run with 30 pending iterations + 4 in-flight; asserts iteration-dispatch count ≤ initial in-flight + already-completed (NOT all 30). Test uses additive new test file (e.g. `iteration_cancellation_test.dart`) — existing tests not edited.

- [ ] **TI06** Two-control-flow reconciliation H1/H2 (plan (h))
  - Pick the smaller diff between (1) inverting the relationship — `WorkflowExecutor.execute()` consumes `_PublicStepDispatcher.dispatchStep()` with hooks for production-only side effects (`_parallel.*` persistence, `_maybeCommitArtifacts`, `step.onError == 'continue'` for action nodes, `promoteAfterSuccess` pass), or (2) renaming the public dispatcher to `dispatchStepForScenario` to flag the scenario-only contract. Record the choice in this FIS's `Implementation Observations`. Also extract the open-coded context-filter-by-prefix policy (duplicated 6+ times in `workflow_executor.dart` plus once in `parallel_group_runner.dart:131`) into **one helper**.
  - **Verify**: `rg "startsWith\('_'\)" packages/dartclaw_workflow/lib/src/workflow/` count drops to ≤2 (helper + at most one comment); existing `dart test packages/dartclaw_workflow` passes unchanged.

- [ ] **TI07** `context_extractor.dart` 4-way split per plan (b) + technical research M40
  - Keep orchestrator + payload extraction in `context_extractor.dart` (~400 LOC). Extract: path-safety helpers (`_safeRelativeExistingFileClaim`, `_safeChangedFileSystemMatches`, `_existingSafeFileClaims`) → new `filesystem_output_resolver.dart`; project-index sanitization (`_sanitizeProjectIndex`, `_sanitizeProjectRelativePath`) → new `project_index_sanitizer.dart`; review-finding-count derivations → new `review_finding_derivations.dart`. Path-safety stays the most security-sensitive logic — give it a discoverable home.
  - **Verify**: `wc -l packages/dartclaw_workflow/lib/src/workflow/context_extractor.dart` ≤600; the three new files exist; `dart test packages/dartclaw_workflow` passes; `dart analyze` clean.

- [ ] **TI08** `workflow_executor_helpers.dart` reduction OR deletion (plan (c))
  - Reabsorb provider-alias resolution at line 633 into the runner that owns the call (or move to a purpose-named helper module). Either reduce to ≤400 LOC or delete the file with helpers fully absorbed. Use S13 helpers wherever applicable to avoid reintroducing duplication.
  - **Verify**: `wc -l packages/dartclaw_workflow/lib/src/workflow/workflow_executor_helpers.dart` ≤400 OR file does not exist; `dart test packages/dartclaw_workflow` passes; `dart analyze` clean.

- [ ] **TI09** TD-088 closure: map/foreach resume cursor (plan (i))
  - Audit production crash-recovery path: does it persist `executionCursor` for map/foreach? If yes, delete or assert the loop-only `_resumeCursor` fallback so map/foreach cannot silently restart from scratch. If no, add symmetric map/foreach reconstruction. Record the audit finding in `Implementation Observations`. Add additive regression test asserting the resumed iteration index matches the persisted cursor (or fails fast cleanly if reconstruction is impossible).
  - **Verify**: regression test passes; `rg "_resumeCursor" packages/dartclaw_workflow/lib/src/workflow/` either zero (deleted) or only inside an assertion / fast-fail path; `dev/state/TECH-DEBT-BACKLOG.md` TD-088 entry marked Resolved-by-S15.

- [ ] **TI10** TD-082 closure: `_waitForTaskCompletion` race fix (plan (i))
  - Replace the `Future.any`-based early-completion shortcut with a single-source-of-truth completer / serialized subscription path so completion and pause/abort events cannot race. Document the chosen total ordering in the method dartdoc.
  - **Verify**: additive regression test exercises both completion-then-abort and abort-then-completion microtask orderings, asserts deterministic outcome across 100 runs (no flakiness); `dev/state/TECH-DEBT-BACKLOG.md` TD-082 entry marked Resolved-by-S15.

- [ ] **TI11** Use S13 helpers wherever applicable in extracted modules
  - In all new collaborator files (TI02–TI08): use `mergeContextPreservingPrivate` for context merges, `_fireStepCompleted` / `WorkflowRunMutator.recordStep*` for `WorkflowStepCompletedEvent` construction, `unwrapCollectionValue` for collection auto-unwrap, `truncate` from `dartclaw_core` for string truncation. No new copies of these patterns.
  - **Verify**: `rg "WorkflowStepCompletedEvent\(" packages/dartclaw_workflow/lib/src/workflow/` returns one match (the helper itself, after S13); `rg "if (e\.key\.startsWith\('_'\)" packages/dartclaw_workflow/lib/src/workflow/` zero matches outside the merge helper.

- [ ] **TI12** Targeted test suites green; structural fitness assertions
  - Run `dart test packages/dartclaw_workflow/test/workflow/parallel_group_test.dart`, `map_step_execution_test.dart`, `loop_execution_test.dart`, `gate_evaluator_test.dart`. Run `dart test packages/dartclaw_testing/test/fitness/max_file_loc_test.dart` and confirm `foreach_iteration_runner.dart` is **not** in the allowlist. Run `dart test packages/dartclaw_workflow` and `dart test` workspace-wide.
  - **Verify**: all four integration tests pass; `max_file_loc_test.dart` passes without allowlist entry for `foreach_iteration_runner.dart`; workspace `dart test` and `dart analyze --fatal-warnings --fatal-infos` are green.

- [ ] **TI13** TD-070 closure + tech-debt backlog updates
  - Update `dev/state/TECH-DEBT-BACKLOG.md`: TD-070 entry deleted **OR** narrowed to a specific named residue with a follow-up issue link; TD-082 + TD-088 entries marked Resolved-by-S15. Confirm runners individually meet the fitness target after TI02–TI08.
  - **Verify**: `dev/state/TECH-DEBT-BACKLOG.md` reflects the changes; `wc -l` confirms each runner ≤900 LOC; `max_file_loc_test.dart` (S10) green without allowlist additions.

### Testing Strategy
- [TI01] (no test — doc commit gate; verified by file existence + content `rg`)
- [TI02] Scenario "Workflow with parallel groups + map iterations + loop exit gates runs identically" → existing `parallel_group_test.dart` + `map_step_execution_test.dart` cover; manual `rg` for `inFlightCount--` count
- [TI03] Scenario "Workflow with parallel groups + map iterations + loop exit gates runs identically" → existing merge-resolve scenarios in foreach tests; persisted-context byte-identical assertion
- [TI04] Scenario "Workflow with parallel groups + map iterations + loop exit gates runs identically" → existing `parallel_group_test.dart`, `map_step_execution_test.dart`, `loop_execution_test.dart`
- [TI05] Scenario "Cancelled run with pending iterations stops promptly" → new additive `iteration_cancellation_test.dart`
- [TI06] Scenario "Workflow with parallel groups + map iterations + loop exit gates runs identically" → existing tests; `rg` count for context-filter-by-prefix duplicates
- [TI07] Scenario "Workflow with parallel groups + map iterations + loop exit gates runs identically" + Scenario "Malformed workflow node triggers identical validation error" → existing tests covering context extraction and validation paths
- [TI08] (no scenario — structural; covered by `wc -l` + workspace `dart test`)
- [TI09] Scenario "Cursor persistence across compaction boundary" → new additive resume-cursor regression test
- [TI10] Scenario "Pause/abort race against task completion" → new additive `wait_for_task_completion_race_test.dart` exercising both microtask orderings × 100 runs
- [TI11] (no test — verified by `rg` counts in TI11 verify line)
- [TI12] Scenario "Negative path — empty foreach collection" → existing foreach edge-case test; structural fitness via `max_file_loc_test.dart`
- [TI13] (no test — backlog hygiene; verified by file inspection)

### Validation
- Plan-and-implement E2E scenario: run a representative workflow under `dev/tools/dartclaw-workflows/run.sh` (or equivalent local harness) before and after; compare emitted SSE event sequence and persisted final context. (Per Binding Constraint #85 — "integration proof via `plan-and-implement` E2E scenario".)

### Execution Contract
- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- **TI01 lands as the first commit** of this story (mandatory per plan (d)).
- File code-freeze on `foreach_iteration_runner.dart` is in effect — no parallel feature edits during this story.
- Prescriptive details (file paths, target LOC, helper names) are exact — implement them verbatim.
- After all tasks: run `dart format packages/dartclaw_workflow apps`, `dart analyze --fatal-warnings --fatal-infos`, `dart test`. Keep `rg "TODO|FIXME|placeholder|not.implemented" packages/dartclaw_workflow/lib/src/workflow/` clean for files touched by this story.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [ ] **All success criteria** met (structural targets + correctness closures + health metrics)
- [ ] **All tasks** TI01–TI13 fully completed, verified, checkboxes checked
- [ ] **No regressions**: full `dart test` workspace-wide green; SSE / REST / JSONL formats byte-unchanged; ADR-022 + ADR-023 contracts preserved
- [ ] **Public API unchanged**: `dartclaw_workflow` barrel diff is empty
- [ ] **Fitness functions green**: `max_file_loc_test.dart` (S10) passes without an allowlist entry for `foreach_iteration_runner.dart`
- [ ] **Tech-debt backlog hygiene**: TD-070 closed/narrowed; TD-082 + TD-088 marked Resolved-by-S15


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._

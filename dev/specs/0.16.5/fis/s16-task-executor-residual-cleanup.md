# S16 — Task Executor Residual Cleanup (ctor params + binding handoff)

**Plan**: dev/specs/0.16.5/plan.md
**Story-ID**: S16

## Feature Overview and Goal

Reduce `TaskExecutor`'s ~28-named-parameter constructor to ≤12 via dep-group structs (S10 ceiling), retype the binding handle to the `WorkflowTaskBindingCoordinator` interface from S33, and collapse any surviving `_failureHandler.markFailedOrRetry(task, errorSummary: 'Project ... not found', …)` near-duplicates into a single `_failForProject(project, reason)` helper. Zero behaviour change. The 0.16.4 S46 decomposition (current `task_executor.dart` = 790 LOC) covered the original LOC target; this story closes the residual ergonomics tail.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S16 — Task Executor Residual Cleanup", Shared Decision #7 for the S33→S16 contract, and Binding PRD Constraints rows 1, 25, 29, 71, 75)_


## Required Context

### From `dev/specs/0.16.5/plan.md` — "S16: Task Executor Residual Cleanup (ctor params + binding handoff)"
<!-- source: dev/specs/0.16.5/plan.md#s16-task-executor-residual-cleanup-ctor-params--binding-handoff -->
<!-- extracted: e670c47 -->
> **Re-scope rationale (2026-04-30)**: The original "task_executor.dart ≤1,500 LOC + decomposition" target is **already met**. 0.16.4 S46 shipped the decomposition; current `task_executor.dart` = **790 LOC** with `task_config_view`, `workflow_turn_extractor`, `task_read_only_guard`, `task_budget_policy`, `workflow_one_shot_runner`, and `workflow_worktree_binder` already extracted. **TD-052 is effectively closed** by 0.16.4 S46 — backlog cleanup at sprint close removes the entry. Remaining work narrows to:
>
> - (a) **Constructor parameter reduction** — current ctor still has ~28 named parameters; group into dep-group structs to reach ≤12 (S10's `constructor_param_count_test.dart` ceiling). Suggested groupings: `TaskExecutorServices` (repos + buses), `TaskExecutorRunners` (turn/harness/runner-pool), `TaskExecutorLimits` (already named in S38 — coordinate with that story); pair with S38 record extraction.
> - (b) **`_markFailedOrRetry` unification** — verify whether the original 3 near-identical blocks survive 0.16.5 S46's split into the new helper modules; collapse any remaining near-duplicates into a single `_failForProject(project, reason)` helper.
> - (c) **`_workflowSharedWorktrees*` field removal** — once S33 lands `WorkflowTaskBindingCoordinator`, delete the three maps + the defensive `StateError` callback guard from `task_executor.dart`; constructor accepts the coordinator instead.
>
> Preserves all call sites and public API.
> **Acceptance Criteria**:
> - [ ] Constructor takes ≤12 parameters via dep-group structs (S10 ceiling) (must-be-TRUE)
> - [ ] All near-identical `_markFailedOrRetry` blocks (if any survive in 790-LOC file) unified into one helper (must-be-TRUE)
> - [ ] `_workflowSharedWorktrees*` fields removed; coordinator wired via constructor (depends on S33) (must-be-TRUE)
> - [ ] `dart test packages/dartclaw_server/test/task` passes with zero test changes (must-be-TRUE)
> - [ ] `constructor_param_count_test.dart` (S10) passes for this file (without allowlist)
> - [ ] TD-052 entry deleted from public `dev/state/TECH-DEBT-BACKLOG.md` at sprint close

### From `dev/specs/0.16.5/.technical-research.md` — Shared Decision #7 (S33 → S16 contract)
<!-- source: dev/specs/0.16.5/.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> **7. S33 → S16 — `WorkflowTaskBindingCoordinator` interface contract**
> - WHAT: `abstract interface class WorkflowTaskBindingCoordinator` in `dartclaw_core/lib/src/workflow/` exposes `hydrate`, `get`, `put`, `waitFor`. Concrete `WorkflowWorktreeBinder` in `dartclaw_server` implements it. Fake at `dartclaw_testing/lib/src/fake_workflow_task_binding_coordinator.dart`. Hydrate-callback signature drops redundant `workflowRunId` parameter.
> - PRODUCER: S33.
> - CONSUMER: S16.
> - WHY: S16 ctor-reduction depends on coordinator handoff seam.

### From `dev/specs/0.16.5/.technical-research.md` — Binding PRD Constraints (rows applying to S16)
<!-- source: dev/specs/0.16.5/.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> | 1  | "JSONL control protocol, REST API payload shapes, SSE envelope formats unchanged." | Out of Scope / NFR Compatibility | S05, S15, S16, S17, S18, S22, S35 |
> | 25 | "`task_executor.dart` constructor takes ≤12 parameters via dep-group structs; `_workflowSharedWorktrees*` fields removed through S33; surviving `_markFailedOrRetry` duplicates unified." | FR4 | S16 |
> | 29 | "`max_file_loc_test.dart` and `constructor_param_count_test.dart` fitness functions pass." | FR4 | S10, S15, S16, S18 |
> | 71 | "Behavioural regressions post-decomposition: Zero — every existing test remains green." | NFR Reliability | S15, S16, S17, S18, S22, S33 |
> | 75 | "JSONL control protocol, REST API payload shapes, SSE envelope formats unchanged." | Out of Scope / NFR | S05, S15, S16, S17, S18, S22, S35 |


## Deeper Context

- `dev/specs/0.16.5/fis/s33-workflow-task-binding-coordinator-extraction.md#architecture-decision` — S33 pins the interface name + method-name mapping; S16's ctor consumes that exact type.
- `dev/specs/0.16.5/plan.md#s38-readability-pack` — S38 part (e) introduces `TaskExecutorLimits` record (compactInstructions / identifierPreservation / identifierInstructions / maxMemoryBytes / budgetConfig quintet) and renames `workspaceDir → workspaceRoot`; coordinate (see Architecture Decision below).
- `dev/specs/0.16.5/fis/s10-level-1-governance-checks.md#implementation-tasks` (TI04) — S10's `constructor_param_count_test.dart` baseline allowlist must be extended to include `TaskExecutor` while S16 is in flight; S16 removes that entry on landing.
- `dev/state/LEARNINGS.md` — async/preflight discipline; relevant to the "no behaviour change" promise on the workflow-shared worktree mutex path.


## Success Criteria (Must Be TRUE)

- [ ] `TaskExecutor` public constructor parameter count is **≤12** (combined positional + named), achieved by introducing dep-group structs (`TaskExecutorServices`, `TaskExecutorRunners`, `TaskExecutorLimits`) plus a small set of one-off scalars
- [ ] `TaskExecutorServices` and `TaskExecutorRunners` are declared as immutable Dart classes (named constructors with `required` fields) inside `packages/dartclaw_server/lib/src/task/` and exported only via the existing `task_executor.dart` import surface (not added to the `dartclaw_server.dart` barrel)
- [ ] `TaskExecutorLimits` is consumed in S16 (typedef alias or thin local re-export). Coordination with S38: S38 owns the canonical record definition and the `workspaceDir → workspaceRoot` rename. If S38 lands first, S16 imports its type verbatim. If S16 lands first, S16 declares the type with the exact field set the brief specifies (`compactInstructions`, `identifierPreservation`, `identifierInstructions`, `maxMemoryBytes`, `budgetConfig`) so S38 can absorb it without reshape
- [ ] `TaskExecutor` no longer holds `_workflowSharedWorktrees*` map fields directly (verify the 0.16.4 S46 baseline still holds — none of `_workflowSharedWorktrees`, `_workflowSharedWorktreeBindings`, `_workflowSharedWorktreeWaiters`, `_workflowInlineBranchKeys` are declared in `task_executor.dart`)
- [ ] `TaskExecutor._worktreeBinder` field is typed as **`WorkflowTaskBindingCoordinator`** (the interface from S33), not the concrete `WorkflowWorktreeBinder` class
- [ ] All near-identical `_failureHandler.markFailedOrRetry(task, errorSummary: 'Project "<id>" not found', retryable: false)` call sites — currently at `task_executor.dart:330-333` and `task_executor_helpers.dart:42` — collapse into a single `_failForProject(taskOrProjectRef, reason)` (or equivalent) helper. Other `markFailedOrRetry` invocations that carry distinct error payloads (cloning, git ref validation, token budget, loop, …) STAY as-is; this AC targets only the project-not-found near-duplicate
- [ ] `dart test packages/dartclaw_server/test/task` passes with **zero behavioural test changes**. Mechanical signature updates at the test ctor call sites (substitute scalar args with the new struct args) are permitted; assertion logic, expected outputs, and skipped-test flags remain identical
- [ ] `dart test packages/dartclaw_testing/test/fitness/constructor_param_count_test.dart` passes with `TaskExecutor` **not** present in `allowlist/constructor_param_count.txt` after S16 lands (S10 may temporarily allowlist it during the W3→W4 gap; that entry is removed in this story's commit)
- [ ] TD-052 entry is removed from `dev/state/TECH-DEBT-BACKLOG.md` at sprint close (deletion lands either in this commit or in S19's hygiene closeout — record which in CHANGELOG)
- [ ] All `TaskExecutor(...)` construction sites updated: `apps/dartclaw_cli/lib/src/commands/wiring/task_wiring.dart:203`, `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart:350`, plus 5 test files (`packages/dartclaw_server/test/task/{budget_enforcement_test,retry_enforcement_test,task_executor_provider_test,task_executor_test,task_autonomy_test}.dart`)

### Health Metrics (Must NOT Regress)

- [ ] `dart format --set-exit-if-changed packages apps` clean
- [ ] `dart analyze --fatal-warnings --fatal-infos` workspace-wide: 0 issues
- [ ] `dart test` workspace-wide green; SSE/REST/JSONL payload shapes unchanged (constraint #1, #75)
- [ ] L1 fitness suite (`packages/dartclaw_testing/test/fitness/`) green, including `max_file_loc_test.dart` (`task_executor.dart` stays ≤1,500; expected ~790 LOC ± a few from the helper additions)
- [ ] No new package dependencies added (constraint #2)
- [ ] `dartclaw_server.dart` barrel surface unchanged — dep-group structs are package-internal


## Scenarios

### Workflow-shared worktree: 3 sibling tasks resolve to the same path (regression guard)

- **Given** a workflow run started with `gitStrategy.worktree: shared` that has spawned three child tasks bound to the same `workflowRunId`
- **When** `TaskExecutor` polls and processes all three tasks
- **Then** each task resolves through the `WorkflowTaskBindingCoordinator` field to the same `WorktreeInfo` (identical `path` and `branch`); `WorktreeManager.create` is invoked exactly once for the run; existing integration tests under `packages/dartclaw_server/test/task/task_executor_test.dart` and `packages/dartclaw_workflow/test/workflow/scenarios/` pass with no logic edits

### Project-not-found uniformly fails through the consolidated helper

- **Given** a queued task whose `projectId` does not match any registered project
- **When** `TaskExecutor.pollOnce()` reaches the project-resolution step (either the inline branch at `task_executor.dart:330-333` path or the helpers-file branch at `task_executor_helpers.dart:42`)
- **Then** the task is marked failed with the exact error message `'Project "<id>" not found'`, `retryable: false`, via the new `_failForProject` helper; existing `retry_enforcement_test.dart` / `task_autonomy_test.dart` assertions on the failure event payload pass unchanged

### Constructor fitness check passes without an allowlist entry

- **Given** the `constructor_param_count_test.dart` fitness function from S10 runs against the workspace
- **When** the test counts `TaskExecutor`'s public ctor parameters
- **Then** the count is **≤12**; `TaskExecutor` is **not** present in `allowlist/constructor_param_count.txt`; the only remaining allowlist entry is `DartclawServer._` (which S18 retires later)

### Coordinator handoff: workflow service hydrate signature unaffected

- **Given** S33 has landed (`WorkflowTaskBindingCoordinator` interface ships in `dartclaw_core`; hydrate callback signature drops the redundant `workflowRunId` named param)
- **When** `TaskExecutor.hydrateWorkflowSharedWorktreeBinding(binding)` is invoked from `WorkflowService._rehydrateWorkflowWorktreeBinding`
- **Then** the call delegates through the `WorkflowTaskBindingCoordinator` field with no additional named arguments; the persisted-binding integrity guard remains in `WorkflowService` (per S33's contract); no defensive `StateError` lives in `TaskExecutor` itself

### Workspace-wide test sweep observes zero behaviour change

- **Given** S16 is fully implemented (ctor reduction + helper consolidation + coordinator-typed field)
- **When** `dart test packages/dartclaw_server/test/task` and `dart test` workspace-wide are run
- **Then** every previously-green test is green; no test was rewritten to weaken assertions, marked skipped, or have its expected outputs adjusted; the only test-file diffs are mechanical ctor-call-site updates substituting scalar args with the new struct args


## Scope & Boundaries

### In Scope

- Three dep-group structs in `packages/dartclaw_server/lib/src/task/`: `TaskExecutorServices`, `TaskExecutorRunners`, `TaskExecutorLimits` (consumed; coordinated with S38 — see Architecture Decision)
- `TaskExecutor` ctor signature change: replace ~28 named scalars with the three structs + ≤9 remaining one-offs (`pollInterval`, `dataDir`, `workspaceDir`, `onSpawnNeeded`, `onAutoAccept` etc.) so total stays ≤12
- `TaskExecutor._worktreeBinder` field retyped to `WorkflowTaskBindingCoordinator`
- New `_failForProject(...)` helper replacing the 2 near-duplicate "Project not found" call sites
- Mechanical ctor-call-site updates at 2 production wiring files + 5 test files
- Verification: `dart analyze`, `dart test packages/dartclaw_server/test/task`, workspace-wide `dart test`, `constructor_param_count_test.dart`
- TD-052 backlog hygiene (delete entry; coordinate with S19 if closeout batches it)

### What We're NOT Doing

- **Not rewriting `TaskExecutor` task-lifecycle logic** — `pollOnce`, `_pollOnceInner`, `_executeTask`, the dispatcher loop, and surrounding control flow are byte-for-byte preserved aside from the ctor field accesses
- **Not refactoring the 0.16.4 S46-extracted helpers** (`task_config_view`, `workflow_turn_extractor`, `task_read_only_guard`, `task_budget_policy`, `workflow_one_shot_runner`, `workflow_worktree_binder`) — their internals stay; only their ctor wiring inside `TaskExecutor` switches to read from the dep-group structs
- **Not introducing a dependency-injection framework or service-locator** — plain Dart records/classes only (constraint #2: no new dependencies)
- **Not renaming `TaskExecutor`** — public type name and import surface are stable; downstream consumers and CLI wiring see only ctor signature change
- **Not extracting `task_executor_test_harness.dart`** — that's S23 R-M8's territory; S16 only mechanically updates the existing test ctor call sites
- **Not changing JSONL/REST/SSE wire formats** (constraint #1, #75) — every public payload shape stays bit-identical
- **Not collapsing `markFailedOrRetry` calls with distinct error semantics** — only the "Project not found" near-duplicate is in scope; other call sites (cloning, git ref, budget, loop, read-only mutation, …) retain their inline error strings
- **Not deleting the S33-extracted `WorkflowTaskBindingCoordinator` defensive guard** — that's S33's responsibility; S16 only consumes the post-S33 interface

### Agent Decision Authority

- **Autonomous**: exact field set on each dep-group struct (final partition between `TaskExecutorServices`, `TaskExecutorRunners`, and the one-off remainder); helper signature shape (`_failForProject(Project project, String reason)` vs `_failForProject(Task task, String projectId)`); whether `TaskExecutorLimits` is declared locally or imported from S38 depending on S38's landing order
- **Escalate**: any decision that requires touching `task_executor_test_harness.dart` (collides with S23); any need to add a new package dependency; any change to `WorkflowWorktreeBinding`/`WorktreeInfo` shapes or persisted JSON; any change to the public `TaskExecutor.hydrateWorkflowSharedWorktreeBinding` signature beyond what S33 already specifies


## Architecture Decision

**We will**: Group the ~28 named ctor parameters into 3 dep-group structs (`TaskExecutorServices` for repos+buses+services that produce/consume domain events; `TaskExecutorRunners` for turn/harness/runner-pool/observer concerns; `TaskExecutorLimits` for the cohesive policy quintet `compactInstructions`/`identifierPreservation`/`identifierInstructions`/`maxMemoryBytes`/`budgetConfig`) plus retain a small set of true one-offs (`pollInterval`, `dataDir`, `workspaceDir`, `onSpawnNeeded`, `onAutoAccept`) to land at ≤12 total ctor parameters. The `_worktreeBinder` field is retyped to the `WorkflowTaskBindingCoordinator` interface from S33, deleting the dependency on the concrete class. The `_failForProject(...)` helper consolidates the project-not-found near-duplicate. -- (over a more elaborate dependency-injection framework or a single mega-record, both of which would either add deps or hide cohesion).

**S38 coordination (autonomous default)**: S38's plan section explicitly owns `TaskExecutorLimits`. Treat S38 as the **producer** of the type definition; S16 is the **consumer**. Implementation order:

1. **If S38 has landed** at the time S16 starts: import `TaskExecutorLimits` directly from S38's location.
2. **If S16 lands first** (the W4-before-W5 default): declare `TaskExecutorLimits` in this story with the exact field set the brief specifies (`compactInstructions` / `identifierPreservation` / `identifierInstructions` / `maxMemoryBytes` / `budgetConfig`) so S38 absorbs it without reshape — S38 then takes ownership and adds any later renames (e.g. `workspaceDir → workspaceRoot`) without changing the type's surface. Record the chosen path under Implementation Observations.

**Dep-group struct partition (pinned at FIS time; executor may shift fields if a stronger cohesion clearly emerges):**

| Struct | Fields | Rationale |
|---|---|---|
| `TaskExecutorServices` | `tasks`, `goals`, `sessions`, `messages`, `artifactCollector`, `worktreeManager`, `taskFileGuard`, `eventRecorder`, `traceService`, `kvService`, `eventBus`, `projectService`, `workflowStepExecutionRepository`, `workflowRunRepository` | Repositories + services + event bus — the domain-data surface |
| `TaskExecutorRunners` | `turns`, `observer`, `workflowCliRunner` | Turn manager + observer + CLI runner — orchestration surface (the harness pool is reached via `turns.pool` already) |
| `TaskExecutorLimits` | `compactInstructions`, `identifierPreservation` (default `'strict'`), `identifierInstructions`, `maxMemoryBytes`, `budgetConfig` | Cohesive policy quintet — coordinated with S38 |
| One-off scalars (≤9) | `pollInterval`, `dataDir`, `workspaceDir`, `onSpawnNeeded`, `onAutoAccept`, `coordinator` (the `WorkflowTaskBindingCoordinator` from S33) | True one-offs that don't cluster cohesively; `coordinator` becomes a ctor param to satisfy the "coordinator wired via constructor" AC |

Total: 3 struct params + ≤6 one-offs (`coordinator` lifts into the one-off list rather than `Services` so it's syntactically obvious it's a binding seam, not a generic service) = **≤9** parameters. Comfortable margin under the ≤12 ceiling.


## Technical Overview

### Data Models

No new domain types. Three dep-group structs (plain Dart classes with `required` named fields, immutable, no equality override needed) plus consumption of `TaskExecutorLimits` (S38-coordinated) and `WorkflowTaskBindingCoordinator` (S33-extracted). No JSON serialisation, no persistence, no public API surface beyond the ctor signature.

### Integration Points

- **`apps/dartclaw_cli/lib/src/commands/wiring/task_wiring.dart:203`** — primary CLI wiring; rebuild the `TaskExecutor(...)` call to pass the three structs + one-offs.
- **`apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart:350`** — workflow-CLI wiring; same mechanical update.
- **`packages/dartclaw_server/test/task/{task_executor_test,task_autonomy_test,task_executor_provider_test,budget_enforcement_test,retry_enforcement_test}.dart`** — 5 test files instantiate `TaskExecutor(...)` directly; mechanical signature update only (no logic changes).
- **`packages/dartclaw_server/lib/src/task/task_executor.dart`** — primary file: new ctor body, struct field destructuring into the existing `_xxx` private fields (preserves the rest of the class as-is), retyped `_worktreeBinder` field, new `_failForProject` helper.
- **`packages/dartclaw_server/lib/src/task/task_executor_helpers.dart`** — replace the inline "Project not found" call site at line 42 with a `_failForProject` invocation.
- **`packages/dartclaw_testing/test/fitness/allowlist/constructor_param_count.txt`** — remove `TaskExecutor` entry (if S10 added one as a temporary baseline).
- **`dev/state/TECH-DEBT-BACKLOG.md`** — delete TD-052 entry (or coordinate with S19).


## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_server/lib/src/task/task_executor.dart                          | Target file (790 LOC); ctor at :40-94; field declarations :96-126; _worktreeBinder :146; hydrateWorkflowSharedWorktreeBinding :165-167
file   | packages/dartclaw_server/lib/src/task/task_executor_helpers.dart                  | Part file; "Project not found" near-duplicate at :42
file   | packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart               | Concrete class; declares `implements WorkflowTaskBindingCoordinator` post-S33
file   | packages/dartclaw_core/lib/src/workflow/workflow_task_binding_coordinator.dart    | S33-produced interface; import target for the retyped field
file   | dev/specs/0.16.5/fis/s33-workflow-task-binding-coordinator-extraction.md          | Coordinator interface contract; method-name mapping
file   | apps/dartclaw_cli/lib/src/commands/wiring/task_wiring.dart:203                    | Primary CLI ctor call site
file   | apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart:350          | Workflow-CLI ctor call site
file   | packages/dartclaw_server/test/task/task_executor_test.dart                        | Largest test ctor consumer; mechanical signature update
file   | packages/dartclaw_testing/test/fitness/constructor_param_count_test.dart          | S10 fitness target (created by S10 in W3); must pass without TaskExecutor in allowlist
file   | dev/state/TECH-DEBT-BACKLOG.md                                                    | TD-052 deletion target
file   | dev/specs/0.16.4/fis/workflow-robustness-refactor/s46-task-executor-decomposition.md | Predecessor; the 0.16.4 split that brought task_executor.dart to 790 LOC
```


## Constraints & Gotchas

- **Zero behaviour change**: every call site, every preserved field name, every error string is identical post-refactor. -- Workaround: keep the `_xxx` private fields in `TaskExecutor` and destructure struct args into them in the initializer list (rather than reading through `_services.tasks` etc. throughout the class body) — this localises the diff and minimises regression risk.
- **Test compat**: plan AC says "zero test changes" but the ctor signature is changing. -- Resolution: interpret as "zero **behavioural** test changes" — mechanical ctor-call-site updates at the 5 test files are permitted; assertion logic, expected outputs, and skip flags must be identical. Record this interpretation under Implementation Observations if exec-spec discovers a stricter reading.
- **S33 dependency strict**: `WorkflowTaskBindingCoordinator` interface MUST exist in `dartclaw_core` before this story merges. -- Verify: `grep "abstract interface class WorkflowTaskBindingCoordinator" packages/dartclaw_core/lib/src/workflow/workflow_task_binding_coordinator.dart` returns 1 line before TI04 starts.
- **S38 type ownership**: `TaskExecutorLimits` is jointly owned with S38. -- Workaround: declare locally with the exact 5-field set if S38 hasn't landed; S38 absorbs the type without reshape. If S38 has landed, import. Either way: do not invent additional fields beyond the 5 the brief specifies.
- **S10 allowlist coordination**: S10 (W3) lands first and may need to allowlist `TaskExecutor` temporarily so its fitness suite goes green during W3→W4 gap. -- Workaround: if `allowlist/constructor_param_count.txt` exists with a `TaskExecutor` entry on a freshly-rebased branch, plan to delete that entry in the same commit as the ctor reduction. If no entry exists (S10 chose to land S16 simultaneously), no allowlist edit needed.
- **S23 collision risk**: S23's R-M8 extracts `task_executor_test_harness.dart`. -- Avoid: do not refactor `task_executor_test.dart` setUp/tearDown blocks; only change ctor call sites. Instead: if a test ctor call site lives inside the set/teardown helpers, make the smallest possible mechanical edit; flag in Implementation Observations.
- **Critical — `_worktreeBinder` initializer**: it currently `late final` initialises to `WorkflowWorktreeBinder(...)`. -- Must handle by: keep the late-final initialiser shape; only change the field's declared **type** to the interface. The instance still constructs the concrete class internally (the interface only narrows the static type).
- **Critical — `failTask` callback**: `WorkflowWorktreeBinder` ctor and `TaskBudgetPolicy` ctor receive `_failureHandler.markFailedOrRetry` as a tear-off. -- Must handle by: don't disturb these tear-offs when introducing the `_failForProject` helper. The new helper sits **above** `markFailedOrRetry` in the call hierarchy; the failure-handler callback wiring stays unchanged.
- **Avoid**: pushing the dep-group structs into the `dartclaw_server.dart` barrel. -- Instead: keep them as `lib/src/task/`-internal types; the only public-API impact is `TaskExecutor`'s ctor signature, which is constructed only in the 2 wiring files + 5 tests.


## Implementation Plan

> Vertical slice ordering: dep-group structs first (Phase 1), then ctor signature swap + binding handoff in one atomic edit (Phase 2), then helper unification + cleanup (Phase 3), then verification.

### Implementation Tasks

- [ ] **TI01** Verify the 0.16.4 S46 baseline + S33 dependency.
  - Pure read; no code change. Confirms premises before any edits.
  - **Verify**: `wc -l packages/dartclaw_server/lib/src/task/task_executor.dart` ≈ 790; `rg '_workflowSharedWorktrees|_workflowInlineBranchKeys' packages/dartclaw_server/lib/src/task/task_executor.dart` returns 0 lines; `rg 'abstract interface class WorkflowTaskBindingCoordinator' packages/dartclaw_core/lib/src/workflow/` returns 1 line. If S33 hasn't landed, STOP and surface as `BLOCKED: S33 dependency not met`.

- [ ] **TI02** Audit current ctor and pin the dep-group partition.
  - Open `task_executor.dart:40-94`. Confirm 27 named + 1 positional = 28 ctor params. Validate the partition table from Architecture Decision against the actual field set; if a field doesn't fit cleanly into Services/Runners/Limits/one-offs, record the deviation under Implementation Observations and adjust struct membership before authoring TI03.
  - **Verify**: a written list of every ctor param mapped to one of {`Services`, `Runners`, `Limits`, `one-off`}; total one-offs ≤ 9; total params after grouping ≤ 12.

- [ ] **TI03** Author `TaskExecutorServices` immutable struct.
  - New file `packages/dartclaw_server/lib/src/task/task_executor_services.dart`. Single `class TaskExecutorServices { TaskExecutorServices({required …}); final … }` with the fields pinned in TI02. All fields `final`; nullable where the original ctor was nullable. Dartdoc on the class only (no per-field docs needed — internal type).
  - **Verify**: `dart analyze packages/dartclaw_server` = 0 issues; `rg 'class TaskExecutorServices' packages/dartclaw_server/lib/src/task/task_executor_services.dart` returns 1 line.

- [ ] **TI04** Author `TaskExecutorRunners` immutable struct.
  - New file `packages/dartclaw_server/lib/src/task/task_executor_runners.dart`. Same shape as TI03; fields pinned in TI02 (`turns`, `observer`, `workflowCliRunner`).
  - **Verify**: `dart analyze packages/dartclaw_server` = 0 issues; `rg 'class TaskExecutorRunners' packages/dartclaw_server/lib/src/task/task_executor_runners.dart` returns 1 line.

- [ ] **TI05** Resolve `TaskExecutorLimits` ownership and produce/import the type.
  - Check whether `TaskExecutorLimits` already exists at `packages/dartclaw_server/lib/src/task/` (S38-landed-first path). If yes: import. If no: declare locally at `task_executor_limits.dart` with exactly the 5 fields the brief pins (`compactInstructions: String?`, `identifierPreservation: String` default `'strict'`, `identifierInstructions: String?`, `maxMemoryBytes: int?`, `budgetConfig: TaskBudgetConfig?`). Either way, record the chosen path under Implementation Observations as a coordination signal for S38.
  - **Verify**: `rg 'class TaskExecutorLimits|typedef TaskExecutorLimits' packages/dartclaw_server/lib/src/task/` returns ≥ 1 line; `dart analyze packages/dartclaw_server` = 0 issues.

- [ ] **TI06** Rewrite `TaskExecutor` ctor signature: replace named scalars with the 3 structs + ≤6 one-offs + new `coordinator: WorkflowTaskBindingCoordinator` param.
  - In `task_executor.dart:40-94`. New ctor: `TaskExecutor({required TaskExecutorServices services, required TaskExecutorRunners runners, TaskExecutorLimits limits = const TaskExecutorLimits(), required WorkflowTaskBindingCoordinator coordinator, this.pollInterval = …, String? dataDir, String? workspaceDir, Future<void> Function()? onSpawnNeeded, Future<void> Function(String)? onAutoAccept})`. Initialiser list destructures struct fields into the existing `_xxx` private fields verbatim. Field count ≤ 9 (3 structs + 1 coordinator + 1 pollInterval + 4 one-offs).
  - **Verify**: ctor parameter count, counted manually against `task_executor.dart:40-94`, is ≤12 total; `dart analyze packages/dartclaw_server` reports only the wiring-callsite errors (TI09 fixes); private `_xxx` field declarations at `:99-126` are unchanged.

- [ ] **TI07** Retype `_worktreeBinder` field to the interface; replace the late-final initialiser's right-hand side construction with the new `coordinator` ctor param.
  - At `task_executor.dart:146-150`. Field becomes `final WorkflowTaskBindingCoordinator _worktreeBinder;` (no `late`); initialised from `coordinator` in the ctor body. Add `import 'package:dartclaw_core/dartclaw_core.dart';` if the symbol doesn't already resolve (it should — `dartclaw_core` is already imported).
  - **Verify**: `rg '_worktreeBinder' packages/dartclaw_server/lib/src/task/task_executor.dart` shows the field declaration line typed as the interface; `dart analyze packages/dartclaw_server/lib/src/task/task_executor.dart` reports zero issues for that file.

- [ ] **TI08** Update CLI wiring call sites to construct the structs + pass the coordinator.
  - At `apps/dartclaw_cli/lib/src/commands/wiring/task_wiring.dart:203` and `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart:350`. Replace the flat scalar arg list with `TaskExecutorServices(...)`, `TaskExecutorRunners(...)`, `TaskExecutorLimits(...)`, and a `coordinator:` arg pointing at the existing `WorkflowWorktreeBinder` instance (which now `implements WorkflowTaskBindingCoordinator` per S33).
  - **Verify**: `dart analyze apps/dartclaw_cli` = 0 issues; both wiring files type-check; no scalar arg remains where a struct-arg is now required.

- [ ] **TI09** Update the 5 test files' `TaskExecutor(...)` ctor call sites mechanically.
  - In `packages/dartclaw_server/test/task/{task_executor_test,task_autonomy_test,task_executor_provider_test,budget_enforcement_test,retry_enforcement_test}.dart`. Replace flat scalar arg lists with the new struct-based form. **Do not** edit setUp/tearDown helpers, expected outputs, assertions, or skip flags. If a test relies on `task_executor_test_harness.dart`, leave that file untouched (S23 territory) and propagate only the mechanical ctor signature change up through the helpers' own ctor calls.
  - **Verify**: `dart test packages/dartclaw_server/test/task` passes; `git diff --stat packages/dartclaw_server/test/task/` shows only ctor-call-site diffs (no `expect(...)` lines changed; no `skip:` added).

- [ ] **TI10** Introduce `_failForProject(...)` helper; collapse the 2 "Project not found" near-duplicates.
  - At `task_executor.dart` (top of the private-method block, before `_pollOnceInner`). Signature: `Future<void> _failForProject(Task task, String projectId) async => _failureHandler.markFailedOrRetry(task, errorSummary: 'Project "\$projectId" not found', retryable: false);`. Replace the call at `task_executor.dart:330-333` and the call at `task_executor_helpers.dart:42` with `_failForProject(task, projectId)`. Other `markFailedOrRetry` call sites STAY as-is.
  - **Verify**: `rg 'Project ".*" not found' packages/dartclaw_server/lib/src/task/` returns exactly 1 line (the new helper's body); `_failForProject` invocations appear at the 2 collapsed call sites.

- [ ] **TI11** Audit for any other surviving `_markFailedOrRetry` near-duplicates.
  - Read every `_failureHandler.markFailedOrRetry(...)` call site in `task_executor.dart` + `task_executor_helpers.dart` (TI01-discovered list). Confirm only the project-not-found pair has near-identical structure; the rest carry distinct payloads (cloning, git ref, budget, loop, read-only, no-prompt). If a second near-duplicate cluster surfaces (≥2 sites with identical signature aside from interpolated values), record under Implementation Observations and either expand `_failForProject` or add a sibling helper. If only the project-not-found pair exists (expected), record the audit result.
  - **Verify**: a written enumeration of every `markFailedOrRetry` call site with its distinct error-payload signature; AC (b) is satisfied either by the TI10 collapse alone (expected) or by a follow-on collapse documented here.

- [ ] **TI12** Remove `TaskExecutor` from the `constructor_param_count_test.dart` allowlist (if present).
  - At `packages/dartclaw_testing/test/fitness/allowlist/constructor_param_count.txt`. If S10 added a `TaskExecutor` entry as a temporary W3 baseline, delete the line in this commit. If no entry exists, no edit required — skip with a note in Implementation Observations.
  - **Verify**: `rg 'TaskExecutor' packages/dartclaw_testing/test/fitness/allowlist/constructor_param_count.txt` returns 0 lines.

- [ ] **TI13** Delete TD-052 from `dev/state/TECH-DEBT-BACKLOG.md`.
  - Locate the TD-052 entry; delete it (or, if S19's hygiene closeout has been confirmed to handle it, leave a single-line comment in this story's CHANGELOG entry signalling the deferral). Default: delete in this commit.
  - **Verify**: `rg 'TD-052' dev/state/TECH-DEBT-BACKLOG.md` returns 0 lines (or 0 lines in any open-items section if the entry is moved to a "Closed" archive).

- [ ] **TI14** Workspace verification.
  - Run `dart format --set-exit-if-changed packages apps`, `dart analyze --fatal-warnings --fatal-infos`, `dart test packages/dartclaw_server/test/task`, `dart test packages/dartclaw_testing/test/fitness/`, and `dart test` workspace-wide. Scan `rg 'TODO|FIXME|placeholder|not.implemented' packages/dartclaw_server/lib/src/task/task_executor.dart packages/dartclaw_server/lib/src/task/task_executor_helpers.dart` for stragglers.
  - **Verify**: all five commands exit 0; `constructor_param_count_test.dart` reports `TaskExecutor` is below the 12-param ceiling without an allowlist entry; no straggler markers introduced.

### Testing Strategy

- [TI01,TI06,TI07] Scenario _Workflow-shared worktree: 3 sibling tasks resolve to the same path_ → existing integration tests in `packages/dartclaw_server/test/task/task_executor_test.dart` and `packages/dartclaw_workflow/test/workflow/scenarios/` re-run unchanged after the ctor signature change + field retype.
- [TI10,TI11] Scenario _Project-not-found uniformly fails through the consolidated helper_ → existing `retry_enforcement_test.dart` and `task_autonomy_test.dart` assertions on the failure event payload (`errorSummary` string) re-run unchanged; a focused unit assertion on the helper is welcome but not required.
- [TI06,TI12] Scenario _Constructor fitness check passes without an allowlist entry_ → `dart test packages/dartclaw_testing/test/fitness/constructor_param_count_test.dart` proves the ceiling holds.
- [TI07,TI08] Scenario _Coordinator handoff: workflow service hydrate signature unaffected_ → existing workflow-service resume tests re-run unchanged; the `TaskExecutor.hydrateWorkflowSharedWorktreeBinding` re-export stays a thin delegate.
- [TI09,TI14] Scenario _Workspace-wide test sweep observes zero behaviour change_ → `dart test` workspace-wide; `git diff --stat packages/dartclaw_server/test/` review confirms only ctor-call-site diffs.

### Validation

- Manual: `git diff --stat packages/dartclaw_server/test/` after TI09 should show only ctor-call-site diffs — no edits to `expect(...)`, `setUp`, or skip flags. If the diff is broader, re-audit before continuing.

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (struct field names, file paths, error strings, line numbers) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs: documentation lookup, architectural advice, build troubleshooting — spawn in background when possible.
- After all tasks: run `dart format --set-exit-if-changed`, `dart analyze --fatal-warnings --fatal-infos`, `dart test` workspace-wide, and keep `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [ ] **All success criteria** met
- [ ] **All tasks** fully completed, verified, and checkboxes checked
- [ ] **No regressions** or breaking changes introduced (ctor signature change is internal — public API unchanged)
- [ ] **Coordinate with S38**: confirm S38's executor sees `TaskExecutorLimits` already declared (or absorbs the local declaration without reshape); pass the coordination note via Implementation Observations
- [ ] **Coordinate with S33**: confirm the `_worktreeBinder` field type matches the interface S33 produced; the test sweep covers both packages


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._

---

## Plan-format migration addendum (2026-05-06)

> Migrated from the pre-template `plan.md` story body during the plan-template reformat. Verbatim copy of the plan's `**Acceptance Criteria**`, `**Key Scenarios**`, and any detailed `**Scope**` paragraphs not already represented above. Authoritative spec content lives in this FIS; the plan now carries only a 1-2 sentence Scope summary plus catalog metadata.

### From plan.md — Re-scope rationale (2026-04-30)

**Re-scope rationale (2026-04-30)**: The original "task_executor.dart ≤1,500 LOC + decomposition" target is **already met**. 0.16.4 S46 (`workflow-robustness-refactor/s46-task-executor-decomposition.md`) shipped the decomposition; current `task_executor.dart` = **790 LOC** with `task_config_view`, `workflow_turn_extractor`, `task_read_only_guard`, `task_budget_policy`, `workflow_one_shot_runner`, and `workflow_worktree_binder` already extracted. **TD-052 is effectively closed** by 0.16.4 S46 — backlog cleanup at sprint close removes the entry. Remaining work narrows to:

**Scope** (current targets):
- (a) **Constructor parameter reduction** — current ctor still has ~28 named parameters; group into dep-group structs to reach ≤12 (S10's `constructor_param_count_test.dart` ceiling). Suggested groupings: `TaskExecutorServices` (repos + buses), `TaskExecutorRunners` (turn/harness/runner-pool), `TaskExecutorLimits` (already named in S38 — coordinate with that story); pair with S38 record extraction.
- (b) **`_markFailedOrRetry` unification** — verify whether the original 3 near-identical blocks survive 0.16.5 S46's split into the new helper modules; collapse any remaining near-duplicates into a single `_failForProject(project, reason)` helper.
- (c) **`_workflowSharedWorktrees*` field removal** — once S33 lands `WorkflowTaskBindingCoordinator`, delete the three maps + the defensive `StateError` callback guard from `task_executor.dart`; constructor accepts the coordinator instead.

Preserves all call sites and public API.

### From plan.md — Acceptance Criteria addendum (migrated from old plan format)

**Acceptance Criteria**:
- [ ] Constructor takes ≤12 parameters via dep-group structs (S10 ceiling) (must-be-TRUE)
- [ ] All near-identical `_markFailedOrRetry` blocks (if any survive in 790-LOC file) unified into one helper (must-be-TRUE)
- [ ] `_workflowSharedWorktrees*` fields removed; coordinator wired via constructor (depends on S33) (must-be-TRUE)
- [ ] `dart test packages/dartclaw_server/test/task` passes with zero test changes (must-be-TRUE)
- [ ] `constructor_param_count_test.dart` (S10) passes for this file (without allowlist)
- [ ] TD-052 entry deleted from public `dev/state/TECH-DEBT-BACKLOG.md` at sprint close

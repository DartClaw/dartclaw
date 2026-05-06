# S33 — WorkflowTaskBindingCoordinator Extraction (interface + fake; concrete already shipped)

**Plan**: dev/specs/0.16.5/plan.md
**Story-ID**: S33

## Feature Overview and Goal

Lift the abstract interface from the already-extracted `WorkflowWorktreeBinder` into `dartclaw_core` as `WorkflowTaskBindingCoordinator`, retype `TaskExecutor`'s field as the interface, ship a fake in `dartclaw_testing`, and drop the redundant `workflowRunId` callback parameter (which lets the defensive `StateError` mismatch guard go away). Behaviour is unchanged at runtime; this closes the seam ARCH-004 anticipated and unblocks S16's residual ctor reduction.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S33 — WorkflowTaskBindingCoordinator Extraction" entry, Shared Decision #7, Binding Constraints #2/#20/#21/#71/#72/#73/#75)_


## Required Context

### From `dev/specs/0.16.5/plan.md` — "[P] S33: WorkflowTaskBindingCoordinator Extraction" (incl. 2026-05-04 reconciliation)
<!-- source: dev/specs/0.16.5/plan.md#p-s33-workflowtaskbindingcoordinator-extraction -->
<!-- extracted: e670c47 -->
> **Scope**: **Note (2026-05-04 reconciliation)**: the bulk of S33's heavy lifting already landed during 0.16.4. The three workflow-shared-worktree maps and waiter set (`_workflowSharedWorktrees`, `_workflowSharedWorktreeBindings`, `_workflowSharedWorktreeWaiters`, `_workflowInlineBranchKeys`) and the `hydrateWorkflowSharedWorktreeBinding(...)` entry point were extracted from `task_executor.dart` into a concrete class `WorkflowWorktreeBinder` at `packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart`. `TaskExecutor` now delegates via a `_worktreeBinder` field (`task_executor.dart:146`). The inter-task-binding `StateError` defensive guard moved into `hydrateWorkflowSharedWorktreeBinding` on the binder.
>
> The remaining 0.16.5 work narrows to the **interface + fake + signature polish**:
> 1. **Lift the abstract interface** from the concrete `WorkflowWorktreeBinder` into `dartclaw_core/lib/src/workflow/` as `abstract interface class WorkflowTaskBindingCoordinator { hydrate, get, put, waitFor }` — picking the surface that consumers actually need (drop public methods that callers don't reach for).
> 2. **Rename or wrap** the concrete class as `WorkflowTaskBindingCoordinatorImpl` (or keep the `WorkflowWorktreeBinder` filename and have it `implements WorkflowTaskBindingCoordinator`) so `TaskExecutor` and `WorkflowService` depend on the interface, not the concrete type.
> 3. **Add a fake** at `dartclaw_testing/lib/src/fake_workflow_task_binding_coordinator.dart`.
> 4. **Drop the redundant `workflowRunId` parameter** in the hydrate callback signature — the binding already carries it. Remove or reduce the defensive guard now that the param mismatch can't happen.
>
> This extraction is what ARCH-004 anticipated; the unblock-S16 framing remains accurate, but S16's "drop the workflow-shared-worktree concern" is **already structurally true** (the binder owns them), so S16's residual is constructor-parameter reduction + dep-grouping only.
>
> **Acceptance Criteria**:
> - [ ] `WorkflowTaskBindingCoordinator` abstract interface class exists in `dartclaw_core` with the methods consumers actually need (must-be-TRUE)
> - [ ] Existing `WorkflowWorktreeBinder` (or a renamed `WorkflowTaskBindingCoordinatorImpl`) in `dartclaw_server` `implements` the new interface; `TaskExecutor` types its field as the interface, not the concrete (must-be-TRUE)
> - [ ] `FakeWorkflowTaskBindingCoordinator` in `dartclaw_testing` for unit-test use
> - [x] `TaskExecutor` no longer holds `_workflowSharedWorktrees*` fields directly — **already met by 0.16.4** (delegates via `_worktreeBinder` field at `task_executor.dart:146`); verify still met
> - [ ] Callback signature no longer carries the redundant `workflowRunId` parameter — only the binding itself
> - [ ] Defensive `StateError` (now living on the binder) deleted or reduced once the signature change makes the mismatch impossible
> - [ ] `dart analyze` and `dart test` workspace-wide pass; workflow-shared-worktree integration tests unchanged
> - [ ] Unblocks S16: `_TaskPreflight` / `_TaskTurnRunner` / `_TaskPostProcessor` split no longer needs to carry the binding-coordinator concern

### From `dev/specs/0.16.5/.technical-research.md` — Shared Decision #7 (S33 → S16 contract)
<!-- source: dev/specs/0.16.5/.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> **7. S33 → S16 — `WorkflowTaskBindingCoordinator` interface contract**
> - WHAT: `abstract interface class WorkflowTaskBindingCoordinator` in `dartclaw_core/lib/src/workflow/` exposes `hydrate`, `get`, `put`, `waitFor`. Concrete `WorkflowWorktreeBinder` in `dartclaw_server` implements it. Fake at `dartclaw_testing/lib/src/fake_workflow_task_binding_coordinator.dart`. Hydrate-callback signature drops redundant `workflowRunId` parameter.
> - PRODUCER: S33.
> - CONSUMER: S16.
> - WHY: S16 ctor-reduction depends on coordinator handoff seam.

### From `dev/specs/0.16.5/.technical-research.md` — Binding PRD Constraints (rows applying to S33)
<!-- source: dev/specs/0.16.5/.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> | 2 | "No new dependencies in any package. Fitness functions use existing `test` + `analyzer` + `package_config`." | Constraint | All stories |
> | 20 | "`WorkflowTaskBindingCoordinator` abstract interface in `dartclaw_core` with concrete impl in `dartclaw_server` and fake in `dartclaw_testing`; `TaskExecutor` no longer holds `_workflowSharedWorktrees*` maps." | FR3 | S33 |
> | 21 | "`testing_package_deps_test.dart` + `no_cross_package_env_plan_duplicates_test.dart` fitness functions pass." | FR3 | S10, S25, S32 |
> | 71 | "Behavioural regressions post-decomposition: Zero — every existing test remains green." | NFR Reliability | S15, S16, S17, S18, S22, S33 |
> | 72 | "No regression in guard chain, credential proxy, audit logging — all existing security tests pass." | NFR Security | S11, S32, S33 |
> | 73 | "Workspace-wide strict-casts + strict-raw-types must remain on throughout." | Constraint | All code-touching stories |
> | 75 | "JSONL control protocol, REST API payload shapes, SSE envelope formats unchanged." | Out of Scope / NFR | S05, S15, S16, S17, S18, S22, S35 |


## Deeper Context

- `dev/specs/0.16.5/plan.md#s16-task-executor-residual-cleanup-ctor-params--binding-handoff` — S16 consumes this seam: confirms the residual cleanup S16 carries (ctor reduction, dep-grouping) once S33 closes.
- `dev/specs/0.16.5/.technical-research.md#story-scoped-file-map` (S33 entry, lines ~510-518) — primary file list and surface decisions.
- `dev/state/LEARNINGS.md` — async/loop discipline; relevant for the mutex-preservation acceptance.


## Success Criteria (Must Be TRUE)

- [ ] `WorkflowTaskBindingCoordinator` abstract interface class exists at `packages/dartclaw_core/lib/src/workflow/workflow_task_binding_coordinator.dart` and is exported from `packages/dartclaw_core/lib/dartclaw_core.dart` with a `show` clause
- [ ] The interface exposes exactly the surface consumers reach for: `hydrate`, `get`, `put`, `waitFor` (consumer-driven naming; concrete method names from `WorkflowWorktreeBinder` map onto these — see Architecture Decision)
- [ ] The concrete server-side class (current `WorkflowWorktreeBinder` at `packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart`) declares `implements WorkflowTaskBindingCoordinator` (rename to `WorkflowTaskBindingCoordinatorImpl` is optional — record the decision either way)
- [ ] `TaskExecutor._worktreeBinder` (`packages/dartclaw_server/lib/src/task/task_executor.dart:146`) is typed as `WorkflowTaskBindingCoordinator`, not the concrete class
- [ ] `WorkflowService._hydrateWorkflowWorktreeBinding` callback (`packages/dartclaw_workflow/lib/src/workflow/workflow_service.dart:68`) and all wiring callers (`apps/dartclaw_cli/lib/src/commands/service_wiring.dart:654`, `cli_workflow_wiring.dart:413`) drop the redundant `workflowRunId` named parameter — the binding already carries it
- [x] `TaskExecutor` no longer holds `_workflowSharedWorktrees*` fields directly — **already met by 0.16.4**; verified by inspection that `task_executor.dart` does not declare those fields
- [ ] Defensive `StateError` mismatch guard in `WorkflowWorktreeBinder.hydrateWorkflowSharedWorktreeBinding` (lines 33-37) is deleted, since the signature change makes the param/binding mismatch unrepresentable; the equivalent guard inside `WorkflowService._rehydrateWorkflowWorktreeBinding` (lines 742-747) remains — it asserts the persisted binding's run-id matches the run that owns it
- [ ] `FakeWorkflowTaskBindingCoordinator` exists at `packages/dartclaw_testing/lib/src/fake_workflow_task_binding_coordinator.dart`, implements the interface, and is exported via `packages/dartclaw_testing/lib/dartclaw_testing.dart` with a `show` clause
- [ ] `packages/dartclaw_testing/test/public_api_test.dart` references `FakeWorkflowTaskBindingCoordinator` so the barrel surface stays asserted

### Health Metrics (Must NOT Regress)

- [ ] `dart analyze` workspace-wide: 0 errors, 0 warnings, 0 infos
- [ ] `dart test` workspace-wide green; no test reduced to a smoke check
- [ ] L1 fitness suite (`packages/dartclaw_testing/test/fitness/`) green — including `testing_package_deps_test.dart`, dependency-direction, and barrel ceilings
- [ ] Workflow-shared-worktree integration tests (`packages/dartclaw_server/test/task/task_executor_test.dart`, the workflow integration suites under `packages/dartclaw_workflow/test/workflow/scenarios/`) pass without modification beyond the callback-signature update at the call sites
- [ ] No new package dependencies added (constraint #2)
- [ ] `dartclaw_core` LOC ceiling (≤13 000) and barrel ceiling (≤80 exports) honoured


## Scenarios

### Workflow-shared worktree: 3 sibling tasks hydrate to the same path
- **Given** a workflow run started with `gitStrategy.worktree: shared` that has spawned three child tasks bound to the same `workflowRunId`
- **When** all three tasks are processed by `TaskExecutor` and request a worktree
- **Then** each one resolves through `WorkflowTaskBindingCoordinator` to the same `WorktreeInfo` (identical `path` and `branch`); the underlying `WorktreeManager.create` is invoked exactly once for the run

### Concurrent hydrate attempts serialise behind a single waiter
- **Given** two sibling tasks for the same workflow run hit the coordinator concurrently before any worktree is materialised
- **When** both call the resolve-shared-worktree path on the same `workflowWorktreeKey`
- **Then** exactly one creates the worktree; the second awaits the existing `Completer` and returns the same `WorktreeInfo`; no duplicate `git worktree add` is attempted (mutex semantics inherited from the existing `WorkflowWorktreeBinder` are preserved)

### Hydrate callback signature: workflowRunId is sourced from the binding alone
- **Given** `WorkflowService._rehydrateWorkflowWorktreeBinding` iterates persisted bindings on resume/retry
- **When** it invokes the injected hydrate callback with each binding
- **Then** the callback signature accepts only the binding (no separate `workflowRunId` named parameter); the implementation reads `binding.workflowRunId` directly; the per-binding self-consistency check stays in `WorkflowService._rehydrateWorkflowWorktreeBinding` (binding.workflowRunId == run.id)

### Persisted binding self-consistency violation surfaces from the workflow layer
- **Given** a corrupted persisted `WorkflowWorktreeBinding` whose `workflowRunId` does not match the run currently being resumed
- **When** `WorkflowService._rehydrateWorkflowWorktreeBinding` walks the bindings before invoking the hydrate callback
- **Then** it throws `StateError` with the existing message ("Workflow worktree binding run ID mismatch: persisted X, requested Y") — this guard is the single remaining mismatch check; the previously-redundant guard on the binder side is deleted because the callback can no longer be called with a mismatched run-id

### Fake binding coordinator drives a unit test without spinning up a real WorktreeManager
- **Given** a server-package or workflow-package unit test seeding `FakeWorkflowTaskBindingCoordinator` with a pre-baked `WorktreeInfo` for a known key
- **When** the system-under-test calls the coordinator's resolve / get path
- **Then** the fake returns the seeded `WorktreeInfo` synchronously; the test never touches the filesystem or git; no `WorktreeManager` is constructed


## Scope & Boundaries

### In Scope

- New `WorkflowTaskBindingCoordinator` interface in `dartclaw_core/lib/src/workflow/` plus barrel export
- Concrete `WorkflowWorktreeBinder` declares `implements WorkflowTaskBindingCoordinator` (rename optional; choose and record)
- `TaskExecutor._worktreeBinder` field retyped to the interface
- Hydrate callback signature: drop `workflowRunId` named parameter at `WorkflowService` ctor, all 2 wiring call sites, and the public `TaskExecutor.hydrateWorkflowSharedWorktreeBinding` re-export method
- Delete the now-unreachable defensive `StateError` mismatch guard in `WorkflowWorktreeBinder.hydrateWorkflowSharedWorktreeBinding`
- `FakeWorkflowTaskBindingCoordinator` in `dartclaw_testing` + barrel export + `public_api_test.dart` registration
- Workspace-wide `dart analyze` + `dart test` clean

### What We're NOT Doing

- **No internal refactor of `WorkflowWorktreeBinder` beyond the interface lift** — the concrete class shipped in 0.16.4; reorganising its internals is out of scope and risks regression.
- **Not changing `WorktreeInfo` or `WorkflowWorktreeBinding` shapes** — those types are stable; this story only narrows the calling contract.
- **Not deleting `WorkflowTaskService`** — that's a separate narrow service interface; unrelated concern.
- **Not editing S16's residual cleanup work** — S16 owns ctor reduction + dep-grouping in `task_executor.dart`; this story only ensures the seam is clean for S16 to consume.
- **Not removing the `WorkflowService`-side mismatch guard** — that guard checks persisted-data integrity on resume and remains useful even after the callback signature tightens.

### Agent Decision Authority

- **Autonomous**: file/class naming choice (`WorkflowWorktreeBinder` keeps name and adds `implements ...` vs. rename to `WorkflowTaskBindingCoordinatorImpl`); selection of the four canonical interface method names from the binder's existing public surface; whether the fake is purely in-memory or accepts seeding callbacks (prefer simplest in-memory shape that the existing tests can use).
- **Escalate**: any decision that would require touching `WorkflowWorktreeBinding` / `WorktreeInfo` shapes or the persisted JSON; any addition of a package dependency.


## Architecture Decision

**We will**: Lift the consumer-facing surface of the existing concrete `WorkflowWorktreeBinder` into `dartclaw_core/lib/src/workflow/workflow_task_binding_coordinator.dart` as `abstract interface class WorkflowTaskBindingCoordinator { hydrate, get, put, waitFor }`, keep the concrete server-side implementation (with a `implements WorkflowTaskBindingCoordinator` declaration; rename to `WorkflowTaskBindingCoordinatorImpl` deferred — keeping `WorkflowWorktreeBinder` minimises diff and preserves test stability), and drop the redundant `workflowRunId` callback parameter, which makes the binder-side mismatch guard unreachable and therefore deletable. The interface follows the existing narrow-service-contract pattern set by `WorkflowTaskService` in `packages/dartclaw_core/lib/src/task/workflow_task_service.dart` -- (over a full server-side rewrite or a more elaborate ADT for the four operations, both of which would expand scope without changing runtime behaviour).

**Method-name mapping (pinned at FIS time, autonomous to the executor only inside this mapping):**

| Interface method (consumer-facing) | Existing concrete method | Notes |
|---|---|---|
| `hydrate(binding)` | `hydrateWorkflowSharedWorktreeBinding(binding, workflowRunId: ...)` | Drops the redundant named parameter |
| `get(workflowWorktreeKey)` | accessor over `_workflowSharedWorktrees[key]` (currently inlined in `resolveWorkflowSharedWorktree`) | New accessor on the concrete; returns `WorktreeInfo?` |
| `put(workflowWorktreeKey, info)` / `resolveShared(...)` | `resolveWorkflowSharedWorktree(task, ...)` | Keep the existing rich resolve method on the concrete; the interface exposes the narrow `put`/`resolveShared` consumers actually need |
| `waitFor(workflowWorktreeKey)` | the in-flight-`Completer` path inside `resolveWorkflowSharedWorktree` | Surfaced so callers can observe the mutex without the concrete type |

> If the executor finds during implementation that an exact 1:1 with `hydrate/get/put/waitFor` over-constrains the surface (e.g. real consumers only need `hydrate` + `resolveShared`), narrow the interface accordingly and record the decision in the implementation observations. The acceptance criterion is "the methods consumers actually need" — not the four names verbatim.

**Reference**: `dartclaw_core/lib/src/task/workflow_task_service.dart` (existing narrow-service interface to mirror).


## Technical Overview

### Data Models

No new types. Reuses existing `WorkflowWorktreeBinding` (`packages/dartclaw_models/lib/src/workflow_run.dart:4`) and `WorktreeInfo` (`packages/dartclaw_server/lib/src/task/worktree_manager.dart:13`). `WorktreeInfo` lives in `dartclaw_server`, but the interface is consumed only by server code (`TaskExecutor`) and the workflow-package callback (which never references `WorktreeInfo`), so the interface signature does not need to mention `WorktreeInfo` at all — the only cross-package method on the interface is `hydrate(WorkflowWorktreeBinding)`. Server-only methods on the interface (`get`, `put`, `waitFor`) can keep `WorktreeInfo` types since they are consumed only inside `dartclaw_server`. (Confirmed: the interface file in `dartclaw_core` does not need to import `WorktreeInfo` because those methods are scoped via Dart's normal cross-package import — `WorktreeInfo` ships from `dartclaw_server.dart`'s public surface and the interface in `dartclaw_core` cannot reference it without violating the dependency direction. Resolution: keep the interface's narrow surface to types that already live in `dartclaw_core`/`dartclaw_models`; if `WorktreeInfo`-returning methods are needed on the interface, parameterise via the `dartclaw_models`-resident types or keep those operations off the interface and on the concrete only. **Pin: the interface MUST NOT import from `dartclaw_server`. If a method's signature requires `WorktreeInfo`, it stays off the interface.**)

### Integration Points

- `TaskExecutor` (server): construction at `:146` retypes the field; the wrapper method `hydrateWorkflowSharedWorktreeBinding` at `:165` either keeps its name as a delegate or renames to match the new interface signature (no `workflowRunId` arg).
- `WorkflowService` (workflow): `_hydrateWorkflowWorktreeBinding` typedef and ctor parameter at `:68-69, :101-102, :124` lose the `workflowRunId` named param; `_rehydrateWorkflowWorktreeBinding` at `:737-754` calls `hydrate(binding)` without the named arg.
- Wiring (CLI): `apps/dartclaw_cli/lib/src/commands/service_wiring.dart:654` and `cli_workflow_wiring.dart:413` are updated to point at the new signature (typically a tear-off of the executor's coordinator method).
- Tests: `packages/dartclaw_server/test/task/task_executor_test.dart:1788` invokes `projectExecutor.hydrateWorkflowSharedWorktreeBinding(binding, workflowRunId: workflowRunId)` — drop the `workflowRunId` named arg.


## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_core/lib/src/task/workflow_task_service.dart            | Pattern for narrow service interface in dartclaw_core (mirror its shape and barrel-export style)
file   | packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart       | Concrete class to add `implements WorkflowTaskBindingCoordinator` to; source of method-name mapping
file   | packages/dartclaw_server/lib/src/task/task_executor.dart:146-167          | Field declaration + delegate wrapper to retype/cleanup
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_service.dart:68-124  | Callback typedef + ctor field — drop workflowRunId named param
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_service.dart:737-754 | _rehydrateWorkflowWorktreeBinding — keep the persisted-data integrity guard here
file   | apps/dartclaw_cli/lib/src/commands/service_wiring.dart:654                | hydrateWorkflowWorktreeBinding wiring call site
file   | apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart:413  | hydrateWorkflowWorktreeBinding wiring call site
file   | packages/dartclaw_server/test/task/task_executor_test.dart:1788           | Test invocation that needs the named-arg drop
file   | packages/dartclaw_testing/lib/dartclaw_testing.dart                       | Barrel for the new fake export (alphabetised `show` clause)
file   | packages/dartclaw_testing/test/public_api_test.dart                       | Register the new fake so the barrel-surface assertion stays current
file   | packages/dartclaw_testing/lib/src/fake_turn_manager.dart                  | Existing fake to model the new fake's structure on
```


## Constraints & Gotchas

- **Layering**: `dartclaw_core` MUST NOT import `dartclaw_server` (arch_check L1). The interface in `dartclaw_core` cannot reference `WorktreeInfo`. -- Workaround: keep `WorktreeInfo`-returning methods (`get`, `put` if it returns the info, `waitFor`) on the concrete only or — preferred — on the interface but typed against types resident in `dartclaw_models`/`dartclaw_core`. If the four-method surface cannot fit, narrow it to the cross-package methods consumers truly need (at minimum `hydrate(binding)`) and document the narrowing in implementation observations.
- **Dep-direction fitness**: changes must keep `testing_package_deps_test.dart` and `dependency_direction_test.dart` green. -- Workaround: do not add `dartclaw_storage` or any new dep to `dartclaw_testing`; existing fakes show the right pattern.
- **Mutex preservation**: the in-flight-`Completer` semantics inside `resolveWorkflowSharedWorktree` must not change. -- Avoid: rewriting the resolve loop while at it; this story is interface-only. Do NOT rip up the existing implementation.
- **`WorkflowService` integrity guard stays**: the persisted-binding-vs-run-id mismatch check at `workflow_service.dart:742-747` remains. -- Instead: only delete the **redundant** mismatch guard inside `WorkflowWorktreeBinder.hydrateWorkflowSharedWorktreeBinding` (lines 33-37), which becomes unreachable once the callback signature drops `workflowRunId`.
- **Critical — barrel hygiene**: `dartclaw_core` and `dartclaw_testing` barrels both use explicit `show` clauses. -- Must handle by: adding the new symbol with a `show` list, not a blanket export.
- **Avoid scope creep into S16**: this story does not touch `task_executor.dart` constructor params or dep-group structs. -- Instead: only the `_worktreeBinder` field type changes; everything else is S16's territory.


## Implementation Plan

> Vertical slice ordering: interface first, then concrete-implements declaration, then field retype, then signature drop (which removes the redundant guard), then fake + barrel wiring, then verification.

### Implementation Tasks

- [ ] **TI01** Verify the 0.16.4 baseline still holds — `task_executor.dart` declares no `_workflowSharedWorktrees*` / `_workflowInlineBranchKeys` fields and the `_worktreeBinder` delegate at `:146` is still present.
  - Pure read; no code change. If the baseline does not hold, STOP and surface as `BLOCKED:` — S33's reconciliation premise is invalidated.
  - **Verify**: `rg '_workflowSharedWorktrees|_workflowInlineBranchKeys' packages/dartclaw_server/lib/src/task/task_executor.dart` returns 0 lines; `rg '_worktreeBinder' packages/dartclaw_server/lib/src/task/task_executor.dart` returns ≥2 lines including the field declaration.

- [ ] **TI02** Author `WorkflowTaskBindingCoordinator` abstract interface in `packages/dartclaw_core/lib/src/workflow/workflow_task_binding_coordinator.dart`.
  - Mirror narrow-service shape from `dartclaw_core/lib/src/task/workflow_task_service.dart`. Surface: at minimum `Future<void> hydrate(WorkflowWorktreeBinding binding)`. Add `get`/`put`/`waitFor` only if their signatures fit without importing `dartclaw_server` types (per Constraints — `WorktreeInfo` lives in `dartclaw_server`). Dartdoc each method (`public_member_api_docs` is on for the package).
  - **Verify**: `dart analyze packages/dartclaw_core` = 0 issues; the file declares `abstract interface class WorkflowTaskBindingCoordinator` and contains `hydrate(WorkflowWorktreeBinding`.

- [ ] **TI03** Export the new interface from `packages/dartclaw_core/lib/dartclaw_core.dart` with an explicit `show WorkflowTaskBindingCoordinator` clause (alphabetised among the existing exports).
  - Pattern: `export 'src/task/workflow_task_service.dart' show WorkflowTaskService;` at line 139.
  - **Verify**: `rg "show WorkflowTaskBindingCoordinator" packages/dartclaw_core/lib/dartclaw_core.dart` returns exactly 1 line; barrel ceiling test in `packages/dartclaw_core/test/` passes.

- [ ] **TI04** Make `WorkflowWorktreeBinder` declare `implements WorkflowTaskBindingCoordinator` and align method names where necessary so the implements clause is satisfied without altering existing call sites except through the public method renames you choose.
  - At `packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart:15`. Keep `WorkflowWorktreeBinder` as the class name (rename deferred — minimises diff). Methods that match the interface verbatim need no change; ones that need to expose a narrower signature get a thin override that delegates to the existing internal method.
  - **Verify**: `dart analyze packages/dartclaw_server` = 0 issues; `WorkflowWorktreeBinder` line shows `final class WorkflowWorktreeBinder implements WorkflowTaskBindingCoordinator`.

- [ ] **TI05** Retype `TaskExecutor._worktreeBinder` to the interface.
  - At `packages/dartclaw_server/lib/src/task/task_executor.dart:146`. Field type becomes `WorkflowTaskBindingCoordinator`; initializer remains a `WorkflowWorktreeBinder(...)` construction. Add the `dartclaw_core` import for the interface if not already present.
  - **Verify**: `dart analyze packages/dartclaw_server` = 0 issues; `rg "WorkflowTaskBindingCoordinator " packages/dartclaw_server/lib/src/task/task_executor.dart` shows the field declaration line.

- [ ] **TI06** Drop the redundant `workflowRunId` named parameter from the hydrate-callback typedef and ctor field in `WorkflowService`.
  - At `packages/dartclaw_workflow/lib/src/workflow/workflow_service.dart:68-69, 101-102, 124, 749-752`. Callback type becomes `FutureOr<void> Function(WorkflowWorktreeBinding binding)`; the per-binding self-consistency check at `:742-747` (binding.workflowRunId == run.id) STAYS.
  - **Verify**: `rg "workflowRunId:" packages/dartclaw_workflow/lib/src/workflow/workflow_service.dart` returns 0 matches inside hydrate-callback signatures; `dart analyze packages/dartclaw_workflow` = 0 issues.

- [ ] **TI07** Update CLI wiring call sites and `TaskExecutor` delegate to the new signature.
  - `apps/dartclaw_cli/lib/src/commands/service_wiring.dart:654` and `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart:413` now pass a tear-off matching the no-`workflowRunId` signature. `TaskExecutor.hydrateWorkflowSharedWorktreeBinding` (`task_executor.dart:165-167`) drops its `workflowRunId` named param and forwards to the binder method (which itself drops the param in TI04).
  - **Verify**: `rg "hydrateWorkflowSharedWorktreeBinding\(.*workflowRunId" apps/ packages/` returns 0 matches; `dart analyze apps/dartclaw_cli packages/dartclaw_server` = 0 issues.

- [ ] **TI08** Delete the now-unreachable defensive `StateError` mismatch guard from `WorkflowWorktreeBinder.hydrateWorkflowSharedWorktreeBinding`.
  - At `packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart:32-38`: remove the `if (binding.workflowRunId != workflowRunId) { throw StateError(...) }` block — the param mismatch is no longer representable. The `_assertWorkflowSharedBindingMatch` helper at `:227-239` (called from `resolveWorkflowSharedWorktree`) is a separate guard and STAYS — it covers the case where a task's `workflowRunId` differs from the persisted binding for the same worktree key, which is reachable via `Task.workflowRunId`.
  - **Verify**: `rg "Workflow worktree binding run ID mismatch" packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart` returns 0 lines; `_assertWorkflowSharedBindingMatch` is still called from `resolveWorkflowSharedWorktree`; `rg "Workflow worktree binding run ID mismatch" packages/dartclaw_workflow/lib/src/workflow/workflow_service.dart` returns 1 line (the surviving `WorkflowService` guard).

- [ ] **TI09** Update the `task_executor_test.dart` invocation to the new signature.
  - At `packages/dartclaw_server/test/task/task_executor_test.dart:1788`: drop the `workflowRunId: workflowRunId` named arg.
  - **Verify**: `rg "hydrateWorkflowSharedWorktreeBinding\(.*workflowRunId" packages/dartclaw_server/test/` returns 0 matches.

- [ ] **TI10** Author `FakeWorkflowTaskBindingCoordinator` at `packages/dartclaw_testing/lib/src/fake_workflow_task_binding_coordinator.dart`.
  - Implements `WorkflowTaskBindingCoordinator`. Records hydrated bindings in an in-memory `Map<String, WorkflowWorktreeBinding>` keyed by `binding.key`; exposes a public `bindings` accessor for assertions. Pattern: model on `packages/dartclaw_testing/lib/src/fake_turn_manager.dart`. Pure-Dart, no `dart:io`.
  - **Verify**: `dart analyze packages/dartclaw_testing` = 0 issues; the fake class signature is `class FakeWorkflowTaskBindingCoordinator implements WorkflowTaskBindingCoordinator`.

- [ ] **TI11** Export the fake from `packages/dartclaw_testing/lib/dartclaw_testing.dart` with `show FakeWorkflowTaskBindingCoordinator` and a re-export of `WorkflowTaskBindingCoordinator` from `dartclaw_core` so consumers don't need a second import.
  - Pattern: existing `show FakeTurnManager` + the existing `dartclaw_core` re-export block at lines 7-31 (extend it with `WorkflowTaskBindingCoordinator`).
  - **Verify**: `rg "FakeWorkflowTaskBindingCoordinator|WorkflowTaskBindingCoordinator" packages/dartclaw_testing/lib/dartclaw_testing.dart` returns ≥2 lines.

- [ ] **TI12** Register `FakeWorkflowTaskBindingCoordinator` in `packages/dartclaw_testing/test/public_api_test.dart` so the barrel surface stays asserted.
  - Add an `expect(FakeWorkflowTaskBindingCoordinator(), isA<WorkflowTaskBindingCoordinator>())` (or equivalent) following the existing pattern in the file. Pattern at lines 6-14.
  - **Verify**: `dart test packages/dartclaw_testing/test/public_api_test.dart` passes.

- [ ] **TI13** Workspace verification — run analyzer + tests + targeted fitness checks; ensure zero behaviour change.
  - Run `dart format --set-exit-if-changed`, `dart analyze --fatal-infos`, `dart test` workspace-wide. Specifically inspect `packages/dartclaw_testing/test/fitness/testing_package_deps_test.dart` and `dependency_direction_test.dart` results. Scan `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` for stragglers.
  - **Verify**: all three commands exit 0; integration tests under `packages/dartclaw_workflow/test/workflow/scenarios/` covering shared-worktree paths pass unchanged; the fitness suite report shows no allowlist additions.

### Testing Strategy

- [TI02,TI03] Scenario: _Hydrate callback signature: workflowRunId is sourced from the binding alone_ → analyzer verifies the typedef compiles only with the binding-only signature; new interface surface is reachable via barrel.
- [TI04,TI05] Scenario: _Workflow-shared worktree: 3 sibling tasks hydrate to the same path_ → existing integration test `task_executor_test.dart` (and workflow scenario tests) re-runs unchanged after the field retype + implements declaration.
- [TI04] Scenario: _Concurrent hydrate attempts serialise behind a single waiter_ → mutex test in `task_executor_test.dart` for `resolveWorkflowSharedWorktree` re-runs unchanged.
- [TI06,TI07,TI08,TI09] Scenario: _Hydrate callback signature_ + _Persisted binding self-consistency violation_ → existing workflow resume tests (which exercise `_rehydrateWorkflowWorktreeBinding`) re-run unchanged; new test coverage may live in the consuming stories.
- [TI10,TI11,TI12] Scenario: _Fake binding coordinator drives a unit test without spinning up a real WorktreeManager_ → `public_api_test.dart` instantiates the fake and asserts the interface conformance; the fake itself is exercised when downstream stories (S16) start using it. A focused per-fake test (`fake_workflow_task_binding_coordinator_test.dart`) is welcome but not required by this story's success criteria.

### Validation

- Manual: spot-check `dev/tools/run-fitness.sh` (or `dart test packages/dartclaw_testing/test/fitness/`) shows green; arch_check passes (`dart run dev/tools/arch_check.dart`).

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (column names, format strings, file paths, error messages) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs: documentation lookup, architectural advice, build troubleshooting, research — spawn in background when possible and do not block progress unnecessarily.
- After all tasks: run `dart format --set-exit-if-changed`, `dart analyze --fatal-warnings --fatal-infos`, `dart test` workspace-wide, and keep `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [ ] **All success criteria** met
- [ ] **All tasks** fully completed, verified, and checkboxes checked
- [ ] **No regressions** or breaking changes introduced
- [ ] **Coordinate with S16**: notify S16's executor that the seam is closed; S16 can now drop its provisional handling of the binding-coordinator concern from its scope


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._

---

## Plan-format migration addendum (2026-05-06)

> Migrated from the pre-template `plan.md` story body during the plan-template reformat. Verbatim copy of the plan's `**Acceptance Criteria**`, `**Key Scenarios**`, and any detailed `**Scope**` paragraphs not already represented above. Authoritative spec content lives in this FIS; the plan now carries only a 1-2 sentence Scope summary plus catalog metadata.

### From plan.md — Scope detail (migrated from old plan format)

**Scope**: **Note (2026-05-04 reconciliation)**: the bulk of S33's heavy lifting already landed during 0.16.4. The three workflow-shared-worktree maps and waiter set (`_workflowSharedWorktrees`, `_workflowSharedWorktreeBindings`, `_workflowSharedWorktreeWaiters`, `_workflowInlineBranchKeys`) and the `hydrateWorkflowSharedWorktreeBinding(...)` entry point were extracted from `task_executor.dart` into a concrete class `WorkflowWorktreeBinder` at `packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart`. `TaskExecutor` now delegates via a `_worktreeBinder` field (`task_executor.dart:146`). The inter-task-binding `StateError` defensive guard moved into `hydrateWorkflowSharedWorktreeBinding` on the binder.
The remaining 0.16.5 work narrows to the **interface + fake + signature polish**:
1. **Lift the abstract interface** from the concrete `WorkflowWorktreeBinder` into `dartclaw_core/lib/src/workflow/` as `abstract interface class WorkflowTaskBindingCoordinator { hydrate, get, put, waitFor }` — picking the surface that consumers actually need (drop public methods that callers don't reach for).
2. **Rename or wrap** the concrete class as `WorkflowTaskBindingCoordinatorImpl` (or keep the `WorkflowWorktreeBinder` filename and have it `implements WorkflowTaskBindingCoordinator`) so `TaskExecutor` and `WorkflowService` depend on the interface, not the concrete type.
3. **Add a fake** at `dartclaw_testing/lib/src/fake_workflow_task_binding_coordinator.dart`.
4. **Drop the redundant `workflowRunId` parameter** in the hydrate callback signature — the binding already carries it. Remove or reduce the defensive guard now that the param mismatch can't happen.

This extraction is what ARCH-004 anticipated; the unblock-S16 framing remains accurate, but S16's "drop the workflow-shared-worktree concern" is **already structurally true** (the binder owns them), so S16's residual is constructor-parameter reduction + dep-grouping only.

### From plan.md — Acceptance Criteria addendum (migrated from old plan format)

**Acceptance Criteria**:
- [ ] `WorkflowTaskBindingCoordinator` abstract interface class exists in `dartclaw_core` with the methods consumers actually need (must-be-TRUE)
- [ ] Existing `WorkflowWorktreeBinder` (or a renamed `WorkflowTaskBindingCoordinatorImpl`) in `dartclaw_server` `implements` the new interface; `TaskExecutor` types its field as the interface, not the concrete (must-be-TRUE)
- [ ] `FakeWorkflowTaskBindingCoordinator` in `dartclaw_testing` for unit-test use
- [x] `TaskExecutor` no longer holds `_workflowSharedWorktrees*` fields directly — **already met by 0.16.4** (delegates via `_worktreeBinder` field at `task_executor.dart:146`); verify still met
- [ ] Callback signature no longer carries the redundant `workflowRunId` parameter — only the binding itself
- [ ] Defensive `StateError` (now living on the binder) deleted or reduced once the signature change makes the mismatch impossible
- [ ] `dart analyze` and `dart test` workspace-wide pass; workflow-shared-worktree integration tests unchanged
- [ ] Unblocks S16: `_TaskPreflight` / `_TaskTurnRunner` / `_TaskPostProcessor` split no longer needs to carry the binding-coordinator concern

### From plan.md — Key Scenarios addendum (migrated from old plan format)

**Key Scenarios**:
- Happy: workflow run with `worktree: shared` spawns 3 child tasks → all three hydrate from the coordinator → identical worktree path returned
- Edge: concurrent hydrate attempts → coordinator serializes (mutex preserved from current `TaskExecutor` semantics)
- Error: persisted binding disagrees with requested `workflowRunId` → coordinator throws with explicit message (behavior equivalent to the deleted `StateError`, now centralized)

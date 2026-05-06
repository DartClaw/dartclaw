# S12 — `WorkflowRunRepository` Interface in `dartclaw_core`

**Plan**: ../plan.md
**Story-ID**: S12

## Feature Overview and Goal

Promote workflow-run persistence to a typed `abstract interface class WorkflowRunRepository` in `dartclaw_core`, replacing the `dynamic`-wrapped `WorkflowRunRepositoryPort` placeholder currently squatting in `packages/dartclaw_workflow/lib/src/workflow/workflow_runner_types.dart:69`. `SqliteWorkflowRunRepository` (in `dartclaw_storage`) gains an `implements WorkflowRunRepository` clause; every consumer — `WorkflowService`, `WorkflowExecutor`, `StepExecutionContext.repository`, **and `TaskExecutor` (still typed concrete `SqliteWorkflowRunRepository?` at `task_executor.dart:54,113` plus the helper `WorkflowWorktreeBinder` at `workflow_worktree_binder.dart:18,21,25,246`)** — depends on the abstract interface, not the concrete storage type. In the same commit, `dartclaw_testing/test/fitness/workflow_task_boundary_test.dart`'s `_knownViolations` allowlist empties and `dev/tools/arch_check.dart` line 53 drops `dartclaw_storage` from `dartclaw_workflow`'s sanctioned-deps set. Closes ADX-01 (the leaky-abstraction smell would otherwise reappear one package lower in `task_executor.dart`).

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S12 — WorkflowRunRepository Interface in dartclaw_core" entry under Story-Scoped File Map; Shared Decision #13; Binding PRD Constraints #17, #18)_

## Required Context

### From `prd.md` — "FR3: Package Boundary Corrections"
<!-- source: ../prd.md#fr3-package-boundary-corrections -->
<!-- extracted: e670c47 -->
> **Description**: Extract abstractions that currently sit in the server package's concrete implementation so stable packages depend on interfaces, not volatile impls. **Note (2026-05-04 reconciliation)**: TD-063's pubspec edge was already removed during 0.16.4 (`dartclaw_testing/pubspec.yaml` lists only `dartclaw_core` under `dependencies:`); the entry will be deleted at sprint close as 0.16.4-closure backlog hygiene rather than counting toward 0.16.5 closure. The actual interface-extraction work (the substantive part of FR3) is unchanged.
>
> **Acceptance (S12 subset)**:
> - `WorkflowRunRepository` abstract interface in `dartclaw_core`; sqlite impl in `dartclaw_storage` (the existing `WorkflowRunRepositoryPort` in `dartclaw_workflow` is a `dynamic`-wrapped placeholder — promote it, type it properly, then delete the placeholder)
> - **`TaskExecutor` accepts `WorkflowRunRepository?` (abstract), not `SqliteWorkflowRunRepository?`** (delta-review ADX-01 closed) — current ctor field type at `task_executor.dart:113` still concrete

### From `prd.md` — "Status Update — 2026-05-04 reconciliation"
<!-- source: ../prd.md#executive-summary -->
<!-- extracted: e670c47 -->
> **S12 partially landed in 0.16.4** — a `WorkflowRunRepositoryPort` exists in `packages/dartclaw_workflow/lib/src/workflow/workflow_runner_types.dart` but is a `dynamic`-wrapped wrapper, not a proper abstract interface, and lives in the wrong package. Remaining S12 scope: **promote to `dartclaw_core`**, replace the `dynamic` delegate with a typed abstract interface, migrate `TaskExecutor` (still types ctor field as concrete `SqliteWorkflowRunRepository?` at `task_executor.dart:113`) and the call sites that touch the field.

### From `plan.md` — "S12: WorkflowRunRepository Interface in dartclaw_core"
<!-- source: ../plan.md#s12-workflowrunrepository-interface-in-dartclaw_core -->
<!-- extracted: e670c47 -->
> **Scope**: Add an abstract `WorkflowRunRepository` interface to `dartclaw_core` alongside `TaskRepository` and `GoalRepository`. Sqlite implementation (`SqliteWorkflowRunRepository`) remains in `dartclaw_storage`. Every consumer — `WorkflowService`, `WorkflowExecutor`, **and `TaskExecutor` (which currently accepts `SqliteWorkflowRunRepository?` at `task_executor.dart:54,113` and calls into the concrete API)** — depends on the abstract interface, not the concrete storage type. Without the TaskExecutor side of the migration, ADR-023's leaky-abstraction smell reappears one package lower (flagged in ADX-01).
>
> **Note (2026-05-04 reconciliation)**: a partial port already exists at `packages/dartclaw_workflow/lib/src/workflow/workflow_runner_types.dart:69` as `WorkflowRunRepositoryPort` — but it's a `dynamic`-wrapped wrapper inside the wrong package, not a typed abstract interface. The 0.16.5 work is to (1) **promote/rewrite** it as a proper `abstract interface class WorkflowRunRepository` in `dartclaw_core/lib/src/workflow/`, (2) make `SqliteWorkflowRunRepository` `implements` the new interface, (3) migrate `dartclaw_workflow` consumers from the `dynamic`-wrapped port to the typed abstract interface, then (4) delete the placeholder port. `sqlite3` stays in `dartclaw_workflow`'s dev-dependencies for tests that need a real DB. **Fitness test wiring**: S28's `_knownViolations` allowlist empties in the same commit as this migration; `dev/tools/arch_check.dart:47` tightens to drop `dartclaw_storage` from `dartclaw_workflow`'s sanctioned deps in lockstep.

### From `.technical-research.md` — Shared Architectural Decision #13
<!-- source: ../.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> **13. `WorkflowRunRepository` interface location** — `dartclaw_core/lib/src/workflow/`. The `WorkflowRunRepositoryPort` placeholder at `packages/dartclaw_workflow/lib/src/workflow/workflow_runner_types.dart:69` (a `dynamic`-wrapped wrapper) is **deleted** at S12 closure. Consumed by `dartclaw_workflow` AND `dartclaw_server` (`TaskExecutor.workflowRunRepository` field at `task_executor.dart:113` retypes from `SqliteWorkflowRunRepository?` to `WorkflowRunRepository?`; call sites that touch the field migrate to the abstract API). `SqliteWorkflowRunRepository` stays in `dartclaw_storage` and `implements WorkflowRunRepository`. S28's `_knownViolations` empties in same commit; `dev/tools/arch_check.dart` drops `dartclaw_storage` from `dartclaw_workflow` sanctioned deps.

### From `.technical-research.md` — Binding PRD Constraints (S12-applicable)
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #2 (Constraint): "No new dependencies in any package." — Applies to all stories; this story adds none.
> #17 (FR3): "`WorkflowRunRepository` abstract interface in `dartclaw_core`; sqlite impl in `dartclaw_storage`. `WorkflowRunRepositoryPort` placeholder promoted, typed properly, then deleted." — Direct AC.
> #18 (FR3 / ADX-01): "`TaskExecutor` accepts `WorkflowRunRepository?` (abstract), not `SqliteWorkflowRunRepository?`." — Direct AC.
> #21 (FR4): structural tightening fitness — workspace-wide `dart analyze` + `dart test` must remain clean.
> #71 (NFR Architecture): "ADR-023 workflow↔task import boundary enforced" — S28 fitness allowlist empties as part of this commit.
> #75 (NFR Governance): "Architecture fitness tests + arch_check.dart governance gates" — `arch_check.dart` line 53 tightens in lockstep.

### From `.technical-research.md` — "S12 reconciliation note (cross-cutting)"
<!-- source: ../.technical-research.md#cross-cutting-coordination -->
<!-- extracted: e670c47 -->
> S12, S28, and `dev/tools/arch_check.dart:47` move in lockstep — single commit drops `dartclaw_storage` from `dartclaw_workflow` sanctioned deps + empties `_knownViolations` + retypes `TaskExecutor` field. _(Plan-research notes line 47; verified at `dev/tools/arch_check.dart:53` in the current tree — the `dartclaw_workflow` map entry. The line number drift is informational; the change is the literal removal of `'dartclaw_storage'` from that set.)_

## Deeper Context

- `packages/dartclaw_core/lib/src/task/task_repository.dart` — canonical pattern for an abstract storage-agnostic repository in `dartclaw_core`. The new `WorkflowRunRepository` mirrors its shape (single dartdoc summary, one method per public DB operation, no defaults, no transitive imports beyond `dartclaw_models` + `dartclaw_core` siblings).
- `packages/dartclaw_core/lib/dartclaw_core.dart:132-139` — barrel grouping under `// Tasks`. New interface exports as `// Workflow` group (sibling to `// Tasks`, `// Execution`) — see `CLAUDE.md` § Conventions ("hand-maintained `show` clauses").
- `packages/dartclaw_storage/CLAUDE.md` § Boundaries — confirms repos `implement` core interfaces; round-trip enums via stable string names; no exposing raw `Database` (already true for `SqliteWorkflowRunRepository`).
- `packages/dartclaw_workflow/CLAUDE.md` § Boundaries — "Allowed prod deps … `dartclaw_storage` only" line is **the line being tightened** by this story; post-S12 the workflow package depends on `dartclaw_core` for the interface and no longer on `dartclaw_storage` in prod (dev_dependency stays for tests).
- `dev/specs/0.16.5/fis/s28-workflow-task-import-fitness-test.md` — the lockstep partner FIS; its post-S12 scenario "Edge (post-S12): allowlist empties and `arch_check.dart` tightens in lockstep" describes the exact dual edit landed by this story.
- `packages/dartclaw_storage/lib/src/storage/sqlite_workflow_run_repository.dart:107-269` — concrete public method surface (`insert`, `getById`, `list`, `update`, `delete`, `setWorktreeBinding`, `getWorktreeBinding`, `getWorktreeBindings`) — every method on this list MUST be on the abstract interface for the `implements` clause to compile.

## Success Criteria (Must Be TRUE)

- [x] `abstract interface class WorkflowRunRepository` exists at `packages/dartclaw_core/lib/src/workflow/workflow_run_repository.dart` with public method signatures matching every public method currently on `SqliteWorkflowRunRepository` (`insert`, `getById`, `list`, `update`, `delete`, `setWorktreeBinding`, `getWorktreeBinding`, `getWorktreeBindings` — return types and parameter types using only `dartclaw_core` + `dartclaw_models` types).
- [x] `dartclaw_core` barrel (`packages/dartclaw_core/lib/dartclaw_core.dart`) exports `WorkflowRunRepository` via a `show` clause under a `// Workflow` group (or appended to `// Tasks` per author's judgement, mirroring `TaskRepository`'s grouping).
- [x] `SqliteWorkflowRunRepository` in `packages/dartclaw_storage/lib/src/storage/sqlite_workflow_run_repository.dart:12` declares `implements WorkflowRunRepository`; `dart analyze packages/dartclaw_storage` is clean (no missing-method or signature-mismatch errors).
- [x] `dartclaw_workflow` source files import `WorkflowRunRepository` from `package:dartclaw_core/dartclaw_core.dart` (via the barrel), not `SqliteWorkflowRunRepository` from `package:dartclaw_storage`. Specifically: `workflow_service.dart:27` no longer imports `dartclaw_storage`; `workflow_service.dart:50,84,107` retype `_repository` / ctor param to `WorkflowRunRepository`; `workflow_executor.dart:53,101` retype `_repository` and drop the `WorkflowRunRepositoryPort(...)` wrapper construction; `StepExecutionContext.repository` at `workflow_runner_types.dart:222,250,286,321` retypes from `dynamic` to `WorkflowRunRepository`.
- [x] `WorkflowRunRepositoryPort` at `packages/dartclaw_workflow/lib/src/workflow/workflow_runner_types.dart:69-79` is **deleted** (preferred). If a wrapper is still required for staged migration, it `implements WorkflowRunRepository` and `_delegate` is typed as `WorkflowRunRepository` (no `dynamic`).
- [x] `TaskExecutor` ctor parameter (`task_executor.dart:54`) and field declaration (`task_executor.dart:113`) retype from `SqliteWorkflowRunRepository?` to `WorkflowRunRepository?`; the `dartclaw_storage` import on `task_executor.dart:6` is dropped if no other concrete storage type is referenced from the file (else narrowed via `show`).
- [x] `WorkflowWorktreeBinder` (`workflow_worktree_binder.dart:18,21,25,246`) ctor parameter, field, and call-site repository reference retype to `WorkflowRunRepository?`; the file's import of `SqliteWorkflowRunRepository` is dropped or narrowed.
- [x] `dev/tools/arch_check.dart` `'dartclaw_workflow'` allowed-deps set (currently line 53) drops `'dartclaw_storage'` (set becomes `{'dartclaw_config', 'dartclaw_core', 'dartclaw_models', 'dartclaw_security'}`).
- [x] `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` `_knownViolations` map empties (`<String, Set<String>>{}`).
- [x] `dart test packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` passes (zero `dartclaw_storage` imports remain in `packages/dartclaw_workflow/lib/src/**`).
- [x] `dart run dev/tools/arch_check.dart` (or whatever wires it into CI) passes with the tightened sanctioned-deps map.
- [x] `dart analyze --fatal-warnings --fatal-infos` workspace-wide is clean.
- [x] `dart test` workspace-wide passes (no behavioural regressions; tests using a real sqlite DB inside `dartclaw_workflow/test/**` pull `dartclaw_storage` via `dev_dependencies` — unchanged).
- [x] `packages/dartclaw_workflow/CLAUDE.md` § Boundaries "Allowed prod deps" line drops `dartclaw_storage` (Boy-Scout — keep package rules current).
- [x] CHANGELOG `## 0.16.5 - Unreleased` gains a single `### Changed` bullet under "Architecture / boundaries": `WorkflowRunRepository` interface promoted to `dartclaw_core`; `dartclaw_workflow` no longer depends on `dartclaw_storage` in prod; `TaskExecutor` retypes its workflow-run repo dependency to the abstract interface (closes ADX-01).

### Health Metrics (Must NOT Regress)

- [x] Existing `packages/dartclaw_storage/test/storage/sqlite_workflow_run_repository_test.dart` remains green (the implementation gains an `implements` clause; behaviour unchanged).
- [x] `packages/dartclaw_workflow/test/**` remains green (callers see the same method shapes through the abstract interface).
- [x] `packages/dartclaw_server/test/task/**` (TaskExecutor + WorkflowWorktreeBinder tests) remain green.
- [x] JSON wire formats (workflow YAML schema, REST envelopes, SSE event payloads) unchanged — Binding Constraint #1.
- [x] `dev/tools/check_versions.sh` continues to pass (no version pin churn from this story).
- [x] `dartclaw_workflow/pubspec.yaml` `dependencies:` block no longer lists `dartclaw_storage`. `dev_dependencies:` retains `dartclaw_storage` for tests that exercise a real sqlite DB.

## Scenarios

### Workflow run loop persists through the abstract interface
- **Given** a freshly built workspace with `WorkflowRunRepository` in `dartclaw_core` and `SqliteWorkflowRunRepository implements WorkflowRunRepository`
- **When** a workflow run is started and progressed through `WorkflowService.start` / `WorkflowExecutor.execute` against an in-memory sqlite DB (`openTaskDbInMemory()`)
- **Then** the run is inserted, updated step-by-step, and read back via `getById` exclusively through `WorkflowRunRepository` method calls (no `as SqliteWorkflowRunRepository` casts anywhere in `dartclaw_workflow/lib/src/**`); end-state row matches the same canonical assertions as the pre-migration test.

### `TaskExecutor` accepts the abstract interface
- **Given** a `TaskExecutor` constructed with `workflowRunRepository:` set to a fake implementing `WorkflowRunRepository` (e.g. an in-memory test double in `dartclaw_testing` or local to the test)
- **When** `TaskExecutor` polls and progresses a workflow-bound task that triggers `WorkflowWorktreeBinder` to read/write the workflow-run row
- **Then** the executor never references `SqliteWorkflowRunRepository` by name; the test double receives the same method calls (`getById`, `setWorktreeBinding`) the concrete sqlite repo would; no `dynamic` dispatch anywhere in the path.

### `WorkflowRunRepositoryPort` is gone (or correctly typed)
- **Given** S12 has shipped
- **When** `rg "class WorkflowRunRepositoryPort" packages/dartclaw_workflow/`
- **Then** either zero matches (preferred), OR exactly one match where the class declaration includes `implements WorkflowRunRepository` and the `_delegate` field is typed `WorkflowRunRepository` (no `dynamic`).

### S28 fitness test green after lockstep commit
- **Given** S28 is in place with the `_knownViolations` allowlist documenting two `dartclaw_storage` violations (`workflow_service.dart:26`, `workflow_executor.dart:54`) tagged for closure by S12
- **When** the S12 commit lands — abstract interface added, consumers migrated, `_knownViolations` set to `<String, Set<String>>{}`, `arch_check.dart` line 53 sanctioned-deps map tightened
- **Then** `dart test packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` passes, `dart run dev/tools/arch_check.dart` passes, AND a future PR that re-introduces a `package:dartclaw_storage/*` import from `packages/dartclaw_workflow/lib/src/**` would fail BOTH gates.

### Future re-introduction of `dartclaw_storage` in workflow prod fails the build
- **Given** post-S12 baseline (no `dartclaw_storage` in `dartclaw_workflow`'s prod deps, empty allowlist)
- **When** a hypothetical PR adds `import 'package:dartclaw_storage/dartclaw_storage.dart';` to any file under `packages/dartclaw_workflow/lib/src/**`
- **Then** `dart test` fails on `workflow_task_boundary_test.dart` (offending file:line reported), AND `dart run dev/tools/arch_check.dart` fails the sanctioned-deps gate.

### Edge: a fake-only test double satisfies the interface
- **Given** a workflow-package test that wants to inject a controllable repository without spinning up sqlite
- **When** the test declares `class _FakeWorkflowRunRepository implements WorkflowRunRepository { ... }` with hand-rolled methods, and passes it via `StepExecutionContext.repository`
- **Then** the test compiles and runs; the workflow path treats it identically to the sqlite repo (no need for `sqlite3` in unit-level workflow tests post-S12).

### Negative: a partial implementation of the interface fails to compile
- **Given** a developer renames or deletes a public method on `SqliteWorkflowRunRepository` without updating the abstract interface
- **When** `dart analyze packages/dartclaw_storage` runs
- **Then** the analyzer reports `Missing concrete implementation of 'WorkflowRunRepository.<method>'` (or, if the abstract method is removed, every consumer in `dartclaw_workflow` reports `Undefined name`) — the interface is the single source of truth.

## Scope & Boundaries

### In Scope
- Author `WorkflowRunRepository` abstract interface in `packages/dartclaw_core/lib/src/workflow/workflow_run_repository.dart` and add a `// Workflow` (or appended `// Tasks`) export group to the core barrel.
- Add `implements WorkflowRunRepository` to `SqliteWorkflowRunRepository`.
- Migrate `dartclaw_workflow` consumers — `WorkflowService`, `WorkflowExecutor`, `StepExecutionContext.repository`, every internal site that currently reaches through `WorkflowRunRepositoryPort._delegate` — to the typed abstract interface; drop the `package:dartclaw_storage` import from prod source.
- Delete `WorkflowRunRepositoryPort` (preferred) or retype its `_delegate` and add `implements WorkflowRunRepository` if a temporary wrapper is needed for staged migration (this FIS prefers full deletion).
- Migrate `TaskExecutor` (`task_executor.dart:54,113`, plus the construction line passing the field at `task_executor.dart:148`) and `WorkflowWorktreeBinder` (`workflow_worktree_binder.dart:18,21,25,246`) from `SqliteWorkflowRunRepository?` to `WorkflowRunRepository?`. Drop the now-unused `dartclaw_storage` symbol import in those files (or narrow via `show` if other concrete types remain).
- Lockstep edit: empty `_knownViolations` in `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart`; drop `'dartclaw_storage'` from `dartclaw_workflow`'s entry in `dev/tools/arch_check.dart` (line 53 of the current tree).
- Move `dartclaw_storage` from `dependencies:` to `dev_dependencies:` (or remove from `dependencies:` if already present in dev) in `packages/dartclaw_workflow/pubspec.yaml`.
- Update `packages/dartclaw_workflow/CLAUDE.md` § Boundaries "Allowed prod deps" line.
- Add CHANGELOG `0.16.5 - Unreleased` bullet.

### What We're NOT Doing
- Changing `SqliteWorkflowRunRepository` SQL behaviour, schema, or migrations. The class gains an `implements` clause; bodies untouched.
- Renaming `SqliteWorkflowRunRepository` (S36 owns naming sweeps and explicitly does not touch this type per its scope note).
- Refactoring `TaskExecutor` further. S16 owns ctor-parameter-count reduction via dep-group structs; S22/S23/S33/S38 own other facets. This story changes only the type of the `workflowRunRepository` ctor param + field + propagation to `WorkflowWorktreeBinder`, nothing else in `TaskExecutor`'s shape.
- Authoring or modifying `workflow_task_boundary_test.dart` itself — S28 owns the test scaffold; this story only flips its allowlist to empty.
- Modifying `arch_check.dart` beyond the surgical removal of `'dartclaw_storage'` from the `dartclaw_workflow` allowed-deps set.
- Promoting `WorkflowStepExecutionRepository`, `AgentExecutionRepository`, or any other interface that already lives in `dartclaw_core` — those are out of scope.
- Introducing a separate `WorkflowRunRepositoryFake` in `dartclaw_testing` — not required by any AC. Tests can declare local fakes if needed; if reuse pressure emerges later, capture as a follow-up FIS. Not this story.
- Modifying JSON wire formats (workflow YAML schema, REST envelopes, SSE event payloads) — Binding Constraint #1.
- Adding new dependencies — Binding Constraint #2.

### Agent Decision Authority

- **Autonomous**: Choose between full deletion of `WorkflowRunRepositoryPort` versus retaining a typed wrapper. Prefer deletion. If kept, the wrapper MUST `implements WorkflowRunRepository` with no `dynamic` typing, and the FIS author must record the rationale (e.g. one consumer needs API translation) in the relevant TI's Verify line.
- **Autonomous**: Decide whether the abstract interface's method set exactly mirrors `SqliteWorkflowRunRepository`'s public surface or narrows to the subset actually called by `dartclaw_workflow` + `dartclaw_server`. **Default**: full mirror — narrowing is harder to reverse and `TaskRepository` follows the full-mirror precedent. If a method is provably unused, capture as a TODO with a follow-up issue link rather than silently dropping it.
- **Autonomous**: Choose where in the `dartclaw_core` barrel to place the new export (under existing `// Tasks` or a new `// Workflow` group). Default: new `// Workflow` group placed adjacent to `// Tasks`, matching the package's grouping conventions.
- **Escalate**: If `dart analyze` after the consumer migration surfaces a `dartclaw_workflow` site that needs a sqlite-specific method NOT on the abstract interface, stop and surface the conflict — do not silently widen the interface beyond `SqliteWorkflowRunRepository`'s public surface or add a sqlite-only escape hatch. Such a finding indicates a deeper coupling the FIS hasn't accounted for.

## Architecture Decision

**We will**: promote the existing `WorkflowRunRepositoryPort:69` placeholder to `dartclaw_core` as a typed `abstract interface class WorkflowRunRepository`, then migrate all `dartclaw_workflow` consumers + `TaskExecutor`/`WorkflowWorktreeBinder` field types in lockstep with the S28 allowlist tightening and `arch_check.dart` sanctioned-deps narrowing — single commit.

**Rationale**: avoids the leaky-abstraction smell reappearing one package lower (ADX-01). Deferring the `TaskExecutor` migration to a follow-up story would mean `dartclaw_storage`-typed fields persist in `dartclaw_server`, and `_knownViolations` in S28 could not empty — defeating the lockstep dependency-direction proof. Single-commit landing keeps the architectural fitness gates (`workflow_task_boundary_test`, `arch_check.dart`) meaningful: the only commit that empties `_knownViolations` is the same commit that would re-introduce a violation if any consumer were missed, so the gates self-bisect any breakage.

**Alternatives considered**:
1. **Two-commit migration** (interface + workflow consumers in commit A; `TaskExecutor` migration + S28 tighten in commit B) — rejected: between A and B, `dartclaw_workflow` would still depend on `dartclaw_storage` in prod (because at least one consumer still types the field concretely), and the lockstep guarantee would not hold; CI gates would have to allow a transient violation.
2. **Retain `WorkflowRunRepositoryPort` as a permanent typed wrapper** (instead of deleting) — rejected unless a concrete API-translation need surfaces during implementation. The Port today exists to hide a `dynamic` delegate; once the delegate is the interface itself, the wrapper adds no value.
3. **Narrow abstract interface to only the methods called by current consumers** (e.g. drop `delete`, `list` if unused) — rejected (default): full mirror of `SqliteWorkflowRunRepository`'s public surface keeps the interface stable for future consumers and matches `TaskRepository`'s precedent. Narrowing is a separate concern.

## Technical Overview

### Integration Points

- **`dartclaw_core` barrel** (`packages/dartclaw_core/lib/dartclaw_core.dart`): hand-maintained `show` clauses; new export under a `// Workflow` group sibling to existing `// Tasks` / `// Execution` groups. Per `dartclaw_core/CLAUDE.md` § Conventions, "the list in the barrel is hand-maintained — missing exports break server wiring silently."
- **`dartclaw_storage` impl** (`packages/dartclaw_storage/lib/src/storage/sqlite_workflow_run_repository.dart:12`): single-line `implements` change; behaviour preserved. Per `dartclaw_storage/CLAUDE.md` § Conventions, repos round-trip enums via stable string names — already true.
- **`dartclaw_workflow` consumers** (`workflow_service.dart`, `workflow_executor.dart`, `workflow_runner_types.dart`): retype repository fields and ctor params; drop the `dartclaw_storage` import. Per `dartclaw_workflow/CLAUDE.md` § Boundaries: this is the line being tightened — post-S12, allowed prod deps shrink to `{config, core, models, security}`.
- **`dartclaw_server` consumers** (`task_executor.dart:54,113,148`, `workflow_worktree_binder.dart:18,21,25,246`): retype `workflowRunRepository` ctor param + field. Per `dartclaw_server/CLAUDE.md` § Boundaries: this package is the composition layer that legitimately depends on storage; the change here is only that it stops *typing* the field as the concrete impl, even though it constructs the concrete impl in the composition root.
- **`dev/tools/arch_check.dart` sanctioned-deps map** (line 53 in current tree): drop `'dartclaw_storage'` from `dartclaw_workflow`'s allowed-deps set in lockstep.
- **`dartclaw_testing` fitness test** (`test/fitness/workflow_task_boundary_test.dart`): empty the `_knownViolations` map in lockstep with the consumer migration (S28-owned file; this story flips its content per the lockstep contract documented in S28's FIS).

## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_core/lib/src/task/task_repository.dart                                             | Reference pattern — abstract storage-agnostic repository in dartclaw_core; mirror its dartdoc + method-signature shape for WorkflowRunRepository
file   | packages/dartclaw_core/lib/dartclaw_core.dart:125-139                                                | Reference pattern — hand-maintained `show`-clause barrel grouping (// Execution, // Tasks); add new // Workflow group
file   | packages/dartclaw_storage/lib/src/storage/sqlite_workflow_run_repository.dart:12                     | Target — add `implements WorkflowRunRepository` to class declaration
file   | packages/dartclaw_storage/lib/src/storage/sqlite_workflow_run_repository.dart:107-269                 | Source of truth for the public method surface that the abstract interface must mirror (insert, getById, list, update, delete, setWorktreeBinding, getWorktreeBinding, getWorktreeBindings)
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_runner_types.dart:69-79                         | Placeholder to delete (or retype) — `WorkflowRunRepositoryPort` `dynamic`-wrapped wrapper
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_runner_types.dart:218-273                       | StepExecutionContext.repository — retype from `dynamic` to `WorkflowRunRepository`
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart:53,101                            | Retype `_repository` field; drop `WorkflowRunRepositoryPort(...)` wrapper construction (assign `executionContext.repository` directly)
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_service.dart:27,50,84,107                       | Drop `dartclaw_storage` import; retype `_repository` field + ctor param + initialiser
file   | packages/dartclaw_server/lib/src/task/task_executor.dart:6,54,82,113,148                             | Retype ctor param + field; drop or narrow `dartclaw_storage` import
file   | packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart:18,21,25,246                     | Retype ctor param, field, call site
file   | packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart                              | Empty `_knownViolations` map (S28-owned file — flip content only)
file   | dev/tools/arch_check.dart:53                                                                          | Drop `'dartclaw_storage'` from `dartclaw_workflow`'s allowed-deps set (FIS top mentions :47 from older tree state — line :53 in current tree; surgical literal-string removal)
file   | packages/dartclaw_workflow/pubspec.yaml                                                              | Move `dartclaw_storage` from `dependencies:` to `dev_dependencies:` (or remove from `dependencies:` if already present in `dev_dependencies:`)
file   | packages/dartclaw_workflow/CLAUDE.md                                                                 | Boy-Scout — "Allowed prod deps … `dartclaw_storage`" line drops `dartclaw_storage`
```

## Constraints & Gotchas

- **Constraint**: No new dependencies — Binding Constraint #2. The interface lives in `dartclaw_core`, which is already a dep of every involved package.
- **Constraint**: `sqlite3` stays in `dartclaw_workflow`'s `dev_dependencies:` for tests that exercise a real DB. Removing it from prod deps is the lockstep tightening; do not remove from dev deps.
- **Constraint**: JSON wire formats unchanged — Binding Constraint #1.
- **Constraint**: ADR-023 workflow↔task boundary — the post-S12 baseline is the canonical "ADX-01 closed" state. Any drift from the lockstep edits (e.g. emptying `_knownViolations` but forgetting to remove the storage import in `task_executor.dart`) is a regression; gates must be run at every TI Verify line.
- **Gotcha**: `StepExecutionContext.repository` at `workflow_runner_types.dart:222` is currently `dynamic`. Retyping it to `WorkflowRunRepository` is a public-API change for consumers that construct `StepExecutionContext` (the only construction site outside the package is in `dartclaw_server`'s task package) — verify those call sites compile after the retype. The tightening is intentional and forced by the interface promotion; if any caller is found that needs `dynamic`, that's a smell to escalate, not a reason to keep the field `dynamic`.
- **Gotcha**: `WorkflowExecutor._internal` currently constructs `WorkflowRunRepositoryPort(executionContext.repository)` at line 101. After the migration, the right-hand side IS the abstract interface — assign directly: `_repository = executionContext.repository`.
- **Gotcha**: `dartclaw_workflow/CLAUDE.md` § Boundaries explicitly lists `dartclaw_storage` in the allowed-deps line; updating it is part of the story. Drift makes the file actively misleading per CLAUDE.md "Keep these files current" rule.
- **Gotcha**: Plan and `.technical-research.md` reference `dev/tools/arch_check.dart:47`, but at HEAD of `feat/0.16.5` (commit e670c47) the `dartclaw_workflow` allowed-deps line is **line 53**. The FIS prefers the literal change ("drop `'dartclaw_storage'` from the `'dartclaw_workflow'` set entry") over the line number — line numbers drift, the literal is unambiguous.
- **Avoid**: introducing a `WorkflowRunRepositoryFake` in `dartclaw_testing` as a side-effect — explicitly out of scope; if reuse pressure emerges later, capture as a follow-up.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** Add `abstract interface class WorkflowRunRepository` at `packages/dartclaw_core/lib/src/workflow/workflow_run_repository.dart` mirroring the public method surface of `SqliteWorkflowRunRepository` (`insert`, `getById`, `list`, `update`, `delete`, `setWorktreeBinding`, `getWorktreeBinding`, `getWorktreeBindings`). Use only `dartclaw_models` + `dartclaw_core`-internal types in the signatures. Pattern reference: `packages/dartclaw_core/lib/src/task/task_repository.dart`.
  - Each method gets a one-line dartdoc comment describing the contract (per `dartclaw_core/CLAUDE.md` Conventions for public API).
  - **Verify**: file compiles (`dart analyze packages/dartclaw_core` clean); `rg "abstract interface class WorkflowRunRepository" packages/dartclaw_core/lib/src/workflow/` returns exactly one match.

- [x] **TI02** Add export to `packages/dartclaw_core/lib/dartclaw_core.dart` under a new `// Workflow` group (or appended to `// Tasks`): `export 'src/workflow/workflow_run_repository.dart' show WorkflowRunRepository;`. Update `packages/dartclaw_core/test/barrel_export_test.dart` if it locks the surface (per the package's "barrel surface is locked by `test/barrel_export_test.dart`" convention).
  - **Verify**: `dart test packages/dartclaw_core/test/barrel_export_test.dart` passes; `rg "WorkflowRunRepository" packages/dartclaw_core/lib/dartclaw_core.dart` returns at least one hit.

- [x] **TI03** Add `implements WorkflowRunRepository` to `SqliteWorkflowRunRepository` at `packages/dartclaw_storage/lib/src/storage/sqlite_workflow_run_repository.dart:12`. Resolve any signature drift (return-type narrowing, parameter-name parity) — bodies stay byte-identical.
  - Update `packages/dartclaw_storage/CLAUDE.md` § Architecture line listing repos if it mentions the interface relation explicitly (Boy-Scout — only if the line meaningfully drifts).
  - **Verify**: `dart analyze packages/dartclaw_storage` clean (zero "non-abstract class … is missing implementations"); `dart test packages/dartclaw_storage/test/storage/sqlite_workflow_run_repository_test.dart` green.

- [x] **TI04** Migrate `dartclaw_workflow` consumers — `workflow_service.dart` (drop `dartclaw_storage` import at :27; retype `_repository` field at :50, ctor param at :84, initialiser at :107 to `WorkflowRunRepository`), `workflow_executor.dart` (retype `_repository` field at :53; drop `WorkflowRunRepositoryPort(...)` wrapper at :101 — assign `executionContext.repository` directly), `workflow_runner_types.dart` (retype `StepExecutionContext.repository` from `dynamic` to `WorkflowRunRepository` at :222, :250, :286, :321).
  - Import `WorkflowRunRepository` via the `package:dartclaw_core/dartclaw_core.dart` barrel `show` clause already used by these files (extend the `show` list if needed).
  - **Verify**: `rg "package:dartclaw_storage" packages/dartclaw_workflow/lib/` returns zero matches; `rg "dynamic" packages/dartclaw_workflow/lib/src/workflow/workflow_runner_types.dart` reports zero `dynamic` typings on the `repository` field/param; `dart analyze packages/dartclaw_workflow` clean.

- [x] **TI05** Delete `WorkflowRunRepositoryPort` class declaration at `workflow_runner_types.dart:69-79`. Remove the `WorkflowRunRepositoryPort` symbol from `workflow_executor.dart:36`'s `export 'workflow_runner_types.dart';` if that export exposes it (and from any package barrel re-export).
  - If a wrapper is genuinely required for staged migration (escalate first), retain with `implements WorkflowRunRepository` and a typed `_delegate: WorkflowRunRepository`; record the rationale in this Verify line. Default action: delete.
  - **Verify**: `rg "WorkflowRunRepositoryPort" packages/dartclaw_workflow/` returns zero matches (or, if retained, a single match with `implements WorkflowRunRepository`); `dart analyze packages/dartclaw_workflow` clean; `dart test packages/dartclaw_workflow` passes.

- [x] **TI06** Migrate `dartclaw_server` consumers — `packages/dartclaw_server/lib/src/task/task_executor.dart` (retype ctor param at :54, field at :113, ensure import at :6 either drops `dartclaw_storage` or narrows via `show`), and `packages/dartclaw_server/lib/src/task/workflow_worktree_binder.dart` (retype ctor param at :18, initialiser at :21, field at :25, call site at :246). The construction-site at `task_executor.dart:148` (passing `_workflowRunRepository` to `WorkflowWorktreeBinder`) needs no shape change but its types must align.
  - Import `WorkflowRunRepository` from `package:dartclaw_core/dartclaw_core.dart` (already imported in both files; extend the `show` list).
  - **Verify**: `rg "SqliteWorkflowRunRepository" packages/dartclaw_server/lib/` returns matches only at composition-root sites where the concrete impl is constructed (e.g. `server_builder.dart`), never as a parameter or field type. `dart analyze packages/dartclaw_server` clean; `dart test packages/dartclaw_server/test/task/` passes.

- [x] **TI07** Lockstep edit #1 — empty `_knownViolations` in `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` to `<String, Set<String>>{}`. The remediation comment (S12 closure) per S28's FIS may stay as a historical note or be deleted; defer to S28's checkbox if both stories race — the literal map content is what matters.
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` passes (no allowed `dartclaw_storage` violations remain because there are none in the source tree post-TI04/TI05); `rg "dartclaw_storage" packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` returns no matches inside the `_knownViolations` literal.

- [x] **TI08** Lockstep edit #2 — drop `'dartclaw_storage'` from the `'dartclaw_workflow'` entry in `dev/tools/arch_check.dart` (line 53 of current tree); the entry becomes `'dartclaw_workflow': {'dartclaw_config', 'dartclaw_core', 'dartclaw_models', 'dartclaw_security'}`.
  - **Verify**: `dart run dev/tools/arch_check.dart` exits 0; `rg "'dartclaw_storage'" dev/tools/arch_check.dart` shows the literal removed from the `dartclaw_workflow` entry (it may legitimately remain elsewhere, e.g. in keys or in another package's allowlist).

- [x] **TI09** Update `packages/dartclaw_workflow/pubspec.yaml`: move `dartclaw_storage` from `dependencies:` to `dev_dependencies:` (or remove from `dependencies:` if already present in `dev_dependencies:`). Update `packages/dartclaw_workflow/CLAUDE.md` § Boundaries "Allowed prod deps" line — drop `dartclaw_storage`.
  - **Verify**: `grep -A 10 'dependencies:' packages/dartclaw_workflow/pubspec.yaml` shows `dartclaw_storage` only under `dev_dependencies:`; `rg "dartclaw_storage" packages/dartclaw_workflow/CLAUDE.md` shows the dep no longer listed in the prod-deps allowlist line; `dart pub get` workspace-wide succeeds.

- [x] **TI10** Add CHANGELOG entry under `## 0.16.5 - Unreleased` `### Changed`: a single bullet naming the interface promotion, the `dartclaw_workflow → dartclaw_storage` prod-dep removal, and the `TaskExecutor` retype, with `(closes ADX-01)` suffix.
  - Wording exact form not prescribed; content must enumerate (1) interface added in `dartclaw_core`, (2) `dartclaw_workflow` no longer prod-depends on `dartclaw_storage`, (3) `TaskExecutor` field retype.
  - **Verify**: `rg "WorkflowRunRepository" CHANGELOG.md` shows a 0.16.5 entry; `rg "ADX-01" CHANGELOG.md` confirms the closure tag.

- [ ] **TI11** Workspace validation — `dart format --set-exit-if-changed packages apps`, `dart analyze --fatal-warnings --fatal-infos`, `dart test`, and `dart run dev/tools/arch_check.dart` all pass. `dev/tools/release_check.sh --quick` (or its current equivalent) passes.
  - **Verify**: All four commands exit 0; no test reports skipped beyond the project's standard `integration` tag default.

### Testing Strategy

- [TI01,TI02,TI03] Scenario "Workflow run loop persists through the abstract interface" → Existing `sqlite_workflow_run_repository_test.dart` exercises the impl through its public surface; with `implements` clause in place, the test indirectly validates the interface contract. No new test required at this layer.
- [TI04,TI05] Scenario "`WorkflowRunRepositoryPort` is gone (or correctly typed)" → Verified by `rg` assertion in TI05's Verify line. No new test required.
- [TI06] Scenario "`TaskExecutor` accepts the abstract interface" → Existing `dartclaw_server/test/task/task_executor_test.dart` and `workflow_worktree_binder_test.dart` (if present) construct the executor / binder; after TI06 the construction with a fake implementing `WorkflowRunRepository` works without changes. If existing tests still pass an `SqliteWorkflowRunRepository` instance, that's fine — the concrete impl satisfies the abstract interface.
- [TI07,TI08] Scenario "S28 fitness test green after lockstep commit" → `dart test packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` + `dart run dev/tools/arch_check.dart` together prove out the lockstep landing.
- [TI07,TI08,TI11] Scenario "Future re-introduction of `dartclaw_storage` in workflow prod fails the build" → Cross-checked manually post-implementation: a temporary in-tree experiment (revert one of the prod imports) confirms both gates fail; the experiment is then reverted before commit. This is observational, not a committed test.
- [TI11] Scenario "Edge: a fake-only test double satisfies the interface" → Implicitly proven by `dart test` passing across the workspace; if any test in `dartclaw_workflow` already used a fake (e.g. via `dartclaw_testing`'s `InMemoryTaskRepository` pattern for a different repo), it's preserved.
- [TI11] Scenario "Negative: a partial implementation of the interface fails to compile" → Demonstrated transiently during TI03 if signatures drift; the dart analyzer is the standing gate. No new test required.

### Validation

- Standard exec-spec validation gates apply (build/test/analyze + 1-pass remediation).
- Feature-specific gates: `dart test packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` AND `dart run dev/tools/arch_check.dart` MUST both pass after TI07+TI08, before TI11. Either gate failing means the lockstep edit is incomplete (typically: a prod import to `dartclaw_storage` remains in `dartclaw_workflow/lib/src/**`).

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding.
- TI04, TI05, TI06 can in principle be reordered, but TI07 + TI08 MUST follow them — emptying the allowlist before consumers migrate would put the test red transiently and is rejected.
- Prescriptive details (file paths, line numbers, the exact set-membership change in `arch_check.dart`) are exact for the HEAD-of-feat/0.16.5 tree at extraction commit `e670c47`. If line numbers have drifted, the **literal change** (e.g. "drop `'dartclaw_storage'` from `dartclaw_workflow`'s allowed-deps set") is unambiguous regardless of line.
- Mark task checkboxes immediately upon completion — do not batch.

## Final Validation Checklist

- [x] All Success Criteria met
- [ ] All TI01–TI11 tasks fully completed, verified, and checkboxes checked
- [x] No regressions: `dart test` workspace-wide passes; `dart analyze --fatal-warnings --fatal-infos` clean; `dart run dev/tools/arch_check.dart` clean
- [x] CHANGELOG entry present under `## 0.16.5 - Unreleased` `### Changed`, names the interface promotion, the prod-dep removal, and the `TaskExecutor` retype, with `(closes ADX-01)` tag
- [x] `packages/dartclaw_workflow/CLAUDE.md` § Boundaries no longer lists `dartclaw_storage` in the prod-deps allowlist
- [x] `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` `_knownViolations` is `<String, Set<String>>{}`
- [x] `dev/tools/arch_check.dart` `'dartclaw_workflow'` allowed-deps set excludes `'dartclaw_storage'`

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._

---

## Plan-format migration addendum (2026-05-06)

> Migrated from the pre-template `plan.md` story body during the plan-template reformat. Verbatim copy of the plan's `**Acceptance Criteria**`, `**Key Scenarios**`, and any detailed `**Scope**` paragraphs not already represented above. Authoritative spec content lives in this FIS; the plan now carries only a 1-2 sentence Scope summary plus catalog metadata.

### From plan.md — Scope detail (migrated from old plan format)

**Scope**: Add an abstract `WorkflowRunRepository` interface to `dartclaw_core` alongside `TaskRepository` and `GoalRepository`. Sqlite implementation (`SqliteWorkflowRunRepository`) remains in `dartclaw_storage`. Every consumer — `WorkflowService`, `WorkflowExecutor`, **and `TaskExecutor` (which currently accepts `SqliteWorkflowRunRepository?` at `task_executor.dart:54,113` and calls into the concrete API)** — depends on the abstract interface, not the concrete storage type. Without the TaskExecutor side of the migration, ADR-023's leaky-abstraction smell reappears one package lower (flagged in ADX-01).

### From plan.md — Note (2026-05-04 reconciliation)

**Note (2026-05-04 reconciliation)**: a partial port already exists at `packages/dartclaw_workflow/lib/src/workflow/workflow_runner_types.dart:69` as `WorkflowRunRepositoryPort` — but it's a `dynamic`-wrapped wrapper inside the wrong package, not a typed abstract interface. The 0.16.5 work is to (1) **promote/rewrite** it as a proper `abstract interface class WorkflowRunRepository` in `dartclaw_core/lib/src/workflow/`, (2) make `SqliteWorkflowRunRepository` `implements` the new interface, (3) migrate `dartclaw_workflow` consumers from the `dynamic`-wrapped port to the typed abstract interface, then (4) delete the placeholder port. `sqlite3` stays in `dartclaw_workflow`'s dev-dependencies for tests that need a real DB. **Fitness test wiring**: S28's `_knownViolations` allowlist empties in the same commit as this migration; `dev/tools/arch_check.dart:47` tightens to drop `dartclaw_storage` from `dartclaw_workflow`'s sanctioned deps in lockstep.

### From plan.md — Acceptance Criteria addendum (migrated from old plan format)

**Acceptance Criteria**:
- [x] `WorkflowRunRepository` abstract interface in `dartclaw_core/lib/src/workflow/` (or similar) (must-be-TRUE)
- [x] `SqliteWorkflowRunRepository` in `dartclaw_storage` implements the interface (must-be-TRUE)
- [x] `dartclaw_workflow` imports `WorkflowRunRepository` from `dartclaw_core` only, not `SqliteWorkflowRunRepository` by name (must-be-TRUE)
- [x] **`TaskExecutor` accepts `WorkflowRunRepository?` — not `SqliteWorkflowRunRepository?`; the constructor param type changes (currently typed concrete at `task_executor.dart:54,113`), and the two call sites (`task_executor.dart:127,1438`) migrate to the abstract API** (must-be-TRUE)
- [x] The `dynamic`-wrapped `WorkflowRunRepositoryPort` at `workflow_runner_types.dart:69` is deleted (or, if a wrapper is still needed for staged migration, it `implements` the new typed abstract interface) (must-be-TRUE)
- [x] S28's `workflow_task_boundary_test.dart` allowlist empties; `dev/tools/arch_check.dart:47` sanctioned-deps list drops `dartclaw_storage` for `dartclaw_workflow` (must-be-TRUE)
- [x] `dart analyze` and `dart test` workspace-wide pass

# S38 — Readability Pack (logRun helper, typed Task.worktree, taskType rename, dir naming, TaskExecutorLimits)

**Plan**: dev/specs/0.16.5/plan.md
**Story-ID**: S38

## Feature Overview and Goal

Bundle five low-cost, high-payoff readability wins into one cohesive PR. Zero runtime behaviour change. (a) `_logRun(run, msg)` helper in `workflow_executor.dart` collapses 12+ inline `_log.info("Workflow '${run.id}': $msg")` sites and drops per-step progression events from `info` → `fine` (terminal/error/approval stay `info`). (b) Typed `Task.worktree` getter parses the existing `worktreeJson` map field — additive only. (c) `WorkflowStep.type` → `taskType` rename after S35 has typed the field with `WorkflowTaskType`; deprecate the old `type` field via `@Deprecated('Use taskType')`. (d) Dartdoc block in the `dartclaw_core` barrel canonicalises the `dataDir` / `workspaceDir` / `workspaceRoot` / `projectDir` distinction; rename `TaskExecutor.workspaceDir` → `workspaceRoot`. (e) `TaskExecutorLimits` record groups the cohesive policy quintet (`compactInstructions` / `identifierPreservation` / `identifierInstructions` / `maxMemoryBytes` / `budgetConfig`); coordinate with S16's ctor-reduction (S16 consumes; S38 owns the type definition).

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S38 — Readability Pack" file map; Shared Decision #8 for S35→S38 ordering; Binding PRD Constraints rows 1, 2, 55, 71)_


## Required Context

> **Wave-internal ordering (added 2026-05-05 per cross-cutting review F4)**: S22 lands before S35 lands before S38 within W5. After S22, `WorkflowDefinition` and `WorkflowStep` live in `packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart`. S38's field rename `type → taskType` (Part c), dir-naming barrel dartdoc (Part d), and `TaskExecutorLimits` record (Part e) all assume the post-S22 file layout. If either prerequisite has not landed, `BLOCKED: S22+S35 prerequisites not yet landed` and stop.


### From `dev/specs/0.16.5/plan.md` — "S38: Readability Pack"
<!-- source: dev/specs/0.16.5/plan.md#s38-readability-pack -->
<!-- extracted: e670c47 -->
> **Dependencies**: S22, S35
> **Risk**: Low — five small, scoped changes; each individually low-risk
> **Scope**: Bundle five low-cost, high-payoff readability wins into one ~4h story. (a) **`_logRun(run, msg)` helper + severity drop to `fine`** in `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart` — 12+ inline `_log.info("Workflow '${run.id}': $msg")` calls collapse to `_logRun(run, msg)`; per-step progression events drop from `info` → `fine` (terminal status, errors, approval events stay `info`). Also unifies the `${run.id}` vs `${definition.name}` vs `(${run.id})` prefix inconsistency. (b) **Typed `Task.worktree` read-only helper** in `packages/dartclaw_core/lib/src/task/task.dart` — add `({String? branch, String? path, DateTime? createdAt})? get worktree => …` that parses the `Map<String, dynamic>? worktreeJson` field. The map field stays for back-compat. (c) **Rename `WorkflowStep.type → taskType`** after S35 has introduced `WorkflowTaskType` on the existing `type` field — add `taskType` field; deprecate `type` with `@Deprecated('Use taskType')`; update public `dev/state/UBIQUITOUS_LANGUAGE.md` §"Overloaded Terms" to distinguish "step type" from "task type". (d) **Document the three dir conventions** — add a dartdoc comment block in the `dartclaw_core` barrel clarifying: `dataDir` = `~/.dartclaw/` (instance root), `workspaceDir` / `workspaceRoot` = user's active project working tree, `projectDir` = clone under `$dataDir/projects/<id>/`. Rename `TaskExecutor.workspaceDir` → `workspaceRoot`. (e) **`TaskExecutorLimits` record** — group `compactInstructions` / `identifierPreservation` / `identifierInstructions` / `maxMemoryBytes` / `budgetConfig` on `TaskExecutor.new` into a single record or class. Drops the ctor below S10's `≤12 params` threshold.
> **Acceptance Criteria**:
> - [ ] `_logRun` helper exists in `workflow_executor.dart`; all 12+ inline prefix calls migrated (must-be-TRUE)
> - [ ] Per-step progression log calls at `fine` severity; terminal / error / approval at `info` (must-be-TRUE)
> - [ ] `Task.worktree` typed getter exists; returns null when `worktreeJson` is null (must-be-TRUE)
> - [ ] `WorkflowStep.taskType` field exists; `type` deprecated with `@Deprecated('Use taskType')` (must-be-TRUE)
> - [ ] Glossary "Overloaded Terms" section distinguishes step type vs task type (must-be-TRUE)
> - [ ] Dir-naming conventions documented in `dartclaw_core` barrel dartdoc (must-be-TRUE)
> - [ ] `TaskExecutor.workspaceDir` renamed to `workspaceRoot`; all call sites updated
> - [ ] `TaskExecutorLimits` record (or class) exists; `TaskExecutor.new` uses it; ctor param count drops below 12 (must-be-TRUE)
> - [ ] `dart analyze` and `dart test` workspace-wide pass

### From `dev/specs/0.16.5/.technical-research.md` — Shared Decision #8 (S35 → S38 ordering)
<!-- source: dev/specs/0.16.5/.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> **8. S35 → S38 — Enum then field-rename ordering**
> - WHAT: S35 introduces `WorkflowTaskType` enum and types existing `WorkflowStep.type` field with it (field name unchanged); `fromJsonString(String)` factory throws `FormatException`; JSON wire format byte-compatible. S38 renames field `type` → `taskType`, deprecates old field via `@Deprecated('Use taskType')`.
> - PRODUCER: S35.
> - CONSUMER: S38.
> - WHY: Two-phase to avoid simultaneous rename+retype churn.

### From `dev/specs/0.16.5/.technical-research.md` — Binding PRD Constraints (rows applying to S38)
<!-- source: dev/specs/0.16.5/.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> | 1  | "JSONL control protocol, REST API payload shapes, SSE envelope formats unchanged." | Out of Scope / NFR Compatibility | S05, S15, S16, S17, S18, S22, S35 |
> | 2  | "No new dependencies in any package. Fitness functions use existing `test` + `analyzer` + `package_config`." | Constraint | All stories |
> | 55 | "Readability pack: `_logRun(run, msg)` helper; per-step progression `info` → `fine`; typed `Task.worktree` getter; `WorkflowStep.type` → `taskType` (deprecated); dir-naming conventions documented; `TaskExecutor.workspaceDir` → `workspaceRoot`; `TaskExecutorLimits` record drops ctor count below 12." | FR10 | S38 |
> | 71 | "Behavioural regressions post-decomposition: Zero — every existing test remains green." | NFR Reliability | S15, S16, S17, S18, S22, S33 |


## Deeper Context

- `dev/specs/0.16.5/plan.md#s35-stringly-typed-workflow-flags-enums` — S35 must land first: introduces `WorkflowTaskType` enum, types the existing `WorkflowStep.type` field with it, JSON wire-format unchanged. S38 renames the field afterwards.
- `dev/specs/0.16.5/fis/s16-task-executor-residual-cleanup.md` — S16 consumes `TaskExecutorLimits`. S16's FIS pins the exact field set (`compactInstructions`, `identifierPreservation` default `'strict'`, `identifierInstructions`, `maxMemoryBytes`, `budgetConfig`) — S38 must not deviate so S16 imports the type cleanly. S16 also retains `dataDir` and `workspaceDir` as one-off scalars — the `workspaceDir → workspaceRoot` rename in this story flows through to S16's ctor signature naturally.
- `dev/state/UBIQUITOUS_LANGUAGE.md#overloaded-terms` — table where the new step-type-vs-task-type row is added.
- `packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart` — post-S22 location of `WorkflowStep.type`; locate by symbol because plan-brief line refs may be stale.
- 0.16.5 reality vs plan brief: the `workflow_executor.dart` log-call line numbers cited in the plan brief (577, 588, 616, …) are stale — actual `_log.info("Workflow '${run.id}': $msg")` sites live around lines 214, 224, 249, 342, 353, 445, 526, 553, 617, 627, 654 (plus terminal/severe/cancellation sites at 143, 163, 312, 646, 871). Executor must locate by pattern, not by line number.


## Success Criteria (Must Be TRUE)

### Part (a) — `_logRun` helper + severity drop

- [ ] Private `void _logRun(WorkflowRun run, String msg, {Level level = Level.FINE})` helper exists in `workflow_executor.dart` and emits `Workflow '${run.id}': $msg` at the chosen `Level`
- [ ] All inline `_log.info("Workflow '${run.id}': $msg")` sites in `workflow_executor.dart` (≥10) migrated to `_logRun(run, msg)` (defaulting to `Level.FINE`)
- [ ] Per-step progression events log at `Level.FINE`; terminal status (`completed successfully`, `cancelled before/after node/step …`), errors, and approval-flow events remain at `Level.INFO` (or higher) by passing `level: Level.INFO` explicitly to `_logRun` or by retaining the existing `_log.info(...)` direct call
- [ ] Prefix inconsistency unified: any surviving call sites that previously used `${definition.name} (${run.id})` or `(${run.id})` prefixes either (i) route through `_logRun` (canonical `Workflow '${run.id}': ...` prefix) or (ii) preserve the variant prefix only where the message intentionally references `definition.name` for human-facing terminal markers (e.g. the line-871 success log)

### Part (b) — Typed `Task.worktree` getter

- [ ] `Task` in `packages/dartclaw_core/lib/src/task/task.dart` exposes a public read-only getter with the exact shape `({String? branch, String? path, DateTime? createdAt})? get worktree`
- [ ] Getter returns `null` when `worktreeJson` is `null`; otherwise returns a record built from `worktreeJson['branch']`, `worktreeJson['path']`, and `worktreeJson['createdAt']` parsed as `DateTime?` (`DateTime.tryParse(...)`); unparseable / wrong-typed values resolve to `null` per-field — never throw
- [ ] The `worktreeJson` map field is **untouched** (declaration, ctor parameter, `copyWith`, `toJson`, `fromJson`); existing readers using `task.worktreeJson?['branch']` continue to compile and behave identically

### Part (c) — `WorkflowStep.type` → `taskType` rename

- [ ] **Pre-flight**: S22 and S35 have landed — `WorkflowStep` lives in `dartclaw_workflow`, `WorkflowStep.type` is typed `WorkflowTaskType` (not `String`), and `WorkflowTaskType.fromJsonString` exists. If either prerequisite has not landed, this story stops with `BLOCKED: S22/S35 dependency not met`
- [ ] `WorkflowStep` in `packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart` exposes a new `taskType` field (typed `WorkflowTaskType`) and the old `type` field carries `@Deprecated('Use taskType')` — both fields have identical values populated from a single ctor source of truth (canonical: ctor accepts `taskType`, defaults to `WorkflowTaskType.agent`; `type` is a `@Deprecated` getter that returns `taskType` so JSON round-trip remains driven by one field)
- [ ] `toJson()` / `fromJson()` continue to emit and consume the `'type'` JSON key (no wire-format change — constraint #1)
- [ ] `dev/state/UBIQUITOUS_LANGUAGE.md` "Overloaded Terms" table gains a row distinguishing "Step type" (kind: `agent` / `bash` / `approval` / `foreach` / `loop` — the workflow-step dispatch kind) from "Task type" (the broader coding/reading/analysis vocabulary used outside workflow definitions)
- [ ] All in-tree call sites that read `step.type` for kind-dispatch (the ~14 sites under `packages/dartclaw_workflow/lib/src/workflow/`) are migrated to `step.taskType` — call sites under `test/` may stay on the deprecated `type` field (covered by the deprecation; tests are intentionally a deprecation early-warning surface)
- [ ] CHANGELOG entry under the FR10 banner notes the deprecation and points readers to `taskType`

### Part (d) — Dir-naming conventions doc + `workspaceRoot` rename

- [ ] `packages/dartclaw_core/lib/dartclaw_core.dart` library-level dartdoc gains a "Directory conventions" block defining `dataDir` (= `~/.dartclaw/`, instance root), `workspaceDir` / `workspaceRoot` (= user's active project working tree), and `projectDir` (= clone under `$dataDir/projects/<id>/`)
- [ ] `TaskExecutor` in `packages/dartclaw_server/lib/src/task/task_executor.dart` renames the named ctor parameter `workspaceDir` → `workspaceRoot` and the private field `_workspaceDir` → `_workspaceRoot`; all in-file references migrated (currently ~5 sites)
- [ ] All `TaskExecutor(...)` ctor call sites pass `workspaceRoot:` instead of `workspaceDir:` — covers the 2 production wiring files in `apps/dartclaw_cli/` plus the 4 test files under `packages/dartclaw_server/test/task/` that construct `TaskExecutor` directly
- [ ] **Out-of-scope reaffirmed**: the `workspaceDir` parameter on `WhatsAppChannel`, on `extractMediaDirectives`, on `AgentExecution`, and elsewhere is **not** renamed — only `TaskExecutor`'s parameter is in scope. The barrel dartdoc explicitly notes "`workspaceRoot` is the canonical name on new code; some legacy parameters retain the historical `workspaceDir` spelling and will be addressed separately."

### Part (e) — `TaskExecutorLimits` record

- [ ] `class TaskExecutorLimits` (immutable, named-ctor with `required` / defaulted fields) declared at `packages/dartclaw_server/lib/src/task/task_executor_limits.dart` with the **exact** five fields specified by the plan and S16's FIS contract:
  - `String? compactInstructions`
  - `String identifierPreservation` (default `'strict'` — string for now; S35's `IdentifierPreservationMode` enum migration is a separate concern)
  - `String? identifierInstructions`
  - `int? maxMemoryBytes`
  - `TaskBudgetConfig? budgetConfig`
- [ ] `TaskExecutor.new` accepts a `TaskExecutorLimits limits = const TaskExecutorLimits()` parameter (or a single `required` if construction sites all opt in); the five named scalars are removed from the ctor surface
- [ ] `TaskExecutor`'s public ctor parameter count, counted manually against the rewritten ctor declaration, is **< 12** (target met independent of S16; S16 then layers its dep-group structs on top)
- [ ] All `TaskExecutor(...)` construction sites updated to pass `limits: TaskExecutorLimits(...)` — covers the 2 production wiring files plus 4 test files. If a call site passed none of the five scalars, the `const TaskExecutorLimits()` default carries through with no edit needed there
- [ ] **Coordination with S16**: `TaskExecutorLimits` is exported only via `task_executor.dart`'s import surface (not added to the `dartclaw_server.dart` barrel). The field set, defaults, and class shape match S16's pinned contract exactly so S16 imports the type without reshape

### Health Metrics (Must NOT Regress)

- [ ] `dart format --set-exit-if-changed packages apps` clean
- [ ] `dart analyze --fatal-warnings --fatal-infos` workspace-wide: 0 issues (deprecation warnings on `WorkflowStep.type` — if any consumer in `lib/` still reads it after part (c) — are deliberate and acceptable; resolve by migrating the consumer)
- [ ] `dart test` workspace-wide green; SSE/REST/JSONL payload shapes unchanged (constraint #1)
- [ ] No new package dependencies (constraint #2)
- [ ] L1 fitness suite green; in particular `constructor_param_count_test.dart` (S10) passes for `TaskExecutor` either via a temporary allowlist entry that S16 removes, or unconditionally if S38 lands close enough to S16 to satisfy the ceiling on its own
- [ ] `Task.worktreeJson` continues to round-trip identically through `toJson`/`fromJson`; existing `task.worktreeJson?['branch']` readers are byte-stable


## Scenarios

### Per-step progression noise disappears at `info` level (happy path)

- **Given** `dart` logging is configured to surface `Level.INFO` and above (the production default), and a workflow run executes a 5-step pipeline to completion
- **When** the run progresses through each step (assignments, gate evaluations, foreach iterations, parallel-group fan-out)
- **Then** the per-step progression messages do **not** appear in `Level.INFO` output; the run's start banner, terminal `completed successfully` line, and any error / cancellation / approval-event lines **do** appear at `Level.INFO`. Re-running the same scenario with logging at `Level.FINE` surfaces the progression messages with the unified `Workflow '${run.id}': ...` prefix

### Terminal errors and approval events remain visible (regression guard)

- **Given** a workflow run that triggers an approval timeout (existing path at `workflow_executor.dart:819`) and a workflow run whose step throws (existing severe / warning sites)
- **When** each event fires and the operator's logger is set at `Level.INFO`
- **Then** the approval-timeout `_log.warning(...)` and the terminal error / cancellation log lines surface at their current severity (`warning` / `info`); none of them is downgraded to `fine` by part (a)

### Existing consumer reading `Task.worktreeJson['branch']` continues to work (back-compat)

- **Given** a `Task` instance whose `worktreeJson` is `{'branch': 'feat/x', 'path': '/tmp/wt', 'createdAt': '2026-04-30T10:00:00Z'}`
- **When** legacy code reads `task.worktreeJson?['branch']` and new code reads `task.worktree?.branch`
- **Then** both return `'feat/x'`; new code reading `task.worktree?.createdAt` returns the parsed `DateTime`; reading from a `Task` whose `worktreeJson` is `null` returns `null` from both surfaces

### `WorkflowStep` JSON round-trip is byte-identical post-rename

- **Given** an existing resolved-workflow YAML / JSON fixture whose step has `"type": "bash"`
- **When** `WorkflowStep.fromJson(...)` parses it and `toJson()` re-emits it
- **Then** the round-tripped JSON is byte-identical to the input (the `"type"` key is preserved); a Dart consumer reading `step.taskType` sees `WorkflowTaskType.bash`; a consumer reading `step.type` sees the same value but `dart analyze` emits a `deprecated_member_use` info; existing in-tree call sites under `packages/dartclaw_workflow/lib/src/workflow/` have already been migrated and emit zero deprecation infos

### `TaskExecutor` ctor surface tightens; `workspaceRoot` shows up at the call site

- **Given** the `TaskExecutor` ctor is rewritten to consume `TaskExecutorLimits` and to expose `workspaceRoot:` instead of `workspaceDir:`
- **When** a developer reads the call site at `apps/dartclaw_cli/lib/src/commands/wiring/task_wiring.dart`
- **Then** the call passes `limits: TaskExecutorLimits(compactInstructions: …, identifierPreservation: 'strict', identifierInstructions: …, maxMemoryBytes: …, budgetConfig: …)` and `workspaceRoot: <path>`; the manual count of ctor parameters at the `TaskExecutor` declaration is **< 12**; `dart analyze` reports zero unused / unknown-named-parameter errors

### Glossary distinguishes step type from task type (boundary)

- **Given** a contributor wonders whether `WorkflowStep.taskType` shares a vocabulary with the broader DartClaw "task type" classification
- **When** they read `dev/state/UBIQUITOUS_LANGUAGE.md` "Overloaded Terms"
- **Then** a row labelled "Type" (or equivalent) records that "Step type" is the workflow dispatch kind (`agent` / `bash` / `approval` / `foreach` / `loop`) while "Task type" is the broader vocabulary; the row references `WorkflowTaskType` and the canonical task-type enum it should not be confused with


## Scope & Boundaries

### In Scope

- `_logRun` helper + per-step → `fine` severity drop in `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart`
- Typed `Task.worktree` getter in `packages/dartclaw_core/lib/src/task/task.dart` (additive; map field untouched)
- `WorkflowStep.taskType` field + `@Deprecated('Use taskType')` on the existing `type` field in `packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart`; in-tree call-site migration under `packages/dartclaw_workflow/lib/src/workflow/`
- `dev/state/UBIQUITOUS_LANGUAGE.md` "Overloaded Terms" row addition
- `packages/dartclaw_core/lib/dartclaw_core.dart` library-level dartdoc block on directory conventions
- `TaskExecutor.workspaceDir` → `workspaceRoot` ctor-param + private-field rename (and the corresponding production + test call-site updates)
- `TaskExecutorLimits` record / class declared at `packages/dartclaw_server/lib/src/task/task_executor_limits.dart` and consumed by `TaskExecutor.new`; the five existing scalar params removed from the ctor surface
- `dart format`, `dart analyze`, `dart test` workspace-wide verification
- CHANGELOG entry under FR10 noting the `taskType` deprecation (one line)

### What We're NOT Doing

- **Not removing** `Task.worktreeJson` map field — the typed getter is purely additive; the map field is the persistence shape and is preserved for back-compat (per plan)
- **Not introducing** a dependency-injection framework, service-locator, or new package dependency (constraint #2)
- **Not rewriting** workflow logging structure — `_logRun` is a thin helper; the underlying `package:logging` `Logger` instance and emitted message format are unchanged in shape (only severity and prefix change at migrated sites)
- **Not migrating** non-`TaskExecutor` `workspaceDir` parameters — `WhatsAppChannel`, `extractMediaDirectives`, `AgentExecution`, and other modules retain their existing parameter spelling. The barrel dartdoc establishes the canonical name for new code; broader migration is deferred
- **Not touching S35's enum work** — S35 introduces `WorkflowTaskType` and types the existing `type` field with it; this story strictly does the field rename + deprecation. If S35 has not landed, this story is `BLOCKED:` per Required Context above
- **Not enum-ifying** `IdentifierPreservationMode` — that's S35 part (d). `TaskExecutorLimits.identifierPreservation` stays `String` in this story; S35 (or follow-up) retypes it without reshaping the field
- **Not reshaping** `TaskExecutorLimits` — the field set is pinned by S16's contract. Adding fields or renaming would force a reshape in S16
- **Not adding** the `TaskExecutorLimits` type to the `dartclaw_server.dart` public barrel — kept as a `lib/src/task/`-internal type
- **Not changing** SSE / REST / JSONL wire formats (constraint #1) — every public payload shape stays bit-identical
- **Not updating** test-only consumers of the deprecated `WorkflowStep.type` field — tests are the intended deprecation early-warning surface and may continue to read the deprecated field (a brief CHANGELOG note is enough; a follow-up sweep can migrate them)

### Agent Decision Authority

- **Autonomous**: which severity-drop sites get an explicit `level: Level.INFO` override vs which retain a direct `_log.info(...)` call (both are correct; choose for minimum diff); whether `Task.worktree` is a getter expression-body or a one-line cached field (cached field rejected — record holds nothing the map doesn't); the exact wording of the "Overloaded Terms" glossary row; whether the `_logRun` helper accepts an optional `level` named parameter or two helpers (`_logRun` for fine, `_logRunInfo` for info) — prefer the single helper with `level` default `FINE`
- **Escalate**: any decision that requires touching `WorkflowStep` JSON wire-format (the `'type'` key must be preserved); any need to remove `worktreeJson`; any need to add a new package dependency; any reshape of `TaskExecutorLimits` field names / defaults beyond what S16's FIS pins; any decision to migrate non-`TaskExecutor` `workspaceDir` instances; any plan to land before S35


## Architecture Decision

**We will**: Land all five readability items in one cohesive PR/commit on the `feat/0.16.5` branch. Each item is independently low-risk and the bundle keeps the FR10 CHANGELOG entry coherent. Coordinate `TaskExecutorLimits` shape with S16 — S38 owns the type definition; S16 consumes it. Coordinate `WorkflowStep.type → taskType` with S35 — S35 introduces the `WorkflowTaskType` enum on the existing `type` field; S38 then renames the field. The map-field `Task.worktreeJson` stays for back-compat — the typed getter is purely additive. The `workspaceDir → workspaceRoot` rename is scoped to `TaskExecutor` only; broader migration is deferred. -- (over a sequence of five separate stories, which would dilute the FR10 CHANGELOG entry into five lines and force five rebases against `feat/0.16.5`).

**Logging-severity safety note**: dropping per-step events from `info` → `fine` is operationally safe — log-watching tools that consume DartClaw stdout should be configured at `Level.INFO`; per-step events were already too noisy at `info` (the original review finding). Operators relying on per-step lines for debugging can reconfigure their handler to `Level.FINE` or use the existing `--verbose` flag if one exists; otherwise enable `Logger.root.level = Level.FINE` in their config.

**`@Deprecated` mechanics**: the deprecated `type` field becomes a `@Deprecated('Use taskType') WorkflowTaskType get type => taskType;` getter rather than a stored field, so there's exactly one source of truth (`taskType`) and JSON round-trip is unambiguous. Default arg on `WorkflowStep.new` shifts from `type = 'agent'` (old) → `taskType = WorkflowTaskType.agent` (new). `fromJson` reads `'type'` key into `taskType` via `WorkflowTaskType.fromJsonString` (S35-provided). `toJson` emits `'type'` key from `taskType.name` (or `taskType.toJson()`).


## Technical Overview

### Data Models

- New: `TaskExecutorLimits` immutable class (5 fields) at `packages/dartclaw_server/lib/src/task/task_executor_limits.dart`. No JSON serialization, no persistence, no public-barrel surface.
- Modified: `WorkflowStep` gains `taskType: WorkflowTaskType` field; `type` becomes a `@Deprecated` getter aliasing `taskType`. JSON wire-format unchanged.
- Modified: `Task` gains `worktree` typed-record getter parsing `worktreeJson`. Map field, ctor signature, `copyWith`, `toJson`, `fromJson` unchanged.

### Integration Points

- **`packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart`** — Part (a). Add `_logRun` helper near top of class; replace ≥10 inline log sites with helper calls; classify each remaining `_log.info(...)` site as terminal/error/approval (stay `info`) or progression (drop to `fine` via `_logRun` default).
- **`packages/dartclaw_core/lib/src/task/task.dart`** — Part (b). Add the typed getter; no other edits.
- **`packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart`** — Part (c). Add `taskType` field, deprecate `type`, update ctor + `toJson` + `fromJson`.
- **`packages/dartclaw_workflow/lib/src/workflow/`** — Part (c). Migrate ~14 in-tree `step.type` reads to `step.taskType` (`step_config_policy.dart`, `public_step_dispatcher_helpers.dart`, `step_dispatcher.dart`, `bash_step_runner.dart`, `workflow_task_factory.dart`, `validation/workflow_step_type_rules.dart`).
- **`dev/state/UBIQUITOUS_LANGUAGE.md`** — Part (c). Add "Step type vs Task type" row in Overloaded Terms; date the changelog at the bottom of the file.
- **`packages/dartclaw_core/lib/dartclaw_core.dart`** — Part (d). Add directory-conventions block to library dartdoc.
- **`packages/dartclaw_server/lib/src/task/task_executor.dart`** — Parts (d) + (e). Rename `workspaceDir` → `workspaceRoot` (ctor param, `_workspaceDir` field, ~5 in-file references); add `TaskExecutorLimits limits = const TaskExecutorLimits()` ctor param; remove the five scalar params (`compactInstructions`, `identifierPreservation`, `identifierInstructions`, `maxMemoryBytes`, `budgetConfig`); destructure `limits.<field>` into the existing `_xxx` private fields in the initializer list (preserves the rest of the class verbatim).
- **`packages/dartclaw_server/lib/src/task/task_executor_limits.dart`** — Part (e). New file declaring the immutable class with the pinned 5 fields.
- **`apps/dartclaw_cli/lib/src/commands/wiring/task_wiring.dart`** + **`apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart`** — Parts (d) + (e). Update `TaskExecutor(...)` calls: pass `workspaceRoot:` and `limits: TaskExecutorLimits(...)`.
- **`packages/dartclaw_server/test/task/{task_executor_test,task_autonomy_test,task_executor_provider_test,budget_enforcement_test,retry_enforcement_test}.dart`** — Parts (d) + (e). Mechanical ctor-call-site updates only.
- **`CHANGELOG.md`** — final task. One-line entry under FR10 / 0.16.5 banner.

### Logger Severity Mapping (Part a)

| Site (current) | Stay `info` (terminal/error/approval) | Drop to `fine` (per-step progression) |
|---|---|---|
| `:143` start banner | yes | — |
| `:163` cancelled before node | yes | — |
| `:214,224,249,342,353,445,526,553,617,627,654` `_log.info("Workflow '${run.id}': $msg")` | classify per-call from inline context | most fall here — progression |
| `:312` multi-line `_log.info(...)` | classify per-call | likely progression |
| `:646` cancelled after step | yes | — |
| `:819` `_log.warning('Failed to cancel task...')` | yes (warning, untouched) | — |
| `:871` terminal "completed successfully" | yes | — |

Executor classifies each call by reading 3-5 lines of surrounding context: messages of the shape "step X started / completed / advancing", "iteration N of M", "fan-out spawning K parallel tasks" → `fine`; messages mentioning approval, error, terminal status, cancellation → `info`. When ambiguous, default to `fine` (the safer noise-reduction choice; can be re-promoted in a follow-up if an operator flags missing visibility).


## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart                       | Part (a) — log-call sites + helper insertion point
file   | packages/dartclaw_core/lib/src/task/task.dart                                            | Part (b) — typed getter target; existing worktreeJson at :37
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart                      | Part (c) — WorkflowStep.type; ctor/fromJson/toJson locations should be found by symbol after S22
file   | packages/dartclaw_workflow/lib/src/workflow/step_config_policy.dart                      | Part (c) — call sites at :55, :81 reading step.type
file   | packages/dartclaw_workflow/lib/src/workflow/step_dispatcher.dart                         | Part (c) — call sites at :42, :46
file   | packages/dartclaw_workflow/lib/src/workflow/public_step_dispatcher_helpers.dart          | Part (c) — call site at :25
file   | packages/dartclaw_workflow/lib/src/workflow/bash_step_runner.dart                        | Part (c) — assert at :54
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_task_factory.dart                   | Part (c) — call site at :263 (`stepType: step.type`)
file   | packages/dartclaw_workflow/lib/src/workflow/validation/workflow_step_type_rules.dart     | Part (c) — call sites at :101, :108, :118, :132, :144 (validation; deprecation-warning-friendly migration)
file   | dev/state/UBIQUITOUS_LANGUAGE.md                                                         | Part (c) — Overloaded Terms table at :143-156; Changelog at :158-160
file   | packages/dartclaw_core/lib/dartclaw_core.dart                                            | Part (d) — library dartdoc at :1-13
file   | packages/dartclaw_server/lib/src/task/task_executor.dart                                 | Parts (d) + (e) — ctor at :40-94; field decls at :96-126; workspaceDir refs at :58, :86, :117, :604, :607, :614, :616
file   | apps/dartclaw_cli/lib/src/commands/wiring/task_wiring.dart                               | Parts (d) + (e) — TaskExecutor construction site
file   | apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart                     | Parts (d) + (e) — TaskExecutor construction site
file   | packages/dartclaw_server/test/task/task_executor_test.dart                               | Mechanical ctor update (largest test consumer)
file   | dev/specs/0.16.5/fis/s16-task-executor-residual-cleanup.md                               | Pinned `TaskExecutorLimits` field set + S38↔S16 coordination
file   | dev/specs/0.16.5/plan.md#s35-stringly-typed-workflow-flags-enums                         | S35 enum contract that this story consumes
```


## Constraints & Gotchas

- **S22 + S35 dependency strict**: `WorkflowDefinition` must already live under `packages/dartclaw_workflow/lib/src/workflow/`, and `WorkflowTaskType` enum + `WorkflowTaskType.fromJsonString` must exist before part (c) starts. -- Verify: `test -f packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart` and `grep "enum WorkflowTaskType\|class WorkflowTaskType" packages/dartclaw_workflow/lib/src/workflow/` returns ≥ 1 line. If not, STOP with `BLOCKED: S22/S35 dependency not met`.
- **S16 contract on `TaskExecutorLimits` shape**: S16 may have already declared the type with the exact field set if it landed first. -- Workaround: detect with `rg "class TaskExecutorLimits" packages/dartclaw_server/lib/src/task/`. If declared, this story takes ownership (move file or keep in place; coordinate with S16's executor) and proceeds to consume it from `TaskExecutor.new`. If not declared, this story creates it. Either way: do **not** invent additional fields beyond the 5 the brief specifies.
- **Plan-brief line numbers are stale**: `workflow_definition.dart:471`, `workflow_executor.dart:577,588,…`, `task_executor.dart:35-62` cited in the plan brief may not match post-S22 line numbers. -- Workaround: locate by symbol/pattern. `WorkflowStep.type` is in `packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart`; `TaskExecutor` ctor is in `task_executor.dart`; log sites are listed in the severity-mapping table above.
- **Critical — JSON wire compat**: `WorkflowStep` `toJson()` / `fromJson()` MUST keep using the `'type'` JSON key (constraint #1). -- Must handle by: `toJson` writes `'type': taskType.name` (or `taskType.toJson()` if S35 provides one); `fromJson` reads `json['type']` into `taskType` via `WorkflowTaskType.fromJsonString(...)`; never emit `'taskType'` to JSON.
- **Critical — `Task.worktree` parsing safety**: `worktreeJson['createdAt']` may be a stored ISO string, a Dart `DateTime.toString()` result, or absent. -- Must handle by: `DateTime.tryParse(map['createdAt'] as String?)` only when the value is a `String`; return `null` on parse failure; never throw from the getter.
- **Critical — `_log.info` at `:312` is multi-line**: don't break the message-construction expression when migrating. -- Must handle by: read the full multi-line call before substituting `_logRun`; if the message uses string interpolation that doesn't naturally collapse to `_logRun(run, msg)`, leave the call as-is (still classify severity per the table, but a direct `_log.info` / `_log.fine` call is acceptable when `_logRun` doesn't fit cleanly).
- **Avoid**: pushing `TaskExecutorLimits` into the `dartclaw_server.dart` barrel. -- Instead: keep it as `lib/src/task/`-internal; the only public surface change is `TaskExecutor.new`'s parameter list, constructed from 2 production wiring files + 4 tests.
- **Avoid**: renaming `workspaceDir` outside `TaskExecutor`. -- Instead: leave `WhatsAppChannel.workspaceDir`, `AgentExecution.workspaceDir`, `extractMediaDirectives({required workspaceDir})` etc. on the historical spelling; document the canonical name in the barrel dartdoc and let the next touch on each module migrate naturally.
- **Logging severity reachability**: ensure the helper signature accepts `Level` from `package:logging` correctly — `package:logging`'s `Logger.log(Level, String)` is the underlying call, not `Logger.info` etc. -- Workaround: `_logRun(WorkflowRun run, String msg, {Level level = Level.FINE}) { _log.log(level, "Workflow '${run.id}': $msg"); }`. The existing `_log` Logger instance is reused.
- **Test-file `step.type` reads stay deprecated**: tests at `serialize_remaining_idempotency_test.dart:327`, `built_in_workflow_contracts_test.dart:96`, `serialize_remaining_escalation_test.dart:252,264`, `workflow_definition_parser_test.dart:2006,2022,2171` continue to read `step.type` and emit `deprecated_member_use` infos. -- Resolution: tests are the deliberate deprecation early-warning surface; record this in Implementation Observations rather than migrating en masse. The CHANGELOG entry signposts the deprecation; a follow-up housekeeping sweep can migrate the test sites.


## Implementation Plan

> Vertical-slice ordering: parts (b) and (d-doc) first (cheapest, isolated), then (a) [logging], then (c) [taskType rename, requires S35 landed], then (d-rename) + (e) [TaskExecutor changes — atomic], then verification. Items are mostly independent; this order minimises rebase friction.

### Implementation Tasks

- [ ] **TI01** Verify pre-flight dependencies.
  - Confirm S22 and S35 have landed: `test -f packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart`; `rg "enum WorkflowTaskType|class WorkflowTaskType" packages/dartclaw_workflow/lib/src/workflow/` returns ≥1 line; `rg "WorkflowTaskType.fromJsonString" packages/dartclaw_workflow/lib/src/workflow/` returns ≥1 line. Confirm `TaskExecutorLimits` does **not** already exist (S16 has not landed first): `rg "class TaskExecutorLimits" packages/dartclaw_server/lib/src/task/` returns 0 lines. Record findings under Implementation Observations.
  - **Verify**: all checks return expected results. If S22/S35 have not landed, STOP with `BLOCKED: S22/S35 dependency not met`. If `TaskExecutorLimits` already exists, switch to "import-only" mode for part (e) and record under Implementation Observations.

- [ ] **TI02** Part (b) — add typed `Task.worktree` getter.
  - Open `packages/dartclaw_core/lib/src/task/task.dart`. Add a public read-only getter `({String? branch, String? path, DateTime? createdAt})? get worktree` immediately after the `worktreeJson` field declaration (around `:37`). Return `null` if `worktreeJson == null`; otherwise return a record `(branch: map['branch'] as String?, path: map['path'] as String?, createdAt: DateTime.tryParse(map['createdAt'] as String? ?? ''))`. Per-field cast must be defensive (`as String?` not `as String`).
  - **Verify**: `dart analyze packages/dartclaw_core` = 0 issues; `dart test packages/dartclaw_core/test/task/` passes; a smoke unit assertion confirms `Task(worktreeJson: {'branch':'b','path':'p','createdAt':'2026-04-30T10:00:00Z'}).worktree?.branch == 'b'` and `Task(worktreeJson: null).worktree == null`.

- [ ] **TI03** Part (d-doc) — directory-conventions dartdoc block in `dartclaw_core` barrel.
  - Open `packages/dartclaw_core/lib/dartclaw_core.dart`. Augment the existing library-level dartdoc (`:1-13`) with a "## Directory conventions" block: `dataDir` (`~/.dartclaw/`, instance root), `workspaceDir` / `workspaceRoot` (user's active project working tree — `workspaceRoot` is canonical on new code), `projectDir` (`$dataDir/projects/<id>/`, per-project clone). Include a one-line note that some legacy parameters retain the historical `workspaceDir` spelling and will be addressed separately.
  - **Verify**: `dart analyze packages/dartclaw_core` = 0 issues; the dartdoc renders as a single library-level block with no syntax errors; `rg "Directory conventions" packages/dartclaw_core/lib/dartclaw_core.dart` returns 1 line.

- [ ] **TI04** Part (a) — declare `_logRun` helper in `WorkflowExecutor`.
  - Open `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart`. Add `void _logRun(WorkflowRun run, String msg, {Level level = Level.FINE}) { _log.log(level, "Workflow '${run.id}': $msg"); }` near the top of the private-method block of `WorkflowExecutor`. Add `import 'package:logging/logging.dart' show Level;` if not already imported (check existing import; `package:logging` is already a transitive dep via `_log`).
  - **Verify**: `dart analyze packages/dartclaw_workflow` = 0 issues at the helper site; `rg "_logRun\(" packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart` returns ≥1 line (the declaration).

- [ ] **TI05** Part (a) — migrate inline `_log.info(...)` sites to `_logRun` and classify severity.
  - Walk the log-call sites enumerated in the severity-mapping table (lines 143, 163, 214, 224, 249, 312, 342, 353, 445, 526, 553, 617, 627, 646, 654, 871). For each site of the canonical shape `_log.info("Workflow '${run.id}': $msg")` where `$msg` is per-step progression context, replace with `_logRun(run, msg)`. For terminal / cancellation / approval / error sites, either retain `_log.info(...)` direct or use `_logRun(run, msg, level: Level.INFO)`. Preserve the variant-prefix line at `:871` (uses `definition.name` — terminal banner, intentional).
  - **Verify**: `rg "_log\.info\(\"Workflow '\\\$\{run\.id\}': " packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart` returns 0 lines (all migrated); `dart test packages/dartclaw_workflow/test/workflow/` passes (workflow logic regression check).

- [ ] **TI06** Part (c) — add `WorkflowStep.taskType` field; deprecate `type`.
  - Open `packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart` and locate `WorkflowStep.type`. Replace the field with: `final WorkflowTaskType taskType;` (typed via S35's enum). Add a deprecated getter: `@Deprecated('Use taskType') WorkflowTaskType get type => taskType;`. Update ctor: replace `this.type = WorkflowTaskType.agent` with `this.taskType = WorkflowTaskType.agent`. Update `toJson`: write the same `'type'` JSON key using `taskType.toJson()` (or `.name` if S35 uses that). Update `fromJson`: read `json['type']` into `taskType` via `WorkflowTaskType.fromJsonString(...)`.
  - **Verify**: `dart analyze packages/dartclaw_workflow` reports zero issues; `dart test packages/dartclaw_workflow/test/workflow/` passes — JSON round-trip is byte-identical for the existing fixtures; a manual round-trip on `{'type': 'bash'}` produces `{'type': 'bash'}` with `step.taskType == WorkflowTaskType.bash`.

- [ ] **TI07** Part (c) — migrate in-tree call sites under `packages/dartclaw_workflow/lib/src/workflow/` from `step.type` to `step.taskType`.
  - Sites: `step_config_policy.dart:55,81`; `step_dispatcher.dart:42,46`; `public_step_dispatcher_helpers.dart:25`; `bash_step_runner.dart:54`; `workflow_task_factory.dart:263`; `validation/workflow_step_type_rules.dart:101,102,108,118,132,144`. Each comparison `step.type == 'agent'` becomes `step.taskType == WorkflowTaskType.agent`, etc. The `removedAgentStepMarker` at `:102` and the YAML-input string-comparison branches stay on string semantics where they're checking arbitrary user input — only call sites that compare against a known-canonical kind (agent / bash / approval / foreach / loop) get migrated to enum.
  - **Verify**: `dart analyze packages/dartclaw_workflow --fatal-warnings --fatal-infos` reports zero `deprecated_member_use` infos for `step.type` from `lib/`; `dart test packages/dartclaw_workflow/test/workflow/` passes; test-file `step.type` reads remain (intentional — record under Implementation Observations).

- [ ] **TI08** Part (c) — update `dev/state/UBIQUITOUS_LANGUAGE.md` "Overloaded Terms".
  - Add a row to the table at `:143-156`: `| Type | Workflow steps | Step type — workflow dispatch kind: `agent`, `bash`, `approval`, `foreach`, `loop` (see `WorkflowTaskType`) | DartClaw runtime | Task type — broader vocabulary for queued tasks (coding, reading, analysis, …) used outside workflow definitions |`. Append a new line to the Changelog at `:158-160` dating today's update (run `date '+%Y-%m-%d'` first; Implementation Observations record date used).
  - **Verify**: `rg "Step type" dev/state/UBIQUITOUS_LANGUAGE.md` returns ≥1 line in the Overloaded Terms table; the changelog entry mentions S38.

- [ ] **TI09** Part (e) — author `TaskExecutorLimits` immutable class.
  - New file `packages/dartclaw_server/lib/src/task/task_executor_limits.dart`. Single immutable class: `class TaskExecutorLimits { const TaskExecutorLimits({this.compactInstructions, this.identifierPreservation = 'strict', this.identifierInstructions, this.maxMemoryBytes, this.budgetConfig}); final String? compactInstructions; final String identifierPreservation; final String? identifierInstructions; final int? maxMemoryBytes; final TaskBudgetConfig? budgetConfig; }`. Brief class-level dartdoc only (internal type). Import `TaskBudgetConfig` from its existing location.
  - **Verify**: `dart analyze packages/dartclaw_server` reports zero issues for the new file; `rg "class TaskExecutorLimits" packages/dartclaw_server/lib/src/task/task_executor_limits.dart` returns 1 line.

- [ ] **TI10** Parts (d) + (e) — rewrite `TaskExecutor.new`: rename `workspaceDir` → `workspaceRoot`, accept `TaskExecutorLimits limits`, drop the 5 scalar params.
  - Open `packages/dartclaw_server/lib/src/task/task_executor.dart:40-94`. Rename ctor param `workspaceDir` → `workspaceRoot`; rename private field `_workspaceDir` → `_workspaceRoot`; update the 5 in-file references at `:58, :86, :117, :604, :607, :614, :616`. Add `TaskExecutorLimits limits = const TaskExecutorLimits()` ctor param. Remove the 5 scalar params (`maxMemoryBytes`, `compactInstructions`, `identifierPreservation`, `identifierInstructions`, `budgetConfig`). In the initializer list, destructure `limits.compactInstructions` etc. into the existing `_compactInstructions` etc. private fields verbatim. Import `task_executor_limits.dart` via a relative `import './task_executor_limits.dart';` (or rely on the `part of` if applicable; check existing imports).
  - **Verify**: manual count of ctor parameters ≤ 12 (helps confirm; document the exact count under Implementation Observations); `dart analyze packages/dartclaw_server` reports only call-site errors at the wiring + test files (TI11 fixes); private `_xxx` field declarations are unchanged in shape; the only field rename is `_workspaceDir → _workspaceRoot`.

- [ ] **TI11** Update `TaskExecutor` construction sites at the 2 production wiring files + 5 test files.
  - At `apps/dartclaw_cli/lib/src/commands/wiring/task_wiring.dart` and `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart`: replace `workspaceDir:` with `workspaceRoot:`; replace the 5 scalar `maxMemoryBytes:` / `compactInstructions:` / `identifierPreservation:` / `identifierInstructions:` / `budgetConfig:` args with a single `limits: TaskExecutorLimits(maxMemoryBytes: …, …)` arg. At test files (`packages/dartclaw_server/test/task/{task_executor_test,task_autonomy_test,task_executor_provider_test,budget_enforcement_test,retry_enforcement_test}.dart`): same mechanical update. Do **not** edit setUp/tearDown, expected outputs, assertions, or skip flags. If a test passes none of the 5 scalars, the `const TaskExecutorLimits()` default carries through with no edit needed.
  - **Verify**: `dart analyze` workspace-wide = 0 issues; `dart test packages/dartclaw_server/test/task/` passes; `git diff --stat packages/dartclaw_server/test/task/` shows only ctor-call-site diffs (no `expect(...)` lines changed; no `skip:` added).

- [ ] **TI12** CHANGELOG entry.
  - Open `CHANGELOG.md`; locate the 0.16.5 in-flight section (under FR10 banner). Append a single line: `S38 — Readability pack: \`_logRun\` helper + per-step progression at \`fine\`; typed \`Task.worktree\` getter; \`WorkflowStep.type\` deprecated in favour of \`taskType\`; dir-naming conventions documented; \`TaskExecutor.workspaceDir\` renamed to \`workspaceRoot\`; \`TaskExecutorLimits\` record extracted.` (Adjust phrasing to match the existing 0.16.5 entry style.)
  - **Verify**: `rg "TaskExecutorLimits|taskType|workspaceRoot" CHANGELOG.md` returns ≥1 hit on the new line.

- [ ] **TI13** Workspace verification.
  - Run `dart format --set-exit-if-changed packages apps`, `dart analyze --fatal-warnings --fatal-infos`, `dart test packages/dartclaw_server/test/task`, `dart test packages/dartclaw_workflow/test/workflow`, `dart test packages/dartclaw_core/test`, and `dart test` workspace-wide. Scan `rg 'TODO|FIXME|placeholder|not.implemented' packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart packages/dartclaw_core/lib/src/task/task.dart packages/dartclaw_server/lib/src/task/task_executor.dart packages/dartclaw_server/lib/src/task/task_executor_limits.dart packages/dartclaw_core/lib/dartclaw_core.dart` for stragglers.
  - **Verify**: all commands exit 0; no straggler markers introduced; `constructor_param_count_test.dart` either reports `TaskExecutor` < 12 unconditionally or via a temporary allowlist entry (record which under Implementation Observations).

### Testing Strategy

- [TI02] Scenario _Existing consumer reading `Task.worktreeJson['branch']` continues to work_ → smoke unit assertion in `packages/dartclaw_core/test/task/task_test.dart` (or nearest existing file): construct a `Task` with a populated `worktreeJson`; assert `task.worktree?.branch == ...` and `task.worktreeJson?['branch'] == ...` both hold; assert the null-input path returns `null`.
- [TI04,TI05] Scenarios _Per-step progression noise disappears at `info` level_ + _Terminal errors and approval events remain visible_ → existing workflow-executor scenario tests (`packages/dartclaw_workflow/test/workflow/scenarios/`, `packages/dartclaw_workflow/test/workflow/workflow_executor_test.dart` or equivalent) re-run unchanged; they assert behavioural outcomes, not log severity, so the severity drop is invisible to assertions. A focused unit assertion that captures `_log.onRecord` and confirms the prefix shape `Workflow '<runId>': ...` is welcome but not required.
- [TI06,TI07] Scenario _`WorkflowStep` JSON round-trip is byte-identical post-rename_ → `dart test packages/dartclaw_workflow/test/workflow/` proves round-trip and dispatcher logic still routes by kind.
- [TI09,TI10,TI11] Scenario _`TaskExecutor` ctor surface tightens; `workspaceRoot` shows up at the call site_ → `dart test packages/dartclaw_server/test/task/` proves the new ctor signature works end-to-end; manual count at `task_executor.dart:40-94` proves the < 12 ceiling.
- [TI08] Scenario _Glossary distinguishes step type from task type_ → manual review of `dev/state/UBIQUITOUS_LANGUAGE.md`.
- [TI13] Workspace-wide `dart test` provides the zero-behaviour-change regression sweep (constraint #71).

### Validation

- Manual: read `git diff --stat` after TI11 — it should show only ctor-call-site diffs in `packages/dartclaw_server/test/task/`. No `expect(...)` mutations, no skip flags added.
- Manual: read the migrated log sites in `workflow_executor.dart` — confirm progression sites are at `fine` (via `_logRun` default) and terminal/error sites are at `info`. If unsure on a borderline site, default to `fine` per the architectural decision.

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding.
- Prescriptive details (field names, file paths, deprecation message strings, log-prefix shape) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs: documentation lookup, build troubleshooting — spawn in background when possible.
- After all tasks: run `dart format --set-exit-if-changed`, `dart analyze --fatal-warnings --fatal-infos`, `dart test` workspace-wide, and keep `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [ ] **All success criteria** met across parts (a) – (e)
- [ ] **All tasks** fully completed, verified, and checkboxes checked
- [ ] **No regressions** or breaking changes introduced (deprecation on `WorkflowStep.type` is intentional and called out in CHANGELOG)
- [ ] **Coordinate with S16**: `TaskExecutorLimits` field set / defaults / location match S16's pinned contract — confirm by re-reading `dev/specs/0.16.5/fis/s16-task-executor-residual-cleanup.md` "Architecture Decision" + "Success Criteria"
- [ ] **Coordinate with S35**: `WorkflowStep.taskType` is typed `WorkflowTaskType` (the enum S35 introduces); `fromJson` uses S35's `fromJsonString`; JSON wire-format unchanged (constraint #1)
- [ ] **CHANGELOG entry** under FR10 banner mentions all five readability items in one line


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._

---

## Plan-format migration addendum (2026-05-06)

> Migrated from the pre-template `plan.md` story body during the plan-template reformat. Verbatim copy of the plan's `**Acceptance Criteria**`, `**Key Scenarios**`, and any detailed `**Scope**` paragraphs not already represented above. Authoritative spec content lives in this FIS; the plan now carries only a 1-2 sentence Scope summary plus catalog metadata.

### From plan.md — Scope detail (migrated from old plan format)

**Scope**: Bundle five low-cost, high-payoff readability wins into one ~4h story. (a) **`_logRun(run, msg)` helper + severity drop to `fine`** in `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart` — 12+ inline `_log.info("Workflow '${run.id}': $msg")` calls (lines 577, 588, 616, 681, 703, 715, 786, 816, 848, 912, …) collapse to `_logRun(run, msg)`; per-step progression events drop from `info` → `fine` (terminal status, errors, approval events stay `info`). Also unifies the `${run.id}` vs `${definition.name}` vs `(${run.id})` prefix inconsistency across lines 499, 523, 577. (b) **Typed `Task.worktree` read-only helper** in `packages/dartclaw_core/lib/src/task/task.dart` — add `({String? branch, String? path, DateTime? createdAt})? get worktree => …` that parses the `Map<String, dynamic>? worktreeJson` field. The map field stays for back-compat. (c) **Rename `WorkflowStep.type → taskType`** in `packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart:471` after S35 has introduced `WorkflowTaskType` on the existing `type` field — add `taskType` field; deprecate `type` with `@Deprecated('Use taskType')`; update public `dev/state/UBIQUITOUS_LANGUAGE.md` §"Overloaded Terms" to distinguish "step type" (kind: action/loop/parallel) from "task type" (coding/reading/analysis/etc). (d) **Document the three dir conventions** — add a dartdoc comment block in the `dartclaw_core` barrel clarifying: `dataDir` = `~/.dartclaw/` (instance root), `workspaceDir` / `workspaceRoot` = user's active project working tree, `projectDir` = clone under `$dataDir/projects/<id>/`. Rename `TaskExecutor.workspaceDir` → `workspaceRoot` to align with the glossary. (e) **`TaskExecutorLimits` record** — group the cohesive `compactInstructions` / `identifierPreservation` / `identifierInstructions` / `maxMemoryBytes` / `budgetConfig` quintet on `TaskExecutor.new` (`task_executor.dart:35-62`, currently ~23 named params) into a single record or class. This drops the ctor below S10's `≤12 params` fitness threshold and makes the cohesive-cluster-vs-one-off-flag distinction visible at the call site. (Similar `WebRoutesChannels` / `WorkflowBashSandbox` clusters are left for S18-adjacent future work — out of scope here.)

### From plan.md — Acceptance Criteria addendum (migrated from old plan format)

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

### From plan.md — Key Scenarios addendum (migrated from old plan format)

**Key Scenarios**:
- Happy: reading `workflow_executor.dart` log lines, the per-step noise disappears at `info` level; terminal errors remain visible
- Edge: consumer code that reads `Task.worktreeJson['branch']` continues to work via the untouched map field; new code uses `task.worktree?.branch`
- Boundary: glossary + dartdoc are authoritative — future contributors reach for `workspaceRoot` not `workspaceDir` on new code

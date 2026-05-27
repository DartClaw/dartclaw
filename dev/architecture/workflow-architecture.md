# Workflow Architecture

Canonical deep-dive for DartClaw's workflow engine. This document covers deterministic orchestration, the definition model, step execution semantics, parallel groups, loops, map/fan-out, context flow, budgets, skill integration, crash recovery, and how the engine relates to task execution.

**Current through**: 0.16.5 (map/foreach `maxItems` is opt-in; omitted means uncapped)

---

## 1. Design Goal

DartClaw workflows are not prompt choreography. They are host-orchestrated pipelines with explicit state, explicit gates, and deterministic recovery points.

The goal is to let the Dart host own the control plane:

| Concern | Dart host | Workflow step |
|---|---|---|
| Ordering | Yes | No |
| Persistence | Yes | No |
| Budgeting | Yes | No |
| Approval gating | Yes | No |
| Tool execution | Indirectly, via task/service wiring | Yes, for agent steps |

This matches the broader 2-layer model:

```
┌────────────────────────────┐
│ Dart host                  │
│ - parses definitions       │
│ - schedules steps          │
│ - persists context         │
│ - evaluates gates          │
│ - creates tasks            │
└─────────────┬──────────────┘
              │
              │ turns / tasks / shell steps
              ▼
┌────────────────────────────┐
│ Provider CLI binaries      │
│ - reasoning                │
│ - tool execution           │
│ - streamed output          │
└────────────────────────────┘
```

The implementation is split across:

- `packages/dartclaw_models/lib/src/workflow_definition.dart` — definition model, step model, loop model
- `packages/dartclaw_models/lib/src/workflow_run.dart` — run state model
- `packages/dartclaw_workflow/lib/src/workflow/` — parser, validator, executor, context extractor, template engine, skill registry, schema validation, filesystem-backed workflow definitions and skills
- `packages/dartclaw_server/lib/src/api/workflow_routes.dart` — HTTP API endpoints
- `apps/dartclaw_cli/lib/src/commands/workflow/` — CLI commands

The public-facing companion guide is [workflows.md](../../../dartclaw-public/docs/guide/workflows.md).
This architecture builds on the multi-provider harness boundary established in [ADR-016](../adrs/016-multi-provider-harness-architecture.md).

## 2. System Overview

Workflow execution is a host-owned lifecycle:

1. Parse a YAML definition into typed models.
2. Validate step references, gate expressions, loop membership, and schema hints.
3. Create a `WorkflowRun` and persist an initial `WorkflowContext`.
4. Execute linear steps in order.
5. Execute contiguous `parallel: true` groups concurrently.
6. Execute loops with a deterministic exit gate and a hard iteration cap.
7. Persist context after every step so crash recovery can resume safely.

The workflow engine is intentionally adjacent to task orchestration but not embedded inside it. Workflow steps create tasks; tasks remain the unit that the rest of the server understands.

### 2.1 Workflow-Owned Git Lifecycle

For project-backed workflows, git state is orchestrated at the workflow runtime level (not only at task accept time):

- `gitStrategy.integrationBranch` can create a workflow-owned integration branch before step execution.
- `gitStrategy.worktree: shared` lets serial coding steps reuse one workflow-owned worktree/branch.
- `gitStrategy.worktree: per-map-item` keeps mapped coding iterations isolated while still promoting results into the integration branch.
- Promotion-aware map execution validates dependency IDs up-front and blocks dependent stories until prerequisite promotion succeeds.
- Promotion merge conflicts pause the run with `promotion-conflict` semantics and preserve worktrees for operator recovery + resume retry.
- `gitStrategy.publish.enabled` triggers deterministic publish at workflow completion and writes machine-readable `publish.*` outputs.

Host-side git operations are injected through `WorkflowTurnAdapter` callbacks, so the workflow package stays independent of server-only git implementations while still reusing `MergeExecutor`, `RemotePushService`, and `PrCreator` in service wiring.

**Review behavior.** Workflow-spawned tasks use task `reviewMode: auto-accept`, so workflow-owned agent steps advance on `TaskStatus.accepted` instead of parking in `TaskStatus.review`. Human checkpoints are structural: add a dedicated review step or an `approval` step instead of per-step `review:`.

**Promotion inference.** The executor resolves the effective worktree mode first and infers promotion from that resolved shape. Omitted `gitStrategy.promotion` behaves as `merge` for isolated per-map-item scopes and `none` for `inline` / `shared` scopes, so shipped workflows do not need to repeat `promotion: merge` just to preserve the existing fold-back behavior.

**`worktree: auto`.** `WorkflowGitStrategy.effectiveWorktreeMode()` resolves omitted or authored `auto` to `per-map-item` only when a map/foreach scope actually runs with `maxParallel > 1`; otherwise serial map/foreach scopes resolve to `inline`. Non-map workflow-level scopes resolve to `shared` when `gitStrategy.integrationBranch: true`, keeping the workflow-owned branch out of the operator's live checkout. Remaining non-map scopes resolve to `inline`. The validator treats unresolved `auto` conservatively for artifact-commit safety checks.

### 2.2 AgentExecution Primitive

Workflow-owned execution state is modeled as an explicit three-row chain rather than being smeared across `Task.configJson` and task-owned runtime columns:

```text
WorkflowRun step
  -> AgentExecution        (provider/model/session/workspace/token-budget runtime state)
  -> WorkflowStepExecution (workflow-only metadata such as step id, step type, git config, map iteration)
  -> Task                  (review lifecycle, artifacts, worktree, UI/API identity)
```

This keeps the workflow package responsible for workflow metadata, keeps the task subsystem responsible for review and artifact lifecycle, and gives both sides a shared `AgentExecution` primitive for the runtime fields that are not inherently task-specific. The practical result is that workflow-private `_workflow*` blobs no longer round-trip through `Task.configJson`, `Task.toJson()` now exposes nested `agentExecution` and `workflowStepExecution` objects, and `TaskExecutor` reads the typed workflow bridge from hydrated `WorkflowStepExecution` rather than reconstructing it from ad hoc task metadata.

## 3. Definition Model

The typed model lives in `dartclaw_models`, not core. The important types are:

| Type | Purpose |
|---|---|
| `WorkflowDefinition` | Top-level workflow schema |
| `WorkflowVariable` | Input variable declaration with optional default |
| `WorkflowStep` | A single step in the pipeline |
| `WorkflowLoop` | Repeating subset of steps with an exit gate |
| `StepConfigDefault` | Glob-based per-step defaults |
| `OutputConfig` | Output extraction and validation metadata |
| `ExtractionConfig` | Explicit extraction override |
| `WorkflowRun` | Runtime state for a run |
| `WorkflowRunStatus` | Run lifecycle state |

The model deliberately keeps string-based fields where the workflow authoring surface needs flexibility. The runtime then validates and normalizes those strings before execution.

### Top-Level Shape

```yaml
name: spec-and-implement
variables:
  FEATURE:
    required: true
steps:
  - id: research
    name: Research
```

The parser accepts the full model surface used by the shipped workflows: `skill`, `parallel`, `gate`, `entryGate`, `inputs`, `outputs` (canonical declaration of context-write keys; per-entry `format`/`schema`/`source`/`outputMode`/`description`/`setValue`), `mapOver`, `maxParallel`, `maxItems`, `continueSession`, `onError`, `workdir`, `maxTokens`, `maxCostUsd`, and `stepDefaults`.

### Schema (S66/S67): `outputs:` and `setValue`

- **`outputs:` is the only declaration of context-write keys.** The parser treats `outputs:` map keys as the source of truth for the context-write set. `WorkflowStep.outputKeys` derives directly from `outputs?.keys`. Foreach / `mapOver` controllers parse `outputs:` through the same path as every other step and emit one aggregate value, so the controller's `outputs:` map must declare exactly one key. The parser throws a `FormatException` with a one-line migration message if the legacy `contextOutputs:` field appears anywhere in the YAML — `contextOutputs: is removed; declare keys under outputs: instead, e.g. outputs: { key_name: text }` — so authors get an immediate cue rather than a silent warning.
- **`OutputConfig.setValue` writes a static literal.** When an output entry declares `setValue:` (any JSON-encodable literal, including `null`), the executor short-circuits extraction for that key and writes the literal verbatim on step success. The slot is sentinel-backed (`_workflowDefinitionFieldUnset`) so absence and explicit `null` round-trip distinctly through `toJson` / `fromJson`. `setValue` wins over the legacy `extraction:` priority branch even at the first-key position, and fires only on success — failure and `entryGate` skip leave context untouched. Snake_case alias `set_value` is accepted alongside the camelCase form.
- **Validator alias-awareness for `continueSession` and multi-prompt.** Role-aliased providers (`@executor`, `@reviewer`, `@planner`, `@workflow`, …) are skipped by the continuity-provider check in both `_validateMultiPromptProviders` and the `continueSession` block. The runtime fallback in `WorkflowExecutor._resolveContinueSessionProvider` continues to detect family mismatches at execution time (warning + re-route to the root provider). Concrete provider names with no continuity support still produce `unsupportedProviderCapability` errors. A `TODO(0.16.7+)` comment in the validator hot spots names the deferred stretch path: thread the workflow's roles config through the validator so the resolved concrete provider can be checked at validation time.

## 4. Step Types

The engine supports both agent-driven and deterministic step types.

| Type | Meaning | Runs a task? |
|---|---|---|
| `agent` | Agent step that creates a coding task | Yes |
| `bash` | Host-side command execution | No |
| `approval` | Human approval checkpoint | No |
| `foreach` | Per-item sub-pipeline controller — executes ordered child steps for each `mapOver` element | Per child step |
| `loop` | Bounded loop controller over authored child steps | Per child step |

The step type axis and the skill axis are independent. A skill-aware step still uses one of the types above, but adds `skill:` to direct prompt construction.

### Agent Steps

Agent steps create tasks, can be reviewed, and may persist or resume sessions when the provider supports continuity. Agent steps support multi-prompt execution (Section 4.4) and session continuity (Section 4.5).

### 4.1 Bash Steps

Bash steps run on the host side via `Process.start('/bin/sh', ['-c', ...])`. They are used for deterministic operations where an LLM would only add noise — extracting diffs, running validators, calling CLI tools.

Execution semantics:

| Concern | Behavior |
|---|---|
| Task creation | None. Bash steps are zero-task, zero-token |
| Working directory | Explicit `workdir` field (template-resolved), or `<dataDir>/workspace/` default |
| Template substitution | `{{context.*}}` values are shell-escaped via `shellEscape()` to prevent injection. Variable references (`{{VAR}}`) are NOT escaped — they are author-controlled |
| Timeout | `step.timeoutSeconds` (default 60s). Process receives SIGTERM, then SIGKILL after 2s grace |
| Stdout capture | Truncated at 64 KB with `[truncated]` marker |
| Output extraction | Respects `outputs` config: `format: json` parses JSON from stdout, `format: lines` splits lines, `format: text` passes raw stdout |
| Error handling | Non-zero exit code → failure. `onError: continue` records failure metadata and advances; `onError: pause` (default) pauses the run |

Bash steps store automatic metadata in context:

- `<stepId>.status` — `success` or `failed`
- `<stepId>.exitCode` — process exit code
- `<stepId>.workdir` — resolved working directory
- `<stepId>.stderr` — stderr output (if non-empty)
- `<stepId>.stdoutTruncated` — `true` if output was truncated

The built-in `code-review` workflow no longer hardcodes an `extract-diff` bash step. It passes review targets directly to `dartclaw-review`, then loops `remediate → re-review` until findings reach zero or the loop exhausts. The `dartclaw-remediate-findings` skill is responsible for running analysis/tests/linting on its edits before emitting a completed remediation result.

All built-in `dartclaw-review` steps pass `--output-dir "{{workflow.runtime_artifacts_dir}}/reviews"`, where `{{workflow.runtime_artifacts_dir}}` is a render-only system variable that resolves to `<dataDir>/workflows/runs/<runId>/runtime-artifacts`. The workflow engine creates that directory and its `reviews/` subdirectory at run start before any provider CLI is launched. This uses AndThen's explicit report-output override to avoid heuristic placement drift while keeping transient review reports outside the project worktree.

### 4.2 Approval Steps

Approval steps hold the workflow until an operator accepts or cancels the run. They are zero-task, zero-token gates.

When the executor reaches an approval step:

1. The approval prompt is template-resolved and persisted as metadata.
2. Approval state keys are written to both `WorkflowContext` and flat `contextJson`:
   - `<stepId>.approval.status` — `pending`, `approved`, `rejected`, `timed_out`
   - `<stepId>.approval.message` — resolved prompt text
   - `<stepId>.approval.requested_at` — ISO 8601 timestamp
   - `_approval.pending.stepId` — for API/UI to identify the active gate
3. `currentStepIndex` is advanced past the approval step before the hold is persisted (so resume starts at the next step).
4. `WorkflowApprovalRequestedEvent` is fired for SSE subscribers.
5. The run transitions to `awaitingApproval`.

If `timeoutSeconds` is set, a timer is started. On expiry, the approval is marked `timed_out` and the run is cancelled. Timeout timers are rehydrated on server restart for `awaitingApproval` runs with unexpired deadlines.

Resolution paths:

| Action | Source | Effect |
|---|---|---|
| Resume | `POST /api/workflows/runs/<id>/resume` | Marks approval as `approved`, fires `WorkflowApprovalResolvedEvent`, resumes from next step |
| Cancel | `POST /api/workflows/runs/<id>/cancel` | Marks approval as `rejected` with optional `feedback`, fires `WorkflowApprovalResolvedEvent`, cancels run and child tasks |
| Timeout | Timer expiry | Marks approval as `timed_out`, cancels run |

No current built-in workflow requires an `approval` step. `spec-and-implement` now follows a single-step spec flow: `spec` writes the FIS to disk, `implement` reads it via `file_read`, then validation, integrated review, and the bounded remediation loop operate against that on-disk baseline. Approval steps remain available for custom workflows that truly need a human checkpoint.

### 4.2.1 Workflow Run Status Model

`WorkflowRunStatus` now distinguishes operator holds from failure states:

- `paused` means an operator deliberately paused the run.
- `awaitingApproval` means the run is blocked on an approval gate or a step-reported `needsInput` outcome.
- `failed` means the run hit a runtime, gate, or step failure and is eligible for explicit retry.

Only `completed`, `failed`, and `cancelled` are terminal lifecycle states. This keeps dashboards, SSE subscribers, and CLI exit codes aligned with operator intent instead of conflating "waiting on a human" with "something broke".

### 4.2.2 Step Outcome Protocol

Agent steps can now end their final assistant message with:

```text
<step-outcome>{"outcome":"succeeded|failed|needsInput","reason":"..."}</step-outcome>
```

The executor appends this contract automatically unless the step or referenced skill opts out with `emitsOwnOutcome: true`.

Runtime handling:

- `succeeded` records `step.<id>.outcome = "succeeded"` and continues normally.
- `failed` records the semantic outcome and applies `onFailure` (`fail`, `continue`, `retry`, `pause`).
- `needsInput` always transitions the run to `awaitingApproval`, reusing the same `_approval.*` metadata shape as an explicit approval step.
- Missing tags fall back to lifecycle status (`accepted -> succeeded`, `failed/cancelled -> failed`), emit a warning log, and increment the `workflow.outcome.fallback` counter.

The older `<stepId>.status` keys remain as lifecycle metadata. Outcome is additive rather than a replacement, so existing gates keep working while authors can now write semantic gates such as `step.review.outcome != failed`.

### 4.3 Hybrid Step Concept

"Hybrid step" is the engine's term for the fact that different step types have different execution semantics sharing the same `WorkflowStep` model. The parser and validator enforce type-specific constraints:

- `bash` and `approval` steps cannot use multi-prompt lists
- `approval` steps cannot be marked `parallel`
- `bash` and `approval` steps with `continueSession` are rejected (no session to continue)
- Unknown step types fail validation (the supported set is closed; additions are intentional breaking changes)

This means workflow authors can mix agent reasoning, host-side shell commands, and human checkpoints in a single pipeline without the engine conflating their execution paths.

### 4.4 Multi-Prompt Steps

A step with `prompt:` as a list of strings (rather than a single string) is a multi-prompt step. The engine executes each prompt sequentially under provider-native session continuity (Claude Code `--resume`, Codex `resume`):

1. The first prompt is launched as a one-shot CLI invocation; its session ID is captured.
2. Each subsequent prompt is launched as another one-shot CLI invocation, resuming the captured session so the agent retains accumulated context.
3. Schema-driven output format instructions are appended only to the final prompt.
4. The skill prefix (`"Use the '<skill>' skill."`) is applied only to the first prompt.

Per-step budget enforcement applies across all prompts: `maxTokens` is checked before each follow-up prompt. Exhausting the budget marks the step as failed; the run's terminal status then follows the step's `onFailure` policy (`fail` by default — see Section 17).

Multi-prompt steps require a continuity-capable provider; the validator rejects multi-prompt steps targeting providers without session continuity (with role-alias awareness — see Section 19).

### 4.4a One-Shot Workflow Execution

Workflow agent steps use a single one-shot CLI execution path. The task lifecycle still exists, but the task executor runs the workflow prompt chain as direct provider CLI invocations instead of routing follow-up prompts back through the interactive harness pool.

Practical consequences:

- Workflow prompt chains can reuse provider-native session continuity (`--resume` / `resume`) across prompts.
- Native structured extraction is implemented as an extra one-shot extraction turn on the same provider session.
- The task/session transcript is still recorded in DartClaw's own session store.
- Workflow tasks set `task.type = TaskType.coding` uniformly; workflow step type no longer flows through task-system bookkeeping.
- Workflow step read-only behavior is derived from effective `allowedTools` via `step_config_policy.stepIsReadOnly`, and the mutation check runs against the provisioned worktree path when present.
- `format: json` with `schema` defaults to provider-enforced structured output. Explicit `outputMode: prompt` is the opt-out; heuristic extraction remains only as a fallback when the structured payload is missing.
- `outputMode: structured` is now inline-first: if the last assistant message already contains a valid `<workflow-context>` payload with the required top-level keys, the executor promotes that inline JSON directly and skips the extra extraction turn. Provider-native schema extraction remains the fallback when the inline payload is missing or malformed.

The parser normalizes `prompt: "single string"` to `prompts: ["single string"]` so the executor always works with a list. `step.isMultiPrompt` is true when `prompts.length > 1`.

### 4.5 Session Continuity

`continueSession` lets a step reuse the agent session from a prior step rather than starting fresh. This preserves the LLM's accumulated context across step boundaries.

Continuation is most valuable for true refinement chains and same-worktree validation loops. Review-style steps whose real inputs are already rendered through `inputs` now prefer fresh sessions in the built-in workflows, because replaying the full prior session history costs tokens without improving the step contract.

The `continueSession` field accepts:

| Value | Meaning |
|---|---|
| `true` (legacy) | Normalized to `@previous` — continue the immediately preceding step's session |
| `"<stepId>"` | Continue the named step's session |
| `@previous` | Internal sentinel for the step before this one |

Resolution is chain-aware: if step C continues step B, which continues step A, the executor traces back to the root (step A) and reuses that session. The root session ID is resolved from context as `<rootStepId>.sessionId`.

When executing a continuation step, the executor snapshots the session's current token count as a baseline so step-level budget accounting reflects only the tokens consumed by this step, not the entire session history.

Validation constraints (enforced by the validator, Section 19):

- Cannot combine `continueSession` with `parallel`
- Cannot target a `bash` or `approval` step
- Cannot cross loop boundaries
- Cannot form a cycle
- Target must precede the current step in author order
- Provider must support session continuity

## 5. Execution Lifecycle

The executor follows authored-order traversal over normalized control nodes:

1. Start a run (validate variables, create `WorkflowRun`, persist initial context).
2. Walk authored steps in order.
3. When adjacent steps are marked `parallel: true`, collect them into a group and run concurrently via `Future.wait()`.
4. When a step has `mapOver`, resolve the collection from context and fan out (Section 8).
5. When the traversal reaches the first step owned by a loop, execute the loop in-place (including optional finalizer).
6. For each dispatched unit: evaluate gates, check budget, dispatch (agent task / bash / approval / multi-prompt), extract context outputs.
7. Persist the updated `WorkflowContext` after each completed step or iteration boundary.
8. When traversal reaches the end of authored nodes, transition run to `completed`.

That gives a predictable mental model:

```
definition -> authored traversal -> parallel/map/loop nodes -> done
```

Within each agent step, the execution path depends on step configuration:

- Single-prompt: create task → wait for terminal state → extract outputs
- Multi-prompt: create task → wait → send follow-up turns → extract from final turn
- Session continuity: resolve root session → snapshot baseline tokens → create task with `_continueSessionId` in config → wait → extract

The run snapshot records step and loop cursor metadata so a crash can restart from the active loop iteration/step boundary without replaying completed siblings.

## 6. Parallel Groups

Contiguous steps with `parallel: true` form a group. The executor dispatches them concurrently and merges results after all finish.

Group semantics:

- The group is contiguous; non-parallel steps break the group.
- The group is launched only after all prior linear steps have succeeded or paused.
- Failures pause the workflow rather than silently dropping results.
- Group results are merged back into context in step order.
- **Pause/cancel during a parallel group preserves the operator-driven terminal status** (S78). When a child step returns `null` from a `_WorkflowRunWaitAbort` propagated by the pause/cancel handler, the executor refreshes run status and short-circuits before invoking `_failRun`, so a paused or cancelled group resolves to `paused`/`cancelled` instead of being converted to `failed` by the parallel branch's failure path. Cancel-threading into already-dispatched inner iteration bodies (H4/H5) is deferred to 0.16.5 — current behaviour cancels by draining once each in-flight task completes; with `maxParallel` peers running, cancel can take up to one full inner iteration to take effect.

Example:

```yaml
steps:
  - id: collect
    parallel: true
  - id: peer-review
    parallel: true
```

This is used for independent discovery and reviewer fan-out. The public guide explains the authoring pattern; the executor guarantees the concurrency behavior.

## 7. Loops, Entry Gates, and Exit Gates

Loops are defined as a named set of step IDs plus a hard cap and an exit condition.

| Field | Purpose |
|---|---|
| `steps` | Step IDs to repeat |
| `maxIterations` | Circuit breaker |
| `entryGate` | Optional Boolean expression evaluated before the first iteration |
| `exitGate` | Boolean expression evaluated after each iteration |
| `finally` | Optional finalizer step outside the loop body |

The gate evaluator supports the operators `==`, `!=`, `<`, `>`, `<=`, `>=`, joined with `&&` and `||` (two-level OR-of-AND grammar — see Section 22).

Loop execution now has two authored gates:

- `entryGate` decides whether the loop body runs at all.
- `exitGate` decides whether another iteration is needed after the current pass.

The loop keeps iterating until:

- the exit gate passes, or
- `maxIterations` is reached

The `finally` step runs after the loop ends regardless of whether the exit gate passed or the iteration cap stopped the run.

## 8. Map / Fan-Out and Per-Item Sub-Pipelines

The engine supports two collection-iteration primitives: `MapNode` for single-step fan-out, and `ForeachNode` for per-item ordered sub-pipelines.

### MapNode (Single-Step Fan-Out)

Map steps iterate over a JSON array in context and run one iteration per element. They are the engine's dynamic fan-out mechanism for single-step work.

Key fields:

- `mapOver`: context key holding the array
- `maxParallel`: cap on concurrent iterations
- `maxItems`: optional collection-size ceiling

Template references for map steps include:

- `{{map.item}}`
- `{{map.index}}`
- `{{map.length}}`
- `{{context.key[map.index]}}`

That lets a later step bind output to the Nth mapped item without hand-written indexing logic in the workflow authoring surface.

### ForeachNode (Per-Item Sub-Pipelines)

`ForeachNode` (type `foreach`) extends the map primitive to support an ordered sequence of authored substeps per item — a "per-item sub-pipeline". It is the mechanism for expressing multi-step work that must run in sequence for every item before the results are aggregated back into the plan-level context.

Key additional fields over `MapNode`:

- `steps`: ordered list of substep definitions, each a full `WorkflowStep`
- `outputs`: a single-entry map declaring the key under which the aggregated per-item result list is written after all iterations. `mapOver` and `foreach` controllers parse this through the same code path as every other step and must declare exactly one key — the validator rejects multi-key declarations as a `contextInconsistency` error.

Each iteration runs its substeps in declared order. Substeps share a per-iteration context overlay: each substep's outputs are written into the overlay under the keys declared in its `outputs:` block (bare keys), so later sibling substeps read them directly — e.g. `quick-review` reads `{{context.story_result}}` produced by `implement`. There is no automatic step-id prefixing in the overlay; if a substep needs to expose its output under a `<stepId>.<key>` form (for disambiguation when two substeps emit the same generic key), it must declare that prefixed key explicitly in its own `outputs:` block. The per-iteration overlay is isolated from the plan-level context during execution; results are aggregated back after all items complete, keyed by child step id. See the user guide's [Step-Prefixed References](../../../dartclaw-public/docs/guide/workflows.md#step-prefixed-references-contextstepidkey) section for the full reference-form grammar.

`ForeachNode` reuses the same `MapStepContext` concurrency and dependency-graph machinery as `MapNode`, so `maxParallel`, `maxItems`, pool availability, and story-level `dependencies` fields all work identically.

`plan-and-implement` uses `ForeachNode` for its `story-pipeline` step, running `implement → quick-review` per story before any plan-level review or remediation. `dartclaw-exec-spec` is responsible for running analysis/tests/linting and fixing issues before emitting the story result.

### Concurrency and Dependency Graph

Both `MapNode` and `ForeachNode` execution respects three concurrency controls:

| Control | Source | Effect |
|---|---|---|
| `maxParallel` | Step definition | Caps simultaneous iterations |
| `maxItems` | Step definition, when set | Optional ceiling on collection size; omitted means uncapped |
| Pool availability | `WorkflowTurnAdapter.availableRunnerCount()` | Bounds concurrency to available harness runners |

Effective concurrency is `min(maxParallel, poolAvailable, collection.length)`.

When collection items declare `id` and `dependencies` fields (common for story_plan arrays), the `DependencyGraph` enforces ordering:

- Items with no dependencies are dispatched immediately.
- Items with dependencies wait until all dependency IDs have completed.
- Cycles are detected via Kahn's algorithm and throw an `ArgumentError` at dispatch time.

This enables the `plan-and-implement` workflow's `story-pipeline` foreach step to respect inter-story dependencies declared in the `story_specs` records produced by the `plan` step.

Map and foreach step results are index-ordered regardless of completion order. Failed iterations store error objects (`{error: true, message: ..., task_id: ...}`) in the result array, and partial results are persisted to context before pausing. The `MapStepContext` tracks in-flight count, completed indices, failed indices, and budget exhaustion state.

The map and foreach iteration dispatch loops wake on iteration completion via a single `Completer<void>` pumped from each in-flight future's `whenComplete`, rather than re-registering listeners every tick via `Future.any(inFlight.values)` and timer-driven 1 ms polling (S78 — that pattern caused listener-allocation pressure scaling with `iterations × outer_loop_ticks` and is the failure mode recorded in `MEMORY.md → feedback_dart_async_test_loops`). Each in-flight future is wrapped with `.catchError((_) {})` so an unhandled async error inside one iteration cannot escape the dispatch loop and leak `inFlightCount`.

## 9. Context Flow

Context is the bridge between steps. The extractor and template engine are the two key pieces.

### Extraction Priority

The server-side extractor uses a deterministic fallback chain (full priority list and rationale in [Section 21](#21-output-and-context-extraction)):

1. `OutputConfig.setValue` — literal write, short-circuits all extraction
2. `OutputConfig.source` — direct task metadata read (`worktree.branch`, `worktree.path`)
3. Canonical context defaults — `*_source` keys default to `synthesized` for any step that emits them blank; `prd`, `plan`, and `story_specs` pre-fill from `project_index` only for the `discover-project` step (see `context_output_defaults.dart`)
4. Per-key resolver — `FileSystemOutput` (path glob), `InlineOutput`/`NarrativeOutput` (`<workflow-context>` JSON, then structured-output payload)
5. Step-level legacy `extraction:` — first-key path
6. Empty string with warning

### Template Engine

The `WorkflowTemplateEngine` resolves `{{...}}` placeholders in four namespaces:

- `{{VARIABLE}}` — workflow variables (fail-fast `ArgumentError` if undefined; the resolver swallows unknowns at resolve-time so resolved YAML stays valid)
- `{{context.KEY}}` — accumulated context data (empty string with warning if missing)
- `{{map.*}}` / `{{<alias>.*}}` — map/foreach iteration references (only available inside map/foreach controllers; aliases declared via `as: <alias>`)
- `{{workflow.*}}` — render-only system variables injected by the engine (currently `{{workflow.runtime_artifacts_dir}}`; undefined throws `ArgumentError`)

`map`, `context`, and `workflow` are reserved alias names — they cannot be used as `as:` identifiers.

Map-aware resolution (`resolveWithMap`) supports:

- `{{map.item}}` — JSON-encoded if Map, toString otherwise
- `{{map.item.field}}` — dot-access on Map items (up to 10 segments after `item.`)
- `{{map.index}}` / `{{map.display_index}}` — 0- / 1-based iteration index
- `{{map.length}}` — total collection size
- `{{context.key[map.index]}}` — indexed lookup into a List-typed context value
- `{{context.key[map.index].field}}` — dot-access on indexed result

When a map/foreach controller declares `as: <alias>` (e.g. `as: story`), templates may also use the named form `{{story.item}}`, `{{story.item.field}}`, `{{story.index}}`, `{{story.display_index}}`, `{{story.length}}`, and `{{context.key[story.index]}}`. The legacy `{{map.*}}` prefix continues to bind to the same iteration, so aliasing is additive.

List-typed fields on map items (e.g., `{{map.item.acceptance_criteria}}`) are automatically rendered as bullet lists. Indexed context values with a `.text` field are auto-extracted for convenience.

The engine is intentionally simple. It does not attempt to be a general-purpose templating language. No conditionals, no loops, no function calls.

### Persistence

Context is persisted atomically after each step, so a crash can resume from the last committed state instead of replaying from scratch.

## 10. Budgets and Defaults

Budgeting exists at three levels:

- workflow-level `maxTokens`
- step-level `maxTokens`
- step-level `maxCostUsd`

`stepDefaults` applies glob-matched defaults before per-step overrides. The first match wins.

```yaml
stepDefaults:
  - match: "review*"
    maxCostUsd: 2.0
  - match: "*"
    maxTokens: 40000
```

This keeps expensive reviewer steps bounded without repeating the same configuration on every step.

## 11. Skill Registry

The skill system plugs into workflow authoring through a narrow interface:

- `SkillRegistry.listAll()`
- `SkillRegistry.getByName()`
- `SkillRegistry.validateRef()`
- `SkillRegistry.isNativeFor()`

When a step declares `skill:`, the `SkillPromptBuilder` handles four prompt construction cases:

| Case | Prompt shape |
|---|---|
| skill + prompt | `"Use the '<skill>' skill.\n\n<resolved prompt>"` |
| skill + no prompt | `"Use the '<skill>' skill.\n\nContext:\n- key: value..."` |
| no skill + prompt | passthrough (resolved prompt unchanged) |
| no skill + no prompt | rejected by validator |

After construction, the `PromptAugmenter` appends schema-driven output format instructions if the step declares outputs with a `schema` field (Section 11.1).

### Skill Frontmatter Workflow Block

Each `SKILL.md` can declare a `workflow:` block in its YAML frontmatter:

```yaml
---
name: dartclaw-quick-review
description: …
workflow:
  default_prompt: "Use $dartclaw-quick-review to run a fast fresh-context review of the recent changes."
  default_outputs:
    quick_review_summary: {format: text}
    quick_review_findings_count: {format: json, schema: non_negative_integer, description: "…"}
---
```

The `SkillRegistryImpl._parseFrontmatterContent` pass reads the block into `SkillInfo.defaultPrompt` and `SkillInfo.defaultOutputs`. The workflow executor consults these when a step declares `skill:` and omits `prompt:` / `outputs:` — the missing fields are filled from the registry entry so Case 1 applies (the skill-line prefix followed by the default prompt), and the extraction path uses the merged `outputs:` map.

This replaces the legacy per-skill `agents/openai.yaml` files; the shape of the frontmatter block is intentionally neutral (no harness label) so third-party skills can target the same surface without declaring per-harness artifacts.

As of ADR-025 (implemented in 0.16.4 / S71 and simplified by S81), DartClaw ships three DC-native skills (`dartclaw-discover-project`, `dartclaw-validate-workflow`, `dartclaw-merge-resolve`). All other workflow skills (`dartclaw-spec`, `dartclaw-plan`, `dartclaw-prd`, `dartclaw-exec-spec`, `dartclaw-review`, `dartclaw-remediate-findings`, `dartclaw-quick-review`, `dartclaw-ops`) are provisioned at `dartclaw serve` startup by `SkillProvisioner` (`packages/dartclaw_workflow/lib/src/skills/skill_provisioner.dart`).

#### Runtime-Provisioning Model (S71, Simplified By S81)

At startup the boot sequence is:

1. **Resolve config** — load `dartclaw.yaml`, populate `AndthenConfig` (`andthen.git_url`, `andthen.ref`, `andthen.network`).
2. **Ensure cache current** — clone-or-pull `<data_dir>/andthen-src/` honoring `andthen.network` (`auto`/`required`/`disabled`); resolve HEAD SHA; check the native user-tier marker plus tree completeness; run `install-skills.sh --prefix dartclaw- --display-brand DartClaw --claude-user` and copy DC-native skills only when the destination is incomplete.
3. **Start HTTP** — bind the listener.

The only install destination is the native harness user tier: `~/.agents/skills`, `~/.codex/agents`, `~/.claude/skills`, and `~/.claude/agents`. The marker + completeness gate keeps repeat startups cheap (no install when SHA matches and tree is intact) while repairing partial installs (missing AndThen skill tree, missing Claude/Codex destination, missing DC-native copy, or marker drift). See [`docs/adrs/025-andthen-as-runtime-prerequisite.md`](../adrs/025-andthen-as-runtime-prerequisite.md) for the architecture rationale and [`../../../dartclaw-public/docs/guide/andthen-skills.md`](../../../dartclaw-public/docs/guide/andthen-skills.md) for operator usage.

### Auto-Framed Context Inputs

`SkillPromptBuilder.build` runs an auto-frame pass between the resolved-prompt assembly and `PromptAugmenter.augment`:

1. Determine the tag name as `key.replaceAll('.', '_')`.
2. Skip the key if `<tagName` already appears in the resolved prompt (case-sensitive, prefix-only so XML attributes don't defeat it).
3. Skip the key if `{{context.key}}` / `{{context.tagName}}` (inputs) or `{{KEY}}` / `{{tagName}}` (variables) appears in the template prompt (pre-substitution form — required for correct detection when the substitution has already happened).
4. Otherwise append `\n\n<tagName>\n{resolved value}\n</tagName>`; null/empty values render as `_(empty)_` per the existing `formatContextSummary` convention.

`WorkflowStep.autoFrameContext` (YAML key `auto_frame_context`, default `true`) opts the step out. The shipped built-in workflows intentionally lean on this mechanism for boilerplate-free step authoring: generic prompt wrappers such as manual `Branch:` lines or duplicated `file_read` reminders are omitted from YAML when skill defaults + auto-framed inputs already carry the same information.

### Resolved Workflow Observability

`WorkflowDefinitionResolver` converts a `WorkflowDefinition` into a round-trippable, fully-merged form:

- `stepDefaults` patterns applied to each step (first match wins; explicit step fields take precedence).
- Skill frontmatter defaults injected where the step omits `prompt:` / `outputs:` (shallow merge for outputs).
- Workflow-level `{{VAR}}` bindings substituted in step prompts when bindings are supplied; unbound references and `{{context.*}}` references stay intact.
- `stepDefaults` is removed from the emitted definition (already baked into steps) and `nodes` is recomputed via `normalizeNodes`.

The resolver emits YAML via a minimal hand-rolled block-style emitter that the parser accepts unchanged — every built-in workflow round-trips through `resolve → emitYaml → parse` with step-id equivalence (asserted in `workflow_definition_resolver_test.dart`). Foreach `as: <alias>` (`WorkflowStep.mapAlias`) is preserved through `_resolveStep` so resolved-view output matches authored YAML (S78); this affects only `workflow show --resolved` fidelity, not runtime execution (the executor reads the parsed step directly).

The resolver is surfaced through two gates:

- `GET /api/workflows/definitions/<name>` returns the authored YAML (`application/yaml`).
- `GET /api/workflows/definitions/<name>?resolve=true[&step=<id>]` returns the resolved YAML (`application/yaml`). With `step=<id>`, the response is a single-step fragment (404 if the step id is unknown).
- `dartclaw workflow show <name> [--resolved] [--step <id>] [--json] [--standalone]` is the CLI surface. Connected mode calls the route; standalone mode loads the definition through `buildWorkflowRegistry()` and runs the resolver locally. `--json` wraps the YAML body in `{"yaml": "..."}` for scripting.

### 11.1 Schema Presets and Validation

The engine ships 13 built-in schema presets (registered in `schema_presets.dart`) that workflow authors can reference by name instead of writing inline JSON Schema:

| Preset | Purpose |
|---|---|
| `verdict` | Review output with pass/fail, `findings_count`, `findings[]`, `summary` |
| `remediation_result` | Outcome of a remediation pass (changes applied, status, follow-ups) |
| `remediation_summary` | Aggregate remediation summary for loop gates |
| `story_plan` | Array of implementation stories with `id`, `title`, `acceptance_criteria`, `dependencies`, `key_files`, `effort` |
| `story_specs` | Array of per-story spec records with `spec_path` for `file_read` consumption |
| `story_result` | Result record for a single story executed via `ForeachNode` |
| `file_list` | Array of file paths with reasons |
| `checklist` | Pass/fail checklist with items and `all_pass` rollup |
| `project_index` | Normalized project index emitted by `dartclaw-discover-project` |
| `non_negative_integer` | Scalar guard used for counts such as `findings_count` |
| `diff_summary` | Structured diff summary for code-review flows |
| `validation_summary` | Structured validator output (errors, warnings) |
| `state_update_summary` | Summary of `dartclaw-ops` state-update changes |

Usage in a workflow definition:

```yaml
outputs:
  review_findings:
    format: json
    schema: verdict
```

The `PromptAugmenter` resolves the preset and appends its `promptFragment` to the step prompt under a `## Required Output Format` heading. This gives the agent structured instructions without workflow authors needing to repeat format guidance. When `outputMode: structured` is used, prompt augmentation is skipped for that JSON output and the engine instead performs a dedicated native structured extraction turn.

For inline schemas (arbitrary JSON Schema objects), `PromptAugmenter` walks the schema properties and generates a prompt fragment automatically.

Schema validation is soft: `SchemaValidator` parses the agent's JSON output, validates against the preset or inline schema, and logs warnings on mismatches. The parsed object is kept in context regardless. This preserves deterministic downstream access while avoiding false "hard fail" behavior on useful-but-imperfect model output.

Validation checks (all produce warnings, not errors):

- Type mismatches (expected object, got array, etc.)
- Missing required fields
- Nested property type mismatches
- Array item schema violations

The validator is used both at extraction time and for `dartclaw workflow validate` pre-flight checks.

## 12. Crash Recovery

Crash recovery is stateful but simple:

- `WorkflowRun` stores the compact execution snapshot.
- `WorkflowContext` stores the full execution context on disk (atomic JSON writes).
- `currentStepIndex`, `currentLoopId`, and `currentLoopIteration` identify the resume point.
- Loop, approval, and parallel-group metadata are encoded into context so resume can restore the correct state.

On server restart, `WorkflowService.recoverIncompleteRuns()` handles two categories:

- **Running runs**: Automatically resumed. The executor finds the last completed step (via child task inspection) and re-executes from there. Mid-loop runs resume from the persisted loop iteration and step ID.
- **Awaiting-approval runs with approval timeouts**: Timeout timers are rehydrated. If the deadline has already passed, the approval is expired immediately.

Parallel group resume uses `_parallel.failed.stepIds` in contextJson: when a group had failures, the next resume re-runs only the failed steps (not the entire group), then merges their results with the previously successful steps.

`WorkflowSerializationEnactedEvent` is fire-exactly-once across crash + resume for any given `(runId, foreachStepId)` pair (S78). The merge-resolve serialize-remaining path persists the `runEmittedKey` flag immediately after the event fires, before the cancel-and-await-siblings drain begins, so a server crash mid-drain cannot re-fire the event on resume. The post-drain `phase = drained` write remains the second persistence point; only the emitted-flag ordering changed.

This is the same failure model used elsewhere in DartClaw: persistent state is written atomically, and the runtime resumes from the last committed cursor rather than from speculative in-memory state.

## 13. Relationship to Task Executor

Workflow execution and task execution are separate layers with a shared boundary:

- workflow steps create tasks
- task execution performs the actual agent turn or host-side action
- workflow completion is derived from task completion plus gate evaluation

This keeps the workflow engine from becoming a second task system. It orchestrates the task system, it does not replace it.

Three ADRs collectively define the boundary:

- [ADR-021](../adrs/021-agent-execution-primitive.md) — the `AgentExecution` / `WorkflowStepExecution` data-layer decomposition that makes the boundary tractable
- [ADR-022](../adrs/022-workflow-run-status-and-step-outcome-protocol.md) — the portable `<step-outcome>` protocol that lets gate evaluation reason semantically without inferring from task lifecycle
- [ADR-023](../adrs/023-workflow-task-boundary.md) — the behavioural contract (workflows compile to tasks; `TaskExecutor` routes workflow-orchestrated tasks via `WorkflowCliRunner`; `dartclaw_workflow` may write `TaskRepository` directly for the atomic three-row insert)

The workflow↔task import boundary is mechanically enforced by a fitness test at [`dartclaw-public/packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart`](../../../dartclaw-public/packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart).

## 14. Workflow Workspace and Built-In Assets

Workflow steps do not inherit the main interactive workspace behavior files.
Instead, the workflow engine passes a dedicated workflow workspace path through
the task config seam (`_workflowWorkspaceDir`) and continuation-turn adapter.

- Default behavior: the engine materializes a built-in `AGENTS.md` under
  `<dataDir>/workflow-workspace/` and uses that directory for workflow steps.
- Operator override: `workflow.workspace_dir` points steps at a custom
  workflow-only behavior directory.
- Continuation behavior: multi-prompt follow-up turns reuse the same workflow
  workspace through the turn adapter rather than falling back to the main
  interactive workspace.

The shipped built-in workflow library contains 3 workflows:

- `spec-and-implement`
- `plan-and-implement`
- `code-review`

(`research-and-evaluate` was removed in 0.16.4 — the three remaining built-ins all use skill-backed thin wrappers around the `dartclaw-*` skill surface.)

The runtime ships three DC-native `dartclaw-*` skills as filesystem assets
under the shared asset root (`dartclaw-discover-project`,
`dartclaw-validate-workflow`, `dartclaw-merge-resolve`). At `dartclaw serve`
startup, `SkillProvisioner` (see §11) provisions the AndThen-derived
`dartclaw-*` workflow skills into the native user-tier harness roots and copies
the three DC-native skills alongside them. The Codex-tier root carries the
`.dartclaw-andthen-sha` marker tracking the AndThen commit that produced the
install. The registry then discovers the resulting trees through the standard
skill-discovery path; provenance attribution follows the native discovery
source.

The built-in workflow definitions are shipped as YAML files under the shared
asset root and materialized into `<dataDir>/workflows/definitions/` on startup
(`WorkflowMaterializer.definitionsDir(dataDir)`). `WorkflowMaterializer` writes
each shipped definition with a sibling `.dartclaw-managed.json` fingerprint
file — a 16-hex-char FNV-1a 64-bit hash of the source content (cheap drift
detector, not a cryptographic integrity proof). On re-materialization the
source-vs-fingerprint comparison decides the outcome: source matches fingerprint ⇒ skip;
destination modified locally (fingerprint drift) ⇒ preserve the local edit and
warn; source removed from the asset tree ⇒ delete only when destination is
unmodified. `WorkflowRegistry` then loads that directory as
`WorkflowSource.materialized`; project-custom workflows load second under
`WorkflowSource.custom`. Materialized names always win on collision — a
custom workflow with the same name as a built-in is rejected with a warning.
In source checkouts, the canonical YAML files under
`packages/dartclaw_workflow/lib/src/workflow/definitions/` remain the
development source of truth.

Workflow runtime state lives under `<dataDir>/workflows/runs/<runId>/` (see
`workflow_run_paths.dart`):

- `context.json` — atomic JSON snapshot of `WorkflowContext`
- `runtime-artifacts/` — engine-managed transient artifacts (review reports
  via `--output-dir "{{workflow.runtime_artifacts_dir}}/reviews"`, etc.)
- `runtime-artifacts/merge-resolve/merge_resolve_iter_<i>_attempt_<n>.json` —
  per-attempt merge-resolve artifacts (9 normative fields + 2 optional
  timestamps; insertion idempotent by name)

`runId` is validated against `^[A-Za-z0-9_-]+$` to keep the path inside the
data directory. The runtime-artifacts root and its `reviews/` subdirectory are
created at run start before the first prompt renders.

## 15. Wire Formats and API Surfaces

The workflow server exposes definition listing, run lifecycle, form-launch, and event streaming endpoints:

- `GET /api/workflows/definitions` — summary list (no prompt bodies)
- `GET /api/workflows/definitions/<name>` — full definition detail
- `POST /api/workflows/run` — start a new run
- `POST /api/workflows/run-form` — HTMX form launch from `/workflows`
- `GET /api/workflows/runs` — list runs (filterable by `?status=` and `?definition=`)
- `GET /api/workflows/runs/<id>` — enriched run detail with per-step status and child task IDs
- `POST /api/workflows/runs/<id>/pause` — pause a running workflow
- `POST /api/workflows/runs/<id>/resume` — resume a paused workflow or approve an `awaitingApproval` hold
- `POST /api/workflows/runs/<id>/retry` — retry a failed workflow from its stored resume cursor
- `POST /api/workflows/runs/<id>/cancel` — cancel a workflow (also rejects pending approval gates with optional `feedback`)
- `GET /api/workflows/runs/<id>/events` — SSE event stream (Section 15.3)

The matching skill discovery endpoint is:

- `GET /api/skills`

The listing surfaces intentionally use summary projections, not full prompt bodies. Full definitions load only when execution or detail display needs them.

### 15.1 Trigger Surfaces

Workflows can currently be triggered from six surfaces:

| Surface | Entry point | Notes |
|---|---|---|
| HTTP API | `POST /api/workflows/run` | Accepts `{definition, variables, project}`. Returns the created `WorkflowRun` |
| Web UI launch form | `POST /api/workflows/run-form` from `/workflows` | HTMX form launch. Validates required variables inline and redirects with `HX-Location: /workflows/<runId>` |
| Web chat command | `POST /api/sessions/<id>/send` with `/workflow list` or `/workflow run <name> KEY=value` | `ChatCommandHandler` intercepts the message before a normal turn is created, returns an HTML card, and deduplicates repeated commands for 30 seconds |
| GitHub webhook | `POST /webhook/github` | `GitHubWebhookHandler` verifies HMAC-SHA256 signatures, maps PR metadata into workflow variables, and deduplicates active runs for the same workflow + PR + repo |
| CLI connected mode | `dartclaw workflow run <name> -v KEY=VALUE` | Default mode in 0.16.4. Calls `POST /api/workflows/run`, then streams `/api/workflows/runs/<id>/events` over SSE. Exit codes: 0=completed, 1=failed, 2=paused/awaitingApproval/cancelled |
| CLI standalone mode | `dartclaw workflow run <name> --standalone [--force]` | Explicit local fallback via `CliWorkflowWiring`. Probes `/health` first and aborts unless `--force` is set when a server is already running. Passes `headless: true` so review steps auto-accept |

All server-managed trigger surfaces converge on `WorkflowService.start()`: the HTTP API, HTMX launch form, chat command interceptor, and GitHub webhook handler all resolve a `WorkflowDefinition` and hand it to the same service. The connected CLI path is therefore an API client over the same server-owned lifecycle rather than a separate executor path.

The standalone CLI path still exists for serverless or CI use. `WorkflowRunCommand` wires a minimal local service stack via `CliWorkflowWiring` — database, event bus, harness pool, and workflow executor — without starting the HTTP server, then calls `WorkflowService.start(..., headless: true)` directly.

The web UI now exposes both workflow management and launch at `/workflows`, and run detail at `/workflows/<runId>` with real-time SSE updates.

The GitHub webhook surface is intentionally workflow-scoped rather than a general-purpose ingress: configured triggers match event/action/label combinations and currently target built-in workflows such as `code-review`.

### 15.2 CLI Commands

The `dartclaw workflow` parent command now provides ten subcommands:

| Command | Purpose |
|---|---|
| `workflow list` | Lists available workflow definitions with summary metadata |
| `workflow show <name>` | Shows workflow definition YAML; `--resolved [--step <id>]` emits the fully-merged form via `WorkflowDefinitionResolver`, `--json` wraps the YAML body for scripting, `--standalone` loads the definition locally |
| `workflow run <name>` | Runs a workflow in connected mode by default, with `--standalone` for explicit local execution |
| `workflow runs` | Lists recent workflow runs from the server, with optional `--status` and `--definition` filters |
| `workflow pause <runId>` | Pauses a running workflow through the server API |
| `workflow resume <runId>` | Resumes a paused workflow through the server API |
| `workflow retry <runId>` | Retries a failed workflow through the server API |
| `workflow cancel <runId>` | Cancels a running or paused workflow through the server API, with optional `--feedback` |
| `workflow status <runId>` | Shows the current status of a workflow run |
| `workflow validate <file>` | Validates a YAML workflow definition without executing |

The command family is intentionally split across two execution models:

- `workflow list` and `workflow validate` remain local-only. They read workflow definitions from disk and do not require a running server.
- `workflow show` is connected by default but can resolve and emit the definition locally via `--standalone`.
- `workflow run` and `workflow status` are connected by default in 0.16.4, with `--standalone` as an explicit local fallback.
- `workflow runs`, `workflow pause`, `workflow resume`, `workflow retry`, and `workflow cancel` are server-backed lifecycle controls and fail fast if the server is unreachable.

`workflow validate` uses the same parser and validator as the runtime (Sections 18-19), surfacing the same error/warning categories. This enables authors to pre-flight definitions before committing them. The standalone `workflow run` path reuses the same execution package, but the connected path is the preferred operational surface because it preserves guard chain enforcement, observability, and web/UI visibility.

### 15.3 SSE Event Stream

The per-run SSE endpoint (`GET /api/workflows/runs/<id>/events`) streams real-time lifecycle events:

| Event type | Payload |
|---|---|
| `connected` | Run state snapshot + step statuses at connection time |
| `workflow_status_changed` | Run status transition (running → paused, etc.) |
| `workflow_step_completed` | Step outcome with token count and task ID |
| `parallel_group_completed` | Group summary with success/failure counts |
| `loop_iteration_completed` | Iteration number, max iterations, gate result |
| `task_status_changed` | Child task status transitions |
| `approval_requested` | Approval step metadata (message, timeout) |
| `approval_resolved` | Approval outcome (approved/rejected with feedback) |

The web UI detail page subscribes to this stream for live progress updates.

## 16. Design Lineage

Workflow support has evolved in clear phases:

| Milestone | What changed |
|---|---|
| 0.15 | Initial deterministic workflow engine: sequential steps, parallel groups, loops with exit gates |
| 0.15.1 | Schema presets and validation, skill registry and skill-aware steps, map/fan-out execution, loop finalizers, built-in workflows, output format augmentation |
| 0.16.1 | Multi-prompt steps (continuation turns), session continuity (`continueSession`), approval gates with timeout, bash step execution with shell escaping, hybrid step validation, `plan-and-implement` workflow, dependency graph for map items |
| 0.16.3 | Workflow package unification (`dartclaw_workflow`), built-in workflow workspace with `AGENTS.md`, filesystem skill materialization, filesystem-backed workflow materialization, CLI `workflow run/list/validate/status` commands, API endpoint consolidation, architecture documentation |
| 0.16.4 | `ForeachNode` per-item sub-pipeline primitive; `plan-and-implement` redesigned to declare all orchestration in YAML (`plan` step owns stories + story_specs in one pass, `story-pipeline` foreach runs per-story implementation, plan-level remediation loop remains the only open-ended loop); AndThen `>= 0.14.0` declared as runtime prerequisite (ADR-025), ported `dartclaw-*` skills removed; connected-by-default workflow CLI (`run`, `status`, `runs`, `pause`, `resume`, `cancel`), HTMX launch forms on `/workflows`, web chat `/workflow` interception, and GitHub PR webhook triggers for `code-review` |

The important design boundary is unchanged: the host owns orchestration, the provider owns reasoning, and the workflow model keeps those responsibilities explicit.

## 17. Definition Model

The definition model is intentionally small. A workflow is only four things:

1. metadata
2. variables
3. steps
4. loops

That keeps authoring surface area proportional to what the executor can
actually enforce.

At the top level, the parser reads:

| Field | Type | Purpose |
|---|---|---|
| `name` | string | Stable identifier used in registry, CLI, and API |
| `description` | string | Human summary for discovery surfaces |
| `variables` | mapping | Declared runtime inputs with defaults and required flags |
| `steps` | list | Linear step catalog in author order |
| `loops` | list | Legacy loop declarations (compatibility) that normalize into ordered loop nodes |
| `maxTokens` | int? | Whole-run budget ceiling |
| `stepDefaults` | list | Glob-matched default policy for steps |

The workflow model is defined in `dartclaw_models`, not in the server or CLI.
That is a deliberate layering decision:

- parser and validator operate on shared typed models
- CLI validation uses the same structures as the server runtime
- execution can be tested without pulling in HTTP concerns
- storage serializes model state without re-parsing YAML

A minimal definition looks like this:

```yaml
name: spec-and-implement
description: Discover the project, specify the change, and implement it
variables:
  FEATURE:
    required: true
steps:
  - id: discover-project
    name: Discover Project
    prompt: Discover the project structure for {{FEATURE}}.
  - id: spec
    name: Generate Specification
    prompt: Write the specification for {{FEATURE}} using the project index.
    inputs: [project_index]
```

Two details matter here:

- the runtime executes by `id`, not by display `name`
- context edges are explicit; steps do not implicitly see prior outputs

The definition model also encodes newer 0.16-era capabilities directly on the
step object:

| Step field | Purpose |
|---|---|
| `type` | structural execution mode: omitted/`agent`, `bash`, `approval`, `foreach`, or `loop` |
| `skill` | provider-native skill reference |
| `parallel` | marks a step as part of a linear parallel group |
| `gate` | pre-step boolean condition against workflow context |
| `inputs` | named context keys supplied to the step prompt |
| `outputs` | canonical per-key output configuration (`format`/`schema`/`source`/`outputMode`/`description`/`setValue`) — the map's keys are the step's context-write set |
| `mapOver` | collection key for fan-out execution |
| `maxParallel` | per-map concurrency cap |
| `maxItems` | map item ceiling |
| `continueSession` | session continuity target |
| `onFailure` | `fail` (default), `continue`, `retry`, or `pause` — modern step failure policy (drives `step_dispatcher` outcome handling for any step type) |
| `onError` | legacy `pause` / `continue` / `fail` — still honored by the executor and loop runner for any step type when set; primarily used by bash steps. `onFailure` is the preferred field for new authoring |
| `provider` / `model` / `effort` | explicit provider, model, or reasoning-effort override |
| `auto_frame_context` | bool, default `true` — opt out of auto-XML-framing of `inputs:` / `workflow_variables:` |
| `emitsOwnOutcome` | bool, default `false` — skip the `<step-outcome>` framing append |
| `maxTokens` / `maxCostUsd` | step-level budgets |
| `allowedTools` | tool allowlist override |

Loops remain a separate object in the serialized model for backward
compatibility, but runtime traversal treats them as ordered nodes:

| Loop field | Purpose |
|---|---|
| `id` | stable loop identifier for recovery and diagnostics |
| `steps` | ordered list of step IDs that belong to the loop |
| `exitGate` | boolean expression checked after each iteration |
| `maxIterations` | hard ceiling to prevent infinite repetition |
| `finally` | optional step ID that runs after termination |

This design keeps the executor predictable:

- authored order is the primary execution order
- loop-owned steps are executed when their loop node is reached
- finalizers remain loop-owned and run within loop execution semantics
- legacy `loops:` declarations are normalized to the same runtime behavior

The consequence is important: a workflow definition is declarative enough to
be validated statically, but concrete enough that the runtime never has to
infer author intent from prompt text.

## 18. Parser Contract

`WorkflowDefinitionParser` is strict about structural shape and intentionally
loose about future-compatible authoring.

The parser rejects malformed structure up front:

- missing `name`
- missing `description`
- missing `steps`
- empty `steps`
- non-string step IDs
- empty step names
- invalid `prompt` shapes

It normalizes where that improves compatibility:

| Author input | Parser output |
|---|---|
| `prompt: "single string"` | `prompts: ["single string"]` |
| `prompt: ["a", "b"]` | multi-prompt list preserved |
| omitted `type` | defaults to `agent` |
| `timeout: "30s"` | normalized to integer seconds |
| `outputs.key: json` | shorthand converted to `OutputConfig` |

The parser is also where hybrid-step compatibility starts.

Prompt rules are relaxed for:

- `bash` steps
- `approval` steps
- skill-only steps

That means the parser does not insist every step carry an agent prompt. It only
insists the step shape is coherent enough for the validator to reason about.

Example normalization cases:

```yaml
steps:
  - id: author
    name: Author YAML
    prompt:
      - Draft the workflow.
      - Refine the workflow.

  - id: validate-generated-workflow
    name: Validate
    type: bash
    prompt: dartclaw workflow validate generated.yaml

  - id: approve
    name: Approve Plan
    type: approval
```

After parsing:

- `author.prompts` contains two entries
- `validate-generated-workflow.type` is `bash`
- `approve.prompts` is `null`
- each step still occupies a fixed position in the linear author order

The parser does not do semantic checks such as:

- whether `mapOver` references a prior context key
- whether `continueSession` targets a valid step
- whether a gate expression is well formed
- whether a skill exists

Those are validator responsibilities. The separation matters operationally:

- parse errors are syntax/shape failures
- validation errors are contract failures
- warnings are loadable-but-risky definitions

That split is surfaced in `dartclaw workflow validate`, in registry loading,
and in the browser/API diagnostic surfaces.

## 19. Validation Semantics

Validation is not a single boolean. The validator returns a
`ValidationReport` with:

- `errors`
- `warnings`

Definitions are loadable when `errors.isEmpty`, even if warnings exist.

This is a deliberate authoring choice. It enables forward-compatible
workflows:

- a future step `type` can warn today and still load
- a non-fatal authoring smell can be reported without blocking iteration
- the registry can expose warning-bearing definitions instead of silently
  dropping them

The validator currently checks these categories:

| Category | Hard error? | Notes |
|---|---|---|
| required fields | yes | empty names, missing prompts where required |
| duplicate IDs | yes | step IDs and loop IDs must be unique |
| variable references | yes | `{{VAR}}` and context refs must resolve |
| context key consistency | yes | consumers cannot reference keys no earlier step produced |
| gate expressions | yes | malformed expressions fail validation |
| loop references | yes | loop-owned step IDs must exist |
| loop max iterations | yes | must be `> 0` |
| loop overlap | yes | one step cannot belong to multiple loops |
| loop finalizers | yes | finalizer must exist and cannot be loop-owned |
| output config consistency | yes | output declarations must align with context outputs |
| map-over references | yes | `mapOver` must come from a prior step |
| map constraints | yes | map step cannot also be `parallel` |
| multi-prompt provider support | yes | continuity providers are enforced |
| skill references | yes | invalid or incompatible skill refs block loading |
| hybrid-step rules | mixed | some cases warn, some cases error |

The hybrid-step rules are especially important because they document what the
engine is willing to execute:

| Rule | Severity |
|---|---|
| unknown step `type` | error |
| approval step inside a loop | warning |
| approval step marked `parallel` | error |
| `bash` or `approval` with multi-prompt | error |
| `parallel` combined with `continueSession` | error |
| unsupported `onError` value | warning |
| `continueSession` targeting unsupported provider | error |
| `continueSession` with no resolvable target | error |
| `continueSession` targeting non-agent step | error |
| `continueSession` crossing loop boundary | error |
| `continueSession` chain cycle | error |

The warning/error boundary is pragmatic:

- if execution would be ambiguous or unsafe, validation errors
- if execution is coherent but operationally risky, warnings

This is why approval-in-loop is only a warning. It can work, but authors must
ensure the loop exit gate will eventually terminate instead of waiting forever.

## 20. Step Defaults and Effective Configuration

`stepDefaults` provide policy inheritance without turning the workflow model
into a global config language.

The rules are:

1. defaults are matched in author order
2. first matching rule wins
3. defaults are not merged across multiple matches
4. explicit step fields override the matched default field-by-field

The matcher itself is intentionally simple:

- only `*` wildcards
- anchored full-string match
- no `?`
- no `**`
- no character classes

Example:

```yaml
stepDefaults:
  - match: "review-*"
    provider: claude
    model: sonnet
    maxTokens: 12000
  - match: "review-security"
    maxTokens: 20000
```

With first-match-wins semantics:

- `review-code` gets the first rule
- `review-security` also gets the first rule
- the second rule never applies

That behavior is deliberate. It avoids surprising blended configs where authors
must reason about partial overlays from multiple default rules.

The resolved fields today are:

| Field | Resolved by defaults? |
|---|---|
| `provider` | yes |
| `model` | yes |
| `maxTokens` | yes |
| `maxCostUsd` | yes |
| `maxRetries` | yes |
| `allowedTools` | yes |

Other step properties remain explicitly step-local:

- `prompt`
- `skill`
- `mapOver`
- `inputs`
- `outputs`
- `gate`
- `continueSession`

That boundary is important because defaults are for execution policy, not for
control-flow structure.

Operationally, effective step config is resolved right before execution, not
pre-expanded into a different workflow definition. That keeps:

- persisted definitions small
- author intent visible
- runtime logging attributable to the original step ID

## 21. Output and Context Extraction

Context extraction is where workflow execution stops being "run some prompts"
and becomes deterministic orchestration.

The runtime writes automatic metadata itself:

| Key pattern | Meaning |
|---|---|
| `<stepId>.status` | terminal step status |
| `<stepId>.tokenCount` | tokens consumed by that step |
| `_loop.*` | loop bookkeeping |
| `_approval.*` | approval bookkeeping |
| `_map.*` | map iteration bookkeeping |

User-declared outputs are then extracted by `ContextExtractor`. The pipeline drives off `step.outputKeys` (derived directly from the `outputs:` map). For each declared output key, extraction priority is:

1. `OutputConfig.setValue` — literal write (any JSON-encodable value, including `null`); short-circuits all other extraction.
2. `OutputConfig.source` — direct read from task metadata (`worktree.branch`, `worktree.path`).
3. Canonical context defaults (`context_output_defaults.dart`) — `*_source` keys default to `synthesized` for any step that declares them and emits no value (the `existing` branch is gated on `step.id == 'discover-project'`); the `prd`, `plan`, and `story_specs` keys pre-fill from the `project_index` projection only for the `discover-project` step.
4. Per-key resolver from `outputResolverFor` — `FileSystemOutput` (glob over changed files; `format: path`), `InlineOutput` (read from the `<workflow-context>` JSON, then the structured-output payload), `NarrativeOutput` (same priority as inline).
5. Step-level legacy `extraction:` config — first-key path only, kept for backwards compatibility.
6. Empty string with warning.

When `format: json` and `schema` are both present, the parser default is `outputMode: structured` — provider-enforced schema extraction. The inline `<workflow-context>` payload is the happy path for structured outputs: when the last assistant message already contains valid JSON with the required top-level keys, the executor promotes it directly and skips the extra extraction turn. Provider-native schema extraction runs only when the inline payload is missing or malformed.

`schema_presets.dart` declares default glob patterns by output key (e.g. `prd → **/prd.md`, `fis_paths → fis/s*.md`, `review_findings → **/*review*.md`). For ordinary path outputs, a missing claimed file is a hard failure (`MissingArtifactFailure`).

The four-strategy design matters because workflows run across very different
step styles:

- agent-only narrative steps
- coding steps that emit markdown artifacts
- review steps that produce JSON verdicts
- deterministic bash steps that may emit line-oriented output

Per-output configuration is carried in `outputs`:

| Field | Meaning |
|---|---|
| `format` | `text`, `json`, or `lines` |
| `schema` | preset or inline JSON schema |
| `source` | direct source such as `worktree.branch` |

`source` is intentionally narrow today:

| Source | Value |
|---|---|
| `worktree.branch` | persisted task worktree branch |
| `worktree.path` | persisted task worktree path |

If a source is unknown, the extractor warns and falls back to normal
content-based extraction rather than silently dropping the output.

The runtime also supports schema soft validation:

- parse JSON first
- validate against preset or inline schema
- log warnings on mismatch
- keep the parsed object in context anyway

That preserves deterministic downstream access while avoiding false "hard fail"
behavior on useful-but-imperfect model output.

## 22. Gate Evaluation

`GateEvaluator` is a two-level OR-of-AND grammar:

```text
expression ::= andGroup ( '||' andGroup )*
andGroup   ::= condition ( '&&' condition )*
condition  ::= "<key> <operator> <value>"
```

`&&` binds tighter than `||`. Parentheses, NOT, and deeper nesting are not supported.

Supported operators:

| Operator | Meaning |
|---|---|
| `==` | string or numeric equality |
| `!=` | inequality |
| `<` | numeric compare when both sides parse, otherwise lexical compare |
| `>` | numeric compare when both sides parse, otherwise lexical compare |
| `<=` | numeric compare when both sides parse, otherwise lexical compare |
| `>=` | numeric compare when both sides parse, otherwise lexical compare |

Examples:

```text
implement.status == accepted
review.verdict == pass
analysis.tokenCount < 50000
plan.status == accepted && plan.tokenCount < 12000
plan-review.gating_findings_count > 0 || architecture-review.gating_findings_count > 0
```

Null-literal handling: `x == null` matches when the value is empty/missing or the literal string `"null"`. Numeric comparisons against an empty actual value default the actual to `'0'`. Keys may be dotted (`project_index.active_prd`); a stray `context.` prefix is forgiven with a warning.

The evaluator is fail-safe:

- malformed expression -> `false`
- missing context key -> empty string -> usually `false`
- unknown operator -> `false`

This is deliberate. Gates are control-plane conditions. If the runtime cannot
prove a gate passes, it must not continue.

The gate language stops short of a full expression DSL:

- no parentheses
- no function calls
- no arithmetic
- no implicit context traversal beyond the flattened (or dotted) key

This constraint keeps three things true:

1. validation can reason about referenced keys
2. UI and docs can explain gate behavior without ambiguity
3. workflows remain auditable as configuration rather than embedded code

## 23. Loop Execution State Machine

Loops are not special prompts. They are a persisted state machine.

Per loop, the executor owns:

- current iteration number
- current loop ID
- current loop step ID
- exit-gate evaluation point
- optional finalizer dispatch

The lifecycle is:

1. enter loop
2. set `_loop.current.*` metadata
3. execute each loop-owned step in order
4. update context outputs and token counts
5. emit `LoopIterationCompletedEvent`
6. evaluate `exitGate`
7. either terminate or continue
8. if terminated and `finally` exists, run finalizer
9. clear `_loop.current.*` metadata

The persisted state fields matter for recovery:

| Field | Meaning |
|---|---|
| `currentLoopId` | which loop was active |
| `currentLoopIteration` | zero-based iteration cursor |
| `currentLoopStepId` | which step within the loop was active |
| `_loop.current.*` context keys | human-readable recovery metadata |

This enables crash recovery with enough precision to distinguish:

- before first loop step
- mid-iteration
- after iteration completion but before exit-gate decision
- inside finalizer

The loop model also explains why `continueSession` cannot cross loop
boundaries. Session continuity is linear by design. Loop iteration is not.
Allowing continuity to bridge loop ownership would make replay ambiguous:

- which prior iteration owns the session?
- does recovery resume with the same turn chain?
- do later iterations inherit stale context from earlier ones?

The runtime rejects that rather than inventing implicit rules.

---

## File-Based Artifact Contract

Artifact-producing skills (`dartclaw-prd`, `dartclaw-plan`, `dartclaw-spec`) follow a **single-mode file-based contract**: they always write their artifact (PRD, plan, per-story FIS) to disk at the canonical location reported by `dartclaw-discover-project`'s `artifact_locations.*` output, and they always emit the workspace-relative **path** under their `outputs:` block — never inline content. Workflow steps downstream read the file via `file_read`.

**Read-existing branches.** `dartclaw-prd` checks `context.project_index.active_prd`; when the referenced file exists, the skill reuses it and emits `prd: <path>` + `prd_source: "existing"` without synthesizing. Otherwise it synthesizes into `artifact_locations.prd` and emits `prd_source: "synthesized"`. `dartclaw-plan` applies the same pattern to `active_plan` and additionally, per story row, checks the `**FIS**` column: rows whose FIS already exists skip the per-story sub-agent and carry the existing path forward in `story_specs[i].spec_path`; rows whose FIS is missing dispatch the sub-agent pipeline.

**`story_specs` shape.** `story_specs` is an array of **structured per-story records** — not bare paths. Each record carries `{id, title, spec_path, acceptance_criteria, phase, wave, dependencies, key_files}` so existing downstream prompts keep working with `{{map.item.title}}` / `{{map.item.id}}` / `{{map.item.acceptance_criteria}}`. `{{map.item.spec_path}}` is the added field that `dartclaw-exec-spec` uses with `file_read` to load the FIS body.

### Single-step PRD/spec contract

The built-in workflows no longer ship separate review-prd / review-spec steps. `dartclaw-prd` and `dartclaw-spec` are responsible for producing a solid final artifact themselves, while downstream steps consume the emitted path (`prd`, `spec_path`) via `file_read`. `plan-review` remains the aggregate read-only review surface for the multi-story pipeline.

## Generalized `entryGate`

`WorkflowStep.entryGate` is an optional `String?` field that mirrors the semantic established on `WorkflowLoop`: a step whose `entryGate` evaluates false is **skipped** — the executor fires a `StepSkippedEvent`, advances the cursor, and continues. Unlike `step.gate`, a false `entryGate` does **not** pause the run awaiting operator review. The check runs in every step-kind dispatch branch (MapNode, ActionNode, ParallelGroup, loop body, foreach child). Skipping a member of a parallel group filters that member out; the remaining members still run.

`GateEvaluator` recognizes `== null` / `!= null` as literal comparisons: missing keys and empty-string values are considered null; the literal string `"null"` also matches null. Numeric-empty-→-0 fallback remains in effect for relational operators.

Validator acceptance is permissive: bare-key (`prd_source == synthesized`), dotted (`plan-review.findings_count > 0`), and chained-with-`&&` forms are all accepted, matching the runtime evaluator.
The resolver preserves authored `entryGate` fields when emitting resolved YAML, so `workflow show --resolved` round-trips without silently dropping skip semantics.

## Artifact Auto-Commit + External Mount

`gitStrategy.artifacts` adds a commit hook that runs automatically after any step that produced path-shaped outputs:

```yaml
gitStrategy:
  integrationBranch: true
  worktree: auto
  artifacts:
    commit: true                                 # default: true iff ≥1 artifact-producing step
    commitMessage: "chore(workflow): artifacts for run {{runId}}"
    project: "{{PROJECT}}"                       # working tree receiving the commit
```

Defaulting truth table:

| Workflow contents | `worktree` | Default `commit` | `commit: false` allowed? |
|---|---|---|---|
| ≥1 artifact-producing step | `per-map-item` | `true` | **No** — validator error |
| ≥1 artifact-producing step | `shared` | `true` | Warning only |
| ≥1 artifact-producing step | `inline` / absent | `true` | Yes |
| No artifact-producing step | any | `false` | Yes (no-op) |

**Hook ordering.** The commit fires after the producing step completes and before any subsequent step. For `plan-and-implement`, this means the plan step's FIS files land on the workflow branch **before** `story-pipeline` creates per-map-item worktrees, so the worktrees inherit the committed files through the normal `git worktree add` path.

### Step Project Resolution (ADR-024)

Workflow definitions can declare a single top-level `project:` field. The executor resolves project binding in this order:

1. Workflow-level `project:` for steps that the engine recognizes as project-bound.
2. `null` for project-agnostic steps.

This keeps the authoring surface focused on workflow structure instead of repeating `project: '{{PROJECT}}'` on every mutating step.

Important distinctions:

- `Task.projectId` is the persisted task-system field used to resolve the target project checkout.
- `workflow project` is the authoring concept declared on `WorkflowDefinition.project`.
- Workflow-created tasks always persist as `TaskType.coding`; workflow step type no longer flows through task-system bookkeeping.
- Workflow-owned review is structural, not task-level. Workflow tasks auto-accept on turn completion; approval/review steps are the way to model human checkpoints in authored workflow structure.

**Cross-clone mount.** Split-repo workflows declare `gitStrategy.worktree.externalArtifactMount` to carry artifact files from the planning-repo workflow branch into each per-map-item worktree of the code repo:

```yaml
gitStrategy:
  artifacts:
    project: "{{DOC_PROJECT}}"
  worktree:
    mode: per-map-item
    externalArtifactMount:
      mode: per-story-copy                        # default: least-privilege
      fromProject: "{{DOC_PROJECT}}"
      source: "{{map.item.spec_path}}"            # resolved per iteration
```

- `mode: per-story-copy` (shipped default): at per-map-item worktree creation the engine resolves `source` against the current `map.item.*` to a workspace-relative path, then copies **only that one file** from `fromProject` into the worktree at the same relative path — `file_read({{map.item.spec_path}})` resolves correctly in both workspaces without any context rewriting.
- `mode: bind-mount` (opt-in, requires README justification): bind-mounts the whole directory read-only into each worktree; every worktree can read every sibling's FIS. Intended for debugging / cross-story references.

The copy runs in the task executor after worktree creation but before the agent turn starts, so the skill inside the task sees the file on its first read.

# Workflow Architecture

Canonical deep-dive for DartClaw's workflow engine: definition model and parser contract, step outcome protocol, execution lifecycle, crash recovery, validation semantics, loop state machine, design lineage, and how the engine relates to task execution.

**Current through**: 0.21 (native Windows Git Bash policy plus embedded workflow assets)

---

## Audience & Scope

This is the **contributor reference**. It documents how the workflow engine is built, why it is structured the way it is, and the invariants that keep it deterministic. Use it when modifying the parser, validator, executor, or context flow — or when writing tests against any of those.

For **authoring workflows** (YAML field reference, step types in practice, examples of `mapOver`, `foreach`, loops, gates, multi-prompt, approval flow, trigger surfaces, CLI usage), read [`docs/guide/workflows.md`](../../docs/guide/workflows.md) — that is the user-facing canonical reference. This document deliberately avoids duplicating that material; sections below that overlap point back to the guide.

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

- `packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart` — definition model, step model, loop model
- `packages/dartclaw_workflow/lib/src/workflow/workflow_run.dart` — run state model
- `packages/dartclaw_workflow/lib/src/workflow/` — parser, validator, executor, context extractor, template engine, runtime skill preflight, schema validation, filesystem-backed workflow definitions and skills
- `packages/dartclaw_server/lib/src/api/workflow_routes.dart` — HTTP API endpoints
- `apps/dartclaw_cli/lib/src/commands/workflow/` — CLI commands

The public-facing companion guide is [workflows.md](../../docs/guide/workflows.md).
This architecture builds on the multi-provider harness boundary established in ADR-016 (private repo).

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

A workflow is intentionally only four things: **metadata, variables, steps, loops**. That keeps the authoring surface area proportional to what the executor can actually enforce.

The typed model lives in `dartclaw_workflow`, not the server or CLI. That layering decision matters:

- parser and validator operate on shared typed models
- CLI validation uses the same structures as the server runtime
- execution can be tested without pulling in HTTP concerns
- storage serializes model state without re-parsing YAML

The important types are:

| Type | Purpose |
|---|---|
| `WorkflowDefinition` | Top-level workflow schema |
| `WorkflowVariable` | Input variable declaration with optional default |
| `WorkflowStep` | A single step in the pipeline |
| `WorkflowLoop` | Repeating subset of steps with an exit gate |
| `StepConfigDefault` | Glob-based per-step defaults |
| `OutputConfig` | Output extraction and validation metadata |
| `WorkflowRun` | Runtime state for a run |
| `WorkflowRunStatus` | Run lifecycle state |

The model deliberately keeps string-based fields where the workflow authoring surface needs flexibility. The runtime then validates and normalizes those strings before execution.

### Top-Level Shape

```yaml
name: spec-and-implement
description: Write a specification, implement it, and run integrated review.
variables:
  FEATURE:
    required: true
steps:
  - id: detect-spec-input
    name: Detect Spec Input
    skill: dartclaw-discover-andthen-spec
    workflowVariables: [FEATURE]
    outputs:
      spec_path: detected_fis_path
      spec_source: spec_source
  - id: spec
    name: Generate Specification
    skill: andthen:spec
    entryGate: "spec_source == synthesized"
    workflowVariables: [FEATURE]
    outputs:
      spec_path: fis_path
      spec_source: spec_source
```

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

Two details matter:

- the runtime executes by `id`, not by display `name`
- context edges are explicit; steps do not implicitly see prior outputs

The definition model encodes 0.16-era capabilities directly on the step object:

| Step field | Purpose |
|---|---|
| `type` | structural execution mode: omitted/`agent`, `bash`, `approval`, `foreach`, or `loop` |
| `skill` | provider-native skill reference |
| `parallel` | marks a step as part of a linear parallel group |
| `gate` | pre-step boolean condition against workflow context |
| `entryGate` | step-level skip-when-false gate |
| `inputs` | named context keys supplied to the step prompt |
| `outputs` | canonical per-key output configuration (`format`/`schema`/`source`/`outputMode`/`description`/`setValue`) — the map's keys are the step's context-write set |
| `mapOver` | collection key for fan-out execution |
| `maxParallel` | per-map concurrency cap |
| `maxItems` | map item ceiling (opt-in; omitted means uncapped) |
| `continueSession` | session continuity target |
| `onFailure` | `fail` (default), `continue`, `retry`, or `pause` — modern step failure policy (drives workflow-owned retry budget handling for any step type) |
| `onError` | legacy `pause` / `continue` / `fail` — still honored by the executor and loop runner for any step type when set; primarily used by bash steps. `onFailure` is the preferred field for new authoring |
| `provider` / `model` / `effort` | explicit provider, model, or reasoning-effort override |
| `auto_frame_context` | bool, default `true` — opt out of auto-XML-framing of `inputs:` / `workflow_variables:` |
| `emitsOwnOutcome` | bool, default `false` — skip the `<step-outcome>` framing append |
| `maxTokens` | step-level token budget |
| `allowedTools` | tool allowlist override |
| `workdir` | step working directory override |

Loops remain a separate object in the serialized model for backward compatibility, but runtime traversal treats them as ordered nodes:

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

The consequence: a workflow definition is declarative enough to be validated statically, but concrete enough that the runtime never has to infer author intent from prompt text.

### Schema (S66/S67): `outputs:` and `setValue`

- **`outputs:` is the only declaration of context-write keys.** The parser treats `outputs:` map keys as the source of truth for the context-write set. `WorkflowStep.outputKeys` derives directly from `outputs?.keys`. Foreach / `mapOver` controllers parse `outputs:` through the same path as every other step and emit one aggregate value, so the controller's `outputs:` map must declare exactly one key. The parser throws a `FormatException` with a one-line migration message if the legacy `contextOutputs:` field appears anywhere in the YAML — `contextOutputs: is removed; declare keys under outputs: instead, e.g. outputs: { key_name: text }` — so authors get an immediate cue rather than a silent warning.
- **`OutputConfig.setValue` writes a static literal.** When an output entry declares `setValue:` (any JSON-encodable literal, including `null`), the executor short-circuits extraction for that key and writes the literal verbatim on step success. The slot is sentinel-backed (`_workflowDefinitionFieldUnset`) so absence and explicit `null` round-trip distinctly through `toJson` / `fromJson`. It fires only on success — failure and `entryGate` skip leave context untouched. Snake_case alias `set_value` is accepted alongside the camelCase form.
- **Validator alias-awareness for `continueSession` and multi-prompt.** Role-aliased providers (`@executor`, `@reviewer`, `@planner`, `@workflow`, …) are skipped by the continuity-provider check in both `_validateMultiPromptProviders` and the `continueSession` block. The runtime fallback in `WorkflowExecutor._resolveContinueSessionProvider` continues to detect family mismatches at execution time (warning + re-route to the root provider). Concrete provider names with no continuity support still produce `unsupportedProviderCapability` errors. Resolving role aliases during validation remains deferred until the validator receives the workflow's roles config.

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

Bash steps run on the host side through an env-sanitized `SafeProcess` spawn. POSIX uses `/bin/sh`; native Windows
resolves Git Bash through `PlatformCapabilities.bashShellPolicy` and its ordered executable candidates, then runs
`bash.exe -c`. Missing Git Bash
produces a structured failed step with `bash steps require Git Bash on Windows`; it never becomes an empty success.
They are used for deterministic operations where an LLM would only add noise — extracting diffs, running validators,
calling CLI tools.

Execution semantics:

| Concern | Behavior |
|---|---|
| Task creation | None. Bash steps are zero-task, zero-token |
| Working directory | Explicit `workdir` field (template-resolved), or `<dataDir>/workspace/` default |
| Template substitution | `{{context.*}}` and `{{VAR}}` values are shell-escaped for unquoted ordinary arguments; caller quoting, `eval`, and direct nested `sh`/`bash` are rejected, while trusted workflow definitions remain responsible for not routing data into other interpreters |
| Child processes | Background jobs remain part of the step and are awaited or cleaned up when observed; detached/daemonized services are unsupported |
| Timeout | `step.timeoutSeconds` (default 60s). POSIX terminates the observed tree with SIGTERM then SIGKILL after 2s. Windows hard-terminates a still-running direct root and never retargets an exited PID; uncontained descendants may continue. If cleanup cannot be confirmed, later Bash steps stay blocked until DartClaw restarts |
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

Review report path outputs remain durable even when the review is clean. If a zero-finding review omits the report path or claims a missing path under the runtime-artifacts directory, the context extractor materializes a diagnostic clean-review markdown file there and records that path in context.

**Review output-key naming convention.** A parallel review step that feeds an `aggregate-reviews` step prefixes **all** its output keys with its own step id: `<stepId>.review_report_path` (the report path), `<stepId>.findings_count`, and `<stepId>.gating_findings_count`. Prefixing avoids context-key collisions between concurrent review branches and is always safe because the host accepts the review skill's bare-suffix emission (`review_report_path`) for the prefixed output via the filesystem-claim alias (`context_extractor.dart _fileSystemClaimKey`) — mirroring the dual-key acceptance already used for counts. The aggregator derives each source's report key from the step's `outputs:` declaration (format `path` + `review_report_path` preset, via `reviewReportPathOutputKey`), so it consumes the prefixed keys without re-deriving names. The `aggregate-reviews` step's **own** outputs stay bare (`review_report_path`/`findings_count`/`gating_findings_count`) — the canonical post-aggregate keys the validator requires and the remediation loop + `re-review` read and overwrite. A single-review workflow with no aggregator (`code-review.yaml`) keeps the bare canonical keys directly, since there is no sibling step to collide with. The convention is enforced by `validation/workflow_review_source_prefix_rules.dart` (a bare/mis-prefixed review key on an aggregate source is a validation error) and contract-locked in `built_in_workflow_contracts_test.dart`. The prior key name `review_findings` is retired — the parser rejects it, naming `review_report_path`.

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

`WorkflowRunStatus` distinguishes operator holds from failure states:

- `paused` means an operator deliberately paused the run.
- `awaitingApproval` means the run is blocked on an approval gate or a step-reported `needsInput` outcome that did not opt into `onFailure: continue`.
- `failed` means the run hit a runtime, gate, or step failure and is eligible for explicit retry.

Only `completed`, `failed`, and `cancelled` are terminal lifecycle states. This keeps dashboards, SSE subscribers, and CLI exit codes aligned with operator intent instead of conflating "waiting on a human" with "something broke".

### 4.2.2 Step Outcome Protocol

Workflow-owned agent steps whose declared outputs need model-derived values resolve their outcome from the `step_outcome` object of the structured execution envelope (Section 4.4a) — the engine-owned `outcome`/`reason` pair rides alongside the step's declared `outputs` in that same no-tools finalizer turn. `step_outcome` is omitted from the envelope when the step opts out with `emitsOwnOutcome: true`.

Outcome-only steps (no model-derived declared outputs) skip the finalizer turn entirely and keep the cheap inline tag as their designed channel — the agent ends its final assistant message with:

```text
<step-outcome>{"outcome":"succeeded|failed|needsInput","reason":"..."}</step-outcome>
```

The executor appends this contract automatically unless the step or referenced skill opts out with `emitsOwnOutcome: true`. The same inline tag also remains a compatibility **fallback** for finalizer-eligible steps — old transcripts, custom workflows, `outputMode: prompt` opt-out steps, and failed-finalization cases — but is no longer the standard extraction path for them.

Runtime handling (envelope `step_outcome` first, inline tag as fallback):

- `succeeded` records `step.<id>.outcome = "succeeded"` and continues normally.
- `failed` records the semantic outcome and applies `onFailure` (`fail`, `continue`, `retry`, `pause`).
- `needsInput` transitions the run to `awaitingApproval` by default, reusing the same `_approval.*` metadata shape as an explicit approval step. `onFailure: continue` is the explicit best-effort policy for advisory/cleanup steps that should record the `needsInput` reason and advance.
- Missing envelope/tags fall back to lifecycle status (`accepted -> succeeded`, `failed/cancelled -> failed`), emit a warning log, and increment the `workflow.outcome.fallback` counter — except a missing/malformed envelope on a finalizer-required step, which is a workflow validation failure eligible for the existing retry path rather than a silent lifecycle fallback.

The older `<stepId>.status` keys remain as lifecycle metadata. Outcome is additive rather than a replacement, so existing gates keep working while authors can now write semantic gates such as `step.review.outcome != failed`.

Workflow `onFailure: retry` is the single retry authority for workflow-spawned tasks. `maxRetries: N` means at most `N + 1` workflow task attempts across single steps, map items, and foreach child steps. The workflow-owned retry budget covers failed tasks, failed `<step-outcome>` envelopes, post-task validation failures, and missing declared artifacts. Retry attempts receive the previous workflow-validation failure in the next prompt so the agent can repair missing files or malformed outputs instead of repeating the same response. The helper stops early when consecutive failures normalize to the same error class, preserving the deterministic-failure guard without reintroducing task-runtime retry.

The task-runtime retry path remains in `dartclaw_server` for non-workflow tasks. Workflow task creation persists `Task.maxRetries == 0`, so workflow retry cannot multiply with task-runtime retry and server retry code stays uncoupled from workflow outcome semantics.

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
- The task/session transcript is still recorded in DartClaw's own session store.
- Workflow tasks set `task.type = TaskType.coding` uniformly; workflow step type no longer flows through task-system bookkeeping.
- Workflow step read-only behavior is derived from effective `allowedTools` via `step_config_policy.stepIsReadOnly`, and the mutation check runs against the provisioned worktree path when present.
- `format: json` with `schema` defaults to provider-enforced structured output. Explicit `outputMode: prompt` is the opt-out; heuristic extraction remains only as a fallback when the structured payload is missing.
- For finalizer-eligible steps (workflow-owned agent steps whose declared outputs need model claims), the standard completion path is a dedicated no-tools structured finalization turn after the main work turn: the provider emits a strict execution envelope `{ "outputs": { ... }, "step_outcome": { ... } }` (`step_outcome` omitted when `emitsOwnOutcome: true`). This finalizer turn runs even when the main turn's last assistant message also contains a legacy inline `<workflow-context>` block — the envelope is authoritative, not the inline text. Legacy inline `<workflow-context>` / `<step-outcome>` parsing remains a compatibility **fallback** (old transcripts, custom workflows, `outputMode: prompt` opt-out steps, finalizer failures), not the happy path.

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

Each iteration runs its substeps in declared order. Substeps share a per-iteration context overlay: each substep's outputs are written into the overlay under the keys declared in its `outputs:` block (bare keys), so later sibling substeps read them directly — e.g. `quick-review` reads `{{context.story_result}}` produced by `implement`. There is no automatic step-id prefixing in the overlay; if a substep needs to expose its output under a `<stepId>.<key>` form (for disambiguation when two substeps emit the same generic key), it must declare that prefixed key explicitly in its own `outputs:` block. The per-iteration overlay is isolated from the plan-level context during execution; results are aggregated back after all items complete, keyed by child step id. See the user guide's [Step-Prefixed References](../../docs/guide/workflows.md#step-prefixed-references-contextstepidkey) section for the full reference-form grammar.

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

When collection items declare `id` and `dependencies` fields, the `DependencyGraph` enforces ordering:

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
3. Canonical context defaults — `*_source` keys default to `synthesized` for any step that emits them blank (see `context_output_defaults.dart`)
4. Per-key resolver — `FileSystemOutput` (path glob), `InlineOutput` (envelope-first, then legacy `<workflow-context>` JSON / structured-output payload; `resolver: narrative` is a parser-known alias)
5. Empty string with warning

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

Budgeting exists at two levels:

- workflow-level `maxTokens`
- step-level `maxTokens`

`stepDefaults` applies glob-matched defaults before per-step overrides. The first match wins.

```yaml
stepDefaults:
  - match: "review*"
    maxTokens: 20000
  - match: "*"
    maxTokens: 40000
```

This keeps expensive reviewer steps bounded without repeating the same configuration on every step.

## 11. Skill-Aware Steps and Runtime Preflight

The skill system plugs into workflow authoring through the `skill:` field and runtime provider introspection:

- `WorkflowDefinitionValidator` checks step shape, but does not reject unknown skill names at YAML load time.
- `WorkflowExecutor` collects reachable authored skill refs, including nested workflow nodes and synthetic merge-resolve steps, before dispatching the first step.
- `SkillIntrospector.listAvailable()` probes the effective provider's visible skill list once per provider/executable pair for that run.
- `workflow_skill_preflight.dart` compares authored refs against the provider-visible names and records aliases when a provider exposes a different invocation name, such as Codex `andthen-review` for authored `andthen:review`.
- Missing refs fail with `WorkflowPreflightException` before any workflow step dispatches.

When a step declares `skill:`, the `SkillPromptBuilder` handles four prompt construction cases:

| Case | Prompt shape |
|---|---|
| skill + prompt | `"Use the '<skill>' skill.\n\n<resolved prompt>"` |
| skill + no prompt | skill activation line plus a markdown input summary when inputs exist, otherwise the activation line alone |
| no skill + prompt | passthrough (resolved prompt unchanged) |
| no skill + no prompt | rejected by validator |

After construction, the `PromptAugmenter` appends schema-driven output format instructions if the step declares outputs with a `schema` field (Section 11.1).

### No Skill Frontmatter Workflow Defaults

`SKILL.md` frontmatter is provider-owned skill metadata, not workflow configuration. DartClaw does not parse third-party skill files and does not consume a `workflow:` frontmatter block for `default_prompt`, `default_outputs`, or outcome protocol defaults.

Workflow prompts and output schemas are authored directly in workflow YAML. Skill-only steps remain valid: when a step omits `prompt:`, `SkillPromptBuilder` emits the provider-native activation line and either appends a markdown summary of declared inputs or lets workflow variables auto-frame at the tail. The provider loads the skill body through its own native skill mechanism.

DartClaw ships four DC-native workflow skills as package assets: `dartclaw-discover-andthen-spec`, `dartclaw-discover-andthen-plan`, `dartclaw-validate-workflow`, and `dartclaw-merge-resolve`. The canonical inventory is `packages/dartclaw_workflow/skills/dartclaw-native-skills.txt`, colocated with the package-root skill payloads rather than embedded in engine `.dart`.

#### Skill-Resolution Model (ADR-040)

DartClaw does not clone AndThen, run its installer, or create a `dartclaw-*` branded copy (the earlier clone + `install-skills.sh` model was retired in 0.17 as the SP-1/SP-2 security remediation — see ADR-040). AndThen is an **operator-installed prerequisite** for whichever provider runs the workflow.

- **AndThen-derived skills** are referenced in workflow YAML by canonical logical name (`andthen:spec`, `andthen:review`, …) and resolved at workflow-load time to the provider-native name: Claude Code → `andthen:spec` (plugin namespace), Codex → `andthen-spec` (hyphenated directory), unknown providers → the authored name verbatim. A missing skill is surfaced at run preflight by the harness-introspection probe (ADR-026), not by a filesystem scan.
- **DC-native skills only** are copied by `SkillProvisioner` at `dartclaw serve` startup and before `dartclaw workflow run --standalone`: the manifest-listed package-root skill payloads go into `<dataDir>/.agents/skills/` (Codex) and `<dataDir>/.claude/skills/` (Claude Code), with configured project workspaces receiving links or managed fallback copies for those directories only. There is no git-subprocess, cached-source, or `andthen.git_url`/`ref`/`network` path; those legacy config keys are ignored with warnings.

See [`025-andthen-as-runtime-prerequisite.md`](../adrs/025-andthen-as-runtime-prerequisite.md) for the original runtime-prerequisite decision, [`040-andthen-skills-via-canonical-name-resolution.md`](../adrs/040-andthen-skills-via-canonical-name-resolution.md) for the current resolution model, and [`../../docs/guide/andthen-skills.md`](../../docs/guide/andthen-skills.md) for operator usage.

### Auto-Framed Context Inputs

`SkillPromptBuilder.build` runs an auto-frame pass between the resolved-prompt assembly and `PromptAugmenter.augment`:

1. Determine the tag name as `key.replaceAll('.', '_')`.
2. Skip the key if `<tagName` already appears in the resolved prompt (case-sensitive, prefix-only so XML attributes don't defeat it).
3. Skip the key if `{{context.key}}` / `{{context.tagName}}` (inputs) or `{{KEY}}` / `{{tagName}}` (variables) appears in the template prompt (pre-substitution form — required for correct detection when the substitution has already happened).
4. Otherwise append `\n\n<tagName>\n{resolved value}\n</tagName>`; null/empty values render as `_(empty)_` per the existing `formatContextSummary` convention.

`WorkflowStep.autoFrameContext` (YAML key `auto_frame_context`, default `true`) opts the step out. The shipped built-in workflows intentionally lean on this mechanism for boilerplate-free step authoring: generic prompt wrappers such as manual `Branch:` lines or duplicated `file_read` reminders are omitted from YAML when explicit step prompts and auto-framed inputs already carry the same information.

### Resolved Workflow Observability

`WorkflowDefinitionResolver` converts a `WorkflowDefinition` into a round-trippable, fully-merged form:

- `stepDefaults` patterns applied to each step (first match wins; explicit step fields take precedence).
- Workflow-level `{{VAR}}` bindings substituted in step prompts when bindings are supplied; unbound references and `{{context.*}}` references stay intact.
- `stepDefaults` is removed from the emitted definition (already baked into steps) and `nodes` is recomputed via `normalizeNodes`.

The resolver emits YAML via a minimal hand-rolled block-style emitter that the parser accepts unchanged — every built-in workflow round-trips through `resolve → emitYaml → parse` with step-id equivalence (asserted in `workflow_definition_resolver_test.dart`). Foreach `as: <alias>` (`WorkflowStep.mapAlias`) is preserved through `_resolveStep` so resolved-view output matches authored YAML (S78); this affects only `workflow show --resolved` fidelity, not runtime execution (the executor reads the parsed step directly).

The resolver is surfaced through two gates:

- `GET /api/workflows/definitions/<name>` returns the authored YAML (`application/yaml`).
- `GET /api/workflows/definitions/<name>?resolve=true[&step=<id>]` returns the resolved YAML (`application/yaml`). With `step=<id>`, the response is a single-step fragment (404 if the step id is unknown).
- `dartclaw workflow show <name> [--resolved] [--step <id>] [--json] [--standalone]` is the CLI surface. Connected mode calls the route; standalone mode loads the definition through `buildWorkflowRegistry()` and runs the resolver locally. `--json` wraps the YAML body in `{"yaml": "..."}` for scripting.

### 11.1 Schema Presets and Validation

**Output-contract invariant (ADR-041).** The engine validates a step's output using exactly two framework-neutral mechanisms:

1. **Declared output schema** — types, required fields, enums, object shape — via `schema:` presets or inline JSON Schema (see presets table below). Applied as a soft schema check; the agent's payload is kept in context even on mismatch.
2. **Generic `format: path` trust-boundary validation** — workspace-relative containment, existence, argument-safe characters, symlink-aware escape rejection — applied uniformly to every path output from any skill, never gated on the skill name. When no active workspace root resolves, the validator performs containment-only and skips the existence check (ADR-041 §Open edge case: no active workspace root).

Everything framework-specific is the skill's responsibility: status normalization, resume-filter logic, dependency pruning, cross-field consistency, empty-plan handling. The engine does not re-validate AndThen artifact schemas (`plan.json` structure, FIS markers, `spec_source` semantics, status vocabulary). Skills emit a final, clean structured payload; the engine trusts it. Skip/resume decisions are expressed as workflow-YAML `entryGate` / `gate` expressions reading the skill's structured output — not re-derived in Dart.

A CI fitness gate (`dev/tools/fitness/check_no_framework_coupling.sh`) enforces this invariant by asserting zero `andthen` / `dartclaw-discover-andthen` literals (case-insensitive) in `packages/dartclaw_workflow/lib/src/`, excluding only `definitions/*.yaml`. Package-root `skills/` payloads are outside the scan scope, but `lib/src/skills` engine code is scanned. This is governance level 2, sibling to `dev/tools/arch_check.dart` (ADR-033, ADR-041).

The engine ships built-in schema presets (registered in `schema_presets.dart`) that workflow authors can reference by name instead of writing inline JSON Schema:

| Preset | Purpose |
|---|---|
| `verdict` | Review output with pass/fail, `findings_count`, `findings[]`, `summary` |
| `remediation_result` | Outcome of a remediation pass (changes applied, status, follow-ups) |
| `remediation_summary` | Aggregate remediation summary for loop gates |
| `story_specs` | Array of per-story spec records with `spec_path` for `file_read` consumption |
| `story_result` | Result record for a single story executed via `ForeachNode` |
| `non_negative_integer` | Scalar guard used for counts such as `findings_count` |
| `diff_summary` | Structured diff summary for code-review flows |
| `validation_summary` | Structured validator output (errors, warnings) |

Usage in a workflow definition:

```yaml
outputs:
  verdict:
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
- `currentStepIndex` and the persisted `executionCursor` (`WorkflowExecutionCursor`) identify the resume point.
- Loop, approval, and parallel-group metadata are encoded into context so resume can restore the correct state.

On server restart, `WorkflowService.recoverIncompleteRuns()` handles two categories:

- **Running runs**: Automatically resumed. The executor finds the last completed step (via child task inspection) and re-executes from there. Mid-loop runs resume from the persisted loop iteration and step ID.
- **Awaiting-approval runs with approval timeouts**: Timeout timers are rehydrated. If the deadline has already passed, the approval is expired immediately.

Parallel group resume uses `_parallel.failed.stepIds` in contextJson: when a group had failures, the next resume re-runs only the failed steps (not the entire group), then merges their results with the previously successful steps.

`WorkflowSerializationEnactedEvent` is fire-exactly-once across crash + resume for any given `(runId, foreachStepId)` pair (S78). The merge-resolve serialize-remaining path persists the typed `_merge_resolve.serializeRemaining` state with `eventEmitted: true` immediately after the event fires, before in-flight siblings finish settling, so a server crash mid-settle cannot re-fire the event on resume. The terminal `phase: 'drained'` marker on the same typed object remains the serial-retry-consumed persistence point.

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

The workflow↔task import boundary is mechanically enforced by a fitness test at [`packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart`](../../packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart).

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

The runtime embeds four DC-native `dartclaw-*` skills:
`dartclaw-discover-andthen-spec`,
`dartclaw-discover-andthen-plan`, `dartclaw-validate-workflow`, and
`dartclaw-merge-resolve`. At startup, `SkillProvisioner` (see §11) copies those
skills into the native user-tier harness roots. Workflow execution then checks
authored refs against the provider-visible skill list during runtime preflight;
there is no DartClaw skill-discovery registry in the execution path.

The built-in workflow definitions are embedded and materialized into
`<dataDir>/workflows/built-in/` on startup (`WorkflowMaterializer.builtInDir(dataDir)`).
Source-checkout YAML wins before the embedded fallback so maintainer edits remain live. `WorkflowMaterializer` writes
each shipped definition with a sibling `.dartclaw-managed.json` fingerprint
file — a 16-hex-char FNV-1a 64-bit hash of the source content (cheap drift
detector, not a cryptographic integrity proof). On re-materialization the
source-vs-fingerprint comparison decides the outcome: source matches fingerprint ⇒ skip;
destination modified locally (fingerprint drift) ⇒ preserve the local edit and
warn; source removed from the active built-in set ⇒ delete only when destination is
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

**Subdirectory ownership.** The engine owns and pre-creates only two
runtime-artifacts subdirectories: `reviews/` (via `_initializeRuntimeArtifactsDir`)
and `merge-resolve/` (via `workflowMergeResolveAttemptsDir`). Any other consumer
— a custom workflow step writing to
`{{workflow.runtime_artifacts_dir}}/screenshots`, `/architecture`, etc. — must
create its own subdirectory; the engine never pre-creates it. If a custom
`format: path` claim names a file under a non-engine subdir that does not exist,
resolution surfaces a `MissingArtifactFailure` rather than silently substituting
an unrelated dirty worktree file (the clean-review fallback is review-only).

**Tie-break between worktree and runtime-artifacts roots.** When the same
relative name resolves under both the worktree and the runtime-artifacts roots,
the worktree copy wins by default. The runtime-artifacts root is tried *first*
only for review-artifact path outputs (those for which
`review_artifact_policy.isReviewArtifactPathOutput` is true, i.e.
`preserveRuntimeArtifactsRoot`). This review-only precedence is load-bearing in
the maintainer profile, where `.dartclaw/` is nested inside the checkout so a
review claim is also within the worktree root; without it the claim would
resolve worktree-relative, be gitignored, and drop to the worktree diff. The
worktree-first default for non-review keys is intentional and must not be
globalized.

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

The listing surfaces intentionally use summary projections, not full prompt bodies. Full definitions load only when execution or detail display needs them.

### 15.1 Trigger Surfaces

Workflows can currently be triggered from six surfaces:

| Surface | Entry point | Notes |
|---|---|---|
| HTTP API | `POST /api/workflows/run` | Accepts `{definition, variables, project}`. Returns the created `WorkflowRun` |
| Web UI launch form | `POST /api/workflows/run-form` from `/workflows` | HTMX form launch. Validates required variables inline and redirects with `HX-Location: /workflows/<runId>` |
| Web chat command | `POST /api/sessions/<id>/send` with `/workflow list` or `/workflow run <name> KEY=value` | `ChatCommandHandler` intercepts the message before a normal turn is created, returns an HTML card, and deduplicates repeated commands for 30 seconds. `/workflow list` is broadly available; `/workflow run` is advertised and accepted only when the request carries admin permission |
| GitHub webhook | `POST /webhook/github` | `GitHubWebhookHandler` verifies HMAC-SHA256 signatures, maps PR metadata into workflow variables, and deduplicates active runs for the same workflow + PR + repo |
| CLI connected mode | `dartclaw workflow run <name> -v KEY=VALUE` | Default mode in 0.16.4. Calls `POST /api/workflows/run`, then streams `/api/workflows/runs/<id>/events` over SSE. Exit codes: 0=completed, 1=failed, 2=paused/awaitingApproval/cancelled |
| CLI standalone mode | `dartclaw workflow run <name> --standalone [--force]` | Explicit local fallback via `CliWorkflowWiring`. Probes `/health` first and aborts unless `--force` is set when a server is already running. Passes `headless: true` so review steps auto-accept |

All server-managed trigger surfaces converge on `WorkflowService.start()`: the HTTP API, HTMX launch form, chat command interceptor, and GitHub webhook handler all resolve a `WorkflowDefinition` and hand it to the same service. The connected CLI path is therefore an API client over the same server-owned lifecycle rather than a separate executor path.

The standalone CLI path still exists for serverless or CI use. `WorkflowRunCommand` wires a minimal local service stack via `CliWorkflowWiring` — database, event bus, harness pool, and workflow executor — without starting the HTTP server, then calls `WorkflowService.start(..., headless: true)` directly.

The web UI now exposes both workflow management and launch at `/workflows`, and run detail at `/workflows/<runId>` with real-time SSE updates.

The GitHub webhook surface is intentionally workflow-scoped rather than a general-purpose ingress: configured triggers match event/action/label combinations and currently target built-in workflows such as `code-review`.

### 15.2 CLI Commands

The `dartclaw workflow` parent command provides eleven subcommands:

| Command | Purpose |
|---|---|
| `workflow list` | Lists available workflow definitions with summary metadata |
| `workflow cleanup-skills` | Removes DartClaw-managed workflow skill links from project workspaces |
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
| `workflow_step_completed` | Step result with token count and task ID, plus additive `outcome`/`reason` (present only when the executor recorded a semantic outcome — e.g. `failed`/`needsInput` with an operator-facing reason) |
| `parallel_group_completed` | Group summary with success/failure counts |
| `loop_iteration_completed` | Iteration number, max iterations, gate result |
| `map_iteration_completed` | Per-item fan-out result with token count, plus additive `outcome`/`reason` when recorded |
| `map_step_completed` | Fan-out aggregate with success/failure/cancelled/`blockedCount` and total tokens |
| `task_status_changed` | Child task status transitions |
| `approval_requested` | Approval step metadata (message, timeout) |
| `approval_resolved` | Approval outcome (approved/rejected with feedback) |

The web UI detail page subscribes to this stream for live progress updates.

## 16. Design Lineage

The workflow engine grew from a deterministic sequential runner into the current model: sequential steps and parallel groups, loops with exit gates, `foreach` per-item sub-pipelines, multi-prompt steps with provider-native session continuity, approval and bash steps, and YAML-declared orchestration for the built-in workflows. Per-release detail lives in [`CHANGELOG.md`](../../CHANGELOG.md).

The important design boundary is unchanged: the host owns orchestration, the provider owns reasoning, and the workflow model keeps those responsibilities explicit.

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
3. Canonical context defaults (`context_output_defaults.dart`) — `*_source` keys default to `synthesized` for any step that declares them and emits no value.
4. Per-key resolver from `outputResolverFor` — `FileSystemOutput` (glob over changed files; `format: path`) or `InlineOutput` (envelope-first: reads the finalizer envelope's `outputs` object first, falling back to the legacy `<workflow-context>` JSON or structured-output payload only when no envelope value is present). The legacy `resolver: narrative` keyword remains a parser-known alias for inline extraction.
5. Empty string with warning (legacy/opt-out steps only).

When `format: json` and `schema` are both present, the parser default is `outputMode: structured` — provider-enforced schema extraction. For finalizer-eligible steps the standard path reads `structuredOutput.outputs` from the no-tools execution-envelope turn (Section 4.4a); the legacy inline `<workflow-context>` payload is retained only as a compatibility fallback when the envelope is missing or malformed. File and path values extracted this way are still claims: `FileSystemOutput` validation (existence, containment, argument safety, review-artifact runtime-root precedence) runs after finalization, so a claimed `succeeded` `step_outcome` cannot bypass a missing required artifact — the step becomes a workflow validation failure eligible for the existing retry path instead.

Path-output glob resolution is name-agnostic: a `format: path` output that declares no `pathPattern:`/preset falls back to the uniform `**/*` glob (list mode for a path-list). Declare `pathPattern:` inline to infer filesystem resolution and narrow the match. For ordinary path outputs, a missing claimed file is a hard failure (`MissingArtifactFailure`).

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

Null-literal handling: `x == null` matches when the value is empty/missing or the literal string `"null"`. Numeric comparisons against an empty actual value default the actual to `'0'`. Keys may be dotted (`plan_review.gating_findings_count`); a stray `context.` prefix is forgiven with a warning.

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
| `executionCursor` (loop node: `nodeType: loop`) | which loop was active (`nodeId`), zero-based iteration cursor (`iteration`), and which step within the loop was active (`stepId`) |
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

Artifact-producing skills (`andthen:spec` and `andthen:plan`) follow a **single-mode file-based contract**: they write their artifacts to disk and emit workspace-relative **paths** under their `outputs:` block, never inline artifact content. Workflow steps downstream read those paths via `file_read`.

The engine validates emitted paths via the generic `format: path` trust-boundary check (§11.1 — containment, existence, argument safety). The engine does not re-validate AndThen artifact schemas (`plan.json` structure, FIS markers, `spec_source` semantics, status vocabulary); those domain semantics are the skill's responsibility (ADR-041). The `story_specs` output additionally passes a data-shape contract check (`story_spec_output_validator.dart`, `story_specs_contract_validator.dart`) that validates `items` list structure and required fields — this is a workflow-data-shape invariant, not framework coupling, and contains no `andthen` literals.

**Read-existing branches.** `dartclaw-discover-andthen-spec` classifies `FEATURE` as an existing FIS path or a feature description. Existing FIS inputs emit `spec_path` with `spec_source: "existing"` and skip `andthen:spec`; synthesized inputs leave the path empty until `andthen:spec` writes the FIS. `dartclaw-discover-andthen-plan` discovers an existing PRD/plan/story-spec state for `plan-and-implement`; `andthen:plan` fills only the missing plan or per-story FIS artifacts and emits `plan` plus `story_specs` paths. Skip/resume decisions are expressed as workflow-YAML `entryGate` expressions reading the skill's structured output — not re-derived in engine Dart code.

**`story_specs` shape.** `story_specs` is an object with an `items` list of **structured per-story records** — not bare paths. Each record carries required `{id, title, spec_path, dependencies}` fields, and may preserve optional workflow metadata such as `phase`, `wave`, or `status`. Downstream prompts read `{{map.item.title}}`, `{{map.item.id}}`, and `{{map.item.spec_path}}`; `{{map.item.spec_path}}` is the field that `andthen:exec-spec` uses with `file_read` to load the FIS body.

Every emitted `story_specs[].spec_path` must resolve to an existing file before the plan step succeeds. The executor validates those paths after extraction against the producing task's `worktree.path` when present, falling back to the active workflow root for inline/no-worktree steps. Missing FIS files convert the step to a workflow failure and, when `onFailure: retry` is configured, the retry prompt includes the validation failure.

### Single-step PRD/spec contract

The built-in workflows no longer ship separate review-prd / review-spec steps. `andthen:spec` and `andthen:plan` are responsible for producing solid final artifacts themselves, while downstream steps consume emitted paths (`spec_path`, `prd`, `plan`, and `story_specs[].spec_path`) via `file_read`. `plan-review` remains the aggregate read-only review surface for the multi-story pipeline.

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

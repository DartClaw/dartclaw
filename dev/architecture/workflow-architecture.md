# Workflow Architecture

Contributor reference for DartClaw's workflow engine (`packages/dartclaw_workflow`): the definition model, the parse and validate contract, run lifecycle and crash recovery, control nodes, step execution, context flow, workflow-owned git, and the HTTP/SSE wire formats. It leaves YAML authoring (field reference, examples, CLI usage) to the user guide [`docs/guide/workflows.md`](../../docs/guide/workflows.md), the task pipeline and worktree mechanics to [task-execution-architecture.md](task-execution-architecture.md), harness protocols to [control-protocol.md](control-protocol.md), CLI structure and trigger surfaces to [cli-api-architecture.md](cli-api-architecture.md), and schemas to [data-model.md](data-model.md).

**Current through**: 0.28.0

---

## 1. Control Plane and Components

Workflows are host-orchestrated pipelines with explicit state, explicit gates and deterministic recovery points, not prompt choreography. The Dart host owns ordering, persistence, budgeting, gating and approval. A step owns reasoning and tool execution only when it is an agent step.

[![Workflow engine: components and ownership](diagrams/workflow-components.svg)](diagrams/workflow-components.svg)

Workflow steps create tasks; the engine orchestrates the task system and never replaces it (section 13). The package depends on `dartclaw_kernel` and `dartclaw_core` only. Everything server-only (git, publishing, turn dispatch) reaches it through ports injected at composition time.

| Component | Responsibility | Code (`packages/dartclaw_workflow/lib/src/` unless noted) |
|---|---|---|
| Definition model | `WorkflowDefinition`, `WorkflowStep`, `WorkflowLoop`, normalized `WorkflowNode`s, `OutputConfig`, git strategy types | `workflow/workflow_definition.dart` |
| DSL rules | Accepted-surface authority: blocks, keys, aliases, value kinds, enums, per-type applicability | `workflow/workflow_dsl_rules.dart` |
| Parser, validator | YAML to typed model; semantic checks | `workflow/workflow_definition_parser.dart`, `workflow/workflow_definition_validator.dart`, `workflow/validation/` |
| Registry, materializer | Built-in and custom definition sources | `workflow/workflow_registry.dart`, `workflow/workflow_materializer.dart` |
| `WorkflowService` | Public run API: start, pause, resume, retry, cancel, request changes, recovery | `workflow/workflow_service.dart` |
| `WorkflowExecutor` | Authored-order traversal and persistence; step, loop, foreach and parallel runners are `part` files | `workflow/workflow_executor*.dart`, `workflow/step_dispatcher.dart`, `workflow/loop_step_runner.dart`, `workflow/foreach_iteration_runner.dart`, `workflow/iteration_dispatch_engine.dart`, `workflow/parallel_group_and_step_outcome_runner.dart` |
| Host-side step runners | Bash, approval, aggregate-reviews | `workflow/bash_step_runner.dart`, `workflow/approval_step_runner.dart`, `workflow/aggregate_step_runner.dart` |
| Context | `WorkflowContext`, template engine, gate evaluator, output extraction | `workflow/workflow_context.dart`, `workflow/workflow_template_engine.dart`, `workflow/gate_evaluator.dart`, `workflow/context_extractor.dart` |
| Git lifecycle | Integration branch, promotion, merge-resolve, publish, artifact commit, cleanup | `workflow/workflow_git_lifecycle.dart`, `workflow/promotion_coordinator.dart`, `workflow/merge_resolve_coordinator.dart`, `workflow/workflow_artifact_committer.dart` |
| Skills | Native skill provisioning, runtime skill preflight | `skills/`, `workflow/workflow_skill_preflight.dart` |
| Storage | `WorkflowRunRepository` implementations | `storage/database_workflow_run_repository.dart`, `storage/file_workflow_run_repository.dart` |
| Host bridge | `WorkflowTurnAdapter` callbacks wired to git, publish and runner capacity | `workflow/workflow_turn_adapter.dart`; wired in `packages/dartclaw_runtime/lib/src/runtime/service_wiring_workflow.dart` |
| HTTP, MCP | Routes, webhook, `workflow_*` tools, run-resolution owner | `packages/dartclaw_runtime/lib/src/api/workflow_routes.dart`, `api/github_webhook.dart`, `mcp/workflow_tools.dart`, `mcp/workflow_run_control_tools.dart`, `task/workflow_run_control.dart` |
| One-shot runner | Executes a workflow task's prompt chain and finalizer on a leased worker | `packages/dartclaw_runtime/lib/src/task/workflow_one_shot_runner.dart` |
| CLI | `dartclaw workflow …` commands | `apps/dartclaw_cli/lib/src/commands/workflow/` |

### Execution rows

Each dispatched agent step is three rows written in one transaction (`workflow_task_factory.dart`):

```text
WorkflowRun step
  -> AgentExecution        (provider, model, session, workspace, token budget)
  -> Task                  (review lifecycle, artifacts, worktree, UI/API identity)
  -> WorkflowStepExecution (step id, step type, git config, map iteration, finalizer schema, receipts)
```

The workflow package owns workflow metadata, the task subsystem owns review and artifact lifecycle, and `AgentExecution` carries the runtime fields neither owns exclusively ([ADR-021](../adrs/021-agent-execution-primitive.md); schemas in data-model.md).

## 2. Definition Model

A workflow is metadata, variables, steps and (inline) loops. The typed model lives in `dartclaw_workflow`, so the parser, validator, CLI and server runtime share one structure and execution is testable without HTTP. The runtime executes by step `id`, never by display `name`, and context edges are explicit: a step sees only the context keys it names.

```yaml
name: story-and-implement
description: Write a specification, implement it, and run integrated review.
variables:
  FEATURE: { required: true }
steps:
  - id: spec
    name: Generate Specification
    skill: andthen:plan
    entryGate: "spec_source == synthesized"
    workflowVariables: [FEATURE]
    outputs:
      spec_path: { format: path }
```

| Top-level key | Meaning |
|---|---|
| `name`, `description`, `steps` | Required. `name` is the registry, CLI and API identifier |
| `variables` | Declared inputs. `required` defaults to `true`; `default` supplies a value |
| `maxTokens` | Whole-run token ceiling (section 7.6) |
| `project` | Workflow project binding, normally `"{{PROJECT}}"` (section 2.4) |
| `stepDefaults` | Glob-matched execution policy (section 2.3) |
| `gitStrategy` | Workflow-owned git behaviour (section 10) |

A top-level `loops:` key does not exist. Loops and foreach controllers are authored inline in `steps:` (below) and the parser flattens them.

### 2.1 Step types

`type` is the structural execution mode; `skill` is an independent axis that only changes prompt construction.

| `type` | Runs a task | Meaning |
|---|---|---|
| `agent` (default) | yes | Agent turn(s) on a leased provider worker |
| `bash` | no | Host-side command, zero tokens (section 8.1) |
| `approval` | no | Human checkpoint (section 8.2) |
| `aggregate-reviews` | no | Host-side merge of upstream review outputs (section 8.3) |
| `foreach` | per child step | Per-item sub-pipeline over a context collection (section 6.3) |
| `loop` | per child step | Bounded repetition with entry and exit gates (section 6.4) |

Unknown types fail parsing; the supported set is closed. The engine calls this mix of step types over one `WorkflowStep` model "hybrid steps"; type-specific constraints are enforced by `WorkflowDslRules` and the validator (section 3).

### 2.2 Normalized nodes and step fields

Parsing produces `steps` (flat, authored order), `loops` and a normalized `nodes` list that the executor walks. `WorkflowDefinition.normalizeNodes` builds it from authored order:

| Node | Built from | Notes |
|---|---|---|
| `ActionNode` | an ordinary step | one dispatch |
| `ParallelGroupNode` | a run of adjacent `parallel: true` steps | non-parallel step, loop or foreach ends the group |
| `LoopNode` | the first step owned by a loop | loop-owned steps are not emitted separately |
| `ForeachNode` | a controller step with `mapOver` and child steps | child steps are foreach-owned and not emitted at top level |

The persisted run snapshot stores `definitionJson` including `nodes`. A node list this version cannot read is discarded and re-normalized from `steps` and `loops`. A step with `mapOver` but no per-item steps is a validation error.

| Step field | Applies to | Meaning |
|---|---|---|
| `skill`, `prompt` | agent (prompt also bash via `script`) | Provider-native skill reference; prompt string or list (list = multi-prompt). `prompt` or `skill` required for agent steps; `script` and `prompt` are exclusive on bash |
| `inputs`, `outputs` | all | Context keys read; output declarations. `outputs` keys are the step's complete context-write set |
| `entryGate` | all but the foreach controller | Skip-when-false gate (section 9.5) |
| `parallel` | agent, bash | Join the adjacent parallel group; exclusive with `continueSession` and `mapOver` |
| `continueSession` | agent | `true` (previous step) or a step id: reuse that step's agent session (section 7.4) |
| `provider`, `model`, `effort` | agent | Overrides; a value may be a role alias (section 2.3) |
| `turn_timeout` / `timeout` | agent / bash, approval, controllers | Per-turn wall clock for agent steps; step timeout otherwise. The wrong one for a type is a parse error |
| `maxRetries`, `onFailure` | agent, foreach | `fail` (default), `continue`, `retry`, `pause` for a modeled `failed` outcome (section 7.5) |
| `onError` | all | `fail` (default), `pause`, `continue` for execution errors before a modeled outcome |
| `allowedTools`, `workdir` | agent / bash | Tool allowlist override; working directory |
| `workflowVariables`, `auto_frame_context` | agent | Variables auto-framed into the prompt; opt-out flag (default `true`) |
| `emitsOwnOutcome` | agent | Skill owns the `<step-outcome>` tag (section 7.5) |
| `revise`, `maxRevisions` | approval | Request-changes target and round bound (section 8.2) |
| `aggregateReviews` | aggregate-reviews | Upstream review step ids |

`maxTokens` on a step is not an authoring key; only the synthetic merge-resolve step sets it (host-side token ceiling). Unknown keys fail parsing with "Unknown field".

### 2.3 Step defaults and role aliases

`stepDefaults` is an ordered list of `{match, …}` rules. `match` is an anchored glob where `*` is the only wildcard. The first matching rule wins and rules never merge; explicit step fields then override the matched rule field by field. Resolved fields: `provider`, `model`, `effort`, `maxRetries`, `allowedTools`, `timeout`, `turn_timeout`. Control flow (`prompt`, `skill`, `mapOver`, `inputs`, `outputs`, `entryGate`, `continueSession`) is never defaulted. Defaults are resolved right before dispatch (`workflow/step_config_resolver.dart`), so persisted definitions stay small and logs stay attributable to the authored step.

`provider` and `model` accept the role aliases `@workflow`, `@planner`, `@executor`, `@reviewer`, resolved from the config `workflow.defaults` roles; the specific roles inherit missing values from `@workflow`. Config reference: configuration-architecture.md.

### 2.4 Project binding

`WorkflowDefinition.project` binds steps to a project checkout. `Task.projectId` (the persisted field) is set only for steps that need one (`shouldBindWorkflowProject` in `step_config_policy.dart`): the workflow declares `project`, and the step is a foreach controller, declares a `format: path` output, has mutating `allowedTools` (`file_write` or `file_edit`), or is an agent step with no `allowedTools`. A read-only agent step (an `allowedTools` list without those tools) gets no project binding, and no worktree outside a `per-map-item` scope. See [ADR-024](../adrs/024-workflow-step-semantics.md).

## 3. Authoring Contract: Parser, Schema, Validator

### 3.1 Parser and published schema

**Parser.** `WorkflowDefinitionParser` is strict about shape and unknown keys and does not check semantics. It rejects missing or empty `name`, `description`, `steps`, non-string or empty ids and names, bad `prompt` shapes, and any key `WorkflowDslRules` does not declare. It normalizes `prompt: "x"` to `prompts: ["x"]`, omitted `type` to `agent`, `timeout: "30s"` to seconds, and the output shorthand `key: json | lines | <preset>` to an `OutputConfig`. Prompts are optional for bash, approval, controller and skill-only steps. Duplicate YAML keys follow `package:yaml` last-key-wins.

The parser does not do semantic checks such as:

- whether `mapOver` references a prior context key
- whether `continueSession` targets a valid step
- whether a gate expression is well formed

Those three checks are validator responsibilities. Skill existence is checked by
`workflow_skill_preflight.dart` during execution preflight.

The separation matters operationally: parse errors are syntax and shape failures, validation errors are contract failures, and warnings mark loadable but risky definitions. `dartclaw workflow validate`, registry loading and the browser/API diagnostics report that same split.

**Rule authority.** `WorkflowDslRules` declares blocks, key aliases (snake and camel case), value kinds, enum members, required fields, type applicability and mutual exclusions as data. The parser, the validator's grammar-shaped checks and the published JSON Schema all read it, so the three cannot disagree.

**Inline controllers.** A `type: foreach` entry carries `map_over`, `max_parallel`, `outputs` and a `steps:` list; a `type: loop` entry carries `maxIterations`, `entryGate`, `exitGate`, `onMaxIterations` and `steps:`. A foreach body may contain loops but not another foreach; a loop may not contain a loop.

**Published schema.** The repo-root `schemas/workflow.schema.json` (draft 2020-12) is generated from `WorkflowDslRules`: the union of step keys once with `additionalProperties: false`, narrowed per `type` by conditional branches. Reference resolution, gate grammar and id uniqueness stay outside it. Regenerate with `dart run packages/dartclaw_workflow/tool/generate_workflow_schema.dart`; `dev/tools/fitness/run_all.sh` runs it with `--check`.

### 3.2 Validation semantics

`WorkflowDefinitionValidator.validate` returns a `ValidationReport` of errors and warnings, not a boolean. A definition is loadable when `errors` is empty; the registry still exposes warning-bearing definitions instead of dropping them, so authors can iterate past non-fatal risks. Stages run in this order (`workflow/validation/` holds the bodies); the capability stage runs only when provider capabilities are supplied.

| Stage | Result | Checks |
|---|---|---|
| `_validateRequiredFields` | error | Required names and prompts; per-type field applicability |
| `_validateUniqueStepIds` | error | Unique step ids |
| `_validateUniqueLoopIds` | error | Unique loop ids |
| `_validateNormalizedNodes` | error | Normalized-node references, shapes and consistency |
| `_validateProviderAliases` | error | Known provider role aliases |
| `_validateVariableReferences` | error | Declared `{{VAR}}` and workflow-system variables |
| `_validateContextKeyConsistency` | error | `inputs` produced earlier or within the same loop |
| `_validateLoopGateExpressions` | error | Loop gate grammar and referenced keys (an `entryGate` cannot read a key only the body produces) |
| `_validateLoopReferences` | error | Loop-owned step ids exist |
| `_validateLoopMaxIterations` | error | Positive `maxIterations` |
| `_validateLoopStepOverlap` | error | No step in two loops |
| `_validateLoopMaxIterationsPolicy` | error | `onMaxIterations` valid for its scope |
| `_validateStepTimeoutFields` | error | Timeout field matches the step type |
| `_validateStepDefaults` | error/log warning | Default timeouts, provider aliases, unmatched patterns |
| `_validateGitStrategy` | error/warning | `worktree` and `promotion` values, artifact-commit defaults, `merge_resolve` bounds (section 10) |
| `_validateStepDefaultsOrdering` | warning | Overlapping defaults whose order changes the effective configuration |
| `_validateStepEntryGates` | error | `entryGate` grammar |
| `_validateOutputConfigs` | error/warning | Output keys, formats, schemas, path patterns, descriptions |
| `_warnCodexAllowedToolsPolicy` | warning | Codex `allowedTools` outside a read-only policy |
| `_validateMapOverReferences` | error | `mapOver` produced by a prior step |
| `_validateMapStepConstraints` | error/log warning | Foreach has per-item steps and one output key, not `parallel` |
| `_validateAggregateReviewsConstraints` | error | Aggregate-reviews sources and output format/preset triple |
| `_validateAggregateReviewsPlacement` | error | Aggregators outside loops and foreach bodies |
| `_validateReviewSourcePrefixing` | error | Review output keys prefixed by their source step |
| `_validateMultiPromptProviders` | error | Multi-prompt provider supports continuity (`@` aliases skipped, re-checked at runtime) |
| `_validateHybridStepRules` | error/warning | The step-type and session-continuity rules below |

The hybrid-step rules run in this order. Applicability and exclusions come from `WorkflowDslRules`; continuity targets, provider compatibility, loop boundaries and cycles need the definition instance (section 7.4).

| Rule | Severity |
|---|---|
| approval step inside a loop | warning |
| approval revise step cannot be re-entered | error |
| step type forbids parallel execution | error |
| step type forbids a prompt list | error |
| parallel combined with continueSession | error |
| continueSession uses an unsupported concrete provider | error |
| continueSession has no resolvable target | error |
| continueSession references an unknown target | error |
| continuing step type forbids continueSession | error |
| continueSession target does not precede the step | error |
| continueSession target is bash or approval | error |
| continueSession providers differ | error |
| continueSession crosses a loop boundary | error |
| continueSession chain forms a cycle | error |

The warning/error boundary is pragmatic: ambiguous or unsafe execution is an error, coherent but operationally risky execution is a warning. That is why approval inside a loop only warns: it can work, but authors must ensure the exit gate eventually ends the loop instead of the run waiting at the approval forever.

Skill names resolve in `workflow_skill_preflight.dart` at execution preflight (section 11.1); they are not a load gate. Unknown step types and unsupported `onError` values fail during parsing.

## 4. Registry and Built-In Definitions

`WorkflowRegistry` is the single definition source for the API, CLI and UI. It loads `WorkflowSource.materialized` definitions from `<dataDir>/workflows/built-in/`, then `WorkflowSource.custom` from `<dataDir>/workflows/custom/` and per-project `workflows/` directories (a deprecated drop folder at `<dataDir>/workflows/` still loads with a warning). A custom definition whose name collides with a materialized one is skipped with a warning; a custom name collision between customs keeps the last loaded. A file that fails to parse or validate is recorded in `exclusions` and does not stop the server. Reads re-check each source file's fingerprint; a changed file is re-parsed and re-validated, and an invalid edit keeps the previous definition.

`WorkflowMaterializer` copies the shipped definitions into `built-in/` at startup from a discovered source checkout when present, else from embedded assets (`generated/embedded_assets.g.dart`). Each copy gets a sibling `.dartclaw-managed.json` holding an FNV-1a 64-bit fingerprint (drift detection, not integrity). A file with no marker is preserved, a managed file edited locally is preserved with a warning, an untouched managed file is refreshed when the source changes, and a stale managed file is deleted only when unmodified.

Shipped built-ins (`lib/src/workflow/definitions/`): `story-and-implement` (spec, implement, integrated review, aggregate, bounded remediation loop), `plan-and-implement` (discover plan state, plan, optional `plan-approval` gate with `revise: plan` behind `PLAN_REVIEW`, a `story-pipeline` foreach running `implement`, `review-story` and a nested `story-remediation` loop per story, plan-level review, aggregate, remediation loop) and `code-review`. Each is a thin wrapper around skills.

## 5. Run Lifecycle

### 5.1 Status model

`WorkflowRunStatus` (`dartclaw_kernel`): `pending` (inserted, momentary), `running`, `paused`, `awaitingApproval`, `completed`, `failed`, `cancelled`. Only the last three are terminal.

- `paused`: an operator paused the run, a step with `onError: pause` held at its failed unit, or a step's task was cancelled while the run was `running` (section 7.5).
- `awaitingApproval`: blocked on an approval gate, a step-reported `needsInput` outcome, or a step with `onFailure: pause` (all use the `_approval.*` shape, section 8.2).
- `failed`: a runtime, gate or step failure; eligible for explicit retry.

This keeps dashboards, SSE subscribers and CLI exit codes aligned with operator intent: waiting on a human is not a failure.

[![Run status transitions](diagrams/workflow-run-status.svg)](diagrams/workflow-run-status.svg)

There is no transition table: every move is a conditional repository update on the expected status, and the figure is the set of those call sites. `WorkflowService` performs `pending` to `running` (start), `running` to `paused` (pause), `paused` or `awaitingApproval` to `running` (resume; request changes only from `awaitingApproval`), `failed` to `running` (retry), any non-terminal status to `cancelled` (cancel, or an expired approval timeout), and `running` to `failed` when the executor throws unexpectedly. The executor performs `running` to `paused`, `awaitingApproval`, `failed` and `completed`. A restart leaves `running` runs `running` and re-spawns them from the cursor (section 5.5). `pending` is not terminal, so cancel would accept it, but it exists for one call inside `start`.

### 5.2 Start and trigger convergence

Every server-managed trigger surface resolves a `WorkflowDefinition` and calls `WorkflowService.start(definition, variables, origin:, …)`: the JSON API, the HTMX launch form, the GitHub webhook (HMAC-verified, deduplicated per workflow, PR and repo), the `workflow_run` MCP tool, and the connected CLI, which is an API client. The standalone CLI calls the same method on a headless runtime composed from `DartclawRuntime.stageHeadless`. Surfaces, commands and exit codes: cli-api-architecture.md.

`start` validates required variables (a supplied `projectId` satisfies a declared `PROJECT`), applies variable defaults, lets the host adapter resolve the project and base branch, snapshots the definition into `definitionJson`, inserts the run, moves it `pending` to `running`, writes the initial `context.json`, fires `WorkflowRunStatusChangedEvent`, and spawns the executor in the background. Options: `approvals` (`manual`, `auto-on-stall`, `auto`; default from config `workflow.approvals`), `inline` (replace the git strategy with no integration branch and an `inline` worktree, for running on the current branch) and `allowDirtyLocalPath`.

**Run origin.** `start(origin:)` is required and persisted in the initial insert; it is immutable (`WorkflowRun.copyWith` cannot change it and both repositories ignore it on update). Surfaces: `web` (run form), `api`, `cli` (a request `surface: cli` marker is descriptive provenance, never authentication; any other value is `400 INVALID_INPUT`), `github`, `cron`, and a channel type name. The `workflow_run` tool takes its origin only from the calling turn's host record ([`McpCallerContext.turn`](system-architecture.md#mcp-server)): channel type, recipient, thread, session key and sender for a chat turn; no tool argument can set them. Runs stored before origin existed report `unknown`.

### 5.3 Executor preflight and traversal

`WorkflowExecutor.execute` runs for one run, started from a node index or a persisted `WorkflowExecutionCursor`:

1. Create `runtime-artifacts/` (and `reviews/`) and register `workflow.runtime_artifacts_dir`.
2. Reconcile any pending usage accounting left by a crash (section 7.6).
3. Initialize workflow git when `gitStrategy.integrationBranch` is set (section 10).
4. Skill preflight: every skill an agent step names, plus the merge-resolve skill when enabled, must be visible to its provider (section 11.1). Failure ends the run before any dispatch.
5. Walk `definition.nodes` in order. Before each dispatch check cancellation (`isCancelled`) and the token budget; evaluate `entryGate`; dispatch; merge outputs into `WorkflowContext`; persist; advance `currentStepIndex`.
6. At the end, run the publish hook if enabled; collect follow-ups (below); mark `completed`, clear the cursor and invoke git cleanup.

**Follow-up draft.** Inside `_completeRun`, after publish succeeded, `collectFollowUpFindings` (`follow_up_draft.dart`) reads the definition's declared `verdict` outputs from the final context: top-level keys, and foreach iteration results (`story_results[i][<childStepId>]`) for steps inside a foreach. A verdict is superseded, and dropped, when its own step emitted `gating_findings_count > 0`, the model-written count the remediation gates read, so a remediated review contributes its re-review's verdict only. Within a kept verdict, `isGatingSeverity` (`review_scoring_fragment.dart`, the single definition of the severity order and threshold, shared with the `verdict` preset enum and the scoring prompt) drops gating findings. When items remain and the run is still `running`, `createFollowUpDraft` creates one `draft` task through the executor's `WorkflowTaskService` under id `followup-<runId>` (an existing task with that id means a resumed completion and creates none), without `workflowRunId` so it is not workflow-owned. The task id and item count are written as the private `_followUp` context entry in the same update that marks the run `completed`, so the status event already finds it; `workflowFollowUp(run)` is its one reader (run page, `followUpTaskId` on `GET /api/workflows/runs/<id>`, the finished post). A creation failure is logged and the run completes without the entry. Counts stay model-written: nothing derives `findings_count` or `gating_findings_count` from a verdict's findings.

[![Run execution flow](diagrams/workflow-run-flow.svg)](diagrams/workflow-run-flow.svg)

Every executor write is conditional on the run still being `running` (`updateOwned`). If pause, cancel or another process changed the status, the next write throws `WorkflowRunOwnershipLost` and the executor stops. A pause or cancel also aborts the executor's wait on an in-flight task. Cancel additionally cancels the run's non-terminal child tasks; pause does not.

### 5.4 Pause, resume, retry, cancel

`pause` is valid only for `running`. `resume` accepts `paused` or `awaitingApproval`; at a pending approval it records the approval as approved. `retry` accepts `failed` and clears the failed step's `status`, `error` and outcome keys. `cancel` records a pending approval as rejected (optional `feedback`), transitions to `cancelled`, cancels child tasks and invokes git cleanup. Resume and retry rebuild the executor from the stored `definitionJson` snapshot, never from the registry, so editing a YAML file does not change an in-flight run. `WorkflowService` serializes all resolutions of one run (resume, cancel, request changes, approval issue and bind, timeout expiry) in a per-run in-process section. That section does not reach other processes (the standalone CLI's pause and cancel run in their own); the persisted guard is the repository's conditional update on expected status and `updatedAt`, and a lost update leaves the approval record unconsumed.

### 5.5 Crash recovery

The run row holds the compact snapshot (`currentStepIndex`, `executionCursor`, `contextJson`, totals); `context.json` under the run directory holds the full `WorkflowContext` (atomic JSON write). `recoverIncompleteRuns()` at startup handles:

- `running` runs: resume from the persisted cursor when present (loop iteration and step; foreach settled items and completed child steps); else, for a request-changes round (marker `_revision.gateId`), from the persisted step index, because the round re-runs steps whose tasks already completed; else from child-task inspection (re-run the interrupted step, otherwise start after the highest terminal step).
- `paused` and `awaitingApproval` runs: rehydrate approval timeout timers; an expired deadline expires the approval at once.

A parallel group resumes only its failed steps (`_parallel.failed.stepIds`). An `onError: pause` hold resumes explicitly; a `failed` run retries explicitly. In-flight siblings of a parallel or foreach hold settle first and their outputs and usage stay persisted; side effects of the failed attempt are not rolled back. A serialize-remaining transition fires `WorkflowSerializationEnactedEvent` exactly once across crash and resume (section 10.4).

Persistent state is written atomically and the runtime resumes from the last committed cursor, never from in-memory state.

### 5.6 Private context keys

Underscore-prefixed keys in `contextJson` are engine bookkeeping. They survive every context rebuild (`privateContextEntries`) and are not user outputs.

| Key | Meaning |
|---|---|
| `_loop.current.{id,iteration,stepId}` | active loop position (human-readable; the cursor is authoritative) |
| `_parallel.current.stepIds`, `_parallel.failed.stepIds` | group membership and members to re-run |
| `_approval.pending.{stepId,stepIndex}` | active approval or hold |
| `_approval.interaction` | chat-resolution record (section 8.2) |
| `_approval.auto_resolved.<stepId>` | auto-resolved gate or stall |
| `_revision.gateId` | request-changes round in progress |
| `_workflow.approvals`, `_workflow.git.integration_branch` | run approval policy; integration branch name |
| `_accounting.*`, `_budget.warningFired` | pending usage reads; one-shot budget warning |
| `_map.<foreachId>.promotedIds`, `_foreach.*`, `_merge_resolve.*` | promotion and sub-step progress, merge-resolve state |

## 6. Control Nodes

[![Control nodes: action, parallel group, foreach, loop](diagrams/workflow-control-nodes.svg)](diagrams/workflow-control-nodes.svg)

### 6.1 Linear steps and entry gates

An `ActionNode` runs one step. If its `entryGate` evaluates false, the executor sets `step.<id>.outcome = skipped` (reason: the expression), `<id>.tokenCount = 0`, fires `StepSkippedEvent`, advances and continues. `entryGate` is the only gate a step declares; to pause on a condition, guard a `type: approval` step with one. The check runs for action nodes, parallel-group members (a skipped member is filtered out), loop-body steps and foreach children. It is not evaluated on a foreach controller (put it on the children), and a request-changes round bypasses it for the revise step.

### 6.2 Parallel groups

Adjacent `parallel: true` steps run concurrently via `Future.wait` after all prior steps settled, and their results merge into context in step order. A member failure is classified per step: accounting stops, cancellation, approval holds and `onError` other than `continue` block the group. Blocking failures persist the merged context plus `_parallel.failed.stepIds`, then the run fails (`onError: fail`) or pauses (`onError: pause`); an interrupted member pauses the run; an approval-needing member moves it to `awaitingApproval`. Pause or cancel while the group runs keeps its operator-driven status instead of being converted to `failed`. `parallel` is ignored (with a warning) on a step inside a loop.

### 6.3 Foreach sub-pipelines

`ForeachNode` is the only collection-iteration primitive. The controller's `mapOver` names a context key holding a list (or a single-key object wrapping one, e.g. `story_specs.items`); an empty list succeeds with an empty result. Each item runs the ordered child steps in a per-iteration overlay: a copy of the plan-level context plus `map`, so a child's bare output keys are visible to later siblings and isolated from the plan-level context until the iteration ends. Results aggregate back as one list under the controller's single output key, index-ordered, each item an object keyed by child step id. The controller's tokens are the sum of its children's `<childId>[<i>].tokenCount` entries.

**Concurrency.** `max_parallel` is an integer, `"unlimited"` or a `{{VAR}}` template; omitted means 1. The dispatch engine (`iteration_dispatch_engine.dart`) caps in-flight iterations by `max_parallel` and by the runner capacity the host adapter reports (`availableRunnerCount`, at least 1); the worker lease at dispatch is the authoritative limit if capacity changes. An `inline` worktree forces 1. The engine owns restore, in-flight tracking, a single wake completer pumped from each future's completion, dependency-ready scan and stalled-dispatch cancellation. Each iteration future swallows its own error before it is tracked, so one iteration's exception cannot escape the dispatch loop and leave `inFlightCount` wrong; the wake completer replaces `Future.any` polling, which allocated listeners on every tick.

**Dependencies.** When items carry `id` and `dependencies`, `DependencyGraph` dispatches an item only after its dependencies completed (promoted, in promotion-aware scopes). An unknown dependency id or a cycle is rejected at dispatch time.

**Failure.** A failed iteration records `{error: true, kind, message, task_id}` in its slot. `kind` is the persisted discriminator of the typed failure (`workflow_failure.dart`) and resume reads it, so renaming a `kind` breaks resume for runs started earlier; `message` is operator text only. Under the controller's error policy, the first hard failure cancels pending iterations; in-flight ones settle. An exhausted token budget cancels pending iterations the same way. Outcomes: hard iteration, promotion or controller failures fail the run. The foreach cursor (settled indices, result slots, completed child steps) stays on the run for a promotion conflict, an unsettled slot or a pending accounting read, so `retry` resumes those items; otherwise `retry` re-enters the controller. `onFailure: continue` on the controller records `step.<id>.outcome = failed` and advances when no hard stop applies. Items blocked on `needsInput` advance with a digest, or hold the run in `awaitingApproval` when a dependent is waiting or the item carries the escalation marker from a nested loop.

Templates inside an iteration: `{{map.item}}`, `{{map.item.field}}`, `{{map.index}}`, `{{map.display_index}}`, `{{map.length}}`, `{{context.key[map.index]}}` (section 9.2).

### 6.4 Loops

A loop is a persisted state machine, not a special prompt.

| Field | Meaning |
|---|---|
| `steps` | Ordered body step ids |
| `maxIterations` | Hard cap (positive) |
| `entryGate` | Optional; evaluated at the start of every iteration. False on the first iteration skips the loop (body steps record `skipped`); false later ends it |
| `exitGate` | Evaluated after each full iteration; true ends the loop |
| `onMaxIterations` | On exhaustion without the exit gate passing: `fail` (default), `continue` (top-level loops only, falls through to the next node), `escalate` (foreach-nested loops only, settles the item as `needsInput` with the residual findings; the item carries an escalation marker, so the foreach always holds the run in `awaitingApproval` for review, even with no open dependent, and resume re-runs the blocked item from scratch in a fresh worktree) |

Per iteration (1-based): set the cursor (`WorkflowExecutionCursor.loop`: loop id, iteration, step id) and `_loop.current.*`; run each body step in order through the normal step dispatch, merging outputs and persisting after every step; fire `LoopIterationCompletedEvent` with the gate result; evaluate the exit gate; on exit clear the cursor and `_loop.current.*`. The cursor distinguishes before the first body step, mid-iteration, and after the iteration but before the exit decision. A failing body step follows its `onError` policy (the run fails by default). A loop nested in a foreach body checkpoints its iteration, step, tokens and iteration data under `_loop.<id>.foreach.<foreachId>[<i>].*` so it converges independently per item.

`continueSession` cannot cross a loop boundary: session continuity is linear and iteration is not, so bridging them would leave replay ambiguous (which iteration owns the session, whether recovery resumes the same turn chain, whether later iterations inherit stale context).

## 7. Agent Step Execution

### 7.1 Dispatch paths

[![Step dispatch paths and outcome protocol](diagrams/workflow-step-dispatch.svg)](diagrams/workflow-step-dispatch.svg)

`_executeStep` (`step_dispatcher.dart`) branches by type:

| Step | Path | Result source |
|---|---|---|
| `bash` | `bash_step_runner.dart`, no task | exit code and stdout |
| `approval` | `approval_step_runner.dart`, no task | operator resolution |
| `aggregate-reviews` | `aggregate_step_runner.dart`, no task | context values |
| `loop` (foreach-nested) | `_executeNestedLoopStep` | loop result |
| `agent` | task triple, then wait for a terminal task | finalizer envelope or task status |

An agent dispatch runs inside `runWithWorkflowRetry`: resolve config and prompt, create the task triple, wait on `TaskStatusChangedEvent` for a terminal status, read token usage, extract outputs, validate (story specs, path claims), resolve the outcome, then promote the step's work if it is the last branch-touching step in scope.

### 7.2 Prompt construction

`SkillPromptBuilder.build` assembles the prompt:

| Case | Prompt |
|---|---|
| skill and prompt | provider activation line, blank line, resolved prompt |
| skill, no prompt | activation line plus a markdown summary of `inputs` (or the line alone) |
| no skill, prompt | resolved prompt unchanged |
| neither | rejected at parse time for agent steps |

The activation line is harness-specific (`AgentHarness.skillActivationLine`): `/<skill>` for Claude Code, `$<skill>` for Codex, `Use the '<skill>' skill.` otherwise. Multi-prompt steps apply it to the first prompt only.

Two appenders follow. **Auto-framing** adds `<tag>value</tag>` blocks (tag is the key with `.` replaced by `_`; empty renders `_(empty)_`) for each `inputs` key and `workflowVariables` entry, unless the prompt already contains the tag or the template already references the value; a value containing its own closing tag is escaped. `auto_frame_context: false` opts out. **Output sections** (`PromptAugmenter`) add `## Declared Outputs` (descriptions), `## Required Output Format` for non-structured `format: json` outputs, the review-scoring fragment for `verdict` and `gating_findings_count`, and, for a step with no finalizer and no `emitsOwnOutcome`, the `<step-outcome>` instructions (the host ignores that tag for such steps; section 7.5).

`SKILL.md` frontmatter is provider-owned metadata; DartClaw reads no workflow defaults from it. Prompts and output schemas are authored in workflow YAML.

### 7.3 One-shot execution and the finalizer envelope

Every workflow task runs through a single guarded harness path (`WorkflowOneShotRunner`; lease and worker mechanics in task-execution-architecture.md, workflow step branch): one provider worker lease for the whole prompt chain, all turns through that worker's `TurnRunner`, the transcript recorded in the task session. Read-only behaviour comes from effective `allowedTools` (`stepIsReadOnly`), and the mutation check runs against the provisioned worktree.

After the work turn, a step whose outputs need model-derived values (any inline output, or a `format: path` claim) gets a **finalizer turn**: no work tools, at most 4 model turns, prompted with the full persisted JSON schema so providers without native schema enforcement see the same contract. The result is a strict **execution envelope** `{"outputs": {…}, "step_outcome": {"outcome", "reason"}}` (`step_outcome` omitted when `emitsOwnOutcome`). A missing or malformed envelope gets one re-ask, then the step fails validation and enters the retry path. The envelope is the only model-derived source of declared outputs; `format: json` with `schema` selects this structured mode (inferred, not authored). Host-owned outputs (`source:`) bypass it. The envelope schema is built in `execution_envelope_schema.dart`.

Claude Code restarts its process when the finalizer changes spawn flags. The harness therefore holds a work turn open while the CLI still lists non-shell background tasks, so the restart cannot kill running subagents; the hold is bounded by the turn timeout ([control-protocol.md § 3.4](control-protocol.md#34-background-tasks-at-the-turn-boundary)). Failure reasons of the finalizer (`missing_provider_session`, `missing_envelope`, `unparsable_envelope`, `malformed_envelope`) are listed in [control-protocol.md § 2.3](control-protocol.md#23-structured-output).

### 7.4 Multi-prompt steps and session continuity

A `prompt:` list runs its prompts sequentially on the same worker, each resuming the captured provider session (`--resume` / `resume`). Output-format instructions go on the final prompt only. The step budget (`maxTokens`, host-set) is checked before every prompt. Each turn's normalized additive token reading is written to the `WorkflowStepExecution` token receipt before the next prompt; a failed receipt write stops the chain. The receipt and the session ledger can disagree: when a turn's settlement `session_cost` write fails, the ledger keeps its pre-dispatch pending marker and the turn counts as incomplete, while the receipt keeps the turn's known increment. A later complete snapshot does not heal that ledger gap (control-protocol.md § 6.4).

`continueSession` reuses an earlier step's agent session. `true` means the immediately preceding step; a step id names a step. Resolution follows the chain to its root and reads `<rootStepId>.sessionId` (and the provider session id) from context. The executor snapshots the session's known token count as a baseline so the step is charged only its own tokens; Claude's native cumulative baseline is scoped to the same logical session, so resuming the native identity under another logical session starts an incomplete lower bound. Validation rejects a continuation that is `parallel`, targets a non-agent step or an unknown or later step, crosses a loop boundary, forms a cycle, or targets a step on a different concrete provider (role aliases are checked at runtime and fall back to the root's provider with a warning). It pays off in refinement chains and same-worktree validation loops; review steps whose inputs arrive through `inputs` should start fresh.

### 7.5 Step outcome protocol, failure policies and retry

A step's semantic outcome is `succeeded`, `failed` or `needsInput`, recorded as `step.<id>.outcome` (and `.outcome.reason`); the executor also assigns `cancelled` and `skipped`. Source, in order:

1. A step with a finalizer: `step_outcome` from the envelope.
2. A step with `emitsOwnOutcome: true`: the last assistant message ends with `<step-outcome>{"outcome":"succeeded|failed|needsInput","reason":"…"}</step-outcome>`. Only these steps parse the tag.
3. Task lifecycle status: terminal `failed` or `rejected` forces `failed` and `cancelled` forces `cancelled` (overriding any reported outcome, without fallback telemetry). A task cancelled while the run is `running` is an interruption, not a failure: run teardown, operator task-cancel and emergency stop all reach this path, the engine alone assigns `cancelled` (the `<step-outcome>` whitelist rejects it from agents), the run pauses without advancing `currentStepIndex`, `workflow resume` re-runs the step, and no git cleanup runs. Every controller (plain step, parallel group, loop, foreach) maps it to its pause seam, ahead of `onFailure` and `onError` policies. An accepted task with no supplied outcome resolves to `succeeded`, logs a warning and increments `workflow.outcome.fallback`.

A finalizer step with a missing or malformed envelope fails validation instead of falling back. A claimed `succeeded` cannot bypass a missing required artifact: path validation runs after finalization and turns the step into a validation failure.

| Situation | Policy | Effect |
|---|---|---|
| `failed` outcome (incl. validation failure) | `onFailure: fail` (default) | run fails |
| | `continue` | records the failure, advances |
| | `retry` | workflow retry below |
| | `pause` | run moves to `awaitingApproval` at the step |
| `needsInput` | default | run moves to `awaitingApproval` |
| | `onFailure: continue` | records the reason, advances (advisory steps) |
| | approvals `auto-on-stall` or `auto` | auto-approves, records `_approval.auto_resolved.<stepId>`, fires `WorkflowApprovalResolvedEvent` |
| Execution error (task creation or wait failure, non-zero or unstartable bash, hard failure before an outcome) | `onError: fail` (default) | run fails |
| | `pause` | run `paused`, resumes at the failed unit |
| | `continue` | advances with a failed step record |

Cancellation, approval, promotion conflict, budget or security stops, and unavailable required token accounting keep their own authority ahead of step-level continuation.

**Retry.** `onFailure: retry` with `maxRetries: N` allows at most N+1 task attempts per step, per map item and per foreach child; this is the only retry authority for workflow tasks. Workflow task creation sets `Task.maxRetries = 0` so it cannot multiply with the task runtime's own retry. Each retry prompt carries the previous failure. The helper stops early when two consecutive attempts carry equal `WorkflowStepRetryFailure` values: host-classified failures (output validation, task terminal status) compare by kind alone; model-declared failures compare by kind plus the model's verbatim reason. Neither identity is ever derived from producer or message text.

### 7.6 Budgets and token accounting

`maxTokens` on the definition bounds the run. Before each dispatch the executor fires a one-time `WorkflowBudgetWarningEvent` at 80% (`_budget.warningFired`) and fails the run when `totalTokens` reaches the ceiling. The cap is a dispatch guard, not a ceiling on concurrent spend: in-flight parallel and foreach work settles and is counted. Agent-step `turn_timeout` (including inherited from `stepDefaults`) bounds each turn.

`WorkflowRun.totalTokens` sums known contributions and `tokenUsageComplete` is a sticky availability flag (a legacy run without it is incomplete). An agent task's usage is accepted only when the receipt's latest turn id matches the session ledger (`session_cost:<sessionId>` in KV), the ledger is complete with no pending accounting turn, and the total is a valid non-negative integer; a continued step charges only its increment over the baseline. Known tokens from an incomplete receipt stay in the lower bound and the step's token count is null. Bash, skipped, approval and other zero-work units count as measured zero. With `maxTokens` set, incomplete required usage fails the run before the next dispatch, and `onError`/`onFailure` cannot continue past it. A transient read error leaves the settled task pending in the cursor (`_accounting.pending*`); explicit retry re-reads the same receipt and ledger, adds it once, then checks the cap.

## 8. Host-Side Steps

### 8.1 Bash

Zero task, zero token. Runs through `SafeProcess` with a sanitized environment (allowlist plus sensitive-pattern stripping) in `/bin/sh -c`; native Windows resolves Git Bash through `PlatformCapabilities.bashShellPolicy` and fails with `bash steps require Git Bash on Windows` when absent, never an empty success.

| Concern | Behaviour |
|---|---|
| Command | `prompt:` or `script:` (exclusive). `{{context.*}}`, `{{workflow.*}}` and `{{VAR}}` are shell-escaped; templates that sit inside caller quotes, or in a command using `eval`, nested `sh`/`bash`, heredocs or command substitution, are rejected. `{{map.*}}` is unavailable |
| Working directory | `workdir` (templates allowed, no `{{context.*}}`; must resolve inside `<dataDir>`, symlink-checked), default `<dataDir>/workspace/` |
| Child processes | background jobs are part of the step and are awaited or cleaned up when observed; detached or daemonized services are unsupported |
| Timeout | `timeout` seconds, default 60. POSIX: SIGTERM then SIGKILL after 2 s on the observed tree. Windows: hard-terminates the direct root; uncontained descendants may survive. If cleanup cannot be confirmed, later bash steps stay blocked until restart |
| Output | stdout and stderr each capped at 64 KB with a `[truncated]` marker. `format: json` parses stdout, `lines` splits non-empty lines, `text` passes it raw |
| Context keys | `<id>.status` (`success` or `failed`), `.exitCode` (`-1` on any failure), `.workdir`, `.stderr` (non-empty), `.stdoutTruncated`, `.stderrTruncated`, `.error` on failure |
| Failure | an execution error: governed by `onError` |

### 8.2 Approval

An approval step holds the run until an operator accepts or cancels it. The prompt is template-resolved. Context gets `<id>.approval.status` (`pending`, `approved`, `rejected`, `changes_requested`, `timed_out`), `.message`, `.requested_at`, `.feedback`, `.revision`, plus `_approval.pending.stepId`. `currentStepIndex` advances past the gate before the hold is persisted, so resume starts at the next step. The run becomes `awaitingApproval`, then `WorkflowApprovalRequestedEvent` fires (after the persisted hold, before the status event). Under approvals `auto` the gate approves itself with no pending state. `timeout` starts a timer that cancels the run with `timed_out`; timers are rehydrated at startup for unexpired deadlines. The same hold shape serves `needsInput` and `onFailure: pause` steps.

| Action | Entry points | Effect |
|---|---|---|
| Approve (resume) | `POST …/resume`, Approve button, `workflow_resume` | marks `approved`, continues at the next step |
| Reject (cancel) | `POST …/cancel` (optional `feedback`), Reject button, `workflow_cancel` | marks `rejected`, cancels run and child tasks |
| Request changes | `POST …/request-changes`, run page form, `workflow_request_changes` | re-runs from the `revise` step, returns to the same gate |
| Timeout | timer | marks `timed_out`, cancels run |

Chat, tool and HTTP callers reach `WorkflowService` through `WorkflowRunControl`, which owns the admin gate and the audit entry (security-architecture.md, run approval gate); resume and cancel over HTTP are audited as `web` resolutions and are not admin-gated.

**Request changes.** The gate declares `revise: <stepId>` (an earlier top-level non-approval step) and `maxRevisions` (1 to 10, default 3 when `revise` is set). The service refuses with typed `WorkflowApprovalRefusal` reasons (`changesNotOffered`, `limitReached`, `feedbackRequired`, plus `notPending`, `alreadyResolved`, `invalidNonce`) before writing anything, so no refusal consumes the nonce. `workflowRevisionState` is the one derivation of "is the round open" shared by the service, tools, run page and route. One persisted update records `changes_requested`, the trimmed feedback, the incremented revision and the consumed interaction, sets the run `running` at the revise step and writes `_revision.gateId`. The marker makes the executor run the revise step despite its `entryGate` and append a round lead-in and the feedback in one framed block to the prompt (`SkillPromptBuilder.appendRevisionFeedback`, skipped when the prompt already references `{{context.<gateId>.approval.feedback}}`); the marker is dropped when the gate pauses again. Outputs of steps between the revise step and the gate are overwritten, never cleared. Refused: a `needsInput` hold, a gate inside a loop, foreach or group, or a gate with no `revise`.

**Chat interaction record.** A chat post can resolve a pending approval once, through `_approval.interaction` in the run's context (`workflow_approval_interaction.dart`). `issueApprovalInteraction` stores `{stepId, nonce, issuedAt}` only when the run is pending at that step; the nonce is 128 bits from `Random.secure()` (32 hex characters). `bindApprovalPost` records the sent post (channel type, recipient, message id) and fails if the record was replaced or consumed. `resume`, `cancel` and `requestChanges` accept an `expect` (step, nonce, channel type, message id) and a `resolver` (source `button`, `tool` or `web`, sender id, display name); with `expect`, the run must still be pending at that step, the record unresolved, and every field equal (nonce compared in constant time), else `WorkflowApprovalRefused`. Resolution is written in the same update as the approval status keys and the record then carries `resolution`. It is kept after resolution, so the notification subscriber can find and edit its post, and ends with the run. A failing update leaves the nonce live. Without `expect`/`resolver` the old behaviour holds (`StateError` for a refused transition). The nonce is readable by an authenticated run-detail caller, who can already resume over HTTP; no tool result, audit entry or log carries it.

### 8.3 Aggregate reviews

`aggregate-reviews` merges the report files of upstream review steps into one markdown file under the run's runtime artifacts, sums their `findings_count` and `gating_findings_count`, and publishes the bare canonical keys `review_report_path`, `findings_count`, `gating_findings_count` that remediation loops read. Each upstream step must prefix its own output keys with its step id (`<stepId>.review_report_path`, `<stepId>.findings_count`, `<stepId>.gating_findings_count`) so concurrent review branches cannot collide. The host accepts the skill's bare `review_report_path` for the prefixed path output through the claim alias in `ContextExtractor`; count keys have no alias and must be emitted under the exact prefixed name. A single review step with no aggregator (`code-review`) keeps bare keys. `validation/workflow_review_source_prefix_rules.dart` enforces this and the parser rejects the retired `review_findings` key.

## 9. Context Flow

### 9.1 WorkflowContext

`WorkflowContext` holds `data` (step outputs and engine keys), `variables` (immutable run inputs) and `systemVariables` (engine-injected: `workflow.runtime_artifacts_dir`, and `unproduced.<stepId>` marking declared outputs a terminally failed step never produced). Per step the engine writes `<id>.status` (terminal task status, or `success`/`failed` for host steps), `<id>.tokenCount`, `<id>.error` on failure, `<id>.sessionId`, `<id>.providerSessionId`, `<id>.branch`, `<id>.worktree_path`, `step.<id>.outcome[.reason]`, then the declared outputs. Context is persisted after each completed step or iteration boundary.

### 9.2 Template engine

`WorkflowTemplateEngine` resolves `{{…}}` in four namespaces: `{{VAR}}` (workflow variable; undefined throws `ArgumentError`), `{{context.key}}` (empty string with a warning if missing), `{{workflow.*}}` (system variable; undefined throws) and, inside foreach, `{{map.*}}`. Map-aware resolution adds `{{map.item}}` (JSON for objects), `{{map.item.field}}` (up to 10 segments; list fields render as bullet lists), `{{map.index}}`, `{{map.display_index}}`, `{{map.length}}`, `{{context.key[map.index]}}` and `{{context.key[map.index].field}}`. An indexed element with a `text` field renders that field. There are no conditionals, loops or functions.

### 9.3 Output declaration and extraction

`outputs:` is the only declaration of context-write keys; `WorkflowStep.outputKeys` derives from it. Per output: `format` (`text`, `json`, `lines`, `path`), `schema` (preset name or inline JSON Schema), `source` (`worktree.branch` or `worktree.path`, a host read of task metadata), `description` (shown to the model and in the envelope), and for `path` outputs `pathPattern` and `preferPatterns`.

`ContextExtractor.extract` resolves each key in order:

1. `source` read from task worktree metadata.
2. The per-key resolver (`outputResolverFor`): a `FileSystemOutput` for `format: path` (and `*_paths` lines lists), else an `InlineOutput` reading the envelope's `outputs`.
3. A value derivable from already extracted outputs (unscoped or nested key).
4. `diff.json` for the canonical `diff_summary` key.
5. Otherwise nothing is set and a warning is logged.

An unknown `source` warns and falls back to normal extraction.

**One rule for every `format: path` output.** Roots are probed in this order: the step's artifacts directory, the task worktree (or persisted execution workspace when there is neither worktree nor project), the run's `runtime-artifacts/`, the project data directory (`fileSystemOutputRoots`). An existing, symlink-contained claim wins, whatever its name; no `git diff` is consulted and the claim is taken literally. A value from an engine-owned root (step artifacts, runtime artifacts) reaches context absolute; other roots stay root-relative, because downstream steps pass the value as a workspace-relative skill argument. Where the same relative name exists in two roots the host-owned copy wins. A claim that escapes the workspace is never used. With no usable claim the value is captured from the step artifacts directory: `pathPattern` filters top-level files by basename, `preferPatterns` breaks ties, most recently modified is last. A path output with no `pathPattern` or preset falls back to `**/*`. With neither claim nor capture: a reported clean review gets a diagnostic markdown stub; a step that named a path or reported findings fails with `MissingArtifactFailure`; anything else resolves empty. Argument-safety (`path_safety_policy.dart`) is enforced after resolution.

The engine owns and pre-creates `reviews/`, `merge-resolve/` and each task's `steps/<stepId>[-<i>]/`. Any other subdirectory a custom step writes under `{{workflow.runtime_artifacts_dir}}` must be created by that step.

### 9.4 Schema presets and validation

**Output-contract invariant ([ADR-041](../adrs/041-framework-agnostic-workflow-engine-generic-output-validation.md)).** The engine validates a step's output with exactly two framework-neutral mechanisms: the declared schema (types, required fields, enums, shape), and generic `format: path` trust-boundary validation (workspace containment, existence, argument-safe characters, symlink-aware escape rejection) applied to every path output regardless of skill. When no workspace root resolves, only containment is checked. Everything framework-specific (status vocabulary, resume filtering, dependency pruning, cross-field consistency) is the skill's job, and skip or resume decisions are `entryGate` expressions over the skill's structured output. `dev/tools/fitness/check_no_framework_coupling.sh` asserts zero `andthen` literals in `packages/dartclaw_workflow/lib/src/` outside `definitions/*.yaml` (governance level 2, [ADR-033](../adrs/033-architectural-governance-via-fitness-functions.md)). The `story_specs` output additionally passes a data-shape check (`story_spec_output_validator.dart`) for the `items` list and required record fields; that is a workflow-data invariant, not framework coupling.

Presets (`schema_presets.dart`) name common schemas: `verdict`, `story_specs`, `non_negative_integer`, `narrative_text`, `diff_summary`, `validation_summary`, `gating_findings_count`, `findings_count`, `review_report_path`. A preset supplies format, schema, default resolver and prompt fragment. `story_specs` is an object with an `items` list of records `{id, title, spec_path, dependencies}` plus optional metadata; every `spec_path` must exist (checked against the producing task's worktree, else the active workflow root) or the step fails and, with `onFailure: retry`, the retry prompt carries the failure.

**File-based artifacts.** Artifact-producing steps (`andthen:plan` for specs and plans) write files and emit workspace-relative paths under `outputs:`, never inline content; downstream steps read the paths with `file_read`. The `dartclaw-discover-andthen-*` skills classify existing specs or plans and emit `spec_path`/`plan` and a source marker, and the workflow YAML skips or resumes through `entryGate` expressions over those outputs.

`SchemaValidator` checks a parsed value against a preset or inline schema (type, required fields, nested properties, array items, `minLength`). Normalization logs diagnostics for soft outputs and keeps the value; it throws, failing the step, for strict count outputs and for resolved scalar filesystem outputs with violations (an authored `minLength: 1` rejects an empty path while a nullable claim can still capture an artifact). `dartclaw workflow validate` and extraction share this validator.

### 9.5 Gate evaluation

`GateEvaluator` implements a two-level grammar; `&&` binds tighter than `||`, with no parentheses, NOT or arithmetic:

```text
expression ::= andGroup ( '||' andGroup )*
andGroup   ::= condition ( '&&' condition )*
condition  ::= "<key> <op> <value>" | "<key> isEmpty" | "<key> isNotEmpty"
op         ::= == | != | < | > | <= | >=
```

Examples: `review.verdict == pass`, `plan.status == accepted && plan.tokenCount < 12000`, `plan-review.gating_findings_count > 0 || re-review.gating_findings_count > 0`, `review_report_path isNotEmpty && findings_count < 5`.

The language stays small on purpose: the validator can reason about the keys a gate reads, docs and the UI can explain a gate without ambiguity, and workflows stay auditable configuration rather than embedded code.

Both productions are declared once on `GateEvaluator` (`binaryConditionPattern`, `unaryConditionPattern`, `conditionGroups`) and the validator reads the same declarations, so it cannot accept what the evaluator rejects.

- Keys are bare or dotted (`plan-review.gating_findings_count`), looked up in context, then in workflow variables (so `PLAN_REVIEW == true` works). A stray `context.` prefix is stripped with a warning.
- `==` and `!=` compare strings. `<`, `>`, `<=`, `>=` require both sides numeric; otherwise the condition is false with a warning.
- `x == null` is true when the value is empty or missing or the string `"null"`. For a numeric expected value, an empty actual is read as `0`. `isEmpty` also treats the string `"null"`, empty lists and empty maps as empty.
- Malformed expressions evaluate false. Gates are control-plane conditions; if the runtime cannot prove one passes, it must not continue.
- **Unproduced outputs are not a value.** If a condition reads a key that a terminally failed step declared and never produced (`unproduced.<stepId>` system variable), the evaluator throws `GateUnproducedOutputFailure` and the executor fails the run. Absence from a skipped step still reads as empty or `0`; absence from a failed step must not pass a remediation gate (a stalled review once let one pass).

## 10. Workflow-Owned Git

For project-backed workflows, git state is orchestrated at workflow level, not only at task accept time. Host-side operations are injected through `WorkflowTurnAdapter` callbacks (reusing `MergeExecutor`, `RemotePushService` and `PrCreator` in wiring), so the workflow package stays independent of server git code. Worktree creation and review mechanics: task-execution-architecture.md § 5. Workflow-spawned tasks use `reviewMode: auto-accept`, so agent steps advance on `TaskStatus.accepted` rather than parking in `review`; human checkpoints are structural (approval steps), never per-step review.

| `gitStrategy` key | Meaning |
|---|---|
| `integrationBranch` (aliases `integration_branch`, `bootstrap`; disagreeing values are rejected) | Create a workflow-owned branch before step execution; tasks base on it |
| `worktree` | `shared`, `per-task`, `per-map-item`, `inline` or `auto` (or `{mode: …}`) |
| `promotion` | `merge`, `rebase`, `none` |
| `publish.enabled` | Deterministic publish at completion; writes `publish.status`, `.branch`, `.remote`, `.pr_url`, `.error` |
| `cleanup.enabled` | Default true; `false` keeps worktrees and branches after a terminal state |
| `artifacts` | Auto-commit of produced files (section 10.5) |
| `merge_resolve` | Agent-resolved promotion conflicts (section 10.4) |

### 10.1 Worktree mode resolution

`WorkflowGitStrategy.effectiveWorktreeMode(maxParallel, isMap)` resolves an omitted or `auto` mode per scope: a foreach scope with `max_parallel` greater than 1 or `unlimited` resolves to `per-map-item`; a serial foreach scope resolves to `inline`; a non-foreach scope resolves to `shared` when `integrationBranch: true` (keeping the workflow branch out of the operator's live checkout) else `inline`. Authored values are used as written. The validator treats unresolved `auto` conservatively for artifact-commit checks.

**Shared-worktree binding.** A `shared` worktree is keyed by the run id and a `per-map-item` one by `<runId>:map:<i>`. The on-disk worktree id is `wf-<token>` (`wf-<token>-map-<i>`), where `<token>` is the first 16 hex characters of the SHA-256 of the run id, not a task UUID. Creation is serialized per key: the first task creates the worktree and concurrent tasks for the same key await it, so parallel steps cannot race to create two. The resulting `{key, path, branch, workflowRunId}` binding is persisted on the run and reloaded before resume, retry and recovery, so a restarted run adopts its existing worktree. A binding whose `workflowRunId` differs from the requesting run is refused with a `StateError`.

### 10.2 Promotion

Authored `promotion` values are `merge`, `rebase` and `none` (validator `workflow_git_strategy_rules.dart`); `none` skips promotion. Under `per-map-item`, each foreach iteration works on its own story branch `dartclaw/task-wf-<token>-map-<i>` (`<token>` is the first 16 hex characters of the SHA-256 of the run id; a `-N` suffix resolves a name collision), cut from the integration branch HEAD (`_baseRef`) and promoted back to it on success. Promotion is inferred from the resolved shape: omitted `promotion` behaves as `merge` for `per-map-item` and `per-task`, and `none` for `inline` and `shared`, so built-ins do not repeat `promotion: merge`. In a promotion-aware scope (`per-map-item` with a project-touching child step and promotion not `none`), dependents wait until their prerequisite is promoted. The last branch-touching step of a scope promotes after it succeeds.

### 10.3 Conflict outcomes

A promotion conflict that is not resolved produces `WorkflowPromotionConflictFailure` (persisted `kind: promotion-conflict`, message prefixed `promotion-conflict:`), carried on the iteration slot and `MapStepResult.failure`. The decision is the failure's type; the text is operator payload and never feeds a branch. The run fails with the foreach cursor kept so `retry` resumes the conflicting items. A resumed run whose failed slots predate the `kind` discriminator fails with a re-run instruction rather than restoring a conflict as an ordinary failure.

### 10.4 Merge-resolve

With `merge_resolve.enabled: true` (requires `promotion: merge`; defaults `max_attempts: 2` within 1 to 5, `token_ceiling: 100000` within 10000 to 500000, `escalation: serialize-remaining`), a promotion conflict runs a bounded loop of `dartclaw-merge-resolve` attempts, each an agent step with file and shell tools and `emitsOwnOutcome` whose outcome is `resolved`, `failed` or `cancelled`. An attempt verifies with the project's documented format, analyze and test commands, falling back to no conflict markers plus `git diff --check` when the project documents none; a failed check is fixed and re-verified inside the same attempt until it passes or the token ceiling is reached. Each attempt runs under a single per-project critical section covering capture and clean, skill execution and the promotion retry, so no sibling promotion mutates the integration branch mid-resolution. Each attempt writes an artifact `merge_resolve_iter_<i>_attempt_<n>.json` (task artifact plus `runtime-artifacts/merge-resolve/`; fields in `merge_resolve_attempt_artifact.dart`); a pre-attempt sha is persisted so crash recovery can detect and clean an in-flight attempt. On exhaustion, `fail` surfaces the conflict, and `serialize-remaining` stops new dispatch, lets in-flight siblings settle (30 s timeout, else `serialize-remaining-settle-timeout` and the run fails with its tasks cancelled), then retries remaining items serially; iterations already promoted stay promoted and only unfinished items re-run. The typed state `_merge_resolve.serializeRemaining` persists `eventEmitted: true` before siblings finish settling, so `WorkflowSerializationEnactedEvent` is emitted at most once across crash and resume; the terminal `phase: drained` marks the serial retry as consumed.

### 10.5 Publish, artifact auto-commit and cleanup

`publish.enabled` runs at completion through the host callback and merges its result into context; a publish failure fails the run without git cleanup, so the integration branch survives. Terminal transitions (`completed`, `failed`, `cancelled`) call the host cleanup callback with a `preserveWorktrees` flag derived from `gitStrategy.cleanup`; by default it removes the run's worktrees and branches, and config `workflow.cleanup.delete_remote_branch_on_failure` also deletes pushed branches of failed runs.

`gitStrategy.artifacts` commits files produced by a step (outputs with `format: path`, and `story_specs`) right after that step, using author `DartClaw Workflow` and the message `commitMessage` (default `chore(workflow): {{step.id}} artifacts`; `{{runId}}`, `{{step.id}}`, `{{step.name}}` and variables substitute), in the worktree or the project from `artifacts.project`. For `plan-and-implement`, this lands the plan's spec files on the workflow branch before `story-pipeline` creates per-item worktrees, so they inherit the files.

| Workflow | Resolved `worktree` | Default `commit` | `commit: false` |
|---|---|---|---|
| has artifact-producing step | `per-map-item` | `true` | validator error (worktrees cannot inherit uncommitted files) |
| has artifact-producing step | `shared` | `true` | warning |
| has artifact-producing step | `inline` or absent | `true` | allowed |
| none | any | `false` | allowed (no-op) |

A commit failure is fatal only when `artifacts.commit` is explicitly `true` and per-map-item isolation is required.

## 11. Skills, Workspace and Runtime Artifacts

### 11.1 Skill resolution and preflight

AndThen skills are referenced by canonical name (`andthen:plan`) and are an operator-installed prerequisite; DartClaw does not clone or install them ([ADR-040](../adrs/040-andthen-skills-via-canonical-name-resolution.md), [ADR-025](../adrs/025-andthen-as-runtime-prerequisite.md); operator usage in [`docs/guide/andthen-skills.md`](../../docs/guide/andthen-skills.md)). Four DC-native skills ship as package assets listed in `packages/dartclaw_workflow/skills/dartclaw-native-skills.txt`: `dartclaw-discover-andthen-spec`, `dartclaw-discover-andthen-plan`, `dartclaw-validate-workflow`, `dartclaw-merge-resolve`. `SkillProvisioner` copies them into `<dataDir>/.agents/skills/` (Codex) and `<dataDir>/.claude/skills/` (Claude Code) at `dartclaw serve` startup and before a standalone run, purges managed `dartclaw-*` skills the manifest no longer lists, and links configured project workspaces.

Runtime preflight (`workflow_skill_preflight.dart`, [ADR-026](../adrs/026-skill-reference-validation-via-harness-introspection.md)) resolves each agent step's effective provider, probes provider authentication, then calls `SkillIntrospector.listAvailable()` once per provider and executable. The authored name is used when visible; Codex also accepts the hyphenated form (`andthen-plan` for `andthen:plan`). Missing skills or an unauthenticated provider throw `WorkflowPreflightException` before any dispatch. Each CLI probe owns and disposes its `ProviderProbeEnvironment`. There is no DartClaw skill-discovery registry in the execution path.

### 11.2 Workflow workspace

Workflow steps do not inherit the interactive workspace's behaviour files. The engine passes a dedicated workspace through `AgentExecution.workspaceDir`: by default `<dataDir>/workflow-workspace/` holding a built-in `AGENTS.md`, reconciled against a `.dartclaw-managed.json` marker so local edits are kept; or `workflow.workspace_dir`, which is operator-owned and never touched. Multi-prompt follow-up turns reuse the same directory.

### 11.3 Run directory

`<dataDir>/workflows/runs/<runId>/` (`workflow_run_paths.dart`; `runId` must match `^[A-Za-z0-9_-]+$`):

- `context.json`: atomic snapshot of `WorkflowContext`
- `runtime-artifacts/`: engine-managed files. `reviews/` (the `--output-dir` for review reports), `merge-resolve/`, and `steps/<stepId>[-<i>]/`, a task's host-owned artifacts directory exposed to the agent as `$DARTCLAW_STEP_ARTIFACTS_DIR` (the orchestrator sets such env vars on process spawn; a skill prompt reads them with the bang operator: a literal `` !`cmd` `` runs before the model sees the skill and its stdout replaces it, the command text is fixed at authoring, `$VAR` references expand at runtime, and Claude Code and Codex behave the same)

`WorkflowRuntimeArtifactsPruner` applies the `workflow.runtime_artifacts_retention` policy to completed runs.

### 11.4 Resolved definitions

`WorkflowDefinitionResolver` emits a fully merged, round-trippable definition: `stepDefaults` baked into steps, `{{VAR}}` substituted where bindings are supplied (unbound references and `{{context.*}}` stay), and `nodes` recomputed. Every built-in round-trips through resolve, emit and parse. It is surfaced by `GET /api/workflows/definitions/<name>?resolve=true[&step=<id>]` and `dartclaw workflow show --resolved`; it never affects execution.

## 12. Persistence

`WorkflowRunRepository` is storage-agnostic. The server uses `DatabaseWorkflowRunRepository` over the prepared PostgreSQL backend; standalone composition uses `FileWorkflowRunRepository` over the shared `FileExecutionStore` checkpoint, with no database, and polls status so a separate CLI process's pause or cancel reaches the active executor. Task, agent-execution and workflow-step writes share one execution-repository transactor: PostgreSQL provides transaction serialization, the file store holds a process mutex and OS lock and publishes one atomic JSON replacement. Tables and columns: data-model.md.

`stepStatusFromTask` (`workflow_view_helpers.dart`) is the single projection of per-step status used by the API, run page, SSE snapshot and sidebar: task-backed steps use task lifecycle, task-less bash, aggregate and approval steps use step-owned values in the persisted context.

## 13. Relationship to Task Execution

Workflow execution and task execution are separate layers sharing a boundary: workflow steps create tasks, task execution performs the agent turn, and workflow completion derives from task completion plus gate evaluation. Three ADRs define it:

- [ADR-021](../adrs/021-agent-execution-primitive.md): the `AgentExecution` / `WorkflowStepExecution` decomposition.
- [ADR-022](../adrs/022-workflow-run-status-and-step-outcome-protocol.md): run status and the portable step-outcome protocol.
- [ADR-023](../adrs/023-workflow-task-boundary.md): workflows compile to tasks; `TaskExecutor` routes workflow-orchestrated tasks through a leased worker; `dartclaw_workflow` may write `TaskRepository` directly for the atomic three-row insert.

`dev/fitness/test/workflow_task_boundary_test.dart` enforces the import boundary mechanically.

## 14. Wire Formats

### 14.1 HTTP API

| Route | Purpose |
|---|---|
| `GET /api/workflows/definitions` | summary projections (no prompt bodies) |
| `GET /api/workflows/definitions/<name>[?resolve=true[&step=<id>]]` | authored or resolved YAML (`application/yaml`) |
| `POST /api/workflows/run` | start; body `definition`, `variables`, `project`, `approvals`, `allowDirtyLocalPath`, `inline`, `surface` (only `cli`); `201` with the run |
| `POST /api/workflows/run-form` | HTMX launch from `/workflows`; errors return `200` HTML fragments, success `201` with `HX-Location: /workflows/<runId>` |
| `GET /api/workflows/runs[?status=&definition=]`, `GET …/runs/<id>` | list; enriched detail with per-step status, child task ids, pending approval |
| `POST …/runs/<id>/pause`, `/resume`, `/retry`, `/cancel`, `/request-changes` | lifecycle; cancel returns `204` and accepts `feedback`; invalid transitions return `409 INVALID_TRANSITION` |
| `GET …/runs/<id>/events` | per-run SSE stream |

Required variables are validated in `WorkflowService.start`; the route layer only injects `PROJECT` from the project field.

### 14.2 SSE events

The stream sends a `connected` snapshot (run state, token completeness, step statuses), then forwards events whose `type` is:

| Type | Payload |
|---|---|
| `workflow_status_changed` | status transition with token totals, completeness, error |
| `workflow_step_completed` | step result with token count and task id; additive `outcome` and `reason` when recorded |
| `parallel_group_completed` | success and failure counts |
| `loop_iteration_completed` | iteration, max, gate result |
| `map_iteration_completed`, `map_step_completed` | per-item result; foreach aggregate with success, failure, cancelled and blocked counts |
| `task_status_changed`, `workflow_cli_turn_progress` | child task transitions; cumulative tokens per turn |
| `approval_requested`, `approval_resolved` | gate metadata; resolution with feedback, and `changesRequested`, `revision`, `maxRevisions` |

`workflow_budget_warning`, `workflow_serialization_enacted` and `step_skipped` exist on the event bus (`dartclaw_core/lib/src/events/workflow_events.dart`) but this stream does not forward them. SSE mechanics and metrics: observability-operations-architecture.md.

### 14.3 MCP tools

`workflow_list`, `workflow_run`, `workflow_status`, `workflow_resume`, `workflow_cancel`, `workflow_request_changes` (`mcp/`). The run-control tools go through `WorkflowRunControl`.

## 15. Related Documents

- [`docs/guide/workflows.md`](../../docs/guide/workflows.md): authoring reference
- [task-execution-architecture.md](task-execution-architecture.md), [control-protocol.md](control-protocol.md), [cli-api-architecture.md](cli-api-architecture.md), [data-model.md](data-model.md), [security-architecture.md](security-architecture.md), [configuration-architecture.md](configuration-architecture.md)
- ADRs: [016](../adrs/016-multi-provider-harness-architecture.md), [021](../adrs/021-agent-execution-primitive.md), [022](../adrs/022-workflow-run-status-and-step-outcome-protocol.md), [023](../adrs/023-workflow-task-boundary.md), [024](../adrs/024-workflow-step-semantics.md), [025](../adrs/025-andthen-as-runtime-prerequisite.md), [026](../adrs/026-skill-reference-validation-via-harness-introspection.md), [033](../adrs/033-architectural-governance-via-fitness-functions.md), [040](../adrs/040-andthen-skills-via-canonical-name-resolution.md), [041](../adrs/041-framework-agnostic-workflow-engine-generic-output-validation.md), [054](../adrs/054-model-first-delegation-and-one-authority-per-concern.md)

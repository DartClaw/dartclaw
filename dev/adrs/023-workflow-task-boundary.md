# ADR-023: Workflow–Task Architectural Boundary

## Status

Accepted — 2026-04-21

## Context

DartClaw ships two orchestration subsystems that share a runtime: the workflow engine in `dartclaw_workflow` and the task orchestrator in `dartclaw_server/src/task/*`. Section 13 of `docs/architecture/workflow-architecture.md` already describes the intent: workflow steps create tasks, task execution performs the actual agent turn or host-side action, and workflow completion is derived from task completion plus gate evaluation. The workflow engine orchestrates the task system, it does not replace it.

The data-layer decomposition that makes that boundary tractable is already in place. ADR-021 extracted `AgentExecution` and `WorkflowStepExecution` as first-class rows so workflow-owned state no longer round-trips through `Task.configJson`. ADR-022 split workflow run status and introduced a portable `<step-outcome>` protocol so gate evaluation does not need to infer intent from task lifecycle state.

What is still missing is a named behavioral contract. Three code-level realities currently look like they could be accidental coupling unless the intent is recorded:

- `TaskExecutor` branches on `_isWorkflowOrchestrated(task)` and routes workflow-orchestrated tasks through `_executeWorkflowOneShotTask()` via `WorkflowCliRunner` instead of the interactive harness-pool path.
- `dartclaw_workflow` writes a `Task` row directly through `TaskRepository.insert()` rather than going through `TaskService.create()`.
- Host-executed steps (`bash`, `approval`) run entirely inside the workflow engine and never materialize a `Task`. The `foreach` controller is also host-executed and zero-task, but it dispatches child steps that do compile to tasks whenever those children are agent steps.

A fresh reader could plausibly flag any of these as layering violations. ADR-023 names them as the intended model so future cleanups do not accidentally erase them.

## Decision

Formalize three behavioral commitments that define the workflow–task boundary.

1. **Workflows compile to tasks.** Every workflow agent step creates a `Task`. The workflow engine does not own a parallel execution stack for agent work. Host-executed steps `bash` and `approval` are zero-task by design. The `foreach` controller is also host-executed and zero-task, but that is a statement about the controller itself: its child steps still compile to tasks whenever those children are agent steps, so a `foreach` scope can and routinely does materialize tasks through its children.

2. **`TaskExecutor` is aware of workflow orchestration and routes deliberately.** The `_isWorkflowOrchestrated(task)` branch and the `_executeWorkflowOneShotTask()` path (via `WorkflowCliRunner`) are intentional, not a refactor target. Workflow-orchestrated tasks execute as a one-shot CLI invocation rather than via the interactive harness pool because a workflow step is a bounded prompt-chain, not a long-lived conversation. The interactive path remains the default for everything else.

3. **`dartclaw_workflow` may write to `TaskRepository` directly.** `TaskService.create()` is intentionally bypassed for the narrow purpose of atomically inserting the three-row chain (`Task` + `AgentExecution` + `WorkflowStepExecution`) in a single transaction. All reads and lifecycle transitions still go through the narrow `WorkflowTaskService` interface defined in `dartclaw_core`. The direct-insert affordance is scoped to creation and must not be widened.

## Consequences

### Positive

- The boundary is an explicit contract rather than an implicit convention, so future contributors can reason about where workflow logic belongs and where task logic belongs.
- Accidental coupling is less likely. Changes that try to grow a parallel workflow execution stack, or that try to push workflow state back through `Task.configJson`, now have a named ADR to push back against.
- The decomposition already paid for by ADR-021 and ADR-022 is protected. Those ADRs reshaped data; this one protects the behavior that depends on that reshape.

### Negative

- `TaskExecutor` carries two execution paths (interactive harness pool vs. workflow one-shot) that must stay synchronized for cross-cutting concerns such as cancellation, timeout, artifact capture, and progress events.
- New contributors need to learn both paths before touching task execution. The branch on `_isWorkflowOrchestrated` is load-bearing and not self-explanatory at the call site.
- The direct-insert affordance in `dartclaw_workflow` is a narrow exception to the usual rule that domain packages go through services. It needs a fitness function to stay narrow.

## Alternatives Considered

### Extract a shared `ExecutionRunner` primitive beneath both paths

Rejected as speculative. Only one non-interactive use case exists today (workflow steps). Introducing a shared abstraction now would be driven by symmetry rather than real pressure. Revisit if a second non-interactive execution use case lands (for example, scheduled agent tasks with a fixed prompt set).

### Make workflows bypass `Task` entirely with their own `WorkflowStepRun` row type

Rejected. Workflow agent steps need the same artifact pipeline, event bus, SSE surface, review flow, and dashboard presence that tasks already have. Duplicating those concerns against a parallel row type would cost a lot and buy nothing that the current design does not already give us.

### Route workflow task creation through `TaskService.create()`

Rejected. `TaskService.create()` operates on a single `Task` row. Workflow creation needs to insert `Task`, `AgentExecution`, and `WorkflowStepExecution` in one transaction so a partial write cannot leave the workflow engine holding a dangling task reference. The direct `TaskRepository.insert()` call is the only path that exposes that transactional shape.

## References

- [ADR-021: AgentExecution Primitive](021-agent-execution-primitive.md)
- [ADR-022: Workflow Run Status Split and Step Outcome Protocol](022-workflow-run-status-and-step-outcome-protocol.md)
- [Workflow architecture](../architecture/workflow-architecture.md)
- Workflow–task boundary fitness function: [`../../packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart`](../../packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart)

## Addendum — 2026-05 — `WorkflowCliRunner` Ownership

**Decision**: `WorkflowCliRunner` remains in `dartclaw_server` as the concrete one-shot process adapter. Per-provider command construction, parsing, and temp-file lifecycle are isolated behind a `CliProvider` interface (`ClaudeCliProvider`, `CodexCliProvider`) that is also server-owned. Portable request/value types (`CliTurnRequest`) and reusable helpers stay in `dartclaw_server` for now; promotion to `dartclaw_core` is deferred until a second consumer appears.

**Rationale**: The `ContainerExecutor` collaborator that providers depend on is server-owned (see `dartclaw_server/CLAUDE.md` boundary rule: "Container orchestration lives here, not in core — don't move it down"). Promoting `CliProvider` or `WorkflowCliRunner` to `dartclaw_core` would invert the package dependency graph. The `CliProvider` seam delivers the encapsulation goal — per-provider isolation, "new file, no runner edit" for future providers such as Ollama or a generic OpenAI-compatible CLI — without forcing a premature core promotion.

**Out of scope for 0.16.5**: Full harness-dispatched rewrite (replacing `WorkflowCliRunner`'s one-shot process adapter pattern with reuse of `AgentHarness` interactive-mode infrastructure). That rewrite remains a future option but is not part of 0.16.5's stabilisation theme and would widen blast radius beyond what the milestone tolerates.

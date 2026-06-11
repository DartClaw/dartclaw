# ADR-021: AgentExecution Primitive

## Status

Accepted — 2026-04-19

## Context

Before S32-S35, workflow-owned execution state was split across three places:

- task-owned runtime columns such as `session_id`, `provider`, and `max_tokens`
- workflow-private `_workflow*` blobs persisted inside `Task.configJson`
- implicit runtime-only state reconstructed inside `TaskExecutor`

That arrangement created avoidable coupling. The workflow package depended on task-owned persistence details, the task subsystem carried workflow-only data it did not own, and the API surface could not represent execution metadata cleanly without either duplicating fields or leaking implementation details. The decomposition research for 0.16.4 concluded that the shared runtime state below Task and workflow step execution should be modeled as its own primitive with explicit fitness functions to keep the boundary from regressing.

## Decision

Extract `AgentExecution` as the shared runtime primitive for provider/session/model/workspace/token-budget state, and pair it with a dedicated `WorkflowStepExecution` row for workflow-only metadata.

The resulting structure is:

```text
Task
  -> agentExecutionId -> AgentExecution
Task
  -> workflowStepExecution -> WorkflowStepExecution
WorkflowStepExecution
  -> agentExecutionId -> AgentExecution
```

Key consequences of the decision:

- `Task` retains task-owned lifecycle, review, artifact, and worktree concerns
- `AgentExecution` owns runtime execution metadata that can outlive any single task shape
- `WorkflowStepExecution` owns workflow-only metadata that used to live in `_workflow*` task JSON
- `Task.toJson()` exposes nested `agentExecution` and `workflowStepExecution` objects instead of duplicating those fields at the top level
- five fitness functions enforce the decomposition mechanically

## Consequences

### Positive

- The workflow/task boundary is explicit and easier to reason about.
- API, CLI, and UI consumers can read execution state from typed nested objects instead of inference from flattened task fields.
- TaskExecutor no longer needs to reconstruct workflow context from scattered task fields and JSON blobs.
- Storage now has a clear place for future AE-without-Task scenarios if the runtime needs them later.

### Negative

- The migration is multi-stage and touches persistence, API shape, and tests together.
- Existing internal consumers of flattened task JSON had to be updated in one coordinated cutover.
- Fitness functions introduce new guardrail scripts and allowlist maintenance.

## Alternatives Considered

### Keep legacy flattened task fields and add nested objects

Rejected. DartClaw is still soft-published, so carrying both shapes would create long-lived debt without protecting a real external ecosystem.

### Expose AgentExecution only through a separate endpoint

Rejected. That would make execution metadata second-class and force every task consumer to issue follow-up lookups.

### Leave the boundary unenforced

Rejected. The research explicitly called out boundary drift as the main failure mode. The decomposition is only valuable if regressions fail mechanically.

## References

- CHANGELOG `[0.16.4]` — agent execution decomposition shipped; provenance: 0.16.4 PRD, story S32
- [Workflow architecture](../architecture/workflow-architecture.md)
- [Task execution architecture](../architecture/task-execution-architecture.md)
- Research sources are summarized in the linked research appendix.

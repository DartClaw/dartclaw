# ADR-022: Workflow Run Status Split and Step Outcome Protocol

## Status

Accepted — 2026-04-20

## Context

Before S36, workflow runs overloaded `paused` for three different situations:

- an operator deliberately pausing a run
- an approval gate waiting on a human
- a real workflow failure

That conflation leaked into the UI, alerting, SSE, and recovery paths. Operators could not tell whether a run was healthy-but-blocked or genuinely broken without drilling into error text. At the same time, the executor inferred step intent from task lifecycle state alone, which meant review-style steps had no portable way to say "this completed successfully as a task, but semantically the workflow should fail or wait for input".

The multi-provider workflow runtime needed a small, provider-agnostic protocol that works across Claude, Codex, and future harnesses without relying on provider-native structured-finish surfaces.

## Decision

Adopt two coupled changes:

1. Split workflow run status into:
   - `paused` for deliberate operator holds only
   - `awaitingApproval` for approval-gated and `needsInput` holds
   - `failed` for runtime, gate, and step failures

2. Add a portable step-outcome protocol:

```text
<step-outcome>{"outcome":"succeeded|failed|needsInput","reason":"..."}</step-outcome>
```

The executor appends this instruction automatically unless a step or skill opts out with `emitsOwnOutcome: true`.

The executor writes semantic outcome state into workflow context as:

- `step.<id>.outcome`
- `step.<id>.outcome.reason`

If the marker is missing, the executor falls back to task lifecycle status, logs a warning, and increments the `workflow.outcome.fallback` counter.

## Consequences

### Positive

- Operators can distinguish "waiting on a human" from "broken" at a glance.
- Failed runs gain an explicit retry path (`WorkflowService.retry`, HTTP route, CLI command, Retry UI).
- Gate expressions can reason about semantic step outcome without changing the gate evaluator.
- The protocol is portable across harnesses because it is plain text, not provider-specific metadata.

### Negative

- More state combinations must be reflected in tests, SSE consumers, UI helpers, and docs.
- Legacy persisted `paused` rows require a one-shot migration.
- Prompt augmentation grows slightly for agent steps that do not emit their own outcome marker.

## Alternatives Considered

### Keep `paused` and add a `pauseReason`

Rejected. Every consumer would have to inspect two fields to answer a basic lifecycle question, and the cognitive cost would continue indefinitely.

### Put outcome metadata inside `<workflow-context>`

Rejected. Outcome is executor metadata, not domain output. Mixing the two would reserve keys inside user-authored schemas and make prompt contracts harder to reason about.

### Use provider-native structured completion only

Rejected. The workflow runtime is multi-harness by design. Provider-native finish surfaces can be added later as an optimization, but the baseline protocol must be portable.

## References

- CHANGELOG `[0.16.4]` — workflow run status and step outcome protocol shipped; provenance: 0.16.4 PRD, story S36
- [Workflow architecture](../architecture/workflow-architecture.md)
- [Public workflow guide](../../docs/guide/workflows.md)

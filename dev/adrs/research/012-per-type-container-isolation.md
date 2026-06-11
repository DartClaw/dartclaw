# ADR-012 Research Appendix: Per-Type Container Isolation

> Frozen synthesis supporting [ADR-012](../012-per-type-container-isolation.md). Point-in-time as of the decision date; not maintained as the design evolves.

## Question
What isolation granularity should DartClaw use for different task and agent types?

## Options considered
- Single shared container — cheapest, but weak blast-radius control.
- Per-agent containers — strong isolation, but operationally heavier.
- Per-type isolation — separates risk classes while keeping pool management tractable.

## Trade-off summary
Per-type isolation balances security with runtime complexity for a single-host orchestrator.

## Deciding evidence
Container and task-orchestrator research showed materially different risk profiles across task types, making a single shared container too broad.

## Sources (private)
- `docs/research/per-agent-container-isolation`
- `docs/research/task-orchestrator/research.md`

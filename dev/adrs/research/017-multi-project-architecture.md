# ADR-017 Research Appendix: Multi-Project Architecture

> Frozen synthesis supporting [ADR-017](../017-multi-project-architecture.md). Point-in-time as of the decision date; not maintained as the design evolves.

## Question
How should DartClaw represent multiple projects and external repositories?

## Options considered
- Single implicit workspace — simple, but does not support durable multi-project operation.
- Project model with external repo support — explicit ownership, state, and isolation boundaries.
- Clone-and-forget task workspaces — useful for tasks, but insufficient as product structure.

## Trade-off summary
An explicit Project model adds schema and UI/API surface, but gives the runtime a stable domain concept for multi-repo work.

## Deciding evidence
The benchmark across agent tools found recurring needs for project identity, repo mapping, and blast-radius control.

## Sources (private)
- `docs/research/multi-project-support/research.md`
- `docs/research/task-orchestrator/research.md`

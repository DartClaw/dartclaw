# ADR-011 Research Appendix: Lightweight Event Bus for Internal Decoupling

> Frozen synthesis supporting [ADR-011](../011-event-driven-architecture.md). Point-in-time as of 2026-03-09; not maintained as the design evolves.

## Question
How should task, harness, and container lifecycle changes be represented across the runtime?

## Options considered
- Direct service calls — simple initially, but couples producers to every consumer.
- Central event model — decouples lifecycle producers from observers and channel updates.
- External broker — scalable but unnecessary for the early single-host runtime.

## Trade-off summary
An in-process event model keeps the runtime small while preserving clear lifecycle seams for future persistence and UI streaming.

## Deciding evidence
Task orchestrator research identified lifecycle events as the shared substrate for channels, audit, state updates, and future observability.

## Sources (private)
- `docs/research/event-driven-architecture/research.md`
- `docs/research/task-orchestrator/research.md`

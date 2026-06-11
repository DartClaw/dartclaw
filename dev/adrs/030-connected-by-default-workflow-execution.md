# ADR-030: Connected-by-Default Workflow Execution — CLI Routes Through the Server API, Standalone Is Opt-In

## Status

Accepted — 2026-05-31 (implemented in 0.16.4; recorded retroactively during an ADR-gap review of 0.16.4–0.16.6)

**Related:** [ADR-021](021-agent-execution-primitive.md), [ADR-022](022-workflow-run-status-and-step-outcome-protocol.md), [ADR-023](023-workflow-task-boundary.md), [ADR-024](024-workflow-step-semantics.md) (the workflow platform this CLI path drives); [ADR-002](002-file-based-storage.md) (the SQLite single-writer constraint that motivates the standalone guard).

## Context

`dartclaw workflow run` and `workflow status` originally executed in-process (standalone). That path bypassed the running server's guard chain, persistence, and observability, and — critically — a standalone CLI process plus a server accessing the same data dir are concurrent SQLite writers, which risks database corruption. As the workflow platform matured in 0.16.4 (operational command groups, lifecycle controls, trigger surfaces), two divergent execution paths with different security and state guarantees became untenable.

## Decision

`workflow run` and `workflow status` default to the running server's HTTP API. `DartclawApiClient` powers server-backed execution, lifecycle control, and SSE progress streaming, with loopback server detection. `--standalone` opts into in-process execution; a safety guard aborts `workflow run --standalone` when a server is already running against the same data dir, unless `--force` is passed. `workflow status --standalone` remains available for direct local-DB inspection. Standalone is positioned as a reduced-capability fallback, not the default.

## Consequences

### Positive

- All CLI-initiated workflows share one guard / persistence / observability path with server- and channel-triggered runs.
- The standalone safety guard closes the concurrent-SQLite-writer corruption risk.
- Execution mode is an explicit, predictable contract rather than implicit auto-switching.

### Negative

- Breaking change to CLI workflow semantics — CI/CD scripts that ran `workflow run` in-process must now pass `--standalone` (and `--force` when a server is up).
- The default path requires a running server, adding a precondition to the simplest CLI invocation.

## Alternatives Considered

1. **Keep standalone as the default** — rejected: bypasses the guard chain and observability and leaves the data-corruption risk unaddressed.
2. **Warn and continue when a server is running** — rejected: invites state divergence between the in-process run and the server's view of the same data dir.
3. **Auto-connect transparently from standalone invocations** — rejected: muddies the explicit mode contract and hides which engine actually executed the workflow.

## References

- CHANGELOG `[0.16.4]` — Added: Connected CLI workflow client (`DartclawApiClient`); Changed: `workflow run`/`workflow status` connected-by-default, Standalone safety guard
- `apps/dartclaw_cli/lib/src/dartclaw_api_client.dart`; `apps/dartclaw_cli/lib/src/commands/workflow/`
- Public CLI operations guide (connected mode, standalone mode, server detection, auth)
- 0.16.4 PRD.

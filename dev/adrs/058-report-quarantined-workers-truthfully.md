# ADR-058: Report Quarantined Workers Truthfully

## Status

Accepted – 2026-08-21 (0.25 S75/TD-125 decision).

The user explicitly delegated all blocker and architecture decisions and required autonomous completion. Under that authority, this ADR records the defensible option as accepted rather than leaving an implementation-blocking Proposed decision.

**Related:** [ADR-016](016-multi-provider-harness-architecture.md) (the execution coordinator and quarantine authority), [ADR-054](054-model-first-delegation-and-one-authority-per-concern.md) (deterministic lease/capacity/quarantine invariants and one authority), [ADR-021](021-agent-execution-primitive.md) (execution identity).

## Context

An unconfirmed worker teardown is a stronger condition than an ordinary stop. DartClaw has attempted to terminate the harness and revoke its authority, but cannot prove the managed root process or container authority is gone. The execution coordinator therefore permanently withholds that provider-capacity slot for the rest of the process, preventing an overlapping replacement.

Capacity reporting is truthful, but runner reporting is not. `_disposeWorker` publishes `disposed` and removes the runner ID before any caller knows whether it must publish `quarantined`. Each later quarantine event therefore carries no runner ID. `RunnerObserver` reports the observed runner as `stopped`, removes its metrics, and cannot execute its existing `quarantined -> crashed` mapping. Operators see `busy -> stopped` for the runner while provider capacity separately degrades.

S75 exposed this as TD-125. Its original “no wire change” boundary conflicts with its acceptance requirement that a quarantined leased runner report `crashed`. Pre-alpha compatibility does not justify a false terminal state, especially for a safety condition that intentionally prevents replacement.

### Decision drivers and weights

| Criterion | Weight |
|---|---:|
| Correctness and operator truth | 30% |
| Lease/capacity/quarantine invariant preservation | 25% |
| One-authority simplicity | 20% |
| Wire/API impact | 15% |
| Testability | 10% |

The first three are decisive. Breaking behavioral changes are acceptable at DartClaw's current stage; new vocabulary or a second lifecycle authority is not.

## Decision

**The execution coordinator publishes one terminal outcome for every observed worker teardown: `disposed` when teardown is confirmed, or `quarantined` when it is not.**

The physical teardown attempt still runs first: stop/dispose the harness, revoke release hooks, and attempt container destruction. Once the typed teardown result and root-process confirmation are known:

1. For an unconfirmed teardown, the coordinator quarantines the permit or available slot before publishing `quarantined` with the worker's existing runner ID.
2. For a confirmed teardown, it publishes `disposed` with that ID.
3. It then detaches the outcome observer and removes runner-ID bookkeeping. It does not publish both terminal events for one teardown.

`RunnerObserver` remains a projection, not a lifecycle authority. It maps `quarantined` to `WorkerState.crashed`, clears current task/session ownership, and retains that terminal metrics tombstone. It removes metrics on `disposed`. It never reconstructs quarantine from capacity deltas, disposal timing, harness state, or logs.

The later generic lease-release notification must not overwrite a crashed tombstone. No new enum, JSON field, SSE type, or status string is introduced. The existing `crashed` value becomes reachable on `runner_state`, and `/api/runners` retains the crashed tombstone until process restart. This is an accepted behavioral wire change.

Pre-registration factory failures remain capacity-only when no stable observed runner ID exists. The decision does not fabricate identities. Retained tombstones are bounded by configured capacity because every tombstone corresponds to a capacity slot permanently quarantined for that process.

**Coordinator shutdown is the one teardown where the withholding step is skipped.** Every gate is already closed, so `quarantineAvailableSlot` has nothing to withhold and no replacement can be admitted at all; the terminal outcome is still published truthfully rather than downgraded to `disposed`, because a teardown that could not be confirmed must not read as a clean one on the way out. That is the only case where a tombstone has no matching quarantined slot, and it is bounded by the same configured capacity.

This refines ADR-016's observability consequence. It does not change its replacement gate, capacity arithmetic, quarantine lifetime, or coordinator ownership.

## Consequences

### Positive

- Operator surfaces report the safety outcome that admission actually enforces.
- Capacity is already degraded when the crash event is observed.
- One typed coordinator event carries causality and identity; observers do no timing-based reconstruction.
- `disposed` and `quarantined` become mutually exclusive terminal meanings rather than two ordered cleanup notifications.
- The change uses the existing `WorkerState.crashed`, runner ID, REST shape, and SSE frame type.
- Terminal retention is bounded without keeping a reusable runner or adding a coordinator quarantine registry.

### Negative

- SSE clients receive a `crashed` runner-state frame that current code never emits for this path.
- `/api/runners` includes a crashed terminal tombstone even though the underlying runner object has been disposed as far as safely possible.
- Any consumer that assumed every worker disappears immediately after physical disposal must adopt the terminal-observation semantics.
- Tombstones remain until restart because quarantined capacity is not recoverable within the current process.

## Alternatives Considered

1. **Publish quarantine before the physical teardown attempt** – rejected. Release-hook and container-destroy failures do not exist until the attempt runs; early classification would guess at a deterministic safety verdict. The accepted ordering is after the attempt but before lifecycle disposal publication.
2. **Publish `disposed`, retain the identity, then publish `quarantined`** – rejected. One runner would receive two terminal outcomes, and the observer would remove then resurrect its metrics or carry pending-disposal state. That is more mechanism and less truthful semantics.
3. **Reconstruct a crash in `RunnerObserver`** – rejected. Disposal plus provider-capacity change does not uniquely identify a runner, and capacity-only quarantine intentionally has none. Reconstruction would create a second lifecycle authority and a timing contract.
4. **Delete the unreachable crashed mapping and report only quarantined capacity** – rejected. It preserves wire behavior by knowingly reporting the runner as `stopped`; indirect capacity truth does not make the runner-state lie acceptable.
5. **Keep quarantined runner objects in a coordinator registry** – rejected. A new registry and object-lifetime policy are unnecessary. A typed terminal event lets the existing observer retain bounded immutable metrics without retaining executable authority.

## Implementation Notes

- Refactor the teardown helper so the caller receives confirmation before any terminal lifecycle event or ID removal.
- Centralize terminal publication and identity cleanup in one coordinator helper; do not duplicate the ordering across `_release`, `_discardWorker`, and session-continuity reset.
- Commit quarantine accounting before the terminal event.
- Ensure generic `released` publication after quarantine has no runner ID or otherwise cannot alter retained crashed metrics.
- Cover active release, cached discard/session reset, exact SSE ordering, REST tombstone contents, cleared task/session IDs, permanent capacity reduction, idempotent release, and replacement refusal.
- Keep the no-ID factory-failure path capacity-only.
- Amend the S75 FIS through the deterministic design-change path before implementation: replace its stale no-wire-change clause with the existing-value behavioral exception recorded here.

## Project Compliance

- **Pragmatic and lightweight:** reorders one existing lifecycle seam and reuses existing event, state, ID, and metrics types.
- **Root cause over workaround:** fixes premature terminal publication instead of correlating unrelated observations.
- **One authority per concern:** the execution coordinator alone classifies teardown; `RunnerObserver` projects its typed result.
- **Deterministic keeps:** all teardown, quarantine, capacity, and replacement decisions remain host-side under ADR-054.
- **Predictable and auditable:** one teardown has one terminal outcome, with capacity state committed before publication.

## References

- `packages/dartclaw_server/lib/src/execution_coordinator.dart`
- `packages/dartclaw_server/lib/src/execution_coordinator_lifecycle.dart`
- `packages/dartclaw_server/lib/src/execution_coordinator_observability.dart`
- `packages/dartclaw_server/lib/src/task/runner_observer.dart`
- `packages/dartclaw_server/test/task/runner_observer_test.dart`
- `packages/dartclaw_server/test/execution_coordinator_test.dart`
- `dev/bundle/docs/specs/0.25/s75-one-worker-status-vocabulary.md`
- `dev/state/TECH-DEBT-BACKLOG.md#td-125--worker-quarantine-is-never-reported-as-crashed-unreachable-quarantined-arm-in-runnerobserver`
- Trade-off artifacts: `../../.agent_temp/reports/s75-quarantine-decision/s75-quarantined-worker-lifecycle/`

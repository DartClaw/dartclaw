# ADR-028: Unified Workflow Step Retry Authority

## Status

Accepted — 2026-05-30 (implemented in 0.17; recorded retroactively during the S11 milestone-documentation pass)

**Related:** [ADR-022](022-workflow-run-status-and-step-outcome-protocol.md) (step-outcome protocol — retry now triggers on failed outcome envelopes, not only task crashes), [ADR-024](024-workflow-step-semantics.md) (step semantics).

## Context

A workflow step's `maxRetries` drove **two independent** retry mechanisms:

- **Layer A — task-runtime retry** in `dartclaw_server` (`TaskFailureHandler.markFailedOrRetry`), which re-runs a failed task up to its `Task.maxRetries`.
- **Layer B — workflow outcome-retry** in the executor, which re-dispatches a step based on its `onFailure`/`maxRetries` policy.

Because both read the same `maxRetries`, they **multiplied**: a step with `maxRetries: 1` could execute up to 4 times, and the effective count differed per dispatch path (single step vs `map` item vs `foreach` inner step). The two layers also disagreed on what counts as a failure — Layer A retried only task crashes, while a workflow step can fail on a completed-but-failed `<step-outcome>` envelope (ADR-022), a post-task validation failure, or a missing declared artifact. The result was unpredictable retry budgets and expensive deterministic failures consuming the full multiplied budget.

## Decision

**Make workflow `onFailure: retry` the single retry authority for workflow-spawned tasks.**

1. **Disable Layer A for workflow-owned retries.** Dispatchers pass `maxRetries: 0` for tasks spawned from `onFailure: retry` steps, so task-runtime retry cannot multiply the workflow-owned retry budget. Workflow steps without `onFailure: retry` keep the authored task-runtime retry budget for crash recovery.
2. **One workflow-owned budget.** `onFailure: retry` + `maxRetries: N` means **at most `N + 1` total attempts** uniformly across single steps, parallel `map` items, and `foreach` inner steps. The shared retry helper lives in `dartclaw_workflow`.
3. **Outcome-aware triggering.** Workflow retry fires on the full outcome-failure set — task crash, failed `<step-outcome>`, post-task validation failure, and missing declared artifact — uniformly across all dispatch paths.
4. **Deterministic-failure short-circuit.** When consecutive attempts normalize to the **same error class**, the helper stops early (before exhausting `N + 1`) and surfaces that error, preserving the deterministic-failure guard without reintroducing a second retry layer.
5. **Non-workflow tasks unchanged.** Channel-triggered and manual tasks keep Layer A (`TaskFailureHandler.markFailedOrRetry`) exactly as before; `dartclaw_server` retry code stays uncoupled from workflow outcome semantics.

## Consequences

### Positive

- `maxRetries: N` is now honest and path-independent — `N + 1` attempts whether single, `map`, or `foreach`. No hidden multiplication.
- Retry covers semantic workflow failures (failed outcome, missing artifact, validation), not just process crashes — matching ADR-022's outcome model.
- Expensive deterministic failures stop early instead of burning the whole budget.
- The boundary is clean: the shared helper is in `dartclaw_workflow`; server retry stays for non-workflow tasks; no new cross-package `lib/src/` import.

### Negative

- Retry semantics now differ by workflow failure policy. Readers of a workflow-spawned task's row must know that `Task.maxRetries == 0` means retry is owned upstream only for `onFailure: retry` steps; non-retry workflow steps can still use task-runtime retry.
- The short-circuit depends on error-class normalization; a too-coarse classifier could stop early on genuinely distinct transient errors, and a too-fine one weakens the guard. The normalization is the load-bearing tuning point.
- More failure-path combinations to cover in tests (single/map/foreach × task-crash/outcome-failure/missing-artifact), plus the resume invariants below.

## Alternatives Considered

1. **Keep both layers, document the multiplication** — rejected: the effective attempt count stays path-dependent and surprising; operators cannot reason about `maxRetries` without knowing the dispatch internals.
2. **Disable Layer B, let task-runtime retry own everything** — rejected: task-runtime retry is crash-only and lives in `dartclaw_server`; it cannot see workflow outcome failures (failed `<step-outcome>`, missing artifact, validation), and routing those back would couple the server retry path to workflow semantics.
3. **Per-step flag to choose which layer wins** — rejected: adds an authoring knob for an internal accident; YAGNI. One authority is simpler and removes the failure mode entirely.

## Implementation Notes

- FIS provenance: 0.17 maintainer workflow, unify-workflow-step-retry.
- Seam: `step_dispatcher.dart` and `map_iteration_dispatcher.dart` pass `maxRetries: 0` for `onFailure: retry` tasks. `workflow_task_factory.dart` persists the dispatch-provided value, so `fail`/`continue`/`pause` steps can retain Layer A when they author `maxRetries`.
- Resume invariants preserved: the parallel `_parallel.failed.stepIds` resume path and the `foreach` iteration cursor still re-attempt correctly after the retry change — no double-execution on resume, no permanently-undispatchable items.
- Built-in review steps now retry transient failures instead of aborting the whole review block.
- Documented in `dev/architecture/workflow-architecture.md` (workflow-owned retry budget, early-stop exception, unchanged non-workflow path) and the public workflows guide.

## Project Compliance

- Honors package boundaries (`DART-PACKAGE-GUIDELINES`): the shared helper stays in `dartclaw_workflow`; no new cross-package `src/` edge; server retry decoupled.
- Tests verify intent (exact attempt counts per path, outcome-aware retry, early stop), not just "it retried" — per the testing guardrail.
- Continuity with ADR-022/024: retry reasons over the portable step-outcome protocol rather than provider-native signals.

## References

- [ADR-022: Workflow Run Status and Step Outcome Protocol](022-workflow-run-status-and-step-outcome-protocol.md)
- [ADR-024: Workflow Step Semantics](024-workflow-step-semantics.md)
- FIS provenance: 0.17 maintainer workflow, unify-workflow-step-retry.
- [Workflow architecture](../architecture/workflow-architecture.md) (workflow-owned retry budget)
- [Public workflow guide](../../docs/guide/workflows.md)

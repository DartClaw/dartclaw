# Workflow Private Context Keys

Private context keys (underscore-prefixed) are persisted in `WorkflowRun.contextJson` and survive
crash/resume. Stability is load-bearing: changing a key name or JSON shape without a migration
breaks in-flight runs.

## Namespaces

### `_map.current.*`

Set by `_persistMapProgress` in `map_iteration_runner.dart`. Cleared when the map step exits.

| Key | Type | Semantics |
|-----|------|-----------|
| `_map.current.stepId` | `String` | ID of the map step currently executing |
| `_map.current.total` | `int` | Total number of iterations |
| `_map.current.completedIndices` | `List<int>` | Settled (success/fail/cancel) indices |
| `_map.current.failedIndices` | `List<int>` | Failed iteration indices |
| `_map.current.cancelledIndices` | `List<int>` | Cancelled iteration indices |

Per-step promoted-IDs tracking (also under `_map.*`):

| Key | Type | Semantics |
|-----|------|-----------|
| `_map.<stepId>.promotedIds` | `List<String>` | Story IDs successfully promoted to integration branch |

### `_foreach.current.*`

Set by `_persistForeachProgress` in `foreach_iteration_runner.dart`. Cleared when the foreach step exits.

| Key | Type | Semantics |
|-----|------|-----------|
| `_foreach.current.stepId` | `String` | ID of the foreach step currently executing |
| `_foreach.current.total` | `int` | Total number of iterations |
| `_foreach.current.completedIndices` | `List<int>` | Settled (success/fail/cancel) indices |
| `_foreach.current.failedIndices` | `List<int>` | Failed iteration indices |
| `_foreach.current.cancelledIndices` | `List<int>` | Cancelled iteration indices |

### `_loop.current.*`

Set by `loop_step_runner.dart` and `_persistLoopStepCheckpoint`.

| Key | Type | Semantics |
|-----|------|-----------|
| `_loop.current.id` | `String` | ID of the loop currently executing |
| `_loop.current.iteration` | `int` | Current loop iteration (1-based) |
| `_loop.current.stepId` | `String?` | Step ID at which the loop was checkpointed |

### `_loop.<loopId>.foreach.<foreachStepId>[<iterIndex>].*`

Set by `loop_step_runner.dart` (`_writeNestedLoopCheckpoint`) for a loop nested inside a
`foreach` body. Per-iteration, per-item resume state for the nested loop – kept separate from
the global `_loop.current.*` so one foreach item's loop position never gates or overwrites
another's. Written into the enclosing foreach's run context after every loop body step (so it
survives crash/resume) and cleared when the loop converges or fails for that item. On resume the
foreach re-dispatches the in-progress loop child (it stays absent from
`completedSubStepIdsByIndex`), and the controller restores its position from these keys.

| Key | Type | Semantics |
|-----|------|-----------|
| `_loop.<loopId>.foreach.<foreachStepId>[<iterIndex>].iteration` | `int` | 1-based loop iteration to resume at |
| `_loop.<loopId>.foreach.<foreachStepId>[<iterIndex>].stepId` | `String?` | Loop body step ID to resume at (`null` ⇒ start of iteration) |
| `_loop.<loopId>.foreach.<foreachStepId>[<iterIndex>].tokens` | `int` | Loop-body tokens accumulated so far for this item's loop. Seeds the controller's token accumulator on resume and feeds the in-loop budget check, so a crash-resumed loop neither undercounts the run total nor lets *this loop instance* run past the remaining budget. Tokens of settled or sibling foreach iterations (and pre-loop children) still reach `run.totalTokens` only at foreach completion, but mid-foreach budget checks add them back as an evaluation-only basis: `foreachScopeConsumedTokens` (`workflow_budget_monitor.dart`) sums the persisted `<childId>[<i>].tokenCount` keys plus sibling in-flight `…tokens` checkpoints, and the foreach controller, per-child dispatch, and nested-loop checks (and the 80% warning) pass that sum as `additionalTokens`. Never added to `run.totalTokens` directly – that would double-count with the foreach's completion sum, which remains the single write path. |
| `_loop.<loopId>.foreach.<foreachStepId>[<iterIndex>].iterData` | `Map` | Snapshot of the iteration context (completed body-step outputs), restored so a resumed step sees prior outputs. Holds the loop's bare review keys – never promoted to a top-level key, and dropped when the loop ends. |

### `_parallel.current.*`

Not currently persisted — parallel groups run as a single atomic step with no mid-group
checkpoint. Reserved for future use if parallel-group crash-recovery is added.

### `_merge_resolve.<stepId>.*`

Set by the merge-resolve FSM inside `_resolveMergePromotionConflict` in
`foreach_iteration_runner.dart`. The on-wire JSON shape is **stability-critical** for
crash-recovery: these keys are read on resume to detect in-flight attempts, restore attempt
counters, and determine FSM phase. Do NOT rename them without a migration.

Serialize-drain FSM state:

| Key | Type | Semantics |
|-----|------|-----------|
| `_merge_resolve.serializeRemaining` | `Map?` | Typed state object for a serialize-drain transition (one tracked at a time, scoped by `stepId`). Fields: `stepId` (`String` foreach controller id), `phase` (`'enacting'` / `'drained'`), `iterIndex` (`int` iteration that triggered serialize-remaining), `failedAttemptNumber` (`int` attempt count at escalation time), `eventEmitted` (`bool`, true after the first `WorkflowSerializationEnactedEvent` fires for this serialize-drain transition — the event is emitted once per transition, deduped via this flag). |

Per-iteration per-attempt state:

| Key | Type | Semantics |
|-----|------|-----------|
| `_merge_resolve.<stepId>.<iterIndex>.pre_attempt_sha` | `String` | Branch HEAD SHA captured before the current attempt |
| `_merge_resolve.<stepId>.<iterIndex>.attempt_counter` | `int` | Number of attempts completed so far |

### `_workflow.git.*`

Set by `workflow_git_lifecycle.dart`.

| Key | Type | Semantics |
|-----|------|-----------|
| `_workflow.git.integration_branch` | `String` | Integration branch name for promotion |

### `_workflow.approvals`

Set once by `WorkflowService.start` when the run is created.

| Key | Type | Semantics |
|-----|------|-----------|
| `_workflow.approvals` | `String` | Effective approval-resolution policy for this run: `manual`, `auto-on-stall`, or `auto`. Persisted so resume uses the same policy instead of re-reading process config or invocation flags |

### `_approval.pending.*`

Set by `_transitionStepAwaitingApproval` in `parallel_group_runner.dart`.

| Key | Type | Semantics |
|-----|------|-----------|
| `_approval.pending.stepId` | `String` | Step ID awaiting approval |
| `_approval.pending.stepIndex` | `int` | Step index awaiting approval |

### `_approval.auto_resolved.<stepId>`

Set when `_workflow.approvals` auto-resolves a `needsInput` outcome or explicit approval step.

| Key | Type | Semantics |
|-----|------|-----------|
| `_approval.auto_resolved.<stepId>` | `Map` | Audit record with `policy`, `reason`, `source` (`needsInput` or `approval`), and `resolved_at` |

### `step.<stepId>.outcome` / `step.<stepId>.outcome.reason`

Not `_`-prefixed (these are part of the public step rollup the status table and the
standalone-run digest read), but listed here because the **blocked** value is load-bearing.

| Key | Type | Semantics |
|-----|------|-----------|
| `step.<stepId>.outcome` | `String` | Settle classification: `succeeded`, `failed`, `needsInput`, `skipped`, `blocked`, or `cancelled`. For a `foreach` controller, `blocked` means one or more items emitted `needsInput` (a recoverable hold), distinct from a hard `failed`; the controller's `blocked` reason names the blocked item ids. `cancelled` marks a run-teardown interruption of the step's task (plain step or loop body) — the run pauses resumable, never fails. Recorded only at the controller level — never promoted from inside an iteration, preserving per-iteration isolation. Per-item state lives under the namespaced `step.<childId>[<iterIndex>].outcome`. |
| `step.<childId>[<iterIndex>].outcome` | `String` | Per-item settle classification inside a `foreach` iteration. `cancelled` here marks a run-teardown interruption of a nested-loop body step or a direct child task — the run pauses resumable and `workflow resume` re-runs from the cancelled step. The foreach controller-level `step.<stepId>.outcome` never carries `cancelled` (an interrupted iteration pauses the run instead of settling the controller). |
| `step.<stepId>.outcome.reason` | `String` | Operator-facing reason for the outcome; surfaced inline in the live console and in the settle-time digest. |

A blocked `foreach` item is **retryable**: it is left out of the cursor's `completedIndices`/`failedIndices`,
so a resume re-attempts it. When a still-open story depends on a blocked or hard-failed prerequisite,
the run pauses for a human (`awaitingApproval`) via the existing approval-hold transition; when nothing
open depends on it, independent stories continue and the blocked item is reported in the digest.
An escalation-marked blocked item (nested loop exhausted with `onMaxIterations: escalate`) additionally
carries `requires_dependency_hold: true` in its result slot (`MapStepContext.requiresDependencyHoldKey`) –
engine-owned routing metadata carried from the loop's `StepOutcome.requiresDependencyHold` that forces the
dependency hold even when the controller declares `onFailure: continue` (under which plain hard failures
do not hold).

## Rules

1. New `_`-prefixed keys must extend this documented set with an entry here before landing.
2. Existing key names and JSON shapes must not change without a data migration.
3. Merge sites that copy persisted context use `mergeContextPreservingPrivate` to ensure
   private keys from storage are never shadowed by a stale in-memory copy.

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

### `_parallel.current.*`

Not currently persisted — parallel groups run as a single atomic step with no mid-group
checkpoint. Reserved for future use if parallel-group crash-recovery is added.

### `_merge_resolve.<stepId>.*`

Set by the merge-resolve FSM inside `_resolveMergePromotionConflict` in
`foreach_iteration_runner.dart`. The on-wire JSON shape is **stability-critical** for
crash-recovery: these keys are read on resume to detect in-flight attempts, restore attempt
counters, and determine FSM phase. Do NOT rename them without a migration.

Per-step FSM state (one set per foreach controller step):

| Key | Type | Semantics |
|-----|------|-----------|
| `_merge_resolve.<stepId>.serialize_remaining_phase` | `String?` | `null` / `'enacting'` / `'drained'` |
| `_merge_resolve.<stepId>.serializing_iter_index` | `int` | Iteration that triggered serialize-remaining |
| `_merge_resolve.<stepId>.failed_attempt_number` | `int` | Attempt count at escalation time |

Per-iteration per-attempt state:

| Key | Type | Semantics |
|-----|------|-----------|
| `_merge_resolve.<stepId>.<iterIndex>.pre_attempt_sha` | `String` | Branch HEAD SHA captured before the current attempt |
| `_merge_resolve.<stepId>.<iterIndex>.attempt_counter` | `int` | Number of attempts completed so far |

Run-level deduplication:

| Key | Type | Semantics |
|-----|------|-----------|
| `_merge_resolve.serialize_remaining_event_emitted` | `bool` | `true` after the first `WorkflowSerializationEnactedEvent` fires for this run |

### `_workflow.git.*`

Set by `workflow_git_lifecycle.dart`.

| Key | Type | Semantics |
|-----|------|-----------|
| `_workflow.git.integration_branch` | `String` | Integration branch name for promotion |

### `_approval.pending.*`

Set by `_transitionStepAwaitingApproval` in `parallel_group_runner.dart`.

| Key | Type | Semantics |
|-----|------|-----------|
| `_approval.pending.stepId` | `String` | Step ID awaiting approval |
| `_approval.pending.stepIndex` | `int` | Step index awaiting approval |

## Rules

1. New `_`-prefixed keys must extend this documented set with an entry here before landing.
2. Existing key names and JSON shapes must not change without a data migration.
3. Merge sites that copy persisted context use `mergeContextPreservingPrivate` to ensure
   private keys from storage are never shadowed by a stale in-memory copy.

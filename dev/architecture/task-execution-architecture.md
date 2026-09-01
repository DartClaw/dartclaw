# Task Execution Architecture

How DartClaw creates, schedules, executes, reviews, and observes background tasks. Covers the full pipeline from task creation through coordinator admission, turn execution, artifact collection, and review lifecycle.

**Current through**: 0.25 explicit task worktree declarations, workflow worker leasing, capacity-only lane retirement,
declared task security profiles, category retirement, agent task tools, kernel formation, storage absorption, and turn contract threading for
structured output and provider sessions.

---

## Audience & Scope

This is the **contributor reference**. It documents how the task subsystem is built: the domain model, the execution pipeline and `TaskExecutor`/`_executeCore` internals, coordinator leases and worker reuse, turn execution and trace persistence, declared-worktree merge + PR plumbing, the review concurrency model, and how task events flow through observability. Use it when modifying the orchestrator, worktree lifecycle, or review/merge code paths — or when writing tests against any of those.

For **using tasks** (creating tasks from the Web UI/API, container profile routing in practice, per-task budget overrides, the review user flow, automation and scheduling examples), read [`docs/guide/tasks.md`](../../docs/guide/tasks.md) and [`docs/guide/agents.md`](../../docs/guide/agents.md). This doc keeps the implementation contract — the full state machine including failure/cancel terminals and dispatch routing code paths — rather than re-explaining the user-facing concepts.

---

## 1. Overview

A **task** is a background unit of work executed by an agent harness. Tasks decouple work submission from execution — any surface (Web UI, API, channel message, cron schedule, workflow step) can create a task, and the runtime handles queuing, dispatch, isolation, and review.

Tasks flow through a well-defined state machine, are executed by harness runners acquired from a pool, produce observable events and artifacts, and optionally go through human review before acceptance.

Key design principles:
- **Decoupled creation and execution** — tasks are queued, not executed inline
- **Optimistic locking** — version-based concurrency control prevents lost updates
- **One post-governance execution authority** — task code requests a provider-neutral lease and never manages pool/cache state
- **Capacity independent from owner lifetime** — per-provider leases bound active execution; host harnesses are opportunistically reused, while a logical-agent container is retained only for its exact owner and task/workflow containers end with their turn/step
- **Fail-safe budgets** — budget enforcement defaults to open (proceed) on error
- **Best-effort observability** — event recording never blocks the execution path

---

## 2. Task Domain Model

### 2.1 Package Ownership

The task domain is split across three packages following the DartClaw package decomposition:

```
dartclaw_kernel       TaskStatus and legacy refusal constants
dartclaw_core         Task, TaskStatus, TaskArtifact, Goal, repositories
dartclaw_runtime       TaskService, TaskExecutor, review, worktrees, scheduling
dartclaw_core      SqliteTaskRepository, TaskEventService, TurnTraceService
```

### 2.2 Task

Immutable value object in `dartclaw_core/lib/src/task/task.dart`.

| Field              | Type                    | Purpose                                             |
|--------------------|-------------------------|-----------------------------------------------------|
| `id`               | `String`                | Unique identifier                                   |
| `title`            | `String`                | Short title for lists and review surfaces            |
| `description`      | `String`                | Full task description or operator request            |
| `status`           | `TaskStatus`            | Current lifecycle state                              |
| `goalId`           | `String?`               | Parent goal for hierarchical planning                |
| `acceptanceCriteria` | `String?`             | Criteria used during review                          |
| `agentExecutionId` | `String?`               | FK to the shared `AgentExecution` runtime row        |
| `configJson`       | `Map<String, dynamic>`  | Arbitrary immutable config (frozen on construction)  |
| `worktreeJson`     | `Map<String, dynamic>?` | Git worktree metadata for isolated tasks             |
| `version`          | `int`                   | Optimistic locking version (starts at 1)             |
| `createdBy`        | `String?`               | Display name of requesting person/system             |
| `projectId`        | `String?`               | Target project for worktree creation                 |
| `workflowStepExecution` | `WorkflowStepExecution?` | Hydrated workflow-side execution metadata       |
| `maxRetries`       | `int`                   | Maximum retry attempts (default 0)                   |
| `retryCount`       | `int`                   | Consumed retry attempts                              |
| `createdAt`        | `DateTime`              | Record creation timestamp                            |
| `startedAt`        | `DateTime?`             | First execution start                                |
| `completedAt`      | `DateTime?`             | Terminal state timestamp                             |

Immutability is enforced via `_freezeJsonMap` — both `configJson` and `worktreeJson` are recursively made unmodifiable at construction time. The `copyWith` method uses a sentinel pattern to distinguish "not provided" from explicit `null`.

The familiar convenience accessors still exist on `Task`: `sessionId`, `provider`, `model`, `maxTokens`, `workflowRunId`, and `stepIndex`. Those values resolve through the linked `AgentExecution` and `WorkflowStepExecution` rows instead of being persisted as top-level task fields (see ADR-021).

### 2.3 Execution declarations

Worktree isolation, artifact collection, review routing, prompt composition, and security profile are controlled by
their own declarations and execution context. The legacy SQLite `tasks.type` column remains only for compatibility:
new rows receive a neutral placeholder, while pre-upgrade `research` and undeclared `coding` rows are refused with
migration guidance before execution.

For workflow-owned tasks specifically, authored workflow step types share the task execution path. The authored YAML type is preserved on the hydrated `WorkflowStepExecution` side-table row (`stepType`) for observability and review-mode compatibility, while write intent is expressed through `configJson.readOnly` (set when `step_config_policy.stepIsReadOnly()` holds).

For workflow-owned agent steps, the one-shot branch runs a dedicated no-tools structured finalization turn after the main work turn, emitting a strict execution envelope (`outputs` + `step_outcome`) that the host reads as the only structured payload. Inline `<step-outcome>` parsing is reserved for steps that explicitly set `emitsOwnOutcome`; persisted pre-0.25 turns without an envelope marker fail with a re-run instruction.

### 2.4 TaskStatus State Machine

Defined in `dartclaw_core/lib/src/task/task_status.dart`:

```
                            +-----------+
                            |   draft   |
                            +-----+-----+
                                  |
                      queued      |    cancelled
                  +---------------+----------+
                  |                           |
            +-----v-----+             +------v------+
            |  queued    |             |  cancelled  |  (terminal)
            +-----+-----+             +-------------+
                  |
         running  |    cancelled / failed
            +-----+----------+--------+
            |                |        |
      +-----v-----+   +-----v--+  +--v--------+
      |  running   |   | failed |  | cancelled |
      +--+--+--+---+   +---+----+  +-----------+
         |  |  |            |
         |  |  |     queued | (retry path)
         |  |  |            |
         |  |  +------------+
         |  |
         |  +---> interrupted ---> queued (resume)
         |                    +---> cancelled
         |
         v
    +----+----+
    |  review  |
    +--+--+--+-+
       |  |  |
       |  |  +---> queued (push back)
       |  |  +---> running (push back with feedback delivery)
       |  +------> rejected (terminal)
       +---------> accepted (terminal)
       +---------> failed
```

Terminal states: `accepted`, `rejected`, `cancelled`, `failed`.

The `failed -> queued` transition enables automatic retry when `retryCount < maxRetries`. A failure kind repeated on consecutive attempts prevents retrying the same recurring error.

Transitions are validated by `Task.transition()` which checks `TaskStatus.validTransitions`, updates timestamps (`startedAt` on running, `completedAt` on terminal), and increments `pushBackCount` in `configJson` on review-to-queued transitions.

### 2.5 TaskArtifact

Persisted output produced by task execution (`dartclaw_core/lib/src/task/task_artifact.dart`):

| Field      | Type           | Purpose                               |
|------------|----------------|---------------------------------------|
| `id`       | `String`       | Unique artifact ID                    |
| `taskId`   | `String`       | Owning task                           |
| `name`     | `String`       | Display name                          |
| `kind`     | `ArtifactKind` | Classification: `diff`, `document`, `data`, `branch`, `pr` |
| `path`     | `String`       | File path or URL                      |
| `createdAt`| `DateTime`     | Recording timestamp                   |

### 2.6 Goal

Hierarchical planning context (`dartclaw_core/lib/src/task/goal.dart`):

| Field          | Type       | Purpose                              |
|----------------|------------|--------------------------------------|
| `id`           | `String`   | Unique goal ID                       |
| `title`        | `String`   | Human-readable name                  |
| `parentGoalId` | `String?`  | Hierarchical parent                  |
| `mission`      | `String`   | Mission statement / desired outcome  |
| `maxTokens`    | `int?`     | Budget inherited by child tasks      |
| `createdAt`    | `DateTime` | Creation timestamp                   |

Goals group tasks and provide inherited token budgets. Budget resolution order: `Task.maxTokens` > legacy `configJson` > `Goal.maxTokens` > global `TaskBudgetConfig.defaultMaxTokens`.

### 2.7 Version-Based Optimistic Locking

`TaskService.transition()` uses `TaskRepository.updateIfStatus()` which applies the update only when the stored status matches the expected status. On mismatch:

- **Version mismatch**: throws `VersionConflictException`
- **Status mismatch**: throws `StateError`
- **Missing task**: throws `ArgumentError`

This prevents concurrent transitions from corrupting task state without requiring database-level locks.

---

## 3. Task Execution Pipeline

### 3.1 End-to-End Flow

```
  Task Creation                      EventBus                    TaskExecutor
  ─────────────                      ────────                    ────────────
  Web UI / API / Channel /     TaskStatusChanged
  Schedule / Workflow Step  ──────────────────────>  [queued tasks]
        |                                                  |
        v                                                  v
  TaskService.create()                             pollOnce() (2s timer)
        |                                                  |
        |  autoStart=true:                                 v
        |  draft -> queued                          List queued tasks
        |                                           Sort by createdAt
        |                                                  |
        v                                                  v
  TaskStatusChangedEvent                           Resolve project status
  TaskEventRecorder                                (waiting/error/ready)
                                                           |
                                                           v
                                                   Global governance,
                                                   then acquire worker lease
                                                   from ExecutionCoordinator
                                                           |
                                                           v
                                                   Checkout: queued -> running
                                                           |
                                                           v
                                              ┌────────────────────────────┐
                                              │   _executeCore()           │
                                              │                            │
                                              │  1. Resolve project        │
                                              │  2. Create worktree        │
                                              │     (when declared)        │
                                              │  3. Create/reuse session   │
                                              │  4. Pre-turn budget check  │
                                              │  5. Compose prompt         │
                                              │  6. Reserve turn           │
                                              │  7. Execute turn           │
                                              │  8. Wait for outcome       │
                                              │  9. Record metrics         │
                                              │ 10. Collect artifacts      │
                                              │ 11. Transition status      │
                                              │     (review/accepted)      │
                                              └────────────────────────────┘
                                                           |
                                                           v
                                                   Release execution lease;
                                                   cache/dispose/quarantine
```

### 3.2 TaskService

Business logic layer at `dartclaw_runtime/lib/src/task/task_service.dart`. Implements `WorkflowTaskService` (the minimal contract exposed to `dartclaw_core` for workflow execution).

`TaskService.create()` creates or links an `AgentExecution` row in the same transaction as the task write when an execution row is required. `TaskService.get()` / `list()` hydrate the linked `AgentExecution` and `WorkflowStepExecution` rows through the joined storage query so dashboard/API consumers do not incur N+1 lookups for provider, session, or workflow-step metadata.

Core operations:
- **`create()`** — inserts task; when `autoStart=true`, transitions draft->queued and fires `TaskStatusChangedEvent`
- **`transition()`** — applies lifecycle transition with optimistic locking, fires events, records to `TaskEventRecorder`
- **`updateFields()`** — updates mutable fields on non-terminal tasks (sessionId, worktreeJson, configJson, etc.)
- **`addArtifact()`** — attaches artifact row to a task

On entering `review` status, `TaskService` asynchronously fires `TaskReviewReadyEvent` with artifact count and kinds (best-effort, non-blocking).

### 3.3 TaskExecutor

Central task orchestrator at `dartclaw_runtime/lib/src/task/task_executor.dart`. Runs a 2-second poll timer that dispatches queued tasks through the shared post-governance execution authority.

Two execution paths:

| Mode | Condition | Behavior |
|------|-----------|----------|
| **Server coordinator** | `ExecutionCoordinator` is wired | Acquires a provider worker lease; execution is bounded by `providers.<id>.pool_size` |
| **SDK single-harness compatibility** | No multi-worker coordinator and one harness supplied | Serializes only ordinary background work whose provider and effective policy exactly match that harness; never used for server logical-agent execution |

Poll cycle (`_pollOnceInner`):
1. List all queued tasks, sort by `createdAt` (FIFO)
2. For each task: check project readiness (`cloning` = wait, `error` = fail)
3. Refuse a pre-upgrade `research` row; otherwise resolve the neutral or operator-declared security profile
4. After global governance, request a provider-neutral worker lease for the exact provider and security profile
5. Transition task to `running` (checkout)
6. Execute asynchronously (`unawaited` in server coordinator mode)
7. On completion: release the lease; the coordinator alone decides whether to cache, dispose, or quarantine the worker

Queued tasks may wait for provider capacity. `TaskExecutor` does not count processes, inspect cache compatibility, or trigger provider-specific spawning. `ExecutionCoordinator` creates a worker only after a lease is available and no healthy compatible cached worker exists.

### 3.4 Execution Core (`_executeCore`)

The shared execution logic for both pool and single-harness paths:

1. **Project resolution** — looks up `Project` via `ProjectService`; calls `ensureFresh()` for auto-fetch (5-min cooldown)
2. **Worktree setup** — when `configJson.needsWorktree` is `true`, creates an isolated git worktree via
   `WorktreeManager` and registers its path with `TaskFileGuard`
3. **Session management** — creates task session via `SessionKey.taskSession(taskId:)`, or reuses a continued session (`_continueSessionId` from workflow)
4. **Budget check** — resolves effective budget (task > goal > global), checks cumulative tokens against threshold; warns at configurable % (default 80%), fails at 100%
5. **Prompt composition** — builds the pending prompt with goal context, retry context, acceptance criteria, and working directory
6. **Workflow step branch** – every workflow-owned task acquires a worker lease from the selected provider after the pre-turn governance/budget checks. The coordinator constructs a worker with the step's artifacts directory and spawn variables, and the task dispatches its complete prompt chain through that worker's guarded `TurnRunner`. It records the transcript in the task session, persists token/cost accounting, stores any native structured payload back onto the task config, and releases the lease after settlement.
7. **Task-scoped behavior** — creates `BehaviorFileService` override for project-specific `CLAUDE.md`/`AGENTS.md`
8. **Tool filter** — applies per-task `allowedTools` from `configJson`
9. **Turn execution** — reserves turn, executes via runner, waits for outcome
10. **Metrics recording** — coordinator settlement updates `RunnerObserver`; `TaskEventRecorder` records task token/tool
    events and `TurnTraceService` persists task traces
11. **Artifact collection** — `ArtifactCollector.collect()` gathers the diff from a worktree, or files modified since
    task start when no worktree exists
12. **Status transition** — transitions to `review` or `accepted` based on review mode
13. **Auto-accept** — optional callback for automatic acceptance after review transition

The read-only mutation check prefers `task.worktreeJson['path']` over `project.localPath` when a worktree exists. Without
that preference, read-only workflow steps would appear clean even when they mutated files inside their linked worktree.

### 3.5 Retry Logic

When a task fails and `retryCount < maxRetries`:
1. `TaskFailureHandler.markFailedOrRetry` stores the sanitized message in `configJson['lastError']` and the failure kind's key in `configJson['_lastFailureKind']`
2. Increments `retryCount`, clears `sessionId` for fresh session
3. Transitions task back to `queued`
4. On next poll cycle, task is picked up again
5. Retry context is injected into the prompt from `lastError`: "Previous attempt failed: ... Approach the task differently"
6. A failure whose kind equals the persisted `_lastFailureKind` fails the task permanently instead of retrying

Each failure call site supplies a `TaskFailureKind` (`task/task_failure_kind.dart`): a `TaskFailureReason` for a reason the host decided, or a `TaskExecutionFailure` discriminated by the exception's runtime type. The persisted key is the only retry comparison -- no message text is normalised or parsed.

Non-retryable failures (loop detection, budget exceeded, missing project) skip the retry path entirely.

---

## 4. Execution Coordination

### 4.1 Authority and lanes

`ExecutionCoordinator` at `dartclaw_runtime/lib/src/execution_coordinator.dart` is the sole execution allocator after global governance. Task code uses only the worker lane. The complete surface map is:

| Lane | Surfaces | Limit |
|---|---|---|
| Primary interactive | Main-agent user and channel turns | Fixed serialized capacity 1, outside provider `pool_size` |
| Worker | Cron/system jobs, tasks, logical agents, workflow steps | Selected provider's `pool_size` |

`providers.<id>.pool_size` is a hard ceiling on concurrent worker executions for that provider. It is not a harness-process count. No task, agent, cache, or container setting adds capacity.

### 4.2 Task acquisition

A task request contains normalized provider identity, security profile, session ID, task ID, and admission behavior. A workflow request also carries its host-owned artifacts directory and spawn variables. Those request-scoped construction inputs make its worker single-use. The coordinator's remaining construction inputs are immutable. Task scheduling remains provider-neutral: concrete provider factories and adapter differences exist only in composition/wiring.

Ordinary queued tasks wait for a lease. Nested logical-agent calls use fail-fast admission to avoid waiting on capacity held by their caller. There is no provider or security-profile fallback.

### 4.3 Opportunistic worker reuse

After the lease is granted, reusable-worker lookup prefers:

1. the exact session with the requested provider/profile; container reuse additionally requires the exact logical-agent principal;
2. any healthy host worker with the same provider and identical effective execution policy;
3. a fresh worker.

A provider/profile mismatch or unknown health means fresh creation. Cache behavior has no configuration knobs. An idle healthy host worker may be cached after release. A logical-agent container may be retained only for the same owner until discard, eviction, or shutdown. Other container workers and unhealthy workers are disposed.

### 4.4 Replacement and quarantine

Worker replacement requires confirmed teardown of the harness's managed root process. An unconfirmed exit is not a recoverable idle state: the worker is omitted from the cache and its capacity slot is quarantined, reducing effective provider capacity. DartClaw never starts an overlapping replacement against that slot.

Workflow steps hold worker leases. Their provider process is lifecycle-owned by the harness; an unconfirmed teardown quarantines the worker lease after its worker is disposed, so no replacement overlaps the withheld slot.

### 4.5 Containers and shutdown

A security profile is a filesystem/capability template, not a running container. Each execution owner receives a dedicated container that never serves another principal. A logical-agent container spans that owner's turns and ends on discard, eviction, or shutdown; an ordinary task container ends with its turn. A workflow step's leased harness worker holds one authority for the complete prompt chain and releases it in `finally`. The complete execution policy – host, or container plus profile – participates in matching, and container reuse additionally requires the exact logical-agent owner.

Coordinator shutdown stops admission, drains active leases, disposes cached harnesses, then tears down the fixed primary harness. Channel managers still reap their own children. Root-process termination confirmation is a replacement invariant, not merely an operational warning.

### 4.6 SDK compatibility

SDK hosts that supply a single harness without multi-worker coordination may serialize ordinary background tasks on it. The production server and logical-agent routing never select this fallback.

---

## 5. Turn Execution

### 5.1 TurnRunner

Per-harness execution engine at `dartclaw_runtime/lib/src/turn_runner.dart`. Each `TurnRunner` encapsulates the full turn lifecycle for a single `AgentHarness`.

Key properties:
- `profileId` — security profile (e.g. `workspace`, `restricted`)
- `providerId` — agent provider (e.g. `claude`, `codex`)

### 5.2 TurnContext

Metadata for an in-flight turn (`turn_manager.dart`):

| Field | Type | Purpose |
|-------|------|---------|
| `turnId` | `String` | Unique turn identifier |
| `sessionId` | `String` | Execution session |
| `agentName` | `String` | Agent role (default `main`, `task` for tasks) |
| `startedAt` | `DateTime` | Reservation timestamp |
| `taskId` | `String?` | Associated task, when any |
| `directory` | `String?` | Working directory override (worktree path) |
| `model` | `String?` | Per-turn model override |
| `effort` | `String?` | Per-turn reasoning effort override |
| `systemPromptOverride` | `String?` | Authoritative non-empty system prompt override |
| `maxTurns` | `int?` | Hard cap on harness turns |
| `outputSchema` | `Map<String, dynamic>?` | Opaque provider-enforced output schema |
| `providerSessionId` | `String?` | Provider-native session identity to resume |
| `requestProviderSessionResume` | `bool` | Whether the provider should mint a durably resumable session |
| `behaviorOverride` | `BehaviorFileService?` | Task-scoped behavior files |
| `promptScope` | `PromptScope?` | Controls which workspace files are included |
| `isHumanInput` | `bool` | Whether a fresh onboarding section is permitted |
| `allowedTools` | `List<String>?` | Active-turn tool allowlist |
| `readOnly` | `bool` | Whether the active turn is read-only |

### 5.3 TurnOutcome

Result of a completed turn:

| Field | Type | Purpose |
|-------|------|---------|
| `turnId` | `String` | Unique turn identifier |
| `sessionId` | `String` | Execution session |
| `status` | `TurnStatus` | `completed`, `failed`, `cancelled` |
| `inputTokens` | `int` | Input token count |
| `outputTokens` | `int` | Output token count |
| `cacheReadTokens` | `int` | Prompt cache read tokens |
| `cacheWriteTokens` | `int` | Prompt cache write tokens |
| `turnDuration` | `Duration` | Wall-clock turn time |
| `toolCalls` | `List<ToolCallRecord>` | Bounded invocation detail (first 63 plus latest) |
| `toolCallCount` | `int` | Exact invocation count |
| `failedToolCallCount` | `int` | Exact failed or incomplete invocation count |
| `toolCallsTruncated` | `bool` | Whether bounded detail omits records |
| `completedAt` | `DateTime` | Completion timestamp |
| `loopDetection` | `LoopDetection?` | Non-null when cancelled due to loop |
| `responseText` | `String?` | Agent's final response text |
| `errorMessage` | `String?` | Error details on failure |
| `structuredOutput` | `Map<String, dynamic>?` | Provider-enforced payload; completed and guard-passed turns only |
| `providerSessionId` | `String?` | Provider-native session identity; absent when unreported or guard-blocked |
| `totalTokens` | `int` | Input plus output tokens |
| `effectiveTokens` | `int` | Billing-weighted token count |

### 5.4 Turn Pipeline

Global governance and execution admission precede the `TurnRunner` pipeline:

```
TurnGovernanceEnforcer
    |
    v
ExecutionCoordinator.acquire()
    |
    v
reserveTurn() on leased runner
    |
    v
TurnContext created
    |
    v
Guard evaluation (TurnGuardEvaluator)
  - messageReceived hook
  - beforeToolCall hooks
    |
    v
Message persistence (MessageService)
    |
    v
Harness.turn() — streaming JSONL over stdin/stdout
    |
    v
SSE event emission and liveness tracking (TurnLivenessTracker)
    |
    v
Context monitoring (ContextMonitor)
    |
    v
Outcome persistence
  - Usage tracking
  - Self-improvement service
    |
    v
Crash recovery checkpoint (TurnStateStore)
    |
    v
TurnOutcome returned to caller
```

### 5.5 TurnManager

Runs session-level turn lifecycle on the runner supplied by an execution lease. It does not select providers, count capacity, or choose cached workers. Main user/channel turns arrive on the fixed primary lease; cron/system jobs, tasks, and logical agents arrive on worker leases.

---

## 6. Declared Worktree Support

Tasks with `configJson.needsWorktree: true` use the git-isolation, diff-generation, and code-review infrastructure below.

### 6.1 WorktreeManager

Git worktree lifecycle manager at `dartclaw_runtime/lib/src/task/worktree_manager.dart`.

**Creation** — two modes:
- **Project-backed**: single-step `git worktree add <path> -b <branch> origin/<defaultBranch>` from the project's clone directory
- **Local fallback**: two-step `git branch` + `git worktree add` from the local base ref

Branch naming: `dartclaw/task-<taskId>`, with `-N` suffix on collision (up to 100 attempts).

Worktree path: `<dataDir>/worktrees/<taskId>/`

**Cleanup** — removes worktree directory and deletes the branch. Best-effort (logs warnings, does not throw).

**Stale detection** — `detectStaleWorktrees()` checks for worktrees older than the configured timeout (default 24 hours).

### 6.2 TaskFileGuard

Per-task file access registry at `dartclaw_runtime/lib/src/task/task_file_guard.dart`.

Maintains a `Map<String, String>` of `taskId -> canonicalized worktree path`. The harness uses `isAllowed(taskId, filePath)` to validate that file operations stay within the task's worktree boundary.

Registration lifecycle:
1. `register(taskId, worktreePath)` — on worktree creation
2. `deregister(taskId)` — on worktree cleanup or task review completion

### 6.3 DiffGenerator

Generates structured diff data at `dartclaw_runtime/lib/src/task/diff_generator.dart`.

Uses three-dot diff (`baseRef...branch`) to show only changes introduced on the branch. Produces `DiffResult` containing:
- Per-file `DiffFileEntry` with status (added/modified/deleted/renamed), line counts, and hunks
- Summary totals: `totalAdditions`, `totalDeletions`, `filesChanged`

### 6.4 MergeExecutor

Handles merging a task branch onto the base branch at `dartclaw_runtime/lib/src/task/merge_executor.dart`.

Supports two strategies:
- **Squash merge** (default): `git merge --squash` + commit
- **Merge commit**: `git merge --no-ff`

Conflict handling: on merge conflict, aborts the merge, restores the original state (stash pop), and returns `MergeConflict` with conflicting file list.

### 6.5 RemotePushService

Pushes branches to remote repositories at `dartclaw_runtime/lib/src/task/remote_push_service.dart`.

Runs `git push` via `Isolate.run()` to avoid blocking the main event loop. This was the first use of `Isolate.run()` in DartClaw (introduced in 0.14).

Credentials are resolved from `CredentialsConfig` and injected via `GIT_SSH_COMMAND` / `GIT_ASKPASS` environment variables — never stored in the container or task config.

Returns sealed `PushResult`: `PushSuccess`, `PushAuthFailure`, `PushRejected`, `PushError`.

### 6.6 PrCreator

Creates GitHub pull requests at `dartclaw_runtime/lib/src/task/pr_creator.dart`.

Calls the GitHub REST API directly via `HttpClient` (`POST /repos/{owner}/{repo}/pulls`), authenticated with the project's resolved `github-token` credential — no `gh` CLI dependency. Returns a sealed `PrCreationResult`: `PrCreated` (with URL), `PrCreationFailed` (incompatible credential, non-GitHub remote, or API error), or `PrGhNotFound` (manual follow-up required).

PR metadata: title from task title, body from task description + acceptance criteria.

Base branch is `project.defaultBranch`; `draft` and `labels` come from `project.pr` (`PrConfig`). Labels are applied via a follow-up `POST /repos/{owner}/{repo}/issues/{number}/labels` call.

### 6.7 ArtifactCollector

Produced-output artifact collection at `dartclaw_runtime/lib/src/task/artifact_collector.dart`.

- A task with `worktreeJson` produces `diff.json` through `DiffGenerator`.
- A task without a worktree collects every workspace file modified since `task.startedAt`, with artifact kind inferred
  from the extension.
- An optional `configJson.artifactExtensions` list narrows the non-worktree scan to the declared extensions.

Artifacts are stored at `<dataDir>/tasks/<taskId>/artifacts/`. Existing artifacts are cleared before each collection pass.

---

## 7. Task Review Workflow

### 7.1 TaskReviewService

Shared lifecycle service at `dartclaw_runtime/lib/src/task/task_review_service.dart`.

Three review actions:

| Action | Target Status | Additional Behavior |
|--------|---------------|---------------------|
| `accept` | `accepted` | Merge (local) or push (project-backed), cleanup worktree |
| `reject` | `rejected` | Cleanup worktree |
| `push_back` | `running` | Inject feedback, increment pushBackCount, resume execution |

### 7.2 Accept Flow

```
review() called with action="accept"
    |
    v
Task has worktreeJson?
    |
    +-- No --> Transition to accepted
    |
    +-- Yes --> Is project-backed?
                    |
                    +-- Yes --> RemotePushService.push()
                    |               |
                    |               +-- PushSuccess --> PrCreator.create()
                    |               |                       |
                    |               |                       +-- PrCreated: store PR URL artifact
                    |               |                       +-- PrGhNotFound: store instructions
                    |               |                       +-- PrCreationFailed: store warning
                    |               |
                    |               +-- Push failure --> return ReviewActionFailed
                    |
                    +-- No --> MergeExecutor.merge()
                                    |
                                    +-- MergeSuccess --> Transition to accepted
                                    +-- MergeConflict --> Store conflict artifact,
                                                          return ReviewMergeConflict
```

### 7.3 Push-Back Flow

1. Validates non-empty comment
2. Transitions task from `review` to `running`
3. Records `PushBack` event on task timeline
4. Delivers feedback as new turn message to the task's session (best-effort via `PushBackFeedbackDelivery` callback)
5. On next execution, the push-back prompt is composed with the feedback text

### 7.4 Review Surfaces

Review decisions reach `TaskReviewService` through the task UI and HTTP API or through the registered `task_review`
agent tool. `review_list` supplies full task IDs before a tool call. Channel messages themselves remain ordinary model
turns; the host does not parse review prose before routing.

### 7.5 Concurrency Control

`TaskReviewService` uses per-task async locks (`_reviewLocks`) to serialize concurrent review actions on the same task. This prevents race conditions where two reviewers simultaneously try to accept/reject the same task.

### 7.6 Review Mode

`TaskExecutor` determines post-completion status based on `configJson['reviewMode']`:

| Mode | Behavior |
|------|----------|
| `auto-accept` | Task transitions directly to `accepted` |
| `mandatory` | All tasks go to `review` |
| `worktree-only` | Tasks declaring `needsWorktree: true` go to `review`; others auto-accept |
| _(default)_ | All tasks go to `review` |

An optional `onAutoAccept` callback allows automatic acceptance after the review transition.

---

## 8. Task Events and Observability

### 8.1 TaskEvent Model

Sealed-class event hierarchy in `dartclaw_kernel/lib/src/task_event.dart`:

| Kind | Details Structure | When Recorded |
|------|-------------------|---------------|
| `StatusChanged` | `{oldStatus, newStatus, trigger}` | Every lifecycle transition |
| `ToolCalled` | `{name, success, durationMs, ?errorType, ?context}` | Each tool invocation during execution |
| `ArtifactCreated` | `{name, kind}` | Artifact added to task |
| `PushBack` | `{comment}` | Review push-back with feedback |
| `TokenUpdate` | `{inputTokens, outputTokens, ?cacheReadTokens, ?cacheWriteTokens}` | After each completed turn |
| `TaskErrorEvent` | `{message}` | Error during execution |
| `Compaction` | `{trigger, sessionId, ?preTokens}` | Context compaction during agent execution |

### 8.2 Persistence Layer

`TaskEventService` in `dartclaw_core/lib/src/storage/task_event_service.dart`:

- SQLite `task_events` table (append-only)
- Synchronous writes for durability (NF04 requirement)
- Indexed on `task_id`, `(task_id, kind)`, and `timestamp`
- Queries: `listForTask()` (chronological), `countForTask()`

Schema:
```sql
CREATE TABLE task_events (
    id        TEXT PRIMARY KEY,
    task_id   TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    kind      TEXT NOT NULL,
    details   TEXT NOT NULL DEFAULT '{}'
);
```

### 8.3 TaskEventRecorder

Centralized recording service at `dartclaw_runtime/lib/src/task/task_event_recorder.dart`.

Each convenience method:
1. Constructs a `TaskEvent` with appropriate kind and details
2. Inserts synchronously via `TaskEventService` (NF04 durability)
3. Fires `TaskEventCreatedEvent` on the `EventBus`

Methods: `recordStatusChanged()`, `recordToolCalled()`, `recordArtifactCreated()`, `recordPushBack()`, `recordTokenUpdate()`, `recordError()`, `recordCompaction()`.

### 8.4 TaskProgressTracker

Throttled progress tracking at `dartclaw_runtime/lib/src/task/task_progress_tracker.dart`.

Subscribes to `TaskEventCreatedEvent` on the `EventBus`, accumulates token usage and current tool activity per task, and emits `TaskProgressSnapshot` updates at most once per second per task via a broadcast stream.

`TaskProgressSnapshot`:
- `taskId` — task identifier
- `progress` — percentage 0-100 (null if no budget set)
- `currentActivity` — human-readable tool activity (e.g. "Reading src/main.dart")
- `tokensUsed` — cumulative tokens
- `tokenBudget` — configured budget
- `isComplete` — true when task leaves running state

Activity formatting is handled by `formatToolActivity()` in `tool_call_summary.dart`, which maps tool names to user-friendly verbs (Read -> "Reading", Bash -> "Running", Grep -> "Searching").

SSE clients subscribe to the broadcast stream for live `task_progress` events.

### 8.5 RunnerObserver

Per-runner runtime metrics at `dartclaw_runtime/lib/src/task/runner_observer.dart`.

Tracks per-runner cumulative turn metrics: tokens, completed turns, errors, cache tokens, duration, and tool-call stats.
`TurnRunner` reports each terminal outcome once through `ExecutionCoordinator`, so primary and worker turns share one
metrics path. Current busy/free/task/session state also comes from coordinator lease events and snapshots, not independent
lifecycle authority. Disposed workers are removed from current metrics after their disposal event. Workflow executions
have a worker identity for the life of their lease, and the workflow path drives that runner for every turn.

Provider summaries expose configured, effective, active, queued, cached, and quarantined counts. Available worker capacity is `effective - active`; cached process count never changes it. Metrics are in-memory and reset on restart. Lease transitions fire `RunnerStateChangedEvent` or its execution-capacity equivalent for SSE propagation.

---

## 9. Turn Traces

### 9.1 TurnTrace Model

Rich per-turn record persisted to SQLite (`dartclaw_core`):

| Field | Type | Purpose |
|-------|------|---------|
| `id` | `String` | Turn identifier |
| `sessionId` | `String` | Execution session |
| `taskId` | `String?` | Associated task (null for interactive turns) |
| `runnerId` | `int?` | Pool runner index |
| `model` | `String?` | Model used |
| `provider` | `String?` | Provider used |
| `startedAt` | `DateTime` | Turn start |
| `endedAt` | `DateTime` | Turn end |
| `inputTokens` | `int` | Input token count |
| `outputTokens` | `int` | Output token count |
| `cacheReadTokens` | `int` | Cache read tokens |
| `cacheWriteTokens` | `int` | Cache write tokens |
| `isError` | `bool` | Whether the turn failed |
| `errorType` | `String?` | Error classification |
| `toolCalls` | `List<ToolCallRecord>` | Bounded records (first 63 plus latest) |
| `toolCallCount` | `int` | Exact invocation count |
| `failedToolCallCount` | `int` | Exact failed or incomplete invocation count |
| `toolCallsTruncated` | `bool` | Whether bounded detail omits records |

### 9.2 Storage

`TurnTraceService` in `dartclaw_core/lib/src/storage/turn_trace_service.dart`:

- SQLite `turns` table, co-located in `tasks.db`
- Indexed on `session_id`, `task_id`, `started_at`, `model`, `provider`
- Fire-and-forget writes (callers use `unawaited`)

Schema:
```sql
CREATE TABLE turns (
    id                 TEXT PRIMARY KEY,
    session_id         TEXT NOT NULL,
    task_id            TEXT,
    runner_id          INTEGER,
    model              TEXT,
    provider           TEXT,
    started_at         TEXT NOT NULL,
    ended_at           TEXT NOT NULL,
    input_tokens       INTEGER NOT NULL DEFAULT 0,
    output_tokens      INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens  INTEGER NOT NULL DEFAULT 0,
    cache_write_tokens INTEGER NOT NULL DEFAULT 0,
    is_error           INTEGER NOT NULL DEFAULT 0,
    error_type         TEXT,
    tool_calls         TEXT  -- JSON envelope; legacy JSON arrays remain readable
);
```

### 9.3 Query API

`GET /api/traces` supports filtering by `taskId`, `sessionId`, `runnerId`, `model`, `provider`, `since`, `until`, plus pagination (`limit`, `offset`).

Returns `TraceQueryResult`: paginated trace list + `TurnTraceSummary` aggregates (total tokens, total duration, exact total tool calls, trace count) over the full filtered result set.

Introduced in 0.14.

---

## 10. Multi-Project Support

### 10.1 Project Model

Defined in `dartclaw_kernel` (see [ADR-017](../adrs/017-multi-project-architecture.md)):

| Field | Type | Purpose |
|-------|------|---------|
| `id` | `String` | Unique project identifier |
| `name` | `String` | Display name |
| `remoteUrl` | `String` | Remote repository URL |
| `localPath` | `String` | Clone directory: `<dataDir>/projects/<projectId>/` |
| `defaultBranch` | `String` | Base branch for worktrees |
| `credentialsRef` | `String?` | Reference to credentials config entry |
| `pr` | `PrConfig` | PR creation settings (strategy, draft, labels) |
| `status` | `ProjectStatus` | `ready`, `cloning`, `error` |

### 10.2 ProjectService

Interface in `dartclaw_core`, implementation in `dartclaw_runtime/lib/src/project/project_service_impl.dart`.

Key operations:
- **`get(id)`** — returns project by ID
- **`getDefaultProject()`** — returns the implicit `_local` project for backward compatibility
- **`ensureFresh(project)`** — auto-fetch with 5-min cooldown + per-project lock, runs in `Isolate.run()`

### 10.3 Task-Project Binding

`taskProjectId()` in `task_project_ref.dart` resolves the project for a task:
1. `Task.projectId` field (first-class)
2. Legacy `configJson['projectId']` (backward compat)
3. `null` — uses default project (`_local`)

`taskTargetsExternalProject()` returns true when the project is not `_local`, which triggers the remote push flow instead of local merge on accept.

### 10.4 Credential Security

Credentials are **reference-based** — the task and project configs store a `credentialsRef` string that references an entry in the operator's `CredentialsConfig`. Actual credential values are resolved at push time by `resolveGitCredentialEnv()` and injected via environment variables:

- `GIT_SSH_COMMAND` — for SSH key authentication
- `GIT_ASKPASS` — for HTTPS token authentication (writes a temp askpass script)

Credential values never appear in task config, container environment, or log output.

---

## 11. Task Scheduling

### 11.1 ScheduleService

Time-based job executor at `dartclaw_runtime/lib/src/scheduling/schedule_service.dart`.

Uses single-shot `Timer` + reschedule pattern for accurate cron intervals. Jobs run in isolated sessions (`SessionKey.cronSession`) on provider worker leases; cron/system execution never occupies the primary-interactive lane.

### 11.2 ScheduledTaskRunner

Bridges `ScheduledTaskDefinition` config entries into `ScheduledJob` instances at `dartclaw_runtime/lib/src/scheduling/scheduled_task_runner.dart`.

Each enabled definition becomes a callback-based job that:
1. **Dedup check**: finds non-terminal tasks with matching `scheduleId` in `configJson`
2. **Skip if open**: logs and skips if a matching open task exists
3. **Create task**: calls `TaskService.create()` with schedule metadata

Task ID format: `sched-<scheduleId>-<timestamp>-<random4hex>`

Config propagation: `model`, `effort`, `tokenBudget` from the schedule definition flow into `configJson`.

### 11.3 CronParser

Parses standard 5-field cron expressions. Calculates next fire time from current time.

---

## 12. Budget Enforcement

One engine, two scopes, two consumers. `BudgetEngine`
(`dartclaw_runtime/lib/src/governance/budget_engine.dart`) owns the only copy of
the budget arithmetic — the threshold comparison, the percentage, and the
warn-once gating. A `BudgetScope` supplies the limit, the consumption reading
and the warn-once cell; the consumer decides what a breach means. The engine
does no I/O of its own and catches nothing, so each scope keeps its own error
posture.

The daily guardrail and the per-task cap remain two deliberately layered
*controls* (see
[Observability & Operations](observability-operations-architecture.md#token-accounting-0164));
only their implementation is shared.

```
BudgetEngine.evaluate(scope)
    |
    +-- scope.limit               -- null/0 -> BudgetOutcome.under, no read
    +-- scope.readConsumption()   -- null   -> BudgetOutcome.under
    +-- ratio >= 1.0              -> BudgetOutcome.exceeded
    +-- ratio >= threshold        -> BudgetOutcome.warning
    +-- otherwise                 -> BudgetOutcome.under
```

### 12.1 Per-Task Scope

`TaskBudgetPolicy` in `dartclaw_runtime/lib/src/task/task_budget_policy.dart`.

The effective budget resolves through one five-rung ladder,
`TaskBudgetPolicy.resolveTokenBudget()`:

```
Task.maxTokens             (first-class field)
  |
  +-- null --> configJson['tokenBudget']     (legacy)
                  |
                  +-- null --> configJson['budget']    (deprecated)
                                  |
                                  +-- null --> Goal.maxTokens
                                                  |
                                                  +-- null --> TaskBudgetConfig.defaultMaxTokens
```

Pre-turn check in `checkBudget()`:
- Reads cumulative session cost from `KvService` (`session_cost:<sessionId>`)
- At the configurable warning threshold (default 80%): injects a warning system
  message, fires `BudgetWarningEvent`, and writes the per-task warn-once cell
  (`configJson['_tokenBudgetWarningFired']`)
- At 100%: fails the task non-retryably with `TaskFailureReason.budgetExceeded`
  and writes a `budget-exceeded` artifact. A terminal breach does **not** consume
  the warn-once cell
- **Fail-safe**: any exception during the budget check defaults to proceed (open
  policy). The wrapper lives here, not in `BudgetEngine` — the daily guardrail
  shares the engine and must not fail open

**Known divergence — four shorter ladders survive, and one of them enforces.**
`TaskConfigView.tokenBudget` (`task/task_config_view.dart`) reads
`task.maxTokens` and `configJson` only, stopping before `Goal.maxTokens` and
`TaskBudgetConfig.defaultMaxTokens`. `TaskExecutor` resolves the *post*-turn
overrun limit through it, so a task budgeted only by its goal or by the config
default is checked before a turn and not after it. Three further readers are
display-only and shorter still, reading `configJson` alone:
`task/task_progress_tracker.dart`, `server.dart` and `web/pages/tasks_page.dart`.
This set is closed: no new truncated copy may be added. Unifying the post-turn
check is a live behaviour change — goal-budgeted tasks that complete today would
start failing — so it needs its own decision and its own story.

### 12.2 Global Daily Scope

`BudgetEnforcer` in `dartclaw_runtime/lib/src/governance/budget_enforcer.dart`:

- Reads daily totals from `UsageTracker.dailySummaryForDate()`
- Timezone-aware: supports `UTC`, `UTC+N`, `UTC-N`, and IANA names via
  `BudgetConfig.timezone`
- Warning threshold is a fixed 80% constant in code, not a config key
- Its warn-once marker (`budget_warning_posted_at`) lives in the persisted daily
  aggregate, so one warning per day survives a restart. Reaching 100% consumes
  the day's warning too
- No error handling: a storage failure surfaces to the caller rather than
  silently allowing an over-budget turn
- `status()` backs the `/status` card

### 12.3 Integration with Governance

`TurnGovernanceEnforcer` is the daily scope's consumer and owns the
block-vs-warn mapping the engine deliberately does not: at or above 100% with
`BudgetAction.block` it throws `BudgetExhaustedException`; otherwise it
broadcasts `budget_warning` (SSE), notifies the originating channel, and lets
the turn proceed.

```
TurnGovernanceEnforcer
    |
    +-- SlidingWindowRateLimiter (per-sender + global)
    +-- BudgetEnforcer (daily token budget scope)
    +-- LoopDetector (turn depth, token velocity, tool fingerprinting)
```

See [Security Architecture](security-architecture.md) for the full governance model.

---

## Cross-References

- [System Architecture](system-architecture.md) — component map, package DAG, deployment model
- [Control Protocol](control-protocol.md) — harness interface, JSONL protocol, stream events, tool approval chain
- [Security Architecture](security-architecture.md) — guard pipeline, TaskFileGuard integration, container isolation, governance enforcement
- [Data Model](data-model.md) — tasks.db schema, worktree storage, entity relationships
- [Workflow Architecture](workflow-architecture.md) — workflow steps create tasks via `WorkflowTaskService`, session continuation across steps
- [ADR-017](../adrs/017-multi-project-architecture.md) — multi-project design decisions and credential model
- [ADR-021](../adrs/021-agent-execution-primitive.md) — `AgentExecution` + `WorkflowStepExecution` decomposition; `Task` carries nested `agentExecution` / `workflowStepExecution` objects
- [ADR-022](../adrs/022-workflow-run-status-and-step-outcome-protocol.md) — portable `<step-outcome>` protocol; `TaskExecutor` preserves task lifecycle fallback when the marker is missing
- [ADR-023](../adrs/023-workflow-task-boundary.md) – behavioural contract for the workflow↔task boundary; names the `_isWorkflowOrchestrated` branch and guarded workflow worker path as intentional

# Task Execution Architecture

How DartClaw creates, schedules, executes, reviews, and observes background tasks. Covers the full pipeline from task creation through harness pool dispatch, turn execution, artifact collection, and review lifecycle.

**Current through**: 0.16.4

---

## Audience & Scope

This is the **contributor reference**. It documents how the task subsystem is built: the domain model, the execution pipeline and `TaskExecutor`/`_executeCore` internals, the `HarnessPool` acquisition strategies, turn execution and trace persistence, coding-task worktree + merge + PR plumbing, the review concurrency model, and how task events flow through observability. Use it when modifying the orchestrator, worktree lifecycle, or review/merge code paths — or when writing tests against any of those.

For **using tasks** (creating tasks from the Web UI/API, container profile routing in practice, per-task budget overrides, the review user flow, automation and scheduling examples), read [`docs/guide/tasks.md`](../../docs/guide/tasks.md) and [`docs/guide/agents.md`](../../docs/guide/agents.md). Where subjects overlap with those guides (TaskType list, simplified state diagram, container profile mapping), this doc keeps the implementation contract — exact enum values, full state machine including failure/cancel terminals, dispatch routing code paths — rather than re-explaining the user-facing concepts.

---

## 1. Overview

A **task** is a background unit of work executed by an agent harness. Tasks decouple work submission from execution — any surface (Web UI, API, channel message, cron schedule, workflow step) can create a task, and the runtime handles queuing, dispatch, isolation, and review.

Tasks flow through a well-defined state machine, are executed by harness runners acquired from a pool, produce observable events and artifacts, and optionally go through human review before acceptance.

Key design principles:
- **Decoupled creation and execution** — tasks are queued, not executed inline
- **Optimistic locking** — version-based concurrency control prevents lost updates
- **Pool-based dispatch** — heterogeneous harness pool with lazy growth
- **Fail-safe budgets** — budget enforcement defaults to open (proceed) on error
- **Best-effort observability** — event recording never blocks the execution path

---

## 2. Task Domain Model

### 2.1 Package Ownership

The task domain is split across three packages following the DartClaw package decomposition:

```
dartclaw_models       TaskType enum (shared DTO)
dartclaw_core         Task, TaskStatus, TaskArtifact, Goal, repositories
dartclaw_server       TaskService, TaskExecutor, review, worktrees, scheduling
dartclaw_storage      SqliteTaskRepository, TaskEventService, TurnTraceService
```

### 2.2 Task

Immutable value object in `dartclaw_core/lib/src/task/task.dart`.

| Field              | Type                    | Purpose                                             |
|--------------------|-------------------------|-----------------------------------------------------|
| `id`               | `String`                | Unique identifier                                   |
| `title`            | `String`                | Short title for lists and review surfaces            |
| `description`      | `String`                | Full task description or operator request            |
| `type`             | `TaskType`              | High-level category (routing, defaults)              |
| `status`           | `TaskStatus`            | Current lifecycle state                              |
| `goalId`           | `String?`               | Parent goal for hierarchical planning                |
| `acceptanceCriteria` | `String?`             | Criteria used during review                          |
| `agentExecutionId` | `String?`               | FK to the shared `AgentExecution` runtime row        |
| `configJson`       | `Map<String, dynamic>`  | Arbitrary immutable config (frozen on construction)  |
| `worktreeJson`     | `Map<String, dynamic>?` | Git worktree metadata for coding tasks               |
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

### 2.3 TaskType

Enum in `dartclaw_models/lib/src/task_type.dart`:

| Value        | Description                                        |
|--------------|----------------------------------------------------|
| `coding`     | Code changes or software implementation             |
| `research`   | Gathering facts, sources, background material       |
| `writing`    | Prose or structured written output                  |
| `analysis`   | Inspects existing state and reports findings        |
| `automation`  | Operational or workflow automation                 |
| `custom`     | Caller-specific conventions                         |

Task type influences artifact collection strategy, prompt composition, review mode resolution, and security profile selection.

For workflow-owned tasks specifically, authored workflow step types collapse onto the coding-task path. The authored YAML type is preserved as `_workflowStepType` metadata for observability and review-mode compatibility, while write intent is expressed through `configJson.readOnly`.

For structured workflow outputs, task execution is conditional rather than always-two-turns: the one-shot branch first checks whether the final assistant message already contains a valid inline `<workflow-context>` payload for the declared structured output, and only falls back to the extra provider-native extraction turn when that inline parse fails.

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

The `failed -> queued` transition enables automatic retry when `retryCount < maxRetries`. Error class loop detection prevents retrying the same recurring error.

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
                                                   Acquire runner from
                                                   HarnessPool
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
                                              │     (coding tasks)         │
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
                                                   Release runner
                                                   back to pool
```

### 3.2 TaskService

Business logic layer at `dartclaw_server/lib/src/task/task_service.dart`. Implements `WorkflowTaskService` (the minimal contract exposed to `dartclaw_core` for workflow execution).

`TaskService.create()` creates or links an `AgentExecution` row in the same transaction as the task write when an execution row is required. `TaskService.get()` / `list()` hydrate the linked `AgentExecution` and `WorkflowStepExecution` rows through the joined storage query so dashboard/API consumers do not incur N+1 lookups for provider, session, or workflow-step metadata.

Core operations:
- **`create()`** — inserts task; when `autoStart=true`, transitions draft->queued and fires `TaskStatusChangedEvent`
- **`transition()`** — applies lifecycle transition with optimistic locking, fires events, records to `TaskEventRecorder`
- **`updateFields()`** — updates mutable fields on non-terminal tasks (sessionId, worktreeJson, configJson, etc.)
- **`addArtifact()`** — attaches artifact row to a task

On entering `review` status, `TaskService` asynchronously fires `TaskReviewReadyEvent` with artifact count and kinds (best-effort, non-blocking).

### 3.3 TaskExecutor

Central orchestrator at `dartclaw_server/lib/src/task/task_executor.dart`. Runs a 2-second poll timer that dispatches queued tasks to available harness runners.

Two execution paths:

| Mode | Condition | Behavior |
|------|-----------|----------|
| **Pool mode** | `pool.maxConcurrentTasks > 0` | Acquires task runners from pool; concurrent execution |
| **Single-harness** | `pool.maxConcurrentTasks == 0` | Uses primary runner when idle; sequential execution |

Poll cycle (`_pollOnceInner`):
1. List all queued tasks, sort by `createdAt` (FIFO)
2. For each task: check project readiness (`cloning` = wait, `error` = fail)
3. Resolve security profile from task type
4. Acquire matching runner (by provider and/or profile)
5. Transition task to `running` (checkout)
6. Execute asynchronously (`unawaited` in pool mode)
7. On completion: release runner back to pool

Lazy pool growth: if tasks are waiting but no runners are available and the pool has capacity, `_triggerSpawn()` invokes the `onSpawnNeeded` callback to spawn a new harness process.

### 3.4 Execution Core (`_executeCore`)

The shared execution logic for both pool and single-harness paths:

1. **Project resolution** — looks up `Project` via `ProjectService`; calls `ensureFresh()` for auto-fetch (5-min cooldown)
2. **Worktree setup** — for coding tasks, creates isolated git worktree via `WorktreeManager`; registers path with `TaskFileGuard`
3. **Session management** — creates task session via `SessionKey.taskSession(taskId:)`, or reuses a continued session (`_continueSessionId` from workflow)
4. **Budget check** — resolves effective budget (task > goal > global), checks cumulative tokens against threshold; warns at configurable % (default 80%), fails at 100%
5. **Prompt composition** — builds the pending prompt with goal context, retry context, acceptance criteria, and working directory
6. **Workflow one-shot branch** — every workflow-owned task dispatches through the one-shot CLI runner after the pre-turn budget check, records the transcript in the task session, persists token/cost accounting, and stores any native structured payload back onto the task config for workflow extraction
7. **Task-scoped behavior** — creates `BehaviorFileService` override for project-specific `CLAUDE.md`/`AGENTS.md`
8. **Tool filter** — applies per-task `allowedTools` from `configJson`
9. **Turn execution** — reserves turn, executes via runner, waits for outcome
10. **Metrics recording** — `AgentObserver.recordTurn()`, `TaskEventRecorder` for token updates and tool calls, `TurnTraceService` for persistent traces
11. **Artifact collection** — `ArtifactCollector.collect()` gathers type-specific artifacts
12. **Status transition** — transitions to `review` or `accepted` based on review mode
13. **Auto-accept** — optional callback for automatic acceptance after review transition

The read-only mutation check prefers `task.worktreeJson['path']` over `project.localPath` when a worktree exists. Without that preference, workflow research/writing/analysis steps would appear clean even when they mutated files inside their linked worktree.

### 3.5 Retry Logic

When a task fails and `retryCount < maxRetries`:
1. `_markFailedOrRetry` stores the error in `configJson['lastError']`
2. Increments `retryCount`, clears `sessionId` for fresh session
3. Transitions task back to `queued`
4. On next poll cycle, task is picked up again
5. Retry context is injected into the prompt: "Previous attempt failed: ... Approach the task differently"
6. Error class loop detection prevents retrying the same recurring error

Non-retryable failures (loop detection, budget exceeded, missing project) skip the retry path entirely.

---

## 4. Harness Pool Management

### 4.1 Architecture

`HarnessPool` at `dartclaw_server/lib/src/harness_pool.dart` manages a heterogeneous collection of `TurnRunner` instances.

```
┌────────────────────────────────────────────────────────────┐
│                       HarnessPool                          │
│                                                            │
│  Index 0: PRIMARY RUNNER                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Reserved for interactive use:                       │  │
│  │  - Web UI chat                                       │  │
│  │  - Channel messages                                  │  │
│  │  - Cron/scheduled jobs (via ScheduleService)         │  │
│  │  Never acquired by TaskExecutor                      │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  Indices 1..N: TASK RUNNERS (lazily added)                 │
│  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────┐  │
│  │ Runner 1        │ │ Runner 2        │ │ Runner N    │  │
│  │ provider: claude│ │ provider: codex │ │ provider: ? │  │
│  │ profile: workspace│ profile: restricted│ ...         │  │
│  │ state: idle     │ │ state: busy     │ │             │  │
│  └─────────────────┘ └─────────────────┘ └─────────────┘  │
│                                                            │
│  Available set:  {Runner 1, Runner N}                      │
│  Busy set:       {Runner 2}                                │
│  Max concurrent: configurable (default: runners.length-1)  │
└────────────────────────────────────────────────────────────┘
```

### 4.2 Acquisition Strategies

| Method | Match Criteria | Use Case |
|--------|----------------|----------|
| `tryAcquire()` | Any idle runner | Default acquisition |
| `tryAcquireForProfile(id)` | Matching `profileId` | Security profile routing |
| `tryAcquireForProvider(id)` | Matching `providerId` | Provider-specific tasks |
| `tryAcquireForProviderAndProfile(provider, profile)` | Both match | Full constraint matching |

All acquisition methods return `null` if no matching idle runner exists or if `busy.length >= maxConcurrentTasks`.

### 4.3 Lazy Growth

The pool starts with only the primary runner. Task runners are added on demand:

1. `TaskExecutor.pollOnce()` finds queued tasks but no available runners
2. Checks `pool.spawnableCount > 0` (capacity remaining)
3. Calls `_triggerSpawn()` which invokes `onSpawnNeeded` callback
4. Callback spawns a new harness process and calls `pool.addRunner()`
5. New runner is immediately available for acquisition

### 4.4 Release-After-Use

Task runners are released back to the pool after each task completes (success or failure). This ensures fairness — no runner is monopolized by long-running tasks when other tasks are waiting.

---

## 5. Turn Execution

### 5.1 TurnRunner

Per-harness execution engine at `dartclaw_server/lib/src/turn_runner.dart`. Each `TurnRunner` encapsulates the full turn lifecycle for a single `AgentHarness`.

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
| `directory` | `String?` | Working directory override (worktree path) |
| `model` | `String?` | Per-turn model override |
| `effort` | `String?` | Per-turn reasoning effort override |
| `maxTurns` | `int?` | Hard cap on harness turns |
| `behaviorOverride` | `BehaviorFileService?` | Task-scoped behavior files |
| `promptScope` | `PromptScope?` | Controls which workspace files are included |

### 5.3 TurnOutcome

Result of a completed turn:

| Field | Type | Purpose |
|-------|------|---------|
| `status` | `TurnStatus` | `completed`, `failed`, `cancelled` |
| `inputTokens` | `int` | Input token count |
| `outputTokens` | `int` | Output token count |
| `cacheReadTokens` | `int` | Prompt cache read tokens |
| `cacheWriteTokens` | `int` | Prompt cache write tokens |
| `turnDuration` | `Duration` | Wall-clock turn time |
| `toolCalls` | `List<ToolCallRecord>` | Tool invocations during the turn |
| `loopDetection` | `LoopDetection?` | Non-null when cancelled due to loop |
| `responseText` | `String?` | Agent's final response text |
| `errorMessage` | `String?` | Error details on failure |

### 5.4 Turn Pipeline

The `TurnRunner` orchestrates the following pipeline for each turn:

```
reserveTurn()
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
Governance checks (TurnGovernanceEnforcer)
  - Rate limiting (SlidingWindowRateLimiter)
  - Budget enforcement (BudgetEnforcer)
  - Loop detection (turn depth, token velocity, tool fingerprinting)
    |
    v
Harness.turn() — streaming JSONL over stdin/stdout
    |
    v
SSE event emission (TurnProgressMonitor)
    |
    v
Context monitoring (ContextMonitor)
  - ExplorationSummarizer for large files
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

Routes session-level turn requests to the appropriate runner in the `HarnessPool`. For interactive use (web, channel, cron), it always uses the primary runner (index 0). For task execution, `TaskExecutor` calls `reserveTurn` directly on the acquired pool runner.

---

## 6. Coding Task Support

Coding tasks get special infrastructure for git isolation, diff generation, and code review.

### 6.1 WorktreeManager

Git worktree lifecycle manager at `dartclaw_server/lib/src/task/worktree_manager.dart`.

**Creation** — two modes:
- **Project-backed**: single-step `git worktree add <path> -b <branch> origin/<defaultBranch>` from the project's clone directory
- **Local fallback**: two-step `git branch` + `git worktree add` from the local base ref

Branch naming: `dartclaw/task-<taskId>`, with `-N` suffix on collision (up to 100 attempts).

Worktree path: `<dataDir>/worktrees/<taskId>/`

**Cleanup** — removes worktree directory and deletes the branch. Best-effort (logs warnings, does not throw).

**Stale detection** — `detectStaleWorktrees()` checks for worktrees older than the configured timeout (default 24 hours).

### 6.2 TaskFileGuard

Per-task file access registry at `dartclaw_server/lib/src/task/task_file_guard.dart`.

Maintains a `Map<String, String>` of `taskId -> canonicalized worktree path`. The harness uses `isAllowed(taskId, filePath)` to validate that file operations stay within the task's worktree boundary.

Registration lifecycle:
1. `register(taskId, worktreePath)` — on worktree creation
2. `deregister(taskId)` — on worktree cleanup or task review completion

### 6.3 DiffGenerator

Generates structured diff data at `dartclaw_server/lib/src/task/diff_generator.dart`.

Uses three-dot diff (`baseRef...branch`) to show only changes introduced on the branch. Produces `DiffResult` containing:
- Per-file `DiffFileEntry` with status (added/modified/deleted/renamed), line counts, and hunks
- Summary totals: `totalAdditions`, `totalDeletions`, `filesChanged`

### 6.4 MergeExecutor

Handles merging a task branch onto the base branch at `dartclaw_server/lib/src/task/merge_executor.dart`.

Supports two strategies:
- **Squash merge** (default): `git merge --squash` + commit
- **Merge commit**: `git merge --no-ff`

Conflict handling: on merge conflict, aborts the merge, restores the original state (stash pop), and returns `MergeConflict` with conflicting file list.

### 6.5 RemotePushService

Pushes branches to remote repositories at `dartclaw_server/lib/src/task/remote_push_service.dart`.

Runs `git push` via `Isolate.run()` to avoid blocking the main event loop. This was the first use of `Isolate.run()` in DartClaw (introduced in 0.14).

Credentials are resolved from `CredentialsConfig` and injected via `GIT_SSH_COMMAND` / `GIT_ASKPASS` environment variables — never stored in the container or task config.

Returns sealed `PushResult`: `PushSuccess`, `PushAuthFailure`, `PushRejected`, `PushError`.

### 6.6 PrCreator

Creates GitHub pull requests at `dartclaw_server/lib/src/task/pr_creator.dart`.

Uses the **outpost pattern**: invokes `gh pr create` as a subprocess. Gracefully degrades when `gh` is not available on PATH, returning `PrGhNotFound` with manual instructions.

PR metadata: title from task title, body from task description + acceptance criteria.

Supports: `--draft`, `--label`, configurable `--base` branch.

### 6.7 ArtifactCollector

Type-aware artifact collection at `dartclaw_server/lib/src/task/artifact_collector.dart`.

Collection strategy by task type:

| TaskType | Strategy | Collected Files |
|----------|----------|-----------------|
| `coding` | Git diff generation | `diff.json` via DiffGenerator |
| `research`, `writing` | Modified file scan | `.md` files modified since `task.startedAt` |
| `analysis` | Modified file scan | `.json`, `.csv`, `.yaml`, `.yml`, `.xml`, `.txt` |
| `automation` | Transcript summary | `transcript.md` from session messages |
| `custom` | All modified files | All files, kind inferred from extension |

Artifacts are stored at `<dataDir>/tasks/<taskId>/artifacts/`. Existing artifacts are cleared before each collection pass.

---

## 7. Task Review Workflow

### 7.1 TaskReviewService

Shared lifecycle service at `dartclaw_server/lib/src/task/task_review_service.dart`.

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

### 7.4 Channel-Based Review

Review commands flow through the channel message pipeline:

```
Channel message
    |
    v
ReviewCommandParser.parse()
    |
    +-- "accept" / "accept <id>"
    +-- "reject" / "reject <id>"
    +-- "push back: <feedback>" / "push back <id>: <feedback>"
    |
    v
ReviewCommandDispatcher.tryHandle()
    |
    v
Resolve target task:
  1. Thread-bound task (implicit from thread binding)
  2. Explicit task ID prefix
  3. Single task in review (auto-resolve)
  4. Multiple tasks: disambiguation response
    |
    v
TaskReviewService.reviewForChannel()
    |
    v
ChannelReviewResult -> formatted response message
```

Components:
- `ReviewCommandParser` — stateless parser in `dartclaw_core/lib/src/channel/review_command_parser.dart`
- `ReviewCommandDispatcher` — task resolution + response formatting in `dartclaw_core/lib/src/channel/review_command_dispatcher.dart`
- `TaskReviewService.channelReviewHandler()` — adapter that maps `ReviewResult` to `ChannelReviewResult`

### 7.5 Concurrency Control

`TaskReviewService` uses per-task async locks (`_reviewLocks`) to serialize concurrent review actions on the same task. This prevents race conditions where two reviewers simultaneously try to accept/reject the same task.

### 7.6 Review Mode

`TaskExecutor` determines post-completion status based on `configJson['reviewMode']`:

| Mode | Behavior |
|------|----------|
| `auto-accept` | Task transitions directly to `accepted` |
| `mandatory` | All tasks go to `review` |
| `coding-only` | Coding tasks go to `review`, others auto-accept |
| _(default)_ | All tasks go to `review` |

An optional `onAutoAccept` callback allows automatic acceptance after the review transition.

---

## 8. Task Events and Observability

### 8.1 TaskEvent Model

Sealed-class event hierarchy in `dartclaw_models/lib/src/task_event.dart`:

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

`TaskEventService` in `dartclaw_storage/lib/src/storage/task_event_service.dart`:

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

Centralized recording service at `dartclaw_server/lib/src/task/task_event_recorder.dart`.

Each convenience method:
1. Constructs a `TaskEvent` with appropriate kind and details
2. Inserts synchronously via `TaskEventService` (NF04 durability)
3. Fires `TaskEventCreatedEvent` on the `EventBus`

Methods: `recordStatusChanged()`, `recordToolCalled()`, `recordArtifactCreated()`, `recordPushBack()`, `recordTokenUpdate()`, `recordError()`, `recordCompaction()`.

### 8.4 TaskProgressTracker

Throttled progress tracking at `dartclaw_server/lib/src/task/task_progress_tracker.dart`.

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

### 8.5 AgentObserver

Per-runner runtime metrics at `dartclaw_server/lib/src/task/agent_observer.dart`.

Tracks per-runner: state (idle/busy/stopped/crashed), current task/session, tokens consumed, turns completed, error count, cache tokens, turn duration, tool call stats.

Uses callback pattern: `TaskExecutor` calls `markBusy()`/`markIdle()` on acquire/release, and `recordTurn()` after each completed turn. Metrics are in-memory and reset on restart. Fires `AgentStateChangedEvent` on the `EventBus`.

Pool-level summary: `poolStatus` returns `(size, activeCount, availableCount, maxConcurrentTasks)`.

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
| `toolCalls` | `List<ToolCallRecord>` | Detailed tool call records |

### 9.2 Storage

`TurnTraceService` in `dartclaw_storage/lib/src/storage/turn_trace_service.dart`:

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
    tool_calls         TEXT
);
```

### 9.3 Query API

`GET /api/traces` supports filtering by `taskId`, `sessionId`, `runnerId`, `model`, `provider`, `since`, `until`, plus pagination (`limit`, `offset`).

Returns `TraceQueryResult`: paginated trace list + `TurnTraceSummary` aggregates (total tokens, total duration, total tool calls, trace count) over the full filtered result set.

Introduced in 0.14.

---

## 10. Multi-Project Support

### 10.1 Project Model

Defined in `dartclaw_models` (see [ADR-017](../adrs/017-multi-project-architecture.md)):

| Field | Type | Purpose |
|-------|------|---------|
| `id` | `String` | Unique project identifier |
| `name` | `String` | Display name |
| `gitUrl` | `String` | Remote repository URL |
| `localPath` | `String` | Clone directory: `<dataDir>/projects/<projectId>/` |
| `defaultBranch` | `String` | Base branch for worktrees |
| `credentialsRef` | `String?` | Reference to credentials config entry |
| `pr` | `PrConfig` | PR creation settings (strategy, draft, labels) |
| `status` | `ProjectStatus` | `ready`, `cloning`, `error` |

### 10.2 ProjectService

Interface in `dartclaw_core`, implementation in `dartclaw_server/lib/src/project/project_service_impl.dart`.

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

Time-based job executor at `dartclaw_server/lib/src/scheduling/schedule_service.dart`.

Uses single-shot `Timer` + reschedule pattern for accurate cron intervals. Jobs run in isolated sessions (`SessionKey.cronSession`).

### 11.2 ScheduledTaskRunner

Bridges `ScheduledTaskDefinition` config entries into `ScheduledJob` instances at `dartclaw_server/lib/src/scheduling/scheduled_task_runner.dart`.

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

### 12.1 Per-Task Budget

Resolved by `TaskExecutor._resolveTokenBudget()`:

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

Pre-turn check in `_checkBudget()`:
- Reads cumulative session cost from `KvService`
- At configurable warning threshold (default 80%): injects warning system message, fires budget warning event
- At 100%: fails task with `budget_exceeded` reason
- **Fail-safe**: any exception during budget check defaults to proceed (open policy)

### 12.2 Global Daily Budget

`BudgetEnforcer` in `dartclaw_server/lib/src/governance/budget_enforcer.dart`:

- Reads daily totals from `UsageTracker.dailySummaryForDate()`
- Timezone-aware: supports `UTC`, `UTC+N`, `UTC-N` offsets
- Warning at 80%, configurable action at 100%:
  - `BudgetAction.block` — throws `BudgetExhaustedException`, rejecting the turn
  - `BudgetAction.warn` — logs warning, allows turn to proceed
- Warning state is in-memory (resets on restart)

### 12.3 Integration with Governance

Budget enforcement is one layer of the governance stack, evaluated per turn by `TurnGovernanceEnforcer`:

```
TurnGovernanceEnforcer
    |
    +-- SlidingWindowRateLimiter (per-sender + global)
    +-- BudgetEnforcer (daily token budget)
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
- [ADR-023](../adrs/023-workflow-task-boundary.md) — behavioural contract for the workflow↔task boundary; names the `_isWorkflowOrchestrated` branch and `WorkflowCliRunner` one-shot path as intentional

# Task Execution Architecture

How DartClaw creates, schedules, executes, reviews, and observes tasks: the task domain model and state machine, the `TaskExecutor` pipeline, worktree isolation and git delivery, review, task events and turn traces, multi-project binding, and budgets. It is the contributor reference for changing those code paths.

Execution allocation (`ExecutionCoordinator`) and the turn lifecycle (`TurnManager`/`TurnRunner`) belong to [Control Protocol](control-protocol.md); this document covers only how tasks use them. Workflow-owned tasks are summarized where they share the task path; the workflow engine is in [Workflow Architecture](workflow-architecture.md). For *using* tasks (creating them, review flow, budgets, scheduling examples) read [`docs/guide/tasks.md`](../../docs/guide/tasks.md).

**Current through**: 0.28.0

---

## 1. Overview

A **task** is a background unit of work run by an agent harness. Any surface can create one: Web UI, HTTP API, `task_create` tool, channel message, cron schedule, or workflow step. Creation never executes inline. A poller dispatches queued tasks onto execution leases, and the result optionally goes through human review.

Design invariants:

- **Creation and execution are decoupled.** `TaskService` writes a row; `TaskExecutor` polls for `queued` rows.
- **Optimistic locking.** Every status change is a compare-and-set on status and version.
- **One execution authority.** Task code requests a provider-neutral lease from `ExecutionCoordinator` and never manages worker pools, caches, or containers.
- **Budgets fail open on error.** A throwing pre-turn budget check lets the turn proceed (see [Budgets](#10-budgets)).
- **Event recording is awaited, trace persistence is not.** Task events are durable before the status they describe is published; turn traces are fire-and-forget.

---

## 2. Task Domain Model

### 2.1 Where the code lives

| Package | Task-related contents |
|---|---|
| `dartclaw_kernel` | `AgentExecution`, `WorkflowStepExecution`, `Project`/`PrConfig`/`ProjectStatus`, `TaskConfig`/`TaskBudgetConfig`, legacy-category refusals (`task_legacy_compatibility.dart`), `ScheduledTaskDefinition` |
| `dartclaw_core` | `Task`, `TaskStatus`, `TaskArtifact`, `Goal`, `TaskEvent`/`TaskEventKind` (`lib/src/task/`); repositories (`storage/database_task_repository.dart`, `file_task_repository.dart`); `TaskEventService`, `TurnTraceService` (`storage/`); `TurnOutcome`, `ToolCallRecord`, `TurnTrace` (`turn/`); `ProjectService` interface |
| `dartclaw_runtime` | `TaskService`, `TaskExecutor`, `TaskReviewService`, worktree/merge/push/PR services, `TaskBudgetPolicy`, observers (`lib/src/task/`); `ProjectServiceImpl` (`project/`); scheduling (`scheduling/`); wiring (`runtime/task_wiring.dart`) |

The server stores tasks in PostgreSQL; a standalone (no-server) run stores them in `FileExecutionStore`. Both are behind the same repository interfaces. Schemas, the standalone checkpoint, and write safety are in [Data Model](data-model.md).

### 2.2 Task

`Task` (`dartclaw_core/lib/src/task/task.dart`) is an immutable value object. `configJson` and `worktreeJson` are recursively frozen at construction; `copyWith` uses a sentinel to tell "not provided" from explicit `null`. Session, provider, model, and token budget are not task columns: `Task.sessionId`, `.provider`, `.model`, and `.maxTokens` resolve through the linked `AgentExecution` row, and `workflowRunId`/`stepIndex` through `WorkflowStepExecution` ([ADR-021](../adrs/021-agent-execution-primitive.md)). `TaskService.get`/`list` hydrate both rows in the joined storage query.

`configJson` is the open-ended part of the contract. Keys the executor and review path read:

| Key | Reader | Meaning |
|---|---|---|
| `needsWorktree` | `TaskConfigView` | `true` creates an isolated git worktree. The only trigger. |
| `securityProfile` | `TaskConfigView` | `workspace` or `restricted`. Host-reserved: `TaskService.create` rejects it inside `configJson` and takes it as a top-level argument from the authenticated API. |
| `allowedTools`, `readOnly` | `TaskConfigView` | Per-turn tool allowlist; read-only enforcement. A set `allowedTools` makes the worker single-use. |
| `reviewMode` | `TaskConfigView` | `auto-accept`, `mandatory`, `worktree-only`; see [Review mode](#64-review-mode). |
| `tokenBudget`, `budget` (deprecated) | `TaskConfigView`, `TaskBudgetPolicy` | Per-task token cap. |
| `effort`, `requiredInputPath`, `_continueSessionId`, `_baseRef`/`baseRef` | `TaskConfigView` | Effort override; file that must exist before the turn; session to continue; worktree/diff base ref. |
| `pushBackComment`, `pushBackCount` | review path | Feedback consumed by the next prompt; push-back counter. |
| `lastError`, `errorSummary`, `_lastFailureKind` | `TaskFailureHandler` | Retry context and failure bookkeeping. |
| `_tokenBudgetWarningFired` | `TaskBudgetPolicy` | Warn-once cell. |
| `scheduleId` | `ScheduledTaskRunner` | Dedup key for scheduled tasks. |

Keys starting with `_` are internal; `TaskCreationService` refuses them from callers.

### 2.3 Execution declarations

Worktree isolation, artifact collection, review routing, prompt scope, and security profile each come from their own declaration (`needsWorktree`, `reviewMode`, `securityProfile`, `readOnly`), not from a task "type". The legacy `tasks.type` column survives only for compatibility: new rows get a neutral placeholder, and pre-upgrade `research` rows or `coding` rows without a `needsWorktree` declaration are refused with migration guidance (`TaskLegacyRefusal`, failed non-retryably by the poller).

Workflow-owned tasks (`task.workflowStepExecution != null`) share this path. Their authored step type stays on the `WorkflowStepExecution` row, and write intent is `configJson.readOnly`. They branch inside `_executeCore` (see [3.4](#34-execution-core)).

### 2.4 State machine

Defined in `TaskStatus.validTransitions` (`dartclaw_core/lib/src/task/task_status.dart`). `Task.transition()` enforces it, sets `startedAt` on `running` and `completedAt` on terminal states, clears `completedAt` when a task returns to `queued`, and bumps `pushBackCount` on `review → queued`.

[![Task lifecycle: status transitions](diagrams/tasks-lifecycle.svg)](diagrams/tasks-lifecycle.svg)

The figure shows the main path; the table is authoritative (it adds `running → accepted` for `auto-accept`, `review → running/queued/failed`, and `interrupted`).

| From | To |
|---|---|
| `draft` | `queued`, `cancelled` |
| `queued` | `running`, `cancelled`, `failed` |
| `running` | `review`, `accepted`, `interrupted`, `failed`, `cancelled` |
| `interrupted` | `queued`, `cancelled` |
| `review` | `accepted`, `rejected`, `queued`, `running`, `failed` |
| `failed` | `queued` (retry or manual restart) |
| `cancelled` | `failed` (only the workflow race correction, below) |
| `accepted`, `rejected` | none |

`TaskStatus.terminal` is true for `accepted`, `rejected`, `cancelled`, and `failed`, even though `failed` has a retry edge. `updateFields` refuses terminal tasks, so retry bookkeeping is written while the task is still `running`. No production code enters `interrupted` today; the edges are reserved.

`cancelled → failed` exists for one case: a workflow turn failure that raced a dispose-cancel must win over the cancel. Only `TaskFailureHandler` calls it, gated by `correctCancelled`; generic cancellation is never rewritten.

### 2.5 TaskArtifact and Goal

`TaskArtifact` (`task_artifact.dart`) is a named output with `kind` in `diff`, `document`, `data`, `branch`, `pr` and a `path` that is a file path or, for `pr`/`branch` artifacts, a URL or branch name.

`Goal` (`goal.dart`) groups tasks and may carry `maxTokens` as an inherited budget. `GoalService` allows two levels only (a parent may not itself have a parent) and renders goal context for the prompt: title and mission, plus the parent's, truncated to 800 characters.

### 2.6 Optimistic locking

`TaskRepository.updateIfStatus` runs `UPDATE … WHERE id = ? AND status = ? AND version = ?` and increments `version`. `TaskService.transition` reads the task, applies `Task.transition`, writes, and on a miss re-reads to classify the failure: `VersionConflictException` when the version moved, `StateError` when only the status moved, `ArgumentError` when the task is gone. Callers (`TaskActionService`, `TaskReviewService`) map these to 409/404 results.

---

## 3. Execution Pipeline

### 3.1 End-to-end flow

[![Task execution pipeline](diagrams/tasks-execution-pipeline.svg)](diagrams/tasks-execution-pipeline.svg)

Steps 1 to 5 are detailed in 3.3 and steps 6 to 7 in 3.4 and 3.5; the lease is released in a `finally` on every path.

### 3.2 Entry points

| Class | Role |
|---|---|
| `TaskCreationService` | Validates an untrusted create body (types, retired `type`/`task_type`, reserved `_` keys, `needsWorktree` boolean, existing `projectId`, positive `maxTokens`). Used by the HTTP API and Web UI. |
| `TaskService` | Business layer over `TaskRepository`: `create`, `transition`, `updateFields` (non-terminal only), `mergeConfigJson` (atomic key merge), artifacts. Implements `WorkflowTaskService`, the narrow contract `dartclaw_workflow` sees. Awaits `TaskEventRecorder` before firing `TaskStatusChangedEvent`; fires `TaskReviewReadyEvent` best-effort on entering `review`. |
| `TaskActionService` | Surface-neutral `start`, `checkout`, `cancel`, `review` returning `TaskActionResult` (status code + code + message) for the HTTP layer. `start` on a `failed` task clears failure markers and resets `retryCount`. `cancel` removes the worktree and cancels the active turn. |

Create and link of the `AgentExecution` row share one `ExecutionRepositoryTransactor` transaction; nested transactions are rejected with `NestedTransactionError`.

### 3.3 TaskExecutor

`TaskExecutor` (`task/task_executor.dart`, helpers in `task_executor_helpers.dart`) polls every `pollInterval` (2 s). One poll (`_pollOnceInner`), per queued task in `createdAt` then `id` order:

1. Fail legacy-category rows (`TaskLegacyRefusal`), non-retryably.
2. `_prepareQueuedTask`: unknown project fails, `cloning` waits (task stays queued), `error` fails.
3. Hydrate the `WorkflowStepExecution`; create the task session with `SessionKey.taskSession(taskId:)` (or continue `_continueSessionId`; a missing or archived session fails the task) and link it to the `AgentExecution`.
4. Resolve provider (task, then `agent.provider`, then the primary runner's) and execution policy from `securityProfile` through `ExecutionPolicyResolver`; a policy refusal fails the task.
5. `ExecutionCoordinator.acquire` with `ExecutionAdmission.failFast`. Capacity is taken first and admission second (daily budget, session lock, loop pre-check, rate window), so a full lane leaves no admission side effects. A `null` lease (provider lane full) leaves the task queued; `BusyTurnException` (global session cap) leaves it queued and ends the pass; `LoopDetectedException` and `BudgetExhaustedException` fail the task non-retryably; worker-creation failures record a `taskError` event once and leave it queued.
6. `_checkout` (queued → running). If it loses the race, the lease is released.
7. Run `_executeCore` unawaited, tracked in `_activeExecutionTasks`; `finally` releases the lease.

`workflowOnly: true` (zero-server workflow runs) restricts polling to workflow-owned tasks. `stop()` stops the timer, cancels active tasks (transition to `cancelled`, then `cancelTurn`), and drains.

Tasks and workflow steps are polled, so they never block inside `acquire`. `ExecutionCoordinator` semantics (lanes, `pool_size`, worker reuse, quarantine) are in [Control Protocol §6.2](control-protocol.md#62-execution-allocation); what matters for tasks:

- Tasks and workflow steps use the worker lane, bounded by `providers.<id>.pool_size`. A single-harness SDK composition may run ordinary tasks on its primary runner only when provider and policy match exactly (`allowPrimaryBackgroundFallback`); the server never does.
- A worker is single-use when the request carries execution-scoped construction inputs: a workflow step, `allowedTools`, an artifacts directory, or spawn environment. Other host workers may be cached after release.
- A container worker serving a task is disposed with its turn. Container profiles, lifetimes, and naming are in [Security Architecture](security-architecture.md#profiles-and-authorities).

**Placement.** `ExecutionPolicyResolver.resolveForTask` decides location (`tasks.execution`, else container when containers are enabled, else host) and profile (`workspace` or `restricted`, from `configJson.securityProfile`; omitted means `workspace`). The profile is declared only through the authenticated `POST /api/tasks` top-level `securityProfile` field. Channel and tool creation seams carry none, and a `securityProfile` inside `configJson` is rejected. A declared profile on a host-only task lane is refused rather than downgraded, and there is no provider or policy fallback.

### 3.4 Execution core

`_executeCore` receives the running task plus the leased runner and runs these steps. Every failure goes through `TaskFailureHandler` (3.5).

1. **Project.** `taskProjectId(task)` resolves `Task.projectId`, then legacy `configJson.projectId`. An unknown, `error`, or `cloning` project fails the task. A task with no project binding and no workflow ownership uses `ProjectService.defaultProject`. `ensureFresh` fetches (5-minute cooldown, ref-aware lock); a strict fetch (workflow tasks) fails the task on error. The resolved base ref is stored in `configJson._baseRef`. Base ref precedence: the explicit requested branch, then the symbolic `HEAD` of the local path (only for a workflow-orchestrated task on the `_local` project), then `project.defaultBranch`.
2. **Worktree.** When `needsWorktree` is true, `WorktreeManager.create` makes the checkout, `TaskFileGuard.register` records it, and `worktreeJson` is persisted. Workflow tasks may instead attach to a workflow-shared worktree or branch ([Workflow Architecture](workflow-architecture.md)).
3. **Execution directory.** `taskExecutionDirectory`: worktree path, else the project clone for a project-bound task, else the execution's workspace directory, else the process working directory. This is the checkout choice only; it does not assign an agent workspace principal or grant memory or skills.
4. **Preconditions.** `requiredInputPath` must exist; read-only tasks snapshot `git status`; the task session must exist and not be archived.
5. **Pre-turn budget check** ([Budgets](#10-budgets)); a warning becomes a system message.
6. **Prompt.** `_composePendingMessage`: retry context from `lastError` when `retryCount > 0`, or the push-back prompt when `pushBackComment` is set; then title, description, working directory, goal context, acceptance criteria.
7. **Workflow branch.** `WorkflowOneShotRunner` drives the complete prompt chain (initial prompt, follow-ups, optional no-tools structured-output finalizer) on the leased runner through `StepTurnRunner`, checking the budget before each prompt, writing token breakdown and provider session ID onto the step row, and firing `WorkflowCliTurnProgressEvent`. It records structured-output events but no `tokenUpdate`/`toolCalled` events and no turn trace. Wire formats and the envelope are in [Workflow Architecture](workflow-architecture.md).
8. **Turn (ordinary tasks).** Insert the user message and clear `pushBackComment`. A task-scoped `BehaviorFileService` is used for workflow workspaces and project-bound tasks. Prompt scope is `restricted` for the `restricted` container profile, otherwise `task`. Then `reserveAdmittedTurn` (agent name `task`), `executeTurn`, `waitForOutcome`, `waitForExecutionSettled`. Turn internals are in [Control Protocol §6.3](control-protocol.md#63-reserve-execute-settle).
9. **Record.** Awaited: one `tokenUpdate` event and one `toolCalled` event per retained `ToolCallRecord`. Then `unawaited` trace persistence ([Turn Traces](#8-turn-traces)).
10. **Settle a completed turn.** Fail if a read-only task mutated its checkout (compared against the step-4 snapshot, taken in the execution directory so a worktree task is checked in its worktree); skip if the task was cancelled meanwhile; collect artifacts and record `artifactCreated`; fail non-retryably if `outcome.totalTokens` exceeds the task's token budget; transition to the post-completion status; call `onAutoAccept` when it is set, the status is `review`, and the task is not workflow-owned (workflow git promotion owns publish and merge there).
11. **Settle a failed turn.** A loop detection on the outcome fails non-retryably; anything else is a retryable `turnFailure`.

`onAutoAccept` is wired when `tasks.completion_action: accept`; it runs a normal `accept` review, so merge conflicts or push failures leave the task in `review` with the error logged.

### 3.5 Failure and retry

`TaskFailureHandler.markFailedOrRetry` (`task_budget_policy_failure.dart`) is the only failure path. Each call site supplies a `TaskFailureKind` (`task_failure_kind.dart`): a `TaskFailureReason` the host decided (`projectSetup`, `budgetExceeded`, `loopDetected`, `turnFailure`, `containerCrash`, …), a `TaskLimitFailure` (`stall`, `turnTimeout`), or a `TaskExecutionFailure` keyed by the exception's runtime type. The persisted key is the only comparison; no message text is parsed.

When `retryable` and `retryCount < maxRetries`:

1. If `configJson._lastFailureKind` equals this kind, fail permanently. A repeated failure kind is not retried.
2. Otherwise store the sanitized message in `lastError` (first line, prefixes stripped, 200 characters) and the kind in `_lastFailureKind`, increment `retryCount`, clear the session ID, and transition `running → failed` (trigger `retry-in-progress`) then `failed → queued` (trigger `retry`).
3. The next prompt starts with the retry context.

Non-retryable call sites: project setup, missing required input or session, absent prompt, read-only mutation, budget exceeded, loop detected, execution-policy refusal. Terminal failures store `errorSummary` and record a `taskError` event.

### 3.6 Cancellation and crashes

Three observers keep task state and execution consistent (wired in `TaskWiring.wirePostServer`):

- `TaskCancellationSubscriber`: on `running → cancelled`, cancels the active turn of the task's session.
- `ContainerTaskFailureSubscriber`: on `ContainerCrashedEvent` naming a task, fails it through `markFailedOrRetry` (kind `containerCrash`); no-ops if the executor already settled the task.
- `CompactionTaskEventSubscriber`: records a `compaction` event on the running task whose session compacted.

`TaskNotificationSubscriber` sends channel notifications for channel-originated tasks; it is covered by [Channel & Messaging](channel-messaging-architecture.md).

---

## 4. Turns and Worker Placement

Tasks run through the same `TurnRunner` as every other surface; the runner is the single enforcement site for guards, liveness, and limits, and returns a `TurnOutcome`. The task-relevant facts:

- The turn context carries `taskId`, the execution directory, model/effort overrides, `allowedTools`, `readOnly`, and the task prompt scope. Field lists live in `turn_manager.dart` (`TurnContext`) and `dartclaw_core/lib/src/turn/turn_outcome.dart`.
- `TurnOutcome` carries what the task path persists: normalized token counts (`inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`, `tokenUsageComplete`), `toolCalls` (bounded: the first 63 plus the latest, with exact `toolCallCount`/`failedToolCallCount`), `limitBreach`, and `loopDetection`. How the runner derives them, including cache token normalization per provider, is in [Control Protocol §6.4](control-protocol.md#64-tool-calls-usage-and-outcome-fields).
- Because the bound is applied before persistence, a task with more than 64 tool calls records at most 64 `toolCalled` events while `toolCallCount` stays exact.

---

## 5. Worktrees and Git Delivery

Tasks with `needsWorktree: true` get a git worktree, a structured diff for review, and a merge or push on accept. Tasks without one run in the execution directory from 3.4 and collect modified files instead.

### 5.1 WorktreeManager

`task/worktree_manager.dart`. Worktrees are keyed by the task UUID, except workflow-owned ones, keyed `wf-<token>` (a hash of the run id, plus `-map-<i>` per map item; `WorkflowWorktreeBinder`). Path: `<workspaceDir>/.dartclaw/worktrees/<taskId>/` (set in `TaskWiring`; the constructor default is `<dataDir>/worktrees`).

- **Project-backed** (`Project` other than `_local`): `git worktree add <path> -b <branch> <ref>` in the project clone, where `<ref>` is `origin/<defaultBranch>` (or the project's local default branch when it has no remote).
- **Local** (`_local`): `git branch` then `git worktree add` from `tasks.worktree.base_ref` (default `main`).
- **Attach mode** (`createBranch: false`, workflow-shared worktrees): checks out an existing ref; detaches only when another worktree already holds the branch.
- Branch name `dartclaw/task-<taskId>`, suffixed `-2`…`-100` on collision. `create` first reconciles existing state (adopts a matching registered worktree, removes a mismatched one, prunes a dangling one), and a failed workflow-skill materialization rolls the worktree back.
- `cleanup` removes the worktree and branch, best-effort (warnings, no throw). `cleanupWorktree` also deregisters the `TaskFileGuard` entry.
- `detectStaleWorktrees` runs once at startup (`tasks.worktree.stale_timeout_hours`, default 24). A directory older than the threshold whose task is missing or terminal is reaped; one whose task is still active is left with a warning.

### 5.2 TaskFileGuard

`task/task_file_guard.dart` is a registry of `taskId → canonical worktree path` with an `isAllowed(taskId, path)` containment check. `TaskExecutor` registers on worktree creation and `cleanupWorktree` deregisters. Nothing in `lib/` calls `isAllowed` today, so it records worktree ownership but does not enforce a boundary; containment comes from the container mounts and the guard chain ([Security Architecture](security-architecture.md)).

### 5.3 DiffGenerator and ArtifactCollector

`DiffGenerator.generate` runs inside the worktree and merges two passes by path: committed changes (`baseRef...branch`, three-dot) and uncommitted changes (`HEAD`), then adds untracked files as `added`. The result is a `DiffResult` of per-file entries (status, line counts, hunks, binary flag) with totals. User-visible git config stays in effect so diffs render as the operator's own git would.

`ArtifactCollector.collect` first clears the task's existing artifacts, then:

- worktree task: writes `diff.json` (kind `diff`) to `<dataDir>/tasks/<taskId>/artifacts/`;
- other tasks: copies files modified since `task.startedAt` from the execution directory into that directory, excluding `.git`, the data dir, and the sessions dir. Kind comes from the extension (`.diff`/`.patch` → `diff`; `.json`, `.csv`, `.yaml`, `.yml`, `.xml`, `.txt` → `data`; else `document`). `configJson.artifactExtensions` narrows the scan; a malformed list collects nothing.

### 5.4 MergeExecutor (local projects)

`task/merge_executor.dart`, operating on the server's own checkout through `WorkflowGitPort`:

1. `_assertPreMergeInvariants`: clean index, no untracked files that overlap the stash, and, when `expectedBaseSha` is given, an unmoved target. Violations throw `PreMergeInvariantException`.
2. Record `HEAD` and branch, stash local changes, check out the base ref.
3. Squash (default: `merge --squash` then commit `task(<id>): <title>`) or merge commit (`--no-ff`), per `tasks.worktree.merge_strategy`.
4. On conflict: collect the conflicting files, restore (`reset --hard HEAD` after squash, `merge --abort` otherwise), return `MergeConflict`.
5. Always restore the original branch or detached `HEAD` and pop the stash; a stash pop that collides with untracked files the merge produced resets and drops the stash.

### 5.5 RemotePushService and PrCreator (external projects)

`RemotePushService.push` runs `git push origin <branch>` in `Isolate.run` so the event loop is not blocked, after `describeProjectAuth` confirms the credential fits the remote. It returns a sealed `PushResult`: `PushSuccess`, `PushAuthFailure`, `PushRejected`, `PushError`, classified from stderr.

Credentials are referenced, never copied: a project stores `credentialsRef`, and `resolveGitCredentialPlan` (`git_credential_env.dart`) turns the `CredentialsConfig` entry into a process environment at push time. `GIT_TERMINAL_PROMPT=0` and an empty credential helper are always set. SSH remotes get `GIT_SSH_COMMAND` (with `-i` for a key credential). A GitHub token rewrites the remote to its canonical HTTPS URL and uses a `GIT_ASKPASS` script that answers `x-access-token` and reads the token from a file under `<dataDir>/projects/`. Those askpass and token files exist on disk until `RemotePushService.dispose`.

`PrCreator.create` calls the GitHub REST API directly (no `gh` CLI): `POST /repos/{owner}/{repo}/pulls` (title from the task, body from description, acceptance criteria and any notes, base `project.defaultBranch`, `draft` from `project.pr`), then `POST …/issues/{n}/labels` for `project.pr.labels`. It returns `PrCreated`, or `PrCreationFailed` for an incompatible credential, non-GitHub remote, missing token, or API error. A label failure after the PR exists still reports `PrCreationFailed` and names the PR URL. (`PrGhNotFound` is declared and handled but nothing produces it.)

---

## 6. Review

### 6.1 TaskReviewService

`task/task_review_service.dart` is the single review implementation. The Web UI and HTTP API reach it through `TaskActionService.review`, channel cards through `channelReviewHandler`, and agents through the `task_review` tool (full task IDs from `review_list`). The host does not parse channel prose for review verbs.

| Action | Target | Behavior |
|---|---|---|
| `accept` | `accepted` | Worktree tasks: merge (local project) or push and PR (external project), then clean up the worktree |
| `reject` | `rejected` | Clean up the worktree |
| `push_back` | `running` | Requires a comment; see 6.3 |

Review actions on one task are serialized by a per-task async lock (`_reviewLocks`). Results are the sealed `ReviewResult`: success, merge conflict, not found, invalid transition, invalid request, action failed.

### 6.2 Accept flow

[![Accepting a reviewed task](diagrams/tasks-accept-flow.svg)](diagrams/tasks-accept-flow.svg)

Which path runs is decided by `taskTargetsExternalProject(task)`: `taskProjectId` is non-null and not `_local`.

### 6.3 Push-back

1. Reject an empty comment.
2. Transition `review → running` with `pushBackComment` set and `pushBackCount` incremented in `configJson`.
3. Record a `pushBack` event.
4. Best-effort `PushBackFeedbackDelivery`: when the task carries a `TaskOrigin`, the feedback is started as a human-input turn on the origin channel's session (wired in `service_wiring.dart`); failures are logged only. Tasks without an origin get no delivery.

The worktree is kept. `TaskExecutor` dispatches `queued` tasks only and nothing in it picks up a task that is already `running`, so a pushed-back task is not re-run by the executor on its own. `pushBackComment` is consumed by the prompt composer when the task is next dispatched.

### 6.4 Review mode

`TaskConfigView.postCompletionStatus` maps `configJson.reviewMode` after a completed turn:

| Mode | Status after completion |
|---|---|
| `auto-accept` | `accepted` |
| `worktree-only` | `review` if `needsWorktree`, else `accepted` |
| `mandatory`, absent, or unknown | `review` |

Separately, `tasks.completion_action: accept` installs `onAutoAccept`, which accepts every task that reached `review`.

---

## 7. Task Events and Live Progress

### 7.1 TaskEvent

`TaskEvent` (`dartclaw_core/lib/src/task/task_event.dart`) is an `id`, `taskId`, `timestamp`, `TaskEventKind`, and a `details` map. Producers are `TaskEventRecorder` methods:

| Kind | Details | Recorded when |
|---|---|---|
| `statusChanged` | `oldStatus`, `newStatus`, `trigger` | every lifecycle transition (`TaskService`) |
| `toolCalled` | `name`, `success`, `durationMs`, `errorType?`, `context?` | per retained tool call after an ordinary task turn |
| `tokenUpdate` | `inputTokens`, `outputTokens`, `tokenUsageComplete`, `cacheReadTokens?`, `cacheWriteTokens?` | after an ordinary task turn |
| `artifactCreated` | `name`, `kind` | artifact collection |
| `pushBack` | `comment` | review push-back |
| `taskError` | `message` | failure or provider-unavailable (`'error'` is the legacy name) |
| `compaction` | `trigger`, `sessionId`, `preTokens?` | context compaction in the task's session |
| `structuredOutputFinalizerUsed`, `…ValidationFailed`, `…FallbackUsed` | `stepId`, `outputKey`, reason | workflow structured-output finalization |

`structuredOutputInlineUsed` is retained only so historical rows still parse; nothing produces it.

### 7.2 Persistence and recorder

`TaskEventService.insert` completes before it returns (append-only `task_events`; schema in [Data Model](data-model.md)). `TaskEventRecorder._record` builds the event, awaits the insert, and only then fires `TaskEventCreatedEvent` on the `EventBus`; an insert failure propagates to the caller. The synchronous workflow callback that records `structuredOutputFallbackUsed` wraps the call and logs failures.

### 7.3 Observability pipeline

[![Turn outcome to task events, traces and runner metrics](diagrams/tasks-turn-recording.svg)](diagrams/tasks-turn-recording.svg)

[![Live task delivery: events to the UI](diagrams/tasks-live-progress.svg)](diagrams/tasks-live-progress.svg)

The first figure is the write side, the second the read side. Sections 7.4 to 7.6 describe the tracker, the stream, and the observer.

Events are recorded when the turn completes, not while it streams, so a long single-turn task shows its first progress at turn end. Status changes, compaction events, and runner/capacity state are live.

### 7.4 TaskProgressTracker

`task/task_progress_tracker.dart` subscribes to `TaskEventCreatedEvent`, starts state on `running`, accumulates `tokenUpdate` totals and the latest `toolCalled` activity (`formatToolActivity` in `tool_call_summary.dart` maps tools to verbs such as "Reading"), and emits a `TaskProgressSnapshot` at most once per second per task on a broadcast stream. `progress` is a 0–100 percentage and `null` without a budget. A final `isComplete` snapshot is emitted when the task leaves `running`. At startup the server seeds running tasks from their stored events.

### 7.5 SSE

`GET /api/tasks/events` (`api/task_sse_routes.dart`) is the task stream. Message types: `connected` (initial review count, active tasks and workflows, runner snapshot, projects), `task_status_changed`, `task_progress`, `task_event`, `runner_state`, `execution_capacity`, `project_status`, `turn_wait_state`, `workflow_sidebar_update`. Transport details are in [Observability & Operations](observability-operations-architecture.md).

### 7.6 RunnerObserver

`task/runner_observer.dart` derives runner metrics from `ExecutionCoordinator.events`: lease acquire and release set busy and idle (with current task and session), `turnSettled` accumulates tokens, cache tokens, turns, errors, duration, and tool-call counts per runner, disposal removes the runner, and quarantine marks it `crashed`. `capacityStatus` aggregates the coordinator snapshot (configured, effective, active, available, queued, cached, quarantined). Metrics are in memory and reset on restart.

---

## 8. Turn Traces

`TurnTrace` (`dartclaw_core/lib/src/turn/turn_trace.dart`) is a per-turn record: `id`, `sessionId`, `taskId?`, `runnerId?`, `model?`, `provider?`, start and end time, the four token counts, `isError`/`errorType`, and bounded `toolCalls` with exact `toolCallCount`, `failedToolCallCount`, and `toolCallsTruncated`. `totalTokens`, `effectiveTokens` (cache-weighted), and `durationMs` are derived.

`TaskExecutor._persistTrace` is the only producer, and only for ordinary task turns: it runs `unawaited` after the task events are recorded and logs a warning on failure. Workflow-owned turns and interactive turns have no trace, although the model allows a null `taskId`. `model` is the task's override, not the resolved model.

`TurnTraceService` (`storage/turn_trace_service.dart`) stores to the `turns` table, with the tool-call list in a JSON envelope (`records`, `count`, `failedCount`, `truncated`; legacy bare arrays still decode). `query` filters on `taskId`, `sessionId`, `runnerId`, `model`, `provider`, `since`, `until`, orders newest first, and clamps `limit` to 500. `GET /api/traces` and `GET /api/traces/<id>` (`api/trace_routes.dart`) expose it; the summary (token, duration, tool-call totals, trace count) covers the full filtered set, not the page.

---

## 9. Multi-Project

A **project** is a git checkout a task runs against ([ADR-017](../adrs/017-multi-project-architecture.md)). `Project` (`dartclaw_kernel/lib/src/project_runtime.dart`) holds `remoteUrl`, `localPath` (`<dataDir>/projects/<id>/`), `defaultBranch`, `credentialsRef`, `cloneStrategy`, `PrConfig` (`strategy` `branchOnly`/`githubPr`, `draft`, `labels`), and `ProjectStatus` (`cloning`, `ready`, `error`, `stale`). The reserved id `_local` is the server's own checkout and has no remote.

`ProjectService` (interface in `dartclaw_core/lib/src/project/`, implementation `dartclaw_runtime/lib/src/project/project_service_impl.dart`) registers config-defined projects (read-only) and runtime-created ones (`projects.json`).

- `defaultProject`: the config project marked default, else the first external project, else `_local`.
- `ensureFresh(project, {ref, strict})`: no-op without a remote; otherwise fetches in an isolate, skipping within `projects.fetchCooldownMinutes` (default 5) unless a `ref` is given, and sharing one in-flight fetch per project/ref/strictness. Non-strict failures log and proceed with local state; strict failures throw.

Binding: `taskProjectId(task)` (`task_project_ref.dart`) returns `Task.projectId`, then legacy `configJson.projectId`, else `null`. `taskTargetsExternalProject` is true when that id is set and not `_local`, which selects push-and-PR over local merge on accept. Execution resolution (3.4) differs slightly: an unbound, non-workflow task executes against `defaultProject`, while review keys off `taskProjectId` only.

Credentials are covered in 5.5; mount and guard scoping for project clones is in [Security Architecture](security-architecture.md).

---

## 10. Budgets

One engine, two scopes. `BudgetEngine` (`governance/budget_engine.dart`) owns the arithmetic (threshold comparison, percentage, warn-once gating) and does no I/O or error handling; each scope supplies the limit, the consumption reading, and the warn-once cell, and its consumer decides what a breach means.

[![Task budgets: limit ladder and evaluation](diagrams/tasks-budget.svg)](diagrams/tasks-budget.svg)

### 10.1 Per-task scope

`TaskBudgetPolicy` (`task/task_budget_policy.dart`) resolves the limit through the five-rung ladder in the figure (`resolveTokenBudget`, first positive value wins).

`checkBudget` runs before each turn (and before each workflow prompt). It reads cumulative session cost from `KvService` (`session_cost:<sessionId>`):

- At `tasks.budget.warning_threshold` (default 0.8): returns a system message asking the agent to wrap up, fires `BudgetWarningEvent`, and sets `configJson._tokenBudgetWarningFired`.
- At 100%: writes a `budget-exceeded` artifact and fails the task non-retryably. A terminal breach does not consume the warn-once cell.
- Any exception: proceeds. The fail-open wrapper lives here, not in the engine, because the daily scope shares the engine and must not fail open.

**Known divergence.** `TaskConfigView.tokenBudget` stops before `Goal.maxTokens` and the config default, and `TaskExecutor` uses it for the post-turn overrun check. A task budgeted only by its goal or the config default is therefore checked before a turn but not after it. Three display-only readers are shorter still and read `configJson` alone: `TaskProgressTracker._resolveTokenBudget`, `server.dart` (progress seeding), and `web/pages/tasks_page.dart`. Add no further truncated copy. Unifying the post-turn check changes behavior (goal-budgeted tasks that complete today would start failing) and needs its own decision.

### 10.2 Global daily scope

`BudgetEnforcer` (`governance/budget_enforcer.dart`) reads daily totals from `UsageTracker`, timezone-aware via `BudgetConfig.timezone`, with a fixed 80% warning constant and a warn-once marker (`budget_warning_posted_at`) in the persisted daily aggregate. It has no error handling: a storage failure surfaces rather than admitting an over-budget turn. `TurnGovernanceEnforcer` maps the result: at 100% with `BudgetAction.block` it throws `BudgetExhaustedException` (which the poller turns into a non-retryable task failure); otherwise it broadcasts `budget_warning` and continues. The daily guardrail and the per-task cap are separate controls ([Observability & Operations](observability-operations-architecture.md), Usage Tracking; [Security Architecture](security-architecture.md) for governance).

---

## 11. Scheduled Tasks

`ScheduledTaskRunner` (`scheduling/scheduled_task_runner.dart`) turns each enabled `ScheduledTaskDefinition` (a `scheduling.jobs` entry with `type: task`) into a callback-backed `ScheduledJob` with id `auto-task-<definitionId>`. When it fires it lists non-terminal tasks whose `configJson.scheduleId` matches and skips if one is open (missed fires are not backfilled); otherwise it calls `TaskService.create` with id `sched-<definitionId>-<ms>-<4hex>`, the definition's title, description, acceptance criteria, `autoStart`, and `model`/`effort`/`tokenBudget` in `configJson`, trigger `system`.

`ScheduleService` and the other job types are covered in [Observability & Operations](observability-operations-architecture.md#10-scheduling-and-heartbeat). Prompt-type jobs run on provider worker leases, never the primary lane.

---

## Cross-References

- [System Architecture](system-architecture.md): package DAG, composition root, wiring
- [Control Protocol](control-protocol.md): execution allocation, turn lifecycle, tool calls and usage fields
- [Security Architecture](security-architecture.md): guards, container isolation, governance enforcement
- [Data Model](data-model.md): `tasks`, `task_events`, `turns` schemas, standalone checkpoint
- [Workflow Architecture](workflow-architecture.md): workflow steps as tasks, structured-output envelope, shared worktrees
- [Observability & Operations](observability-operations-architecture.md): SSE transport, usage tracking, scheduling
- [Channel & Messaging](channel-messaging-architecture.md): `ChannelTaskBridge`, task notifications
- ADRs: [017](../adrs/017-multi-project-architecture.md) multi-project and credentials; [021](../adrs/021-agent-execution-primitive.md) `AgentExecution`/`WorkflowStepExecution`; [022](../adrs/022-workflow-run-status-and-step-outcome-protocol.md) step outcome; [023](../adrs/023-workflow-task-boundary.md) workflow↔task boundary

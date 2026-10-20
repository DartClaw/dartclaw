# Session & State Architecture

How DartClaw holds conversation state: the session model and its keys, per-session conversation state and admission, the locks and global cap that gate turns, the event bus, and session reset, maintenance and crash recovery. It does not cover the harness side of a turn ([Control Protocol](control-protocol.md)), channel adapters and thread binding ([Channel Messaging](channel-messaging-architecture.md)), runtime governance and emergency controls ([Security Architecture](security-architecture.md)), or store schemas and write safety ([Data Model](data-model.md)).

**Current through**: 0.28.0

---

## Table of Contents

1. [Overview](#1-overview)
2. [Session Model](#2-session-model)
3. [Session Keys and Scoping](#3-session-keys-and-scoping)
4. [Session Resolution](#4-session-resolution)
5. [Conversation State](#5-conversation-state)
6. [Session Services](#6-session-services)
7. [Turn Admission and Locking](#7-turn-admission-and-locking)
8. [Event Bus](#8-event-bus)
9. [Group Sessions](#9-group-sessions)
10. [Session Reset and Maintenance](#10-session-reset-and-maintenance)
11. [Crash Recovery](#11-crash-recovery)

---

## 1. Overview

A session is the unit of conversation state. Every interaction (web chat, channel message, scheduled job, task, logical-agent call) happens inside one, which gives:

- **Isolation**: each session has its own message history and provider continuity.
- **Deterministic routing**: a `SessionKey` maps an external context (contact, group, thread, job, task) to one session UUID.
- **Persistence**: `meta.json` plus an append-only `messages.ndjson`, or bounded process memory for temporary conversations.
- **Serialized mutation**: one active turn per session and a global cap on concurrent turns.

| Component | Package / path | Role |
|---|---|---|
| `Session`, `SessionType`, `SessionKey`, `Message` | `dartclaw_kernel` `models.dart`, `session_key.dart` | Model and key factories |
| `SessionConfig`, `SessionScopeConfig`, `SessionMaintenanceConfig` | `dartclaw_kernel` | Config values (reference: [Configuration](configuration-architecture.md)) |
| `SessionService`, `MessageService`, `KvService`, `ConversationState`, `TurnStateStore` | `dartclaw_core` `storage/` | File-backed stores |
| `EventBus`, `DartclawEvent` | `dartclaw_core` `events/` | Typed in-process pub/sub |
| `LiveScopeConfig` | `dartclaw_core` `scoping/` | Mutable holder read at key derivation |
| `SessionLockManager`, `SessionMutationCoordinator` | `dartclaw_runtime` `concurrency/` | Session lock, global cap, arrival-order chains |
| `ConversationService`, `ConversationInboxService` | `dartclaw_runtime` `conversation/` | Web conversation admission, queue, branching, inbox |
| `SessionResetService`, `GroupSessionInitializer` | `dartclaw_runtime` `session/` | Reset timers, group pre-creation |
| `SessionMaintenanceService` | `dartclaw_runtime` `maintenance/` | Archive and retention pipeline |

---

## 2. Session Model

`Session` (`packages/dartclaw_kernel/lib/src/models.dart`) carries identity (`id`, `channelKey`), classification (`type`, `retention`), title authority (`title`, `titleRevision`, `titleProvenance`, `automaticTitleAttempted`), pinned routing (`provider`, `securityProfile`, `executionMode`, `workspace`), and inbox state (`settledAt`, `readMessageCursor`, `attentionReadEventId`, `dismissedAttentionEventIds`). The field table is in [Data Model](data-model.md#sessions-and-messages).

### Session types

| `SessionType` | Meaning | Deletable | Pruned by maintenance |
|---|---|---|---|
| `main` | Long-lived primary session (key `main`) | No | Never |
| `user` | Web chat created through the API; no key | Yes | Yes |
| `channel` | Derived from an inbound channel message | No | Only if its key is not active |
| `cron` | Scheduled job | No | Protected while its job is active; deleted once orphaned (stage 3) |
| `task` | Task execution | No | Never |
| `logicalAgent` | Hidden conversation created by `sessions_spawn` | Yes | Yes, via ordinary retention and count cap |
| `archive` | Read-only history left by reset or maintenance | Yes | Deleted oldest-first under the disk budget |

`SessionService.protectedTypes` (`main`, `channel`, `cron`, `task`) rejects deletion with `StateError`. `isChatFacing` (everything except `cron`, `task`, `logicalAgent`) decides what enters the conversation index; archived conversations stay owner-searchable.

`listSessions` hides `task` and `logicalAgent` sessions unless the caller asks for them by type, so lifecycle code that must see everything passes `types: SessionType.values`. Normal list and sidebar queries therefore omit logical-agent sessions.

### Retention

`Session.retention` is the single persistence classifier.

- `durable` (default): `meta.json` and `messages.ndjson` on disk.
- `process`: temporary conversation. `createSession` accepts it only for `user` sessions. `SessionService` keeps the session and its `ConversationState` in memory (cap `maxProcessSessions` = 32), and `MessageService` keeps up to 500 messages per session. A missing session under an installed retention resolver is treated as revoked and writes are refused. The create route pins `provider`, `securityProfile` and `executionMode` from `TemporaryConversationCapability`, so these sessions run on a worker lane (`ExecutionSurface.temporary`), not the primary runner.

Every durable-only consumer checks the classifier before writing: conversation index, memory and daily log, automatic title, usage KV (`isDurable` call sites in `turn_runner_execution.dart`, `conversation_index_projection.dart`, `harness_wiring.dart`). Branch destinations inherit their source's retention. Ending a temporary conversation goes through `markTemporaryEnding` and `releaseTemporarySession`, and a failed cleanup leaves it in `end_failed` so the end can be retried.

### Settled, read and attention state

Settling removes a completed, read conversation from the active inbox without making it read-only; new work clears `settledAt`. The owner settles manually, or `ConversationInboxService.autoSettleIdleSessions` does it after `sessions.auto_settle_idle_days` (default 0, disabled) as the first step of the maintenance run. Attention items are derived on read from `ConversationState` submissions and display records. Only the read marker and the dismissed ids (capped at `maxDismissedAttentionEventIds` = 200) are stored on the session, and `updateInboxMetadata` advances the conversation revision with them.

### Storage layout

```
<dataDir>/sessions/
  .session_keys.json              key -> UUID index
  <uuid>/
    meta.json                     Session JSON plus nested `conversationState`
    messages.ndjson               append-only transcript
    attachments/<id>.{data,json}  accepted message attachments
    conversation/
      attempts/<attemptId>.json   per-attempt record
      queues/<queueId>.json       per-queue-item record
      manifests/<submissionId>.json  accepted attachment manifest
```

`meta.json` and the index are written atomically (`atomicWriteJson`: random-suffixed temp file, flush, rename). `.session_keys.json` is guarded by `RepoLock`, so concurrent creators (parallel workflow iterations, group pre-creation) do not lose each other's mappings.

### Messages

A `Message` is `cursor`, `id`, `sessionId`, `role`, `content`, `metadata`, `createdAt`. The cursor is the 1-based line number in `messages.ndjson`, assigned on read and not stored. That gives resume-after-cursor and backward pagination without a sequence counter. `insertMessageWithIdentity` and `replaceMessageWithIdentity` write under a caller-supplied id and are idempotent, which conversation admission and branch copy rely on for recovery.

### Logical-agent sessions

`sessions_spawn` creates a `logicalAgent` session through `getOrCreateByKey` with the key from `SessionKey.logicalAgentSession`. The key string is the external handle that `sessions_send` takes; the session UUID stays internal. The session is pinned to the agent's provider, security profile, execution mode and workspace. Persisted user and assistant messages provide replay across worker replacement or restart. A failed spawn (blocked content, schema violation, turn failure) is discarded: continuity reset, session archived, key mapping removed. Lifecycle decisions never infer logical-agent behavior from a key prefix.

### Named-agent workspace pin

A session created for a named agent pins the derived absolute workspace binding (`AgentWorkspace`: agent id, directory, `agent:<id>` storage principal) after its host marker passes admission. `meta.json` stays authoritative: moving `data_dir`, removing the agent, or changing the derived root does not rewrite the session, change its principal, or reclassify history as owner data. `AgentWorkspace.requireCurrent` refuses a turn or `getOrCreateByKey` against a mismatched binding. A branch or fork whose pinned destination no longer matches the current definition fails with `BRANCH_DESTINATION_UNAVAILABLE`; there is no automatic adoption or relocation.

---

## 3. Session Keys and Scoping

### SessionKey

`SessionKey` (`packages/dartclaw_kernel/lib/src/session_key.dart`) serializes as `agent:<agentId>:<scope>:<identifiers>`. Factories URI-encode every component, so delimiters in ids cannot collide; `SessionKey.parse` reverses it.

| Factory | Scope | Example |
|---|---|---|
| `dmShared` | `dm` | `agent:main:dm:shared` |
| `dmPerContact` | `dm` | `agent:main:dm:contact:alice%40example.com` |
| `dmPerChannelContact` | `dm` | `agent:main:dm:whatsapp:alice%40example.com` |
| `groupShared` | `group` | `agent:main:group:googlechat:spaces%2FAAAA` |
| `groupPerMember` | `group` | `agent:main:group:googlechat:spaces%2FAAAA:bob` |
| `cronSession` | `cron` | `agent:main:cron:daily-summary` |
| `taskSession` | `task` | `agent:main:task:abc123` |
| `logicalAgentSession` | `logical` | `agent:review%3Asecurity:logical:turn%2F123` |
| `webSession` | `web` | `agent:main:web:` (no production caller; web chats are unkeyed) |

The `dm` and `group` factories take an optional `threadId`, which appends `:thread:<encoded>`, so each channel thread is its own session under every scope. The main session uses the literal key `main`.

The `agentId` component is `main` unless the allowlist row that owns the conversation carries `agent: <name>`. `ChannelManager.deriveSessionKey` then emits that name (`agent:ana:dm:signal:%2B46700000001`), so a bound conversation is its own session with no storage change. `dispatchChannelTurn` creates it pinned to the agent's provider and execution policy, and its turns run under the agent's name on a worker lane with `wait` admission (`TurnManager._reserveExecutionForSession`).

### Scope configuration

| Setting | Values | Default |
|---|---|---|
| `DmScope` (`sessions.dm_scope`) | `shared`, `perContact`, `perChannelContact` | `perChannelContact` |
| `GroupScope` (`sessions.group_scope`) | `shared`, `perMember` | `shared` |

`SessionScopeConfig` (`session_scope_config.dart`) holds the global scopes plus `model` and `effort` overrides for channel turns, and a `channels` map of `ChannelScopeConfig` overrides. `forChannel(channelType)` merges a channel's override over the global values. `SessionConfig` adds `resetHour` (default 4, negative disables), `idleTimeoutMinutes` (default 0), `autoSettleIdleDays` (default 0), and the maintenance config.

`ChannelManager` reads scope through `LiveScopeConfig`, a mutable holder. `ScopeReconciler` updates a `LiveScopeConfig` on `sessions.dm_scope` / `group_scope` changes, but `service_wiring.dart` constructs the reconciler's instance separately from the one `channel_wiring.dart` gives `ChannelManager`, so a live scope change does not currently reach key derivation.

---

## 4. Session Resolution

| Surface | Type | Key | Resolved by |
|---|---|---|---|
| Web chat | `user` | none | `SessionService.createSession()` (`POST /api/sessions`) |
| Main | `main` | `main` | `getOrCreateMainSession()` at storage wiring |
| Channel DM or group | `channel` | derived (above) | `dispatchChannelTurn`, `GroupSessionInitializer` |
| Scheduled job | `cron` | `cronSession(jobId)` | `ScheduleService` |
| Task | `task` | `taskSession(taskId)` | `TaskExecutor` |
| `sessions_spawn` | `logicalAgent` | `logicalAgentSession(...)` | `LogicalAgentSessionService` dispatch |

Interactive session creation accepts no provider override (`PROVIDER_OVERRIDE_UNSUPPORTED`); main and channel conversations use the primary lane with `agent.provider`. The nullable `provider` field records host-resolved routing for system-managed and temporary sessions.

The channel path, from the session side (steps 3 to 6 belong to [Channel Messaging](channel-messaging-architecture.md); the figure marks them):

[![Session resolution: channel steps and other surfaces into SessionService](diagrams/sessions-resolution.svg)](diagrams/sessions-resolution.svg)

Web chat and temporary conversations never get a key; every keyed surface is idempotent per key, so a second call returns the same session. The user message is persisted before admission, so a cap-deferred channel turn must wait and retry inside `dispatchChannelTurn` rather than be retried by its caller.

---

## 5. Conversation State

`ConversationState` (`packages/dartclaw_core/lib/src/storage/conversation_state.dart`) is the single snapshot of one ordinary web conversation: a monotonic `revision`, `submissions` (claims), display `records` (tool, approval and context-change rows keyed by attempt and turn), `branches`, `currentContext`, `nextContext` and `telemetry`. Durable sessions nest it in `meta.json`; process-retained sessions hold the same object in memory. `ConversationService` mutates it through a `SessionMutationCoordinator` chain and rejects stale writes with `STALE_CONVERSATION_REVISION`, so a rejected mutation applies nothing. Each persisted change broadcasts `conversation_changed` with the new revision over SSE.

### Submission lifecycle

A submission claim has a `commitState` (`preparing`, `committed`, `integrityFailed`) and a `workState`. Admission (`ConversationService.submit`) is a recoverable sequence, with each step persisted before the next:

The sequence before `committed`: persist the claim as `preparing` in `meta.json`; verify attachments (sha256) and write the accepted manifest; append the transcript message by identity (its metadata carries `submissionId`, `revisionId`, `payloadDigest`); write the attempt or queue record file; persist the claim as `committed`. A committed claim becomes `accepted`, or `queued` if work is active or already queued.

[![Conversation submission lifecycle](diagrams/sessions-submission-lifecycle.svg)](diagrams/sessions-submission-lifecycle.svg)

Rules that matter when changing this code:

- **Verification before dispatch.** `_dispatch` revalidates the admitted context and checks the transcript message, record files and attachment manifest against the claim. A mismatch sets `integrityFailed` and `held` (`SUBMISSION_INTEGRITY_FAILED`).
- **Queue order.** Input is queued whenever a turn is active, a dispatch is in flight, or any item is already `queued`, so a capacity-deferred message is never overtaken. A turn that completes releases the oldest `queued` item (`_observeOutcome` then `_dispatchFirstQueued`); a failed or cancelled turn, or shutdown, holds the remaining queue (`held`) instead. `steer` first confirms cancellation of the displayed turn, then admits ordinarily.
- **Global-cap deferral.** A dispatch refused with `BusyTurnException` (web turns use waiting admission, so in practice the global turn cap or provider capacity) returns to `queued` and waits on `TurnManager.whenAdmissionCapacityAvailable()` outside the tracked background work, so shutdown never waits for capacity. When a slot frees, the session's mutation chain redispatches the oldest `queued` item unless a turn is active, whose settlement releases the queue instead. Losing the race for the slot re-defers the item.
- **Idempotence.** Resubmitting a `submissionId` with the same revision and digest replays recovery; a different payload is `SUBMISSION_CONFLICT`.

### Effective context and attempts

An admitted attempt captures one complete `EffectiveConversationContext`: nullable project association, directory, reference root, provider, model, effort. General owner chats resolve directory and reference root to the validated owner workspace; project chats resolve the named ready checkout. `nextContext` is authoritative for the current association, even when a retained attempt records an older project.

Moving a chat between General and a project (`_updateContext`) requires an idle, durable `user` session with no key and no pinned workspace (`CONTEXT_MOVE_UNAVAILABLE`, `CONTEXT_MOVE_BUSY`). It resets provider continuity, changes future context only, and appends one `contextChange` record without rewriting past attempts. The session's `AgentWorkspace` and storage principal never change. Project semantics: [ADR-017](../adrs/017-multi-project-architecture.md).

### Branches

Retry, edit and fork (refused for `channel`, `cron`, `task`, `logicalAgent` and `archive` sources with `BRANCH_UNAVAILABLE`) create a new destination session with a pre-reserved UUID (`createSessionWithIdentity`, source retention), copy visible messages by identity, and link both snapshots with a `ConversationBranchLink`. The destination provider, profile and workspace come from `TurnManager.resolveConversationDestination`, which is what fails with `BRANCH_DESTINATION_UNAVAILABLE`. Reserved identities make a crashed branch resumable.

### Shutdown

`DartclawServer.shutdown` calls `ConversationService.beginShutdown()` (refuse new admission with `SERVER_STOPPING`, hold queued work, drain the mutation chain), cancels active turns, then `drain()` awaits retained outcomes and background writes before storage closes. A completed turn cannot release queued work once shutdown has begun.

---

## 6. Session Services

All three live in `packages/dartclaw_core/lib/src/storage/`.

### SessionService

| Method | Behavior |
|---|---|
| `createSession` / `createSessionWithIdentity` | New UUID directory with `meta.json`; fires `SessionCreatedEvent`. The identity variant is idempotent for an identical request and throws `StateError` if the id is already used differently |
| `getOrCreateByKey` | Key to UUID via `.session_keys.json` under `RepoLock`. A stale or archived mapping is dropped and a new session created. For a live session it lazy-migrates `type`, `channelKey`, `provider`, `securityProfile` and `executionMode` when they differ from the request (a null `executionMode` never clears a pinned one) |
| `getByKey` / `removeKeyMapping` | Lookup without creation; unmap without deleting |
| `updateSessionType` | Used for archive; notifies the observer |
| `updateConversationState` / `updateInboxMetadata` | Replace the nested snapshot atomically; the inbox variant checks the expected revision |
| `deleteSession` | Rejects protected types; removes directory and key mappings; fires `SessionEndedEvent` |

A single `SessionServiceObserver` (`onSessionTypeChanged`, `onSessionDeleting`) feeds the derived conversation index; `MessageServiceObserver` (`onMessageAppended`, `onMessagesCleared`) feeds the index and the inbox.

### MessageService

Append-only NDJSON with cursor reads (`getMessages`, `getMessagesAfterCursor`, `getMessagesTail`, `getMessagesBefore`, filtered variants). `insertMessage` and `clearMessages` run through a `BoundedWriteQueue`, so appends never interleave. Malformed lines are skipped with a warning on read; identity writes repair a torn final line first (`_repairTornFinalLine`).

### KvService

Global key-value store over `kv.json` with a lazily loaded in-memory cache, writes through `BoundedWriteQueue`, and cache invalidation on write failure. It holds runtime state such as daily usage summaries and budget warning markers.

---

## 7. Turn Admission and Locking

### SessionLockManager

`packages/dartclaw_runtime/lib/src/concurrency/session_lock_manager.dart`. One instance is shared by every runner (`HarnessWiring`).

- **Per-session lock.** `acquire(sessionId)` waits while that session is locked, then takes the lock. Waiters resume in the order they began waiting; a caller that finds the lock momentarily free takes it at once. Callers still upstream of `acquire` are not ordered here.
- **Global cap.** After any wait, if `activeCount >= maxParallel` it throws `BusyTurnException(isSameSession: false)`. `maxParallel` comes from `concurrency.max_parallel_turns` (default 3). The manager is `Reconfigurable` on `server.*`, and a raise wakes callers parked in `whenCapacityAvailable()`.
- **Capacity wakeup.** `whenCapacityAvailable()` reserves nothing: a woken caller retries `acquire` and may lose the race.
- **Wait visibility.** A waiter arms two timers: `waiting` after 30 s and `stuck` after 120 s, surfaced as `TurnWaitState` with reason `session_lock` (`TurnWaitStateChangedEvent`).

Consistency model: single writer per session. Only turn mutations (message append plus execution) take the lock; reads are never blocked.

### Arrival order: SessionMutationCoordinator

`SessionMutationCoordinator.run(sessionId, op)` is a per-session promise chain: operations for one session run one at a time, in arrival order, and never see each other's async gaps. One instance is one chain, so separate instances (`TurnManager._sessionReservations`, `ConversationService.mutations` shared with the inbox, the session routes' own) can nest safely, while nesting on the same instance and session deadlocks. This is the canonical statement of the ordering guarantee; code comments point here.

`TurnManager.reserveTurn` runs each session's whole reservation through its chain: session read, governance checks, session lock, lane or worker permit. Ending the chain at the lock would require the coordinator to signal admission mid-`acquire`. Accepted consequences:

- A same-session successor waits behind its predecessor's governance side effects and lane wait instead of overtaking and then blocking at the lock.
- A successor is invisible to `ExecutionCoordinator`'s busy checks until its predecessor's reservation completes, so `resetSessionContinuity` can succeed in that window and the successor starts on the fresh continuity.
- A queued successor cannot be cancelled (it has no turn id), as a lock waiter could not.
- `TaskExecutor` calls `ExecutionCoordinator.acquire` plus `reserveAdmittedTurn` directly and is outside the chain.

### Admission order

`TurnRunner.admitTurn`, invoked through `ExecutionCoordinator.acquire` as the shared `admitExecution` hook (when there is no primary harness, only the lock step runs):

1. `checkBudget`: read-only daily budget check, before the lock.
2. `SessionLockManager.acquire`: session lock and global cap. A cap rejection has recorded nothing yet.
3. `checkLoopPreTurn`: turn-chain depth and token velocity (records the turn start).
4. `awaitRateLimitWindow`: defers while the global turn rate limit is reached (records an event, waits holding the cap slot).

A throw from 3 or 4 releases the lock from 2. Steps 3 and 4 record state, so they run only once the cap admitted the attempt. For the same reason a fail-fast task or workflow request takes its lane permit before admission, so one that finds no permit returns without running these checks. It then holds the permit through the rate-limit wait, so `wait` requests on the same gate queue behind it. Every other request is admitted first and then takes its permit; a fail-fast logical-agent turn must not take it first, because its admission may wait on a same-session lock while an earlier turn of that session holds the permit. The checks themselves (budget, loop detection, rate limit) are specified in [Security Architecture](security-architecture.md).

### What a rejected admission does, per surface

| Surface | Global cap reached (`BusyTurnException`, not same session) |
|---|---|
| Web chat | Submission returns to `queued`; redispatched on `whenAdmissionCapacityAvailable()` (section 5) |
| Channel | `_untilAdmitted` in `channel_wiring.dart` waits for capacity and retries; the inbound message is already persisted, so the caller must not retry itself. Same-session busy propagates |
| Task and workflow | Fail-fast; `TaskExecutor` marks the cap full and retries on the next poll |
| Direct send to an existing session (`_sendExistingSessionTurn`) | `409 AGENT_BUSY_PROVIDER` |

### Session-side turn lifecycle

[![Turn admission and locking, session side](diagrams/sessions-turn-admission.svg)](diagrams/sessions-turn-admission.svg)

The turn id is generated and `turn_state.json` written only after admission and a lane permit succeeded, so a rejected request leaves no crash marker. Settlement removes the marker and releases the lock; the harness half of the lifecycle is in [Control Protocol](control-protocol.md#6-turn-lifecycle).

---

## 8. Event Bus

`packages/dartclaw_core/lib/src/events/`. `EventBus` wraps a broadcast `StreamController<DartclawEvent>`:

- `on<T>()` returns a filtered, typed stream; `fire(event)` broadcasts.
- Fire-and-forget: with no listener an event is dropped. Subscriber exceptions are caught by `runZonedGuarded` and logged, never thrown at the producer. Firing on a disposed bus logs a warning and returns.

`DartclawEvent` is a sealed class split across `part` files, so a `switch` over it is exhaustive (the alert classifier relies on this, see [ADR-057](../adrs/057-workflow-events-stay-in-the-sealed-event-library.md)). Families:

| Family (sealed parent) | Events |
|---|---|
| `SessionLifecycleEvent` | `SessionCreatedEvent`, `SessionEndedEvent`, `SessionErrorEvent` (declared, no production emitter) |
| `TaskLifecycleEvent` | `TaskStatusChangedEvent`, `TaskReviewReadyEvent`, `TaskEventCreatedEvent`, `BudgetWarningEvent` |
| `WorkflowLifecycleEvent` | run status, step completed or skipped, parallel group, loop and map iteration, budget warning, approval requested or resolved, serialization enacted |
| `AgentExecutionEvent` | `AgentExecutionStatusChangedEvent` |
| `ContainerLifecycleEvent` | started, stopped, crashed |
| `CompactionLifecycleEvent` | starting, completed |
| `RunnerLifecycleEvent`, `ProjectLifecycleEvent` | `RunnerStateChangedEvent`, `ProjectStatusChangedEvent` |
| Unparented | `TurnWaitStateChangedEvent`, `LoopDetectedEvent`, `EmergencyStopEvent`, `OutboundMcpGovernanceEvent`, `FailedAuthEvent`, `GuardBlockEvent`, `ToolPermissionDeniedEvent`, `ConfigChangedEvent`, `CredentialHealthChangedEvent`, `ScheduledJobFailedEvent`, `ContextResearchMetricsEvent`, `WorkflowCliTurnProgressEvent`, `WorkflowCliStallEvent` |

`SessionLifecycleSubscriber` (wired in `security_wiring.dart`) logs the three session events. Producers fire without knowing consumers; consumers (SSE bridge, alert router, audit bridge, `GroupSessionInitializer`, `ScopeReconciler`) are described in [Observability](observability-operations-architecture.md) and [Configuration](configuration-architecture.md). Rationale: [ADR-011](../adrs/011-event-driven-architecture.md).

---

## 9. Group Sessions

`GroupSessionInitializer` (`packages/dartclaw_runtime/lib/src/session/group_session_initializer.dart`) pre-creates sessions for allowlisted groups so they appear in the UI before the first message. It runs at startup for every `ChannelGroupConfig` with `groupAccessEnabled`, and again on a `ConfigChangedEvent` for `channels.<type>.group_allowlist`.

For each group it calls `getOrCreateByKey(SessionKey.groupShared(agentId: entry.agent ?? 'main', ...), type: channel)`, with the row's agent as the key's agent component so it matches the key inbound messages derive. It titles the session only when `title == null`: structured `GroupEntry.name`, else the channel's `displayNameResolver`, else the raw group id. A user-set title is never overwritten. It pre-creates no thread-scoped sessions.

DM access control and pairing are in [Channel Messaging](channel-messaging-architecture.md).

---

## 10. Session Reset and Maintenance

### SessionResetService

`packages/dartclaw_runtime/lib/src/session/session_reset_service.dart`. The daily and idle timers act on `main`, `channel` and `cron` sessions only; `POST /api/sessions/<id>/reset` can target any other non-archive, non-task session (a turn in progress answers `409 SESSION_BUSY`). `sessions.reset_hour` and `sessions.idle_timeout_minutes` reload live: the service is `Reconfigurable` on `sessions.*`.

[![Session reset: three triggers, continuity first, then archive or clear](diagrams/sessions-reset.svg)](diagrams/sessions-reset.svg)

- **Idle timeout**: `touchActivity(sessionId)` restarts a per-session timer. `TurnRunner` calls it when a turn is reserved and on forward-progress events, so long tool runs keep the session alive.
- **Order inside `resetSession(id)`**: provider continuity is reset first through `TurnManager.resetSessionContinuity`, which throws `BusyTurnException` while a turn is active (the daily reset logs the failure and moves on, so that session waits for the next trigger). Only then is the session archived or cleared, so a failed reset never archives a session whose provider state is still live.
- A keyed session is archived (an empty one without a title) and `getOrCreateByKey` then creates its replacement under the same key and type at once; it treats the archived mapping as stale. An unkeyed session is cleared in place: its messages and its attachments directory are removed and no archive is created.

### SessionMaintenanceService

[![Session maintenance: six stages and the sessions they never touch](diagrams/sessions-maintenance.svg)](diagrams/sessions-maintenance.svg)

`packages/dartclaw_runtime/lib/src/maintenance/session_maintenance_service.dart`. Stages run in the figure's order, and a limit of `0` disables its stage. `mode: warn` (the default) plans and reports without applying; `enforce` applies. Stage 3 flips a cron session's type to `user` before deleting it so the protected-type guard in `deleteSession` passes.

| Stage | Action | Setting (default) |
|---|---|---|
| 0 | Auto-settle idle conversations (`ConversationInboxService`) | `sessions.auto_settle_idle_days` (0) |
| 1 | Archive sessions not updated within the window (never `archive`, `task`, or protected) | `prune_after_days` (30) |
| 2 | Archive the oldest unprotected sessions beyond the cap | `max_sessions` (500) |
| 3 | Delete orphaned cron sessions older than the window (type is flipped to `user` first to pass the delete guard) | `cron_retention_hours` (24) |
| 4 | Delete archived sessions oldest-first until usage is at most 80% of the budget | `max_disk_mb` (0) |
| 5 | Delete artifacts of terminal tasks older than the window | `tasks.artifact_retention_days` |

Protected from stages 1, 2 and 4: `main`, `task`, any session with an active turn (`isSessionActive`), a `channel` session whose key is active, and a `cron` session whose job is active. The scheduled job treats every existing channel session key as active whenever a channel is registered; `dartclaw cleanup` does so whenever a channel is enabled in config, and derives active jobs from config. Stages 0 and 5 run only from the scheduled job; `dartclaw cleanup` passes no inbox or task service. Stage 5 and the audit-file cleanup that follows the scheduled run are outside the session model.

---

## 11. Crash Recovery

Recovery layers, from the transcript up:

| Layer | Mechanism |
|---|---|
| Transcript | `messages.ndjson` is append-only and never truncated in normal operation. Reads skip malformed lines with a warning; identity writes repair a torn final line. Clients resume with `getMessagesAfterCursor` |
| Session files | `meta.json`, `.session_keys.json` and thread bindings use atomic temp-file-and-rename writes ([Data Model](data-model.md#7-write-safety)) |
| Active turns | `TurnRunner` records `{turnId, startedAt}` per session in `turn_state.json` at reservation and deletes it at settlement or cancel. After `wire()` on a serving start, `detectAndCleanOrphanedTurns()` removes surviving records and flags each session; `consumeRecoveryNotice(sessionId)` returns true once, and the web session page renders the "recovered from an interrupted turn" banner. Headless runs neither scan nor acknowledge. Store format, quarantine and startup scan: [Control Protocol](control-protocol.md) and [Data Model](data-model.md) |
| Conversation state | `ConversationService.recoverAfterRestart` runs lazily, once per session, on first touch (`_ensureRecovered`) |
| Transient state | Lock table, pause state, loop detector windows and rate-limit timestamps are in memory and reset on restart, so no phantom locks or stale limits survive a crash |
| Temporary conversations | Process memory only; lost on restart by design |

`recoverAfterRestart` rewrites persisted `workState` so nothing is shown as live that the process cannot confirm:

| Found | Becomes |
|---|---|
| `commitState: preparing` | Sequence completed idempotently; on failure `integrityFailed` and `held` |
| `dispatching`, `running`, `stopping` | `uncertain` (informational; the next dispatch marks it `failed`: "Dispatch was never confirmed") |
| `queued` | `held` (the owner releases or removes it) |
| Approval record `resolving` | `unavailable` ("Decision delivery could not be confirmed after restart") |

It also removes partial attachment uploads. An approval action is offered only when the exact request and turn are still live (`canResolveToolApproval`), recomputed on read.

The automated proof for the orphan path is `packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart`: kill a process mid-turn, restart on the same directory, and check that the recovery banner appears once and the failed-turn message (`.msg-turn-failed`) renders.

---

## Cross-References

- [System Architecture](system-architecture.md): component map, package topology, service wiring
- [Data Model & Persistence](data-model.md): session and message entities, storage layout, write safety, `turn_state.json`
- [Control Protocol](control-protocol.md): harness turn lifecycle, liveness, worker crash recovery
- [Security Architecture](security-architecture.md): budget, rate-limit, loop detection, pause and emergency stop
- [Channel Messaging](channel-messaging-architecture.md): inbound pipeline, `ChannelTaskBridge`, thread binding, DM access, crowd coding
- [Task Execution](task-execution-architecture.md): task sessions, `TaskExecutor` admission
- [Workflow Architecture](workflow-architecture.md): workflow sessions and step execution
- [Observability & Operations](observability-operations-architecture.md): SSE bridge, alerts, usage tracking
- [Architecture Governance](architecture-governance.md): fitness functions, structural boundaries
- [ADR-011](../adrs/011-event-driven-architecture.md): event bus rationale
- [ADR-017](../adrs/017-multi-project-architecture.md): projects, project chats, effective context

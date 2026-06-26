# Session & State Architecture

How DartClaw manages conversation state: session model, routing, scoping, persistence, locking, governance, maintenance, crash recovery, and the event bus that ties them together.

**Current through**: 0.18.0

---

## Table of Contents

1. [Overview](#1-overview)
2. [Session Model](#2-session-model)
3. [Session Scoping Model](#3-session-scoping-model)
4. [Session Routing](#4-session-routing)
5. [Session Services](#5-session-services)
6. [Session Locking](#6-session-locking)
7. [Event Bus Architecture](#7-event-bus-architecture)
8. [Group Sessions](#8-group-sessions)
9. [Session Maintenance](#9-session-maintenance)
10. [Thread Binding](#10-thread-binding)
11. [Governance & Emergency Controls](#11-governance--emergency-controls)
12. [Crowd Coding State](#12-crowd-coding-state)
13. [Crash Recovery](#13-crash-recovery)

---

## 1. Overview

Sessions are the primary unit of conversation state. Every interaction with
the runtime -- web chat, channel message, scheduled job, task execution --
happens within a session. Sessions provide:

- **Isolation** -- each conversation has its own message history
- **Deterministic routing** -- the `SessionKey` maps external context to internal UUID sessions
- **Persistence** -- NDJSON message files with cursor-based crash recovery
- **Concurrency safety** -- per-session write locks and global concurrency caps
- **Lifecycle management** -- automated archival, maintenance, and reset

The session subsystem spans four packages:

```
+-------------------+     +-------------------+     +-------------------+
| dartclaw_models   |     | dartclaw_config   |     | dartclaw_core     |
|                   |     |                   |     |                   |
| Session           |     | SessionConfig     |     | SessionService    |
| SessionType       |     | SessionScope-     |     | MessageService    |
| SessionKey        |     |   Config (ref)    |     | KvService         |
| Message           |     | SessionMaint-     |     | EventBus          |
| SessionScopeConfig|     |   enanceConfig    |     | DartclawEvent     |
| DmScope           |     | GovernanceConfig  |     | LoopDetector      |
| GroupScope         |     | BudgetConfig     |     | SlidingWindow-    |
| ChannelScopeConfig|     | LoopDetection-   |     |   RateLimiter     |
+-------------------+     |   Config         |     | ThreadBinding     |
                          | RateLimitsConfig  |     | ThreadBinding-    |
                          +-------------------+     |   Store           |
                                                    | DmAccessController|
                                                    | ChannelTaskBridge |
                                                    +-------------------+
                                    |
                          +-------------------+     +-------------------+
                          | dartclaw_storage  |     | dartclaw_server   |
                          |                   |     |                   |
                          | TurnStateStore    |     | SessionLockManager|
                          | (SQLite state.db) |     | SessionResetSvc   |
                          +-------------------+     | SessionMaint-     |
                                                    |   enanceService   |
                                                    | GroupSession-     |
                                                    |   Initializer     |
                                                    | TurnGovernance-   |
                                                    |   Enforcer        |
                                                    | BudgetEnforcer    |
                                                    | PauseController   |
                                                    | EmergencyStop-    |
                                                    |   Handler         |
                                                    +-------------------+
```


## 2. Session Model

### Session Entity

Defined in `packages/dartclaw_models/lib/src/models.dart`:

```
Session
  +-- id: String              (UUID v4, primary key)
  +-- title: String?          (human-readable, shown in UI)
  +-- type: SessionType       (classification enum)
  +-- channelKey: String?     (deterministic routing key)
  +-- provider: String?       (optional provider override)
  +-- createdAt: DateTime
  +-- updatedAt: DateTime
```

### SessionType Enum

| Value     | Description                                       |
|-----------|---------------------------------------------------|
| `main`    | Long-lived primary session created by the runtime  |
| `channel` | Derived from an inbound channel message            |
| `cron`    | Started by a scheduled task or cron trigger         |
| `user`    | User-initiated interactive session (web, CLI)       |
| `task`    | Associated with a tracked task execution            |
| `archive` | Read-only historical session retained for archival  |

Protected types (`main`, `channel`, `cron`, `task`) cannot be deleted through
the normal deletion API -- they are system-managed.

### SessionKey

Defined in `packages/dartclaw_models/lib/src/session_key.dart`.
Provides deterministic, collision-free routing from external contexts to
internal UUID-based sessions.

Format: `agent:<agentId>:<scope>:<identifiers>`

| Factory Method         | Scope   | Key Example                                         |
|------------------------|---------|-----------------------------------------------------|
| `webSession()`         | `web`   | `agent:main:web:`                                   |
| `dmShared()`           | `dm`    | `agent:main:dm:shared`                              |
| `dmPerContact()`       | `dm`    | `agent:main:dm:contact:alice%40example.com`         |
| `dmPerChannelContact()`| `dm`    | `agent:main:dm:whatsapp:alice%40example.com`        |
| `groupShared()`        | `group` | `agent:main:group:googlechat:spaces%2FAAAA`         |
| `groupPerMember()`     | `group` | `agent:main:group:googlechat:spaces%2FAAAA:bob`     |
| `cronSession()`        | `cron`  | `agent:main:cron:daily-summary`                     |
| `taskSession()`        | `task`  | `agent:main:task:abc123`                            |

Identifier components are URI-encoded by the factory methods to prevent
delimiter collisions. The `SessionKey.parse()` factory reconstructs the
structured representation from a serialized string.

### Session Storage Layout

```
<dataDir>/sessions/
  .session_keys.json          <-- key->UUID index (atomic writes)
  <uuid>/
    meta.json                 <-- Session JSON (atomic writes)
    messages.ndjson           <-- append-only message log
```

- **`.session_keys.json`**: Maps deterministic `SessionKey` strings to session UUIDs.
  Loaded and updated by `SessionService.getOrCreateByKey()`. Stale/archived
  mappings are removed on lookup, creating a new session with the same key.

- **`meta.json`**: Serialized `Session` object. Written atomically via
  `atomicWriteJson()` (write to `.tmp`, then `rename`).

- **`messages.ndjson`**: Append-only NDJSON file. Each line is a serialized
  `Message` object. The 1-based line number is the cursor.

### Message Entity

Defined alongside `Session` in `models.dart`:

```
Message
  +-- cursor: int             (1-based line number in NDJSON)
  +-- id: String              (UUID v4)
  +-- sessionId: String       (FK to Session.id)
  +-- role: String            (user, assistant, system)
  +-- content: String
  +-- metadata: String?       (serialized JSON metadata)
  +-- createdAt: DateTime
```


## 3. Session Scoping Model

Controls how inbound channel messages are mapped to sessions.
Defined in `packages/dartclaw_models/lib/src/session_scope_config.dart`.

### Scope Enums

**DmScope** -- how DM sessions are scoped:

| Value              | Behavior                                      |
|--------------------|-----------------------------------------------|
| `shared`           | All DMs share a single session                 |
| `perContact`       | One session per contact (across channels)       |
| `perChannelContact`| One session per (channel, contact) pair (default)|

**GroupScope** -- how group sessions are scoped:

| Value       | Behavior                                 |
|-------------|------------------------------------------|
| `shared`    | All group messages share one session (default) |
| `perMember` | One session per group member              |

### SessionScopeConfig

Top-level configuration with per-channel overrides:

```
SessionScopeConfig
  +-- dmScope: DmScope                  (global default)
  +-- groupScope: GroupScope            (global default)
  +-- model: String?                    (model override for channel turns)
  +-- effort: String?                   (effort override for channel turns)
  +-- channels: Map<String, ChannelScopeConfig>  (per-channel overrides)
```

`ChannelScopeConfig` provides per-channel overrides for DM scope, group scope,
model, and effort. Nullable fields fall back to the global defaults.

Resolution: `SessionScopeConfig.forChannel(channelType)` returns the resolved
config for a channel type, merging per-channel overrides with global defaults.

### LiveScopeConfig

Mutable wrapper in `packages/dartclaw_core/lib/src/scoping/live_scope_config.dart`
that holds the current `SessionScopeConfig`. Updated at runtime when config
changes are detected, allowing the session routing layer to pick up new scoping
rules without restart.

### Config Integration

`SessionConfig` in `packages/dartclaw_config/lib/src/session_config.dart`
bundles session-related configuration:

```
SessionConfig
  +-- resetHour: int                      (default: 4, daily reset hour)
  +-- idleTimeoutMinutes: int             (default: 0, disabled)
  +-- scopeConfig: SessionScopeConfig     (scoping rules)
  +-- maintenanceConfig: SessionMaintenanceConfig
```


## 4. Session Routing

How an inbound message is routed to a session:

```
  Inbound Message
  (sender, channel, group?, thread?)
       |
       v
  +-----------------------------+
  | 1. Governance check         |  rate limit -> budget -> loop detection
  |    (TurnGovernanceEnforcer)  |  May reject before routing.
  +-----------------------------+
       |
       v
  +-----------------------------+
  | 2. Thread binding lookup    |  ThreadBindingStore.lookupByThread()
  |    (ChannelTaskBridge)       |  If bound thread -> route to task session.
  +-----------------------------+
       | no binding
       v
  +-----------------------------+
  | 3. Scope resolution         |  LiveScopeConfig.forChannel(channelType)
  |                             |  Determines DmScope or GroupScope
  +-----------------------------+
       |
       v
  +-----------------------------+
  | 4. SessionKey computation   |  SessionKey factory method selected
  |                             |  based on scope + context:
  |    DM + perChannelContact   |  -> dmPerChannelContact()
  |    DM + perContact          |  -> dmPerContact()
  |    DM + shared              |  -> dmShared()
  |    Group + shared           |  -> groupShared()
  |    Group + perMember        |  -> groupPerMember()
  |    Cron job                 |  -> cronSession()
  |    Task                     |  -> taskSession()
  |    Web UI                   |  -> webSession()
  +-----------------------------+
       |
       v
  +-----------------------------+
  | 5. Session resolution       |  SessionService.getOrCreateByKey()
  |    Load .session_keys.json  |
  |    Key exists? -> load meta |
  |    Key missing? -> create   |
  |      new session + map key  |
  +-----------------------------+
       |
       v
  +-----------------------------+
  | 6. Session lock             |  SessionLockManager.acquire()
  |    acquire + execute turn   |  Write serialization
  +-----------------------------+
       |
       v
  +-----------------------------+
  | 7. Message persistence      |  MessageService.insertMessage()
  |    + turn execution         |  Append to messages.ndjson
  +-----------------------------+
```


## 5. Session Services

All session services live in `packages/dartclaw_core/lib/src/storage/`.

### SessionService

CRUD operations backed by the filesystem. Key methods:

| Method                | Behavior                                              |
|-----------------------|-------------------------------------------------------|
| `createSession()`     | UUID v4 dir + `meta.json`, fires `SessionCreatedEvent` |
| `getSession(id)`      | Load `meta.json`, validate UUID format                 |
| `listSessions()`      | Scan session dirs, sort by `updatedAt` descending      |
| `getOrCreateByKey()`  | Deterministic key -> UUID via `.session_keys.json`     |
| `updateTitle()`       | Atomic write of updated `meta.json`                    |
| `touchUpdatedAt()`    | Bump `updatedAt` timestamp                             |
| `updateSessionType()` | Change session type (e.g., archive on reset)           |
| `updateProvider()`    | Change provider override                               |
| `deleteSession()`     | Remove dir, fires `SessionEndedEvent`                  |

Lazy migration: `getOrCreateByKey()` updates `type`, `channelKey`, and
`provider` on existing sessions if they differ from the requested values.
This handles upgrading old sessions created before type tracking was added.

### MessageService

Append-only NDJSON persistence with cursor-based pagination:

| Method                  | Behavior                                           |
|-------------------------|----------------------------------------------------|
| `insertMessage()`       | Append JSON line, return `Message` with cursor     |
| `getMessages()`         | Read all lines, assign 1-based cursor to each      |
| `getMessagesAfterCursor()` | Resume from cursor (skip first N lines)         |
| `getMessagesTail()`     | Last N messages (backward scan)                    |
| `getMessagesBefore()`   | Backward pagination before a cursor                |
| `clearMessages()`       | Truncate NDJSON file                               |

Write serialization: `insertMessage()` and `clearMessages()` are enqueued via
`BoundedWriteQueue` (a write-ahead queue backed by `WriteOp` completers) to
prevent interleaved appends.

**Cursor model**: The 1-based line number in the NDJSON file serves as the
message cursor. This enables:
- Efficient resume after crash: "give me all messages after cursor X"
- Backward pagination: "give me N messages before cursor Y"
- Stable ordering without separate sequence counters

### KvService

Global key-value store backed by a single JSON file with atomic writes:

| Method          | Behavior                                     |
|-----------------|----------------------------------------------|
| `get(key)`      | Load from in-memory cache, lazy-init from file |
| `set(key, val)` | Atomic write via `BoundedWriteQueue`          |
| `getByPrefix()` | Prefix scan over cached entries               |
| `delete(key)`   | Remove key, atomic persist                    |

Used for global runtime state (e.g., daily usage summaries, budget warning
markers). The cache is invalidated on write failure.


## 6. Session Locking

Defined in `packages/dartclaw_server/lib/src/concurrency/session_lock_manager.dart`.

`SessionLockManager` provides per-session write serialization with a global
concurrency cap:

```
SessionLockManager
  +-- _maxParallel: int                (configurable, default: 3)
  +-- _locks: Map<String, Completer>   (per-session lock state)
  +-- _activeCount: int                (current global lock count)
  |
  +-- acquire(sessionId)               (wait if same-session busy,
  |                                     throw BusyTurnException if global cap)
  +-- release(sessionId)               (complete Completer, decrement count)
  +-- isLocked(sessionId)              (query lock state)
```

**Behavior**:
- Same-session contention: the caller `await`s the existing `Completer.future`,
  then retries. This queues turns behind each other per-session.
- Global cap: if `_activeCount >= _maxParallel`, throws `BusyTurnException`
  with `isSameSession: false`.
- Implements `Reconfigurable` -- watches `server.*` config keys and updates
  `_maxParallel` on the fly from `ServerConfig.maxParallelTurns`.

**Consistency model**: Single-writer-at-a-time per session. No reads are
blocked -- only turn mutations (message append + agent execution) acquire locks.
This simplifies consistency guarantees and avoids read-write contention.


## 7. Event Bus Architecture

Defined in `packages/dartclaw_core/lib/src/events/`.

### EventBus

Lightweight typed event bus using a broadcast `StreamController`:

```dart
class EventBus {
  Stream<T> on<T extends DartclawEvent>()   // filtered, typed subscription
  void fire(DartclawEvent event)            // broadcast to all listeners
  Future<void> dispose()                    // close controller
}
```

**Semantics**:
- Fire-and-forget: if no listener is subscribed, the event is silently dropped
  (broadcast stream semantics)
- Subscriber exceptions do not propagate to `fire()` callers -- caught by
  `runZonedGuarded` and logged
- Disposed bus logs a warning on `fire()` and returns (no exception)

### DartclawEvent Hierarchy

Sealed class hierarchy enabling exhaustive pattern matching:

```
DartclawEvent (sealed)
  |
  +-- SessionLifecycleEvent (sealed)
  |     +-- SessionCreatedEvent
  |     +-- SessionEndedEvent
  |     +-- SessionErrorEvent
  |
  +-- TaskLifecycleEvent (sealed)
  |     +-- TaskStatusChangedEvent
  |     +-- TaskReviewReadyEvent
  |     +-- TaskEventCreatedEvent
  |     +-- BudgetWarningEvent
  |
  +-- WorkflowLifecycleEvent (sealed)
  |     +-- WorkflowRunStatusChangedEvent
  |     +-- WorkflowStepCompletedEvent
  |     +-- ParallelGroupCompletedEvent
  |     +-- WorkflowBudgetWarningEvent
  |     +-- LoopIterationCompletedEvent
  |     +-- MapIterationCompletedEvent
  |     +-- MapStepCompletedEvent
  |     +-- WorkflowApprovalRequestedEvent
  |     +-- WorkflowApprovalResolvedEvent
  |
  +-- ContainerLifecycleEvent (sealed)
  |     +-- ContainerStartedEvent
  |     +-- ContainerStoppedEvent
  |     +-- ContainerCrashedEvent
  |
  +-- CompactionLifecycleEvent (sealed)
  |     +-- CompactionStartingEvent
  |     +-- CompactionCompletedEvent
  |
  +-- AgentLifecycleEvent (sealed)
  |     +-- AgentStateChangedEvent
  |
  +-- ProjectLifecycleEvent (sealed)
  |     +-- ProjectStatusChangedEvent
  |
  +-- LoopDetectedEvent             (governance)
  +-- EmergencyStopEvent            (governance)
  +-- ScheduledJobFailedEvent       (scheduling)
  +-- FailedAuthEvent               (auth/security)
  +-- GuardBlockEvent               (auth/security)
  +-- ToolPermissionDeniedEvent     (auth/security)
  +-- ConfigChangedEvent            (auth/config)
  +-- AdvisorMentionEvent           (advisor)
  +-- AdvisorInsightEvent           (advisor)
```

### SessionLifecycleSubscriber

Convenience subscriber in `session_lifecycle_subscriber.dart` that logs
session lifecycle events at INFO level. Demonstrates the typed subscription
pattern:

```dart
bus.on<SessionLifecycleEvent>().listen((event) {
  switch (event) {
    case SessionCreatedEvent(): _log.info('Session created: ...');
    case SessionEndedEvent():   _log.info('Session ended: ...');
    case SessionErrorEvent():   _log.warning('Session error: ...');
  }
});
```

### Design Rationale

See ADR-011 for the event bus design decision. Key motivations:
- Decouple producers (session service, task service, governance) from consumers
  (SSE broadcast, UI updates, channel notifications, logging)
- Enable new subsystems to observe state changes without modifying producers
- Fire-and-forget semantics keep producers simple -- no error handling for
  missing or failing consumers


## 8. Group Sessions

### GroupSessionInitializer

Defined in `packages/dartclaw_server/lib/src/session/group_session_initializer.dart`.

Pre-creates sessions for allowlisted groups so they appear in the UI immediately,
without waiting for the first inbound message.

**Trigger points**:
1. Server startup: iterates all `ChannelGroupConfig` entries with
   `groupAccessEnabled == true`
2. Config change: subscribes to `ConfigChangedEvent` and watches for
   `channels.<type>.group_allowlist` key changes

**Session creation flow**:
1. Compute `SessionKey.groupShared()` for each `(channelType, groupId)` pair
2. Call `SessionService.getOrCreateByKey()` with `SessionType.channel`
3. Set title via display name resolution chain:
   - Structured `GroupEntry.name` (trimmed, non-empty)
   - `displayNameResolver` callback (e.g., Google Chat API lookup)
   - Raw group ID as fallback
4. Only set title if `null` (newly created) -- never overwrite user-set titles

### ChannelGroupConfig

Lightweight config decoupling the initializer from channel-specific config types:

```
ChannelGroupConfig
  +-- channelType: String
  +-- groupAccessEnabled: bool
  +-- groupEntries: List<GroupEntry>
```

### DmAccessController

Defined in `packages/dartclaw_core/lib/src/channel/dm_access.dart`.
Controls which senders are allowed to DM the bot.

| Mode        | Behavior                                          |
|-------------|---------------------------------------------------|
| `open`      | Any sender may interact                           |
| `allowlist`  | Only listed senders allowed                       |
| `pairing`   | Unknown senders get a pairing code for approval    |
| `disabled`  | All DMs rejected                                  |

The pairing flow: `createPairing()` generates an 8-character code (ambiguity-free
charset: no 0/O/1/I), valid for 1 hour, max 3 pending. `confirmPairing(code)`
adds the sender to the allowlist; `rejectPairing(code)` discards it.


## 9. Session Maintenance

### SessionMaintenanceService

Defined in `packages/dartclaw_server/lib/src/maintenance/session_maintenance_service.dart`.

Executes a five-stage pipeline:

```
Stage 1: Prune Stale Sessions
  Archive sessions older than pruneAfterDays (skip protected + task + archive)

Stage 2: Count Cap
  Archive oldest non-protected sessions when active count > maxSessions

Stage 3: Cron Retention
  Delete orphaned cron sessions older than cronRetentionHours

Stage 4: Disk Budget
  Delete archived sessions oldest-first until under maxDiskMb * 80%

Stage 5: Artifact Retention
  Delete task artifacts older than artifactRetentionDays
```

**Protected sessions** are never pruned:
- `main` type (always protected)
- `channel` type with an active channel key
- `cron` type with an active job ID
- `task` type (always protected)

### SessionMaintenanceConfig

```
SessionMaintenanceConfig
  +-- mode: MaintenanceMode      (warn = dry-run, enforce = apply)
  +-- pruneAfterDays: int        (default: 30, 0 = disabled)
  +-- maxSessions: int           (default: 500, 0 = disabled)
  +-- maxDiskMb: int             (default: 0 = disabled)
  +-- cronRetentionHours: int    (default: 24, 0 = disabled)
  +-- schedule: String           (cron expression, default: "0 3 * * *")
```

### SessionResetService

Defined in `packages/dartclaw_server/lib/src/session/session_reset_service.dart`.
Manages daily and idle-timeout session resets.

**Daily reset** (configurable hour, default 4 AM):
- Iterates all `main`, `channel`, and `cron` sessions
- For keyed sessions with messages: convert to `archive`, create fresh replacement
- For keyed sessions without messages: mark as `archive` (key index treats as stale)

**Idle timeout** (opt-in, default 0 = disabled):
- Per-session timer started by `touchActivity(sessionId)`
- On timeout: reset session via the same archive-and-replace flow

**Per-session reset** (`resetSession(id)`):
- Keyed sessions: archive old, create fresh with same key + type
- User/unkeyed sessions: clear messages in place (no archive)

Implements `Reconfigurable` -- watches `sessions.*` config keys for live
updates to `resetHour` and `idleTimeoutMinutes`.


## 10. Thread Binding

Crowd coding feature. Defined in
`packages/dartclaw_core/lib/src/channel/thread_binding.dart`.
Related classes (`ThreadBindingRouter`, `ThreadBindingLifecycleManager`) live
alongside it in the same directory.

Thread bindings route messages from specific channel threads directly to task
sessions, bypassing the normal scope-based routing.

### ThreadBinding Model

```
ThreadBinding
  +-- channelType: String      (e.g., "googlechat")
  +-- threadId: String         (e.g., "spaces/AAAA/threads/CCCC")
  +-- taskId: String           (bound task ID)
  +-- sessionKey: String       (task session key)
  +-- createdAt: DateTime
  +-- lastActivity: DateTime
```

Compound key: `<channelType>::<threadId>` (via `ThreadBinding.key()`).

### ThreadBindingStore

In-memory `Map` backed by a JSON file. All lookups are synchronous (in-memory);
only writes touch the filesystem with atomic persistence.

| Method                | Behavior                                           |
|-----------------------|----------------------------------------------------|
| `load()`              | Parse JSON array from file on startup               |
| `create(binding)`     | Upsert + persist                                    |
| `lookupByThread()`    | Synchronous in-memory lookup                        |
| `lookupByTask()`      | Filter by `taskId`                                  |
| `updateLastActivity()`| Touch `lastActivity` + persist                      |
| `delete()`            | Remove by thread key + persist                      |
| `deleteByTaskId()`    | Remove all bindings for a task (best-effort persist) |
| `removeExpiredBindings()` | Prune by `lastActivity` cutoff                  |
| `reconcile(activeIds)`| Remove bindings for tasks not in the active set     |

File format: JSON array of serialized `ThreadBinding` objects, written atomically.

### Routing Integration

Thread binding lookup occurs before scope-based routing in the message pipeline
(see section 4). When a bound thread is found, the message bypasses `SessionKey`
computation and routes directly to the task's session.

Auto-unbind: when a task reaches a terminal state, `deleteByTaskId()` removes
all associated bindings.


## 11. Governance & Emergency Controls

### GovernanceConfig

Top-level governance configuration in `packages/dartclaw_config/lib/src/governance_config.dart`:

```
GovernanceConfig
  +-- adminSenders: List<String>     (empty = all are admins)
  +-- rateLimits: RateLimitsConfig
  |     +-- perSender: PerSenderRateLimitConfig
  |     |     +-- messages: int              (0 = disabled)
  |     |     +-- windowMinutes: int         (default: 5)
  |     |     +-- maxQueued: int             (0 = disabled)
  |     |     +-- maxPauseQueued: int        (0 = disabled)
  |     +-- global: GlobalRateLimitConfig
  |           +-- turns: int                 (0 = disabled)
  |           +-- windowMinutes: int         (default: 60)
  +-- budget: BudgetConfig
  |     +-- dailyTokens: int                 (0 = disabled)
  |     +-- action: BudgetAction             (warn | block)
  |     +-- timezone: String                 (default: "UTC")
  +-- loopDetection: LoopDetectionConfig
  |     +-- enabled: bool                    (default: false)
  |     +-- maxConsecutiveTurns: int         (0 = disabled)
  |     +-- maxTokensPerMinute: int          (0 = disabled)
  |     +-- velocityWindowMinutes: int       (default: 5)
  |     +-- maxConsecutiveIdenticalToolCalls: int (0 = disabled)
  |     +-- action: LoopAction               (abort | warn)
  +-- queueStrategy: QueueStrategy           (fifo | fair)
  +-- crowdCoding: CrowdCodingConfig
  +-- turnProgress: TurnProgressConfig
```

All features default to disabled for backward compatibility. When `adminSenders`
is empty, all senders are treated as admins (suitable for single-user deployments).

### TurnGovernanceEnforcer

Defined in `packages/dartclaw_server/lib/src/turn_governance_enforcer.dart`.
Orchestrates pre-turn and in-turn governance checks:

**Pre-turn checks** (called before `SessionLockManager.acquire()`):
1. `checkBudget()` -- consult `BudgetEnforcer` for daily token budget
2. `awaitRateLimitWindow()` -- defer if global rate limit reached
3. `checkLoopPreTurn()` -- turn chain depth + token velocity

**In-turn checks** (called during turn execution):
4. `recordToolCall()` -- tool fingerprint loop detection
5. `recordTokensAndCheckVelocity()` -- rolling token velocity

### SlidingWindowRateLimiter

In-memory sliding window rate limiter in
`packages/dartclaw_config/lib/src/sliding_window_rate_limiter.dart` (re-exported from the `dartclaw_core` barrel).

- Tracks events per key within a configurable time window
- `check(key)`: returns `true` if under limit (and records event), `false` if at limit
- Lazy eviction: expired entries removed on `check`/`currentCount`/`totalCount`
- `limit <= 0` means unlimited -- `check()` always returns `true`
- Used for both per-sender inbound rate limiting and global turn rate limiting

### LoopDetector

Three independent detection mechanisms in
`packages/dartclaw_config/lib/src/loop_detector.dart` (re-exported from the `dartclaw_core` barrel):

```
Mechanism 1: Turn Chain Depth
  Per-session consecutive autonomous turn count.
  Reset on human input. Triggers when depth > maxConsecutiveTurns.

Mechanism 2: Token Velocity
  Rolling window of (timestamp, tokens) per session.
  Triggers when tokens in window > maxTokensPerMinute * velocityWindowMinutes.

Mechanism 3: Tool Fingerprinting
  Per-turn consecutive identical tool calls.
  Canonical JSON fingerprint (sorted keys). Triggers when count >= threshold.
```

All state is in-memory -- resets on restart. Each mechanism independently
disableable by setting its threshold to 0.

Returns `LoopDetection` results (mechanism, sessionId, message, detail) --
callers decide the action (`LoopAction.abort` throws `LoopDetectedException`,
`LoopAction.warn` logs and continues).

### BudgetEnforcer

Defined in `packages/dartclaw_server/lib/src/governance/budget_enforcer.dart`.
Checks daily token consumption against the configured budget:

```
Under 80%         -> BudgetDecision.allow
At/above 80%      -> BudgetDecision.warn (once per day)
At/above 100%     -> BudgetDecision.block (if action=block)
                  -> BudgetDecision.warn  (if action=warn)
```

Timezone-aware via `BudgetConfig.timezone` (supports `UTC`, `UTC+N`, `UTC-N`).
Warning state is in-memory (resets on restart). Reads actual consumption from
`UsageTracker.dailySummaryForDate()`.

### Emergency Controls

**`/stop`** -- `EmergencyStopHandler` in
`packages/dartclaw_server/lib/src/emergency/emergency_stop_handler.dart`:

1. Cancel all active turns across all runners in the harness pool
2. Transition all `running` and `queued` tasks to `cancelled`
3. Fire `EmergencyStopEvent` on the EventBus
4. Broadcast `emergency_stop` SSE event

Best-effort: individual failures are logged but do not halt the stop sequence.
Admin-only command.

**`/pause`** and **`/resume`** -- `PauseController` in
`packages/dartclaw_server/lib/src/governance/pause_controller.dart`:

**Pause state**:
- `pause(adminName)`: set paused flag, record who/when
- While paused: `enqueue()` queues inbound messages per session key
  - Per-sender cap (`maxPauseQueued`) prevents queue flooding
  - Global cap (`maxQueueSize`, default 200) prevents memory exhaustion

**Resume and drain**:
- `drain()`: returns `Map<sessionKey, collapsedText>`, clears queue, unpauses
- Collapsed text format groups messages per sender within each session:
  ```
  While paused, 2 participants sent messages:
  - Alice: message1, message2
  - Bob: message3
  ```

All state is in-memory -- resets automatically on server restart (no persisted
pause state means a crash naturally "unpauses").


## 12. Crowd Coding State

Multi-user collaborative AI agent steering via channel Spaces.

### Governance Pipeline Ordering

For crowd coding scenarios, governance checks execute in a strict order before
message routing:

```
  Inbound Channel Message
       |
       v
  [1] Per-sender rate limit      (admin exempt)
       |
       v
  [2] Token budget check         (warn or block)
       |
       v
  [3] Loop detection check       (turn chain + velocity)
       |
       v
  [4] Pause check                (enqueue if paused)
       |
       v
  [5] Thread binding lookup      (bound thread -> task session)
       |
       v
  [6] Scope-based routing        (SessionKey computation)
```

### Sender Attribution

Tasks track `createdBy` (sender identity extracted from the channel message that
triggered task creation). This attribution flows through to the UI (task list,
Cards v2 responses) and is used for per-sender governance decisions.

### Per-Sender Message Queuing

During pause, the `PauseController` maintains per-sender message queuing:
- Messages are partitioned by session key for drain delivery
- Within each session, messages are grouped by sender display name
- Chronological first-appearance order is preserved for senders
- Admin senders bypass per-sender queue caps but not the global cap

### Queue Strategy

`QueueStrategy` enum controls drain behavior:
- `fifo` (default): preserve insertion order
- `fair`: round-robin across senders (future crowd coding enhancement)


## 13. Crash Recovery

DartClaw uses multiple mechanisms for crash resilience:

### NDJSON Cursor Recovery

The `messages.ndjson` file is append-only. The 1-based line number serves as
the cursor. On crash:

1. The NDJSON file is never truncated during normal operation -- only appended
2. Malformed trailing lines (partial write) are detected and skipped by
   `MessageService.getMessages()` (logged as warnings)
3. `getMessagesAfterCursor(sessionId, cursor)` resumes from the last known
   cursor position

### TurnStateStore

SQLite-backed store in `packages/dartclaw_storage/lib/src/storage/turn_state_store.dart`
that tracks active turns:

```sql
CREATE TABLE IF NOT EXISTS turn_state (
  session_id TEXT PRIMARY KEY,
  turn_id TEXT NOT NULL,
  started_at TEXT NOT NULL
)
```

| Method      | Behavior                                           |
|-------------|----------------------------------------------------|
| `set()`     | Upsert active turn for a session                   |
| `delete()`  | Remove turn record on completion                    |
| `getAll()`  | List all active turns (used on startup recovery)    |

**Recovery flow on restart**:
1. `TurnStateStore.getAll()` returns orphaned turn records
2. For each orphaned entry: clean the row (the process that was running is gone)
3. Surface a recovery notice (log or UI) indicating which sessions had
   interrupted turns

Uses WAL journal mode for crash safety.

The automated proof path is `packages/dartclaw_server/test/integration/crash_recovery_smoke_test.dart`. It exercises a real server restart boundary, not only the in-process `TurnManager` seam: start a turn, kill the process, restart with the same data directory, clean `TurnStateStore`, consume the one-time recovery notice, and render the `.msg-turn-failed` path.

### Atomic Writes

All JSON state files (`meta.json`, `.session_keys.json`, `thread-bindings.json`,
KvService) use atomic writes:

```dart
Future<void> atomicWriteJson(File target, Object json) async {
  final tempFile = File('${target.path}.tmp');
  await tempFile.writeAsString(jsonEncode(json));
  await tempFile.rename(target.path);  // atomic on POSIX
}
```

This prevents partial writes from corrupting state files on crash. The `rename`
operation is atomic on POSIX filesystems, so the file is either fully written
or contains the previous content.

### In-Memory State Reset

Several components use in-memory state that naturally resets on restart:
- `PauseController`: paused state, queued messages
- `LoopDetector`: turn chain depths, velocity windows, tool fingerprints
- `SlidingWindowRateLimiter`: event timestamps
- `BudgetEnforcer`: warning-posted flag (persisted daily summary survives restart)
- `SessionLockManager`: active locks

This is by design -- a crash naturally clears all transient governance state,
which is the safest default (no stale rate limits or phantom locks after restart).


---

## Cross-References

- [System Architecture](system-architecture.md) -- component map, 2-layer model, turn orchestration
- [Data Model & Persistence](data-model.md) -- session storage layout, `messages.ndjson`, `.session_keys.json`, entity relationships
- [Security Architecture](security-architecture.md) -- guard pipeline, governance rate limiting, emergency controls, access control
- [Control Protocol](control-protocol.md) -- JSONL protocol spec, stream events, harness pool
- [Workflow Architecture](workflow-architecture.md) -- workflow sessions, step execution, approval gates
- [Architecture Governance](architecture-governance.md) -- fitness functions, structural boundaries
- ADR-011 -- Event bus design rationale
- ADR-017 -- Multi-project architecture (project sessions, credential injection)

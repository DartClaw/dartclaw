# DartClaw Data Model & Persistence Overview

Canonical reference for DartClaw's persistence landscape. Covers all storage mechanisms, their relationships, and lifecycle behavior.

**Current through**: 0.16.5 (map/foreach `maxItems` is opt-in; omitted means uncapped)

---

## Architecture Principle

**Files are the source of truth. SQLite is a derived index or relational model.**

- Sessions, messages, memory, config → file-based (human-inspectable, portable)
- Search index → SQLite FTS5 (derived from MEMORY.md, rebuildable via `dartclaw rebuild-index`)
- Tasks, goals, artifacts, turn traces, task events → SQLite (authoritative — relational queries on status/type/goal)
- Projects → file-based JSON (atomic writes, human-inspectable)

Design rationale: [ADR-002 (File-Based Storage)](../adrs/002-file-based-storage.md)

**Diagram**: [Data Model (Excalidraw)](../diagrams/data-model.excalidraw) — entity relationships, storage zones, cross-store references | [View online](https://excalidraw.com/#json=TO3wyb40ar2YhjD0SITKx,onxECrwQG4vIdgKnPLeELQ)

---

## Storage Mechanisms

### Overview

```
~/.dartclaw/                          # dataDir (configurable)
├── dartclaw.yaml                     # [YAML]   Config (live + reloadable + restart-required fields)
├── kv.json                           # [JSON]   Global key-value store
├── search.db                         # [SQLite] FTS5 search index (REBUILDABLE)
├── tasks.db                          # [SQLite] Tasks + agent_executions + workflow_step_executions + goals + artifacts + turns + task_events + kg_facts (AUTHORITATIVE)
├── state.db                          # [SQLite] Active turn recovery state (TRANSIENT)
├── projects.json                     # [JSON]   Project registry (atomic writes)
├── audit-YYYY-MM-DD.ndjson           # [NDJSON] Guard audit log partitions with retention cleanup
├── usage.jsonl                       # [JSONL]  Token/cost tracking (append + rotate)
├── signal-sender-map.json            # [JSON]   Signal UUID↔phone mapping
├── google-chat-user-oauth.json       # [JSON]   Shared Google Chat user OAuth refresh token + client metadata (space events + reactions)
├── thread-bindings.json              # [JSON]   Channel thread/task bindings
├── sessions/
│   ├── .session_keys.json            # [JSON]   Deterministic key→UUID index
│   └── <uuid>/
│       ├── meta.json                 # [JSON]   Session metadata
│       └── messages.ndjson           # [NDJSON] Conversation transcript (append-only)
├── workspace/
│   ├── MEMORY.md                     # [MD]     Long-term memory (source of truth for search.db)
│   ├── errors.md                     # [MD]     Auto-populated error log (capped 50)
│   ├── learnings.md                  # [MD]     Agent-written insights (capped 50)
│   ├── memory/
│   │   └── YYYY-MM-DD.md            # [MD]     Daily turn logs
│   ├── SOUL.md                       # [MD]     Identity/values (read-only by runtime)
│   ├── USER.md                       # [MD]     User profile (read-only by runtime)
│   ├── TOOLS.md                      # [MD]     Env-specific notes (read-only by runtime)
│   ├── AGENTS.md                     # [MD]     Safety rules (read-only by runtime)
│   ├── HEARTBEAT.md                  # [MD]     Periodic task checklist (read-only by runtime)
│   └── .git/                         # [Git]    Workspace version control
├── worktrees/
│   └── <taskId>/                     #          Git worktree for coding tasks
├── projects/
│   └── <projectId>/                  # [Git]    Full git repository clone per project
└── logs/                             #          Application logs
```

### By Access Pattern

| Pattern | Files | Write Method | Concurrency |
|---------|-------|-------------|-------------|
| **Relational queries** | `search.db`, `tasks.db`, `state.db` | SQLite prepared statements | WAL (`tasks.db`, `state.db`), single-thread (`search.db`) |
| **Append-only logs** | `messages.ndjson`, `audit-YYYY-MM-DD.ndjson`, `usage.jsonl` | File append | Write queue (messages), fire-and-forget (audit, usage) |
| **Atomic documents** | `meta.json`, `.session_keys.json`, `kv.json`, `dartclaw.yaml`, `google-chat-user-oauth.json`, `thread-bindings.json`, `projects.json` | Temp file → rename | Write queue (kv, config), direct (meta, keys, bindings, OAuth store, projects) |
| **Structured text** | `MEMORY.md`, `errors.md`, `learnings.md`, daily logs | Temp file → rename or append | Write queue (memory, errors) |
| **Append-mostly SQLite** | `turns` (in `tasks.db`) | Async upsert, fire-and-forget | `TurnTraceService` (WAL) |
| **Append-only SQLite** | `task_events` (in `tasks.db`) | Synchronous insert | `TaskEventService` (WAL) |

---

## Domain Models

### Session

Sessions are the primary conversation container. File-based storage, one directory per session.

```
Session
├── id: String (UUID v4)
├── title: String?
├── type: SessionType {main, user, channel, cron, task, archive}
├── channelKey: String? (e.g., "agent:main:dm:contact:%40alice")
├── createdAt: DateTime
└── updatedAt: DateTime
```

**Storage**: `sessions/<id>/meta.json` (atomic full rewrite)
**Messages**: `sessions/<id>/messages.ndjson` (append-only, cursor = line number)
**Package**: `dartclaw_models` (model), `dartclaw_core` (service)

#### Session Key (Deterministic Routing)

```
SessionKey (factories)
├── webSession()                                    → agent:main:web:
├── dmShared()                                      → agent:main:dm:shared
├── dmPerContact(peerId)                            → agent:main:dm:contact:<encoded>
├── dmPerChannelContact(channelType, peerId)         → agent:main:dm:<channel>:<encoded>
├── groupShared(channelType, groupId)                → agent:main:group:<channel>:<encoded>
├── groupPerMember(channelType, groupId, peerId)     → agent:main:group:<channel>:<encoded>:<encoded>
├── cronSession(jobId)                              → agent:main:cron:<encoded>
└── taskSession(taskId)                             → agent:main:task:<encoded>
```

**Index**: `sessions/.session_keys.json` maps keys to session UUIDs. `getOrCreateByKey()` is idempotent.

#### Session Types & Protection

| Type | Created by | Protected from pruning | Protected from deletion |
|------|-----------|----------------------|------------------------|
| `main` | Startup | Yes | Yes |
| `user` | Web UI "new session" | No | No |
| `channel` | Channel message | Yes (when channel active) | No |
| `cron` | Scheduler | Yes (when job active) | Orphan cleanup after retention period |
| `task` | TaskExecutor | Yes | Yes (lifecycle via task API) |
| `archive` | Maintenance prune | No (eligible for disk budget cleanup) | No |

### Message

```
Message
├── cursor: int (1-based line number — crash recovery cursor)
├── id: String (UUID)
├── sessionId: String
├── role: String {user, assistant, system}
├── content: String
├── metadata: String? (JSON)
└── createdAt: DateTime
```

**Storage**: One JSON object per line in `messages.ndjson`. Cursor is assigned on read (line number), not stored.
**Package**: `dartclaw_models` (model), `dartclaw_core` (service)

### Task

Tasks are the structured work unit for the task orchestrator. SQLite-based.

```
Task
├── id: String (UUID)
├── title: String
├── description: String
├── type: TaskType {coding, research, writing, analysis, automation, custom}
├── status: TaskStatus (state machine — see below)
├── goalId: String? → Goal.id
├── projectId: String? → Project.id (file-based, not FK-enforced; null = implicit _local project)
├── agentExecutionId: String? → AgentExecution.id
├── acceptanceCriteria: String?
├── configJson: String (model override, token budget)
├── worktreeJson: String? (branch, path, baseRef)
├── createdAt: DateTime
├── startedAt: DateTime?
└── completedAt: DateTime?
```

**Storage**: `tasks.db` → `tasks` table (WAL mode, indexed on status+type)
**Package**: `dartclaw_models` (model), `dartclaw_storage` (repository), `dartclaw_server` (service)

Task JSON and API surfaces now expose nested `agentExecution` and `workflowStepExecution` objects when hydrated. The task row itself keeps only task-owned lifecycle and artifact fields; runtime provider/session/model state lives on `AgentExecution`, and workflow-only metadata lives on `WorkflowStepExecution`.

### AgentExecution

`AgentExecution` is the shared runtime primitive below both workflow steps and standalone tasks.

```text
AgentExecution
├── id: String (UUID)
├── sessionId: String? → Session.id (file-based, not FK-enforced)
├── provider: String?
├── model: String?
├── workspaceDir: String?
├── containerJson: String?
├── budgetTokens: int?
├── harnessMetaJson: String?
├── startedAt: DateTime?
└── completedAt: DateTime?
```

**Storage**: `tasks.db` → `agent_executions` table (indexed on `session_id`)
**Relationships**: `tasks.agent_execution_id` references `agent_executions.id`; `workflow_step_executions.agent_execution_id` also references `agent_executions.id`

### WorkflowStepExecution

Workflow-owned execution metadata moved out of `Task.configJson` into a dedicated table keyed by task.

```text
WorkflowStepExecution
├── taskId: String → Task.id
├── agentExecutionId: String → AgentExecution.id
├── workflowRunId: String
├── stepIndex: int
├── stepId: String
├── stepType: String
├── gitJson: String?
├── providerSessionId: String?
├── structuredSchemaJson: String?
├── structuredOutputJson: String?
├── followUpPromptsJson: String?
├── externalArtifactMountJson: String?
├── mapIterationIndex: int?
├── mapIterationTotal: int?
└── stepTokenBreakdownJson: String?
```

**Storage**: `tasks.db` → `workflow_step_executions` table (indexed on `(workflow_run_id, step_index)`)
**Relationships**: `task_id` is `ON DELETE CASCADE` to `tasks.id`; `agent_execution_id` references `agent_executions.id`

#### TaskOrigin (channel-originated tasks)

When a task is created via a channel message trigger, the originating channel context is stored in `task.configJson['origin']` as a JSON object:

```
TaskOrigin
├── channelType: String          # 'whatsapp' | 'signal' | 'googlechat'  (ChannelType.name enum value)
├── sessionKey: String           # Deterministic session key for the originating contact
├── contactId: String            # Channel-specific contact identifier
├── recipientId: String          # Concrete sendMessage() target (JID for WA, UUID for Signal, spaceName for GChat)
├── sourceMessageId: String?     # Original message ID (for reply correlation, e.g. GChat typing placeholder)
├── senderDisplayName: String?   # Human-readable sender name from channel metadata
├── senderId: String?            # Stable sender identifier retained explicitly for attribution
└── senderAvatarUrl: String?     # Channel avatar URL when available (currently Google Chat)
```
Note: short IDs (6-char hex prefix of the task UUID) are computed at display time from the task `id` field; they are **not** persisted in `TaskOrigin`.

Tasks with `TaskOrigin` receive channel status notifications via `TaskNotificationSubscriber`. Tasks without `TaskOrigin` (web/API-created) receive no channel notifications. The `recipientId` is the concrete target for `Channel.sendMessage()` calls — it differs per channel type and must be extracted from the inbound message context at task creation time.

**Per-group project binding**: When a task is created from a group channel message, `ChannelTaskBridge` looks up the `GroupEntry.project` from `GroupConfigResolver` using the message's `groupJid`. If a project is configured, it is passed as `projectId` to `TaskCreator` and stored in `Task.projectId`. Groups without a `project` field fall back to the default project (null).

#### Sender Attribution

Tasks carry sender identity for audit provenance:

- `Task.createdBy`: Stores the sender display name when available, otherwise the sender JID/ID of the user who triggered the task. Set at creation time and never modified.
- `TaskOrigin`: Persists both routing context (`channelType`, `sessionKey`, `recipientId`, `contactId`, `sourceMessageId`) and attribution fields (`senderDisplayName`, `senderId`, `senderAvatarUrl`) for channel-originated tasks.
- This keeps provenance renderable even after the originating message is gone: task cards can show "Requested by", task detail views can display sender context, and audits can distinguish contact routing identifiers from human-friendly names.

#### Task State Machine

```
                    ┌──────────────────────────────────┐
                    │                                  │
  draft ──→ queued ──→ running ──→ review ──→ accepted │
    │         │         │    │       │                  │
    │         │         │    │       ├──→ rejected      │
    │         │         │    │       │                  │
    │         │         │    │       └──→ queued        │
    │         │         │    │           (push-back)    │
    │         │         │    │                          │
    │         │         │    └──→ interrupted ──→ queued│
    │         │         │                              │
    └─────────┴─────────┴──→ cancelled                 │
                        │                              │
                        └──→ failed                    │
                                                       │
  Terminal states: accepted, rejected, cancelled, failed│
                    └──────────────────────────────────┘
```

Valid transitions:
- `draft` → `queued`, `cancelled`
- `queued` → `running`, `cancelled`
- `running` → `review`, `failed`, `cancelled`, `interrupted`
- `interrupted` → `queued`, `cancelled`
- `review` → `accepted`, `rejected`, `queued` (push-back), `cancelled`

### Task Artifact

```
TaskArtifact
├── id: String (UUID)
├── taskId: String → Task.id (FK, CASCADE DELETE)
├── name: String
├── kind: ArtifactKind {diff, document, data, log}
├── path: String (relative to dataDir/tasks/<taskId>/artifacts/)
└── createdAt: DateTime
```

**Storage**: `tasks.db` → `task_artifacts` table (FK cascade on task delete)

Merge conflicts are persisted as a data artifact named `conflict.json` with the shape:

```json
{
  "conflictingFiles": ["lib/main.dart", "lib/utils.dart"],
  "details": "Automatic merge failed"
}
```

Use `ArtifactKind.data` for this artifact. The file lives under `tasks/<taskId>/artifacts/conflict.json`.

### Goal

```
Goal
├── id: String (UUID)
├── title: String
├── parentGoalId: String? → Goal.id (max 2 levels)
├── mission: String
└── createdAt: DateTime
```

**Storage**: `tasks.db` → `goals` table

### Memory Chunk (Search Index)

```
MemoryChunk
├── id: int (autoincrement)
├── text: String
├── source: String (e.g., "MEMORY.md", "2026-03-12.md")
├── category: String?
├── createdAt: DateTime
└── userId: String (default: "owner")
```

**Storage**: `search.db` → `memory_chunks` + `memory_chunks_fts` (FTS5 virtual table)
**Source of truth**: `workspace/MEMORY.md` + `workspace/memory/*.md` files
**Rebuild**: `dartclaw rebuild-index` deletes and repopulates from source files

### Thread Binding

Thread bindings map channel conversations to DartClaw task sessions so replies continue in the task session instead of the default shared or scoped session. Routing precedence lives in [System Architecture](system-architecture.md); security implications live in [Security Architecture](security-architecture.md).

```
ThreadBinding
├── channelType: String       (e.g. "googlechat", "whatsapp", "signal")
├── threadId: String          (Google Chat thread resource name or group identifier)
├── taskId: String             → Task.id
├── sessionKey: String         (encoded session key for message routing)
├── createdAt: DateTime
└── lastActivity: DateTime     (updated on each routed message)
```

**Storage**: `thread-bindings.json` — JSON array of binding objects, atomic writes (temp file + rename)
**Lookup key**: `"<channelType>::<threadId>"` — compound in-memory key
**Package**: `dartclaw_core` (model + store)

**Lifecycle**:
- Created automatically when a task with a Google Chat `TaskOrigin` transitions to `running` and `TaskNotificationSubscriber` receives the server-assigned `thread.name` from the initial threaded notification
- Additional bindings can be created explicitly through `/bind <taskId>` or the task binding API, so multiple channels can point at the same task session simultaneously
- `lastActivity` is updated with a fire-and-forget persist on each routed message so the binding reflects recent use without blocking inbound routing
- `ThreadBindingLifecycleManager` auto-unbinds terminal tasks (`accepted`, `rejected`, `cancelled`, `failed`) from the event bus and also runs idle-timeout cleanup (default: 1 hour idle, swept every 5 minutes)
- Startup reconciliation via `ThreadBindingStore.reconcile(activeTaskIds)` prunes stale entries left behind by restarts or write failures before new traffic is accepted

`ThreadBindingStore` maintains an in-memory `Map` backed by the JSON file. All lookups are synchronous (in-memory); only writes touch the filesystem. If the file is missing or contains invalid JSON on load, the store starts empty without error.

### Channel Runtime DTOs (Ephemeral)

These objects are not persisted as standalone records, but they carry channel-specific routing and reply state through the in-memory channel pipeline.

```
ChannelMessage
├── id: String
├── senderJid: String
├── groupJid: String?
├── text: String
├── timestamp: DateTime
└── metadata: Map<String, dynamic>
```

Important Google Chat metadata keys:
- `messageName` — canonical Chat message resource name (`spaces/.../messages/...`)
- `messageCreateTime` — RFC 3339 timestamp copied from the inbound Chat message resource
- `threadName` — Chat thread resource name for thread binding and routing
- `spaceType` — inbound Chat space type (`DM`, `GROUP_CHAT`, `SPACE`); used to gate quoting before `quotedMessageMetadata` is built
- `senderDisplayName` — human-readable sender name used for text-level attribution and sender attribution decisions when quoting is unavailable

```
ChannelResponse
├── text: String
├── mediaAttachments: List<String>
├── metadata: Map<String, dynamic>
├── replyToMessageId: String?
└── structuredPayload: Map<String, dynamic>?
```

- `replyToMessageId` is the explicit outbound reply target carried through `MessageQueue`
- Google Chat uses `replyToMessageId` together with `metadata['messageCreateTime']` to populate `quotedMessageMetadata` when the space type supports quoting
- `metadata['sourceMessageId']` remains the queue-level link back to the originating inbound message for placeholder cleanup and other adapter bookkeeping

`FeedbackContext` is another ephemeral runtime object used only while a channel turn is in flight. It holds the target `Channel`, recipient ID, inbound message ID, and any active placeholder message ID so a feedback strategy can patch or clear in-progress UI affordances without persisting extra state.

### Governance State

Runtime governance uses a mix of in-memory and persisted state:

| State | Storage | Durability | Reset |
|-------|---------|------------|-------|
| Per-sender rate limit counters | In-memory (`SlidingWindowRateLimiter`) | Transient | Server restart |
| Global turn rate limit counters | In-memory (`SlidingWindowRateLimiter`) | Transient | Server restart |
| Daily token budget totals | Persisted via `UsageTracker` in KvService (`kv.json`) | Durable | Midnight in configured timezone (new date key) |
| Budget warning flag | Persisted in daily summary (`budget_warning_posted_at`) | Durable | New day |
| Loop detection turn chain depth | In-memory (`LoopDetector._turnChainDepth`) | Transient | Server restart or human message |
| Loop detection token velocity | In-memory (`LoopDetector._tokenVelocityWindow`) | Transient | Server restart |
| Loop detection tool fingerprints | In-memory (`LoopDetector._consecutiveToolCalls`) | Transient | Turn completion |
| Active turn stall timers | In-memory (`TurnProgressMonitor` per active turn) | Transient | Turn completion or server restart |
| Pause state + message queue | In-memory (`PauseController`) | Transient | Server restart |

**Design rationale**: Rate limit and loop detection state is intentionally in-memory. A server restart naturally resets these counters, which is acceptable because restarts already interrupt all active processing. Budget state uses the existing `UsageTracker` daily aggregation pipeline via KvService, avoiding any new persistence mechanism.

**Governance configuration** is stored in the `governance:` section of `dartclaw.yaml`. Governance-adjacent runtime services can subscribe through `ConfigNotifier` and `Reconfigurable`, so changed values are written to YAML and picked up by the next turn or evaluation cycle without a full process restart. The counters themselves remain intentionally in-memory and transient.

### Runtime Events and Config

EventBus-only runtime event models plus two persisted config sections:

```text
CompactionStartingEvent
├── sessionId: String
├── trigger: String                  # auto | manual
└── timestamp: DateTime

CompactionCompletedEvent
├── sessionId: String
├── trigger: String
├── preTokens: int?
├── summary: String?                 # reserved; currently always null
└── timestamp: DateTime

ScheduledJobFailedEvent
├── jobId: String
├── jobName: String
├── error: String
└── timestamp: DateTime

ToolPermissionDeniedEvent
├── toolName: String
├── sessionId: String?
├── reason: String?
└── timestamp: DateTime

ReloadConfig                                 # nested under gateway.reload
├── mode: String                             # off | signal | auto
└── debounceMs: int

AlertsConfig                                 # top-level alerts:
├── enabled: bool
├── cooldownSeconds: int
├── burstThreshold: int
├── targets: List<AlertTarget>
└── routes: Map<String, List<String>>
```

- `CompactionStartingEvent`, `CompactionCompletedEvent`, `ScheduledJobFailedEvent`, and `ToolPermissionDeniedEvent` are runtime notifications only; they are not persisted directly
- `CompactionCompletedEvent` can cause a persisted `TaskEventKind.compaction` row when the compacted session belongs to an active running task
- `ReloadConfig` and `AlertsConfig` live in `dartclaw.yaml` and participate in hot-reload via `ConfigNotifier`

### Advisor Events and Config

The advisor observer has three runtime-facing concepts:

```text
AdvisorConfig
├── enabled: bool
├── model: String?
├── effort: String?
├── triggers: List<String>
├── periodicIntervalMinutes: int
├── maxWindowTurns: int
└── maxPriorReflections: int
```

- `AdvisorConfig` lives in the top-level `advisor:` section of `dartclaw.yaml`
- `AdvisorMentionEvent` captures explicit `@advisor` invocations from channel traffic
- `AdvisorInsightEvent` carries structured advisor output (`status`, `observation`, `suggestion`, `triggerType`, `taskIds`, `sessionKey`) for downstream consumers
- The advisor context window and prior reflections are intentionally in-memory only and reset on restart

### Project

Projects represent external git repositories managed by DartClaw.

```
Project
├── id: String (UUID)
├── name: String
├── remoteUrl: String?              (null for implicit _local project)
├── localPath: String               (absolute path to clone under <dataDir>/projects/<id>/)
├── defaultBranch: String           (default: "main")
├── credentialsRef: String?         (reference name in credential store; never the key itself)
├── cloneStrategy: CloneStrategy    {shallow, full}
├── prStrategy: PrStrategy          {branch, pr}
├── status: ProjectStatus           {cloning, ready, error, stale}
├── lastFetchAt: DateTime?
├── source: ProjectSource           {config, runtime}
└── createdAt: DateTime
```

**Status lifecycle**:
- `cloning` → `ready` (on successful clone), `cloning` → `error` (on failure)
- `ready` → `stale` (fetch age exceeds threshold); `stale` resolved on next successful fetch

**Storage**: `<dataDir>/projects.json` — JSON array of project objects, atomic writes (temp file + rename).
**Clones**: `<dataDir>/projects/<projectId>/` — full or shallow git repositories.
**Implicit `_local` project**: Synthesized from `Directory.current.path` at startup; not persisted in `projects.json`.
**Package**: `dartclaw_models` (model), `dartclaw_core` (service interface), `dartclaw_server` (implementation)

### Turn Trace

Turn traces are an enriched record of each agent turn for analytics and observability.

```
TurnTrace (turns table)
├── id: String (UUID)
├── session_id: String
├── task_id: String?                (null for interactive turns)
├── runner_id: String               (harness runner index)
├── model: String
├── provider: String
├── started_at: DateTime
├── ended_at: DateTime?
├── input_tokens: int
├── output_tokens: int
├── cache_read_tokens: int
├── cache_write_tokens: int
├── is_error: bool
├── error_type: String?
└── tool_calls: String              (JSON array of ToolCallRecord)
```

**Storage**: `tasks.db` → `turns` table (WAL mode; indexed on `session_id`, `task_id`, `started_at`)
**Write pattern**: Async fire-and-forget — same as `usage.jsonl`. Zero latency impact on the turn lifecycle. Traces survive entity deletion (no foreign keys).
**Package**: `dartclaw_models` (`ToolCallRecord`), `dartclaw_storage` (`TurnTraceService`)

**Multi-service co-location note**: `tasks.db` contains eight tables (`tasks`, `agent_executions`, `workflow_step_executions`, `task_artifacts`, `turns`, `task_events`, `goals`, and `kg_facts` plus its `kg_facts_lookup` index) managed by cooperating services (`SqliteTaskRepository`, `SqliteAgentExecutionRepository`, `SqliteWorkflowStepExecutionRepository`, `TurnTraceService`, `TaskEventService`, `SqliteGoalRepository`, `TemporalKnowledgeGraphService`). Each service uses idempotent bootstrap DDL; destructive migrations require explicit coordination across those services because task-owned runtime columns can move into the shared execution tables.

### Task Event

Task events are a structured timeline of observable happenings during a task's lifecycle.

```
TaskEvent (task_events table)
├── id: String (UUID)
├── task_id: String
├── timestamp: DateTime
├── kind: TaskEventKind             (see sealed enum below)
└── details: String                 (JSON object — schema varies by kind)
```

**Event kinds** (`TaskEventKind` sealed enum):
| Kind | details fields | Description |
|------|---------------|-------------|
| `statusChanged` | `oldStatus`, `newStatus` | Task state machine transition |
| `toolCalled` | `name`, `success`, `durationMs?`, `errorType?` | Agent tool invocation |
| `artifactCreated` | `name`, `kind` | New artifact collected |
| `pushBack` | `comment` | Reviewer sent push-back with comment |
| `tokenUpdate` | `inputTokens`, `outputTokens`, `cacheReadTokens?` | Token usage snapshot |
| `compaction` | `trigger`, `sessionId`, `preTokens?` | Provider compacted the task session context |
| `error` | `message` | Task-level error |

**Storage**: `tasks.db` → `task_events` table (WAL mode; indexed on `task_id`, `(task_id, kind)`, `timestamp`)
**Write pattern**: Synchronous — no event loss on crash. Opposite design choice from turn traces (fire-and-forget) because task events are operational data, not analytical.
**Retention**: No retention policy — unbounded growth; cleanup deferred to a later milestone.
**Package**: `dartclaw_models` (`TaskEvent`, `TaskEventKind`), `dartclaw_storage` (`TaskEventService`), `dartclaw_server` (`TaskEventRecorder`)

### Workflow Models

Workflow engine domain models.

```
WorkflowDefinition
├── name: String
├── description: String
├── variables: Map<String, WorkflowVariable>
│   └── WorkflowVariable
│       ├── required: bool (default true)
│       ├── description: String
│       └── defaultValue: String?
├── steps: List<WorkflowStep>
├── loops: List<WorkflowLoop>
├── maxTokens: int?
└── stepDefaults: List<StepConfigDefault>?   # glob-matched config defaults

WorkflowStep
├── id: String
├── name: String
├── prompts: List<String>                    # multi-prompt (list of turns)
├── type: String                             {research, analysis, coding, writing, bash, approval}
├── project: String?
├── provider: String?
├── model: String?
├── timeoutSeconds: int?
├── review: StepReviewMode                   {always, codingOnly, never}
├── parallel: bool
├── gate: String?                            # step-id.key operator value expression
├── inputs: List<String>
├── extraction: ExtractionConfig?
├── outputs: Map<String, OutputConfig>?      # canonical context-write declarations; keys exposed as outputKeys
├── evaluator: bool                          # minimal prompt scope for reviewer steps
├── maxTokens: int?
├── maxCostUsd: double?
├── maxRetries: int?
├── allowedTools: List<String>?
├── skill: String?                           # Agent Skills skill name
├── mapOver: String?                         # context key naming a JSON array
├── maxParallel: Object?                     # int, "unlimited", or template string
├── maxItems: int?                           # optional collection-size ceiling; null = uncapped
├── continueSession: bool                    # reuse the preceding agent step's resolved root session
├── onError: String?                         # failure policy (`pause`, `continue`, provider-specific future values)
└── workdir: String?                         # explicit working directory for bash steps

OutputConfig
├── format: OutputFormat                     {text, json, lines}
├── schema: Object?                          # String (preset name) or Map (inline JSON Schema)
└── source: String?                          # explicit output source (`worktree.branch`, `worktree.path`)

StepConfigDefault                            # entry in stepDefaults list
├── match: String                            # glob pattern matched against step IDs
├── provider: String?
├── model: String?
├── maxTokens: int?
├── maxCostUsd: double?
├── maxRetries: int?
└── allowedTools: List<String>?

WorkflowLoop
├── id: String
├── steps: List<String>                      # step IDs that repeat
├── maxIterations: int                       # hard cap
├── exitGate: String                         # early-exit condition expression
└── finally_: String?                        # step ID run once after loop exits

MapContext                                   # per-iteration state for map steps
├── item: Object                             # current element (Map, String, int, etc.)
├── index: int                               # 0-based iteration index
└── length: int                              # total collection size

WorkflowSummary                              # discovery projection, not persisted
├── name: String
├── description: String
├── stepCount: int
├── hasLoops: bool
├── maxTokens: int?
└── variables: Map<String, WorkflowVariable>
```

**Workflow lifecycle events** (`dartclaw_core` → `WorkflowLifecycleEvent`):

| Event class | Key fields | Fired when |
|-------------|-----------|-----------|
| `MapIterationCompletedEvent` | `runId`, `stepId`, `iterationIndex`, `totalIterations`, `itemId?`, `taskId`, `success`, `tokenCount` | A single map/fan-out iteration settles (success or failure) |
| `MapStepCompletedEvent` | `runId`, `stepId`, `stepName`, `totalIterations`, `successCount`, `failureCount`, `cancelledCount`, `totalTokens` | All iterations of a map step have settled |

**Storage**: Workflow definitions are YAML files parsed at runtime (not persisted to DB). Shipped workflow YAML files live in the asset tree and are materialized into `<workspaceDir>/workflows/` on startup as `WorkflowSource.materialized`, so the registry can load them from the filesystem without embedding prompt-bearing definitions. In source checkouts, the canonical YAML files remain under `packages/dartclaw_workflow/lib/src/workflow/definitions/` for editing and dev runs. Built-in `dartclaw-*` skills are also filesystem assets, discovered via the asset root and materialized to harness-visible skill directories with `.dartclaw-managed` provenance markers. Workflow execution state is persisted in two layers: lightweight context/status snapshots live on `WorkflowRun.contextJson` in SQLite, while the fuller `WorkflowContext` JSON is written under the workflow data directory and reloaded for resume/recovery paths.

**Discovery contract**: listing surfaces do not materialize full prompt-bearing definitions. `WorkflowDefinitionSource.listSummaries()` projects `WorkflowSummary` records for browsers and pickers, while detail/execution paths fetch the full `WorkflowDefinition` by name. This keeps discovery payloads small while preserving a single definition source of truth.

**Worktree bridge**: `OutputConfig.source` lets downstream workflow steps read persisted coding-task metadata directly (`worktree.branch`, `worktree.path`) instead of requiring the agent to restate those values in context text. This is the durable seam that connects workflow execution to task/worktree persistence.

**Package**: `dartclaw_models` (`WorkflowDefinition`, `WorkflowStep`, `WorkflowLoop`, `WorkflowVariable`, `OutputConfig`, `OutputFormat`, `StepConfigDefault`), `dartclaw_core` (`MapContext`, `WorkflowContext`, parser, validator, template engine, schema presets)

---

## Relationships

### Entity Relationship Diagram

```
┌──────────────┐
│   Project    │
│ (projects.json)│
└──────┬───────┘
       │ project_id (optional, not FK)
       │
                           ┌─────────────┐
                           │    Goal      │
                           │  (tasks.db)  │
                           └──────┬───────┘
                                  │ goal_id (optional)
                                  │
┌─────────────┐  session_id  ┌────┴────────┐  task_id   ┌──────────────┐
│   Session   │◄─ ─ ─ ─ ─ ─ ┤    Task     ├───────────►│ TaskArtifact │
│  (files)    │  (by ID,     │  (tasks.db) │  (FK,      │  (tasks.db)  │
└──────┬──────┘   not FK)    └──────┬──────┘  CASCADE)  └──────────────┘
       │                            │
       │ contains                   ├── task_id ──►┌──────────────┐
       │                            │              │  TurnTrace   │
┌──────┴──────┐                     │              │  (tasks.db)  │
│   Message   │                     │              └──────────────┘
│  (NDJSON)   │                     │
└─────────────┘                     └── task_id ──►┌──────────────┐
                                                   │  TaskEvent   │
                                                   │  (tasks.db)  │
                                                   └──────────────┘

┌─────────────┐  derived from  ┌──────────────────┐
│ MEMORY.md   │───────────────►│ MemoryChunk (FTS5)│
│ daily logs  │  (rebuildable) │   (search.db)     │
└─────────────┘                └──────────────────┘
```

### Cross-Store References

| From | To | Mechanism | Enforced? |
|------|----|-----------|-----------|
| `Task.sessionId` | `Session.id` | String ID reference | **No** — convention-based protection (SessionType.task excluded from pruning) |
| `Task.goalId` | `Goal.id` | String ID in same DB | **No** — no FK constraint (goal deletion doesn't cascade to tasks) |
| `Task.projectId` | `projects.json` | String ID reference | **No** — cross-store (SQLite → file) |
| `TaskArtifact.taskId` | `Task.id` | Foreign key | **Yes** — `ON DELETE CASCADE` |
| `TurnTrace.task_id` | `Task.id` | String ID reference | **No** — traces survive task deletion |
| `TaskEvent.task_id` | `Task.id` | String ID reference | **No** — events survive task deletion |
| `MemoryChunk` | `MEMORY.md` | Source → derived index | **Rebuild** — `dartclaw rebuild-index` |
| `ThreadBinding.taskId` | `Task.id` | String ID reference | **No** — reconciled on startup (stale bindings pruned) |

### Lifecycle Dependencies

| Event | Cascade Behavior |
|-------|-----------------|
| **Session deleted** | Directory deleted (messages go with it). If referenced by a task, task's `sessionId` becomes dangling. |
| **Task deleted** | Artifacts cascade-deleted via FK. Session is NOT deleted (must be cleaned separately). |
| **Task accepted/rejected** | Worktree cleaned up (branch + directory). Session preserved for audit trail. |
| **Goal deleted** | Tasks referencing the goal retain `goalId` but goal lookup returns null. |
| **Session archived** | Type changes to `archive`. Messages preserved. Task sessions are protected from automated archival. |
| **Task cancelled/accepted/rejected** | Thread binding deleted (if any). Worktree cleaned up. Session preserved for audit trail. |
| **Memory pruned** | Entries >90d archived. Search index out of sync until next `rebuild-index`. |
| **Server restart** | In-memory governance state reset (rate limit counters, loop detection, pause queue). Persisted budget totals preserved in KvService. Thread bindings reloaded from file and reconciled against active tasks. |

---

## Package Ownership

```
dartclaw_models     (zero deps)         Session, Message, MemoryChunk, SessionKey,
                                        Task*, Goal*, Project,
                                        ToolCallRecord, TaskEvent, TaskEventKind
     ▲
     │
dartclaw_core       (no sqlite3)        SessionService, MessageService, KvService,
     ▲                                  MemoryFileService, parsed config models,
     │                                  EventBus, GovernanceConfig, LoopDetector,
     │                                  SlidingWindowRateLimiter, ThreadBindingStore,
     │                                  ProjectService (interface),
     │                                  AgentExecution, WorkflowStepExecution,
     │                                  HarnessFactory, harness interfaces
     │
dartclaw_storage    (sqlite3)           SqliteTaskRepository, SqliteGoalRepository,
     ▲                                  SqliteAgentExecutionRepository,
     │                                  SqliteWorkflowStepExecutionRepository,
     │                                  SqliteWorkflowRunRepository,
     │                                  MemoryService (FTS5), SearchDb, TaskDb,
     │                                  TurnStateStore, TurnTraceService,
     │                                  TaskEventService
     │
dartclaw_security   (security)          GuardAuditLogger, GuardChain, MessageRedactor
     ▲
     │
dartclaw_config     (yaml_edit)         ConfigWriter, ConfigValidator, ConfigMeta
     ▲
     │
dartclaw_workflow   (core + storage)    WorkflowRegistry, workflow parser/validator,
     ▲                                  workflow execution engine, skill registry,
     │                                  schema presets, built-in skills
     │
dartclaw_server     (shelf, http)       TaskService (wraps repository),
     ▲                                  TaskExecutor, WorktreeManager, DiffGenerator,
     │                                  ProjectService (implementation), TaskEventRecorder,
     │                                  BudgetEnforcer, PauseController, ScopeReconciler,
     │                                  EmergencyStopHandler
     │
dartclaw_cli        (args)              CLI runner, loopback API client, connected
                                        operations (`workflow`, `tasks`, `config`,
                                        `projects`, `sessions`, `agents`, `traces`,
                                        `jobs`), plus local lifecycle/maintenance
                                        commands
```

*Task and Goal models may live in `dartclaw_models` or `dartclaw_core` depending on current package structure.

Design rationale: [ADR-008 (SDK Publishing)](../adrs/008-sdk-publishing-strategy.md), [ADR-010 (Models Split)](../adrs/010-package-split-models.md), [ADR-014 (SDK Decomposition)](../adrs/014-sdk-package-decomposition.md)

---

## Write Safety

### Atomic Write Pattern

All mutable JSON/YAML files use temp-file + rename:

```
write(target, data):
  1. Write to target.tmp
  2. Rename target.tmp → target  (atomic on POSIX)
```

If the process crashes mid-write, the temp file is orphaned but the original remains intact.

### Write Queue Pattern

Services with concurrent callers serialize writes via `StreamController`:

| Service | Queue Type | Purpose |
|---------|-----------|---------|
| `MessageService` | `StreamController` | Prevent concurrent NDJSON appends |
| `KvService` | `StreamController<_WriteOp>` | Prevent concurrent kv.json rewrites |
| `MemoryFileService` | `StreamController<_WriteOp>` | Prevent concurrent MEMORY.md rewrites |
| `ConfigWriter` | `StreamController<_WriteOp>` | Prevent concurrent YAML rewrites |
| `SelfImprovementService` | (via MemoryFileService) | Shared queue for errors.md/learnings.md |

### Fire-and-Forget Pattern

Append-only logs that must not block the caller:

| Service | File | Failure Mode |
|---------|------|-------------|
| `GuardAuditLogger` | `audit-YYYY-MM-DD.ndjson` | Log error, don't throw — guard verdict must not be delayed by I/O |
| `UsageTracker` | `usage.jsonl` | Log error, don't throw — turn must not fail because of metering |

---

## Rotation & Maintenance

| File | Rotation Strategy | Trigger |
|------|-------------------|---------|
| `audit-YYYY-MM-DD.ndjson` | Delete partitions older than `guard_audit.max_retention_days` (default: 30) | Session-maintenance job |
| `usage.jsonl` | Rename to `.1` when >10MB | On write |
| `errors.md` | Keep newest N entries (default: 50) | On write |
| `learnings.md` | Keep newest N entries (default: 50) | On write |
| `MEMORY.md` | Pruner archives entries >90d, deduplicates | Nightly cron (`MemoryPruner`) |
| Sessions | Archive after N days idle, count/disk budget | Scheduled (`SessionMaintenanceService`) |
| `search.db` | Full rebuild from source files | Manual (`dartclaw rebuild-index`) |

---

## Backup & Recovery

### Backup

All state lives under `dataDir` (default `~/.dartclaw/`). A filesystem-level backup captures everything:

```bash
# Simple backup (sufficient for single-user)
tar czf dartclaw-backup-$(date +%Y%m%d).tar.gz ~/.dartclaw/
```

For consistent SQLite snapshots, flush WAL first:
```bash
sqlite3 ~/.dartclaw/tasks.db "PRAGMA wal_checkpoint(TRUNCATE);"
```

`search.db` does not need WAL flush (no WAL mode) and is rebuildable anyway.

### Recovery

| Scenario | Recovery |
|----------|---------|
| `search.db` corrupted/deleted | `dartclaw rebuild-index` — rebuilt from MEMORY.md + daily logs |
| `tasks.db` corrupted/deleted | **Data loss** — tasks are authoritative. Restore from backup. |
| `state.db` corrupted/deleted | Loss of active-turn crash recovery only. In-flight sessions may miss a recovery banner, but durable message/task data remains intact. |
| Session directory deleted | Session metadata and messages lost. If referenced by a task, task has dangling `sessionId`. |
| `dartclaw.yaml` corrupted | Restore from `dartclaw.yaml.bak` (created on every config write) |
| `kv.json` corrupted | Loss of daily usage aggregates and Signal sender map. Recoverable from `usage.jsonl` re-aggregation. |
| `MEMORY.md` deleted | Long-term memory lost. Daily logs (`memory/`) may partially reconstruct. |

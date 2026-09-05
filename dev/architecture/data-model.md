# DartClaw Data Model & Persistence Overview

Canonical reference for DartClaw's persistence landscape. Covers all storage mechanisms, their relationships, and lifecycle behavior.

**Current through**: 0.25 kernel formation and storage absorption.

---

## Architecture Principle

**Files are the source of truth. SQLite is a derived index or relational model.**

- Sessions, messages, memory, config → file-based (human-inspectable, portable)
- Search index → SQLite FTS5 (derived from validated searchable canonical roles, rebuildable via `dartclaw rebuild-index`)
- Tasks, goals, artifacts, turn traces, task events → SQLite (authoritative — relational queries on status/type/goal)
- Projects → file-based JSON (atomic writes, human-inspectable)

Design rationale: [ADR-002 (File-Based Storage)](../adrs/002-file-based-storage.md)

**Diagram**: Data Model (Excalidraw) — entity relationships, storage zones, cross-store references (source in private repo: `docs/diagrams/data-model.excalidraw`) | [View online](https://excalidraw.com/#json=TO3wyb40ar2YhjD0SITKx,onxECrwQG4vIdgKnPLeELQ)

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
├── channels/signal/
│   └── signal-sender-map.json        # [JSON]   Signal UUID↔phone mapping
├── google-chat-user-oauth.json       # [JSON]   Shared Google Chat user OAuth refresh token + client metadata (space events + reactions)
├── thread-bindings.json              # [JSON]   Channel thread/task bindings
├── sessions/
│   ├── .session_keys.json            # [JSON]   Deterministic key→UUID index
│   └── <uuid>/
│       ├── meta.json                 # [JSON]   Session metadata
│       └── messages.ndjson           # [NDJSON] Conversation transcript (append-only)
├── workspace/
│   ├── MEMORY.md                     # [MD]     Bounded canonical index
│   ├── memory/topics/                # [MD]     Canonical topic documents
│   ├── MEMORY.archive.md             # [MD]     Canonical archive
│   ├── MEMORY.audit.md               # [MD]     Content-free deletion audit (never indexed)
│   ├── .dartclaw-memory-corpus.json   # [JSON]   Derived authenticated member manifest
│   ├── errors.md                     # [MD]     Canonical error role (newest 50)
│   ├── learnings.md                  # [MD]     Canonical learning role (newest 50)
│   ├── memory/
│   │   └── YYYY-MM-DD.md            # [MD]     Daily turn logs
│   ├── SOUL.md                       # [MD]     Identity/values (read-only by runtime)
│   ├── USER.md                       # [MD]     User profile (read-only by runtime)
│   ├── TOOLS.md                      # [MD]     Env-specific notes (read-only by runtime)
│   ├── AGENTS.md                     # [MD]     Safety rules (read-only by runtime)
│   ├── HEARTBEAT.md                  # [MD]     Periodic task checklist (read-only by runtime)
│   └── .git/                         # [Git]    Workspace version control
├── worktrees/
│   └── <taskId>/                     #          Git worktree for tasks that declare one
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
| **Structured text** | Canonical memory documents (index, topics, archive, audit, `learnings.md`, `errors.md`, daily logs) | Temp file → rename or append | Shared corpus lock/write queue |
| **Append-mostly SQLite** | `turns` (in `tasks.db`) | Async upsert, fire-and-forget | `TurnTraceService` (WAL) |
| **Append-only SQLite** | `task_events` (in `tasks.db`) | Synchronous insert | `TaskEventService` (WAL) |

Daily turn-log records are byte-bounded at 512 KiB. A date partition is accepted through 8 MiB; an append that would
exceed it is rejected before mutation and never trims prior observations. Host-side reads of canonical workspace text
files fail closed above 64 MiB. Recursive memory/wiki requests admit at most 1,000 regular files and 64 MiB of body bytes.

`errors.md` and `learnings.md` are canonical corpus members with the `error` and `learning` roles, not independently
capped logs: both are written through the shared corpus authority under one collection revision and the same CAS and
lock the curated roles use, and a role-scoped write leaves every unselected member byte-identical. The `error` role is
not searchable — it is excluded from the derived search index, unlike `learning`. A pre-canonical `errors.md` is
converted to the error role by memory preflight at startup; unrecognised remainder text is preserved verbatim under
`memory/legacy/`.

`.dartclaw-memory-corpus.json` is non-authoritative coordination state. It records the authenticated identity, role,
length, digest, and record IDs of each canonical member so ordinary reads and sparse writes can select only relevant
documents while preserving unopened members. Startup authenticates the complete corpus in bounded batches before
publishing the manifest or healthy derived-index state. A missing manifest is rebuilt from canonical Markdown; a
semantic mismatch triggers stopped-edit reconciliation or fails closed before index publication.

---

## Domain Models

### Session

Sessions are the primary conversation container. File-based storage, one directory per session.

```
Session
├── id: String (UUID v4)
├── title: String?
├── type: SessionType {main, user, channel, cron, task, logicalAgent, archive}
├── channelKey: String? (e.g., "agent:main:dm:contact:%40alice")
├── provider: String? (provider pinned for logical-agent sessions)
├── securityProfile: String? (worker isolation profile pinned for logical-agent sessions)
├── createdAt: DateTime
└── updatedAt: DateTime
```

**Storage**: `sessions/<id>/meta.json` (atomic full rewrite)
**Messages**: `sessions/<id>/messages.ndjson` (append-only, cursor = line number)
**Package**: `dartclaw_kernel` (model), `dartclaw_core` (service)

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
├── taskSession(taskId)                             → agent:main:task:<encoded>
└── logicalAgentSession(agentId, conversationId)    → agent:<encoded>:logical:<encoded>
```

**Index**: `sessions/.session_keys.json` maps keys to session UUIDs. `getOrCreateByKey()` is idempotent.
For logical-agent sessions, the returned UUID is the external conversation handle and the deterministic
`logicalAgentSession()` value is stored as `channelKey` for reconstruction.

#### Session Types & Protection

| Type | Created by | Protected from pruning | Protected from deletion |
|------|-----------|----------------------|------------------------|
| `main` | Startup | Yes | Yes |
| `user` | Web UI "new session" | No | No |
| `channel` | Channel message | Yes (when channel active) | No |
| `cron` | Scheduler | Yes (when job active) | Orphan cleanup after retention period |
| `task` | TaskExecutor | Yes | Yes (lifecycle via task API) |
| `logicalAgent` | `sessions_spawn` | No (ordinary retention/count rules) | No |
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
**Package**: `dartclaw_kernel` (model), `dartclaw_core` (service)

### Task

Tasks are the structured work unit for the task orchestrator. SQLite-based.

```
Task
├── id: String (UUID)
├── title: String
├── description: String
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

**Storage**: `tasks.db` → `tasks` table (WAL mode, indexed on status; the legacy `type` column remains through 0.25 for refusal compatibility)
**Package**: `dartclaw_core` (model and repository), `dartclaw_runtime` (service)

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

**Per-group project binding**: `GroupConfigResolver` resolves a `GroupEntry.project` from channel type and group ID for
the channel turn. Agent tool calls can pass that resolved project ID when creating work. Groups without a `project`
field fall back to the default project.

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

Valid transitions (`TaskStatus.validTransitions`):
- `draft` → `queued`, `cancelled`
- `queued` → `running`, `cancelled`, `failed`
- `running` → `review`, `accepted`, `interrupted`, `failed`, `cancelled`
- `interrupted` → `queued`, `cancelled`
- `review` → `accepted`, `rejected`, `queued` (push-back), `running`, `failed`
- `failed` → `queued` (retry: re-queue after failure)

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

### Derived Memory Index Row

```
MemoryIndexRow
├── id: int (autoincrement)
├── text: String
├── source: String (stable canonical locator, e.g. "topic/preferences/<entry-id>")
├── category: String?
├── createdAt: DateTime
└── userId: String (default: "owner")
```

**Storage**: `search.db` → `memory_chunks` + `memory_chunks_fts` (FTS5 virtual table)
**Source of truth**: the validated canonical corpus: bounded index, topic documents, archive, observations, learnings,
and deletion audit. Only searchable topic, archive, observation, and learning entries project into `search.db`;
`MEMORY.audit.md` is content-free operational evidence and is never indexed.
**Rebuild**: with DartClaw stopped, `dartclaw rebuild-index` atomically recreates the projection while preserving stable
entry locators, revisions, provenance, and source timestamps; undated entries sort oldest. Rebuild reads authenticated
corpus selections in bounded batches and publishes a healthy sibling index only after complete-union validation.

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
| Active turn liveness and wall-clock timers | In-memory (`TurnLivenessTracker` plus runner timer per active turn) | Transient | Turn completion or server restart |
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
**Package**: `dartclaw_kernel` (model), `dartclaw_core` (service interface), `dartclaw_runtime` (implementation)

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
└── tool_calls: String              (JSON records/count envelope; legacy arrays readable)
```

**Storage**: `tasks.db` → `turns` table (WAL mode; indexed on `session_id`, `task_id`, `started_at`)
**Write pattern**: Async fire-and-forget — same as `usage.jsonl`. Records retain the first 63 calls plus the latest while exact total/failed counts remain in the envelope. Traces survive entity deletion (no foreign keys).
**Package**: `dartclaw_core` (`ToolCallRecord`, `TurnTraceService`)

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
**Package**: `dartclaw_core` (`TaskEvent`, `TaskEventKind`, `TaskEventService`), `dartclaw_runtime` (`TaskEventRecorder`)

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
├── turnTimeoutSeconds: int?                 # agent-turn override
├── timeoutSeconds: int?                     # bash/approval operation deadline
├── review: StepReviewMode                   {always, codingOnly, never}
├── parallel: bool
├── entryGate: String?                       # skip-when-false gate; the only gate a step declares
├── inputs: List<String>
├── outputs: Map<String, OutputConfig>?      # canonical context-write declarations; keys exposed as outputKeys
├── evaluator: bool                          # minimal prompt scope for reviewer steps
├── maxTokens: int?                          # host-set only (merge-resolve token ceiling); not an authoring key
├── maxCostUsd: double?
├── maxRetries: int?
├── allowedTools: List<String>?
├── skill: String?                           # Agent Skills skill name
├── mapOver: String?                         # context key naming a JSON array
├── maxParallel: Object?                     # int, "unlimited", or template string
├── continueSession: bool                    # reuse the preceding agent step's resolved root session
├── onError: String?                         # engine-level error policy (`pause` default, `continue`)
└── workdir: String?                         # explicit working directory for bash steps

OutputConfig
├── format: OutputFormat                     {text, json, lines}
├── schema: Object?                          # String (preset name) or Map (inline JSON Schema)
└── source: String?                          # explicit output source (`worktree.branch`, `worktree.path`)

StepConfigDefault                            # entry in stepDefaults list
├── match: String                            # glob pattern matched against step IDs
├── provider: String?
├── model: String?
├── maxCostUsd: double?
├── maxRetries: int?
└── allowedTools: List<String>?

WorkflowLoop
├── id: String
├── steps: List<String>                      # step IDs that repeat
├── maxIterations: int                       # hard cap
└── exitGate: String                         # early-exit condition expression

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

**Storage**: Workflow definitions are YAML files parsed at runtime (not persisted to DB). Shipped definitions compile into the `dartclaw_workflow` embedded map and are materialized into `<dataDir>/workflows/built-in/` as `WorkflowSource.materialized`, because registries and spawned harnesses require real files. In source checkouts, canonical YAML under `packages/dartclaw_workflow/lib/src/workflow/definitions/` wins for editing and dev runs. Built-in `dartclaw-*` skills follow the same source precedence and materialize into provider-visible skill directories. Workflow execution state is persisted in two layers: lightweight context/status snapshots live on `WorkflowRun.contextJson` in SQLite, while the fuller `WorkflowContext` JSON is written under the workflow data directory and reloaded for resume/recovery paths.

**Discovery contract**: listing surfaces do not materialize full prompt-bearing definitions. `WorkflowDefinitionSource.listSummaries()` projects `WorkflowSummary` records for browsers and pickers, while detail/execution paths fetch the full `WorkflowDefinition` by name. This keeps discovery payloads small while preserving a single definition source of truth.

**Worktree bridge**: `OutputConfig.source` lets downstream workflow steps read persisted task worktree metadata directly
(`worktree.branch`, `worktree.path`) instead of requiring the agent to restate those values in context text. This is the
durable seam that connects workflow execution to task/worktree persistence.

**Package**: `dartclaw_workflow` (`WorkflowDefinition`, `WorkflowStep`, `WorkflowLoop`, `WorkflowVariable`, `OutputConfig`, `OutputFormat`, `StepConfigDefault`, `MapContext`, `WorkflowContext`, parser, validator, template engine, schema presets), `dartclaw_core` (`WorkflowLifecycleEvent` family)

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

┌──────────────────────────────┐  derived from  ┌───────────────────┐
│ Canonical searchable roles      │──────────────►│ MemoryIndexRow (FTS5)│
└──────────────────────────────┘  (rebuildable) └───────────────────┘
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
| `MemoryIndexRow` | Canonical topic, archive, observation, and learning entries | Source → derived index | **Rebuild** — `dartclaw rebuild-index` |
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
| **Memory pruned** | Entries >90d archived; canonical memory rows are atomically reconciled in `search.db`. |
| **Server restart** | In-memory governance state reset (rate limit counters, loop detection, pause queue). Persisted budget totals preserved in KvService. Thread bindings reloaded from file and reconciled against active tasks. |

---

## Package Ownership

```
dartclaw_kernel     (no workspace deps) Session, Message, SessionKey, shared enums,
                                        DartclawConfig, ConfigMeta, ConfigWriter,
                                        GuardChain, GuardAuditLogger, Project,
                                        AgentExecution, deterministic utilities
     ▲
     │
dartclaw_core       (kernel + sqlite3)  SessionService, MessageService, KvService,
     ▲                                  MemoryFileService, Task*, Goal*, EventBus,
     │                                  ThreadBindingStore, ProjectService (interface),
     │                                  HarnessFactory, harness interfaces,
     │                                  SqliteTaskRepository, SqliteGoalRepository,
     │                                  SqliteAgentExecutionRepository,
     │                                  SqliteWorkflowStepExecutionRepository,
     │                                  SqliteWorkflowRunRepository,
     │                                  MemoryService (FTS5), SearchDb, TaskDb,
     │                                  TurnStateStore, TurnTraceService,
     │                                  TaskEventService
     │
dartclaw_workflow   (core)              WorkflowRegistry, WorkflowDefinition/Step/Loop,
     ▲                                  workflow parser/validator/engine, MapContext,
     │                                  WorkflowContext, schema presets, built-in skills,
     │                                  WorkflowRunRepository + WorkflowStepExecutionRepository
     │                                  (ports; SQLite impls in dartclaw_core, which
     │                                  depends on this package), WorkflowMaterializer
     │
dartclaw_runtime     (shelf, http)       TaskService (wraps repository),
     ▲                                  TaskExecutor, WorktreeManager, DiffGenerator,
     │                                  ProjectService (implementation), TaskEventRecorder,
     │                                  BudgetEnforcer, PauseController, ScopeReconciler,
     │                                  EmergencyStopHandler
     │
dartclaw_cli        (args)              CLI runner, loopback API client, connected
                                        operations (`workflow`, `tasks`, `config`,
                                        `projects`, `sessions`, `runners`, `traces`,
                                        `jobs`), plus local lifecycle/maintenance
                                        commands
```

*`Task` and `Goal` models currently live in `dartclaw_core` (`lib/src/task/`).

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
| `MemoryCorpusService` / `MemoryPruner` | Bounded write queue + shared workspace lock | Serialize canonical memory mutations, pruning, and derived-index updates |
| `ConfigWriter` | `StreamController<_WriteOp>` | Prevent concurrent YAML rewrites |
| `SelfImprovementService` | `StreamController<_WriteOp>` + shared workspace lock for learnings | Serialize errors/learnings writes; keep capped learnings and their derived-index rows coherent with pruning |

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
| `errors.md` | Keep newest N records (default: 50) | On write (canonical error role, shared corpus lock) |
| `learnings.md` | Keep newest N records (default: 50) | On write (canonical learning role, shared corpus lock) |
| Canonical topic entries | Archive old entries and remove exact replays; regenerate the bounded index | Nightly cron (`MemoryPruner`) |
| Sessions | Archive after N days idle, count/disk budget | Scheduled (`SessionMaintenanceService`) |
| `search.db` | Full rebuild from searchable canonical roles | Manual (`dartclaw rebuild-index`) |

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
| `search.db` corrupted/deleted | `dartclaw rebuild-index` — rebuilt from the validated canonical corpus |
| `tasks.db` corrupted/deleted | **Data loss** — tasks are authoritative. Restore from backup. |
| `state.db` corrupted/deleted | Loss of active-turn crash recovery only. In-flight sessions may miss a recovery banner, but durable message/task data remains intact. |
| Session directory deleted | Session metadata and messages lost. If referenced by a task, task has dangling `sessionId`. |
| `dartclaw.yaml` corrupted | Restore from `dartclaw.yaml.bak` (created on every config write) |
| `kv.json` corrupted | Loss of daily usage aggregates. Recoverable from `usage.jsonl` re-aggregation. |
| Canonical memory member deleted | Corpus validation/reconciliation reports the missing member; restore the validated canonical topic, archive, observation, learning, or audit member from workspace Git or another trusted backup before rebuilding the derived index. `MEMORY.md` alone is only the bounded index, not the complete knowledge body. |

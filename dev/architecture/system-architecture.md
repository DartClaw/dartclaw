# DartClaw System Architecture Overview

Canonical reference for understanding how DartClaw works. Covers the 2-layer runtime model, all major subsystems, package structure, and how they connect.

**Current through**: 0.16.6 (Web UI interaction layer is Stimulus controllers on HTMX-rendered DOM; map/foreach `maxItems` is opt-in; omitted means uncapped)

---

## Design Philosophy

Five principles shape every architectural decision:

| Principle | Meaning |
|-----------|---------|
| **Minimal attack surface** | No Node.js/npm in the chain. Fewer dependencies = fewer supply chain vulnerabilities. Prefer capable standard libraries over third-party packages |
| **Dart as host** | AOT-compiled native binary, complete built-in toolchain (formatter, analyzer, linter, test runner), capable stdlib. No external toolchain dependencies |
| **Direct control protocol** | Dart spawns the native `claude` and `codex` binaries directly, no intermediate runtime. All state/storage/security lives in Dart |
| **Outpost pattern** | Purpose-built CLI tools in the best language for the job (Go for WhatsApp, Python for ML/NLP), invoked as subprocesses with structured JSON I/O. No shared runtime, no dependency contamination |
| **Auditable** | Codebase fits in a context window; dependencies stay minimal. On the order of ~100K production LOC across ~600 `lib/` Dart files (excluding tests and tooling) |

See also: [Roadmap — Core Philosophy](../ROADMAP.md)

---

## System Overview

DartClaw is a **2-layer agent runtime**. The Dart host is the control plane (full trust); the `claude` and `codex` CLI binaries are execution-plane providers with provider-specific security boundaries.

```
┌─────────────────────────────────────────────────────────────────────┐
│  Layer 1: Dart Host (AOT binary)                                   │
│  ────────────────────────────────                                   │
│  Owns: persistent storage, HTTP API + web UI, turn orchestration,  │
│        security policy, credential isolation, container management,│
│        session/task lifecycle, event bus, scheduling, MCP server    │
│  Trust: FULL — operator-controlled                                 │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ Provider control protocol
                           │ over stdin/stdout
┌──────────────────────────▼──────────────────────────────────────────┐
│  Layer 2: Provider CLI Binaries                                    │
│  ─────────────────────────────                                     │
│  Owns: LLM reasoning, tool execution (bash, file ops, grep, etc.),│
│        context management, streaming, prompt caching               │
│  Runtime: `claude` CLI (Bun standalone) + `codex` CLI              │
│           (Rust static binary)                                     │
│  Trust: PROVIDER-BOUND — Claude can run in Docker; Codex runs as   │
│         a direct subprocess with approval/sandbox controls         │
└─────────────────────────────────────────────────────────────────────┘
```

**Key insight**: The provider binaries are _not_ called via the TypeScript Agent SDK. Dart reimplements the provider-specific control boundaries directly (~500-800 LOC), eliminating the Deno/TypeScript middleman. Claude uses the bidirectional JSONL control protocol, while Codex uses bidirectional JSON-RPC JSONL; see [Control Protocol & Harness Architecture](control-protocol.md). This was validated by reverse-engineering the protocol from official SDKs in Python, Go, and Elixir (see [ADR-001](../adrs/001-sdk-integration-and-security-architecture.md)).

### What Each Layer Owns

| Concern | Layer 1 (Dart Host) | Layer 2 (Execution-Plane Providers) |
|---------|--------------------|-----------------------|
| State | Sessions, messages, memory, tasks, config, audit logs | Stateless (no session persistence) |
| Security | Guard chain, Claude container orchestration, credential proxy, audit | Tool execution inside the active provider boundary |
| Networking | HTTP server, SSE streaming, channel webhooks, MCP endpoint | Constrained by the active boundary (Claude container or Codex sandbox/runtime) |
| Agent logic | Turn orchestration, prompt composition, hook evaluation | LLM reasoning, tool selection and execution |
| Credentials | Owns all API keys; injects them through provider-specific boundaries (proxy for Claude, env for Codex) | Claude receives credentials through the proxy boundary; Codex receives only `OPENAI_API_KEY` via env injection |

Design rationale: [ADR-001 (SDK Integration & Security Architecture)](../adrs/001-sdk-integration-and-security-architecture.md)

Provider-specific credential and interception details live in [Security Architecture](security-architecture.md). Protocol details live in [Control Protocol & Harness Architecture](control-protocol.md).

---

## Component Map

```
┌───────────────────────────────────────────────────────────────────────────┐
│                           Dart Host Process                              │
│                                                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ Web UI      │  │ REST API    │  │ MCP Server   │  │ Channel       │  │
│  │ (Trellis +  │  │ (shelf)     │  │ (/mcp)       │  │ Webhooks      │  │
│  │  HTMX+SSE)  │  │             │  │              │  │ (WA/Sig/GC)   │  │
│  └──────┬──────┘  └──────┬──────┘  └──────┬───────┘  └───────┬───────┘  │
│         │                │                │                   │          │
│  ┌──────▼────────────────▼────────────────▼───────────────────▼───────┐  │
│  │                    DartclawServer (shelf)                          │  │
│  │  Auth middleware · Security headers · PageRegistry                │  │
│  └────────────────────────────┬───────────────────────────────────────┘  │
│                               │                                          │
│  ┌──────────┐  ┌──────────────▼───────────────┐  ┌────────────────────┐ │
│  │ Event    │  │ Turn Orchestration            │  │ Task Orchestrator  │ │
│  │ Bus      │◄─┤ TurnManager · TurnRunner     │  │ TaskExecutor       │ │
│  │          │  │ HarnessPool · SessionLock     │  │ WorktreeManager    │ │
│  └────┬─────┘  └──────────────┬───────────────┘  │ DiffGenerator      │ │
│       │                       │                   │ MergeExecutor      │ │
│       │        ┌──────────────▼───────────────┐   └────────┬───────────┘ │
│       │        │ HarnessFactory               │            │             │
│       │        │ ProtocolAdapter (abstract)    │            │             │
│       │        │ ClaudeProtocolAdapter        │            │             │
│       │        │ CodexProtocolAdapter         │            │             │
│       │        │ ClaudeCodeHarness             │◄───────────┘             │
│       │        │ CodexHarness                  │                          │
│       │        └──────────────┬───────────────┘                          │
│       │                       │                                          │
│  ┌────▼─────┐  ┌──────────────▼───────────────┐  ┌────────────────────┐ │
│  │ Guard    │  │ Security & Isolation          │  │ Storage            │ │
│  │ Chain    │  │ ContainerManager(s)           │  │ Files: NDJSON/JSON │ │
│  │ Cmd/File │  │ CredentialRegistry            │  │ SQLite: search.db  │ │
│  │ Net/Cont │  │ CredentialProxy               │  │         tasks.db   │ │
│  │          │  │ Docker (per-profile)          │  │         state.db   │ │
│  └──────────┘  └──────────────────────────────┘  └────────────────────┘ │
│                                                                          │
│  ┌──────────┐  ┌──────────────┐  ┌─────────────┐  ┌──────────────────┐  │
│  │ Channels │  │ Scheduling & │  │ Memory &    │  │ Config & Reload  │  │
│  │ WA/Sig/  │  │ Alerts       │  │ Search      │  │ ConfigNotifier   │  │
│  │ GChat    │  │ AlertRouter  │  │ FTS5/QMD    │  │ Reconfigurable   │  │
│  │          │  │ Cron jobs    │  │             │  │ SIGUSR1/filewatch│  │
│  └──────────┘  └──────────────┘  └─────────────┘  └──────────────────┘  │
│                                                                          │
│  ┌──────────────────────────┐  ┌──────────────────────────────────────┐  │
│  │ Project Management       │  │ Agent Observability                  │  │
│  │ ProjectService           │  │ AgentObserver                        │  │
│  │ RemotePushService        │  │ TurnTraceService · TaskEventService  │  │
│  │ PrCreator · Isolate git  │  │ TaskEventRecorder                    │  │
│  └──────────────────────────┘  └──────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────────┐  ┌──────────────────────────────────────┐  │
│  │ Workflow Engine           │  │ Canvas                               │  │
│  │ WorkflowExecutor          │  │ CanvasService                        │  │
│  │ WorkflowRegistry          │  │ CanvasRoutes · ShareMiddleware       │  │
│  │ DefinitionParser          │  │ WorkshopCanvasSubscriber             │  │
│  │ SkillIntrospector         │  │ CanvasAdminRoutes · QR               │  │
│  └──────────────────────────┘  └──────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────────┘
                           │
            Provider control protocol over stdin/stdout
                           │
┌──────────────────────────▼────────────────────────────────────────────────┐
│  Execution Boundary Examples                                              │
│                                                                          │
│  Claude path (container mode):                                           │
│    ├── Docker container (network:none, cap-drop=ALL, read-only rootfs)   │
│    ├── claude binary (Bun standalone)                                    │
│    ├── PreToolUse/PostToolUse hooks (evaluated by Dart host via JSONL)   │
│    └── MCP client → connects back to Dart host /mcp endpoint             │
│                                                                          │
│  Codex path (app-server mode):                                           │
│    ├── codex app-server (long-lived JSON-RPC over stdio)                 │
│    ├── Direct OPENAI_API_KEY env injection                               │
│    └── Approval or sandbox boundary depending on config                  │
│                                                                          │
│  Sidecar binaries (outpost pattern):                                     │
│    ├── GOWA (Go) — WhatsApp Web protocol                                │
│    └── signal-cli (Java) — Signal protocol                              │
└───────────────────────────────────────────────────────────────────────────┘
```

### Subsystem Details

#### Agent Harness

The harness layer is the interface between the Dart host and the execution-plane provider binaries. `AgentHarness` is an abstract class; `HarnessFactory` selects the provider family; `ProtocolAdapter` is the abstract wire-format boundary. `ClaudeCodeHarness` and `CodexHarness` are the production implementations.

| Component | File | Role |
|-----------|------|------|
| `AgentHarness` | `harness/agent_harness.dart` | Abstract interface: `start()`, `turn()`, `cancel()`, `stop()`, `dispose()` |
| `HarnessFactory` | `harness/harness_factory.dart` | Provider creation point that resolves the provider family and returns the matching harness and protocol adapter |
| `ProtocolAdapter` | `harness/protocol_adapter.dart` | Abstract protocol boundary for provider-specific wire formats |
| `ClaudeProtocolAdapter` | `harness/claude_protocol_adapter.dart` | Claude-specific adapter for bidirectional JSONL control protocol |
| `CodexProtocolAdapter` | `harness/codex_protocol_adapter.dart` | Codex adapter for bidirectional JSON-RPC JSONL |
| `ClaudeCodeHarness` | `harness/claude_code_harness.dart` | Spawns `claude` binary, manages JSONL I/O, implements the Claude control protocol |
| `CodexHarness` | `harness/codex_harness.dart` | Spawns `codex` binary, manages JSON-RPC JSONL I/O, implements the Codex control protocol |
| `ClaudeProtocol` | `harness/claude_protocol.dart` | Sealed class hierarchy for Claude JSONL message parsing (`SystemInit`, `StreamTextDelta`, `ToolUseBlock`, `ControlRequest`, etc.) |
| `HarnessConfig` | `harness/harness_config.dart` | Per-harness configuration: model, max turns, disallowed tools, MCP config |
| `ToolPolicyCascade` | `harness/tool_policy.dart` | 3-layer tool approval: global deny, agent deny, sandbox allow |
| `BridgeEvent` | `bridge/bridge_events.dart` | Typed stream events for consumers (text deltas, tool activity, results) |
| `NdjsonChannel` | `bridge/ndjson_channel.dart` | NDJSON line splitting and framing over `stdin`/`stdout` |

The Claude `initialize` control-protocol handshake registers hooks, MCP servers, and system prompt. Hook callbacks (`PreToolUse`/`PostToolUse`) and MCP tool calls (`mcp_message`) are handled in-process by the Dart host, with request-response correlation via `request_id`. For protocol details, see [Control Protocol & Harness Architecture](control-protocol.md).

**Package**: `dartclaw_core`

#### Turn Orchestration

Turn orchestration coordinates message flow from user input through guard evaluation, harness execution, and response persistence.

| Component | File | Role |
|-----------|------|------|
| `TurnManager` | `turn_manager.dart` | Entry point for interactive turns (web, channels, cron). Delegates to `TurnRunner` |
| `TurnRunner` | `turn_runner.dart` | Per-harness turn engine: guard evaluation, message persistence, SSE event streaming, progress-aware stall handling, cost tracking, crash recovery. One per harness in the pool |
| `TurnProgressMonitor` | `turn_progress_monitor.dart` | Resettable stall timer used by `TurnRunner`. Watches forward-progress events (`DeltaEvent`, `ToolUseEvent`, `ToolResultEvent`) and triggers warn/cancel/ignore actions when a turn goes silent |
| `HarnessPool` | `harness_pool.dart` | Pool of `TurnRunner` instances. Index 0 = primary (interactive use), indices 1..N = task pool. Configurable `maxConcurrent` |
| `SessionLockManager` | `concurrency/session_lock_manager.dart` | Per-session FIFO lock to serialize concurrent turns to the same session |
| `ContextMonitor` | `context/context_monitor.dart` | Tracks context window usage; suppresses heuristic flush when deterministic compaction signals exist; deduplicates pre-compaction flushes per cycle; emits SSE `context_warning` when usage exceeds configurable threshold (one-shot per session) |
| `ResultTrimmer` | `context/result_trimmer.dart` | Head+tail truncation for oversized tool results (fallback for `ExplorationSummarizer`) |
| `ExplorationSummarizer` | `context/exploration_summarizer.dart` | Type-aware structural summaries for large tool output (JSON schema, CSV columns, source code declarations); falls back to `ResultTrimmer` for unrecognized types or parse failures |
| `CompactionTaskEventSubscriber` | `task/compaction_task_event_subscriber.dart` | Listens for `CompactionCompletedEvent` and records a `compaction` task-timeline event when the compacted session belongs to an active running task |

**Context management strategy** (0.10): Three layers preserve useful context in long-running sessions:
1. **Compact instructions** — `BehaviorFileService.composeSystemPrompt()` appends a `# Compact instructions` section for long-running session types (web, DM, group, cron), guiding the binary on what to preserve during auto-compaction. Configurable via `context.compact_instructions`.
2. **Exploration summaries** — `ExplorationSummarizer` produces type-aware structural summaries (JSON key-paths, CSV columns, source code declarations) for tool output exceeding `context.exploration_summary_threshold` (default 25K tokens). Unrecognized types fall back to `ResultTrimmer` head+tail.
3. **Context warning** — `ContextMonitor.checkThreshold()` emits an SSE `context_warning` event when usage exceeds `context.warning_threshold` (default 80%, live-mutable). One-shot per session; web UI renders a dismissable banner.
4. **Compaction observability** (0.16) — provider compaction signals now flow into the shared event model. Claude emits `CompactionStartingEvent` from `PreCompact` and `CompactionCompletedEvent` from `compact_boundary`; Codex parses `contextCompaction` items into bridge events. `ContextMonitor` advances its compaction cycle on completion, pre-compaction flushes are SHA-256 deduplicated, and running task sessions record a `compaction` timeline event.

**Progress-aware stall detection** (0.14.4): `TurnRunner` now treats `DeltaEvent`, `ToolUseEvent`, and `ToolResultEvent` as forward progress. `TurnProgressMonitor` resets only on those events, not on `SystemInitEvent`, so long-running turns with steady tool activity do not trip a false stall timeout. The same forward-progress events also call `SessionResetService.touchActivity()` so idle-session maintenance follows actual harness activity rather than wall-clock turn duration.

**Package**: `dartclaw_server`

#### Channels

Channels connect DartClaw to external messaging platforms. All follow the **outpost pattern**: a purpose-built binary in the best language for the job, communicating via REST/webhooks.

| Channel | Sidecar | Protocol | Session Keying |
|---------|---------|----------|----------------|
| **WhatsApp** | GOWA (Go/whatsmeow) | REST + webhooks | `dmPerChannelContact()` / `groupShared()` |
| **Signal** | signal-cli (Java) | REST + SSE events | `dmPerChannelContact()` / `groupShared()` |
| **Google Chat** | None (pure REST) | Inbound webhook + REST API | `dmPerChannelContact()` / `groupShared()` |

Common infrastructure:

| Component | File | Role |
|-----------|------|------|
| `Channel` | `channel/channel.dart` | Abstract interface: `connect()`, `disconnect()`, `sendMessage()`, `formatResponse()` |
| `ChannelManager` | `channel/channel_manager.dart` | Routes inbound messages to sessions, derives session keys from scope config, preserves routed session context during pause, and delegates task-aware interception to `ChannelTaskBridge` before normal `MessageQueue` enqueue |
| `DmAccessController` | `channel/dm_access.dart` | Unified access control: pairing, allowlist, open, disabled modes |
| `MessageQueue` | `channel/message_queue.dart` | Per-session FIFO with debouncing (1000ms default) and global concurrency cap. Preserves channel-specific reply metadata on outbound chunks and can attach a `TurnObserver` for channel-specific in-flight feedback |
| `SessionScopeConfig` | `scoping/session_scope_config.dart` | Configurable DM/group scope with per-channel overrides (5 DM + 3 group modes) |
| `GroupEntry` | `scoping/group_entry.dart` | Structured group allowlist entry with optional `name`, `project`, `model`, `effort` overrides. Parsed by `GroupEntry.parseList()` which accepts mixed string/map YAML |
| `GroupConfigResolver` | `scoping/group_config_resolver.dart` | Lookup service keyed by `(ChannelType, groupId)`. Constructed in `ChannelWiring` from per-channel allowlists. Used by `resolveChannelTurnOverrides()` (model/effort precedence tier) and `ChannelTaskBridge` (project binding) |
| `TaskTriggerParser` | `channel/task_trigger_parser.dart` | Parses `<prefix> [<type>:] <description>` task trigger commands at message start. Returns match, empty-description error, or no-match |
| `ReviewCommandParser` | `channel/review_command_parser.dart` | Exact-match parser for `accept`, `reject`, and `push_back [<comment>]` review commands |
| `TaskOrigin` | `channel/task_origin.dart` | Persisted metadata linking a task back to its originating channel contact (`channelType`, `sessionKey`, `recipientId`, `contactId`) |
| `ThreadBinding` | `channel/thread_binding.dart` | Immutable model: `(channelType, threadId) → (taskId, sessionKey)`. Key: `"<channelType>::<threadId>"`. Fields: `createdAt`, `lastActivity` |
| `ThreadBindingStore` | `channel/thread_binding.dart` | In-memory `Map<String, ThreadBinding>` with JSON persistence to `thread-bindings.json`. CRUD + `reconcile()` (prunes bindings for terminal tasks on startup) |
| `FeaturesConfig` / `ThreadBindingFeatureConfig` | `config/features_config.dart` | `features.thread_binding.enabled` toggle that gates all thread binding features. Default: disabled. The `features:` namespace is the standard home for built-in feature flags (`features.<feature_name>.*`); a parallel `plugins:` namespace is reserved for future third-party extensions |

Design rationale: [ADR-005 (WhatsApp Integration)](../adrs/005-whatsapp-integration.md)

**Package**: `dartclaw_core` (interfaces, `DmAccessController`, `ChannelManager`), `dartclaw_whatsapp`, `dartclaw_signal`, `dartclaw_google_chat` (channel implementations), `dartclaw_server` (webhook routes, pairing UI)

#### Inbound Message Pipeline

Channel adapters normalize platform-specific payloads into `ChannelMessage` before any session routing begins. Google Chat contributes thread metadata (`thread.name`), sender display name, and avatar URL; WhatsApp and Signal contribute equivalent sender/contact metadata through the same DTO shape. The routing stack then composes pause handling, governance, review commands, thread binding, and task creation as separate capabilities rather than a standalone subsystem.

**Stage 1 — `ChannelManager.handleInboundMessage()`**

1. Resolve the owning `Channel`.
2. Derive the default session key from the current live scope config.
3. If thread binding is enabled, look up an existing binding and compute the routed session key early.
4. If the runtime is paused and the message is not a reserved command, enqueue it in `PauseController` using the already-resolved session key so bound-thread messages resume to the correct task session.
5. Delegate task-aware interception to `ChannelTaskBridge.tryHandle()`.
6. If nothing consumes the message, enqueue it to the normal `MessageQueue`.

##### Thread Binding Routing

**Stage 2 — `ChannelTaskBridge.tryHandle()` routing precedence**

1. Reserved commands: `/stop`, `/pause`, `/resume`, `/status`, `/new`, `/reset`, `/bind`, `/unbind`, and `@advisor`.
2. Thread-binding resolution: capture bound task/session context when a thread ID maps to a `ThreadBinding`.
3. Per-sender rate limit check: reject excess non-admin, non-review traffic with a polite response.
4. Review command parsing: `accept`, `reject`, and `push back` can target the bound task implicitly when a thread binding is present.
5. Bound-thread routing: enqueue the message directly to the bound task session and update `lastActivity`.
6. Task trigger parsing: create a task from the configured task prefix.
7. Fall through: route to the default shared or scoped session via `MessageQueue`.

Design rationale:
- Reserved commands stay ahead of pause and rate limiting so operators can always recover the runtime.
- Thread-binding lookup happens before review parsing so a bare `accept` in a bound thread can resolve the task implicitly.
- Bound-thread routing happens after review parsing so review commands are consumed as workflow actions instead of ordinary chat turns.
- Thread binding now supports multiple bindings per task. Google Chat binds a concrete thread, while WhatsApp and Signal bind the whole group conversation via explicit `/bind`.

**Outbound channel notifications**

- `TaskNotificationSubscriber` posts lifecycle updates back to the originating channel for tasks carrying a `TaskOrigin`.
- The initial Google Chat `running` notification opens or reuses a thread keyed by the task ID; the returned `thread.name` becomes the persisted `ThreadBinding`.
- Review-ready notifications are posted into the bound thread so replies such as `accept` or `push back` resolve in place.
- Terminal task states remove the binding through lifecycle cleanup, so later replies fall back to normal session routing.
- Governance events also surface back to channels when relevant: budget warnings post once per day after the 80% threshold, and loop-detection warnings or aborts emit notifications tied to the originating task/session context.

**Queued outbound reply handling** (0.14.4):
- `MessageQueue` copies Google Chat reply metadata (`messageName`, `messageCreateTime`, plus the originating `sourceMessageId`) from the inbound `ChannelMessage` onto each outbound `ChannelResponse`.
- `ChannelResponse.replyToMessageId` is now the explicit runtime field for "reply to this inbound channel message" instead of overloading metadata-only conventions.
- `GoogleChatChannel` uses `replyToMessageId` together with `messageCreateTime` to populate `quotedMessageMetadata`, which keeps quote-reply working across both direct webhook ingress and Space Events ingress.
- CLI channel wiring can attach a `TurnObserver` that watches the live turn future and bridge events, letting `GoogleChatFeedbackStrategy` update a placeholder message or emoji reaction during long-running turns without changing the normal queue contract.

#### Task Orchestrator

The task orchestrator transforms DartClaw from a single-session assistant into a parallel task execution platform with structured review flows.

| Component | File | Role |
|-----------|------|------|
| `TaskService` | `dartclaw_server/src/task/task_service.dart` | CRUD + state machine transitions. Wraps `SqliteTaskRepository` and is injected back into channel flows via `TaskCreator` / `TaskLister` callbacks |
| `TaskExecutor` | `task/task_executor.dart` | Acquires harness from pool, runs task turn, collects artifacts, transitions status |
| `WorktreeManager` | `task/worktree_manager.dart` | Git worktree lifecycle: create branch, register with file guard, cleanup on accept/reject |
| `DiffGenerator` | `task/diff_generator.dart` | Structured diff output: files changed, additions, deletions, hunks |
| `MergeExecutor` | `task/merge_executor.dart` | Squash/merge worktree back to main branch, conflict detection |
| `TaskFileGuard` | `task/task_file_guard.dart` | Path containment via `p.isWithin()` — coding tasks restricted to worktree directory |
| `ArtifactCollector` | `task/artifact_collector.dart` | Collects task outputs as typed artifacts (`diff`, `document`, `data`, `log`) |
| `AgentObserver` | `task/agent_observer.dart` | Per-agent metrics: busy/idle tracking, turn counts, harness status |
| `TaskReviewService` | `task/task_review_service.dart` | Shared accept/reject/push-back lifecycle for both HTTP and channel review paths. Owns state transition, merge execution (coding tasks), conflict artifact persistence, worktree cleanup, and `TaskStatusChangedEvent` firing. Single shared instance wired into both `task_routes.dart` and `ChannelManager` |
| `TaskNotificationSubscriber` | `task/task_notification_subscriber.dart` | Subscribes to `TaskStatusChangedEvent` on the event bus. For tasks with a `TaskOrigin`, sends best-effort in-channel notifications on key transitions (queued, running, review, accepted, rejected, failed). Notification text is conditioned on task type — worktree-backed tasks include merge outcome language; non-coding tasks do not. When thread binding is enabled and the origin channel is Google Chat, the initial `running` notification is sent in a new thread (via `sendMessageWithThread`); the returned `thread.name` is used to create a `ThreadBinding`, and subsequent notifications for that task are threaded into the same conversation |
| `AdvisorSubscriber` | `advisor/advisor_subscriber.dart` | EventBus-driven crowd-coding observer. Accumulates a bounded normalized context window, evaluates triggers (`periodic`, `task_review`, `turn_depth`, `token_velocity`, `explicit`), acquires a pooled runner for an advisory turn, parses structured output, then routes the result to canvas, bound channels, and the event bus |

Task state machine: `draft` → `queued` → `running` → `review` → `accepted`/`rejected`/`cancelled`/`failed`. See [Data Model — Task State Machine](data-model.md) for valid transitions.

Container dispatch routes task types to security profiles: `research` → `restricted` container (no workspace mount), all others → `workspace` container.

**Package**: `dartclaw_server` (service, executor), `dartclaw_core` (models, status enum), `dartclaw_storage` (SQLite repository)

**Worktree lifecycle hardening (0.16.4)**:
- `WorktreeManager.create()` now reconciles three sources of truth before `git worktree add`: the in-memory cache, the on-disk worktree directory, and `git worktree list --porcelain`. Matching state is adopted; orphaned or mismatched state is reaped and recreated.
- Workflow-shared worktrees are no longer a plain read-then-create race. `TaskExecutor` now serializes lookup+create per `workflowWorktreeKey`, persists the resulting `{key, path, branch, workflowRunId}` binding on the `workflow_runs` row, and rehydrates that binding on resume/retry/recovery before execution restarts.
- The path invariant is explicit: worktrees stay keyed by the caller-supplied task UUID. Shared identity fields such as workflow run ID can select a binding, but must never derive the on-disk worktree path.

#### Workflow Engine

Multi-step agent pipelines defined in YAML. Added in 0.15, then extended incrementally through 0.16.4.

| Component | File | Role |
|-----------|------|------|
| `WorkflowDefinitionParser` | `workflow/workflow_definition_parser.dart` | Parses YAML into `WorkflowDefinition` model — handles all 0.16.1 fields |
| `WorkflowDefinitionValidator` | `workflow/workflow_definition_validator.dart` | Semantic validation: variable refs, context key consistency, gate expressions, loop references, `mapOver` references, hybrid step constraints (warnings + errors) |
| `WorkflowTemplateEngine` | `workflow/workflow_template_engine.dart` | Resolves `{{VARIABLE}}`, `{{context.key}}`, and `{{map.*}}` references in step prompts |
| `WorkflowContext` | `workflow/workflow_context.dart` | Per-run accumulated context: step outputs keyed by name |
| `MapContext` | `workflow/map_context.dart` | Per-iteration state for map steps: current item, 0-based index, total length |
| `WorkflowDefinitionSource` | `workflow/workflow_definition_source.dart` | Summary/detail seam for workflow discovery. Listing surfaces consume `WorkflowSummary`; detail/execution paths fetch the full `WorkflowDefinition` by name |
| `WorkflowRegistry` | `workflow/workflow_registry.dart` | Production registry for materialized + custom workflow definitions. Loads filesystem YAML from the asset/workspace roots and serves both summary listings and full-definition lookup |
| `PromptAugmenter` | `workflow/prompt_augmenter.dart` | Appends `schema` preset instructions to step prompts |
| `SchemaValidator` | `workflow/schema_validator.dart` | Validates step output against JSON Schema (preset or inline) |
| `StepConfigResolver` | `workflow/step_config_resolver.dart` | Resolves per-step config from `stepDefaults` patterns and per-step overrides |
| `SkillIntrospector` | `workflow/skill_introspector.dart` | Runtime skill preflight seam: checks authored `skill:` refs against the selected provider's visible skill list before dispatch |
| `WorkflowCliRunner` | `task/workflow_cli_runner.dart` | Workflow-only one-shot CLI execution path for all workflow agent steps plus structured extraction turns |
| `WorkflowMaterializer` | `apps/dartclaw_cli/lib/src/commands/workflow_materializer.dart` | Copies shipped workflow YAML files into `<workspaceDir>/workflows/` before registry load; preserves user edits and materialized precedence |
| `shellEscape` | `workflow/shell_escape.dart` | Single-quote shell escaping for `{{context.*}}` values in bash commands — prevents injection |

### Workflow One-Shot Execution

The default system model remains a long-lived streaming harness per active runner. Workflow execution now adds a scoped exception for bounded workflow agent steps:

- The Dart host still owns task rows, workflow state, transcript persistence, and budget enforcement.
- Workflow agent steps execute prompt chains as direct CLI invocations instead of replaying those prompts through the interactive streaming harness.
- Structured extraction turns reuse provider-native session continuity (`--resume` / `resume`) and add native schema flags.
- Workflow-authored step types are preserved as metadata (`_workflowStepType`), while runtime dispatch uses the coding-task path and `readOnly` to distinguish mutating and non-mutating workflow steps.

Key workflow-engine extensions:
- **Output format system**: `outputs:` map per step, `format: text/json/lines`, `schema: preset_name` or inline JSON Schema. Multi-strategy JSON extraction (raw → code blocks → pattern scan). 5 built-in schema presets: `verdict`, `remediation_result`, `story_plan`, `file_list`, `checklist`.
- **Step config defaults**: `stepDefaults:` list with glob `match` patterns. First match wins. Covers provider, model, maxTokens, maxCostUsd, maxRetries, allowedTools.
- **Skill-aware steps**: Optional `skill:` field on steps. When present, step delegates to an Agent Skills-compatible skill. Authored refs are checked at workflow-run preflight through `SkillIntrospector`, using the effective provider's visible skill list rather than a local metadata registry.
- **Map/fan-out**: `map_over:` references a JSON array in context; the step runs once per element. `max_parallel:` (int, `"unlimited"`, or template), optional `max_items:` (omitted means uncapped). Template engine resolves `{{map.item}}`, `{{map.item.field}}`, `{{map.index}}`, `{{map.length}}`, `{{context.key[map.index]}}`.
- **Workflow workspace isolation**: workflow steps receive behavior files from a dedicated workflow workspace (`workflow.workspace_dir` or the built-in `<dataDir>/workflow-workspace/`), not the main interactive workspace.

Key 0.16.1 extensions:
- **Hybrid validation**: `WorkflowDefinitionValidator.validate()` returns `ValidationReport` with separate `errors` (hard failures, definition excluded) and `warnings` (soft notices, definition still loads). Unknown step types and `approval` in loops are warnings; `approval` in parallel groups and invalid `continueSession` are errors.
- **Approval pauses**: `type: approval` steps reuse the workflow run's paused lifecycle rather than inventing a parallel status tree. Approval metadata is persisted into workflow context, surfaced through run-detail/API/SSE views, and resumed or cancelled through the existing workflow service.
- **Bash step execution**: `type: bash` steps run host-side via `Process.run()` with zero task creation and zero token accounting. `{{context.*}}` values are shell-escaped before execution. stdout captured up to 64 KB, fed to the same `text`/`json`/`lines` extraction pipeline as agent steps. Step metadata (`<stepId>.status`, `<stepId>.exitCode`, `<stepId>.tokenCount: 0`) written to context.
- **Session continuity + worktree bridge**: `continueSession: true` allows linear agent-step chains to reuse the preceding root session. Downstream steps can read persisted worktree metadata through output sources such as `worktree.branch` and `worktree.path`, so deterministic steps no longer need agent-authored bridge text.
- **`workdir` resolution**: Explicit `workdir` (with template resolution) → workspace root (`<dataDir>/workspace`). Non-existent directory fails the step before command execution.
- **`onError` policy**: `onError: pause` (default) pauses the run on failure. `onError: continue` records failed-step metadata and continues to the next step. Applies uniformly to bash steps and agent steps.
- **Summary-first discovery contract**: workflow listing surfaces now consume a summary projection (`name`, `description`, `stepCount`, `hasLoops`, `maxTokens`, variables) from `WorkflowDefinitionSource.listSummaries()`. Full prompt-bearing definitions are fetched separately by name for detail pages and execution. This keeps picker/browser flows lightweight while preserving a single source of truth in the registry.

**Package**: `dartclaw_workflow` (parser, validator, workflow registry, executor, skill preflight, workflow DTOs), `dartclaw_server` (workflow HTTP routes and web presentation)

#### Security

Defense-in-depth across five layers:

```
Layer 5:  OS-level container isolation (Docker kernel namespaces)
Layer 4:  Network isolation (network:none + Dart credential proxy)
Layer 3:  Guard chain (command/file/network/content/input sanitizer)
Layer 2:  Prompt-level safety rules (AGENTS.md, hardcoded rules)
Layer 1:  Credential isolation (API keys never in agent env)
```

| Component | File | Role |
|-----------|------|------|
| `GuardChain` | `security/guard.dart` | Ordered guard evaluation; fail-closed by default |
| `CommandGuard` | `security/command_guard.dart` | Regex + pipe analysis + quote stripping on bash commands |
| `FileGuard` | `security/file_guard.dart` | 3-level path access (`no_access`/`read_only`/`no_delete`), symlink resolution |
| `NetworkGuard` | `security/network_guard.dart` | Domain allowlist + SSRF detection (DNS resolution + address range validation) |
| `ContentGuard` | `security/content_guard.dart` | LLM-based content classification at agent boundary (Haiku) |
| `InputSanitizer` | `security/input_sanitizer.dart` | Length cap + regex scrub on inbound channel messages |
| `MessageRedactor` | `security/message_redactor.dart` | Pattern-based redaction of secrets/PII in logged output |
| `GuardAuditLogger` | `security/guard_audit.dart` | Date-partitioned `audit-YYYY-MM-DD.ndjson` files with retention cleanup |
| `ContainerManager` | `container/container_manager.dart` | Docker lifecycle: create, start, exec, stop. Per-security-profile containers |
| `ContentClassifier` | `security/content_classifier.dart` | Pluggable backends: `ClaudeBinaryClassifier` (default) or `AnthropicApiClassifier` |

Container naming: `dartclaw-<fnv1a8(dataDir)>-<profileId>` — deterministic 8-char FNV-1a digest of the data directory (Docker-safe local identifier, not a cryptographic hash), collision-free across installs.

| Security Profile | Container | Mounts | Used By |
|------------------|-----------|--------|---------|
| `workspace` | `dartclaw-<id>-workspace` | `/workspace:rw`, `/project:ro` | Main chat, coding tasks, cron |
| `restricted` | `dartclaw-<id>-restricted` | No workspace | Search agent, research tasks |

Design rationale: [ADR-001](../adrs/001-sdk-integration-and-security-architecture.md), [ADR-012 (Per-Type Container Isolation)](../adrs/012-per-type-container-isolation.md)

**Package**: `dartclaw_security` (guards, all concrete guard implementations, content classification interfaces, message redaction, guard audit primitives), `dartclaw_core` (container config, guard config, `GuardBlockEvent`), `dartclaw_server` (guard wiring with EventBus, container health monitor)

#### Storage

Two storage mechanisms, each for distinct access patterns:

| Mechanism | Used For | Access Pattern | Source of Truth? |
|-----------|----------|----------------|-----------------|
| **Files** (NDJSON, JSON, YAML, Markdown) | Sessions, messages, memory, config, audit, usage | Append-only logs, atomic documents | **Yes** |
| **SQLite** (`search.db`, `tasks.db`, `state.db`) | FTS5 search index, tasks/goals/artifacts, transient turn recovery state | Relational queries, full-text search | `search.db`: derived (rebuildable). `tasks.db`: **authoritative**. `state.db`: transient operational state |

File-based services use write queues (`StreamController`) or fire-and-forget patterns for concurrency safety. All mutable JSON/YAML files use temp-file + atomic rename.

Full persistence details: [Data Model & Persistence Overview](data-model.md)

Design rationale: [ADR-002 (File-Based Storage)](../adrs/002-file-based-storage.md)

**Package**: `dartclaw_core` (file-based services), `dartclaw_storage` (SQLite services)

#### Web UI

Server-rendered HTML with declarative interactivity — zero JavaScript build toolchain.

| Layer | Technology | Role |
|-------|-----------|------|
| Templates | Trellis (`.html` files with `tl:` attributes) | Server-side rendering with auto-escaping, fragment support |
| Interactivity | HTMX + Stimulus controllers | HTMX owns navigation, requests, swaps, and OOB updates; Stimulus owns `dc-*` browser behavior attached to server-rendered DOM |
| Streaming | HTMX SSE extension (`htmx-ext-sse`) | Declarative SSE: `sse-connect`, `sse-swap` attributes. Server pushes HTML fragments |
| Markdown | marked.js + highlight.js | Client-side rendering of agent responses |
| Styling | Custom CSS (tokens.css + components.css) | Catppuccin Mocha (dark) + Latte (light) palette, CSS custom properties |

Navigation uses HTMX fragment rendering: `_wantsFragment()` detects `HX-Request` header and returns content-only HTML (no shell), swapped into `#main-content` with out-of-band sidebar/topbar updates.

Stimulus controllers live under `static/controllers/` and use `dc-*` controller names. Trellis templates attach behavior with `data-controller`, `data-action="event->controller#method"`, controller targets, and typed values. Controller `connect()`/`disconnect()` lifecycle handles HTMX replacement and history restoration without page-global reinitialization.

SSE streaming flow: POST `/api/sessions/:id/send` → server returns HTMX SSE-connected HTML fragment → server pushes `delta`, `tool_use`, `tool_result`, `done` events as HTML fragments → HTMX handles DOM insertion.

Pages registered via `PageRegistry`: Health Dashboard, Settings, Memory, Scheduling, Tasks. SDK consumers can add pages via `server.registerDashboardPage()`.

The 0.14.2 canvas subsystem adds two extra surfaces on top of the core web UI:
- Public share-token pages under `/canvas/<token>` for zero-auth viewer access
- An authenticated `/canvas-admin` dashboard page that manages share links and embeds the live canvas in a sandboxed iframe

`CanvasService` is the server-side state hub for this feature. It keeps in-memory per-session canvas state, tracks share tokens, and fan-outs SSE events to both public viewers and admin embeds. Workshop mode uses `WorkshopCanvasSubscriber` to auto-push a task board and stats bar when task events fire.

**Package**: `dartclaw_server`

#### Configuration

Three-tier configuration system:

| Tier | Mechanism | Restart Required? |
|------|-----------|-------------------|
| **Tier 1** (0.5) | Runtime toggles via API | No — applied immediately |
| **Tier 2** (0.6) | Full YAML editing + graceful restart | Yes — 30s turn drain + restart |
| **Tier 3** (0.16) | `ConfigNotifier` + `Reconfigurable` services + reload triggers (`SIGUSR1` / file-watch) | No — reloadable sections apply to the running process |

| Component | File | Role |
|-----------|------|------|
| `DartclawConfig` | `dartclaw_config/dartclaw_config.dart` | Parsed YAML config with env var substitution (`${ENV_VAR}`) |
| `ConfigWriter` | `dartclaw_config/config_writer.dart` | YAML round-trip writer (preserves comments via `yaml_edit`), backup-on-write |
| `ConfigValidator` | `dartclaw_config/config_validator.dart` | Server-side validation before write |
| `ConfigMeta` | `dartclaw_config/config_meta.dart` | Schema metadata for UI form generation |
| `RuntimeConfig` | `runtime_config.dart` | In-memory toggles for live config fields |
| `ConfigNotifier` | `config/config_notifier.dart` | Holds the current `DartclawConfig`, computes `ConfigDelta`, and synchronously notifies registered `Reconfigurable` services |
| `ConfigDelta` | `config/config_delta.dart` | Immutable changed-section snapshot (`previous`, `current`, `changedKeys`) used to filter reconfiguration work |
| `Reconfigurable` | `config/reconfigurable.dart` | Interface implemented by hot-reloadable services (`watchKeys`, synchronous `reconfigure`) |
| `ReloadConfig` | `config/gateway_config.dart` | `gateway.reload` sub-config: `mode` (`off` / `signal` / `auto`) and file-watch `debounce_ms` |
| `ReloadTriggerService` | `apps/dartclaw_cli/.../reload_trigger_service.dart` | Process-level trigger integration: `SIGUSR1` plus parent-directory file watching with debounce for atomic writes |

Config resolution order: CLI flags > config file (`--config` > `DARTCLAW_CONFIG` env > `./dartclaw.yaml` > `~/.dartclaw/dartclaw.yaml`) > defaults.

The config API now partitions fields into three mutability classes:
- **live** — handled immediately by existing Tier 1 side effects
- **reloadable** — written to YAML, then applied by `ConfigNotifier.reload()` without restart
- **restart** — written to YAML and tracked in `restart.pending` until the next graceful restart

In 0.16, this powers hot-reload for context settings, scheduling services, alert routing config, guard-chain rebuilds, queue/lock tuning, and other runtime-owned services. Server socket bindings (`server.port`, `server.host`, `server.data_dir`) remain explicitly non-reloadable and are excluded from `ConfigDelta`.

Behavior files (`SOUL.md`, `AGENTS.md`, `USER.md`, `TOOLS.md`, `MEMORY.md`, `HEARTBEAT.md`) are re-read every turn — no restart needed for behavior changes.

**Package**: `dartclaw_core` (live config notifier, delta, runtime-facing interfaces), `dartclaw_config` (typed config model, metadata, validator, writer), `dartclaw_server` (API routes), `dartclaw_cli` (reload triggers)

#### Event Bus

Lightweight typed event bus for internal decoupling (~50 LOC, zero external dependencies).

```dart
class EventBus {
  final _controller = StreamController<DartclawEvent>.broadcast();
  Stream<T> on<T extends DartclawEvent>() => _controller.stream.whereType<T>();
  void fire(DartclawEvent event) { /* runZonedGuarded wrapper */ }
}
```

Event hierarchy (Dart 3 sealed classes — compiler-checked exhaustive matching):

```
sealed class DartclawEvent
├── FailedAuthEvent              — authentication failure
├── GuardBlockEvent              — guard blocks/warns on input
├── ToolPermissionDeniedEvent    — Claude denied a tool at its own permission layer
├── ConfigChangedEvent           — config values changed via API
├── sealed CompactionLifecycleEvent
│   ├── CompactionStartingEvent  — provider signaled compaction is about to begin
│   └── CompactionCompletedEvent — provider signaled compaction boundary completed
├── sealed SessionLifecycleEvent
│   ├── SessionCreatedEvent      — session created
│   ├── SessionEndedEvent        — session ended
│   └── SessionErrorEvent        — session error
├── sealed TaskLifecycleEvent
│   ├── TaskStatusChangedEvent   — task state machine transitions
│   ├── TaskReviewReadyEvent     — task ready for review
│   ├── TaskEventCreatedEvent    — task timeline event created
│   └── BudgetWarningEvent       — token budget threshold reached
├── ScheduledJobFailedEvent      — scheduled job exhausted retries
├── sealed WorkflowLifecycleEvent
│   ├── WorkflowRunStatusChangedEvent — workflow run status transitions
│   ├── WorkflowStepCompletedEvent    — individual step completed
│   ├── ParallelGroupCompletedEvent   — parallel group completed
│   ├── WorkflowBudgetWarningEvent    — workflow token budget threshold
│   ├── LoopIterationCompletedEvent   — loop iteration completed
│   ├── MapIterationCompletedEvent    — map iteration completed
│   ├── MapStepCompletedEvent         — map step fully completed
│   ├── WorkflowApprovalRequestedEvent — approval step paused for review
│   └── WorkflowApprovalResolvedEvent  — approval resolved
├── sealed ProjectLifecycleEvent
│   └── ProjectStatusChangedEvent — project status transitions
├── LoopDetectedEvent            — governance loop detection triggered
├── EmergencyStopEvent           — /stop command executed
├── AdvisorMentionEvent          — explicit `@advisor` invocation from channel traffic
├── AdvisorInsightEvent          — structured advisor output routed to canvas/channels
├── sealed AgentLifecycleEvent
│   └── AgentStateChangedEvent   — harness busy/idle transitions
└── sealed ContainerLifecycleEvent
    ├── ContainerStartedEvent    — container started
    ├── ContainerStoppedEvent    — container stopped
    └── ContainerCrashedEvent    — container crashed
```

Subscriber exceptions are caught via `runZonedGuarded` and logged without propagating to the event source. Events are fire-and-forget notifications — no buffering, no persistence.

Design rationale: [ADR-011 (Event-Driven Architecture)](../adrs/011-event-driven-architecture.md)

**Package**: `dartclaw_core`

#### Scheduling

Scheduled automation with three job modes and two delivery patterns:

| Component | File | Role |
|-----------|------|------|
| `ScheduleService` | `scheduling/schedule_service.dart` | Manages job lifecycle, timer scheduling, delivery |
| `HeartbeatScheduler` | (via `ScheduleService`) | Periodic task checklist from `HEARTBEAT.md` |
| `CronParser` | `scheduling/cron_parser.dart` | 5-field cron expression parser |
| `ScheduledTaskRunner` | `scheduling/scheduled_task_runner.dart` | Bridges scheduling to task orchestrator (`task` job type) |

Job types: `cron` (cron expression), `interval` (repeat every N minutes), `once` (one-shot).

Delivery modes: `announce` (sends result to a session), `webhook` (HTTP POST to URL), `none` (run silently), `task` (creates a reviewable task).

0.16 adds `ScheduledJobFailedEvent` to the event hierarchy. `ScheduleService` emits it after the final retry attempt fails, letting observability and alert-routing subscribers react without coupling scheduling logic to channels or UI concerns.

**Package**: `dartclaw_server`

#### System Alerts

0.16 introduces an explicit alert-routing subsystem for operational events.

| Component | File | Role |
|-----------|------|------|
| `AlertsConfig` | `config/alerts_config.dart` | Top-level `alerts:` config section: `enabled`, `cooldown_seconds`, `burst_threshold`, `targets`, `routes` |
| `AlertRouter` | `alerts/alert_router.dart` | EventBus subscriber that classifies runtime events, resolves explicit channel targets, and delegates formatting/delivery |
| `AlertDeliveryAdapter` | `alerts/alert_delivery_adapter.dart` | Resolves `(channelType, recipient)` into the concrete `Channel.sendMessage()` call without going through job-oriented delivery services |
| `AlertFormatter` | `alerts/alert_formatter.dart` | Channel-aware formatting: plain text for WhatsApp/Signal, Cards v2 payloads for Google Chat |
| `AlertThrottle` | `alerts/alert_throttle.dart` | Per-target cooldown and burst-summary accumulator keyed by `(eventType, channelType, recipient)` |

The shipped alert classification model covers guard blocks, container crashes, non-channel task failures, scheduled-job failures, budget warnings (task and workflow), and compaction completion. Routing is explicit: operators declare recipient/channel pairs in `alerts.targets`, then optionally narrow delivery per event type through `alerts.routes`.

**Package**: `dartclaw_config` (`AlertsConfig`), `dartclaw_server` (routing, classification, formatting, throttling)

#### Memory & Search

```
MEMORY.md ──(source of truth)──► search.db (FTS5 index, rebuildable)
daily logs  ─────────────────────┘
```

| Component | File | Role |
|-----------|------|------|
| `MemoryFileService` | `memory/memory_file.dart` | Read/write MEMORY.md with size cap and atomic writes |
| `SelfImprovementService` | `memory/self_improvement.dart` | Auto-populate `errors.md` on failures, route `learnings.md` via memory_save |
| `MemoryPruner` | `memory/memory_pruner.dart` | Archive entries >90d, exact dedup, keep under cap |
| `MemoryService` | `storage/memory_service.dart` | FTS5 insert/search with BM25 ranking |
| `SearchDb` | `storage/search_db.dart` | SQLite schema, FTS5 virtual table, rebuild |
| `Fts5SearchBackend` | `search/fts5_search_backend.dart` | Default search: FTS5 BM25 |
| `QmdSearchBackend` | `search/qmd_search_backend.dart` | Opt-in hybrid: QMD sidecar for neural reranking |

Memory MCP tools (`memory_save`, `memory_search`, `memory_read`) are registered on the internal MCP server and invoked by the agent via standard MCP protocol.

**Package**: `dartclaw_core` (file services), `dartclaw_storage` (SQLite services, search backends)

#### Project Management

Multi-project support added in 0.14. DartClaw can manage multiple git repositories and route coding tasks to the appropriate project worktree.

| Component | File | Role |
|-----------|------|------|
| `ProjectService` | `task/project_service.dart` | CRUD for projects; clone/fetch/push management via `Isolate.run()` |
| `ProjectConfig` | `config/project_config.dart` | Parser for `projects:` config section |
| `Project` | `dartclaw_models` | Domain model: id, name, remoteUrl, localPath, defaultBranch, credentialsRef, cloneStrategy, prStrategy, status |
| Implicit `_local` | (ephemeral) | Backward-compatible project synthesized from `Directory.current.path`; not persisted |

Key characteristics:
- **Config-seeded, API-managed** pattern: projects defined in `dartclaw.yaml` are read-only via the API; projects added at runtime are fully mutable
- **`Isolate.run()`** for blocking git operations (clone, fetch, push) — prevents blocking the Dart event loop on I/O-intensive operations. First use of Isolates in DartClaw; simple args in / `ProcessResult` out, no complex objects cross the isolate boundary
- **`projects.json`** with atomic writes for runtime project registry persistence
- Clones stored at `<dataDir>/projects/<projectId>/`

As of 0.16.4, config/API projects can also be bound directly to an existing checkout via `projects.<id>.localPath:`. The runtime still uses `remoteUrl == ''` as the single discriminator for local-only projects (covering both the implicit `_local` project and named local-path projects). Workflow start now preflights named local-path projects before any coding task is created: dirty trees and branch mismatches fail fast unless the operator explicitly opts in with `--allow-dirty-localpath`, publish requires an existing `origin` remote in the working tree, and containerized runs mount named local-path projects under the same `/projects/<id>` container convention used for cloned repositories.

Design rationale: [ADR-017 (Multi-Project Architecture)](../adrs/017-multi-project-architecture.md)

**Package**: `dartclaw_models` (model), `dartclaw_core` (service interface), `dartclaw_server` (implementation, API routes)

#### Agent Observability

Enriched turn recording and task event system added in 0.14.

| Component | File | Role |
|-----------|------|------|
| `ToolCallRecord` | `dartclaw_models` | Per-tool-call record: name, success, durationMs, errorType |
| `TurnTraceService` | `dartclaw_storage` | Fire-and-forget persistence to `turns` SQLite table in `tasks.db` (NF03 — zero latency impact) |
| `TaskEventService` | `dartclaw_storage` | Synchronous persistence to `task_events` SQLite table in `tasks.db` (NF04 — no event loss on crash) |
| `TaskEventRecorder` | `dartclaw_server` | Centralized event recording helper with typed convenience methods |

**Dual write pattern**: Turn traces are fire-and-forget (async, same as `usage.jsonl`) — low latency, best-effort. Task events are synchronous — guaranteed persistence before the recording call returns. The two patterns reflect different durability requirements: traces are analytical; events are operational (used for timeline display and progress tracking).

0.16 extends task observability with compaction tracking. `CompactionTaskEventSubscriber` listens for `CompactionCompletedEvent` and records a `TaskEventKind.compaction` row when the compacted SDK session belongs to a currently running task. This keeps long-running coding sessions observable even when provider-managed compaction occurs mid-task.

Cache token normalization is handled at the `ProtocolAdapter` layer: Anthropic cache fields (`cache_read_input_tokens`, `cache_creation_input_tokens`) and OpenAI fields (`cached_input_tokens`) are both normalized to canonical `cacheReadTokens` / `cacheWriteTokens` before reaching `TurnOutcome`. See [Control Protocol & Harness Architecture](control-protocol.md) for details.

**Package**: `dartclaw_models` (`ToolCallRecord`, `TaskEvent`, `TaskEventKind`), `dartclaw_storage` (`TurnTraceService`, `TaskEventService`), `dartclaw_server` (`TaskEventRecorder`)

#### MCP Server

Internal MCP server hosted as a `/mcp` endpoint on the existing shelf HTTP server. Provider binaries connect back to this endpoint for tool invocations: Claude receives MCP server config via `--mcp-config`, while Codex receives the same endpoint through generated `config.toml`.

| Component | File | Role |
|-----------|------|------|
| `McpProtocolHandler` | `mcp/mcp_server.dart` | MCP protocol handling, tool registration |
| `McpRouter` | `mcp/mcp_router.dart` | Shelf route adapter for MCP HTTP transport |
| `MemoryTools` | `mcp/memory_tools.dart` | `memory_save`, `memory_search`, `memory_read` |
| `SessionsSendTool` | `mcp/sessions_send_tool.dart` | Inter-agent delegation (sync) |
| `SessionsSpawnTool` | `mcp/sessions_spawn_tool.dart` | Background agent spawning |
| `WebFetchTool` | `mcp/web_fetch_tool.dart` | SSRF-hardened fetch with inline ContentGuard scanning |
| `BraveSearchTool` | `mcp/brave_search_tool.dart` | Brave Search API |
| `TavilySearchTool` | `mcp/tavily_search_tool.dart` | Tavily Search API |
| `SearchProvider` | `mcp/search_provider.dart` | Configurable search backend selection |

SDK extensibility: `server.registerTool(McpTool)` — implement `name`, `description`, `inputSchema`, and `call()`.

Design rationale: [ADR-009 (Internal MCP Server)](../adrs/009-internal-mcp-server.md)

**Package**: `dartclaw_server`

---

## Package Architecture

DartClaw uses a Dart pub workspace with strict dependency layering.

### Dependency DAG

```
dartclaw_models     (zero deps)
       ▲
       │
dartclaw_security   (dartclaw_models + logging + path)
       ▲
       │
dartclaw_core       (dartclaw_models + dartclaw_security + no sqlite3)
       ▲──────────────────────────────────┐
       │                                  │
       ├──── dartclaw_whatsapp            │
       │     (dartclaw_core)              │
       │                                  │
       ├──── dartclaw_signal              │
       │     (dartclaw_core)              │
       │                                  │
       └──── dartclaw_google_chat         │
             (dartclaw_core +             │
              googleapis_auth + http)     │
                                          │
dartclaw_storage    (dartclaw_core + dartclaw_workflow + sqlite3)
       ▲
       │
dartclaw_workflow   (dartclaw_config + dartclaw_core +
                     dartclaw_models + dartclaw_security)
       ▲
dartclaw            (umbrella — re-exports: core, storage,
                     whatsapp, signal, google_chat)

dartclaw_server     (core + storage + config + workflow + security +
                     whatsapp + signal + google_chat + shelf + http)
       ▲
dartclaw_cli        (server + core + all channel packages + args)
```

The `dartclaw` umbrella package re-exports `dartclaw_core`, `dartclaw_storage`, `dartclaw_whatsapp`, `dartclaw_signal`, and `dartclaw_google_chat` for convenience.

### Package Responsibilities

| Package | Owns | Key Constraint |
|---------|------|----------------|
| `dartclaw_models` | `Session`, `Message`, `MemoryChunk`, `SessionKey`, `Task`, `Goal`, `TaskStatus`, `Project`, `ToolCallRecord`, `TaskEvent`, `TaskEventKind` | Zero dependencies — shareable everywhere |
| `dartclaw_security` | `Guard`, `GuardChain`, concrete guards, content classification interfaces, message redaction, guard audit primitives | Isolated security surface — no EventBus or server wiring |
| `dartclaw_core` | `AgentHarness`, channel interfaces/infrastructure, events, file-based services (`SessionService`, `MessageService`, `KvService`, `MemoryFileService`), `EventBus`, workflow/task seams | **No sqlite3, no config parsing, no container orchestration** — shareable with future Flutter app |
| `dartclaw_config` | `DartclawConfig`, typed config sections, `ConfigMeta`, `ConfigValidator`, `ConfigWriter` | Config loading/authoring isolated below core |
| `dartclaw_workflow` | `WorkflowService`, `WorkflowExecutor`, parser/validator, template engine, workflow registry, workflow materialization, `WorkflowDefinition`/`WorkflowRun` models, `SkillIntrospector`, schema presets | Workflow definition + execution package shared by server and CLI. Prod deps: config + core + models + security (storage is a dev-only/test dependency) |
| `dartclaw_whatsapp` | `WhatsAppChannel`, `GowaManager`, media extraction, WhatsApp config registration | Depends only on core — WhatsApp-specific logic isolated |
| `dartclaw_signal` | `SignalChannel`, `SignalCliManager`, sender mapping, Signal config registration | Depends only on core — Signal-specific logic isolated |
| `dartclaw_google_chat` | `GoogleChatChannel`, REST client, GCP auth, Google Chat config registration | Google auth + HTTP deps isolated from core |
| `dartclaw_storage` | `MemoryService` (FTS5), `SearchDb`, `TaskDb`, `TurnStateStore`, `SqliteTaskRepository`, `SqliteGoalRepository`, `MemoryPruner`, `TurnTraceService`, `TaskEventService`, search backends (FTS5, QMD) | sqlite3 dependency isolated here |
| `dartclaw_server` | `DartclawServer`, `TurnManager`, `TurnRunner`, `HarnessPool`, `TaskService`, `TaskExecutor`, `ProjectService`, `TaskEventRecorder`, `AlertRouter`, `CanvasService`, container orchestration, scheduling, behavior/workspace/maintenance/observability services, project API routes, trace query API, workflow HTTP routes, MCP server, web routes, templates, auth | shelf, http, workflow — server-only, not Flutter-compatible |
| `dartclaw_testing` | Shared test doubles and in-memory test helpers (`FakeAgentHarness`, `FakeGuard`, `InMemorySessionService`, `InMemoryTaskRepository`, `TestEventBus`) | Test-only support package; keep production code free of test helpers |
| `dartclaw_cli` | CLI runner, `DartclawApiClient`, connected command groups (`workflow`, `tasks`, `config`, `projects`, `sessions`, `agents`, `traces`, `jobs`), plus local lifecycle/maintenance commands (`serve`, `status`, `init`, `service`, `deploy`, `token`, `rebuild-index`, `sessions cleanup`) | args — application entry point and loopback operations surface |
| `dartclaw` | Umbrella re-export of `dartclaw_core`, `dartclaw_storage`, `dartclaw_whatsapp`, `dartclaw_signal`, `dartclaw_google_chat` | Lean SDK entry point; prefer direct packages for narrower dependency graphs |

### Why These Boundaries?

The critical boundaries are **`dartclaw_core` has no sqlite3 dependency**, **typed config loading now lives in `dartclaw_config`**, and **workflow execution now lives in `dartclaw_workflow`**. This keeps the core runtime (harnesses, shared channel abstractions, events, sessions, messages, governance seams) shareable with a future Flutter desktop/mobile app, while `dartclaw_security`, `dartclaw_config`, `dartclaw_workflow`, and the per-channel packages isolate subsystem-specific code.

`dartclaw_models` is zero-dep so it can be used by any consumer without pulling in runtime machinery.

`dartclaw_security` isolates guard types and content classification primitives so server, CLI, and SDK packages can depend on a narrow security surface without pulling in channel or storage code. It is zero-EventBus — consumers can use guards standalone without the server's event bus.

`dartclaw_storage` isolates the sqlite3 native dependency (FFI, platform-specific binary) — only packages that actually query SQLite need this.

Channel packages (`dartclaw_whatsapp`, `dartclaw_signal`, `dartclaw_google_chat`) isolate their heavy transitive dependencies — a consumer using only WhatsApp does not pull in Google Cloud libraries.

`dartclaw_server` is `publish_to: none` — it contains the HTTP server, templates, and application logic that SDK consumers don't need.

Design rationale: [ADR-008 (SDK Publishing Strategy)](../adrs/008-sdk-publishing-strategy.md), [ADR-010 (Package Split — Models)](../adrs/010-package-split-models.md), [ADR-014 (SDK Package Decomposition)](../adrs/014-sdk-package-decomposition.md), [ADR-020 (Package Decomposition Phase 2)](../adrs/020-package-decomposition-phase-2.md)

---

## The JSONL Control Protocol

This section summarizes the Claude Code protocol. Codex app-server uses bidirectional JSON-RPC JSONL instead; see [Control Protocol & Harness Architecture](control-protocol.md) for the multi-provider comparison and the Codex lifecycle.

### Message Types

**Host → claude stdin:**

| Type | Purpose |
|------|---------|
| `user` | User message (starts a turn) |
| `control_response` | Response to a `control_request` (hook verdict, MCP tool result, permission decision) |

**claude stdout → host:**

| Type | Purpose |
|------|---------|
| `system:init` | Session ID, available tools, context window size |
| `stream_event` | Text deltas, tool use blocks, tool results (real-time) |
| `assistant` | Complete assistant message (after turn completes) |
| `result` | Turn result with token counts |
| `control_request` | Hook callback, tool approval, MCP tool call |

### Control Request Subtypes

| Subtype | Direction | Purpose |
|---------|-----------|---------|
| `initialize` | Host → binary | Register hooks, MCP servers, system prompt |
| `hook_callback` | Binary → host | `PreToolUse`/`PostToolUse` evaluation |
| `can_use_tool` | Binary → host | Tool approval (when `--permission-prompt-tool stdio`) |
| `mcp_message` | Binary → host | MCP tool invocation (JSONRPC proxied over control protocol) |

Request-response correlation uses `request_id` fields. The Dart host multiplexes concurrent control requests using a `Map<String, Completer>`.

### Spawn Command

```
claude --print --input-format stream-json --output-format stream-json \
       --verbose --include-partial-messages --no-session-persistence \
       --permission-prompt-tool stdio --model <model>
       [--directory <worktree-path>]
       [--mcp-config <temp-file-path>]
```

Environment: `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, and `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` are cleared to prevent nesting detection.

---

## Deployment Model

### Single-User, Single-Binary

DartClaw targets one user, one deployment. AOT-compiled to a single native binary via `dart compile exe`. No Node.js, no npm, no Deno at runtime.

Runtime dependencies:
- `claude` CLI binary (~185-234 MB, Bun standalone — installed via `curl -fsSL https://claude.ai/install.sh | bash`)
- `codex` CLI binary (required for `codex` workers)
- Docker (OrbStack on macOS, native Engine on Linux) — for container isolation
- SQLite (system library) — for search index and task persistence
- Channel sidecars (optional): GOWA binary (WhatsApp), signal-cli (Signal)

### Claude Container Isolation Topology

```
Host OS
  ├── dartclaw binary (Dart AOT)
  │     ├── HTTP server (port 3000)
  │     ├── CredentialProxy (Unix socket)
  │     └── Container orchestrator
  │
  ├── Docker: dartclaw-<id>-workspace
  │     ├── claude binary (docker exec per turn)
  │     ├── /workspace:rw mount
  │     ├── /project:ro mount
  │     ├── socat → Unix socket proxy
  │     └── network:none, cap-drop=ALL, read-only rootfs
  │
  ├── Docker: dartclaw-<id>-restricted
  │     ├── claude binary (docker exec per turn)
  │     ├── No workspace mount
  │     ├── socat → Unix socket proxy
  │     └── network:none, cap-drop=ALL, read-only rootfs
  │
  ├── GOWA sidecar (optional, Go binary)
  └── signal-cli sidecar (optional, Java)
```

Credential flow: API keys live on the host. The `CredentialProxy` listens on a Unix socket, injecting credentials into API requests. Containers mount the socket directory and use `ANTHROPIC_BASE_URL=http+unix:///var/run/proxy.sock` to route API calls through the proxy. Credentials never exist inside Claude container environments.

Codex does not use this proxy path in 0.13. Both shipped Codex harnesses run as direct subprocesses and receive `OPENAI_API_KEY` via environment injection instead.

### Dev Mode

When `container.enabled: false`, all harnesses run as direct subprocesses on the host (no Docker). Guards still evaluate, but there is no OS-level isolation boundary. Acceptable for local development.

---

## Runtime Governance

Runtime governance protects deployments from cost overruns, abuse, and runaway agent behavior. It is configured under the `governance:` YAML section and enforced across two integration points.

### Components

| Component | Package | Role |
|-----------|---------|------|
| `GovernanceConfig` | `dartclaw_config` | Parsed governance schema: rate limits, budget, loop detection |
| `RateLimitsConfig` | `dartclaw_config` | Per-sender + global rate limit sub-config |
| `BudgetConfig` | `dartclaw_config` | Daily token budget sub-config: threshold, action, timezone |
| `LoopDetectionConfig` | `dartclaw_config` | Loop detection thresholds and action |
| `TurnProgressConfig` | `dartclaw_config` | Stall-timeout sub-config: `stall_timeout` and `stall_action` |
| `SlidingWindowRateLimiter` | `dartclaw_core` | In-memory sliding window rate limiter utility |

### Integration Points

**Per-sender rate limiting** (enforced in `ChannelTaskBridge.tryHandle()`):
- Applies after thread binding check, before review command or task trigger routing
- Keyed by sender JID
- Rejects excess messages with a polite "too fast" response and returns `true` (consumed — not enqueued)
- Exempt: admin senders, review commands (`accept`, `reject`, `push back`), reserved commands (`/status`, `/stop`)
- Note: thread-bound task replies bypass per-sender rate limiting once routing is resolved. This keeps a shared task thread conversational while global turn limits still cap aggregate work.

**Global turn rate limiting** (enforced in `TurnRunner.reserveTurn()`):
- Applies across all sessions and senders combined
- Defers turn reservation (waits for window capacity) rather than rejecting
- Emits SSE `rate_limit_warning` event at 80% usage; resets hysteresis below 60%

**Daily token budget enforcement** (enforced in `TurnRunner` via `BudgetEnforcer`):
- Configured by `governance.budget.daily_tokens`, `action`, and `timezone`
- Posts a budget warning once per day when usage reaches 80% of the configured budget
- At 100%, either logs and allows (`warn`) or blocks new turns until the next budget window (`block`)
- Uses KvService-backed daily usage summaries so the warning state survives restarts

**Loop detection** (enforced in `TurnRunner` via `LoopDetector`):

| Mechanism | What it detects | Default threshold |
|-----------|-----------------|-------------------|
| **Turn chain depth** | Consecutive autonomous turns without human input | 5 |
| **Token velocity** | Sustained token burn within a rolling window | 10,000 tokens/min over 2 minutes |
| **Tool fingerprinting** | Repeated identical tool calls (`tool_name` + canonical args hash) | 5 consecutive |

- Actions: `abort` fails the active turn/task; `warn` emits observability events but allows execution to continue
- Human input resets the autonomous-turn counter, which keeps intentional pause/resume and reviewer feedback from looking like loops
- All loop-detection state is intentionally in-memory; a restart clears counters just as it clears active execution state

**Turn-progress stall detection** (enforced in `TurnRunner` via `TurnProgressMonitor`):
- Configured by `governance.turn_progress.stall_timeout` and `governance.turn_progress.stall_action`
- Resets only on forward-progress bridge events: `DeltaEvent`, `ToolUseEvent`, and `ToolResultEvent`
- Actions: `warn` emits SSE `turn_progress_stall`, `cancel` aborts the active turn, `ignore` logs only
- Uses the same progress signals as `SessionResetService.touchActivity()`, so long-running tool execution refreshes session activity without weakening stall detection

### Admin Sender Model

`governance.admin_senders` lists sender IDs exempt from per-sender rate limits. When the list is empty (default), **all senders are treated as admins** — suitable for single-user deployments. When non-empty, only the listed IDs are exempt.

### Rate Limiter Design

`SlidingWindowRateLimiter` uses lazy eviction (expired entries removed on `check()` calls — no background timers). `check()` both verifies and records the event atomically: a passing check records; a failing check does not. This makes it safe to use in deferral retry loops without self-inflating the counter.

### Configuration

```yaml
governance:
  admin_senders: []           # empty = all are admins
  rate_limits:
    per_sender:
      messages: 10            # 0 = disabled
      window: 5m              # supports 30s, 5m, 1h etc.
    global:
      turns: 60               # 0 = disabled
      window: 1h
  budget:
    daily_tokens: 100000      # 0 = disabled
    action: warn              # warn or block
    timezone: UTC
  loop_detection:
    enabled: false
    max_consecutive_turns: 0
    max_tokens_per_minute: 0
    velocity_window_minutes: 5
    max_consecutive_identical_tool_calls: 0
    action: abort
```

Missing `governance:` section → all defaults (all disabled).

---

### Emergency Controls

Emergency controls are admin-only command paths for immediate intervention. Google Chat exposes them as slash commands; other channels reach the same handlers through reserved message prefixes.

**`/stop`**
- Executes `EmergencyStopHandler`, which aborts all active turns and cancels running or queued tasks in a best-effort sequence
- Returns counts for cancelled turns and tasks so the operator gets an explicit outcome
- Failures are logged per item and do not stop cancellation of the remaining work

**`/pause`**
- Sets `PauseController.isPaused = true`
- Queues inbound non-reserved messages in memory (default cap: 200) while preserving their resolved session key, including bound task-thread routes
- Acknowledges queued messages immediately; once the queue is full, new inbound messages are rejected with a pause-capacity warning

**`/resume`**
- Drains the pause queue by session key, then groups messages by sender within each session into one collapsed human-input message
- Delivers one synthesized turn per session, which both preserves task-thread routing and resets autonomous-turn loop counters
- Returns a summary of how many queued messages and sessions were resumed

**Admin enforcement**
- `governance.admin_senders` defines which sender IDs may invoke emergency controls
- Empty list = every sender is treated as admin (backward-compatible single-operator default)
- Non-empty list = only exact sender IDs are privileged; this applies consistently across Google Chat, WhatsApp, and Signal

---

## Service Wiring

`ServiceWiring` (in `dartclaw_cli`) is the dependency injection root. It constructs all services, wires them together, and returns a `WiringResult` containing everything `ServeCommand.run` needs.

### Construction Order (simplified)

```
1.  Config parsing (DartclawConfig from YAML)
2.  Config notifier (`ConfigNotifier`) for reloadable sections
3.  File services (SessionService, MessageService, KvService)
4.  SQLite databases (SearchDb, TaskDb, TurnStateStore/state.db)
5.  Search backends (FTS5, optional QMD)
6.  Memory services (MemoryFileService, MemoryService, SelfImprovementService)
7.  Security (GuardChain, concrete guards, `InputSanitizer`, `MessageRedactor`, and `GuardAuditLogger` from `dartclaw_security`; guard config + `GuardBlockEvent` from `dartclaw_core`; guard verdict wiring + `GuardAuditSubscriber` from `dartclaw_server`)
8.  Container managers (per-profile: workspace, restricted)
9.  Agent harnesses (ClaudeCodeHarness × maxConcurrent)
10. Turn runners (TurnRunner × harness count)
11. Harness pool (HarnessPool wrapping turn runners)
12. Event bus + subscribers
13. Channels (dartclaw_whatsapp, dartclaw_signal, dartclaw_google_chat — if configured)
14. Scheduling (HeartbeatScheduler, ScheduleService)
15. Task orchestrator (TaskService, TaskExecutor)
16. Project management (ProjectService, RemotePushService)
17. Workflow engine (WorkflowRegistry, WorkflowService, WorkflowExecutor)
18. Alert routing (AlertRouter, AlertDeliveryAdapter — if alerts configured)
19. Canvas (CanvasService, WorkshopCanvasSubscriber — if canvas configured)
20. MCP server (register tools: memory, sessions_send, web_fetch, search)
21. DartclawServer (shelf handler assembly, page registration)
22. Reload triggers (`ReloadTriggerService`) for `SIGUSR1` / file-watch hot-reload
```

All services are single-instance, single-threaded. Isolates are avoided unless profiling shows a bottleneck.

---

## Cross-References

### Architecture Documents

| Document | Path | Content |
|----------|------|---------|
| Control protocol & harness | [`dev/architecture/control-protocol.md`](control-protocol.md) | JSONL protocol spec, multi-provider comparison, harness pool lifecycle |
| Security architecture | [`dev/architecture/security-architecture.md`](security-architecture.md) | Defense-in-depth model, guard pipeline, container isolation, credential security |
| Data model & persistence | [`dev/architecture/data-model.md`](data-model.md) | Entity models, storage zones, write safety, rotation |
| Workflow architecture | [`dev/architecture/workflow-architecture.md`](workflow-architecture.md) | Workflow engine deep-dive: parser, executor, skill system, map/fan-out |
| CLI & API architecture | [`dev/architecture/cli-api-architecture.md`](cli-api-architecture.md) | CLI runner, loopback API client, command groups, connected-vs-standalone execution, route mapping |
| Channel & messaging | [`dev/architecture/channel-messaging-architecture.md`](channel-messaging-architecture.md) | Channel abstractions, inbound pipeline, thread binding, outbound routing |
| Task & execution | [`dev/architecture/task-execution-architecture.md`](task-execution-architecture.md) | Task orchestrator, worktree lifecycle, review flows, project dispatch |
| Configuration | [`dev/architecture/configuration-architecture.md`](configuration-architecture.md) | Three-tier config, hot-reload, ConfigNotifier, Reconfigurable pattern |
| Observability & operations | [`dev/architecture/observability-operations-architecture.md`](observability-operations-architecture.md) | Turn traces, task events, alert routing, scheduling, canvas |
| Session & state management | [`dev/architecture/session-state-architecture.md`](session-state-architecture.md) | Session lifecycle, scoping, locks, pause/resume, crash recovery |
| Architecture governance | [`dev/architecture/architecture-governance.md`](architecture-governance.md) | Fitness functions, structural boundaries, update rules, and governance scope |
| Roadmap | [`docs/ROADMAP.md`](../ROADMAP.md) | Milestones, status, success criteria |
| Feature comparison | [`docs/specs/feature-comparison.md`](../specs/feature-comparison.md) | OpenClaw vs NanoClaw vs DartClaw |
| Product Backlog | [`docs/PRODUCT-BACKLOG.md`](../PRODUCT-BACKLOG.md) | Deferred/future features with rationale |
| Learnings | [`dartclaw-public/dev/state/LEARNINGS.md`](../../../dartclaw-public/dev/state/LEARNINGS.md) | Traps, gotchas, non-obvious patterns |
| User-facing architecture overview | [`docs/guide/architecture.md`](../../docs/guide/architecture.md) | Operator-oriented 2-layer overview |

### Key ADRs

| ADR | Decision |
|-----|----------|
| [ADR-001](../adrs/001-sdk-integration-and-security-architecture.md) | 2-layer architecture: Dart → claude binary via JSONL (replaced 3-layer Dart → Deno → claude) |
| [ADR-002](../adrs/002-file-based-storage.md) | File-based storage for sessions/messages; SQLite only for search index and tasks |
| [ADR-005](../adrs/005-whatsapp-integration.md) | WhatsApp via GOWA (Go/whatsmeow) sidecar — outpost pattern |
| [ADR-007](../adrs/007-system-prompt-architecture.md) | System prompt via `--append-system-prompt` — preserve Claude Code built-in prompt |
| [ADR-008](../adrs/008-sdk-publishing-strategy.md) | SDK publishing strategy — 5-package structure, barrel narrowing |
| [ADR-009](../adrs/009-internal-mcp-server.md) | Internal MCP server at `/mcp` for tool extensions |
| [ADR-011](../adrs/011-event-driven-architecture.md) | Lightweight event bus with sealed class hierarchy |
| [ADR-012](../adrs/012-per-type-container-isolation.md) | Per-security-profile containers (workspace + restricted) |
| [ADR-014](../adrs/014-sdk-package-decomposition.md) | Package decomposition strategy — extract security and channel packages while keeping core sqlite3-free |
| [ADR-016](../adrs/016-multi-provider-harness-architecture.md) | Multi-provider harness architecture — abstract harness + protocol adapter for Claude and Codex |
| [ADR-017](../adrs/017-multi-project-architecture.md) | Multi-project architecture — config-seeded + API-managed project registry, Isolate git ops |
| [ADR-018](../adrs/018-cli-onboarding-architecture.md) | CLI onboarding architecture |
| [ADR-019](../adrs/019-tui-cli-package-selection.md) | TUI CLI package selection |
| [ADR-020](../adrs/020-package-decomposition-phase-2.md) | Package decomposition phase 2 — workflow package extraction |

### Diagrams

Architecture diagrams are maintained as Excalidraw source files in [`docs/diagrams/`](../diagrams/). Rendered PNGs in `docs/diagrams/renders/` are gitignored and regenerable.

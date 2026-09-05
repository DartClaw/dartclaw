# DartClaw System Architecture Overview

Canonical reference for understanding how DartClaw works. Covers the 2-layer runtime model, all major subsystems, package structure, and how they connect.

**Current through**: 0.25 security posture corrections, guarded MCP dispatch, capacity-only lane retirement, kernel formation, and storage absorption.

---

## Design Philosophy

Five principles shape every architectural decision:

| Principle | Meaning |
|-----------|---------|
| **Minimal attack surface** | No Node.js/npm in the chain. Fewer dependencies = fewer supply chain vulnerabilities. Prefer capable standard libraries over third-party packages |
| **Dart as host** | AOT-compiled native binary, complete built-in toolchain (formatter, analyzer, linter, test runner), capable stdlib. No external toolchain dependencies |
| **Direct control protocol** | Dart spawns native provider binaries directly (`claude`, `codex`, or ACP agents such as Goose/Vibe), no intermediate runtime. All state/storage/security lives in Dart |
| **Outpost pattern** | Purpose-built CLI tools in the best language for the job (Go for WhatsApp, Python for ML/NLP), invoked as subprocesses with structured JSON I/O. No shared runtime, no dependency contamination |
| **Auditable** | Dependencies stay minimal and every subsystem has one owner. 156,183 production LOC across 858 `lib/` Dart files at the 0.25 close, excluding generated Dart, tests and tooling — no longer one context window, which is what the per-package LOC ceilings and the context map exist to keep navigable |

See also: [Roadmap — Core Philosophy](../state/ROADMAP.md)

---

## System Overview

DartClaw is a **2-layer agent runtime**. The Dart host is the control plane (full trust); `claude`, `codex`, and configured ACP agent binaries are execution-plane providers with provider-specific security boundaries.

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
│  Owns: LLM reasoning, tool execution through the active provider   │
│        boundary, context management, streaming, prompt caching     │
│  Runtime: `claude`, `codex`, and ACP agent binaries such as Goose  │
│           or Vibe                                                  │
│  Trust: PROVIDER-BOUND — Claude can run in Docker; Codex uses      │
│         approval/sandbox controls; ACP depends on topology         │
└─────────────────────────────────────────────────────────────────────┘
```

**Key insight**: The provider binaries are _not_ called via the TypeScript Agent SDK. Dart reimplements the provider-specific control boundaries directly, eliminating the Deno/TypeScript middleman. Claude uses bidirectional JSONL, Codex uses bidirectional JSON-RPC JSONL, and ACP agents use stdio JSON-RPC; see [Control Protocol & Harness Architecture](control-protocol.md). The original Claude path was validated by reverse-engineering the protocol from official SDKs in Python, Go, and Elixir (see [ADR-001](../adrs/001-sdk-integration-and-security-architecture.md)).

### What Each Layer Owns

| Concern | Layer 1 (Dart Host) | Layer 2 (Execution-Plane Providers) |
|---------|--------------------|-----------------------|
| State | Sessions, messages, memory, tasks, config, audit logs | Stateless (no session persistence) |
| Security | Guard chain, container orchestration, host gateway mediation, audit | Tool execution inside the active provider boundary |
| Networking | HTTP server, SSE streaming, channel webhooks, MCP endpoint | Constrained by the active boundary (Claude container or Codex sandbox/runtime) |
| Agent logic | Turn orchestration, prompt composition, hook/reverse-call evaluation, logical-agent session admission | LLM reasoning, tool selection and execution inside the provider boundary |
| Credentials | Owns all API keys; container executions reach their provider only through the host gateway, host executions receive their provider-scoped credential directly, and an ACP registration (host-only) receives nothing unless it names a `credential:` API key | Provider binaries receive only the credentials required for their family |

Design rationale: [ADR-001 (SDK Integration & Security Architecture)](../adrs/001-sdk-integration-and-security-architecture.md)

Provider-specific credential and interception details live in [Security Architecture](security-architecture.md). Protocol details live in [Control Protocol & Harness Architecture](control-protocol.md).

### Platform Capability Surface

`dartclaw_kernel` owns the immutable `PlatformCapabilities` policy surface defined by
[ADR-049](../adrs/049-typed-platform-capability-surface.md). Consumers query this surface instead of scattering raw
operating-system checks across lifecycle, workflow, reload, and isolation code. It covers:

- home-directory resolution with `HOME` then `USERPROFILE` fallback;
- executable search candidates derived from injected `PATH`/`PATHEXT`, with empty entries excluded so lookup never implies the current directory;
- trusted absolute Windows system-helper paths with a minimal environment;
- Bash shell policy and POSIX signal/file-permission availability;
- process-termination semantics and container-isolation availability; and
- `UnsupportedCapabilityError`, which names the capability, attempted context, and remediation.

The Windows constraints are explicit:

| Area | Native Windows contract |
|---|---|
| Process lifecycle | Directly managed root-handle hard termination with bounded exit observation; no SIGTERM-to-SIGKILL or descendant-containment claim |
| Config reload | `gateway.reload.mode: auto` uses debounced file watching; SIGUSR1 is POSIX-only |
| Storage/search | Release bundles carry FTS5-enabled `lib/sqlite3.dll`; DartClaw does not use system `winsqlite3.dll` |
| Bash workflow steps | Git Bash is required and selected through executable lookup; absence is an explicit failed step |
| Container isolation | Unavailable and fail-closed; remediation points to a POSIX host or WSL |

The capability value is deterministic policy only. Consumers retain ownership of subprocess I/O, executable lookup,
and context-specific remediation text.

---

## Component Map

```
┌───────────────────────────────────────────────────────────────────────────┐
│                           Dart Host Process                              │
│                                                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ Web UI      │  │ REST API    │  │ MCP Server   │  │ Channel       │  │
│  │ (Trellis +  │  │ (shelf)     │  │ (/mcp)       │  │ Ingress       │  │
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
│  │          │  │ ExecutionCoordinator · locks │  │ WorktreeManager    │ │
│  └────┬─────┘  └──────────────┬───────────────┘  │ DiffGenerator      │ │
│       │                       │                   │ MergeExecutor      │ │
│       │        ┌──────────────▼───────────────┐   └────────┬───────────┘ │
│       │        │ HarnessFactory (core)         │            │             │
│       │        │ ProtocolAdapter (core)        │            │             │
│       │        │ ClaudeProtocolAdapter        │            │             │
│       │        │ CodexProtocolAdapter         │            │             │
│       │        │ AcpProtocolAdapter (acp)     │            │             │
│       │        │ ClaudeCodeHarness             │◄───────────┘             │
│       │        │ CodexHarness                  │                          │
│       │        │ AcpHarness (dartclaw_acp)     │                          │
│       │        └──────────────┬───────────────┘                          │
│       │                       │                                          │
│  ┌────▼─────┐  ┌──────────────▼───────────────┐  ┌────────────────────┐ │
│  │ Guard    │  │ Security & Isolation          │  │ Storage            │ │
│  │ Chain    │  │ ContainerManager(s)           │  │ Files: NDJSON/JSON │ │
│  │ Cmd/File │  │ CredentialRegistry            │  │ SQLite: search.db  │ │
│  │ Net/Cont │  │ HostGateway (per authority)   │  │         tasks.db   │ │
│  │          │  │ Docker (per authority)        │  │         state.db   │ │
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
│  │ ProjectService           │  │ RunnerObserver                        │  │
│  │ RemotePushService        │  │ TurnTraceService · TaskEventService  │  │
│  │ PrCreator · Isolate git  │  │ TaskEventRecorder                    │  │
│  └──────────────────────────┘  └──────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────────┐                                            │
│  │ Workflow Engine           │                                            │
│  │ WorkflowExecutor          │                                            │
│  │ WorkflowRegistry          │                                            │
│  │ DefinitionParser          │                                            │
│  │ SkillIntrospector         │                                            │
│  └──────────────────────────┘                                            │
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
│  ACP path (stdio JSON-RPC):                                               │
│    ├── AcpHarness + AcpClient                                             │
│    ├── Direct-provider targets can be guard-mediated after verification   │
│    └── Relay or unverified targets are unavailable (host-only ACP)        │
│                                                                          │
│  Sidecar binaries (outpost pattern):                                     │
│    ├── GOWA (Go) — WhatsApp Web protocol                                │
│    └── signal-cli — Signal protocol                                     │
└───────────────────────────────────────────────────────────────────────────┘
```

### Subsystem Details

#### Agent Harness

The harness layer is the interface between the Dart host and the execution-plane provider binaries. `AgentHarness` is an abstract class; `HarnessFactory` selects the provider family; `ProtocolAdapter` is the abstract wire-format boundary. `ClaudeCodeHarness`, `CodexHarness`, and `AcpHarness` are the production implementations.

| Component | File | Role |
|-----------|------|------|
| `AgentHarness` | `packages/dartclaw_core/lib/src/harness/agent_harness.dart` | Abstract interface: `start()`, `turn()`, `cancel()`, `stop()`, `dispose()` |
| `HarnessFactory` | `packages/dartclaw_core/lib/src/harness/harness_factory.dart` | Provider creation point that resolves the provider family and returns the matching harness and protocol adapter |
| `ProtocolAdapter` | `packages/dartclaw_core/lib/src/harness/protocol_adapter.dart` | Abstract protocol boundary for provider-specific wire formats |
| `ClaudeProtocolAdapter` | `packages/dartclaw_core/lib/src/harness/claude_protocol_adapter.dart` | Claude-specific adapter for bidirectional JSONL control protocol |
| `CodexProtocolAdapter` | `packages/dartclaw_core/lib/src/harness/codex_protocol_adapter.dart` | Codex adapter for bidirectional JSON-RPC JSONL |
| `AcpProtocolAdapter` | `packages/dartclaw_acp/lib/src/acp_protocol_adapter.dart` | ACP session update adapter for stdio JSON-RPC agents |
| `ClaudeCodeHarness` | `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart` | Spawns `claude` binary, manages JSONL I/O, implements the Claude control protocol |
| `CodexHarness` | `packages/dartclaw_core/lib/src/harness/codex_harness.dart` | Spawns `codex` binary, manages JSON-RPC JSONL I/O, implements the Codex control protocol |
| `AcpHarness` | `packages/dartclaw_acp/lib/src/acp_harness.dart` | Spawns configured ACP agent binaries, manages stdio JSON-RPC lifecycle, and delegates reverse-calls to guarded host handlers |
| `AcpClient` | `packages/dartclaw_acp/lib/src/acp_client.dart` | Minimal ACP JSON-RPC client used by `AcpHarness` |
| `AcpReverseCallHandlers` | `packages/dartclaw_acp/lib/src/acp_reverse_call_handlers.dart` | Binds ACP filesystem reverse-calls to the active session and maps them to canonical guarded host tools |
| `ClaudeProtocol` | `packages/dartclaw_core/lib/src/harness/claude_protocol.dart` | Sealed class hierarchy for Claude JSONL message parsing (`SystemInit`, `StreamTextDelta`, `ToolUseBlock`, `ControlRequest`, etc.) |
| `HarnessConfig` | `packages/dartclaw_core/lib/src/harness/harness_config.dart` | Per-harness configuration: model, max turns, disallowed tools, MCP config |
| `ToolPolicyCascade` | `packages/dartclaw_core/lib/src/harness/tool_policy.dart` | 3-layer tool approval: global deny, agent deny, sandbox allow |
| `BridgeEvent` | `packages/dartclaw_core/lib/src/bridge/bridge_events.dart` | Typed stream events for consumers (text deltas, tool activity, results) |
| `NdjsonChannel` | `packages/dartclaw_acp/lib/src/ndjson_channel.dart` | NDJSON line splitting and framing over `stdin`/`stdout` |

The Claude `initialize` control-protocol handshake registers hooks, MCP servers, and system prompt. Hook callbacks (`PreToolUse`/`PostToolUse`) and MCP tool calls (`mcp_message`) are handled in-process by the Dart host, with request-response correlation via `request_id`. ACP agents use stdio JSON-RPC instead: `AcpHarness` owns the subprocess, `AcpClient` owns request correlation, and filesystem reverse-calls are bound to the active host session and evaluated through the same guard chain before host work. ACP terminal reverse-calls are disabled. For protocol details, see [Control Protocol & Harness Architecture](control-protocol.md).

**Packages**: `dartclaw_core` owns the common contracts plus Claude and Codex; `dartclaw_acp` owns the ACP implementation.

#### Turn Orchestration

Turn orchestration coordinates message flow from user input through guard evaluation, harness execution, and response persistence.

| Component | File | Role |
|-----------|------|------|
| `TurnManager` | `turn_manager.dart` | Entry point for turns after routing. Acquires an execution lease and delegates to `TurnRunner` |
| `TurnRunner` | `turn_runner.dart` | Per-harness turn engine: guard evaluation, message persistence, SSE event streaming, progress-aware stall handling, cost tracking, crash recovery |
| `TurnLivenessTracker` | `turn_liveness_tracker.dart` | One per-turn tracker for waiting/stuck observations and stall enforcement. Forward-progress events reset it; known approval waits suspend only the stall budget |
| `ExecutionCoordinator` | `execution_coordinator.dart` | Post-governance authority: one fixed serialized primary lane for main user/channel turns; hard per-provider worker leases for tasks, scheduled/system work, logical agents, and workflow steps |
| `SessionMutationCoordinator` | `concurrency/session_mutation_coordinator.dart` | Per-session promise chain that runs operations in arrival order; one instance orders `TurnManager` reservations, another the API's session mutations |
| `SessionLockManager` | `concurrency/session_lock_manager.dart` | Per-session lock with a global cap; orders the callers that have reached `acquire` |
| `ContextMonitor` | `context/context_monitor.dart` | Tracks context window usage; suppresses heuristic flush when deterministic compaction signals exist; deduplicates pre-compaction flushes per cycle; emits SSE `context_warning` when usage exceeds configurable threshold (one-shot per session) |
| `ResultTrimmer` | `context/result_trimmer.dart` | Head+tail truncation with a `...[trimmed N bytes]...` marker, applied by `McpProtocolHandler` to the successful text result of every `tools/call` it dispatches, outbound MCP relays included |
| `CompactionTaskEventSubscriber` | `task/compaction_task_event_subscriber.dart` | Listens for `CompactionCompletedEvent` and records a `compaction` task-timeline event when the compacted session belongs to an active running task |

`providers.<id>.pool_size` is the hard concurrent worker-lease limit for that provider, not a target runner count.
Workers are created on demand. After release, a healthy idle worker may be retained and reused only when its
provider and security profile match within the immutable coordinator composition; the exact prior session is preferred. Reuse is
an optimization, never the capacity authority. Provider/profile containers have their own lifecycle and may be shared by
multiple workers, so container count and worker capacity are independent.

**Context management strategy** (0.10): Layered mechanisms preserve useful context in long-running sessions:
1. **Compact instructions** — `BehaviorFileService.composeSystemPrompt()` appends a `# Compact instructions` section for long-running session types (web, DM, group, cron), guiding the binary on what to preserve during auto-compaction. Configurable via `context.compact_instructions`.
2. **Tool-result cap** — `ResultTrimmer` bounds the text every tool registered on the MCP handler returns over `tools/call` at `context.max_result_bytes` (default 50KB), inserting a `...[trimmed N bytes]...` marker so the model reads the result as truncated. Nothing reshapes the assistant's own reply.
3. **Context warning** — `ContextMonitor.checkThreshold()` emits an SSE `context_warning` event when usage exceeds `context.warning_threshold` (default 80%, live-mutable). One-shot per session; web UI renders a dismissable banner.
4. **Compaction observability** (0.16) — provider compaction signals now flow into the shared event model. Claude emits `CompactionStartingEvent` from `PreCompact` and `CompactionCompletedEvent` from `compact_boundary`; Codex parses `contextCompaction` items into bridge events. `ContextMonitor` advances its compaction cycle on completion, pre-compaction flushes are SHA-256 deduplicated, and running task sessions record a `compaction` timeline event.

**Progress-aware turn liveness**: `TurnRunner` treats `DeltaEvent`, `ToolUseEvent`, and `ToolResultEvent` as forward progress. `TurnLivenessTracker` resets only on those events, not on `SystemInitEvent`, so long-running turns with steady tool activity do not trip a false stall timeout. Known approval waits suspend the stall clock, while the wall-clock turn limit continues. The same forward-progress events also call `SessionResetService.touchActivity()` so idle-session maintenance follows actual harness activity rather than wall-clock turn duration.

**Package**: `dartclaw_runtime`

#### Channels

Channels normalize external messaging platforms behind shared core abstractions. WhatsApp and Signal use outpost binaries; Google Chat integrates directly over HTTP.

| Channel | Sidecar | Protocol | Session Keying |
|---------|---------|----------|----------------|
| **WhatsApp** | GOWA (Go/whatsmeow) | REST + webhooks | `dmPerChannelContact()` / `groupShared()` |
| **Signal** | signal-cli | JSON-RPC + SSE events | `dmPerChannelContact()` / `groupShared()` |
| **Google Chat** | None (pure REST) | Inbound webhook + REST API | `dmPerChannelContact()` / `groupShared()` |

Common infrastructure:

| Component | File | Role |
|-----------|------|------|
| `Channel` | `channel/channel.dart` | Abstract interface for lifecycle, delivery, response formatting, and optional typing feedback |
| `ChannelManager` | `channel/channel_manager.dart` | Routes inbound messages to sessions, derives session keys from scope config, preserves routed session context during pause, and delegates task-aware interception to `ChannelTaskBridge` before normal `MessageQueue` enqueue |
| `DmAccessController` | `channel/dm_access.dart` | Unified access control: pairing, allowlist, open, disabled modes |
| `MessageQueue` | `channel/message_queue.dart` | Per-session FIFO with debouncing (1000ms default) and global concurrency cap. Preserves channel-specific reply metadata on outbound chunks and can attach a `TurnObserver` for channel-specific in-flight feedback |
| `SessionScopeConfig` | `scoping/session_scope_config.dart` | Configurable DM/group scope with per-channel overrides (5 DM + 3 group modes) |
| `GroupEntry` | `scoping/group_entry.dart` | Structured group allowlist entry with optional `name`, `project`, `model`, `effort` overrides. Parsed by `GroupEntry.parseList()` which accepts mixed string/map YAML |
| `GroupConfigResolver` | `scoping/group_config_resolver.dart` | Lookup service keyed by `(ChannelType, groupId)`. Constructed in `ChannelWiring` from per-channel allowlists. Used by `resolveChannelTurnOverrides()` (model/effort precedence tier) and `ChannelTaskBridge` (project binding) |
| `TaskOrigin` | `channel/task_origin.dart` | Persisted metadata linking a task back to its originating channel contact (`channelType`, `sessionKey`, `recipientId`, `contactId`) |
| `ThreadBinding` | `channel/thread_binding.dart` | Immutable model: `(channelType, threadId) → (taskId, sessionKey)`. Key: `"<channelType>::<threadId>"`. Fields: `createdAt`, `lastActivity` |
| `ThreadBindingStore` | `channel/thread_binding.dart` | In-memory `Map<String, ThreadBinding>` with JSON persistence to `thread-bindings.json`. CRUD + `reconcile()` (prunes bindings for terminal tasks on startup) |

Design rationale: [ADR-005 (WhatsApp Integration)](../adrs/005-whatsapp-integration.md)

**Package**: `dartclaw_core` (interfaces, `DmAccessController`, `ChannelManager`), `dartclaw_whatsapp`, `dartclaw_signal`, `dartclaw_google_chat` (channel implementations), `dartclaw_runtime` (webhook routes, pairing UI)

#### Inbound Message Pipeline

Channel adapters normalize platform-specific payloads into `ChannelMessage` before any session routing begins. Google
Chat contributes thread metadata (`thread.name`), sender display name, and avatar URL; WhatsApp and Signal contribute
equivalent sender/contact metadata through the same DTO shape. The routing stack then composes pause handling,
governance, thread binding, and ordinary session routing. Thread binding is opt-in: the runtime creates its store and
wires binding behavior only when `features.thread_binding.enabled` is true.

**Stage 1 — `ChannelManager.handleInboundMessage()`**

1. Resolve the owning `Channel`.
2. Derive the default session key from the current live scope config.
3. Look up an existing thread binding and compute the routed session key early.
4. If the runtime is paused and the message is not a reserved command, enqueue it in `PauseController` using the already-resolved session key so bound-thread messages resume to the correct task session.
5. Delegate task-aware interception to `ChannelTaskBridge.tryHandle()`.
6. If nothing consumes the message, enqueue it to the normal `MessageQueue`.

##### Thread Binding Routing

**Stage 2 — `ChannelTaskBridge.tryHandle()` routing precedence**

1. Bridge-reserved text commands: `/stop`, `/pause`, `/resume`, `/bind`, and `/unbind`.
2. Thread-binding resolution: capture bound task/session context when a thread ID maps to a `ThreadBinding`.
3. Per-sender rate limit check: reject excess non-admin, non-reserved traffic with a polite response.
4. Bound-thread routing: enqueue the message directly to the bound task session and update `lastActivity`.
5. Fall through: route to the default shared or scoped session via `MessageQueue`.

Design rationale:
- Reserved commands stay ahead of pause and rate limiting so operators can always recover the runtime.
- Thread-binding lookup happens before rate limiting so the bridge preserves the task-session context.
- Thread binding now supports multiple bindings per task. Google Chat binds a concrete thread, while WhatsApp and Signal bind the whole group conversation via explicit `/bind`.

**Outbound channel notifications**

- `TaskNotificationSubscriber` posts lifecycle updates back to the originating channel for tasks carrying a `TaskOrigin`.
- The initial Google Chat `running` notification opens or reuses a thread keyed by the task ID; the returned `thread.name` becomes the persisted `ThreadBinding`.
- Review-ready notifications are posted into the bound thread; review decisions use the task UI, API, or `task_review`.
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
| `TaskService` | `dartclaw_runtime/src/task/task_service.dart` | CRUD + state machine transitions. Wraps `SqliteTaskRepository` and backs the task HTTP, UI, and agent-tool surfaces |
| `TaskExecutor` | `task/task_executor.dart` | Acquires harness from pool, runs task turn, collects artifacts, transitions status |
| `WorktreeManager` | `task/worktree_manager.dart` | Git worktree lifecycle: create branch, register with file guard, cleanup on accept/reject |
| `DiffGenerator` | `task/diff_generator.dart` | Structured diff output: files changed, additions, deletions, hunks |
| `MergeExecutor` | `task/merge_executor.dart` | Squash/merge worktree back to main branch, conflict detection |
| `TaskFileGuard` | `task/task_file_guard.dart` | Path containment via `p.isWithin()` for tasks with a registered declared worktree |
| `ArtifactCollector` | `task/artifact_collector.dart` | Collects task outputs as typed artifacts (`diff`, `document`, `data`, `log`) |
| `RunnerObserver` | `task/runner_observer.dart` | Current runner lifecycle and cumulative turn metrics derived from coordinator events |
| `TaskReviewService` | `task/task_review_service.dart` | Shared task-review lifecycle for HTTP, UI, and agent-tool paths. Owns state transition, merge execution for worktree-backed tasks, conflict artifact persistence, worktree cleanup, and `TaskStatusChangedEvent` firing |
| `TaskNotificationSubscriber` | `task/task_notification_subscriber.dart` | Subscribes to `TaskStatusChangedEvent` on the event bus. For tasks with a `TaskOrigin`, sends best-effort in-channel notifications on key transitions. For Google Chat origins, the initial `running` notification can establish the persisted thread binding used by later notifications and inbound routing |
| `AdvisorSubscriber` | `advisor/advisor_subscriber.dart` | EventBus-driven crowd-coding observer. Accumulates a bounded normalized context window, evaluates triggers (`periodic`, `task_review`, `turn_depth`, `token_velocity`, `explicit`), acquires a pooled runner for an advisory turn, parses structured output, then routes the result to bound channels and the event bus |

Task state machine: `draft` → `queued` → `running` → `review` → `accepted`/`rejected`/`cancelled`/`failed`. See [Data Model — Task State Machine](data-model.md) for valid transitions.

Task dispatch defaults to the `workspace` profile. An authenticated operator may explicitly declare `restricted`;
legacy `research` input and stored rows are refused.

**Package**: `dartclaw_runtime` (service, executor), `dartclaw_core` (models, status enum, SQLite repository)

**Worktree lifecycle hardening (0.16.4)**:
- `WorktreeManager.create()` now reconciles three sources of truth before `git worktree add`: the in-memory cache, the on-disk worktree directory, and `git worktree list --porcelain`. Matching state is adopted; orphaned or mismatched state is reaped and recreated.
- Workflow-shared worktrees are no longer a plain read-then-create race. `TaskExecutor` now serializes lookup+create per `workflowWorktreeKey`, persists the resulting `{key, path, branch, workflowRunId}` binding on the `workflow_runs` row, and rehydrates that binding on resume/retry/recovery before execution restarts.
- The path invariant is explicit: worktrees stay keyed by the caller-supplied task UUID. Shared identity fields such as workflow run ID can select a binding, but must never derive the on-disk worktree path.

#### Workflow Engine

`dartclaw_workflow` owns framework-agnostic YAML parsing, validation, discovery, execution, skill preflight, output extraction, concurrency, and workflow lifecycle coordination. Server and CLI wiring provide persistence, guarded harness execution, and git/workspace ports. Bounded agent steps use one leased harness worker for their complete prompt chain; host-owned deterministic and approval steps remain inside the engine. Built-in definitions and skills are embedded and materialized into runtime-visible paths.

Connected HTTP/UI and standalone CLI paths share this engine. See [Workflow Engine Architecture](workflow-architecture.md) and the [Workflows guide](../../docs/guide/workflows.md) for execution, recovery, isolation, and authoring contracts.

**Package**: `dartclaw_workflow` (engine and definition lifecycle), `dartclaw_runtime` (connected HTTP and web integration plus the in-`serve` provider and persistence wiring), `dartclaw_cli` (standalone/connected commands)

#### Security

Defense-in-depth across five layers:

```
Layer 5:  OS-level container isolation (Docker kernel namespaces)
Layer 4:  Network isolation (network:none + host-gateway mediation)
Layer 3:  Guard chain (command/file/network/content/tool)
Layer 2:  Prompt-level safety rules (AGENTS.md, hardcoded rules)
Layer 1:  Credential isolation (container provider traffic is mediated by the host gateway; credentials stay host-side)
```

| Component | File | Role |
|-----------|------|------|
| `GuardChain` | `security/guard.dart` | Ordered guard evaluation; fail-closed by default |
| `CommandGuard` | `security/command_guard.dart` | Regex + pipe analysis + quote stripping on bash commands |
| `FileGuard` | `security/file_guard.dart` | 3-level path access (`no_access`/`read_only`/`no_delete`), symlink resolution |
| `NetworkGuard` | `security/network_guard.dart` | Domain allowlist + SSRF detection (DNS resolution + address range validation) |
| `ContentGuard` | `security/content_guard.dart` | LLM-based content classification at agent boundary (Haiku) |
| `MessageRedactor` | `security/message_redactor.dart` | Best-effort pattern-based redaction of secrets in logged output |
| `GuardAuditLogger` | `security/guard_audit.dart` | Date-partitioned `audit-YYYY-MM-DD.ndjson` files with retention cleanup |
| `ContainerManager` | `container/container_manager.dart` | Docker lifecycle: create, start, exec, stop. Per-security-profile containers |
| `ContentClassifier` | `security/content_classifier.dart` | Pluggable backends: `ClaudeBinaryClassifier` (default) or `AnthropicApiClassifier` |

Service wiring gives each runner a layered chain: the shared reloadable base guards plus that runner's `TaskToolFilterGuard`. The executing harness evaluates that chain, so base reloads propagate without discarding per-turn or per-task policy. SDK hosts own the same composition boundary; see [Security Architecture](security-architecture.md).

Container naming: `dartclaw-<fnv1a8(dataDir)>-<profileId>` — deterministic 8-char FNV-1a digest of the data directory (Docker-safe local identifier, not a cryptographic hash), collision-free across installs.

| Security Profile | Container | Mounts | Used By |
|------------------|-----------|--------|---------|
| `workspace` | `dartclaw-<id>-workspace` | `/workspace:rw`, `/project:ro` | Main chat, default tasks, cron |
| `restricted` | `dartclaw-<id>-restricted` | No workspace | Search agent, explicitly declared tasks |

Design rationale: [ADR-001](../adrs/001-sdk-integration-and-security-architecture.md), [ADR-012 (Per-Type Container Isolation)](../adrs/012-per-type-container-isolation.md)

**Package**: `dartclaw_kernel` (guards, all concrete guard implementations, content classification interfaces, message redaction, guard audit primitives, `ContainerConfig`, `GuardConfig`), `dartclaw_core` (`GuardBlockEvent`), `dartclaw_runtime` (guard wiring with EventBus, container health monitor)

#### Storage

Two storage mechanisms, each for distinct access patterns:

| Mechanism | Used For | Access Pattern | Source of Truth? |
|-----------|----------|----------------|-----------------|
| **Files** (NDJSON, JSON, YAML, Markdown) | Sessions, messages, memory, config, audit, usage | Append-only logs, atomic documents | **Yes** |
| **SQLite** (`search.db`, `tasks.db`, `state.db`) | FTS5 search index, tasks/goals/artifacts, transient turn recovery state | Relational queries, full-text search | `search.db`: derived (rebuildable). `tasks.db`: **authoritative**. `state.db`: transient operational state |

File-based services use write queues (`StreamController`) or fire-and-forget patterns for concurrency safety. All mutable JSON/YAML files use temp-file + atomic rename.

Full persistence details: [Data Model & Persistence Overview](data-model.md)

Design rationale: [ADR-002 (File-Based Storage)](../adrs/002-file-based-storage.md)

**Package**: `dartclaw_core` (file-based and SQLite services)

#### Web UI

Server-rendered HTML with declarative interactivity — zero JavaScript build toolchain.

| Layer | Technology | Role |
|-------|-----------|------|
| Templates | Trellis (`.html` files with `tl:` attributes) | Server-side rendering with auto-escaping, fragment support |
| Interactivity | HTMX + Stimulus controllers | HTMX owns navigation, requests, swaps, and OOB updates; Stimulus owns `dc-*` browser behavior attached to server-rendered DOM |
| Streaming | HTMX SSE extension (`htmx-ext-sse`) | Declarative SSE: `sse-connect`, `sse-swap` attributes. Server pushes HTML fragments |
| Markdown | marked.js + highlight.js | Client-side rendering of agent responses |
| Styling | Afterglow `tokens.css` + `design-system.css`, then app-only `app-tokens.css` + `app.css` | Canonical primitives followed by product-specific tokens and composition |

Navigation uses HTMX fragment rendering: `_wantsFragment()` detects `HX-Request` header and returns content-only HTML (no shell), swapped into `#main-content` with out-of-band sidebar/topbar updates.

Stimulus controllers live under `static/controllers/` and use `dc-*` controller names. Trellis templates attach behavior with `data-controller`, `data-action="event->controller#method"`, controller targets, and typed values. Controller `connect()`/`disconnect()` lifecycle handles HTMX replacement and history restoration without page-global reinitialization.

SSE streaming flow: POST `/api/sessions/:id/send` → server returns HTMX SSE-connected HTML fragment → server pushes `delta`, `tool_use`, `tool_result`, `done` events as HTML fragments → HTMX handles DOM insertion.

`PageRegistry` can include Health Dashboard, Settings, Memory, Knowledge, Scheduling, Tasks, Projects, and Workflows. Settings and Knowledge are always registered; the other pages depend on active services or configuration. The Knowledge timeline is a registered nested route but not a top-level navigation item. SDK consumers can add pages via `server.registerDashboardPage()`.

**Package**: `dartclaw_runtime`

#### Configuration

Three-tier configuration system:

| Tier | Mechanism | Restart Required? |
|------|-----------|-------------------|
| **Tier 1** (0.5) | Runtime toggles via API | No — applied immediately |
| **Tier 2** (0.6) | Full YAML editing + graceful restart | Yes — 30s turn drain + restart |
| **Tier 3** (0.16) | `ConfigNotifier` + `Reconfigurable` services + reload triggers (`SIGUSR1` / file-watch) | No — reloadable sections apply to the running process |

| Component | File | Role |
|-----------|------|------|
| `DartclawConfig` | `dartclaw_kernel/dartclaw_kernel.dart` | Parsed YAML config with env var substitution (`${ENV_VAR}`) |
| `ConfigWriter` | `dartclaw_kernel/config_writer.dart` | YAML round-trip writer (preserves comments via `yaml_edit`), backup-on-write |
| `ConfigValidator` | `dartclaw_kernel/config_validator.dart` | Server-side validation before write |
| `ConfigMeta` | `dartclaw_kernel/config_meta.dart` | Schema metadata for UI form generation |
| `RuntimeConfig` | `runtime_config.dart` | In-memory toggles for live config fields |
| `ConfigNotifier` | `dartclaw_kernel/config_notifier.dart` | Holds the current `DartclawConfig`, computes `ConfigDelta`, and synchronously notifies registered `Reconfigurable` services |
| `ConfigDelta` | `dartclaw_kernel/config_delta.dart` | Immutable changed-section snapshot (`previous`, `current`, `changedKeys`) used to filter reconfiguration work |
| `Reconfigurable` | `dartclaw_kernel/reconfigurable.dart` | Interface implemented by hot-reloadable services (`watchKeys`, synchronous `reconfigure`) |
| `ReloadConfig` | `config/gateway_config.dart` | `gateway.reload` sub-config: `mode` (`off` / `signal` / `auto`) and file-watch `debounce_ms` |
| `ReloadTriggerService` | `apps/dartclaw_cli/.../reload_trigger_service.dart` | Process-level trigger integration: `SIGUSR1` plus parent-directory file watching with debounce for atomic writes |

Config resolution order: CLI flags > config file (`--config` > `DARTCLAW_CONFIG` env > `DARTCLAW_HOME/dartclaw.yaml` > `~/.dartclaw/dartclaw.yaml`) > defaults. Standalone workflow commands add a scoped cwd-local `.dartclaw/dartclaw.yaml` lookup before the default instance path when no explicit config path or home is set.

The config API now partitions fields into three mutability classes:
- **live** — handled immediately by existing Tier 1 side effects
- **reloadable** — written to YAML, then applied by `ConfigNotifier.reload()` without restart
- **restart** — written to YAML and tracked in `restart.pending` until the next graceful restart

In 0.16, this powers hot-reload for context settings, scheduling services, alert routing config, guard-chain rebuilds, queue/lock tuning, and other runtime-owned services. Server socket bindings (`server.port`, `server.host`, `server.data_dir`) remain explicitly non-reloadable and are excluded from `ConfigDelta`.

Every turn receives an authoritative prompt for its scope. Replace-mode providers recompose current behavior files and,
for primary turns, a fresh bounded canonical-memory index projection. Append-mode providers receive scoped static
behavior plus the same fresh bounded projection through the turn prompt; topic bodies remain available on demand through
`memory_search` and `memory_read`.

**Package**: `dartclaw_kernel` (typed config model, metadata, validator, writer, live notifier, delta, runtime-facing interfaces), `dartclaw_runtime` (API routes), `dartclaw_cli` (reload triggers)

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
├── sealed RunnerLifecycleEvent
│   └── RunnerStateChangedEvent   — harness busy/idle transitions
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
| `buildHeartbeatJob` | `behavior/heartbeat_job.dart` | Built-in `heartbeat` job: periodic `HEARTBEAT.md` checklist |
| `buildWorkspaceGitSyncJob` | `workspace/workspace_git_sync_job.dart` | Built-in `git-sync` job: workspace versioning on its own interval |
| `CronParser` | `scheduling/cron_parser.dart` | 5-field cron expression parser |
| `ScheduledTaskRunner` | `scheduling/scheduled_task_runner.dart` | Bridges scheduling to task orchestrator (`task` job type) |

Job types: `cron` (cron expression), `interval` (repeat every N minutes), `once` (one-shot).

Delivery modes: `announce` (sends result to a session), `webhook` (HTTP POST to URL), `none` (run silently), `task` (creates a reviewable task).

0.16 adds `ScheduledJobFailedEvent` to the event hierarchy. `ScheduleService` emits it after the final retry attempt fails, letting observability and alert-routing subscribers react without coupling scheduling logic to channels or UI concerns.

**Package**: `dartclaw_runtime`

#### System Alerts

0.16 introduces an explicit alert-routing subsystem for operational events.

| Component | File | Role |
|-----------|------|------|
| `AlertsConfig` | `dartclaw_kernel` `alerts_config.dart` | Top-level `alerts:` config section: `enabled`, `cooldown_seconds`, `burst_threshold`, `targets`, `routes` – all five registered in `ConfigMeta` as `reloadable` |
| `classifyAlert` | `alerts/alert_classifier.dart` | **The single decision point**: whether an event is alertable, its type, its severity, its body and its detail fields, returned together. A wildcard-free switch over the sealed `DartclawEvent` base, so a new event type fails the build until it is consciously classified ([ADR-057](../adrs/057-workflow-events-stay-in-the-sealed-event-library.md)) |
| `AlertRouter` | `alerts/alert_router.dart` | EventBus subscriber that classifies runtime events, resolves explicit channel targets, and delegates formatting/delivery |
| `AlertDeliveryAdapter` | `alerts/alert_delivery_adapter.dart` | Resolves `(channelType, recipient)` into the concrete `Channel.sendMessage()` call without going through job-oriented delivery services |
| `AlertFormatter` | `alerts/alert_formatter.dart` | Channel shape only – plain text for WhatsApp/Signal, Cards v2 payloads for Google Chat – over an already-classified alert. It holds the alert-type-to-title table and knows nothing about event types, so an unclassified event has no route to a channel |
| `AlertThrottle` | `alerts/alert_throttle.dart` | Per-target cooldown and burst-summary accumulator keyed by `(eventType, channelType, recipient)`; carries the classified severity into the summary so a burst is never summarised below the severity of the alerts it stands for |

The shipped classification covers guard blocks, container crashes, non-channel task failures, scheduled-job failures, budget warnings (task and workflow), compaction completion, loop detection, emergency stops, and the four degraded credential-health states – `credential_expiry`, `credential_refresh_failure`, `credential_reauth_required` and `credential_contract_break` (healthy and unknown are recorded, never alerted). Routing is explicit: operators declare recipient/channel pairs in `alerts.targets`, then optionally narrow delivery per event type through `alerts.routes`.

An alert's type, severity and content are host-decided throughout; no alert path parses model output.

**Package**: `dartclaw_kernel` (`AlertsConfig`), `dartclaw_runtime` (classification, routing, formatting, throttling)

#### Memory & Search

```
canonical topic + archive + observation + learning roles ──► search.db (FTS5 projection, rebuildable)
```

Live saves and pruning reconcile the same line-ending-normalized entry rows, source timestamps, and canonical-file
union that `dartclaw rebuild-index` restores.

| Component | File | Role |
|-----------|------|------|
| `MemoryFileService` | `packages/dartclaw_core/lib/src/memory/memory_file_service.dart` | Daily-observation adapter over `MemoryCorpusService`, plus bounded source reads and indexing helpers |
| `SelfImprovementService` | `packages/dartclaw_runtime/lib/src/behavior/self_improvement_service.dart` | Auto-populate `errors.md` on failures and bound canonical learning captures |
| `MemoryPruner` | `packages/dartclaw_core/lib/src/memory/memory_pruner.dart` | Archive recognized entries >90d under their original categories, deduplicate them, preserve opaque content |
| `MemoryService` | `packages/dartclaw_core/lib/src/storage/memory_service.dart` | FTS5 insert/search with BM25 ranking |
| `SearchDb` | `packages/dartclaw_core/lib/src/storage/search_db.dart` | SQLite schema, FTS5 virtual table, rebuild |
| `Fts5SearchBackend` | `packages/dartclaw_core/lib/src/search/fts5_search_backend.dart` | Default search: FTS5 BM25 |
| `QmdSearchBackend` | `packages/dartclaw_core/lib/src/search/qmd_search_backend.dart` | Opt-in hybrid: QMD sidecar over a startup-verified recursive workspace Markdown collection |

Memory MCP tools (`memory_apply`, `memory_observe`, `memory_search`, `memory_read`) are registered on the internal MCP server and invoked by the agent via standard MCP protocol.

#### Context Research Synthesis

`context_research` is the Context Engine's MCP synthesis tool. It returns one compact citation packet instead of
requiring separate `memory_search`, temporal-KG, and wiki reads. Design rationale:
[ADR-042](../adrs/042-context-research-synthesis-and-citation-model.md).

At call time the tool fans out retrieval across:

- FTS5/QMD memory search, using the configured search backend;
- temporal-KG facts and timelines for query-derived entity candidates;
- wiki/source documents exposed through the knowledge layer.

Results are deduplicated while preserving source metadata. Synthesis then runs through the injected background-turn
seam; production wiring uses the logical-agent session path, while tests can inject a deterministic synthesizer.
The returned `CitationPacket` contains statements, source references, degraded layers, and a
`noSourcesFound` flag. If no sources are found, the packet reports that state instead of fabricating an answer. If the
synthesizer returns malformed output, assembly falls back to citation-preserving snippets.

Synthesized answers are never cached. Every `context_research` call reruns retrieval and synthesis so temporal facts,
wiki edits, and memory updates are reflected by the next request.

**Package**: `dartclaw_core` (file services, SQLite services, and search backends)

#### Project Management

Multi-project support added in 0.14. DartClaw can manage multiple git repositories and route tasks to the selected project.
Tasks declaring `configJson.needsWorktree: true` receive a worktree from that project.

| Component | File | Role |
|-----------|------|------|
| `ProjectService` | `task/project_service.dart` | CRUD for projects; clone/fetch/push management via `Isolate.run()` |
| `ProjectConfig` | `config/project_config.dart` | Parser for `projects:` config section |
| `Project` | `dartclaw_kernel` | Domain model: id, name, remoteUrl, localPath, defaultBranch, credentialsRef, cloneStrategy, prStrategy, status |
| Implicit `_local` | (ephemeral) | Backward-compatible project synthesized from `Directory.current.path`; not persisted |

Key characteristics:
- **Config-seeded, API-managed** pattern: projects defined in `dartclaw.yaml` are read-only via the API; projects added at runtime are fully mutable
- **`Isolate.run()`** for blocking git operations (clone, fetch, push) — prevents blocking the Dart event loop on I/O-intensive operations. First use of Isolates in DartClaw; simple args in / `ProcessResult` out, no complex objects cross the isolate boundary
- **`projects.json`** with atomic writes for runtime project registry persistence
- Clones stored at `<dataDir>/projects/<projectId>/`

As of 0.16.4, config/API projects can also be bound directly to an existing checkout via `projects.<id>.localPath:`. The runtime still uses `remoteUrl == ''` as the single discriminator for local-only projects (covering both the implicit `_local` project and named local-path projects). Workflow start now preflights named local-path projects before any workflow task is created: dirty trees and branch mismatches fail fast unless the operator explicitly opts in with `--allow-dirty-localpath`, publish requires an existing `origin` remote in the working tree, and containerized runs mount named local-path projects under the same `/projects/<id>` container convention used for cloned repositories.

Design rationale: [ADR-017 (Multi-Project Architecture)](../adrs/017-multi-project-architecture.md)

**Package**: `dartclaw_kernel` (model), `dartclaw_core` (service interface), `dartclaw_runtime` (implementation, API routes)

#### Agent Observability

Enriched turn recording and task event system added in 0.14.

| Component | File | Role |
|-----------|------|------|
| `ToolCallRecord` | `dartclaw_core/turn/tool_call_record.dart` | Per-tool-call record: name, success, durationMs, errorType |
| `TaskEvent`, `TaskEventKind` | `dartclaw_core/task/task_event.dart` | Typed task-timeline event and its closed event-kind vocabulary |
| `TurnTraceService` | `dartclaw_core` | Fire-and-forget persistence to `turns` SQLite table in `tasks.db` (NF03 — zero latency impact) |
| `TaskEventService` | `dartclaw_core` | Synchronous persistence to `task_events` SQLite table in `tasks.db` (NF04 — no event loss on crash) |
| `TaskEventRecorder` | `dartclaw_runtime` | Centralized event recording helper with typed convenience methods |

**Dual write pattern**: Turn traces are fire-and-forget (async, same as `usage.jsonl`) — low latency, best-effort. Task events are synchronous — guaranteed persistence before the recording call returns. The two patterns reflect different durability requirements: traces are analytical; events are operational (used for timeline display and progress tracking).

0.16 extends task observability with compaction tracking. `CompactionTaskEventSubscriber` listens for `CompactionCompletedEvent` and records a `TaskEventKind.compaction` row when the compacted SDK session belongs to a currently running task. This keeps long-running task sessions observable even when provider-managed compaction occurs mid-task.

Cache token normalization is handled at the `ProtocolAdapter` layer: Anthropic cache fields (`cache_read_input_tokens`, `cache_creation_input_tokens`) and OpenAI fields (`cached_input_tokens`) are both normalized to canonical `cacheReadTokens` / `cacheWriteTokens` before reaching `TurnOutcome`. See [Control Protocol & Harness Architecture](control-protocol.md) for details.

**Package**: `dartclaw_core` (`ToolCallRecord`, `TaskEvent`, `TaskEventKind`, `TurnTraceService`, `TaskEventService`), `dartclaw_runtime` (`TaskEventRecorder`)

#### MCP Server

Internal MCP server hosted as a `/mcp` endpoint on the existing shelf HTTP server. Provider binaries connect back to this endpoint for tool invocations: Claude receives MCP server config via `--mcp-config`, while Codex receives the same endpoint through generated `config.toml`.

| Component | File | Role |
|-----------|------|------|
| `McpProtocolHandler` | `mcp/mcp_server.dart` | MCP protocol handling, tool registration |
| `McpRouter` | `mcp/mcp_router.dart` | Shelf route adapter for MCP HTTP transport |
| `MemoryTools` | `mcp/memory_tools.dart` | `memory_apply`, `memory_observe`, `memory_search`, `memory_read` |
| `SessionsSpawnTool` | `mcp/sessions_spawn_tool.dart` | Create a configured logical-agent conversation (sync) |
| `SessionsSendTool` | `mcp/sessions_send_tool.dart` | Continue a logical-agent conversation (sync) |
| `WebFetchTool` | `mcp/web_fetch_tool.dart` | SSRF-hardened fetch with inline ContentGuard scanning |
| `BraveSearchTool` | `mcp/brave_search_tool.dart` | Brave Search API |
| `TavilySearchTool` | `mcp/tavily_search_tool.dart` | Tavily Search API |
| `SearchProvider` | `mcp/search_provider.dart` | Configurable search backend selection |
| `ContextResearchTool` | `mcp/context_research_tool.dart` | `context_research` synthesis over memory, temporal KG, and wiki sources |
| `OutboundMcpPool` | `mcp/outbound/outbound_mcp_pool.dart` | Pooled outbound MCP client with guard, audit, governance, and selective tool surfacing |

The outbound MCP client consumes configured external MCP servers rather than serving tools to provider binaries. It
owns native stdio and HTTP transports, performs `initialize`, `tools/list`, and `tools/call`, pools connections with
idle teardown, and surfaces only tools listed in `mcp_servers.<name>.surface_tools`. Calls are mediated by the egress
guard and audited before dispatch; guard, governance, or audit failure denies the call without contacting the external
server.
See [Security Architecture](security-architecture.md#outbound-mcp-egress-boundary) and
[ADR-039](../adrs/039-outbound-mcp-trust-boundary-and-transport.md).

SDK extensibility: `server.registerTool(McpTool)` — implement `name`, `description`, `inputSchema`, `access`
(`McpToolAccess.read` / `.write`, required and undefaulted), and `call()`. Guard evaluation and audit belong to
dispatch, not to the tool.

Design rationale: [ADR-009 (Internal MCP Server)](../adrs/009-internal-mcp-server.md)

**Package**: `dartclaw_runtime`

---

## Package Architecture

DartClaw uses a Dart pub workspace with strict dependency layering.

### Dependency DAG

```
dartclaw_kernel      → no workspace dependencies
dartclaw_core        → kernel
dartclaw_workflow    → core, kernel
dartclaw_whatsapp    → core, kernel
dartclaw_signal      → core, kernel
dartclaw_google_chat → core, kernel
dartclaw_testing     → core, kernel
dartclaw_client      → (none)
dartclaw             → client, kernel
dartclaw_acp         → core, kernel
dartclaw_bridge      → (none)
dartclaw_runtime      → bridge, core, kernel, workflow, all channels
dartclaw_cli         → acp, client, core, kernel, workflow, runtime, google_chat
```

The `dartclaw` umbrella package re-exports the client tier — `dartclaw_client` and `dartclaw_kernel` — and nothing from the runtime. Embedding the runtime means depending on `dartclaw_core` and friends directly (ADR-008).

### Package Responsibilities

| Package | Owns | Key Constraint |
|---------|------|----------------|
| `dartclaw_kernel` | Shared models, typed config, guards, content classification, validation, authoring helpers, and dependency-free utilities | No DartClaw dependencies; shared contracts and deterministic policy remain usable without runtime, storage, or EventBus wiring |
| `dartclaw_core` | `AgentHarness`, channel interfaces/infrastructure, events, file and SQLite persistence, FTS5/QMD search, `EventBus`, workflow/task seams | Runtime and persistence authority; no server or workflow dependency |
| `dartclaw_acp` | ACP stdio JSON-RPC client/harness, reverse-call mediation, target validation, `harness.acp` DTOs/parser and `AcpHarnessRegistrar` | Depends on the public kernel and core barrels only, implementing core's `HarnessRegistrar` seam; the CLI composes it and runtime production code never imports or names it |
| `dartclaw_workflow` | `WorkflowService`, `WorkflowExecutor`, parser/validator, template engine, workflow registry, workflow materialization, `WorkflowDefinition`/`WorkflowRun` models, `SkillIntrospector`, schema presets | Workflow definition + execution package shared by server and CLI. Production dependencies: kernel + core. Owns its workflow-run SQLite adapter and the fakes of its ports |
| `dartclaw_whatsapp` | `WhatsAppChannel`, `GowaManager`, response formatting, WhatsApp config registration | Depends on kernel + core – WhatsApp-specific logic isolated |
| `dartclaw_signal` | `SignalChannel`, `SignalCliManager`, sender mapping, Signal config registration | Depends on kernel + core – Signal-specific logic isolated |
| `dartclaw_google_chat` | `GoogleChatChannel`, REST client, GCP auth, Google Chat config registration | Depends on kernel + core – Google auth + HTTP isolated from core. Owns `FakeGoogleChatRestClient` behind `lib/testing.dart` |
| `dartclaw_bridge` | Framed bridge protocol, codec, runner, and the executable delivered into `network:none` containers | Standing zero-dependency leaf; keeping the graph hook-free preserves `dart compile exe` cross-compilation for both Linux targets |
| `dartclaw_runtime` | `DartclawServer`, `TurnManager`, `TurnRunner`, `ExecutionCoordinator`, `TaskService`, `TaskExecutor`, `ProjectService`, `TaskEventRecorder`, `AlertRouter`, container orchestration, scheduling, behavior/workspace/maintenance/observability services, project API routes, trace query API, workflow HTTP routes, MCP server, web routes, templates, auth | shelf, http, workflow — server-only, not Flutter-compatible |
| `dartclaw_testing` | Shared test doubles and in-memory test helpers for core-and-below boundaries (`FakeAgentHarness`, `FakeGuard`, `InMemorySessionService`, `InMemoryTaskRepository`, `TestEventBus`) | Test-only support package, production-depending on kernel + core only. A double for a port owned above core lives in that port's package under `lib/src/testing/`, behind an opt-in `lib/testing.dart` the package barrel does not re-export |
| `dartclaw_cli` | CLI runner (command layer only — the service graph lives in `dartclaw_runtime`), `DartclawApiClient`, connected command groups (`workflow`, `tasks`, `config`, `projects`, `sessions`, `runners`, `traces`, `jobs`), plus local lifecycle/maintenance commands (`serve`, `status`, `init`, `service`, `token`, `rebuild-index`, `sessions cleanup`) | args — application entry point and loopback operations surface |
| `dartclaw` | Client-tier umbrella re-export of `dartclaw_client` and `dartclaw_kernel` | Lean API-client entry point; it never re-exports runtime packages |

### Why These Boundaries?

The critical boundaries are **`dartclaw_kernel` has no workspace dependency**, **runtime persistence lives in `dartclaw_core`**, and **workflow execution plus workflow-run persistence lives in `dartclaw_workflow`**. The kernel gives shared models, config, guard contracts, and deterministic utilities one owner without pulling in runtime machinery.

`dartclaw_kernel` remains zero-EventBus, so consumers can use guards and typed configuration without server wiring. Its external dependencies are small Dart libraries needed by those contracts; it has no upward workspace edge.

`dartclaw_core` owns the sqlite3 native dependency and the repositories that share aggregate hydration and row mapping.

`dartclaw_bridge` stays a standing zero-dependency leaf because `dart compile exe` refuses build-hook graphs, while a
different hook-free host would only preserve cross-compilation until its next dependency change (ADR-051).

Channel packages (`dartclaw_whatsapp`, `dartclaw_signal`, `dartclaw_google_chat`) isolate their heavy transitive dependencies — a consumer using only WhatsApp does not pull in Google Cloud libraries.

`dartclaw_runtime` is `publish_to: none` — it contains the HTTP server, templates, and application logic that SDK consumers don't need.

Design rationale: [ADR-008 (SDK Publishing Strategy)](../adrs/008-sdk-publishing-strategy.md), [ADR-056 (Package Topology Consolidation)](../adrs/056-package-topology-consolidation.md)

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

DartClaw targets one user, one deployment. AOT-compiled via `dart build cli` to a native binary plus a bundled SQLite library in a sibling `lib/`. No Node.js, no npm, no Deno at runtime.

Runtime dependencies:
- `claude` CLI binary (~185-234 MB, Bun standalone — installed via `curl -fsSL https://claude.ai/install.sh | bash`)
- `codex` CLI binary (required for `codex` workers)
- Docker (OrbStack on macOS, native Engine on Linux) — for container isolation
- Bundled SQLite library (`lib/sqlite3.*`; `lib/sqlite3.dll` on Windows) — for search index and task persistence
- Channel sidecars (optional): GOWA binary (WhatsApp), signal-cli (Signal)

### Container Isolation Topology

```
Host OS
  ├── dartclaw binary (Dart AOT)
  │     ├── HTTP server (port 3000)
  │     ├── HostGateway (one authority per live container execution)
  │     └── Container orchestrator
  │
  ├── Docker: dartclaw-<hash>-workspace-<authority>
  │     ├── claude or codex binary packaged in the image
  │     ├── dartclaw-bridge (read-only mount) → framed stdio over docker exec
  │     ├── /workspace:rw mount, /project:ro mount
  │     ├── per-authority generated-state mount (destroyed with the container)
  │     └── network:none, cap-drop=ALL, read-only rootfs
  │
  ├── Docker: dartclaw-<hash>-restricted-<authority>
  │     ├── claude or codex binary packaged in the image
  │     ├── dartclaw-bridge (read-only mount)
  │     ├── No workspace mount
  │     └── network:none, cap-drop=ALL, read-only rootfs
  │
  ├── GOWA sidecar (optional, Go binary)
  └── signal-cli sidecar (optional)
```

Credential flow: API keys live on the host and never enter a container environment. Each live authority owns its own container plus a pair of framed `docker exec` pipes served by `HostGateway`; the provider adapter strips any client-supplied credential and injects the host one per request. A container reaches exactly one upstream, holds no reusable credential, and has no network of its own.

Both Claude and Codex have a verified provider adapter and run on either execution boundary. ACP registrations have none, so they have no mediated container execution — see [Control Protocol](control-protocol.md) for the computed compatibility rule.

### Dev Mode

When the resolved posture is disabled — declared `container.enabled: false`, or an unset posture with no container runtime detected — all harnesses run as direct subprocesses on the host. Guards still evaluate, but there is no OS-level isolation boundary. Acceptable for local development; `examples/dev.yaml` declares it rather than relying on whether a runtime happens to be installed.

---

## Runtime Governance

Runtime governance protects deployments from cost overruns, abuse, and runaway agent behavior. It is configured under the `governance:` YAML section and enforced across two integration points.

### Components

| Component | Package | Role |
|-----------|---------|------|
| `GovernanceConfig` | `dartclaw_kernel` | Parsed governance schema: rate limits, budget, loop detection |
| `RateLimitsConfig` | `dartclaw_kernel` | Per-sender + global rate limit sub-config |
| `BudgetConfig` | `dartclaw_kernel` | Daily token budget sub-config: threshold, action, timezone |
| `LoopDetectionConfig` | `dartclaw_kernel` | Loop detection thresholds and action |
| `TurnLimitsConfig` | `dartclaw_kernel` | Turn-budget sub-config: `turn_timeout`, `stall_timeout`, and `stall_action` |
| `SlidingWindowRateLimiter` | `dartclaw_kernel` | In-memory sliding window rate limiter utility |

### Integration Points

**Per-sender rate limiting** (enforced in `ChannelTaskBridge.tryHandle()`):
- Applies after thread-binding lookup, before bound-thread or ordinary session routing
- Keyed by sender JID
- Rejects excess messages with a polite "too fast" response and returns `true` (consumed — not enqueued)
- Exempt: admin senders and recognized reserved commands
- Review requests are ordinary model turns and receive no exemption

**Global turn rate limiting** (enforced in `TurnRunner.reserveTurn()`):
- Applies across all sessions and senders combined
- Defers turn reservation (waits for window capacity) rather than rejecting
- Emits SSE `rate_limit_warning` event at 80% usage; resets hysteresis below 60%

**Daily token budget enforcement** (enforced in `TurnRunner` via `BudgetEnforcer`, the daily scope over the shared `BudgetEngine`):
- Configured by `governance.budget.daily_tokens`, `action`, and `timezone`
- Posts a budget warning once per day when usage reaches 80% of the configured budget; reaching 100% consumes the same daily warning
- `BudgetEnforcer` reports consumption only; `TurnGovernanceEnforcer` maps it onto the configured action — at 100% it either logs and allows (`warn`) or blocks new turns until the next budget window (`block`)
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

**Turn limits** (enforced in `TurnRunner` via `TurnLivenessTracker`):
- Configured by `governance.turn_limits.stall_timeout`, `.stall_action`, and `.turn_timeout`
- Resets only on forward-progress bridge events: `DeltaEvent`, `ToolUseEvent`, and `ToolResultEvent`
- Stall actions: `warn` emits SSE `turn_progress_stall`, `cancel` aborts the active turn, `ignore` logs only
- Known tool-approval waits suspend stall accounting, but never the wall-clock turn limit
- A limit-attributed cancellation records `limit_breach` as `stall` or `turn_timeout`; ordinary user cancellation remains un-attributed
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

`DartclawRuntime.build(config, {headless, harnessRegistrars, …})` (in `dartclaw_runtime`, `lib/src/runtime/`) is the dependency injection root. It constructs all services, wires them together, and returns a `DartclawRuntime` carrying everything `ServeCommand.run` needs plus the `shutdown()` that tears them down. `headless: true` composes the same guarded execution, task and workflow stacks while constructing none of the inbound or scheduled surfaces — no `DartclawServer`, channel manager, heartbeat, schedule service or token service — so a caller that is not `serve` boots a runtime without copying application code. `harnessRegistrars` lets the composer contribute provider families `dartclaw_runtime` does not name.

### Construction Order (simplified)

```
1.  Config parsing (DartclawConfig from YAML)
2.  Config notifier (`ConfigNotifier`) for reloadable sections
3.  File services (SessionService, MessageService, KvService)
4.  SQLite databases (SearchDb, TaskDb, TurnStateStore/state.db)
5.  Search backends (FTS5, optional QMD)
6.  Memory services (MemoryFileService, MemoryService, SelfImprovementService)
7.  Security (GuardChain, concrete guards, `MessageRedactor`, `GuardAuditLogger`, and `GuardConfig` from `dartclaw_kernel`; `GuardBlockEvent` from `dartclaw_core`; guard verdict wiring + `GuardAuditSubscriber` from `dartclaw_runtime`)
8.  Container managers (per-profile: workspace, restricted)
9.  Primary provider harness and `TurnRunner`
10. Execution coordinator (primary lane + per-provider capacity gates; workers remain lazy)
11. Execution observers derived from coordinator leases and snapshots
12. Event bus + subscribers
13. Channels (dartclaw_whatsapp, dartclaw_signal, dartclaw_google_chat — if configured)
14. Scheduling (ScheduleService, including the built-in heartbeat and git-sync jobs)
15. Task orchestrator (TaskService, TaskExecutor)
16. Project management (ProjectService, RemotePushService)
17. Workflow engine (WorkflowRegistry, WorkflowService, WorkflowExecutor)
18. Alert routing (AlertRouter, AlertDeliveryAdapter — if alerts configured)
19. MCP server (register tools: memory, sessions_spawn, sessions_send, web_fetch, search)
20. DartclawServer (shelf handler assembly, page registration)
21. Reload triggers (`ReloadTriggerService`) for `SIGUSR1` / file-watch hot-reload
```

All services are single-instance, single-threaded. Isolates are avoided unless profiling shows a bottleneck.

---

## Cross-References

### Architecture Documents

| Document | Path | Content |
|----------|------|---------|
| Control protocol & harness | [`dev/architecture/control-protocol.md`](control-protocol.md) | JSONL protocol spec, multi-provider comparison, harness lifecycle |
| Security architecture | [`dev/architecture/security-architecture.md`](security-architecture.md) | Defense-in-depth model, guard pipeline, container isolation, credential security |
| Data model & persistence | [`dev/architecture/data-model.md`](data-model.md) | Entity models, storage zones, write safety, rotation |
| Workflow architecture | [`dev/architecture/workflow-architecture.md`](workflow-architecture.md) | Workflow engine deep-dive: parser, executor, skill system, map/fan-out |
| CLI & API architecture | [`dev/architecture/cli-api-architecture.md`](cli-api-architecture.md) | CLI runner, loopback API client, command groups, connected-vs-standalone execution, route mapping |
| Channel & messaging | [`dev/architecture/channel-messaging-architecture.md`](channel-messaging-architecture.md) | Channel abstractions, inbound pipeline, thread binding, outbound routing |
| Task & execution | [`dev/architecture/task-execution-architecture.md`](task-execution-architecture.md) | Task orchestrator, worktree lifecycle, review flows, project dispatch |
| Configuration | [`dev/architecture/configuration-architecture.md`](configuration-architecture.md) | Three-tier config, hot-reload, ConfigNotifier, Reconfigurable pattern |
| Observability & operations | [`dev/architecture/observability-operations-architecture.md`](observability-operations-architecture.md) | Turn traces, task events, alert routing, scheduling |
| Session & state management | [`dev/architecture/session-state-architecture.md`](session-state-architecture.md) | Session lifecycle, scoping, locks, pause/resume, crash recovery |
| Architecture governance | [`dev/architecture/architecture-governance.md`](architecture-governance.md) | Fitness functions, structural boundaries, update rules, and governance scope |
| Roadmap | [`dev/state/ROADMAP.md`](../state/ROADMAP.md) | Milestones, status, success criteria |
| Feature comparison | `docs/specs/feature-comparison.md` (private repo) | OpenClaw vs NanoClaw vs DartClaw |
| Product Backlog | `docs/PRODUCT-BACKLOG.md` (private repo) | Deferred/future features with rationale |
| Learnings | [`dev/state/LEARNINGS.md`](../state/LEARNINGS.md) (index) + `dev/state/learnings/` shards | Traps, gotchas, non-obvious patterns |
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
| [ADR-012](../adrs/012-per-type-container-isolation.md) | Per-profile, per-owner containers (workspace + restricted profiles) |
| [ADR-014](../adrs/014-sdk-package-decomposition.md) | Original package decomposition; its storage split is superseded by ADR-056 |
| [ADR-016](../adrs/016-multi-provider-harness-architecture.md) | Multi-provider harness architecture — abstract harness + protocol adapter for Claude and Codex |
| [ADR-017](../adrs/017-multi-project-architecture.md) | Multi-project architecture — config-seeded + API-managed project registry, Isolate git ops |
| [ADR-018](../adrs/018-cli-onboarding-architecture.md) | CLI onboarding architecture |
| [ADR-019](../adrs/019-tui-cli-package-selection.md) | TUI CLI package selection |
| [ADR-020](../adrs/020-package-decomposition-phase-2.md) | Package decomposition phase 2 — workflow package extraction |

### Diagrams

Architecture diagrams are maintained as Excalidraw source files in `docs/diagrams/` (private repo). Rendered PNGs in `docs/diagrams/renders/` are gitignored and regenerable.

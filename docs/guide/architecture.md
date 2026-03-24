# Architecture

> Current through: **0.14**

DartClaw is a 2-layer agent runtime where each layer has a distinct role and trust level. The Dart host owns all state, security, and orchestration. Agent CLI binaries handle reasoning and tool execution. This document explains how they fit together, why they are separated, and how the major subsystems interact.

## The Two Layers

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1: Dart Host (AOT-compiled binary)               │
│  ────────────────────────────────────────               │
│  Owns: storage, HTTP API, web UI, turn orchestration,   │
│        security policy, channels, tasks, scheduling     │
│  Trust: FULL — this is your code                        │
└────────────────────────┬────────────────────────────────┘
                         │ JSONL control protocol (stdin/stdout)
┌────────────────────────▼────────────────────────────────┐
│  Layer 2: Agent CLI Binary                              │
│  ─────────────────────────                              │
│  claude CLI (Anthropic) or codex CLI (OpenAI)           │
│  Owns: agent reasoning, tool execution,                 │
│        bash commands, file operations                   │
│  Trust: SANDBOXED — Docker container isolation          │
└─────────────────────────────────────────────────────────┘
```

### Layer 1: Dart Host

The Dart host is the control plane. It is an AOT-compiled Shelf HTTP server with file-based storage that:

- **Stores state** — sessions and messages in NDJSON files, tasks/search/turn-recovery state in SQLite, config in YAML
- **Serves the web UI** — Trellis HTML templates, HTMX + SSE streaming, CSS design tokens
- **Orchestrates turns** — receives messages (from web, WhatsApp, Signal, Google Chat), composes system prompts, dispatches to agent harnesses, streams results back
- **Enforces security** — guard chain (input sanitization, command/file/network guards, content classification), credential isolation, container management, audit logging
- **Runs background work** — cron scheduling, session maintenance, memory pruning, task queue processing

The host never executes agent logic directly. It spawns agent binaries as subprocesses and controls what information flows in and out.

### Layer 2: Agent CLI Binaries

The actual agent runtimes. DartClaw supports multiple providers (since 0.13):

| Provider | Binary | Protocol | Models |
|----------|--------|----------|--------|
| **Claude** (default) | `claude` CLI | Bidirectional JSONL | Claude Haiku, Sonnet, Opus |
| **Codex** | `codex` CLI | JSON-RPC JSONL | OpenAI GPT-4o, GPT-5, o-series, Ollama |

Each provider binary is spawned as a subprocess. The Dart host manages its lifecycle, including auto-restart with exponential backoff on crash. The `HarnessFactory` creates the appropriate harness type based on the configured provider ID.

In a mixed deployment, the `HarnessPool` can contain workers from different providers — for example, a Claude primary harness for interactive chat and Codex workers for background tasks. See [Agents § Providers](agents.md#providers) for configuration details.

## Communication: The JSONL Control Protocol

Dart and the claude CLI binary communicate over stdin/stdout using a **bidirectional JSONL** (JSON Lines) control protocol. This is the same protocol used by the official Python, Go, and Elixir SDKs.

```
Dart Host                              Agent CLI Binary
    │                                       │
    │──── spawn with args + env ───────────>│
    │                                       │
    │──── initialize (hooks, MCP, prompt) ─>│
    │<──── init response ──────────────────│
    │                                       │
    │──── user message (JSONL) ───────────>│
    │<──── stream text delta ──────────────│
    │<──── hook callback (PreToolUse) ─────│  ← guard evaluation
    │──── hook response (allow/deny) ─────>│
    │<──── stream tool_use ────────────────│
    │<──── stream tool_result ─────────────│
    │<──── stream text delta ──────────────│
    │<──── result ─────────────────────────│
    │                                       │
```

The protocol supports:

- **Streaming events** — text deltas, tool use, tool results, all parsed via a sealed class hierarchy
- **Hook callbacks** — the binary asks the Dart host for permission before tool execution (PreToolUse/PostToolUse), enabling the guard system to block dangerous operations
- **In-process MCP** — MCP tool calls (memory search, web fetch, etc.) are proxied through the control protocol as JSONRPC messages, handled by the Dart host
- **Control messages** — interrupt, model switching, permission mode changes

### Why JSONL over stdin/stdout?

- No network port needed (simpler than HTTP or WebSocket)
- Works seamlessly when the binary runs inside a Docker container
- One line = one message — no framing issues
- Native Dart JSON parsing, no additional protocol libraries needed

## Package Structure

DartClaw is organized as a Dart pub workspace with eleven packages plus a CLI app. Each package has a focused role:

```
packages/
  dartclaw_models/       Zero dependencies. Shared data types such as Session,
                         Message, MemoryChunk, SessionKey, Task, and Goal.

  dartclaw_security/     Guard framework, concrete guards, content
                         classification, redaction, and guard audit primitives.

  dartclaw_core/         No SQLite. Harness abstraction, channel interfaces
                         and shared routing, config, event bus, container
                         config, and file-based services. Shareable with a
                         future Flutter app.

  dartclaw_config/       Shared config editing/metadata utilities used by the
                         server and config API.

  dartclaw_whatsapp/     WhatsApp integration and config registration.

  dartclaw_signal/       Signal integration and config registration.

  dartclaw_google_chat/  Google Chat integration and config registration.

  dartclaw_storage/      SQLite3. Search index, tasks, goals, related storage
                         services, and transient turn recovery state.

  dartclaw_server/       Shelf HTTP. API routes, web UI templates, turn
                         orchestration, MCP server, scheduling, task execution,
                         and server-only behavior, workspace, maintenance, and
                         observability services.

  dartclaw_testing/      Shared test doubles and in-memory helpers reused
                         across workspace packages.

  dartclaw/              Convenience umbrella package that re-exports the main
                         SDK surface from `dartclaw_core`, `dartclaw_storage`,
                         and the bundled channel packages.

apps/
  dartclaw_cli/          CLI app (AOT-compilable): serve, status,
                         rebuild-index, deploy, token, and maintenance
                         commands.
```

The key boundaries are simple: `dartclaw_core` stays SQLite-free, concrete guards live in `dartclaw_security`, concrete channel implementations live in per-channel packages, and server-only behavior/workspace/maintenance/observability code lives in `dartclaw_server`.

## Storage Design

DartClaw uses a dual storage strategy: **files are the source of truth** for sessions, messages, memory, and config. **SQLite is used for derived indexes and relational data** (search index, tasks).

### File-Based Storage

```
~/.dartclaw/                          # dataDir (configurable)
├── dartclaw.yaml                     # Config (YAML, backup-on-write)
├── kv.json                           # Global key-value store
├── audit-YYYY-MM-DD.ndjson           # Guard audit log partitions with retention cleanup
├── usage.jsonl                       # Token tracking (append + rotate)
├── state.db                          # Active turn recovery state
├── projects.json                     # Project registry (multi-project support)
├── sessions/
│   ├── .session_keys.json            # Deterministic key → UUID index
│   └── <uuid>/
│       ├── meta.json                 # Session metadata
│       └── messages.ndjson           # Conversation transcript (append-only)
├── projects/
│   └── <projectId>/                  # Git repository clones
└── workspace/
    ├── MEMORY.md                     # Long-term memory
    ├── errors.md                     # Auto-populated error log
    ├── learnings.md                  # Agent-written insights
    ├── SOUL.md, USER.md, TOOLS.md    # Behavior files (identity, profile, env)
    └── memory/
        └── YYYY-MM-DD.md            # Daily turn logs
```

Mutable files use atomic writes (temp file + rename) to prevent corruption on crash. Services with concurrent callers serialize writes via Dart `StreamController` queues.

### SQLite

| Database | Contents | Authoritative? |
|----------|----------|----------------|
| `search.db` | FTS5-indexed memory chunks (BM25 ranking) | No — derived from MEMORY.md, rebuildable via `dartclaw rebuild-index` |
| `tasks.db` | Tasks, goals, task artifacts, turn traces, task events | Yes — relational data with state machine transitions |
| `state.db` | Active turn recovery rows keyed by session ID | No — transient operational state only |

### Crash Recovery

Messages in NDJSON files use their line number as a cursor. After a crash or restart, the client requests "all messages after cursor X" to resume exactly where it left off. This is more reliable than timestamp-based recovery because line numbers are monotonic and gap-free.

Separately, active turn reservations are persisted in `state.db` via `TurnStateStore`. On restart, the server scans that table for orphaned turns, cleans the rows, and surfaces a one-time recovery notice for the affected sessions.

### Memory Search

When the agent calls `memory_save`, text is appended to `MEMORY.md`, stripped of markdown, split into paragraph-sized chunks, and inserted into the FTS5 index. `memory_search` queries the index and returns BM25-ranked results. A nightly `MemoryPruner` archives entries older than 90 days and removes exact duplicates to keep the index focused.

For more detail on memory configuration, see the [Search guide](search.md).

## Turn Orchestration

A "turn" is a single round-trip: user message in, agent response out. The Dart host manages turns through several layers:

1. **TurnManager** — receives the user message, selects a harness from the pool, delegates to a TurnRunner
2. **TurnRunner** — executes the full turn lifecycle for a single harness: guard evaluation, message persistence, system prompt composition, streaming, cost tracking, crash recovery
3. **AgentHarness** — abstract interface to agent binaries. `ClaudeCodeHarness` (Claude) and `CodexHarness` (OpenAI) are the concrete implementations. `HarnessFactory` creates the appropriate type based on provider ID
4. **HarnessPool** — manages multiple harness instances for concurrent execution. Runner 0 is the "primary" (reserved for interactive chat, cron, channels). Runners 1..N are the "task pool" (acquired by the task executor for background work). In mixed deployments, pool workers can be from different providers

```
User message (web / channel / cron / task)
    │
    ▼
TurnManager ──→ HarnessPool.primary (interactive)
    │               or
    │           HarnessPool.tryAcquire() (background task)
    │
    ▼
TurnRunner (per-harness)
    ├── GuardChain evaluation (input sanitizer, command/file/network guards)
    ├── System prompt composition (behavior files + context)
    ├── AgentHarness.turn() → agent binary via JSONL
    ├── SSE streaming to web UI
    ├── Message persistence (NDJSON append)
    ├── Usage tracking (token attribution)
    └── Self-improvement (errors.md / learnings.md on failure)
```

## Channel System

DartClaw receives messages from multiple sources through a unified channel abstraction. Each channel normalizes inbound messages into a `ChannelMessage` and formats outbound responses for its delivery requirements.

| Channel | Transport | Sidecar |
|---------|-----------|---------|
| **Web** | HTTP API + SSE | None |
| **WhatsApp** | Webhook (GOWA binary) | Yes — Go binary, outpost pattern |
| **Signal** | REST API (signal-cli-rest-api) | Yes — Docker container |
| **Google Chat** | Webhook + REST API | None — pure REST, GCP service account auth |

All channels flow through the same `ChannelManager`, which handles session key routing, DM access control, group mention gating, and message queuing. Session keys are deterministic — the same contact on the same channel always maps to the same session, configurable via scoping rules (per-contact, per-channel, shared).

For Google Chat thread binding, task notifications can create a dedicated Chat thread and DartClaw persists a `ThreadBinding` that maps that thread back to the correct task session. Replies in that thread reuse the bound route context, which keeps task discussion and review commands such as `accept`, `reject`, and `push back` scoped to the task instead of falling back to the shared room session.

Runtime governance also applies at the channel boundary. Per-sender rate limits, deployment-wide token budgets, and facilitator-only emergency controls (`/stop`, `/pause`, `/resume`) are enforced before normal inbound processing continues.

The shared channel abstractions and routing live in `dartclaw_core`; the WhatsApp, Signal, and Google Chat integrations live in their own packages.

For channel setup, see the [WhatsApp](whatsapp.md), [Signal](signal.md), and [Configuration](configuration.md) guides.

## Task Orchestrator

The task system (added in 0.8) enables structured background work with review flows. Tasks move through a state machine:

```
draft → queued → running → review → accepted
                   │         │
                   │         ├→ rejected
                   │         └→ queued (push-back)
                   │
                   └→ interrupted → queued
```

Key components:

- **TaskService** — CRUD + state machine transitions, SQLite persistence, now owned by `dartclaw_server`
- **TaskExecutor** — polls for queued tasks, acquires a harness from the pool, executes the task, collects artifacts
- **WorktreeManager** — for coding tasks, creates git worktrees scoped to the task's assigned project. On accept, changes are pushed to the remote as a branch or PR (if configured). On reject, the worktree is cleaned up
- **DiffGenerator** — produces structured diffs (files changed, additions, deletions, hunks) stored as artifacts
- **AgentObserver** — tracks per-runner state (idle/busy) and metrics for the observability API
- **TaskEventRecorder** — records structured task events (status changes, tool calls, artifacts, token usage) to the task timeline, visible on the task detail page

Channel-originated task creation and review do not call the service directly from `dartclaw_core`. `ChannelManager` stays in `dartclaw_core`, but it now uses injected `TaskCreator`, `TaskLister`, and review-handler callbacks supplied by `dartclaw_server`.

Tasks are typed (`coding`, `research`, `writing`, `analysis`, `automation`, `custom`), and each type maps to a security profile that determines which container the task runs in.

For a user-facing comparison of task runners vs subagent delegation (the two agent execution models), see the [Agents guide](agents.md).

## Project Management

Added in 0.14. DartClaw can manage multiple git repositories, routing coding tasks to the correct project and pushing results back on accept.

**How it works**:
1. Register an external git repository via the web UI (`/tasks`) or the config API. Provide the remote URL and optionally a credential reference (SSH key or token name stored in the credential store).
2. DartClaw clones the repository into `<dataDir>/projects/<projectId>/` and keeps it fresh with periodic auto-fetch.
3. When a coding task targets that project, `WorktreeManager` creates an isolated git worktree for the task's working branch — the agent operates in this worktree, isolated from other concurrent tasks.
4. On task accept, the result is pushed to the remote as a branch (or as a pull request, if `prStrategy: pr` is configured).
5. On task reject, the worktree is cleaned up.

**Backward compatibility**: If no projects are configured, DartClaw synthesizes an implicit `_local` project from the directory where `dartclaw serve` was started. Existing single-project deployments work unchanged — no migration required.

## Container Isolation

When Docker is enabled, DartClaw runs agent processes inside containers with kernel-level isolation. Containers are organized by **security profile** — each profile defines what the agent can access at the OS level.

| Profile | Mounts | Network | Used By |
|---------|--------|---------|---------|
| `workspace` | `/workspace:rw`, `/project:ro` | `none` | Main chat, coding tasks, cron, channels |
| `restricted` | No workspace | `none` | Search agent, research tasks |

Multiple concurrent tasks sharing the same profile share one container (via `docker exec`). This keeps the container count small (2-4) regardless of task parallelism (up to 10 concurrent).

Container hardening: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, non-root user, read-only root filesystem, `--network none`. API credentials are injected via a credential proxy on a Unix socket — keys never exist inside the container environment.

Container names include a hash of the data directory, preventing collisions when running multiple DartClaw instances on the same Docker daemon.

> DartClaw runs without Docker in development mode. This is acceptable for local use where you trust the agent. For any networked or shared deployment, container isolation is essential.

For full security details, see the [Security guide](security.md).

## Security Model

DartClaw follows **defense-in-depth** — multiple overlapping layers, each providing protection even if another fails.

| Layer | Mechanism |
|-------|-----------|
| **Container isolation** | Docker kernel namespaces (PID, network, mount, user). The primary security boundary. |
| **Credential isolation** | API keys injected via Unix socket proxy. Container environment is clean. |
| **Guard chain** | InputSanitizer (prompt injection), CommandGuard (shell injection), FileGuard (path traversal), NetworkGuard (allowlist), ContentGuard (agent output scanning) |
| **Message redaction** | Outbound secret/PII redaction via configurable patterns |
| **Audit logging** | All guard verdicts logged to date-partitioned `audit-YYYY-MM-DD.ndjson` files with retention cleanup. Viewable in the health dashboard. |
| **Usage tracking** | Per-agent token attribution, daily budget enforcement, and budget warnings posted to SSE and originating channels |
| **Mount allowlist** | Only approved directories visible inside containers |
| **XSS prevention** | Server-side HTML escaping (Trellis `tl:text`) + client-side DOMPurify |

The concrete guard chain lives in `dartclaw_security` and is wired into the running server by the Dart host.

For configuration and guard details, see the [Security guide](security.md).

## Scheduling and Maintenance

DartClaw runs background work on cron schedules:

- **Scheduled jobs** — user-defined cron entries (morning briefing, research tasks, custom prompts). Each job gets its own session via deterministic `SessionKey.cronSession(jobId)`.
- **Heartbeat** — periodic health check
- **Memory pruning** — archives old entries, removes duplicates, enforces disk budget
- **Session maintenance** — prunes idle sessions, enforces count caps and disk budgets, cleans up orphaned cron sessions
- **Task automation** — scheduled jobs can create tasks that enter the review queue

Jobs are managed via the web UI (`/scheduling`) or the config API. See the [Scheduling guide](scheduling.md).

## Event Bus

Internal components communicate through a lightweight typed event bus. This decouples producers from consumers — adding a new reaction to an event requires zero changes to the code that fires it.

Events use Dart 3 sealed classes, so the compiler catches missing handlers when new event types are added. Current event types include:

- **GuardBlockEvent** — a guard blocked or warned on input
- **ConfigChangedEvent** — configuration values changed via the API
- **SessionLifecycleEvent** — session created, ended, or errored
- **TaskLifecycleEvent** — task status changed, review ready
- **ContainerLifecycleEvent** — container started, stopped, or crashed
- **AgentStateChangedEvent** — a harness runner changed state (idle/busy)

Events are fire-and-forget notifications. If no listener is subscribed, the event is silently dropped (broadcast stream semantics).

## MCP Server

DartClaw exposes an internal MCP (Model Context Protocol) server that provides custom tools to the agent. Tool calls are proxied through the JSONL control protocol as JSONRPC messages — no external MCP server process needed.

Built-in MCP tools:

| Tool | Purpose |
|------|---------|
| `memory_save` / `memory_search` | Persistent memory with FTS5 search |
| `sessions_send` | Synchronous delegation to a subagent (blocks until complete) |
| `sessions_spawn` | Async delegation to a subagent (returns session ID immediately) |
| `web_fetch` | Fetch web content (SSRF-hardened: DNS resolution, private IP blocking) |
| `brave_search` / `tavily_search` | Web search via configurable provider |

Additional tools can be registered via the `registerTool()` SDK API.

## Web UI Architecture

The web UI avoids JavaScript build toolchains entirely:

- **Server-side**: Trellis template engine with HTML fragment rendering. Templates are `.html` files with `tl:` attributes for auto-escaping.
- **Client-side**: HTMX for SPA-like navigation and form submission, HTMX SSE extension for streaming, marked.js for markdown, highlight.js for syntax highlighting. Vendored locally — no CDN dependency at runtime.
- **Styling**: Custom CSS with Catppuccin-based design tokens. Light/dark theme toggle.

### SSE Streaming

When you send a message:

1. HTMX POSTs the form to `/api/sessions/:id/send`
2. Server starts the turn and returns an HTML fragment with `hx-ext="sse"` attributes pointing to the SSE endpoint
3. The HTMX SSE extension opens an EventSource and handles reconnection
4. Server pushes HTML fragment events: `delta` (text chunks), `tool_use` (tool indicators), `tool_result` (OOB swap updates), `done` (triggers close)
5. HTMX swaps each fragment into the DOM declaratively

### Dashboard Pages

| Page | Purpose |
|------|---------|
| `/` | Main chat with session sidebar |
| `/tasks` | Task dashboard (filterable, SSE badge count, agent overview) |
| `/tasks/:id` | Task detail (embedded chat, artifact panel, review controls) |
| `/health-dashboard` | System health, guard audit log, usage stats |
| `/memory` | Memory overview, file browser, pruner history |
| `/settings` | Live configuration editor, guard config viewer, channel access management |
| `/scheduling` | Cron job management (add/edit/delete) |

## Configuration System

DartClaw is configured via `dartclaw.yaml` with live editing support:

- **Config API** — `GET/PATCH /api/config` reads from disk and writes with YAML round-trip preservation (comments survive edits)
- **Config validation** — `ConfigMeta` registry with validators, ensuring invalid values are rejected before write
- **Backup on write** — every config change creates a `.bak` file
- **Graceful restart** — when a config change requires restart, the server drains active turns (30s timeout), restarts services, and sends an SSE banner to connected clients

For the full config reference, see the [Configuration guide](configuration.md).

## Lineage

DartClaw evolved through three iterations:

- **OpenClaw** — original Node.js prototype with comprehensive security patterns
- **NanoClaw** — stripped-down version that identified the core feature set and proved OS-level isolation
- **DartClaw** — current: rewritten in Dart for AOT compilation, zero npm runtime, security-first design

The Dart rewrite was motivated by AOT compilation to a single binary (no runtime dependencies beyond SQLite) and eliminating the Node.js/npm supply chain from the runtime. The architecture decisions and their rationale are documented in detail in the development repository.

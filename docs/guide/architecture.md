# Architecture

DartClaw is a 2-layer agent runtime where each layer has a distinct role and trust level. This document explains how they fit together, why they're separated, and where the boundaries are.

## The Two Layers

```
┌──────────────────────────────────────────────┐
│  Layer 1: Dart Host                          │
│  ─────────────────                           │
│  Owns: file storage, HTTP API, web UI,       │
│        turn orchestration, security policy    │
│  Trust: FULL — this is your code             │
└──────────────────────┬───────────────────────┘
                       │ JSONL control protocol (stdin/stdout)
┌──────────────────────▼───────────────────────┐
│  Layer 2: claude CLI Binary                  │
│  ──────────────────────────                  │
│  Owns: agent reasoning, tool execution,      │
│        bash commands, file operations        │
│  Trust: SANDBOXED — isolated in Phase 2      │
└──────────────────────────────────────────────┘
```

### Layer 1: Dart Host

The Dart host is the control plane. It's a Shelf HTTP server + file-based storage that:

- **Stores state** — sessions and messages in NDJSON files, memory in MEMORY.md + SQLite FTS5 search index
- **Serves the web UI** — HTML templates (Dart string functions), CSS, and JavaScript (HTMX + SSE)
- **Orchestrates turns** — receives user messages, composes system prompts, spawns the claude binary, streams results
- **Enforces security** — API key isolation, safety rule injection, memory operation routing

The host never executes agent logic directly. It spawns the `claude` binary as a subprocess and controls what information flows in and out.

### Layer 2: claude CLI Binary

The actual agent runtime. The Dart host spawns this binary to execute each turn. It:

- Reasons about the user's request
- Decides which tools to use (bash, file read/write, etc.)
- Executes tools and incorporates results
- Streams JSONL events back to the Dart host (text deltas, tool use, tool results)

The Dart host manages the claude binary lifecycle, including auto-restart with exponential backoff on crash.

## Communication: The JSONL Control Protocol

Dart and the claude CLI binary communicate over stdin/stdout using a **JSONL** (JSON Lines) control protocol.

### Message Flow

```
Dart Host                              claude CLI Binary
    │                                       │
    │──── spawn with args + env ───────────>│
    │                                       │
    │<──── system init (JSONL) ─────────────│
    │<──── stream text delta (JSONL) ───────│
    │<──── stream text delta (JSONL) ───────│
    │<──── stream tool_use (JSONL) ─────────│
    │<──── stream tool_result (JSONL) ──────│
    │<──── stream text delta (JSONL) ───────│
    │<──── result (JSONL) ──────────────────│
    │                                       │
```

**Key design choice**: The Dart host drives the claude binary directly — no intermediate bridge layer. The JSONL protocol is parsed natively in Dart using a sealed class hierarchy (`ClaudeMessage` types: `SystemInit`, `StreamTextDelta`, `StreamToolUse`, `StreamToolResult`, etc.).

### Why JSONL over stdin/stdout?

- No network port needed (simpler than HTTP or WebSocket)
- Works seamlessly when the binary runs inside a Docker container
- One line = one message — no framing issues
- Native Dart JSON parsing, no additional protocol libraries needed

## Database Design

File-based storage (NDJSON + JSON) for sessions/messages/kv, with SQLite for search index:

| Table | Purpose |
|-------|---------|
| `sessions` | Chat sessions (id, title, timestamps) |
| `messages` | All messages with auto-increment `cursor` column for crash recovery |
| `memory_chunks` | FTS5-indexed memory entries for full-text search |
| `kv_state` | Key-value store for global settings |

### Crash Recovery

Messages have an auto-incrementing `cursor` column (separate from their UUID `id`). After a crash or restart, the client can request "all messages after cursor X" to resume exactly where it left off. This is more reliable than timestamp-based recovery.

### Memory Search

Memory uses SQLite FTS5 with BM25 ranking. When the agent calls `memory_save`:

1. Text is appended to `MEMORY.md` (human-readable log)
2. Text is stripped of markdown formatting
3. Long text is split into paragraph-sized chunks
4. Each chunk is inserted into `memory_chunks` (which auto-syncs to the FTS5 index via triggers)

Searching with `memory_search` queries the FTS5 index and returns results ranked by relevance.

## Security Model

DartClaw follows **defense-in-depth** — multiple overlapping layers, each providing protection even if another fails.

### Current (MVP / Phase 1)

| Layer | What It Does | Limitation |
|-------|-------------|------------|
| **Credential isolation** | `ANTHROPIC_API_KEY` not passed to agent subprocess environment | Only protects the API key, not other secrets |
| **Safety rules** | System prompt rules injected every turn (no exfiltration, no credential exposure) | Prompt-level only — can be ignored by sufficiently confused agent |
| **XSS prevention** | Server-side HTML escaping + client-side DOMPurify | Standard web security |

### Planned (Phase 2)

| Layer | What It Does |
|-------|-------------|
| **Docker containers** | Kernel-level isolation — the agent literally cannot access host filesystem or network |
| **Dart HTTP proxy** | API keys stay on the host; the container gets a Unix socket proxy that injects credentials |
| **Mount allowlist** | Only explicitly approved directories are visible inside the container |
| **Network control** | Container runs with `network:none`; only the Dart proxy can reach external services |

### Why Docker Is Needed

The claude binary runs with full OS-level access — any bash command can access the host filesystem, network, and environment. Application-level controls (credential isolation, safety rules) are defense-in-depth only.

Docker provides kernel-level namespaces: separate PID, network, mount, and user spaces. Even with full bash access inside the container, the agent cannot escape to the host. This is the real security boundary — everything else is defense-in-depth.

> **MVP runs without Docker.** This is acceptable for local development where you trust the agent's actions. For any networked or shared deployment, Docker isolation (Phase 2) is essential.

## Web UI Architecture

The web UI avoids JavaScript build toolchains entirely:

- **Server-side**: Trellis template engine with HTML fragment rendering. Templates are `.html` files with `tl:` attributes.
- **Client-side**: HTMX for navigation and form submission, HTMX SSE extension (`htmx-ext-sse`) for streaming, marked.js for markdown, highlight.js for syntax highlighting. HTMX and marked loaded from CDN; SSE extension, highlight.js, and DOMPurify vendored locally.
- **Styling**: Custom CSS with design tokens (variables for colors, spacing, typography). Light/dark theme toggle.

### SSE Streaming Flow

When you send a message:

1. HTMX POSTs the form to `/api/sessions/:id/send`
2. Server starts the turn and returns an HTML fragment with `hx-ext="sse"` and `sse-connect` attributes pointing to the SSE endpoint
3. The HTMX SSE extension automatically opens an EventSource to that URL and handles reconnection
4. Server pushes HTML fragment events: `delta` (`<span>` text chunks), `tool_use` (tool indicator `<div>`s), `tool_result` (OOB swap updates), `done` (empty, triggers close)
5. HTMX swaps each fragment into the DOM declaratively — text appended, tool indicators updated via OOB swap

This architecture means zero JavaScript bundling, zero WebSocket complexity, and declarative streaming via HTMX attributes.

## Lineage

DartClaw evolved through three iterations:

- **OpenClaw** — original Node.js prototype with security guide
- **NanoClaw** — stripped-down version, identified the core feature set
- **DartClaw** — current: rewritten in Dart for AOT compilation, zero npm runtime, security-first design

The Dart rewrite was motivated by two things: AOT compilation to a single binary (no runtime dependencies beyond SQLite), and eliminating the Node.js/npm supply chain from the runtime.

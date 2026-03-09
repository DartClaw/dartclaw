# Web UI & API Reference

## Web Interface

DartClaw's web UI is a terminal-aesthetic chat interface built with HTMX, the HTMX SSE extension, and server-rendered HTML fragments. No JavaScript build step — everything runs from vendored libraries and a single `app.js` file.

### Layout

The interface has three main areas:

```
┌──────────┬──────────────────────────────────┐
│          │  Topbar (title, delete, theme)    │
│ Sidebar  ├──────────────────────────────────┤
│          │                                   │
│ Sessions │  Chat Area                        │
│ list     │  (messages + streaming)            │
│          │                                   │
│ + New    │                                   │
│          ├──────────────────────────────────┤
│          │  Input (textarea + send)          │
└──────────┴──────────────────────────────────┘
```

### Features

**Session Management**
- **Create**: Click "+ New Session" in the sidebar
- **Switch**: Click any session in the sidebar to load its messages
- **Rename**: Click the title in the topbar to enter edit mode, type a new name, click "Save"
- **Delete**: Click the × button on a sidebar item, or the delete button in the topbar
- **Auto-title**: After the first assistant response, the session is titled with the first ~50 characters of your message

**Chat**
- **Send**: Type in the textarea, press **Ctrl+Enter** (or **Cmd+Enter** on macOS)
- **Streaming**: Responses appear in real-time as the agent generates them
- **Markdown**: Agent responses are rendered with full markdown support (headings, lists, code blocks, links)
- **Syntax highlighting**: Code blocks are highlighted via highlight.js
- **Tool indicators**: When the agent uses tools, you see status lines:
  - `> Reading src/main.dart ...` (in progress)
  - `> Reading src/main.dart ✓` (completed)
  - `> Bash: npm test ✗` (failed)

**Theme**
- Toggle between light and dark mode using the button in the topbar
- Preference is saved in localStorage and persists across sessions

**Responsive**
- On mobile/narrow screens, the sidebar collapses behind a hamburger menu
- Single-column layout below 768px

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Ctrl+Enter / Cmd+Enter | Send message |
| Tab | Focus textarea (when not focused) |

## REST API

All API endpoints return JSON unless otherwise noted. Errors return `{"error": "message"}`.

### Sessions

#### List sessions

```
GET /api/sessions
```

Returns all sessions ordered by last activity (most recent first).

```json
[
  {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "title": "Help me refactor the auth module",
    "created_at": "2026-02-23T10:30:00Z",
    "updated_at": "2026-02-23T11:45:00Z"
  }
]
```

#### Create session

```
POST /api/sessions
```

No body required. Returns the new session.

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440001",
  "title": null,
  "created_at": "2026-02-23T12:00:00Z",
  "updated_at": "2026-02-23T12:00:00Z"
}
```

#### Rename session

```
PATCH /api/sessions/:id
Content-Type: application/json

{"title": "New title"}
```

Title must be non-empty and ≤ 500 characters. Returns the updated session.

#### Delete session

```
DELETE /api/sessions/:id
```

Cancels any active turn on the session, then deletes the session and all its messages (cascade). Returns `204 No Content`.

### Messages

#### Send message and start turn

```
POST /api/sessions/:id/send
Content-Type: application/x-www-form-urlencoded

message=Help+me+write+a+test
```

Stores the user message, composes the system prompt, and starts an agent turn. Returns an HTML fragment (for HTMX) containing an `sse-connect` attribute that connects to the SSE stream via the HTMX SSE extension.

**Error responses**:
- `400` — empty message
- `404` — session not found
- `409` — another turn is already active on this session

#### SSE event stream

```
GET /api/sessions/:id/stream?turn=<turnId>
```

Returns a Server-Sent Events stream. The HTMX SSE extension (`htmx-ext-sse`) handles the EventSource lifecycle, reconnection, and DOM swapping via declarative attributes. Each event contains an HTML fragment:

**Text chunk** (streaming response text):
```
event: delta
data: <span>Here's how to </span>
```

**Tool use** (agent invokes a tool):
```
event: tool_use
data: <div id="tool-toolabc123" class="tool-indicator pending">Read</div>
```

**Tool result** (tool execution completed — uses OOB swap to update existing indicator):
```
event: tool_result
data: <div id="tool-toolabc123" hx-swap-oob="outerHTML:#tool-toolabc123" class="tool-indicator success">Read</div>
```

**Turn completed** (HTMX `sse-close="done"` terminates EventSource):
```
event: done
data:
```

**Turn failed**:
```
event: turn_error
data: <div class="turn-error">Worker process crashed</div>
```

The stream closes after a terminal event (`done` or `turn_error`). The HTMX SSE extension handles reconnection with exponential backoff automatically.

> **Note**: The event is named `turn_error` (not `error`) because the EventSource spec treats `error` as a special event that triggers `onerror` instead of being dispatched as a named event.

### Configuration

#### Get configuration

```
GET /api/config
```

Returns the current server configuration with metadata (allowed values, restart-pending fields).

#### Update configuration

```
PATCH /api/config
Content-Type: application/json

{"agent.model": "claude-sonnet-4-20250514", "server.port": 3333}
```

Validates and applies configuration changes. Fields requiring restart are flagged in the response metadata. Returns `422` with field-level errors on validation failure.

### Scheduling

#### Create job

```
POST /api/scheduling/jobs
Content-Type: application/json

{"name": "daily-summary", "schedule": "0 9 * * *", "prompt": "Summarize yesterday's changes", "delivery": "announce"}
```

#### Update job

```
PUT /api/scheduling/jobs/:name
Content-Type: application/json

{"schedule": "0 10 * * *", "prompt": "Updated prompt", "delivery": "none"}
```

#### Delete job

```
DELETE /api/scheduling/jobs/:name
```

### Memory

#### Get memory status

```
GET /api/memory/status
```

Returns memory overview: file sizes, entry counts, pruner status.

#### Read memory file

```
GET /api/memory/files/:name
```

Returns the raw text content of a memory file (`memory`, `errors`, `learnings`, `archive`).

#### Trigger prune

```
POST /api/memory/prune
```

Runs the memory pruner immediately. Returns prune results (archived, deduped, remaining).

### System

#### Restart server

```
POST /api/system/restart
```

Initiates a graceful restart. Active turns are drained first. Returns `200` on success.

#### Server-Sent Events (global)

```
GET /api/events
```

Global SSE stream for system-level events (e.g., `server_restart`). Separate from per-session chat SSE.

### Web Pages

| Route | Description |
|-------|-------------|
| `GET /login` | Login page with token input |
| `GET /` | Redirects to most recent session, or shows empty app state |
| `GET /sessions/:id` | Full page render with sidebar, topbar, and chat area |
| `GET /sessions/:id/info` | Session info page (tokens, messages, details) |
| `GET /sessions/:id/messages-html` | HTML fragment of message history (for HTMX partial reload) |
| `GET /health-dashboard` | System health status, services, guard audit log |
| `GET /health-dashboard/audit` | Guard audit table fragment (HTMX polling) |
| `GET /settings` | Configuration editor (agent, server, security, scheduling settings) |
| `GET /scheduling` | Scheduling status, heartbeat, job management |
| `GET /memory` | Memory dashboard (overview, pruning, search, file viewer) |
| `GET /memory/content` | Memory dashboard content fragment (HTMX polling) |
| `GET /static/*` | Static assets (CSS, JS, vendored libraries) |

## Memory MCP Tools

These tools are available to the agent during conversations. They're exposed via an MCP server in the Deno worker and bridge back to the Dart host for storage.

| Tool | Parameters | Description |
|------|-----------|-------------|
| `memory_save` | `text` (required), `category` (optional) | Save text to persistent memory. Categories: general, preferences, facts, etc. |
| `memory_search` | `query` (required), `limit` (optional, default 5) | Search memory using FTS5 full-text search. Returns ranked results. |
| `memory_read` | — | Read the full contents of MEMORY.md |

The agent decides when to use these tools based on the conversation context. Memory persists across sessions.

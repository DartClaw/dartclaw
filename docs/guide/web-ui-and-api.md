# Web UI & API Reference

## Web Interface

DartClaw's web UI is a terminal-aesthetic chat interface built with HTMX and Server-Sent Events. No JavaScript build step — everything runs from CDN libraries and a single `app.js` file.

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

Stores the user message, composes the system prompt, and starts an agent turn. Returns an HTML fragment (for HTMX) containing a `data-sse-url` attribute pointing to the SSE stream.

**Error responses**:
- `400` — empty message
- `404` — session not found
- `409` — another turn is already active on this session

#### SSE event stream

```
GET /api/sessions/:id/stream?turn=<turnId>
```

Returns a Server-Sent Events stream. Each event has a `data` field containing JSON:

**Text chunk** (streaming response text):
```
event: message
data: {"type": "delta", "text": "Here's how to "}
```

**Tool use** (agent invokes a tool):
```
event: message
data: {"type": "tool_use", "tool_name": "Read", "tool_id": "tool_abc123", "input": {"file_path": "/src/main.dart"}}
```

**Tool result** (tool execution completed):
```
event: message
data: {"type": "tool_result", "tool_id": "tool_abc123", "output": "file contents...", "is_error": false}
```

**Turn completed**:
```
event: message
data: {"type": "done"}
```

**Turn failed**:
```
event: message
data: {"type": "error", "message": "Worker process crashed"}
```

**Turn cancelled**:
```
event: message
data: {"type": "cancelled"}
```

The stream closes after a terminal event (`done`, `error`, or `cancelled`).

### Web Pages

| Route | Description |
|-------|-------------|
| `GET /` | Redirects to the most recent session, or shows empty app state |
| `GET /sessions/:id` | Full page render with sidebar, topbar, and chat area |
| `GET /sessions/:id/messages-html` | HTML fragment of message history (for HTMX partial reload) |
| `GET /static/*` | Static assets (CSS, JS) |

## Memory MCP Tools

These tools are available to the agent during conversations. They're exposed via an MCP server in the Deno worker and bridge back to the Dart host for storage.

| Tool | Parameters | Description |
|------|-----------|-------------|
| `memory_save` | `text` (required), `category` (optional) | Save text to persistent memory. Categories: general, preferences, facts, etc. |
| `memory_search` | `query` (required), `limit` (optional, default 5) | Search memory using FTS5 full-text search. Returns ranked results. |
| `memory_read` | — | Read the full contents of MEMORY.md |

The agent decides when to use these tools based on the conversation context. Memory persists across sessions.

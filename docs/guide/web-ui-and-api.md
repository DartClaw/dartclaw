# Web UI & API Reference

## Web Interface

DartClaw's web UI is a terminal-aesthetic chat interface built with HTMX, the HTMX SSE extension, Trellis-rendered HTML fragments, and vendored Stimulus controllers. No JavaScript build step is required. Browser behavior lives under `packages/dartclaw_server/lib/src/static/controllers/` and is registered explicitly from `controllers/index.js`.

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
│          │  Rich composer + context tray      │
└──────────┴──────────────────────────────────┘
```

### Features

**Session Management**
- **Create**: Click "+ New Session" in the sidebar
- **Switch**: Click any session in the sidebar to load its messages
- **Rename**: Click the title in the topbar to enter edit mode, type a new name, click "Save"
- **Delete**: Click the × button on a sidebar item, or the delete button in the topbar
- **Auto-title**: After the first assistant response, the session is titled with the first ~50 characters of your message
- **Archived sessions**: Sessions archived by maintenance appear in a collapsible "Archived (N)" subsection at the bottom of the sidebar. Expand/collapse state persists in localStorage.
- **Workflow chat commands**: Web chat supports `/workflow list` and `/workflow run <name> VAR=value` without creating a normal agent turn

**Chat**
- **Rich composer**: Type in the composer, press **Ctrl+Enter** (or **Cmd+Enter** on macOS), or use the circular send button. During streaming the button changes to stop.
- **Streaming**: Responses appear in real-time as the agent generates them
- **Interrupted turns**: Failed or recovered turns render inline retry guidance through the `turn_error` stream path and persisted turn-failed messages.
- **Command palette**: Type `/` or use the command button to discover available slash commands. Availability is filtered by session type and request permissions.
- **Attachments**: Drag, paste, or select files. Uploaded files appear as removable chips before send and are submitted as structured message metadata.
- **Context references**: Type `@` to resolve sessions, projects, files, tools, and memory into explicit removable chips.
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

**Workflow Operations**
- **Workflow launch form**: The `/workflows` page now includes an inline launch form on each workflow definition card
- **Validation**: Required workflow variables are validated inline before a run starts
- **Redirect**: Successful launches navigate directly to `/workflows/<runId>`
- **Other trigger surfaces**: Chat `/workflow run` commands and the GitHub PR webhook share the same launch path – see [Workflow Triggers](workflows.md#workflow-triggers) for the full surface

**Guard Editor** (Settings page)
- **Manage guard extensions**: Admins list, add, edit, delete, and test command/file/network/input-sanitizer guard extensions without hand-editing YAML
- **In-UI tester**: Evaluate a sample command, path, or URL through the real runtime guard semantics
- **Fail-closed + activation status**: Invalid changes are rejected before save; responses separate immediately-active from pending-restart changes
- **Admin-gated**: Editing and testing require admin access, enforced server-side – see [Security § Guard Editor](security.md#guard-editor-web-ui)

**Knowledge Hub**
- **Browse**: Open `/knowledge` to inspect wiki, temporal KG, memory, and inbox/search-derived knowledge in one read-only view
- **Filter**: Use `q` and `layer` query parameters, for example `/knowledge?q=release&layer=kg`
- **Attribution**: The shared source-attribution component keeps wiki pages, KG facts, memory entries, and inbox sources traceable
- **Read-only**: Ingestion and invalidation remain MCP/tool or job operations

**Temporal KG Timeline**
- **Open**: Use `/knowledge/timeline` for the category-first temporal-KG timeline
- **As-of view**: Add `as_of=<ISO-8601 timestamp>` to inspect the graph at a point in time, for example `/knowledge/timeline?as_of=2026-01-01T00:00:00Z`
- **Validity windows**: Facts render with valid-from/valid-until windows where present
- **Contradictions and supersession**: Superseded or contradictory facts stay visible as timeline evidence

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

#### Get session detail

```
GET /api/sessions/:id
```

Returns the persisted session metadata for a single session.

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

Title must be non-empty and ≤ 120 characters. Returns the updated session.

#### Delete session

```
DELETE /api/sessions/:id
```

Cancels any active turn on the session, then deletes the session and all its messages (cascade). Returns `204 No Content`.

### Messages

#### Discover session commands

```
GET /api/sessions/:id/commands
```

Returns slash commands available for the session context. Archive and task sessions return an empty list. Workflow commands require the workflow handler; `/workflow run` is advertised only when the request has admin permission.

#### Upload an attachment

```
POST /api/sessions/:id/attachments
Content-Type: application/json

{"filename":"notes.md","mediaType":"text/markdown","size":8,"contentBase64":"IyBOb3Rlcwo="}
```

Stores an attachment under the session and returns structured metadata for the composer chip. Size and payload limits are enforced before storage.

#### Lookup context references

```
GET /api/sessions/:id/references?q=<query>
```

Returns typed reference suggestions for sessions, projects, files, tools, and memory. Submitted references must resolve before the message is accepted.

#### Send message and start turn

```
POST /api/sessions/:id/send
Content-Type: application/x-www-form-urlencoded

message=Help+me+write+a+test&attachments=[]&references=[]
```

Stores the user message, validates rich input metadata, composes the system prompt, and starts an agent turn. Attachments and references are persisted with the message and appended to the turn payload as a JSON-fenced `rich_input_context` block marked as untrusted data. Returns an HTML fragment (for HTMX) containing an `sse-connect` attribute that connects to the SSE stream via the HTMX SSE extension.

**Error responses**:
- `400` – empty message
- `404` – session not found
- `409` – another turn is already active on this session

#### Turn status

```
GET /api/sessions/:id/turn-status
```

Returns the operator-visible active turn snapshot. `state` is one of `idle`, `running`, `waiting`, `stuck`, `cancelling`, `cancelled`, `completed`, or `failed`. `wait_reason` identifies the authoritative blocker when a turn is waiting or stuck:

- `session_lock` - another same-session request is waiting for the active turn to release the session lock.
- `provider_turn` - the provider has accepted the turn but has not produced progress before `harness.turn_monitor.wait_warning_after`.
- `tool_approval` - the provider is waiting on a tool approval decision.
- `unknown` - the provider turn is still active but no more specific wait source is known.

`can_cancel` is the authoritative cancel affordance. Provider-turn and unknown waits can be cancelled once surfaced as `waiting` or `stuck`; ordinary session-lock waits can be cancelled once surfaced unless the active turn is blocked on a non-stale tool approval. Tool approvals remain non-cancellable until the approval wait becomes stale or stuck under the approval timeout policy. Idle snapshots use null turn fields.

```json
{
  "session_id": "session-123",
  "turn_id": "turn-456",
  "provider": "codex",
  "task_id": null,
  "state": "stuck",
  "wait_reason": "session_lock",
  "waiting_since": "2026-03-10T10:00:00.000Z",
  "stuck_since": "2026-03-10T10:02:00.000Z",
  "global_timeout_at": "2026-03-10T10:10:00.000Z",
  "can_cancel": true
}
```

Errors include `TURN_STATUS_FORBIDDEN` when the authenticated request is not operator/admin authorized.

#### Cancel active turn

```
POST /api/sessions/:id/turns/:turn_id/cancel
Content-Type: application/json

{"reason":"operator_cancel"}
```

`reason` is required and must be `operator_cancel`, `admin_cancel`, or `automation_cancel`. A successful active cancel returns `{"status":"cancelled","released_session_lock":true}`. Cancelling a completed or already cancelled turn is a terminal no-op success with `released_session_lock: false`.

Structured error codes: `TURN_CANCEL_FORBIDDEN`, `TURN_CANCEL_BAD_REQUEST`, `TURN_CANCEL_INVALID_REASON`, `TURN_NOT_FOUND`, and `TURN_NOT_CANCELLABLE`.

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

**Tool result** (tool execution completed – uses OOB swap to update existing indicator):
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

{"agent.model": "sonnet", "port": 3333}
```

Validates and applies configuration changes. Fields requiring restart are flagged in the response metadata. Returns `422` with field-level errors on validation failure.
Requires admin access. Non-admin or unauthenticated requests receive `403`.

### Scheduling

#### List jobs

```
GET /api/scheduling/jobs
```

Returns scheduled jobs from the current YAML config.

#### Get job detail

```
GET /api/scheduling/jobs/:name
```

Returns a single scheduled job by name.

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

### Traces

#### Query traces

```
GET /api/traces
```

Supports filtering by `taskId`, `sessionId`, `provider`, `since`, `until`, `limit`, and `offset`.

#### Get trace detail

```
GET /api/traces/:id
```

Returns a single persisted turn trace, including token totals, duration, and tool call records.

### Workflows

#### Start workflow

```
POST /api/workflows/run
Content-Type: application/json

{"definition": "spec-and-implement", "variables": {"FEATURE": "Add trace UI"}}
```

#### Start workflow from the workflows page

```
POST /api/workflows/run-form
Content-Type: application/x-www-form-urlencoded

definition=spec-and-implement&var_FEATURE=Add+trace+UI
```

On success the response includes `HX-Location: /workflows/<runId>`.

#### Pause workflow run

```
POST /api/workflows/runs/:id/pause
```

Pauses a running workflow and returns the updated run as JSON.

#### Resume workflow run

```
POST /api/workflows/runs/:id/resume
```

Resumes a paused workflow, including approval-paused runs, and returns the updated run as JSON.

#### Cancel workflow run

```
POST /api/workflows/runs/:id/cancel
Content-Type: application/json

{"feedback": "Not ready yet"}
```

Cancels a running or paused workflow. Approval rejections can include optional feedback. Successful cancellation returns `204 No Content`.

#### GitHub workflow webhook

```
POST /webhook/github
X-GitHub-Event: pull_request
X-Hub-Signature-256: sha256=<digest>
```

When enabled, pull request events can start the built-in `code-review` workflow. Signature validation uses HMAC-SHA256 and invalid signatures emit `FailedAuthEvent`.

### Tasks

#### Create task guard for `configJson`

```
POST /api/tasks
```

Client-supplied `configJson` keys starting with `_` are rejected with `400 INVALID_INPUT`. Workflow-internal `_` keys remain server-owned and are still allowed when the server sets them internally.

### Channel Access Management

#### Get DM allowlist

```
GET /api/config/channels/:type/dm-allowlist
```

Returns the current DM allowlist for a channel (`whatsapp` or `signal`).

#### Add to DM allowlist

```
POST /api/config/channels/:type/dm-allowlist
Content-Type: application/json

{"entry": "+1234567890"}
```

Adds an entry and persists to YAML. Returns `409` if already present.

#### Remove from DM allowlist

```
DELETE /api/config/channels/:type/dm-allowlist
Content-Type: application/json

{"entry": "+1234567890"}
```

#### Get group allowlist

```
GET /api/config/channels/:type/group-allowlist
```

Returns the group allowlist (restart-required – reads from persisted YAML).

#### Add to group allowlist

```
POST /api/config/channels/:type/group-allowlist
Content-Type: application/json

{"entry": "group-id-here"}
```

Restart-required. Returns `201` on success.

#### Remove from group allowlist

```
DELETE /api/config/channels/:type/group-allowlist
Content-Type: application/json

{"entry": "group-id-here"}
```

#### List pending pairings

```
GET /api/channels/:type/dm-pairing
```

Returns pending pairing codes with remaining TTL.

#### Confirm pairing

```
POST /api/channels/:type/dm-pairing/confirm
Content-Type: application/json

{"code": "ABC12345"}
```

Approves a pending pairing, adding the sender to the DM allowlist. Persists to YAML before updating runtime state.

#### Reject pairing

```
POST /api/channels/:type/dm-pairing/reject
Content-Type: application/json

{"code": "ABC12345"}
```

#### Pairing counts (for badge display)

```
GET /api/channels/pairing-counts
```

Returns `{"whatsapp": 0, "signal": 1}`.

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

#### Task events stream

```
GET /api/tasks/events
```

Task/dashboard clients receive JSON Server-Sent Events. Existing event types include `connected`, `task_status_changed`, `agent_state`, `project_status`, `task_progress`, `task_event`, and `workflow_sidebar_update`. Turn monitor updates are delivered on the same stream as `turn_wait_state`, using the same authoritative `wait_reason` and `can_cancel` semantics as `GET /api/sessions/:id/turn-status`:

```json
{
  "type": "turn_wait_state",
  "session_id": "session-123",
  "turn_id": "turn-456",
  "task_id": "task-789",
  "state": "stuck",
  "wait_reason": "session_lock",
  "can_cancel": true
}
```

After reconnect, clients should refresh the displayed session through `GET /api/sessions/:id/turn-status`.

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
| `GET /settings` | Configuration editor (agent, server, security, sessions, scheduling settings) |
| `GET /settings/channels/:type` | Channel detail page (DM/group access, allowlist management, pairing) |
| `GET /scheduling` | Scheduling status, heartbeat, job management |
| `GET /memory` | Memory dashboard (overview, pruning, search, file viewer) |
| `GET /memory/content` | Memory dashboard content fragment (HTMX polling) |
| `GET /knowledge` | Read-only knowledge hub across wiki, temporal KG, memory, and inbox/search-derived sources |
| `GET /knowledge/timeline` | Read-only category-first temporal-KG timeline; accepts `category` and `as_of` query parameters |
| `GET /knowledge/research` | Read-only rendered `context_research` citation packet view |
| `GET /static/*` | Static assets (CSS, JS, vendored libraries) |

#### Workflow API

Workflow discovery and execution endpoints:

| Method | Route | Description |
|--------|-------|-------------|
| `POST` | `/api/workflows/run` | Start a workflow run from a named definition |
| `POST` | `/api/workflows/run-form` | Start a workflow run from the `/workflows` HTMX form |
| `GET` | `/api/workflows/runs` | List workflow runs (filterable by `status` and `definition`) |
| `GET` | `/api/workflows/runs/<id>` | Get a single run with step/task detail |
| `POST` | `/api/workflows/runs/<id>/pause` | Pause a running workflow |
| `POST` | `/api/workflows/runs/<id>/resume` | Resume a paused workflow |
| `POST` | `/api/workflows/runs/<id>/retry` | Retry a failed workflow run |
| `POST` | `/api/workflows/runs/<id>/cancel` | Cancel a running or paused workflow |
| `GET` | `/api/workflows/runs/<id>/events` | SSE stream for a specific run |
| `GET` | `/api/workflows/definitions` | List workflow summaries |
| `GET` | `/api/workflows/definitions/<name>` | Fetch a full workflow definition |
| `POST` | `/webhook/github` | Trigger webhook-driven workflow launches for matching GitHub PR events |

Common request shape for `POST /api/workflows/run`:

```json
{
  "definition": "spec-and-implement",
  "variables": {
    "FEATURE": "Add pagination"
  },
  "project": "main"
}
```

The route returns the created run as JSON. Missing required variables produce a `400` error with a machine-readable payload; unknown definitions return `404`.

## Memory MCP Tools

These tools are available to the agent during conversations. They're exposed via an in-process MCP server inside the Dart host, and agents reach them over the JSONL control protocol.

| Tool | Parameters | Description |
|------|-----------|-------------|
| `memory_save` | `text` (required), `category` (optional) | Save text to persistent memory. Categories: general, preferences, facts, etc. |
| `memory_search` | `query` (required), `limit` (optional, default 5) | Search memory using FTS5 full-text search. Returns ranked results. |
| `memory_read` | – | Read the full contents of MEMORY.md |

The agent decides when to use these tools based on the conversation context. Memory persists across sessions.

## Temporal Knowledge Graph MCP Tools

The temporal knowledge graph stores source-linked facts with validity windows. It is used for dated recall, timelines, and contradiction pre-screening before new facts are written.

| Tool | Parameters | Description |
|------|-----------|-------------|
| `kg_add` | `entity`, `predicate`, `value`, `valid_from`, `source`, optional `valid_to` | Add a source-linked temporal fact. Returns `status: contradiction` instead of writing when an open fact with the same entity and predicate has a different value. |
| `kg_query` | `entity`, optional `predicate`, `as_of`, `include_invalidated` | Query facts valid at `as_of`, or currently valid facts when omitted. Returns `status: no_result` with an empty fact list when nothing matches. |
| `kg_timeline` | `entity`, optional `predicate` | Return the full timeline for an entity, including invalidation metadata. |
| `kg_invalidate` | `id`, `invalidated_at`, `reason` | Close a fact without deleting its history. |
| `kg_contradictions` | `entity`, `predicate`, `value` | Check whether an incoming fact conflicts with existing open facts. |

Temporal fields must be ISO-8601 dates or timestamps. Date-only values are interpreted as UTC midnight; timestamps must include `Z` or an explicit offset.

# Web UI & API Reference

## Web Interface

DartClaw's web UI is a terminal-aesthetic chat interface built with HTMX, the HTMX SSE extension, Trellis-rendered HTML fragments, and vendored Stimulus controllers. No JavaScript build step is required. Browser behavior lives under `packages/dartclaw_runtime/lib/src/static/controllers/` and is registered explicitly from `controllers/index.js`.

### Layout

The interface has three main areas:

```
┌──────────────┬──────────────────────────────┐
│ ❯ DartClaw   │ Title · project · provider   │
│ Search  ⌘K ✎ │        state  🔍 🔔 ⋯        │
│ All projects⚙├──────────────────────────────┤
│ n waiting    │                              │
│ ┌──────────┐ │  Chat Area                   │
│ │ project  ⏱│ │  (messages + streaming)      │
│ │ Title    ●│ │                              │
│ └──────────┘ ├──────────────────────────────┤
│ Settled (n)  │  Rich composer + context tray │
│ System     ▲ │                              │
└──────────────┴──────────────────────────────┘
```

The rail is 280px by default and resizes between 240 and 420 by dragging its
right edge, by arrow keys once the edge has focus (Shift for a larger step), and
back to 280 with Home or a double-click. The width persists per device. The
panel icon beside the wordmark collapses the rail; the hamburger in the topbar
brings it back.

### Features

**Session Management**
- **Create**: Click the **New chat** icon beside the rail's search row (at narrow widths it moves into the topbar, so creation stays reachable without opening the drawer). If an untouched default chat already exists, DartClaw reopens it instead of accumulating another blank conversation. Blank destinations are labelled **Untitled draft**. Activating New chat from that draft simply returns focus to its composer.
- **Switch**: Click any conversation in the rail to load its messages. A row carries its project and relative time on the first line, its title and a state dot on the second, and — only when there is one — an attention reason, a failure reason or its fork lineage on a third. Hovering or focusing the row swaps the time for **Settle** and **Archive**.
- **Triage**: The inbox keeps creation order stable while showing unread, running, waiting, done, failed and local-draft state. Settle completed and fully read conversations to move them into the paged Settled tail; Restore returns them to their original place. New work restores a settled conversation automatically.
- **Filter, scope and group**: The sliders icon beside the project scope opens **View options** — *Show* (All · Unread · Waiting on you · Running · Failed · Drafts on this device) and *Group by* (None · Project · Status). A non-default filter shows as a removable chip with a **Clear** action. The scope selector narrows the rail to one project. All three are per-device view state: they never change stored order and are not sent to the server.
- **Bulk settle**: **Select conversations** in the same menu reveals a checkbox on every row and a bulk bar with the selection count, a clear action and **Settle**. Each member settles against the revision the row was rendered with, so the result reports per-conversation acceptance. Escape leaves select mode.
- **Waiting count**: A **n waiting on you** row appears above the list only while something is blocked on you, and jumps to the next such conversation.
- **Settle and archive**: Settling is reversible inbox organization; the conversation stays writable and searchable. Archiving is a read-only historical lifecycle used by reset and maintenance, remains searchable under the archived filter, and appears in the separate Archived subsection.
- **Attention**: The topbar bell pages durable completion, failure and input-request events, grouped into **Blocked on you** and **Finished**. A row links back to the exact transcript record; hovering or focusing it reveals approve, reject and dismiss, and the approval actions appear only while the underlying request remains pending. Opening the panel marks the newest unread item per conversation as read.
- **Rename**: For non-workspace conversations, edit the title in the topbar, then press Enter or move focus away to save. The main workspace conversation keeps the fixed **Agent** identity. Beside the title, a context crumb names the conversation's project, provider and model, and a badge reports its state.
- **Delete**: Click the × button on an archived conversation. Active conversations carry settle and archive instead.
- **Auto-title**: A new non-workspace conversation gets an immediate title from the first message. After the first assistant response, one schema-bound title request may replace that fallback. A manual or newer title always wins, and the workspace **Agent** is never auto-titled.
- **Temporary conversations**: Start one from the topbar's overflow menu or the command palette. Creation requires the retention disclosure and is available only when the effective
  provider is a built-in Codex adapter whose exact workspace-container policy passes the launch inventory and whose
  Docker workspace profile is available. Release support also requires the shipped candidate to pass the documented
  real-provider EOF/SIGKILL qualification matrix. The opaque link works only in the current server process. Drafts survive
  in-page navigation but disappear on reload or close. A temporary conversation carries a one-line banner above the
  transcript with its own **Export** and **End** actions. **End temporary chat** waits for active work and its container
  to stop before revoking the link. Provider processing and deliberate workspace or external tool effects can persist.
- **Export**: Reachable from the topbar's overflow menu, the command palette, or a temporary conversation's banner. An authenticated owner can confirm a Markdown download for an ordinary or temporary conversation. It
  contains visible redacted messages, UTC timestamps, branch lineage, and an attachment availability manifest. It never
  embeds attachment bytes. The downloaded file is a deliberate durable copy.
- **Archived sessions**: Sessions archived by maintenance appear in a collapsible "Archived (N)" subsection at the bottom of the sidebar. Expand/collapse state persists in localStorage. Most of them come from the daily reset, which archives every workspace, channel and scheduled conversation at `sessions.reset_hour` and starts a fresh one under the same key — set it to `-1` to keep those conversations running instead.
- **System pages**: Use the bottom-left **System** disclosure to open administration and runtime pages. When one is active, its name remains visible in the collapsed trigger.
- **Workflow tools**: Ask the agent to list or start a workflow; it calls `workflow_list` or `workflow_run`
- **Session cost**: Available only when every recorded turn has provider-reported cost. Missing, partial, and older records without this evidence show cost as unavailable; an explicitly reported zero remains zero. Token counts remain available independently.

**Chat**
- **Search and commands**: **Find in conversation** — from the topbar's overflow menu or the command palette — opens a
  slim bar above the transcript with a match count and previous/next controls. It searches indexed matches in the whole
  conversation, including history outside the loaded 200-message window, and the count reports only matches the bar can
  step to; a page it could not reach is marked with a trailing `+`. Press **Cmd-K** or **Ctrl-K** for global
  conversation search and the shared command catalog. Global search can narrow by lifecycle and project and opens the
  exact matching message. The composer's `>_` button, or typing `/`, filters the same nine built-ins (`/new`, `/reset`, `/stop`, `/status`, `/fork`, `/settle`,
  `/model`, `/effort`, `/help`) plus authorized provider-native skills. An unknown slash-prefixed message is labelled
  **Send to provider** and follows the ordinary message path without byte changes or a capability claim. A built-in
  keeps its canonical action when a native skill has the same name; the skill remains available with a skill label.
- **Rich composer**: The composer floats over the transcript, aligned to the message column. Type, then press
  **Ctrl+Enter** (or **Cmd+Enter** on macOS) or the square arrow send button. Its toolbar carries attach, commands, and
  a context chip naming the project the next turn runs in — with the context window percentage when the provider
  reports a live measurement — and, on the right, the draft-save status, a pill stating the provider, model and effort
  for the next turn, and the send control. Drafts and selected file bytes are saved in this browser and restored after
  reload. A persistent warning with retry, copy, and download actions replaces the saved status if browser storage
  fails.
- **Active turns**: Drafting remains available while a turn runs. The send control becomes **Stop** and cancels only the
  displayed turn; **Queue** beside it accepts the draft in order, and **Steer** in its menu stops the displayed turn and
  sends the follow-up after cancellation is confirmed. Queued and held turns render as one-line rows above the composer
  with edit and remove controls. Failed, cancelled, stopped, and restart-recovered work holds queued items until
  **Release** on the oldest held row sends the next queued message.
- **Streaming**: Responses appear in real-time as the agent generates them
- **Interrupted turns**: Failed or recovered turns render inline retry guidance through the `turn_error` stream path and persisted turn-failed messages.
- **Retained history**: The page loads at most 200 visible messages at a time. Earlier pages and `?message=<id>` deep links
  keep a stable message anchor while tool arguments, partial or terminal results, elapsed time, and linked branches remain
  attached to their owning attempt.
- **Recovery**: Copy preserves the whole displayed message. Retry starts one linked attempt from an unchanged failed or
  cancelled input; edit-and-continue and fork create a linked conversation. These actions do not undo external tool effects.
- **Runtime approval**: An approval card is actionable only while the exact provider request and owning web turn are live.
  Expired, restarted, unsupported, mismatched, and hard-guarded requests remain visible as unavailable or blocked. While
  one is pending, a strip above the composer names the request and offers **Review**, which moves focus to the card; the
  verdict is only ever given on the card that states the action.
- **Tool calls**: A turn's tool calls collapse into one disclosure naming their count, tools and elapsed time. It stays
  open while any call is running, failed or blocked, and closes once every call in the run has succeeded. Opening it
  shows each call's retained arguments and result.
- **Attachments**: Drag, paste, or select files. Uploaded files appear as removable chips before send and are submitted as structured message metadata.
- **Context references**: Type `@` to resolve sessions, projects, files, tools, and memory into explicit removable chips.
- **Effective context**: The context chip and the model pill open one popover each, anchored under the control that
  opens them. **Project** stages the project and working directory and links to Session info, which lists the workspace
  owner, the current turn, and the measurement, behavior and memory records. **Model** stages the provider, model and
  effort: model and effort are pickers over what that provider's adapter accepts, plus its own default, plus any value
  already staged from YAML or the JSON API. Either **Apply to next turn** commits both popovers' current selection. A
  provider change warns about provider-native continuity only while the selection actually differs from the running
  provider. Context changes carry the displayed conversation revision. Fields an adapter does not transport are
  disabled, and a rejected change leaves the draft and prior context intact.
- **Markdown**: Agent responses are rendered with full markdown support (headings, lists, code blocks, links)
- **Syntax highlighting**: Code blocks are highlighted via highlight.js
- **Tool indicators**: When the agent uses tools, you see status lines:
  - `> Reading src/main.dart ...` (in progress)
  - `> Reading src/main.dart ✓` (completed)
  - `> Bash: npm test ✗` (failed)

**Theme**
- On a conversation, **Toggle theme** is the last entry in the topbar's `⋯` overflow menu; on system pages it stays a topbar button
- Preference is saved in localStorage and persists across sessions

**Responsive**
- On mobile/narrow screens, the rail collapses behind a hamburger menu; New chat surfaces as its own topbar icon so creation stays reachable without opening the drawer
- Below 768px the topbar's state badge becomes a dot and the context crumb and `⌘K` hint drop, leaving the title its width
- The rail's per-row settle and archive are hover-only, so select mode and its bulk bar are the touch path for both
- Single-column layout below 768px

**Workflow Operations**
- **Workflow launch form**: The `/workflows` page now includes an inline launch form on each workflow definition card
- **Validation**: Required workflow variables are validated inline before a run starts
- **Redirect**: Successful launches navigate directly to `/workflows/<runId>`
- **Other trigger surfaces**: Agent tools and the GitHub PR webhook share the same launch service – see [Workflow Triggers](workflows.md#workflow-triggers) for the full surface

**Settings** (`/settings`)
- **Every registered config field**: the form is generated from DartClaw's config field registry, so every key the loader honours — except channel settings (their own detail pages) and guard rules (the guard editor below) — has a control, with the key's own description as help text
- **Server-rendered values**: the page arrives with the current values already in it; there is no loading state and no separate config fetch
- **Reload tier per field**: each control is badged `live`, `reload` or `restart`, and the section note says when that section's changes take effect
- **Read-only where it must be**: credential material, placement keys and host-reach bounds render as facts, and no credential value is ever sent to the browser
- **Save is per section**: an invalid value is refused with the message on the offending control and *nothing* in that submission is written; a restart-tier change writes YAML and arms the restart banner
- **YAML stays authoritative**: list-of-object sections (`providers`, `projects`, `mcp_servers`, `agent.agents`, `alerts.routes`, `github.triggers`) are shown read-only with the keys one entry accepts — edit those in `dartclaw.yaml`

**Guard Editor** (Settings page)
- **Manage guard extensions**: Admins list, add, edit, delete, and test command/file/network guard extensions without hand-editing YAML
- **In-UI tester**: Evaluate a sample command, path, or URL through the real runtime guard semantics
- **Fail-closed + activation status**: Invalid changes are rejected before save; responses separate immediately-active from pending-restart changes
- **Admin-gated**: Editing and testing require admin access, enforced server-side – see [Security § Guard Editor](security.md#guard-editor-web-ui)

**Provider credentials** (Settings page)
- **Per-provider cards**: Each provider card shows which credential is presented, its renewal countdown, health state, when it was last checked, and the command that fixes a degraded state
- **Always available**: The same values are served as JSON by `GET /api/providers`, so credential health is visible without any alert channel configured – see [Provider credential health](#provider-credential-health)

**Knowledge Hub**
- **Browse**: Open `/knowledge` to inspect wiki, temporal KG, memory, and inbox/search-derived knowledge in one read-only view
- **Filter**: Use `q` and `layer` query parameters, for example `/knowledge?q=release&layer=kg`
- **Attribution**: The shared source-attribution component keeps wiki pages, KG facts, memory entries, and inbox sources traceable
- **Read-only**: Ingestion and invalidation remain MCP/tool or job operations

**Memory lifecycle**
- **Inspect**: `/memory` separates canonical roles, raw observations, the bounded prompt index, and rebuildable search rows
- **Curate**: enable the `memory-curation` job (`memory.curation.enabled`); run it on demand from Scheduling or `dartclaw jobs run memory-curation`
- **Recover**: Degraded index states keep canonical success intact and point to the stopped-runtime `dartclaw rebuild-index` path

**Temporal KG Timeline**
- **Open**: Select **Timeline** within **Knowledge**, or open `/knowledge/timeline` directly
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

No body is required for a durable session. Returns the new session. Interactive session creation does not accept a
provider override; sends use the fixed primary lane and global `agent.provider`.

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440001",
  "title": null,
  "created_at": "2026-02-23T12:00:00Z",
  "updated_at": "2026-02-23T12:00:00Z"
}
```

To create a supported process-retained conversation, accept its disclosure explicitly:

```json
{"retention":"process","disclosureAccepted":true}
```

Process retention is available only to an authenticated owner when the runtime reports a qualified temporary
conversation capability. It keeps the session, messages, attachments, conversation state, provider home, and usage
context out of durable DartClaw stores. Page drafts stay only in that page and are lost on reload or close. Provider
processing and deliberate workspace or external-tool effects may persist.

#### End a temporary conversation

```
POST /api/sessions/:id/end-temporary
```

The route waits for active work and the dedicated container authority to stop, then clears the process-retained state
and returns `204`. The opaque link is revoked only after cleanup is confirmed. `409 END_INCOMPLETE` leaves the link
retryable when shutdown or cleanup cannot be confirmed.

#### Export a conversation

```
GET /api/sessions/:id/export
POST /api/sessions/:id/export
```

`GET` returns the export disclosure. `POST` requires
`{"confirmed":true,"durableCopyAccepted":true}` and streams a durable Markdown copy containing visible redacted
messages, timestamps, roles, visible tool and approval details, branch lineage, and an attachment availability
manifest. It contains no attachment bytes, hidden messages, or provider-native state.

#### Open a New Chat draft

```
POST /api/sessions/open
```

Used by the web UI's **New Chat** command. Returns the newest untitled, message-free default user session with `200`, or creates one and returns it with `201`. Concurrent requests are coalesced. Generic `POST /api/sessions` remains unconditional.

#### Rename session

```
PATCH /api/sessions/:id
Content-Type: application/json

{"title": "New title"}
```

Title must be non-empty and ≤ 120 characters. The main workspace session has the fixed UI identity **Agent** and
cannot be renamed. Returns the updated session.

#### Delete session

```
DELETE /api/sessions/:id
```

Cancels any active turn on the session, then deletes the session and all its messages (cascade). Returns `204 No Content`.

### Messages

#### Upload an attachment

```
POST /api/sessions/:id/attachments
Content-Type: application/json

{"filename":"notes.md","mediaType":"text/markdown","size":8,"contentBase64":"IyBOb3Rlcwo="}
```

Stores an attachment under the session and returns structured metadata for the composer chip. Size and payload limits are enforced before storage.

The composer reads the server limit from `GET /api/sessions/:id/attachments/limits`. An unclaimed draft attachment can be removed with `DELETE /api/sessions/:id/attachments/:attachment_id`; a handle owned by accepted work is retained.

#### Lookup context references

```
GET /api/sessions/:id/references?q=<query>
```

Returns typed reference suggestions for sessions, projects, files, tools, and memory. Submitted references must resolve before the message is accepted.

#### Read and change effective context

```
GET /api/sessions/:id/conversation-state
PATCH /api/sessions/:id/context
Content-Type: application/json

{"conversation_revision":4,"project_id":"docs","directory":"/workspace/docs","provider":"claude","model":"sonnet","effort":"high"}
```

The conversation snapshot includes `current_context`, `next_context`, and session-scoped telemetry when recorded. A context mutation stages the complete next-turn context only after its revision, project, directory, provider, and adapter-supported overrides pass validation. The next admitted attempt captures that exact snapshot. Stale or unauthorized mutations reject atomically.

#### Send message and start turn

```
POST /api/sessions/:id/send
Content-Type: application/x-www-form-urlencoded

message=Help+me+write+a+test&attachments=[]&references=[]
```

The web composer also sends stable `submission_id` and `revision_id` fields. DartClaw durably claims that identity, validates rich input metadata, and accepts it once. If no turn is active, the committed submission starts a turn. Otherwise it enters the ordered queue. Attachments and references are persisted with the message and appended to the turn payload as a JSON-fenced `rich_input_context` block marked as untrusted data. An HTML request returns the matching active-turn or queued fragment. A request accepting JSON receives the stable message, attempt or queue identity and the authoritative conversation revision.

**Error responses**:
- `400` – empty message
- `404` – session not found
- `409` – the same submission identity names different content or its durable state cannot be reconciled safely

#### Conversation and queue state

```
GET /api/sessions/:id/conversation-state
PATCH /api/sessions/:id/queue/:queue_id
DELETE /api/sessions/:id/queue/:queue_id
POST /api/sessions/:id/queue/release
POST /api/sessions/:id/steer
GET /api/sessions/:id/messages?count=200&before_cursor=<cursor>
GET /api/sessions/:id/messages?count=200&around_message_id=<message_id>
POST /api/sessions/:id/approvals/:request_id
POST /api/sessions/:id/attempts/:attempt_id/retry
POST /api/sessions/:id/messages/:message_id/branch
```

The snapshot is the authority for submission, attempt, and queue state. Each persisted mutation advances its `revision`; clients include that revision when editing, removing, or releasing a queue item. A stale mutation returns the current snapshot without changing accepted work. Queue editing preserves its accepted attachment handles. Release sends only the oldest held item, and only when no active dispatch blocks it. A submission left `uncertain` by a restart records a dispatch whose outcome was never observed: it is never replayed, it blocks neither release nor a new send, and it settles as `failed`, with the reason in its detail, once the session dispatches again. Steer performs confirmed stop followed by ordinary admission.

Its `activity` projection reads the latest retained message identity and current turn status from the existing message and turn authorities. Channel and cron sessions set `ordinary_controls` to false: their existing admission and Stop behavior remains available, while browser Queue and Steer actions are not offered.

History `count` is 1–200. Filtering by the conversation visibility snapshot happens before the storage reader fills the
window. `before_cursor` pages backward; `around_message_id` returns a bounded deep-link window and an explicit target
state. They cannot be combined.

Approval decisions require `attempt_id`, `turn_id`, and `decision` (`approve` or `reject`). Two viewers addressing the
same live request receive its one terminal decision, while only one response reaches the provider. A request without an
exact active provider owner returns `APPROVAL_UNAVAILABLE`. Operator approval is offered only for ordinary human web
turns: Codex must be configured with `approval: on-request`; Claude must use an explicit native `permissionMode` that
can emit `can_use_tool` (`default`, `acceptEdits`, or `plan`). Claude `PreToolUse` callbacks remain automatic guard
evaluation. Background, channel, task, cron, workflow, ACP, Claude `dontAsk`/`bypassPermissions`, and other Codex
approval modes do not expose these cards.

Retry requires a stable `mutation_id`. Branch creation also requires `mutation_id`, plus `kind` (`edit` or `fork`) and
an edited message for `edit`. Repeating an accepted mutation returns the same linked attempt or destination. Rejected,
stale, read-only, and ineligible requests leave source messages, files, and provider state unchanged.

Branch creation resolves the destination from the server's current configured agent and execution policy. A removed or
changed workspace binding makes a new branch unavailable instead of reviving the source session's stale provider or
workspace metadata. The mutation reserves its destination identity before copying history or admitting an edited turn,
so retry after an interrupted write resumes the same destination.

#### Turn status

```
GET /api/sessions/:id/turn-status
```

Returns the operator-visible active turn snapshot. `state` is one of `idle`, `running`, `waiting`, `stuck`, `cancelling`, `cancelled`, `completed`, or `failed`. `wait_reason` identifies the authoritative blocker when a turn is waiting or stuck:

- `session_lock` - another same-session request is waiting for the active turn to release the session lock.
- `provider_turn` - the provider has accepted the turn but is not currently waiting for a tool approval. The status advances from waiting to stuck on the turn-liveness tracker's internal observation thresholds.
- `tool_approval` - the provider is waiting on a tool approval decision.
- `unknown` - the provider turn is still active but no more specific wait source is known.

`can_cancel` is the authoritative cancel affordance. Provider-turn and unknown waits can be cancelled once surfaced as `waiting` or `stuck`; ordinary session-lock waits can be cancelled once surfaced unless the active turn is blocked on a non-stale tool approval. Tool approvals remain non-cancellable until the approval wait becomes stale or stuck under the approval timeout policy. Idle snapshots use null turn fields.

`limit_breach` is `stall` or `turn_timeout` when a cached terminal cancellation came from that configured budget; it is null for active turns, successful turns, failures, and operator cancellations.

The endpoint can briefly return a cached terminal snapshot (`completed`, `cancelled`, or `failed`) so status and cancel clients can resolve consistently. The web UI's operator panel renders only active states (`running`, `waiting`, `stuck`, and `cancelling`), and shows **Cancel Turn** only while `can_cancel` is true.

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
  "can_cancel": true,
  "limit_breach": null
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

#### `POST /api/scheduling/jobs/:name/run`

Starts a live prompt or shell job immediately and returns `202` with `{"name":"daily-summary","status":"started"}`. Returns
`409 CONFLICT` when the job is already running, `404 NOT_FOUND` when it is absent from the live scheduler or not
runnable on demand, and `404 NOT_AVAILABLE` when scheduling is not configured. The route uses the same authentication
as the other scheduling APIs. A job written through the jobs API, the `schedule_upsert` tool or the Scheduling page is
loaded before that write returns, so it is runnable immediately — except a tool write parked under
`scheduling.mutation.approval: operator`, which is loaded when an operator approves it on the Scheduling page.
The pending approval row displays every field the parked write can commit. The durable pending queue accepts at most
100 changes or 1 MiB of compact serialized UTF-8 JSON; `schedule_upsert` reports `pending_queue_full` without changing
the existing queue when either bound is reached.

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

Pass `at` (an ISO-8601 instant in the future) instead of `schedule` for a one-time job; exactly one of the two is
accepted, and a job written with `at` removes itself once it has fired. Create, update and delete responses carry no
`pendingRestart` key: the write loads the job into the running scheduler before it answers. A job id the runtime owns
itself (`heartbeat` and the other built-ins) is refused `409 CONFLICT`. `type` accepts `prompt` and `task` only; a
`type: shell` entry is file-only, and a create naming an id such an entry already holds is refused as a conflict.

#### Update job

```
PUT /api/scheduling/jobs/:name
Content-Type: application/json

{"schedule": "0 10 * * *", "prompt": "Updated prompt", "delivery": "none"}
```

An update or delete touching a `type: shell` entry is refused `400 INVALID_INPUT`, before any file change, with a
reason beginning `Shell jobs are file-only: edit scheduling.jobs in dartclaw.yaml` and naming the entry. The kind exists only by editing the config
file — see [Scheduling § Shell jobs](scheduling.md#shell-jobs).

#### Delete job

```
DELETE /api/scheduling/jobs/:name
```

Refused `400 INVALID_INPUT` for a `type: shell` entry, as for an update.

### Memory

#### Get memory status

```
GET /api/memory/status
```

Returns the operator projection: `collection`, `promptIndex`, `observations`, and `index` objects.
Counts are nullable when evidence is unavailable. Observation `usageKind` is `exact`, `lowerBound`, or `unknown`, while
its warning is `none`, `active`, or `unknown`. The warning is informational – status never deletes observations or blocks writes by aggregate
usage alone.

The `index` object includes `memoryUnembeddedCount` and `conversationUnembeddedCount`. With hybrid search, zero means
the corpus is fully represented by usable vectors, a positive value is the number of current chunks still missing one,
and `null` means the count could not be read. Both are `null` when hybrid search is inactive. `health`, `reason`, and
`action` describe the lexical memory projection; follow the action and the stopped-runtime `dartclaw rebuild-index`
path when it is degraded.

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

### Search

#### Search conversations

```
GET /api/conversation-search?q=marker&scope=global&lifecycle=all&project_id=docs&request_token=17
GET /api/conversation-search/target?session_id=<session>&message_id=<message>
```

The authenticated operator route searches authorized owner and configured-agent conversation indexes. `scope` is
`current` or `global`; lifecycle is `all`, `active`, `settled`, or `archived`. Results include the total before page
limits, a bounded snippet and highlight offsets, conversation revision, project/origin metadata, a stable
`conversation:<session>/message:<message>` citation, and an exact-message URL. The target route reauthorizes the
session and message immediately before navigation. Backend failures return `503 SEARCH_BACKEND_UNAVAILABLE`; missing
or revoked targets return `404 SEARCH_TARGET_UNAVAILABLE` without result derivatives.

```
GET /api/command-catalog?surface=global&session_id=<session>
POST /api/command-actions
```

Catalog responses carry an identity token bound to the principal, provider, workspace, conversation revision,
current authorized skill inventory and effective capabilities. The server refreshes that inventory when a palette
opens and again when an action is selected. The action endpoint accepts only a catalog ID plus that token and rejects
stale context with `409 STALE_COMMAND_CONTEXT`. Native skills appear only when workspace discovery, authorization and
the selected provider adapter all support invocation.

#### Inspect search ranking

```
POST /api/search/inspect
Content-Type: application/json

{"corpus":"memory","query":"release policy","limit":20}
```

This authenticated operator endpoint accepts `memory` or `conversation`, a nonblank query, and an optional integer
limit from 1 to 20. It returns the selected corpus, ordered results with bounded snippets and canonical locator or
session/message provenance, and diagnostics:

```json
{
  "corpus": "memory",
  "results": [],
  "diagnostics": {
    "candidates": [],
    "unembeddedCount": 0,
    "degradations": []
  }
}
```

Each candidate names `documentId`, `chunkIndex`, `keywordRank`, `vectorRank`, `keywordContribution`,
`vectorContribution`, `fusedScore`, and `sourceLayer`. This evidence explains the returned hybrid order; it is bounded
to the request and does not expose stored vectors. `unembeddedCount` applies only to the requested corpus.

Invalid bodies return `400 INVALID_INPUT`. If hybrid inspection, its current-index evidence, or a corpus service is
unavailable, the endpoint returns `503 SEARCH_INSPECTION_UNAVAILABLE` rather than an empty success. The CLI owner for
this endpoint is `dartclaw search inspect`.

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

Returns a single persisted turn trace, including token totals, duration, bounded `toolCalls` detail, exact `toolCallCount` and `failedToolCallCount`, and `toolCallsTruncated`. When truncated, detail contains the first 63 records plus the latest.

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

#### Emergency stop

```
POST /api/emergency-stop
```

Cancels every active turn and every running or queued task, then emits one `EmergencyStopEvent` and an
`emergency_stop` SSE broadcast — the same sequence a channel `/stop` runs, reachable on an install with no channel
enabled. Requires operator/admin access; without it the request is refused with `403` and nothing is cancelled. Returns
`{"turnsCancelled": n, "tasksCancelled": n}`. The CLI equivalent is `dartclaw stop`.

#### Server-Sent Events (global)

```
GET /api/events
```

Global SSE stream for system-level events (e.g., `server_restart`). Separate from per-session chat SSE. A `conversation_changed` event carries `session_id` and `revision`, plus retained turn identity/state when a turn transition caused the invalidation. Clients fetch the authoritative conversation snapshot rather than treating the event as state.

#### Task events stream

```
GET /api/tasks/events
```

Task/dashboard clients receive JSON Server-Sent Events. Existing event types include `connected`, `task_status_changed`, `runner_state`, `project_status`, `task_progress`, `task_event`, and `workflow_sidebar_update`. Turn wait-state updates are delivered on the same stream as `turn_wait_state`, using the same authoritative `wait_reason` and `can_cancel` semantics as `GET /api/sessions/:id/turn-status`:

`runner_state` reflects coordinator lease events and currently observed runners. Worker IDs are runtime identities, not
static pool slots; configured/effective/active/queued/cached/quarantined counts come from the same lease snapshot.

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

#### Provider credential health

```
GET /api/providers
```

Returns one entry per configured provider. When DartClaw has probed the provider's credential, the entry carries these
additional fields – individually `null` where that particular value is not known. A provider with no credential-health
information at all omits the whole block rather than emitting seven null keys.

| Field | Meaning |
|-------|---------|
| `credentialMode` | `subscription` or `api_key` – which credential is being presented |
| `credentialHealth` | `healthy`, `nearing-expiry`, `refresh-failure`, `reauth-required`, `contract-break`, or `unknown` |
| `credentialReauthRequired` | `true` when the operator must re-authenticate before executions can run |
| `credentialExpiresAt` | ISO-8601 renewal deadline, when one can be computed |
| `credentialExpiryDerived` | `true` when the deadline is a best-effort derivation rather than a value the credential states |
| `credentialLastChecked` | ISO-8601 timestamp of the last probe |
| `credentialRemediation` | The exact command or configuration change that resolves the current state |

The entry's top-level `health` field folds this in: a provider whose `credentialHealth` needs operator attention –
anything but `healthy` and `unknown` – reports `"health": "degraded"`, and is counted as degraded in the summary, even
though its binary was found and its credential is `present`. Presence answers whether a credential was found, never
whether it still works, so the two fields would otherwise contradict each other in the same object. `credentialStatus`
is unaffected: it keeps reporting presence – specifically, whether the credential `providers.<id>.auth` selects can be
presented, which is the same question execution admission asks. A provider forced to `auth: subscription` with only an
API key configured therefore reports `missing`, and its `errorMessage` carries the same fix the startup gate prints.

Renewal deadlines are best-effort and marked as derived. A Claude `setup-token` states no expiry, so its deadline is
derived from the ingestion time plus the documented ~1-year lifetime, and `nearing-expiry` starts 30 days out. For Codex
the deadline is the refresh-token renewal deadline – eight days from the store's last write – deliberately *not* the
access token's `exp` claim, which is minutes away and replaced by refresh without any operator action; its
`nearing-expiry` window is the final 48 hours.

`unknown` is informational, not a fault. A provider reports it when no renewal deadline can be computed, and also when a
Claude provider is authenticated through the vendor CLI's own login rather than through DartClaw's store: that case is
verifiable – DartClaw can confirm the login is live – so it raises no alert. Codex has no equivalent exemption. Its
probe only proves that an `auth.json` parses, not that the credential still works, so a Codex provider without a
DartClaw-held credential reports `reauth-required` and alerts instead.

The same values render on the per-provider cards on `/settings`: the credential mode (**Subscription** / **API key**), a
renewal countdown suffixed `· derived` (shown for a subscription credential only, and reading **Renewal deadline
unknown** or **Renewal deadline passed: …** at the edges), a state badge (**Nearing expiry** and **Refresh failed** as warnings,
**Re-authentication required** and **Mediation contract broken** as errors, **Lifetime not checkable** as a neutral
informational badge for `unknown`), a **Checked …** relative timestamp, and the remediation command – labelled **Fix:**
when action is needed, or **DartClaw-managed auth:** for the `unknown` case. A healthy credential shows no badge. The
card's own **Degraded** badge follows the same state, so the card's headline never reads healthy while the credential
section says otherwise.

With no alert target configured, these two surfaces plus a stderr warning line from the `serve` process are what remain:
degraded credential health is logged independently of alert routing, so turning alerts off does not silence it. The line
is an ordinary `WARNING`, so a `logging.level` above that suppresses it along with every other warning.

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
| `GET /settings` | Configuration editor, generated from the config field registry |
| `POST /settings` | Save one settings section (form-encoded, admin-only); answers with that section re-rendered |
| `GET /settings/channels/:type` | Channel detail page (DM/group access, allowlist management, pairing) |
| `GET /scheduling` | Scheduling status, heartbeat, job management |
| `GET /memory` | Memory dashboard (overview, pruning, search, file viewer) |
| `GET /memory/content` | Memory dashboard content fragment (HTMX polling) |
| `GET /knowledge` | Read-only knowledge hub across wiki, temporal KG, memory, and inbox/search-derived sources |
| `GET /knowledge/timeline` | Read-only category-first temporal-KG timeline; accepts `category` and `as_of` query parameters |
| `GET /static/*` | Static assets (CSS, JS, vendored libraries) |

The inbox API uses `conversation_revision` on every mutation so two viewers cannot silently overwrite one another.
`GET /api/inbox` returns stable active or settled pages and complete counts; `POST /api/inbox/settle`,
`POST /api/inbox/:id/restore`, and `POST /api/inbox/:id/read` update membership and foreground read boundaries.
`GET /api/attention` returns durable attention events; its `/read`, `/dismiss`, and `/action` endpoints keep feed
markers separate from exact pending-request resolution.

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

## Orchestration and Content MCP Tools

These tools let the agent start work and produce content on the owner's behalf, from a chat turn or from a scheduled job alike — they take no session, channel or caller argument.

| Tool | Parameters | Description |
|------|-----------|-------------|
| `workflow_run` | `definition`, optional `variables` object, optional `project` | Start a registered workflow. Returns the run's ID and its `/workflows/<id>` location. Required-variable validation, declared defaults and the `PROJECT` fallback are the workflow service's, exactly as for the HTTP start route. |
| `workflow_list` | no arguments | List the workflow catalog with each definition's description, step count and declared variables (required flag and default), so `workflow_run` can be called without a second lookup. An empty catalog is an empty list, not an error. |
| `schedule_upsert` | `id`, `type` (`prompt` or `task`), exactly one of `schedule` (cron) or `at` (ISO-8601 instant), `prompt` or `task`, optional `delivery`, `model`, `effort` | Create or replace a `scheduling.jobs` entry. Schedule validation and the config write go through the same seam the scheduling API uses, and that seam loads the job into the running scheduler before the tool answers — the result reports `loaded`, not a pending restart. Under `scheduling.mutation.approval: operator` the validated write is parked instead and the result is `{"id", "pending": true, "changeId"}` with no `loaded` key; an operator settles it on the Scheduling page. An `at` job runs once and then removes its own entry. A built-in job id is refused. A `type: shell` entry is file-only: `type` accepts only `prompt` and `task`, and an upsert naming an id a shell entry already holds is refused `invalid_request`. |
| `schedule_list` | no arguments | List configured jobs with their cron expressions, whether the running server loaded them, and whether they are paused. Jobs the runtime registers itself are listed as built-in and cannot be edited through `schedule_upsert`; a configured entry the scheduler does not hold is one it could not compose, and the log says why. A `type: shell` row reports `editable: false` — the kind is file-only. |
| `attach_media` | `path`, optional `caption` | Send a workspace file to the owner as a media attachment. The path must resolve — after symlink resolution — inside the workspace; anything that escapes it is refused and nothing is delivered. The recipient is the owner's active direct-message sessions and cannot be chosen in the call. |
| `wiki_write` | `slug`, `title`, `body`, `sources`, optional `confidence` | Author a wiki page through the same entry point knowledge-inbox ingestion uses, so slug containment, frontmatter emission, provenance, the sources union and the shrink floor all apply. The slug must already be lowercase words joined by hyphens. Writing over a stored page replaces its body; a replacement materially shorter than what is stored is refused. |

Every refusal the tool itself makes is a tool-level error (a JSON-RPC success carrying `isError: true`) naming the reason — an invalid cron expression, a path that escapes the workspace, a missing workflow variable. JSON-RPC error codes stay with the dispatch seam's authorization and schema layers: an argument the closed schema does not name is answered with `-32602` before the tool runs.

A containerized agent reaches these six exactly as a host one does. Your own chat turns run as the deployment and
reach all six on either lane; a task, workflow or logical-agent turn reaches only what its own tool policy names, and
one with no policy reaches none of them. Container isolation changes where the turn runs, not what it may call.

## Memory MCP Tools

These tools are available to the agent during conversations. They're exposed via an in-process MCP server inside the Dart host, and agents reach them over the JSONL control protocol.

| Tool | Parameters | Description |
|------|-----------|-------------|
| `memory_apply` | `expectedRevision`, nonempty `operations` array | Atomically add, revise, merge, or remove curated personal entries. Every operation supplies a unique `correlationId`; revise/merge/remove use entry revisions. |
| `memory_observe` | `text`, `role` (`observation` or `learning`) | Capture non-authoritative observations or bounded runtime learnings. |
| `memory_search` | `query` (required), `limit` (optional integer, 1–50, default 5) | Search canonical memory and sourced knowledge using the configured backend's natural-language query path. Non-integer or out-of-range limits are rejected. Returns ranked results with explicit degraded-layer metadata. |
| `memory_read` | `locator`, or `role` + `topic`; optional `limit` | Read a bounded canonical record or reopen a native wiki, knowledge-graph, knowledge-inbox, or eligible QMD search locator through its source owner. `role` + `topic` addresses canonical topic-bearing roles only. |

`memory_apply` is personal-memory-only and uses the collection revision returned by canonical reads/search results. A valid changed request commits once; an exact no-op does not advance revision. Results report canonical and derived-index outcomes separately. Removal audit records contain the entry ID, time, host provenance, and the caller's unfiltered verbatim reason. The host never copies entry content into the record, though the caller's reason may independently quote it.

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

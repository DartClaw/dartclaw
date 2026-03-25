# Canvas

The Shareable Canvas is an agent-controlled visual workspace that renders live HTML content on viewer devices. Workshop facilitators project it on a shared screen, participants access it on their phones via a share link -- no DartClaw login required.

**Added in 0.14.2.**

## How It Works

```
Agent ──→ canvas MCP tool ──→ CanvasService ──→ SSE broadcast ──→ Viewers
                                    │
                         In-memory state           Share link: /canvas/<token>
                         (no persistence)          Zero-auth (token IS the auth)
```

1. The agent calls the `canvas` MCP tool to push HTML content
2. `CanvasService` stores the content in memory and broadcasts via SSE to all connected viewers
3. Viewers open a share link (`/canvas/<token>`) -- a standalone page with zero external dependencies
4. Workshop templates auto-render task boards and stats bars when task state changes

Canvas state is **ephemeral** -- it lives in memory and does not survive server restarts. Share tokens are also ephemeral. This is intentional: workshops are time-bounded events, and restart recovery is a simple "regenerate the share link."

## Configuration

```yaml
# Top-level: required for share link generation
base_url: https://workshop.example.com:3333

canvas:
  enabled: true                     # Master toggle (default: true)
  share:
    default_permission: interact    # view | interact (default: interact)
    default_ttl: 8h                 # Share token TTL (default: 8h)
    max_connections: 50             # Max concurrent SSE connections per session (default: 50)
    auto_share: true                # Reserved for future use (default: true)
    show_qr: true                   # Render QR code in admin panel (default: true)
  workshop_mode:
    task_board: true                # Auto-render kanban task board (default: true)
    show_contributor_stats: true    # Show top-5 contributor leaderboard (default: true)
    show_budget_bar: true           # Show token budget progress bar (default: true)
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `base_url` | string | *(none)* | Server's public URL. Required for the `canvas` tool's `share` action to generate correct share links. Top-level config key (not under `canvas:`). |
| `canvas.enabled` | bool | `true` | Master toggle. When `false`, canvas routes are not mounted and the MCP tool is not registered. |
| `canvas.share.default_permission` | string | `interact` | Default permission tier for new share tokens. `view` = read-only; `interact` = can trigger actions. |
| `canvas.share.default_ttl` | duration | `8h` | Default share token lifetime. Accepts shorthand: `30m`, `8h`, `1d`. |
| `canvas.share.max_connections` | int | `50` | Max concurrent SSE viewers per session. Additional connections are rejected with 429. |
| `canvas.workshop_mode.task_board` | bool | `true` | Auto-push a kanban task board to the canvas on every task status change. |
| `canvas.workshop_mode.show_contributor_stats` | bool | `true` | Include a contributor leaderboard and task counters in the auto-pushed stats bar. |
| `canvas.workshop_mode.show_budget_bar` | bool | `true` | Include a token budget progress bar in the auto-pushed stats bar. |

## Share Links

Share links are the primary access mechanism. They embed the token directly in the URL path:

```
https://workshop.example.com:3333/canvas/AbCdEfGh12345678AbCdEfGh12345678
```

### Permission Tiers

| Tier | Behavior |
|------|----------|
| **view** | Read-only. Sees canvas content. Interaction elements are visually disabled. No nickname prompt. |
| **interact** | Full participation. Prompted for a display name on first visit. Can click `[data-canvas-action]` elements which trigger agent turns. |

### Token Lifecycle

- Tokens are generated via the admin panel (`/canvas-admin`) or the agent's `canvas` tool
- Each token has a TTL (default 8 hours) and is validated on every request
- Expired tokens return 404 (no information leakage -- invalid, expired, and revoked tokens all look the same)
- Tokens do not survive server restarts (regenerate after restart)

### Admin Panel

Navigate to `/canvas-admin` in the web UI. From there you can:

- **Preview** the canvas in a sandboxed iframe
- **Generate** share links with a chosen permission tier, TTL, and label
- **Copy** share link URLs
- **Revoke** active share links
- **View QR codes** for each share link (scan with a phone to open)

## Canvas MCP Tool

The agent uses the `canvas` MCP tool to control the canvas:

| Action | Parameters | Description |
|--------|-----------|-------------|
| `render` | `html` (required) | Push HTML content to the canvas. Max 512KB. |
| `clear` | -- | Remove current content (shows "Waiting" state). |
| `share` | `permission` (optional), `ttl` (optional) | Generate a share link. Returns the full URL. Requires `base_url` to be configured. |
| `present` | -- | Make the canvas visible to viewers. |
| `hide` | -- | Hide the canvas content (dims to 35% opacity). |

Example agent interaction:
```
Agent: I'll set up the workshop canvas with a task board.
→ calls canvas tool: {action: "render", html: "<h1>Workshop Task Board</h1>..."}
→ calls canvas tool: {action: "share", permission: "interact"}
← Share URL: https://workshop.example.com:3333/canvas/AbCd...
Agent: Here's the workshop canvas link: https://workshop.example.com:3333/canvas/AbCd...
```

## Workshop Mode

When workshop mode is enabled (the default), a `WorkshopCanvasSubscriber` listens for task status changes and automatically pushes visual content:

### Task Board

A kanban-style board with four columns: **Queued**, **Running**, **Review**, **Done**. Each card shows:
- Task title (truncated to 40 characters)
- Creator name (from `Task.createdBy`)
- Time in current state
- Pulsing indicator for running tasks

Responsive layout: 4-column on wide screens (>1200px), 2-column on tablets (600--1200px), stacked on phones (<600px).

### Stats Bar

Rendered above the task board:
- **Budget bar**: Token usage with color thresholds (green <50%, yellow 50--80%, red >80%)
- **Counters**: Completed / running / queued task counts
- **Leaderboard**: Top 5 contributors by task count
- **Clock**: Session elapsed time

Workshop mode fragments are debounced (500ms) to avoid flooding SSE on rapid task transitions.

## Standalone Page

The standalone page at `/canvas/:token` is a self-contained HTML document:

- **Zero external dependencies** -- all CSS and JS are inline (single HTTP request)
- **Dark/light mode** -- auto-detected via `prefers-color-scheme` (Catppuccin palette)
- **Responsive** -- projection-friendly `clamp()`-based typography scales from phones to 1080p projectors
- **Connection indicator** -- bottom-right dot: green (connected), yellow (reconnecting), red (disconnected)
- **Late-joiner support** -- new viewers immediately receive the current canvas state

## Security

### Share-Token Authentication

Canvas routes bypass the web UI's `authMiddleware` entirely. Authentication is via the share token embedded in the URL path. This is a deliberate design choice: workshop participants should not need DartClaw credentials.

All token validation failures (invalid, expired, revoked, wrong permission) return **404 Not Found** -- no information leakage about whether a token exists or has expired.

### Content Security Policy

Canvas pages use a **nonce-based CSP**:

```
default-src 'none';
style-src 'unsafe-inline';
script-src 'nonce-{per-request-nonce}';
connect-src 'self';
img-src 'self' data:;
form-action 'self';
frame-ancestors 'self'
```

The nonce is generated server-side per request. Only the page's own `<script>` tag carries the nonce attribute -- any scripts injected via agent-generated HTML content cannot execute.

### Rate Limiting

The canvas action endpoint (`POST /canvas/:token/action`) has a per-token rate limiter: **10 actions per minute**. This prevents a single share-link holder from flooding the agent with turn requests.

### Admin Iframe Sandboxing

The admin panel embeds the canvas in an `<iframe sandbox="allow-scripts allow-forms">`. This prevents agent-generated HTML in the canvas from accessing the admin's session cookies or DOM.

## API Endpoints

### Public (share-token auth)

| Method | Route | Description |
|--------|-------|-------------|
| `GET` | `/canvas/:token` | Standalone canvas page |
| `GET` | `/canvas/:token/stream` | SSE event stream |
| `POST` | `/canvas/:token/action` | Submit interaction (interact tokens only) |

### Admin (cookie/token auth)

| Method | Route | Description |
|--------|-------|-------------|
| `GET` | `/api/canvas/share` | List active share tokens |
| `POST` | `/api/canvas/share` | Create share token |
| `DELETE` | `/api/canvas/share/:token` | Revoke share token |
| `GET` | `/api/sessions/:key/canvas/embed` | Admin embed page |
| `GET` | `/api/sessions/:key/canvas/embed/stream` | Admin embed SSE stream |

### SSE Events

| Event | Data | When |
|-------|------|------|
| `canvas_state` | `{html, visible}` | On initial connection (late-joiner catch-up) |
| `canvas_update` | `{html, visible}` | When content is pushed |
| `canvas_clear` | `{visible}` | When content is cleared |
| `canvas_visible` | `{visible}` | When visibility is toggled |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Share link shows 404 | Token expired or server restarted | Generate a new share link from `/canvas-admin` |
| Page says "Waiting" indefinitely | No content pushed yet or SSE disconnected | Check connection indicator; verify `canvas.enabled: true` and tasks are running |
| "Rate limit exceeded" on interactions | >10 canvas actions in 1 minute | Wait and retry |
| Canvas not updating on task changes | Workshop subscriber not enabled | Verify `canvas.workshop_mode.task_board: true` in config |
| Agent says "server.baseUrl required" | `base_url` not set in config | Add `base_url: https://your-host:port` to `dartclaw.yaml` |
| 429 on SSE connect | Max connections reached | Increase `canvas.share.max_connections` or close stale viewer tabs |

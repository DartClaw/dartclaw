# UX Spec: Real-Time Update Patterns

Per-page refresh and real-time data mechanisms across DartClaw web UI.

## Per-Page Refresh Strategy

| Page | Mechanism | Status | Details |
|------|-----------|--------|---------|
| Chat | SSE (Server-Sent Events) | Implemented | Streaming responses via `text/event-stream`. Messages append in real time. Input disabled during streaming. Reconnects on connection loss (banner shown). |
| Health Dashboard | Polling | Planned | Currently static on page load. Will poll `/api/health` at interval (30s) to refresh service cards, metrics, and status hero. HTMX `hx-trigger="every 30s"`. |
| Settings | Static | N/A | No refresh needed. Settings are read on page load and saved via form submission. Channel status badges refresh on page navigation. |
| Scheduling Status | Polling | Planned | Heartbeat countdown and "last run" timestamps will update via polling. `hx-trigger="every 60s"` on heartbeat card. Recent runs table refreshes on navigation. |
| Pairing Pages (WhatsApp, Signal) | Polling | Planned | QR code / link-code pages poll for pairing completion. `hx-trigger="every 3s"` during active pairing flow. Stops polling on success/timeout. |
| Session Info | Static | N/A | Loaded once per navigation. Token/cost data is historical, not live. |

## SSE Implementation (Chat)

```
Response.ok(eventStream, headers: {'Content-Type': 'text/event-stream'})
```

- Dart shelf streams events directly -- no WebSocket upgrade needed
- Events: `message` (text chunks), `tool_start`, `tool_end`, `done`, `error`
- Client uses `EventSource` API; HTMX SSE extension handles DOM updates
- On disconnect: banner shows "Connection lost. Reconnecting..." with auto-retry

## Polling Implementation (Planned)

- Use HTMX `hx-trigger="every Ns"` for automatic polling
- Server returns HTML fragments, not JSON -- no client-side rendering
- Polling stops when page is not visible (`document.hidden` check via `hx-trigger` modifiers)
- Rate: health = 30s, scheduling = 60s, pairing = 3s

## Connection States

| State | Visual Indicator | Behavior |
|-------|-----------------|----------|
| Connected | No indicator (normal) | SSE stream active, data flowing |
| Connecting | "Connecting..." with blinking cursor | Initial connection or reconnect in progress |
| Disconnected | Banner: "Connection lost. Reconnecting..." | Auto-retry with backoff. Input remains enabled for queuing. |
| Error | Banner: "Agent interrupted" (red) | Worker crashed. User can retry message. |

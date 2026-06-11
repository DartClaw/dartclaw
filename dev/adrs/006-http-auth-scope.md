# ADR-006: HTTP Auth Scope and Mechanism

**Status:** Accepted — fully implemented. Token bootstrap + session cookie (Option C). `AuthMiddleware`, `TokenService`, `SessionStore`, login page, security headers all in `dartclaw_server`.
**Date:** 2026-02-25 (accepted: 2026-02-27)
**Deciders:** DartClaw team

## Context

DartClaw's HTTP gateway (shelf) serves multiple consumers with different auth capabilities:

1. **Web UI (browser)** — HTMX server-rendered pages. Supports cookies. Limited header control from JS
2. **REST API (programmatic)** — `curl`, scripts, CLI. Full header control
3. **SSE streams (browser)** — Native `EventSource` API. **Cannot set custom headers** (W3C spec limitation)
4. **WhatsApp webhook callbacks** — Server-to-server. Meta-controlled HMAC signing (`X-Hub-Signature-256`)
5. **Health endpoint** — Monitoring probes. Should be unauthenticated

The PRD (F10) requires token-based HTTP auth with auto-generated 64-hex gateway token. But F10 flagged scope as unclear: which consumers need which auth mechanism?

### Key Technical Constraint: EventSource

The browser `EventSource` constructor is `new EventSource(url, {withCredentials})`. There is no way to set `Authorization` or any other custom header. This is a W3C spec limitation with no native workaround. HTMX's SSE extension uses native `EventSource` internally — same limitation.

The only options for authenticating SSE connections from a browser:
- **Query param** (`?token=<hex>`) — token leaks to server logs, browser history, Referer headers
- **Session cookie** — sent automatically on same-origin requests. Zero JS changes. No token leakage
- **Fetch-based polyfill** — npm dependency, conflicts with zero-JS-build-toolchain constraint

### Predecessor Analysis

- **OpenClaw** uses WebSocket (not SSE) for streaming — WS supports custom headers at connection time, so the `EventSource` limitation doesn't apply. Auth is bearer token, auto-generated if missing
- **NanoClaw** has no HTTP gateway — all interaction via messaging channels. No HTTP auth needed

DartClaw is the first in the lineage to combine a server-rendered web UI with SSE streaming — this is genuinely new territory.

### Webhook Auth Is a Separate Concern

Research confirmed webhook authentication is fundamentally different from gateway auth:
- **Different actors**: Gateway auth = DartClaw user. Webhook auth = Meta's infrastructure
- **Different mechanisms**: Bearer token vs HMAC-SHA256 over raw request body
- **Different credentials**: Gateway token (we generate) vs Meta App Secret (Meta assigns)
- **Integration-dependent**: Baileys (WebSocket client) has no webhooks. Cloud API uses HMAC. The mechanism depends on the WhatsApp integration approach (separate ADR)

Webhook auth belongs in the WhatsApp Integration ADR. This ADR only defines the route exclusion pattern.

## Decision Drivers

- **SSE compatibility** — must authenticate `EventSource` connections without custom headers
- **Single-user UX** — near-zero friction for the sole operator; no username/password overhead
- **Defense-in-depth** — agent has bash execution; open access is unacceptable even on LAN
- **Implementation simplicity** — minimal LOC, zero new dependencies
- **Tunnel readiness** — must work correctly under VPN/tunnel (Tailscale, ngrok) from day one

## Considered Options

### Option A: Bearer Token Only

Single 64-hex token for everything. `Authorization: Bearer <token>` header for API. `?token=<hex>` query param for SSE and web UI. Stateless.

- ~30 LOC. Simplest implementation
- Token appears in every SSE URL → server logs, browser history
- No session concept — token sent on every request
- Works everywhere but with poor token hygiene

### Option B: Login Page + Session Cookie

Token entry page → server sets `HttpOnly; SameSite=Strict` cookie → cookie for all browser requests including SSE. Bearer header for API.

- ~120-150 LOC. Two auth paths (cookie + bearer)
- Clean SSE auth — cookie sent automatically, no token in URLs
- Requires login page UI from day one
- Strongest browser security posture

### Option C: Auto-Token Bootstrap + Session Cookie (Chosen)

Server prints token URL at startup. User clicks link → server validates, sets cookie, redirects to clean URL. Subsequent requests use cookie. Token entry page as fallback for expired cookies. Bearer header for API.

- ~130-160 LOC. Combines bootstrap convenience with cookie security
- Token in URL only once (at bootstrap) — not on every SSE connection
- Token entry page handles cookie expiry without dead ends
- Zero-friction daily use after initial bootstrap

### Option D: Localhost Trust Bypass

No auth from `127.0.0.1`. Auth required from all other origins.

- ~15 LOC. Zero friction
- Fails silently under tunnels (Tailscale, ngrok expose non-localhost origin)
- Any local process can access the agent. No audit trail
- Unsuitable for production — agent has bash execution

## Decision Outcome

**Option C (Auto-Token Bootstrap + Session Cookie)** chosen. Combines the Jupyter-style bootstrap UX (click URL from terminal → authenticated) with cookie-based session management that cleanly solves the SSE auth constraint.

### Auth Architecture

```
┌─────────────────────────────────────────────────┐
│                  shelf Pipeline                  │
├─────────────────────────────────────────────────┤
│  1. logRequests()                               │
│  2. securityHeadersMiddleware()                 │
│  3. corsMiddleware()                            │
│  4. authMiddleware()                            │
│     ├── Skip: /health, /login, /static/,        │
│     │         /favicon.ico, /webhook/*           │
│     ├── Check: Cookie → valid session → pass    │
│     ├── Check: Authorization: Bearer → pass     │
│     ├── Check: ?token= on GET /                 │
│     │   └── Validate → set cookie → redirect /  │
│     └── Else: redirect /login (browser)         │
│              or 401 (API)                        │
│  5. router.call                                 │
└─────────────────────────────────────────────────┘
```

### Auth Flows by Consumer

| Consumer | Initial Auth | Ongoing Auth | Token in URL |
|----------|-------------|-------------|-------------|
| Web UI (browser) | Click token URL from CLI output | Session cookie | Once (bootstrap only) |
| SSE (`EventSource`) | Inherited from web UI cookie | Session cookie | Never |
| REST API (curl/scripts) | `Authorization: Bearer <token>` | Same header per request | Never |
| Webhook (WhatsApp) | Excluded from middleware | Own verification (separate ADR) | N/A |
| Health endpoint | Excluded from middleware | None | N/A |

### Token Management

- **Auto-generate**: `Random.secure()` → 32 bytes → hex (64 chars). Persist to `~/.dartclaw/config.yaml` under `gateway.token`
- **Startup output**: `INFO: Web UI: http://localhost:7547/?token=<hex64>`
- **CLI access**: `dartclaw token show` prints current token
- **Rotation**: `dartclaw token rotate` generates new token, invalidates all sessions
- **Explicit no-auth**: `gateway.auth.mode: "none"` in config. Log levels: WARN on loopback without auth, CRITICAL when remote-accessible without auth

### Cookie Specification

```
Set-Cookie: dart_session=<session_id>;
            HttpOnly;
            SameSite=Strict;
            Path=/;
            Max-Age=2592000
```

- `HttpOnly` — JS cannot read the cookie. Blocks XSS token theft
- `SameSite=Strict` — not sent on cross-site requests. Blocks CSRF. No CSRF tokens needed
- `Max-Age=2592000` — 30 days. Single user doesn't benefit from short sessions
- No `Secure` flag initially (HTTP on localhost). Add when HTTPS enabled
- Session ID: random 32-byte hex, not the gateway token itself

### Session Store

In-memory `Map<String, DateTime>` (session ID → expiry). Acceptable for single-user, single-process. On server restart, sessions invalidate — user re-bootstraps via token URL or token entry page.

Future: persist to `kv_state` if restart-survival proves important.

### Route Exclusions

```dart
const _publicPaths = {'/health', '/login', '/favicon.ico'};
const _publicPrefixes = ['/webhook/', '/static/'];
```

Webhook paths are excluded from bearer middleware. Each webhook integration implements its own verification (HMAC, verify_token, etc.) in a separate middleware scoped to its routes.

### Security Response Headers (Global)

```dart
'Referrer-Policy': 'no-referrer'          // prevent token leakage via referrer
'X-Content-Type-Options': 'nosniff'
'X-Frame-Options': 'DENY'
'Cache-Control': 'no-store'               // auth-gated pages not cached
```

### Token Entry Page

Minimal HTML: single text input for the gateway token, POST to `/login`. No username field — single-user system. Serves as fallback when:
- Session cookie expired (after 30 days)
- User cleared browser data
- User lost the original token URL from terminal output

The page itself is excluded from auth (must be accessible to unauthenticated users).

### Browser vs API Detection

Auth middleware distinguishes browser requests from API calls to return appropriate responses:
- Browser (`Accept: text/html`): redirect to `/login` on auth failure
- API (everything else): return `401 Unauthorized` JSON

## Comparison

| Aspect | A: Bearer Only | B: Login + Cookie | **C: Bootstrap + Cookie** | D: Localhost Bypass |
|--------|---------------|-------------------|--------------------------|-------------------|
| SSE auth | Token in every URL | Cookie (automatic) | **Cookie (automatic)** | No auth needed |
| Token in logs | Every request | Never | Once (bootstrap) | N/A |
| UX friction | Manage token manually | Login page on first visit | **Click URL once** | Zero |
| Implementation | ~30 LOC | ~120-150 LOC | **~130-160 LOC** | ~15 LOC |
| New dependencies | 0 | 0 | **0** | 0 |
| Tunnel-safe | Yes | Yes | **Yes** | No |
| Dead-end UX | No | No | **No** (token entry fallback) | N/A |

## Consequences

### Positive

- SSE auth solved cleanly — cookie sent automatically on `EventSource`, no token in streaming URLs
- Near-zero daily friction — click startup URL once, authenticated for 30 days
- `HttpOnly` + `SameSite=Strict` — defense-in-depth against XSS and CSRF with zero extra code
- Token entry page eliminates dead-end UX when cookie expires
- API clients unaffected — `Authorization: Bearer` works as expected
- Webhook paths cleanly separated — each integration owns its own verification
- Zero new dependencies — pure shelf middleware

### Negative

- In-memory session store lost on restart — user must re-authenticate (minor: click URL or paste token)
- Two auth code paths (cookie + bearer) — more code than bearer-only, but both are simple string comparisons
- Token appears in browser history once (at bootstrap URL) — mitigated by `Referrer-Policy: no-referrer`
- 30-day cookie TTL means a compromised cookie grants long access — acceptable for single-user home server; `dartclaw token rotate` invalidates all sessions

### Neutral

- Same gateway token used for bootstrap, token entry page, and API bearer auth — single secret to manage
- No CSRF protection logic needed — `SameSite=Strict` handles it at the browser level
- Login page is pure HTML template (Dart string interpolation) — no JS, no client-side state

## Implementation Notes

- Auth middleware slots into existing shelf `Pipeline` in `server.dart` (before `router.call`)
- The existing CORS middleware needs `Access-Control-Allow-Headers: Authorization` for API bearer auth
- `app.js` `startStream()` requires **no changes** — SSE URLs carry no token; cookie is automatic
- Token auto-generation runs in config initialization, before server starts
- Session map cleanup: lazy eviction on access (check expiry when validating). No background timer needed for single-user

## References

- [W3C EventSource spec](https://html.spec.whatwg.org/multipage/server-sent-events.html) — no custom header support
- [MDN EventSource](https://developer.mozilla.org/en-US/docs/Web/API/EventSource) — `withCredentials` is cookies/TLS only
- [Jupyter Notebook token auth](https://jupyter-notebook.readthedocs.io/en/stable/security.html) — token-in-URL bootstrap pattern
- [Syncthing API auth](https://docs.syncthing.net/dev/rest.html) — auto-generated API key on first run
- [Miniflux auth](https://miniflux.app/docs/api.html) — cookie-based SSE auth
- OpenClaw gateway auth (`gateway.auth` auto-generated, 2026.2.19) — bearer token, WebSocket streaming
- HTTP auth trade-off analysis is archived privately.

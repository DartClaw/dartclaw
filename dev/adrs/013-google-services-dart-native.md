# ADR-013: Dart-Native Google Services Integration via `googleapis`

**Status:** Proposed

## Context

DartClaw needs Google services integration (Gmail, Calendar, Drive, etc.) — no Google integration exists today. Four approaches were evaluated:

- **A: gogcli sidecar** — Go CLI binary (15+ services), subprocess pattern matching GOWA/signal-cli
- **B: Dart-native** — Google's official `googleapis` + `googleapis_auth` Dart packages
- **C: Hybrid** — Dart channel for Gmail + gogcli tools for Calendar/Drive/Sheets
- **D: Community MCP server** — Python `google_workspace_mcp` as external MCP server

Gmail is an untrusted data source (attacker controls email content). Google's own research shows 84% of agents are vulnerable to prompt injection via email. This makes the security architecture of Google integration a first-order concern.

Research is summarized in the linked appendix.

## Decision

**We will use Google's official Dart packages (`googleapis` v16 + `googleapis_auth` v2.2) for all Google services integration.**

Gmail will be a first-class channel (polling via History API). Calendar, Drive, and other services will be MCP tools sharing the same authenticated client. All Google service data flows through DartClaw's Dart security pipeline.

### Gmail Channel

- Polling via `UsersHistoryResource.list(startHistoryId)` — incremental, efficient, no public endpoint needed
- Default poll interval: 60s (configurable, min 15s)
- Thread mapping: `gmail:<threadId>` as session key
- Reply threading via `In-Reply-To` + `References` headers
- Draft-only mode by default (`UsersDraftsResource.create()`) — autonomous send requires explicit config opt-in
- DmAccessController reused with email-address allowlist

### MCP Tools

Each additional Google service is a `McpTool` implementation (~60-120 lines) sharing the same `AutoRefreshingAuthClient`:
- Calendar: event CRUD, freebusy queries
- Drive: file search, read, download
- Sheets: read/write cells
- Tasks: CRUD
- Additional services added incrementally as needed

### Authentication

- Standard OAuth 2.0 desktop flow via `googleapis_auth.clientViaUserConsent()`
- Token persisted in DartClaw data directory (`~/.dartclaw/channels/gmail/credentials.json`)
- Auto-refresh via `AutoRefreshingAuthClient`
- Single OAuth consent flow covers all Google services (scopes combined)
- GCP project + OAuth client required (setup wizard planned: `dartclaw setup gmail`)

### Security Pipeline

- Inbound email text passes through ContentClassifier + InputSanitizer before entering agent context
- OAuth scopes minimized: `gmail.readonly` + `gmail.send` (or `gmail.compose` for draft-only)
- Token custody entirely within DartClaw's data directory
- MCP tool results from Calendar/Drive/Sheets also pass through ContentGuard (shared docs from external parties could contain injection payloads)

## Consequences

### Positive
- Full security pipeline control — all Google content sanitized before LLM context
- Single auth flow — one OAuth consent, one token store, one refresh mechanism
- No public endpoint required — polling works behind NAT/firewall
- Google-maintained, auto-generated SDK — lowest upstream risk, no bus-factor concern
- Zero external binaries — pure Dart, AOT-compatible, aligns with dependency philosophy
- Low marginal cost per service — each new Google service is ~60-120 lines

### Negative
- More implementation effort per service than gogcli wrappers (~60-120 LOC vs ~50-80 LOC per tool, plus ~790 LOC for Gmail channel)
- MIME parsing complexity — email HTML, encodings, quoted replies require `enough_mail` package or custom parser
- GCP project setup friction for end users (mitigated by CLI setup wizard)
- Channel abstraction needs minor adaptation for email semantics (threads vs conversations, no mentions, CC/BCC)
- Polling adds up to 60s latency vs push notifications (Pub/Sub push available as optional upgrade)

### Neutral
- `googleapis` major version bumps (v14→v15→v16) require version pinning and planned upgrades
- OAuth refresh tokens can be silently invalidated (password change, revocation, 6-month inactivity) — requires graceful 401 handling

## Alternatives Considered

### A: gogcli as Sidecar Binary (Score: 7.08/10)
- **Pros**: Perfect sidecar pattern match; 15+ services from one Go binary; defense-in-depth with `GOG_ENABLE_COMMANDS`
- **Cons**: Pre-1.0 with no JSON schema contract; Gmail push requires public HTTPS endpoint; interactive OAuth hostile to headless servers; `GOG_ENABLE_COMMANDS` only gates at top-level command granularity (enabling `gmail` enables both `search` and `send`)
- **Rejected because**: Lower score on highest-weighted criteria (Security 7 vs 9, Maintainability 6 vs 8). Public endpoint requirement breaks outbound-only connection model. Pre-1.0 stability risk with rapid release cadence (12+ releases in 3 months).
- **Fallback option**: If service breadth demand exceeds Dart implementation capacity, gogcli wrappers can be added for specific services later without requiring architectural changes.

### C: Hybrid — Dart Channel + gogcli Tools (Score: 6.65/10)
- **Pros**: Security-optimal Gmail inbound path; domain-aligned boundary (channels for messaging, tools for utility)
- **Cons**: Dual-auth problem — two separate OAuth consent flows for same Google account (googleapis_auth stores tokens in data dir, gogcli stores in OS keyring, cannot share); doubled dependency burden; subprocess tool is new pattern within tool layer
- **Rejected because**: Dual-auth is a UX anti-pattern with no clean workaround. Adds both `googleapis` deps AND gogcli binary — strictly worse than either pure option on dependencies.

### D: Community MCP Server (Score: 4.45/10)
- **Pros**: 100+ tools immediately; ~50 LOC integration; tiered tool exposure
- **Cons**: Complete ContentGuard bypass — external MCP server connects to `claude` binary directly, Dart host never sees tool calls or results; Python runtime dependency; bus factor 1 (94%+ commits from single maintainer)
- **Rejected because**: Fundamentally contradicts DartClaw's security architecture. ContentClassifier, InputSanitizer, MessageRedactor, guard audit logging all bypassed. PostToolUse hooks fire after content already in agent context — not a real security boundary.

## Implementation Notes
- Verify `googleapis` + `googleapis_auth` compile cleanly with `dart compile exe` (pure Dart, no `dart:mirrors` — should work)
- Evaluate `enough_mail` pub.dev package for MIME parsing before building custom parser
- Gmail quota: 250 units/sec per user; `messages.list` = 5 units; 60s poll interval is well within limits
- Pub/Sub push (optional upgrade): requires GCP topic, public endpoint, 7-day watch renewal
- NanoClaw's Gmail channel implementation is a useful reference for the polling + thread mapping pattern

## References
- [googleapis on pub.dev](https://pub.dev/packages/googleapis) — v16.0.0
- [googleapis_auth on pub.dev](https://pub.dev/packages/googleapis_auth) — v2.2.0
- [gogcli](https://github.com/steipete/gogcli) — runner-up option
- [NanoClaw Gmail Channel](https://github.com/qwibitai/nanoclaw) — reference implementation
- [ADR-009: Internal MCP Server](009-internal-mcp-server.md) — establishes the internal MCP pattern that this decision extends
- Research sources are summarized in the linked research appendix.

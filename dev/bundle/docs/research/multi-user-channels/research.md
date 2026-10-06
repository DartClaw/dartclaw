# Multi-User Channels: Research Summary

> **📁 PARTIALLY ARCHIVED** — Multi-user is deferred to post-1.0, but **Google Chat** has been promoted to 0.8 as a single-user channel. See [0.8 PRD Phase F](../../specs/0.8/prd.md) and [dedicated research](../google-chat-integration/research.md). Slack and WhatsApp groups remain deferred.

Research into supporting multi-user scenarios via messaging platform integrations (Slack, Google Chat, WhatsApp groups) in a future DartClaw release.

> Date: 2026-02-25. Sources: OpenClaw Guide, NanoClaw docs, official platform APIs, open-source reference projects.

---

## Current State

DartClaw is explicitly single-user through 0.2. Multi-user deployment deferred to Phase 5+ (post-0.2). However, 0.2 architecture already prepares for extensibility:

- **Channel interface abstraction** (F18) — `connect`, `sendMessage`, `ownsJid`, `disconnect`
- **Session key format** (TD-008) — composite keys: `agent:<agentId>:<scope>:<identifiers>`
- **Message queue** — debounce, per-session FIFO, global concurrency cap
- **Group chat support** — mention gating + group policies (WhatsApp, Phase 2)

---

## Channel Assessments

### Slack — Best Fit for Multi-User AI Agent

**Architecture**: Dart-native adapter on existing `shelf` server. HTTP Events API for production, Socket Mode for dev. No sidecar needed — maintains zero-npm principle.

**Core constraint**: Slack requires HTTP 200 within 3 seconds. Pattern: ack immediately → process async → respond via API.

**Streaming**: DartClaw's SSE maps directly to Slack's `chat.startStream`/`chat.appendStream`/`chat.stopStream` APIs (Oct 2025). Translation:
1. Receive event → ack 200
2. `assistant.threads.setStatus("is thinking…")`
3. `chat.startStream(channel, thread_ts)` → get `stream_ts`
4. For each SSE chunk → `chat.appendStream(stream_ts, chunk)` (batch ~500ms)
5. SSE closes → `chat.stopStream(stream_ts, final_ts)`

**Session keying**: `thread_ts` → DartClaw session ID. DMs use channel ID.

**Multi-user strengths**:
- Native `@mention` detection (first-class)
- Stable user IDs (not phone numbers)
- First-class thread support → natural session isolation
- AI Apps feature with `assistant.threads.setStatus` typing indicator
- No policy restrictions on AI agents
- Rich interactive elements (buttons, modals, workflows)

**Auth**: Bot token (`xoxb-`) + signing secret. HMAC-SHA256 verification ~30 LOC in Dart.

**Scopes**: `assistant:write`, `chat:write`, `channels:history`, `im:history`, `im:write`, `app_mentions:read`

**Rate limits**: 1 msg/sec/channel writes, 4K chars recommended (40K hard truncation).

**References**: [Slack Events API](https://docs.slack.dev/apis/events-api/comparing-http-socket-mode/), [AI Apps](https://docs.slack.dev/ai/developing-ai-apps/), [chat streaming](https://docs.slack.dev/changelog/2025/10/7/chat-streaming/), [claude-code-slack-bot](https://github.com/mpociot/claude-code-slack-bot)

---

### Google Chat — Simplest Integration, Requires Workspace

**Architecture**: Pure REST, no sidecar. HTTP POST handler receives events, Chat REST API for outbound. Service account JWT auth.

**Core constraint**: 30-second sync response window. Pattern: return "Working on it..." synchronously → PATCH message with final content async.

**Session keying**: DM = `space.name` (stable per user). Spaces = `space.name/thread.name` per thread.

**Multi-user strengths**:
- Stable `users/{userId}` identity + email
- Native threading in spaces
- Cards v2 for rich structured output
- Slash commands (`/new`, `/reset`, `/status`)
- No AI agent policy restrictions
- 32KB message limit (generous)

**Blockers**: Requires Google Workspace (Business/Enterprise) — free accounts cannot create Chat apps. Needs GCP project with billing.

**Rate limits**: 3,000 writes/min per project, 1 write/sec per space.

**References**: [Chat API architecture](https://developers.google.com/workspace/chat/structure), [Chat events](https://developers.google.com/workspace/chat/receive-respond-interactions), [Rate limits](https://developers.google.com/workspace/chat/limits)

---

### WhatsApp Groups — Significant Headwinds

**CRITICAL: AI Agent Policy Ban (Jan 15, 2026)**

Meta banned general-purpose AI chatbots from WhatsApp Business API. DartClaw as AI agent runtime likely qualifies as "general-purpose AI assistant as primary functionality" — which is banned.

- Under EU antitrust scrutiny (Italy, EU Commission, Brazil probing Meta)
- [TechCrunch](https://techcrunch.com/2025/10/18/whatssapp-changes-its-terms-to-bar-general-purpose-chatbots-from-its-platform/)

**Official Groups API (Oct 2025)**: Max **8 participants**, 100K+ conversations/month eligibility threshold, no interactive elements in groups. Unsuitable for meaningful multi-user.

**Unofficial path** (whatsmeow/GOWA — DartClaw 0.2 choice): Full group support, unlimited size, native mention detection. For single-user personal use, the AI ban doesn't apply (personal account, not Business API).

**For multi-user deployment**: Weakest channel. Phone number as identity (mutable), no threading, GDPR concerns, hostile policy environment. Supply-chain attack risk (Dec 2025 `lotusbail` incident — 56K npm installations compromised).

**WhatsApp vs Slack/Google Chat**:
| Dimension | WhatsApp | Slack | Google Chat |
|---|---|---|---|
| Group size | 8 (official) / unlimited (unofficial) | Unlimited | Unlimited |
| Bot @mention | App-layer only | Native | Native |
| User identity | Phone number (mutable) | Stable user ID | Stable user ID |
| Threading | None | First-class | Spaces/threads |
| AI agent policy | Banned if primary function | Allowed | Allowed |
| Interactive elements | None in groups | Full | Cards, dialogs |

---

## Multi-User Architecture Patterns (from OpenClaw)

### Session Isolation Levels

Most to least isolated:

1. **`per-account-channel-peer`** — includes account ID
2. **`per-channel-peer`** — one session per sender + channel (**recommended**)
3. **`per-peer`** — one session per sender across channels
4. **`main`** — all DMs share one conversation (unsafe for multi-user)

### Identity Links

Collapse multi-channel identities into single sessions:
```json
{ "identityLinks": { "alice": ["whatsapp:+1555...", "slack:U12345"] } }
```

### Tool-Based Role Restriction

OpenClaw uses per-agent tool policies (not RBAC):

- Channel agents: deny `exec`, `process`, `browser` — delegate to main via `sessions_send`
- Read-only agents: allow only `group:fs`, `memory_search`, `group:sessions`
- Tool groups: `group:runtime`, `group:fs`, `group:sessions`, `group:memory`, `group:web`, `group:messaging`

Two-tier privilege model: admin (owner) gets full tool access, guest users get sandboxed tool subset. Maps to `disallowedTools` passthrough already in DartClaw 0.2 SDK bridge.

### Security Layers (for untrusted senders)

1. DM/Group policy (channel level)
2. Allowlist filtering (sender-based)
3. Mention gating (group-only)
4. Tool policy (per-agent, 8-layer cascade in OpenClaw)
5. Docker sandbox isolation (per-session)
6. **Channel-guard** (DeBERTa ONNX, ~370MB) — ML injection scanning. Mandatory with untrusted senders

### Binding-Based Routing

Deterministic precedence: peer → guild → team → account → channel → default (first match wins).

---

## Key Architectural Considerations

### Memory Namespace Isolation (Blocker)

Current FTS5 index has no `user_id` column — user A's memories could leak to user B's queries. Must be added before multi-user. Changes needed:

1. Add `user_id TEXT` column to `memory_chunks` table (default `'owner'` for single-user compat)
2. Add `user_id` filter to all search queries
3. Add `owner` field to Session model
4. Scope MEMORY.md per user (`~/.dartclaw/{user_id}/MEMORY.md`)
5. Propagate user context through bridge

**Recommendation**: Add `user_id` column in 0.2 (cheap now, painful to retrofit later). Default to `'owner'` — no behavioral change for single-user, but schema ready for multi-user.

### Token-Based Rate Limiting

Rate limit by tokens, not requests (one malicious prompt can generate thousands of internal calls):

- **Global budget**: max tokens/day across all users
- **User budget**: max tokens/hour per user
- **Function budget**: max calls/hour for expensive tools (bash, web_search)

DartClaw 0.2 already has per-session token/cost counters — post-0.2 aggregates per `user_id`.

### Channel Abstraction

Unified normalized message format:

```
InboundMessage {
  channelId     // "whatsapp" | "slack" | "googlechat"
  senderId      // platform-native ID
  groupId?      // null for DMs
  threadId?     // parent message ID (platform-specific → normalized)
  text
  type          // dm | group_mention | group_message
  timestamp
}
```

Platform threading normalization:
| Platform | Threading | Normalized |
|---|---|---|
| Slack | `thread_ts` | `threadId` |
| Google Chat | `thread.name` | `threadId` |
| WhatsApp | `quoted_message_id` | `threadId` |
| Telegram | `reply_to_message_id` | `threadId` |

### Workspace Isolation

Per-session workspace directories with file-guard enforcement:
```
/workspaces/<session-id>/
  SOUL.md          ← shared (read-only bind mount)
  USER.md          ← per-user copy
  workspace/       ← agent's writable area
```

---

## Recommended Architecture

```
                    ┌─────────────┐
                    │  Slack      │──── HTTP Events API ────┐
                    └─────────────┘                         │
                    ┌─────────────┐                         ▼
                    │ Google Chat │──── HTTP POST ──────► ┌──────────────────┐
                    └─────────────┘                       │  Channel Router  │
                    ┌─────────────┐                       │  (shelf routes)  │
                    │  WhatsApp   │──── GOWA webhook ──►  │                  │
                    └─────────────┘                       │  → Normalize msg │
                    ┌─────────────┐                       │  → Access control│
                    │  Web UI     │──── existing SSE ──►  │  → Session route │
                    └─────────────┘                       │  → Message queue │
                                                          └────────┬─────────┘
                                                                   │
                                                          ┌────────▼─────────┐
                                                          │  Agent Runtime   │
                                                          │  (per-session)   │
                                                          │  Tool policies   │
                                                          │  per user/group  │
                                                          └──────────────────┘
```

**Key decisions**:
1. Channel adapters as shelf routes — no new processes for Slack/Google Chat
2. Unified normalized message format before message queue
3. `per-channel-peer` session scope as default
4. Tool policy gating per channel/user via `disallowedTools`
5. Channel-guard mandatory with untrusted senders
6. Token budget tracking per user

---

## Channel Priority (for multi-user release)

1. **Google Chat** — simplest integration (pure REST, no sidecar), good threading, native in Workspace environments. First channel to implement
2. **Slack** — best platform support, native AI features, thread→session mapping, no policy risk
3. **Telegram** — already planned post-0.2, good bot API
4. **WhatsApp groups** — policy hostility, weak multi-user primitives, unofficial API only

---

## Implementation Sequence (Post-0.2)

1. **Memory namespace isolation** — add `user_id` to FTS5/SQLite indexes (**recommended for 0.2**)
2. **Channel identity resolution** — map `(channelId, senderId)` → `(userId, role)`
3. **`disallowedTools` per role** — wire role-based tool policies to existing SDK passthrough
4. **Session workspace isolation** — per-session directories with file-guard enforcement
5. **Token budget tracking** — aggregate per-session counters to per-user buckets
6. **Channel-guard** — DeBERTa ONNX injection scanning (mandatory for untrusted senders)
7. **Google Chat adapter** — HTTP POST + service account JWT (first — simplest, pure REST)
8. **Slack adapter** — HTTP Events API + streaming
9. **Telegram adapter** — Grammy library (already planned)

---

## Reference Projects

| Project | Channels | Notable Patterns |
|---|---|---|
| [OpenClaw](https://github.com/openclaw/openclaw) | WA, Telegram, Slack, Discord, GChat, Signal | Channel abstraction, binding routing, tool policy cascade, channel-guard |
| [LettaBot](https://github.com/letta-ai/lettabot) | Telegram, Slack, Discord, WA, Signal | Pairing access control, unified/per-channel modes, no public URL needed |
| [claude-code-slack-bot](https://github.com/mpociot/claude-code-slack-bot) | Slack | Token streaming to Slack, per-scope sessions |
| [Bottender](https://bottender.js.org/) | Multi-platform | Clean adapter pattern, unified Context interface, middleware chains |

---

## Open Questions

- What lockdown level for multi-user agent? Full deny on exec/fs/browser, or configurable per group?
- Should multi-user support be a separate deployment mode, or integrated into the existing single-user architecture?
- Identity verification: is DM pairing sufficient, or do we need OAuth for Slack/Google Chat user verification?
- Cost allocation: per-user billing vs shared pool with caps?

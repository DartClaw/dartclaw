# Channel Feature Parity Matrix

**Status**: Current through 0.25
**Channels**: WhatsApp (0.2), Signal (0.4), Google Chat (0.8)

> Use this matrix when implementing new channels or auditing parity across existing ones.
> For channel-specific configuration, see the `channels.*` section schema in `dartclaw.yaml`.

## Access Control

| Feature | WhatsApp | Signal | Google Chat |
|---------|----------|--------|-------------|
| DM access modes | pairing, allowlist, open, disabled | pairing, allowlist, open, disabled | pairing, allowlist, open, disabled |
| Default DM mode | `pairing` | `allowlist` | `pairing` |
| Group access modes | disabled, allowlist, open | disabled, allowlist, open | disabled, allowlist, open |
| Default group mode | `disabled` | `disabled` | `disabled` |
| Pairing code flow | 8-char code, 1h expiry, max 3 pending | Same | Same |
| Unified `DmAccessController` | Yes | Yes | Yes |
| Sender identifier format | JID (`number@s.whatsapp.net`) | Phone or ACI UUID | User resource name (`users/{id}`) |
| Group identifier format | Group JID (`number@g.us`) | Base64-encoded group ID | Space name (`spaces/{id}`) |

## Authentication & Connectivity

| Feature | WhatsApp | Signal | Google Chat |
|---------|----------|--------|-------------|
| Sidecar required | Yes (GOWA binary) | Yes (signal-cli) | No (pure REST) |
| Auth method | QR code login via GOWA | Link device (QR + phone scan) | GCP service account JWT |
| Inbound message delivery | GOWA webhook (HTTP POST) | signal-cli SSE event stream | Google Chat webhook (HTTP POST) |
| Outbound message delivery | GOWA REST API | signal-cli JSON-RPC 2.0 | Google Chat REST API |
| JWT verification | No | No | Yes (inbound webhook JWT validation) |
| Restart reconnection | Detects pairing from GOWA stderr | Calls `isAccountRegistered()` | Verifies JWT credentials |

## Message Handling

| Feature | WhatsApp | Signal | Google Chat |
|---------|----------|--------|-------------|
| Max chunk size | 4000 chars (configurable) | 4000 chars (configurable) | 4000 chars (hardcoded) |
| Chunking algorithm | Smart break: paragraph > line > sentence > word | Same (shared `chunkText()`) | Same (shared `chunkText()`) |
| Chunk indicators | `(n/total)` prefix | `(n/total)` prefix | `(n/total)` prefix |
| Response prefix | Configurable (`response_prefix` config) | No | No |
| Message debouncing | 1000ms default | 1000ms default | 1000ms default |

## Group & Mention Support

| Feature | WhatsApp | Signal | Google Chat |
|---------|----------|--------|-------------|
| Group detection | `chatId.endsWith('@g.us')` | `groupInfo?.groupId` in dataMessage | `space.type` in `['ROOM', 'SPACE']` |
| Mention gating (configurable) | Yes (`require_mention`, default: true) | Yes (`require_mention`, default: true) | Yes (`require_mention`, default: true) |
| Mention detection methods | 1. Native `mentionedJids` 2. Configurable regex patterns | 1. Native `mentionedJids` 2. Configurable regex patterns | 1. Text extraction (`_extractMentionedJids`) 2. Regex patterns (not wired in 0.8) |
| Custom mention patterns config | `whatsapp.mention_patterns` | `signal.mention_patterns` | Not yet wired |

## Media & Rich Content

| Feature | WhatsApp | Signal | Google Chat |
|---------|----------|--------|-------------|
| Inbound media | Not parsed (text only) | Not supported (text only) | Download via API (`downloadMedia()`) |
| Outbound media | Yes (via the `attach_media` MCP tool, 60s timeout) | No | No (logged warning) |
| Outbound media mechanism | The agent calls `attach_media` with a workspace-relative path; the host validates existence and containment and resolves the recipient from the owner's active DM sessions. The `MEDIA:` assistant-text sentinel and its host-side extraction were deleted in 0.25 | — | — |
| Typing indicator | Yes (lease-tracked, shared tracker) | Yes (lease-tracked, shared tracker) | Yes (placeholder message + edit on completion) |
| Voice messages | Not supported | Not supported | Not supported |

## Reliability & Error Handling

| Feature | WhatsApp | Signal | Google Chat |
|---------|----------|--------|-------------|
| Ban/restriction detection | Yes (monitors send errors, auto-disables) | No | No (official API, no ban risk) |
| Crash recovery | Exponential backoff (max 5 restarts) | SSE auto-reconnection with backoff | N/A (stateless webhooks) |
| Write queue | Per-session FIFO | Per-session FIFO | Per-space serialization |

## Channel-Specific Features

### WhatsApp Only
- Ban/restriction signal detection with auto-disable
- GOWA sidecar management (crash recovery, process logging)
- Configurable response prefix (model + agent name)
- Outbound media delivery (agent-initiated via `attach_media`; the `MEDIA:` sentinel was retired in 0.25)
- Webhook secret validation (`?secret=<token>`)
- Multi-device support (X-Device-Id header)

### Signal Only
- Sealed-sender fallback via `SignalSenderMap` (UUID ↔ phone bidirectional mapping, persisted to `signal-sender-map.json`)
- SSE event streaming with automatic reconnection
- JSON-RPC 2.0 protocol for API calls
- Account linking (QR scan with 5-min timeout). SMS/voice registration and its CAPTCHA flow were deleted in 0.25 – the routes, their templates and `SignalCliManager.requestSmsVerification` / `requestVoiceVerification` / `verifySmsCode` are gone

### Google Chat Only
- GCP JWT authentication (inbound webhook validation)
- Typing indicator (placeholder message → edit with final response)
- Configurable audience (`app-url` or `project-number` JWT verification)
- Space-based routing (native DM, ROOM, SPACE types)
- Inbound media download via API
- Write queue per space (rate limiting + ordering)
- No sidecar dependency (pure REST)

## Implementation Reference

Post-0.25 topology: each channel owns its own package, and the shared bases live in `dartclaw_core`.

| Channel | Implementation |
|---|---|
| WhatsApp | `packages/dartclaw_whatsapp/lib/src/whatsapp_channel.dart`, `gowa_manager.dart` |
| Signal | `packages/dartclaw_signal/lib/src/signal_channel.dart`, `signal_cli_manager.dart`, `signal_sender_map.dart` |
| Google Chat | `packages/dartclaw_google_chat/lib/src/` — including the webhook and its JWT verifier, absorbed from the server package in 0.25 |

| Shared base | Package |
|---|---|
| `channel/text_chunking.dart` | `dartclaw_core` |
| `channel/dm_access.dart` | `dartclaw_core` |
| `channel/inbound_gate.dart` (group/mention gating pipeline) | `dartclaw_core` |
| Sidecar process manager, typing-lease tracker | `dartclaw_core` |

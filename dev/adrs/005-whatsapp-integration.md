# ADR-005: WhatsApp Integration Approach

**Status:** Accepted — fully implemented. GOWA sidecar (whatsmeow/Go) with REST API + webhooks. `GowaManager`, `WhatsAppChannel`, DM access control, mention gating, QR pairing UI all in `dartclaw_core`/`dartclaw_server`.
**Date:** 2026-02-25 (accepted: 2026-02-27)
**Deciders:** DartClaw team

## Context

DartClaw 0.2 requires WhatsApp messaging as a P0 feature (F17) — the primary mobile interface for the personal AI assistant. The PRD specifies: DM send/receive, group participation with mention gating, QR/pairing code setup, media support, text chunking, and DM access control policies.

DartClaw's core principle is **zero npm/Node.js at runtime** (Dart AOT + Deno worker + native Claude CLI). But WhatsApp has no official open protocol — all implementations are unofficial reverse-engineered clients or the official Cloud API (which targets business use).

The PRD explicitly flags this tension: "Baileys is Node.js — conflicts with zero-npm principle. Integration approach needs ADR."

### Key Constraints
- Single-user deployment on Mac Mini (home server)
- Must support: DMs, groups, @mention gating, media, QR pairing
- NanoClaw (predecessor) successfully uses Baileys with Node.js
- Channel interface abstraction (F18) decouples WhatsApp specifics from core

## Decision

**We will use whatsmeow (Go) for WhatsApp integration, initially via the GOWA REST wrapper as a sidecar process.**

whatsmeow is a Go library for the WhatsApp Web multi-device API. It powers mautrix-whatsapp, the most widely deployed Matrix-WhatsApp bridge, commercially offered by Element/EMS. GOWA (go-whatsapp-web-multidevice, ~2.3k GitHub stars) provides a ready-made REST API, webhook support, MCP server mode, Docker images, and goreleaser binaries.

### Integration Architecture

This follows the **outpost pattern** (see CLAUDE.md Design Philosophy): a purpose-built binary in the best language for the job (Go for WhatsApp protocol), invoked as a subprocess with structured I/O, no shared runtime or dependency contamination.

```
Dart Host (state/API/security)
  ├── [NDJSON/JSON-RPC] → Deno Worker (Claude Agent SDK)
  └── [REST + webhooks]  → GOWA binary (whatsmeow, WhatsApp Web)
```

**Phase 1**: GOWA goreleaser binary as sidecar. Dart host calls GOWA REST API for sending, receives incoming messages via webhook HTTP POST. QR pairing via GOWA's built-in web UI or API endpoint.

**Phase 2 (optional)**: If HTTP overhead or tighter process control is needed, write a thin NDJSON/JSON-RPC Go wrapper (~500-800 LOC) around whatsmeow directly, communicating via stdin/stdout like the Deno worker.

## Consequences

### Positive
- **Zero npm/Node.js** — Go compiles to single binary. Core principle preserved
- **Commercially proven reliability** — mautrix-whatsapp/EMS validates production maturity
- **Full feature set** — DMs, groups, mentions (`mentionedJids`), QR/pairing, media, presence, read receipts — complete parity with Baileys
- **Better stability than Baileys** — users report lower memory usage, fewer session drops, no auto-logout issues
- **GOWA eliminates wrapper work** — REST API, webhooks, Docker images, goreleaser binaries all ready
- **MPL-2.0 license** — permissive copyleft, avoids Baileys' GPL-3.0 (from libsignal-node)
- **Low resource footprint** — Go binary ~15-25MB, minimal memory/CPU

### Negative
- **Still unofficial API** — WhatsApp ban risk exists for all unofficial clients. Single personal account + conservative usage mitigates this
- **tulir bus factor** — single primary maintainer. Mitigated: MPL-2.0 allows forking, EMS commercial interest ensures continuity
- **Go binary management** — additional process to manage at runtime (GOWA sidecar). Mitigated: goreleaser binaries, Docker images available
- **CGo for SQLite** — whatsmeow's default session store uses mattn/go-sqlite3 (CGo). Non-issue on macOS (Xcode clang) or solvable with `modernc.org/sqlite`
- **REST+webhook adds HTTP hop** — slightly higher latency vs NDJSON stdio. Negligible for messaging (not real-time streaming)

### Neutral
- WhatsApp protocol changes affect all unofficial clients equally — whatsmeow, Baileys, and any other reverse-engineered implementation
- The channel interface abstraction (F18) means the WhatsApp implementation is swappable — if Cloud API gains group support or Baileys-in-Deno becomes viable, the adapter can be replaced without affecting the rest of the system

## Alternatives Considered

### Baileys via Deno npm compat
- **Pros**: Stays in existing Deno ecosystem, feature-complete, NanoClaw precedent
- **Cons**: Blocked — Baileys' git-based libsignal dependency breaks Deno's npm resolver (denoland/deno#17679, open since Feb 2023). `whatsapp-rust-bridge` native dep adds second blocker. JSR port (@hviana/baileys) has 1 download/week — not viable
- **Rejected because**: Technical blocker with no clear timeline for resolution

### Baileys as Node.js sidecar
- **Pros**: Proven in NanoClaw, Baileys' native runtime, reuses NDJSON bridge pattern
- **Cons**: Requires Node.js (~60-80MB) + npm (~30-50MB node_modules). Breaks zero-npm principle. GPL-3.0 license. Users report session instability, memory creep vs whatsmeow
- **Rejected because**: whatsmeow provides equivalent features with better stability, zero npm, and permissive license. Node.js sidecar is strictly inferior

### WhatsApp Cloud API (official Meta)
- **Pros**: Official API, zero ban risk, pure HTTP from Dart (perfect runtime alignment), stable
- **Cons**: **Cannot join regular WhatsApp groups** (dealbreaker). 24h messaging window constrains proactive notifications. Requires dedicated phone number + Meta developer account. No E2E encryption (Meta sees all messages). Template approval friction
- **Rejected because**: Group participation is a core requirement. 24h window and no E2E encryption are philosophically misaligned with a personal assistant

### Pure Dart WhatsApp library
- **Pros**: Perfect runtime alignment if it existed
- **Cons**: No mature library exists on pub.dev. WhatsApp Web is an 8-layer protocol stack (Noise + Signal + custom binary XML + protobuf + multi-device sync). Multi-year, multi-person effort against undocumented, actively-changing protocol
- **Rejected because**: Not viable for a single-developer project. The library does not exist and cannot be reasonably built

## Implementation Notes

- GOWA binary managed as sidecar process by Dart host (lifecycle: start on DartClaw boot, health check via REST, restart on crash)
- WhatsApp session state (Signal Protocol keys) persisted by GOWA in its own SQLite database
- `WhatsAppChannel` adapter implements F18 channel interface (`connect`, `sendMessage`, `ownsJid`, `disconnect`)
- Incoming messages received via webhook → normalized to channel-agnostic format → routed to message queue
- QR pairing exposed in DartClaw web UI (proxy to GOWA's pairing endpoint or embed QR image)
- Text chunking (4000 char limit) and response prefix handled in channel adapter
- DM access control policies (pairing, allowlist, open, disabled) enforced in Dart host before forwarding to agent
- Mention gating uses whatsmeow's `mentionedJids` + regex `mentionPatterns` fallback

## References

- [whatsmeow — GitHub](https://github.com/tulir/whatsmeow) (~5.1k stars)
- [GOWA — GitHub](https://github.com/aldinokemal/go-whatsapp-web-multidevice) (~2.3k stars)
- [mautrix-whatsapp — GitHub](https://github.com/mautrix/whatsapp) (~1.5k stars)
- [Baileys — GitHub](https://github.com/WhiskeySockets/Baileys) (~8.4k stars)
- [Deno npm git deps — denoland/deno#17679](https://github.com/denoland/deno/issues/17679)
- [WhatsApp Cloud API — Meta](https://business.whatsapp.com/products/platform-pricing)
- Research sources are summarized in the linked research appendix.

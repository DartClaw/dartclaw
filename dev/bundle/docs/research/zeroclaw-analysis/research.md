# ZeroClaw — Deep Feature & Architecture Analysis

> Last updated: 2026-03-28
> ZeroClaw version: v0.6.5 (Mar 27, 2026)
> Repository: [zeroclaw-labs/zeroclaw](https://github.com/zeroclaw-labs/zeroclaw)
> Stars: ~29,000 | Forks: 4,036 | Open issues: 332 | License: MIT OR Apache-2.0 | Language: Rust (Edition 2024)

## Overview

ZeroClaw is a Rust-native personal AI assistant runtime positioned as an ultra-lightweight, security-first alternative to OpenClaw. Created in mid-February 2026, it attracted 3,400+ stars within two days and has grown to ~29,000 stars — making it the fastest-growing compiled-language entrant in the personal AI assistant space.

**Positioning:** "Fast, small, and fully autonomous AI personal assistant infrastructure, ANY OS, ANY PLATFORM — deploy anywhere, swap anything." Explicitly targets the $5-$10/month VPS market and edge/IoT hardware that cannot run OpenClaw's Node.js stack.

**Community:** Built by Harvard, MIT, and Sundai.Club communities. Active development with daily/bi-daily release cadence. 2,517 commits, 228 PRs, 104 issues as of late March 2026.

**Official presence:** zeroclawlabs.ai, X (@zeroclawlabs), Reddit (r/zeroclawlabs).

---

## Architecture

### Runtime Model

Single-binary Rust daemon (~8.8MB) with Tokio async runtime. Zero external runtime dependencies. Three execution modes:

1. **`zeroclaw agent`** — interactive single-message or REPL mode
2. **`zeroclaw gateway`** — HTTP/WS/SSE control plane + web dashboard
3. **`zeroclaw daemon`** — full autonomous mode (gateway + channels + cron + swarms)

Process model: one daemon per workspace, single-threaded async (Tokio). No per-agent container isolation — sandboxing via Landlock (Linux) and Bubblewrap at the OS level.

### Performance Profile

| Metric | ZeroClaw | OpenClaw | DartClaw |
|--------|----------|----------|----------|
| RAM (idle) | <5MB (measured: ~15MB in production) | >1GB | ~50-80MB (est.) |
| Startup | <10ms cold start | >500ms | ~100ms (AOT) |
| Binary | ~8.8MB | ~28MB + Node.js runtime | ~15-20MB (AOT) |
| Min hardware | $5-10 VPS, Raspberry Pi, ESP32 | Mac mini ($599+) | $5 VPS (AOT binary) |

**Note:** The <5MB claim is for release builds without the web dashboard. Production measurements (from the migration assessment) show ~15MB per bot with full features. OpenClaw's >1GB includes Node.js runtime overhead (~390MB baseline).

### Extension Model — Trait-Based Plugin System

ZeroClaw exposes **8 core Rust traits** that define swappable subsystems:

1. **Provider** — LLM backend (20+ providers)
2. **Channel** — messaging platform integration (21+ channels)
3. **Tool** — executable capability (70+ tools)
4. **Memory** — knowledge storage backend (SQLite default, Redis optional)
5. **Tunnel** — remote access method (Cloudflare, Tailscale, ngrok, OpenVPN)
6. **Observability** — monitoring/tracing
7. **Peripheral** — hardware device interface (ESP32, STM32, Arduino)
8. **Runtime** — execution environment

Component swapping requires only configuration changes, no daemon restart for most trait implementations.

### Web Dashboard

React 19 + Vite 6 + Tailwind CSS 4 SPA served directly from the gateway binary. Sections: Dashboard (overview, health, uptime, cost), Agent Chat, Memory browser, Config editor, Cron manager, Tools inspector, Logs viewer, Cost analytics, Doctor diagnostics, Integrations status, Device pairing.

### Control Plane

HTTP/WS/SSE gateway server (default: `127.0.0.1:42617`). Real-time session management, webhook dispatcher, cron scheduler. Per-session actor queue for concurrent turn serialization (v0.6.5).

---

## Security Model

### Five-Layer Architecture

1. **Network** — localhost binding by default, 64KB body limit, rate limiting, auth rate limiting for brute-force protection (v0.6.5)
2. **Authentication** — 6-digit OTP pairing (code-based device allowlisting), channel allowlists, HMAC webhook validation
3. **Authorization** — 3 autonomy levels (ReadOnly, Supervised, Full), workspace scoping, command allowlists
4. **Runtime** — Optional Docker sandbox, Landlock (Linux), Bubblewrap; read-only rootfs possible via systemd
5. **Data** — ChaCha20-Poly1305 AEAD encryption at rest for secrets, HashiCorp Vault BYOK support

### Autonomy Levels

- **ReadOnly** — observation only
- **Supervised** (default) — requires approval for medium/high-risk operations
- **Full** — autonomous action within policy bounds

### Security Features

- Workspace-scoped filesystem access (forbidden: `/etc`, `/root`, `~/.ssh`)
- Path traversal blocking
- Command allowlists (explicit opt-in for dangerous commands)
- Rate limiting: max actions/hour, max cost/day (configurable)
- DM pairing: unknown senders receive code, messages not processed until approved
- E-stop: emergency shutdown capability
- 129+ security tests in automated CI
- Randomized gateway ports (`--port 0`) to reduce scan exposure

### DartClaw Comparison

| Security Layer | ZeroClaw | DartClaw |
|---|---|---|
| **Container isolation** | Optional Docker; Landlock/Bubblewrap | Docker `network:none`, `--cap-drop=ALL` (always-on) |
| **Credential isolation** | ChaCha20-Poly1305 encrypted secrets at rest | Unix socket credential proxy (keys never in container env) |
| **Network isolation** | Localhost binding default; no network:none | `network:none` + Dart HTTP proxy |
| **Guard pipeline** | Command allowlists, workspace scoping | 3-layer: command-guard + file-guard + network-guard + content-guard |
| **Inbound sanitization** | Rate limiting, body size cap | InputSanitizer + MessageRedactor + rate limiting + loop detection |
| **Pairing** | 6-digit OTP per channel | Token-based auth (64-hex gateway token) |
| **Audit** | 129+ CI tests | Guard audit log (persistent NDJSON) + web UI viewer |

**Assessment:** ZeroClaw's security is application-level (similar to PocketPaw). No per-agent container isolation, no network-level credential proxy. The workspace scoping + command allowlists + Landlock combination is reasonable for single-user, but fundamentally weaker than DartClaw's OS-level defense-in-depth stack.

---

## Channel Support (25+)

| Channel | Status | Notes |
|---|---|---|
| CLI | Default | Built-in REPL |
| Telegram | Stable | Bot API |
| Discord | Stable | Bot token, DM pairing |
| Slack | Stable | Bot token + app token |
| WhatsApp | Feature-gated | Native `wa-rs` (Web mode); requires `--features whatsapp-web` build |
| Signal | Supported | Phone number based |
| iMessage | Supported | macOS only |
| Matrix | Feature-gated | E2EE recovery (v0.6.5), multi-room |
| IRC | Supported | — |
| Email | Supported | — |
| Bluesky | Supported | — |
| Mattermost | Supported | — |
| Nextcloud Talk | Supported | — |
| Nostr | Feature-gated | — |
| DingTalk | Supported | Chinese market |
| Lark | Feature-gated | Chinese market (Feishu) |
| QQ | Supported | Chinese market |
| Reddit | Supported | — |
| LinkedIn | Supported | — |
| Twitter/X | Supported | — |
| MQTT | Supported | IoT messaging |
| WeChat Work | Supported | Chinese enterprise |

**Also supported:** WATI, Mochat, Linq, Notion, WebSocket, ClawdTalk (not in table above).

**Notable:** Broadest channel coverage of any surveyed project (25+ vs OpenClaw's 16+, PocketPaw's 9, DartClaw's 3+web). Several channels are feature-gated (require compile-time flags). WhatsApp has dual mode: Cloud API (official Meta Business Account) or Web mode (`wa-rs` native Rust client, `--features whatsapp-web`). WhatsApp Web mode merged 2026-02-19 but not in default binary builds — requires compile from source. Per-channel config supports `proxy_url` (HTTP/SOCKS5), `allowed_users` allowlists, streaming modes (Partial, MultiMessage), platform-native formatting.

---

## LLM Provider Support (28+)

**OAuth/Subscription:** OpenAI (ChatGPT, o1, o3), OpenAI Codex (ChatGPT subscription OAuth), Google Gemini (including OAuth), Anthropic (Claude — API key or auth token)

**API Key:** OpenRouter, Groq, Together.ai, Replicate, Mistral, Cohere, Hugging Face, xAI (Grok), Perplexity, DeepSeek, DeepMyst, GitHub Copilot, Fireworks, Venice, LM Studio, AWS Bedrock, Ollama, vLLM, llama.cpp, SearXNG (search provider), and custom OpenAI-compatible endpoints

**Features:** Model failover and rotation via `create_resilient_provider()`, multi-provider redundancy, multi-account encrypted auth storage (ChaCha20-Poly1305), multimodal vision routing to dedicated provider (v0.5.8), max-token continuation policy, cost-optimized provider routing strategy (v0.6.3).

**Comparison:** Broader than DartClaw (Claude + Codex) and NanoClaw (Anthropic-compatible), approaching OpenClaw (35+).

---

## Memory & Knowledge System

### Architecture

SQLite-backed with custom vector storage — no external vector DB required.

- **Vector search:** cosine similarity, 70% weight in hybrid scoring
- **Keyword search:** BM25 via FTS5, 30% weight
- **Embedding cache:** 10k LRU entries
- **Storage:** workspace-scoped local filesystem

### Tools

- `recall` — retrieve memories by semantic context
- `store` — save new memory entries
- `forget` — delete memories
- `knowledge` — query knowledge base
- `project_intel` — domain-specific information retrieval

### DartClaw Comparison

ZeroClaw's hybrid search (70/30 vector/BM25) is comparable to DartClaw's QMD hybrid mode. Both use SQLite FTS5 for keyword search. ZeroClaw includes built-in vector embeddings (no external sidecar); DartClaw's QMD uses an external sidecar for neural reranking.

**Migration compatibility:** `zeroclaw migrate openclaw` imports memory entries with category preservation (verified: 59+ memories, zero skipped).

---

## Multi-Agent & Orchestration

### Hands (Agent Swarms)

"Autonomous agent swarms running on schedule, learning over time." Hands are scheduled agent groups that can be assigned persistent goals and improve through iteration.

### Agent-to-Agent Communication

- `delegate` tool for inter-agent task delegation
- Subagent coordination with shared iteration budgets (v0.6.5)
- Parent/subagent resource sharing

### Standard Operating Procedures (SOPs)

Event-driven workflow automation triggered by:
- MQTT messages
- Webhooks
- Cron expressions
- Peripheral triggers (GPIO, hardware events)

SOPs define multi-step workflows that respond to real-world events — unique in the surveyed landscape.

### DartClaw Comparison

ZeroClaw's multi-agent is less structured than DartClaw's HarnessPool + TaskService (no 9-state lifecycle, no review flows, no structured task dashboard). But SOPs and Hands represent a different paradigm — event-driven autonomous workflows vs. human-in-the-loop task orchestration. The hardware peripheral triggers (MQTT, GPIO) are genuinely novel.

---

## Scheduling & Automation

- **Cron scheduling** with add/remove/update/run commands
- **HEARTBEAT.md** pattern (same as OpenClaw)
- **SOP event triggers** (MQTT, webhook, cron, peripheral)
- **CLI:** `zeroclaw cron add/remove/update/run`

---

## CLI Commands

| Command | Purpose |
|---------|---------|
| `zeroclaw daemon` | Full autonomous runtime |
| `zeroclaw gateway` | Control plane + dashboard |
| `zeroclaw agent` | Interactive chat / single message |
| `zeroclaw onboard` | Interactive setup wizard |
| `zeroclaw doctor` | Diagnostics & config validation |
| `zeroclaw status` | System status |
| `zeroclaw migrate openclaw` | Import OpenClaw workspace |
| `zeroclaw service install` | Register as system service |
| `zeroclaw auth` | Manage credentials |
| `zeroclaw channel` | Channel management |
| `zeroclaw skills` | Skill management |
| `zeroclaw cron` | Scheduling management |
| `zeroclaw pairing approve` | Device pairing approval |
| `zeroclaw hardware discover` | Discover connected peripherals |
| `zeroclaw peripheral list/flash` | Manage hardware peripherals |
| `zeroclaw skills list/install/audit/remove` | Skill management with security audit |
| `zeroclaw config schema` | Generate JSON schema for config |

---

## ACP Protocol Support

- **ACP server mode** (v0.6.3): Implemented Agent Communication Protocol server over stdio (JSON-RPC 2.0), enabling integration with ACP-compatible clients like the Zed editor. Issue #4564 tracks further development.
- **ACP client**: `src/channels/acp.rs` — acts as ACP client for tool discovery and execution.
- **MCP client**: JSON-RPC 2.0, discovers and executes tools from remote/local MCP servers. On-demand tool loading via `tool_search` (Issue #3095).

**DartClaw comparison:** DartClaw has MCP server hosting (0.5) but no ACP support yet (deferred per inspiration backlog, waiting for native Claude Code ACP). ZeroClaw implementing ACP server is notable — if Claude Code ships native ACP, ZeroClaw will already have the integration.

---

## Voice & Media Features (Unique)

- **Local Whisper STT** (v0.5.5): `LocalWhisperProvider` for self-hosted speech-to-text transcription. No external API dependency.
- **Local Piper TTS** (v0.5.8): Self-hosted text-to-speech synthesis.
- **Real-time voice calls** (v0.6.3): Twilio/Telnyx integration for live voice conversations.
- **Image generation** (v0.5.7): Standalone image generation via fal.ai.
- **Multimodal vision routing** (v0.5.8): Image messages automatically routed to a dedicated vision provider.
- **Browser automation skill + VNC** (v0.5.9-beta): Web automation with VNC setup.

**DartClaw comparison:** DartClaw has no voice or TTS features. The `claude` binary handles audio natively for WhatsApp voice memos, but there's no self-hosted STT/TTS. Voice is called out as a differentiator DartClaw lacks in the feature comparison.

---

## Desktop Companion App

**Tauri desktop app** (v0.6.0-6.2, `apps/tauri/`): macOS universal `.dmg`, device-aware installer. Currently macOS only; positions ZeroClaw alongside PocketPaw (Tauri), Maestro (Electron), and Proma (Electron-style) in the desktop client space.

---

## ClaudeCodeTool (Agent-as-Subagent)

**v0.5.5:** Two-tier agent delegation — ZeroClaw can spawn a Claude Code session as a subagent via `ClaudeCodeTool`. This is architecturally interesting: a Rust agent runtime delegating coding tasks to Claude Code's native capabilities. Similar in concept to DartClaw's JSONL control protocol, but invoked as a tool rather than as the primary harness.

---

## Additional Security Features (v0.6.3+)

Beyond the five-layer model documented above:

- **Mutual TLS (mTLS)** for high-security deployments
- **WebAuthn / hardware key authentication** for gateway access
- **Ed25519 plugin signature verification** — signed skill/plugin packages
- **HMAC-SHA256 audit trail** — cryptographically verifiable action log
- **macOS Seatbelt sandbox profiles** (sandbox-exec)
- **Per-domain trust scoring** with regression detection
- **seccomp sandbox** + capability dropping for single-process workloads
- **Escalate-to-human tool** with urgency routing — agent can hand off to a human when confidence is low

---

## Atomic Soul Export

Core memories are continuously exported to `MEMORY_SNAPSHOT.md` — Git-visible, survives database loss. The agent's "soul" is always inspectable as a markdown file in the workspace. This addresses the "memory as black box" problem — useful for auditing and debugging agent behavior.

**DartClaw comparison:** DartClaw's `MEMORY.md` serves a similar role but is agent-maintained, not automatically exported from the database. The automatic export pattern is worth studying.

---

## AIEOS Identity System

AI Entity Object Specification — a structured identity definition beyond prompt-only configuration:

- **Identity:** name, background, profile metadata
- **Psychology:** cognitive preferences, ethics, personality traits
- **Linguistics:** language style, tone, expression patterns
- **Motivations:** short-term and long-term goals for behavior guidance

Positioned as a "portable and standardized AI persona" spec. More structured than OpenClaw's SOUL.md or DartClaw's behavior files — defines personality traits, ethics frameworks, and psychological profiles that persist across sessions.

---

## Hardware & IoT Support (Unique)

Firmware targets for embedded platforms:

| Target | Platform | Purpose |
|--------|----------|---------|
| ESP32 | Espressif | Wireless peripheral agent |
| ESP32-UI | ESP32 + Display | Agent with visual interface |
| STM32 Nucleo | ARM Cortex-M | Industrial peripheral |
| Arduino | Arduino | Sensor/actuator bridge |
| Uno Q Bridge | Arduino Uno | Serial bridge to agent |

**No other surveyed project has hardware peripheral integration.** This enables physical-world automation — LED control, sensor reading, motor actuation — triggered by AI agent decisions. Combined with MQTT channel and SOP triggers, creates an IoT agent platform.

---

## Configuration

**Format:** TOML (auto-migrated from OpenClaw JSON)

**Workspace:** `~/.zeroclaw/workspace/` containing sessions/, memory/, state/, cron/, skills/, and identity files (IDENTITY.md, AGENTS.md, SOUL.md, USER.md, TOOLS.md).

**Minimal config:**
```toml
default_provider = "anthropic"
api_key = "sk-ant-..."
```

**Tunnel options:** Cloudflare, Tailscale, ngrok, OpenVPN, custom command, none (local only).

**Hot-reload:** Config changes applied without daemon restart for most settings.

---

## Deployment

- **Homebrew:** `brew install zeroclaw`
- **One-click bootstrap:** clone + `./install.sh`
- **From source:** `cargo build --release --locked`
- **Docker:** Alpine and Debian variants
- **Systemd:** `zeroclaw service install`
- **Marketplace:** Coolify, Dokploy, EasyPanel templates (v0.6.5)
- **Binaries:** Linux (x86_64, aarch64, armv7), macOS (x86_64, aarch64), Windows (x86_64)
- **Package managers:** crates.io, Scoop (Windows), AUR (Arch), Homebrew

---

## Recent Release Highlights (v0.6.x)

### v0.6.5 (Mar 27, 2026)
- Context overflow recovery in interactive daemon and tool call loops
- Fast-path tool result trimming in context compressor
- Preemptive context check before provider calls
- Shared iteration budgets for parent/subagent coordination
- Inbound message debouncing for rapid senders
- Auth rate limiting for brute-force protection
- Per-session actor queue for concurrent turn serialization
- Session state machine (idle/running/error)
- Web chat history persistence across navigation
- Slack permalink resolution
- Matrix E2EE auto-recovery with multi-room listening
- Marketplace templates (Coolify, Dokploy, EasyPanel)

---

## Maturity Concerns

From the migration assessment (Feb 2026, may have improved since):

- **261 `.unwrap()` calls** across 80 files (panic risk — Rust idiom for "crash on unexpected state")
- **6 modules using `std::sync::Mutex` in async contexts** (potential deadlock)
- **3 integration tests** (very low test coverage)
- **Daily release cadence** (fast iteration but moving target)
- **WhatsApp Web is feature-gated** — not in default binary builds
- **No plugin system** — extending requires Rust PRs or sidecars
- **Missing session persistence** — no `sessions.json` equivalent for transcript mapping

These are significant maturity gaps for production use. The rapid star growth (29k) and release cadence suggest active improvement, but code quality indicators lag behind the hype.

---

## Interesting Features for DartClaw Inspiration

### 1. AIEOS Identity System (P3)
Structured identity beyond SOUL.md — psychology, linguistics, motivations. More structured than DartClaw's behavior files. Worth studying for the personal AI identity story.

### 2. SOP Event-Driven Workflows (P2)
MQTT/webhook/cron/peripheral triggers → workflow automation. Complements DartClaw's planned Cue-style triggers (inspiration backlog). The MQTT + hardware peripheral angle is novel.

### 3. Hardware Peripheral Integration (P3)
ESP32/STM32/Arduino firmware targets. Unique in the landscape. Low priority for DartClaw but validates IoT agent use cases.

### 4. OpenClaw Migration Tool (Reference)
`zeroclaw migrate openclaw --dry-run` with config format conversion + memory import. DartClaw should consider a similar migration path for the eventual public launch.

### 5. Marketplace Templates (P3)
Coolify, Dokploy, EasyPanel deployment templates. Low-effort deployment expansion that increases accessibility.

### 6. Context Overflow Recovery (P2)
v0.6.5 adds preemptive context checks, fast-path tool result trimming, graceful shutdown on max iterations. DartClaw's `ContextMonitor` (0.10) covers some of this, but the tool-result-specific trimming is worth studying.

### 7. Message Debouncing at Channel Level (Reference)
Already implemented in DartClaw (0.2, 1000ms default). ZeroClaw added this in v0.6.5 — validates the pattern.

### 8. ACP Server Mode (P2 — watch)
v0.6.3 implemented ACP server over stdio. If Claude Code ships native ACP, ZeroClaw will already have the integration ready. DartClaw's ACP backlog item should monitor this.

### 9. Atomic Soul Export (P3)
Continuous export of core memories to `MEMORY_SNAPSHOT.md` — Git-visible, survives database loss. DartClaw's `MEMORY.md` is agent-maintained; an automatic database-to-markdown export would add auditability.

### 10. Local Voice Features (Reference)
Local Whisper STT + Piper TTS + Twilio/Telnyx live voice calls. Unique in the landscape. DartClaw's voice story relies on the `claude` binary handling audio natively. Self-hosted voice processing is a genuine differentiator for privacy-focused users.

### 11. Escalate-to-Human Tool (P3)
Agent can hand off to a human with urgency routing when confidence is low. Interesting for DartClaw's crowd coding and channel-based workflows where human oversight is expected.

### 12. Desktop Companion App (Reference)
Tauri desktop app (v0.6.0). ZeroClaw joins PocketPaw, Maestro, and Proma in the desktop client space. DartClaw's Flutter app (P5) is planned but not built. The proliferation of desktop clients across competitors validates this as a competitive front.

---

## Strategic Assessment

### Where ZeroClaw Leads (vs DartClaw)
1. **Resource efficiency** — <5MB RAM, <10ms startup, $5 VPS viable. DartClaw's AOT binary is efficient but not in this class
2. **Channel breadth** — 25+ channels vs DartClaw's 3+web
3. **LLM provider breadth** — 28+ vs DartClaw's 2 (Claude + Codex)
4. **Community momentum** — 29k stars (explosive growth), 4k forks, 31 README languages
5. **IoT/edge story** — hardware peripherals, RISC-V support, ESP32 firmware
6. **Web dashboard** — React 19 SPA (richer than DartClaw's HTMX)
7. **Voice features** — local Whisper STT + Piper TTS + Twilio/Telnyx live calls
8. **OpenClaw migration** — drop-in migration tool with dry-run
9. **AIEOS identity** — more structured persona definition
10. **ACP server** — already implemented, ahead of DartClaw on protocol support
11. **Desktop app** — Tauri companion (macOS)

### Where DartClaw Leads (vs ZeroClaw)
1. **Security depth** — container isolation + credential proxy + 3-layer guard pipeline. ZeroClaw's security is application-level only (no container isolation, no credential proxy)
2. **Task orchestration** — 9-state lifecycle, review flows, parallel execution, coding worktrees. ZeroClaw has no structured task model
3. **Crowd coding** — multi-user collaborative steering via channels. ZeroClaw is single-user
4. **Runtime governance** — per-sender + global rate limiting, daily token budgets with warn/block, 3-heuristic loop detection. ZeroClaw has basic rate limiting only
5. **Turn trace persistence** — per-turn duration, token breakdown incl. cache, tool call records, query API. ZeroClaw has basic observability
6. **Multi-project support** — project registry, auto-fetch, PR creation
7. **Auditable supply chain** — AOT Dart binary, zero npm. ZeroClaw is also compiled (Rust) but has a React 19 frontend dependency
8. **Thread binding** — channel-agnostic task-to-thread routing with auto-unbind
9. **Test maturity** — comprehensive test suites vs ZeroClaw's limited testing
10. **Immutable system prompt** — behavior files are host-managed, not agent-writable (eliminates persistence attacks)

### Overall Position

ZeroClaw is a **Tier 1 competitor by community momentum** (29k stars) but **not a direct threat to DartClaw's niche**. The two projects optimize for different axes:

- **ZeroClaw** = maximum reach (25+ channels, 28+ LLM providers, IoT hardware, voice, $5 VPS, desktop app)
- **DartClaw** = maximum depth (security, task orchestration, governance, multi-user, observability, multi-project)

ZeroClaw's security model (application-level only) means it's unsuitable for the security-conscious daily-driver use case that DartClaw targets. But its community size (29k, surpassing NanoClaw), channel breadth, voice features, and rapid iteration create competitive pressure on multiple fronts. The ACP server implementation is ahead of DartClaw and worth monitoring.

**Key watch items:**
- ZeroClaw's maturity improving — v0.6.x added significant robustness (context recovery, session state machine, mTLS). If test coverage improves, the maturity gap narrows.
- ACP server adoption — if Zed/other editors adopt ZeroClaw's ACP, it creates ecosystem lock-in.
- Desktop companion app evolution — Tauri app is early; if it matures, it competes directly with DartClaw's planned Flutter app.

---

## References

- [GitHub Repository](https://github.com/zeroclaw-labs/zeroclaw) — 29k stars, 4k forks
- [Official Website](https://www.zeroclawlabs.ai/)
- [Releases](https://github.com/zeroclaw-labs/zeroclaw/releases) — v0.6.5 latest
- [Wiki: Memory System](https://github.com/zeroclaw-labs/zeroclaw/wiki/09-Memory-System)
- [DeepWiki](https://deepwiki.com/zeroclaw-labs/zeroclaw) — auto-generated docs
- [DEV Community Analysis](https://dev.to/brooks_wilson_36fbefbbae4/zeroclaw-a-lightweight-secure-rust-agent-runtime-redefining-openclaw-infrastructure-2cl0)
- [Pinggy Analysis](https://pinggy.io/blog/zeroclaw_lightweight_openclaw_alternative/)
- [Migration Assessment (Gist)](https://gist.github.com/yanji84/ebc72e9b02553786418c2c24829752c7)
- [BrightCoding Review](https://www.blog.brightcoding.dev/2026/03/20/zeroclaw-the-10-ai-assistant-that-runs-on-5mb-ram)
- [SparkCo OpenClaw vs ZeroClaw Comparison](https://sparkco.ai/blog/openclaw-vs-zeroclaw-which-ai-agent-framework-should-you-choose-in-2026)
- [Cloudron Forum Thread](https://forum.cloudron.io/topic/15080/zeroclaw-rust-based-alternative-to-openclaw-picoclaw-nanobot-agentzero)
- [HN: "ZeroClaw – Zero overhead. Zero compromise. 100% Rust"](https://news.ycombinator.com/item?id=47047192)
- [HN: "Has anyone used OpenClaw/NanoClaw/IronClaw/PicoClaw/ZeroClaw?"](https://news.ycombinator.com/item?id=47195676)
- [ACP Server Issue #4564](https://github.com/zeroclaw-labs/zeroclaw/issues/4564)
- [MCP On-Demand Tool Loading Issue #3095](https://github.com/zeroclaw-labs/zeroclaw/issues/3095)

# Changelog

## 0.5 — 2026-03-03

Security hardening, memory lifecycle, MCP foundation, package split, Signal/WhatsApp E2E verification.

### Security
- **Input sanitizer** (S01): `InputSanitizer` — regex-based prompt injection prevention on all inbound channel messages; 4 built-in pattern categories (instruction override, role-play, prompt leak, meta-injection); content length cap to bound backtracking
- **Outbound redaction** (S02): `MessageRedactor` strips secrets and PII from agent output across all 4 delivery paths (channel, SSE, tool output, logs)
- **Content classifier** (S03): `ContentClassifier` abstract interface; `ClaudeBinaryClassifier` (OAuth-compatible, default) and `AnthropicApiClassifier` implementations; config-driven via `content_guard.classifier`
- **Webhook hardening** (S05): shared-secret validation on incoming webhooks; payload size limit; `UsageTracker` records per-agent token usage to `usage.jsonl` with daily KV aggregates

### Memory
- **Memory pruning** (S07): `MemoryPruner` — deduplication and age-based archiving of MEMORY.md entries to `MEMORY.archive.md`; FTS5-searchable archive; registered as built-in `ScheduledJob` (visible in scheduling UI, supports pause/resume)
- **Self-improvement files** (S06): `SelfImprovementService` — `errors.md` auto-populated on turn failures/guard blocks; `learnings.md` writable via `memory_save`; both loaded in behavior cascade

### Channels
- **Signal** (S12): `formatResponse` implementation + DM/group access config
- **Signal voice verification** (S13): voice verification flow + route tests
- **WhatsApp E2E** (S14): end-to-end test suite for WhatsApp channel
- **Signal E2E** (S15): end-to-end test suite for Signal channel

### MCP
- **MCP foundation** (S16): `McpTool` interface, MCP router with 1 MB body size limit, tool registration scaffolding
- **MCP tool migration** (S17): `SessionsSendTool`, `SessionsSpawnTool`, `MemorySaveTool`, `MemorySearchTool`, `MemoryReadTool` implementing `McpTool` interface

### Configuration
- **Search agent model config** (S04): configurable model for search agent via `dartclaw.yaml`
- **Live config tier 1** (S18): `RuntimeConfig` ephemeral state; runtime toggles for heartbeat and git sync via `/api/settings/*`; per-job pause/resume via `/api/scheduling/jobs/<name>/toggle`

### Architecture
- **Package split** (S11): new `packages/dartclaw_storage/` extracts sqlite3-backed services from `dartclaw_core` (`MemoryService`, `SearchDb`, FTS5/QMD backends, `MemoryPruner`); `dartclaw_core` is now sqlite3-free
- **API surface audit** (S10): barrel exports narrowed with `show` clauses; `///` doc comments added to all exported symbols

### Documentation
- **Use-case cookbook** (S08+S09): `docs/guide/` expanded with WhatsApp, Signal, scheduling, and deployment recipes


## 0.4 — 2026-03-03

Template engine migration, SPA navigation, search agent wiring, Signal channel.

### Trellis Template Engine
- Migrated all 13 templates from inline Dart string builders to `.html` files with Trellis engine (`tl:text` auto-escaping, `tl:utext` trusted HTML, `tl:fragment` for partial rendering)
- `TemplateLoader` pre-loads and validates all templates at startup (smoke-render with empty context)
- 42 render tests covering all templates and fragments

### HTMX SPA Navigation
- SPA-style navigation via `hx-get` + `hx-target="#main-content"` + `hx-select-oob` for topbar/sidebar
- Two-path server rendering: full page for direct requests, fragment for HTMX requests (`HX-Request` detection)
- Streaming guard: disables nav links during SSE stream, re-enables on `htmx:sseClose`
- View Transitions API integration with CSS fade animations
- `HX-Location` redirect for session create/reset, `Vary: HX-Request` for caching correctness
- `htmx:afterSwap` re-init for `marked`/`hljs` content rendering

### Server Integration
- Wired `SessionDelegate`, `ContentGuard`, `ToolPolicyGuard` into `serve_command.dart`
- Search agent session directory created at startup; graceful degradation when `ANTHROPIC_API_KEY` missing
- FTS5 `SearchBackend` wired into memory service handlers; memory consolidation in heartbeat
- Content-guard fail-closed when API key available

### Signal Channel
- `SignalConfig`, `SignalCliManager` (exponential backoff 1s→30s), `SignalChannel` implementing `Channel` interface
- `SignalDmAccessController` + `SignalMentionGating` for DM/group access control
- Webhook route (`/webhook/signal?secret=<token>`) with constant-time secret validation
- Pairing page (SMS/voice/linked device registration flows)
- Settings status card + conditional sidebar nav item
- Message deduplication, Docker-unavailable degradation

### Other
- Trellis upgraded to 0.2.1 (resolves `<tl:block>` fragment, null `tl:each`, `!` negation)
- `constantTimeEquals` extracted to `auth/auth_utils.dart`, shared across webhook/signal/token auth
- Version fallback `'unknown'` instead of hardcoded `'0.2.0'`


## 0.3 — 2026-03-01

Consolidation milestone — template DX, tech debt resolution, system prompt correctness, GOWA v8 alignment. No new features or dependencies.

### Template DX
- Extracted ~215 lines of inline `<style>` blocks from 6 templates to `components.css`
- Added `pageTopbarTemplate()` — single function replaces 4 pages' inline topbar markup
- Decomposed monolithic templates (`healthDashboard`, `settings`) into sub-functions
- Consolidated formatting helpers (`formatUptime`, `formatBytes`) into `helpers.dart`

### Tech Debt Resolution
- **Per-session concurrency** (TD-003): same-session requests now queue behind active turn instead of returning 409; `SessionLockManager` with `Completer`-based async wait
- **Crash recovery** (TD-004): turn state persisted to `kv.json`; orphaned turns detected and cleaned on restart; client receives recovery banner
- **SessionKey** (TD-008): moved to `dartclaw_core` with composite key format (`agent:<id>:<scope>:<identifiers>`); factory methods for web/peer/channel/cron sessions; lazy migration for existing UUID keys
- **System prompt** (ADR-007): switched to `--append-system-prompt` to preserve Claude Code's built-in prompt (tools, safety, git protocols); MEMORY.md access via MCP tools instead of prompt injection
- Guard integration tests (TD-017), search backend contract tests (TD-018)

### WhatsApp / GOWA v8 Alignment
- Full API realignment to GOWA v8.3.2 contract — CLI args (`rest` subcommand, `--webhook`, `--db-uri`), endpoint paths (`/app/status`, `/send/message`, `/app/login-with-code`), response envelope unwrapping
- Multipart media upload with type-specific routing (image/video/file)
- Webhook parsing for v8 nested envelope (`{event, device_id, payload}`) with `is_from_me` filtering
- Webhook shared secret (`?secret=<token>`) for lightweight endpoint protection
- Config defaults: binary `whatsapp` (was `gowa`), port `3000` (was `3080`)
- Startup cleanup: kill orphaned GOWA process on health check failure

### Other
- `KvService.getByPrefix()` for key-range queries
- `Channel.formatResponse()` virtual method for per-channel response formatting
- `PromptStrategy` enum (`append`/`replace`) on `AgentHarness`
- `BehaviorFileService.composeStaticPrompt()` for spawn-time prompt composition


## 0.2 — 2026-02-27

Initial public release. Core agent runtime with security hardening.

- 2-layer architecture: Dart host → native `claude` binary via JSONL control protocol
- File-based storage (NDJSON sessions, JSON KV, FTS5 search index)
- Memory system (MEMORY.md, MCP tools, FTS5/QMD hybrid search)
- HTMX + SSE web UI with session management
- REST API, CLI (`serve`, `status`, `rebuild-index`, `deploy`)
- Behavior files (SOUL.md, USER.md, TOOLS.md, AGENTS.md)
- Guard plugin architecture (command, file, network guards)
- HTTP auth (token/cookie), security headers, CSP, CORS
- Per-session concurrency, structured logging, health endpoint
- Docker container isolation + credential proxy
- Cron scheduling with deterministic session keys
- WhatsApp channel (GowaManager sidecar, webhook receiver, DM/group access control, mention gating, pairing UI)
- Deployment tooling (launchd/systemd, firewall rules)

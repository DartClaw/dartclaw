# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Channel DM access management — unified controller, config API, settings UI, pairing flow.

### Added
- **Unified DM access controller** (S02): shared `DmAccessController` extracted to `dartclaw_core/channel/`; Signal gains `pairing` mode (was WhatsApp-only); `SignalDmAccessController` removed; `DmAccessMode` enum (`open`, `disabled`, `allowlist`, `pairing`) shared across both channels; Signal allowlist accepts both phone numbers and ACI UUIDs
- **Channel access config API** (S03): `GET/PATCH /api/config` now includes channel DM/group access fields; dedicated allowlist CRUD endpoints (`GET/POST/DELETE /api/config/channels/<type>/dm-allowlist`); allowlist changes are live (no restart); E.164 and JID validation on entries
- **Channel access config UI** (S04): `/settings/channels/whatsapp` and `/settings/channels/signal` detail pages; DM mode selector, DM allowlist editor, group mode selector, group allowlist editor, mention gating toggle; restart-required banner for mode changes; closes wireframe deviation #8
- **Pairing flow** (S05): unknown senders in `pairing` mode now trigger `createPairing()` instead of silent drop; pending pairings shown on channel detail page with sender ID, display name, and expiry countdown; Approve/Reject buttons wire through `confirmPairing()` → live allowlist update + YAML persist; pairing management endpoints (`GET /api/channels/<type>/dm-pairing`, `POST .../confirm`, `DELETE .../reject`); notification badge on channel card when pending pairings exist; HTMX polling for real-time updates

### Changed
- **Doc corrections** (S01): GOWA v8 alignment plan corrected — `GET /app/status` `device_id` is an internal UUID, not the WhatsApp JID; JID available via `GET /devices` → `jid` and `LOGIN_SUCCESS` event; signal-cli sealed-sender behaviour documented — `source` field carries ACI UUID, `sourceNumber` is the phone fallback

---

## [0.6.0] — 2026-03-05

Config editing, guard audit UI, memory dashboard, MCP tool extensions, SDK prep.

### Added
- **YAML config writer** (S02): `ConfigWriter` — round-trip YAML edits via `yaml_edit`, preserves comments and formatting; automatic backup before write
- **Config validation** (S03): `ConfigMeta` field registry + `ConfigValidator`; typed field descriptors with constraints; validation errors surfaced in UI
- **Config read/write API** (S04): `GET /api/config` + `PATCH /api/config` for live config updates; job CRUD endpoints (`POST /api/scheduling/jobs`, `PUT /api/scheduling/jobs/<name>`, `DELETE /api/scheduling/jobs/<name>`)
- **Settings page form mode** (S05): data-driven editable forms for all config sections; live-mutable toggles; restart-required badge on fields that need a server restart
- **Scheduling job management UI** (S06): inline add/edit/delete jobs on the scheduling page; cron expression human-readable preview
- **Graceful restart** (S07): `RestartService` — drains active turns then exits; SSE broadcast notifies connected clients; persistent banner survives the restart; client overlay blocks interaction during drain
- **Guard audit storage** (S08): `GuardAuditSink` — persistent NDJSON file log of every guard decision; automatic rotation at 10 000 entries
- **Guard audit web UI** (S09): guard audit table on `/health-dashboard` — paginated table of audit entries; filter by guard type and verdict
- **Guard config detail viewer** (S10): per-guard configuration cards on `/settings`; `FileGuard` rule display
- **Memory status API** (S11): `MemoryStatusService` — memory file sizes, entry counts, last-prune timestamp; pruner run history stored in KV
- **Memory dashboard** (S12): `/memory` page with 5 sections (status, files, pruner history, archive stats, manual prune); 30-second HTMX polling; prune confirmation dialog
- **`web_fetch` MCP tool** (S13): `WebFetchTool` — fetches URLs and converts HTML to Markdown for agent consumption
- **Search MCP tools** (S14): `SearchProvider` interface; `BraveSearchTool` and `TavilySearchTool` implementations; provider selected via config
- **`registerTool()` SDK API** (S15): public API on `DartClaw` for registering external MCP tools without forking
- **Harness auto-config for MCP** (S16): registered MCP tools automatically wired into harness `--mcp-config` at spawn time; no manual config required

### Changed
- **Package split** (S17): new `packages/dartclaw_models/` extracted from `dartclaw_core` — `models.dart` + `session_key.dart`; consumers depend on `dartclaw_models` directly
- **API surface + doc comments** (S18): `///` doc comments on all exported symbols across `dartclaw_core`, `dartclaw_models`, `dartclaw_storage`, `dartclaw_server`; barrel exports tightened; pana score 145/160; all packages bumped to 0.6.0

---

## [0.5.0] — 2026-03-03

Security hardening, memory lifecycle, MCP foundation, package split, Signal/WhatsApp E2E verification.

### Added
- **Input sanitizer** (S01): `InputSanitizer` — regex-based prompt injection prevention on all inbound channel messages; 4 built-in pattern categories (instruction override, role-play, prompt leak, meta-injection); content length cap to bound backtracking
- **Outbound redaction** (S02): `MessageRedactor` strips secrets and PII from agent output across all 4 delivery paths (channel, SSE, tool output, logs)
- **Content classifier** (S03): `ContentClassifier` abstract interface; `ClaudeBinaryClassifier` (OAuth-compatible, default) and `AnthropicApiClassifier` implementations; config-driven via `content_guard.classifier`
- **Webhook hardening** (S05): shared-secret validation on incoming webhooks; payload size limit; `UsageTracker` records per-agent token usage to `usage.jsonl` with daily KV aggregates
- **Memory pruning** (S07): `MemoryPruner` — deduplication and age-based archiving of MEMORY.md entries to `MEMORY.archive.md`; FTS5-searchable archive; registered as built-in `ScheduledJob` (visible in scheduling UI, supports pause/resume)
- **Self-improvement files** (S06): `SelfImprovementService` — `errors.md` auto-populated on turn failures/guard blocks; `learnings.md` writable via `memory_save`; both loaded in behavior cascade
- **Signal `formatResponse`** (S12): implementation + DM/group access config
- **Signal voice verification** (S13): voice verification flow + route tests
- **WhatsApp E2E tests** (S14): end-to-end test suite for WhatsApp channel
- **Signal E2E tests** (S15): end-to-end test suite for Signal channel
- **MCP foundation** (S16): `McpTool` interface, MCP router with 1 MB body size limit, tool registration scaffolding
- **MCP tool migration** (S17): `SessionsSendTool`, `SessionsSpawnTool`, `MemorySaveTool`, `MemorySearchTool`, `MemoryReadTool` implementing `McpTool` interface
- **Search agent model config** (S04): configurable model for search agent via `dartclaw.yaml`
- **Live config tier 1** (S18): `RuntimeConfig` ephemeral state; runtime toggles for heartbeat and git sync via `/api/settings/*`; per-job pause/resume via `/api/scheduling/jobs/<name>/toggle`
- **Use-case cookbook** (S08+S09): `docs/guide/` expanded with WhatsApp, Signal, scheduling, and deployment recipes
- **Stateless auth**: HMAC-signed session cookies replace in-memory `SessionStore`; sessions survive server restarts; `token rotate` auto-invalidates
- **SPA fragment detection**: pairing pages (Signal, WhatsApp) return HTMX fragments for SPA navigation
- **HTMX history restore handler**: re-initializes markdown rendering and UI state after browser back/forward navigation

### Changed
- **Package split** (S11): new `packages/dartclaw_storage/` extracts sqlite3-backed services from `dartclaw_core` (`MemoryService`, `SearchDb`, FTS5/QMD backends, `MemoryPruner`); `dartclaw_core` is now sqlite3-free
- **API surface audit** (S10): barrel exports narrowed with `show` clauses; `///` doc comments added to all exported symbols
- **Channel dispatcher**: extracted shared `_dispatchTurn()` helper for ChannelManager and HeartbeatScheduler

---

## [0.4.0] — 2026-03-03

Template engine migration, SPA navigation, search agent wiring, Signal channel.

### Added
- SPA-style navigation via `hx-get` + `hx-target="#main-content"` + `hx-select-oob` for topbar/sidebar
- Two-path server rendering: full page for direct requests, fragment for HTMX requests (`HX-Request` detection)
- Streaming guard: disables nav links during SSE stream, re-enables on `htmx:sseClose`
- View Transitions API integration with CSS fade animations
- `HX-Location` redirect for session create/reset, `Vary: HX-Request` for caching correctness
- `htmx:afterSwap` re-init for `marked`/`hljs` content rendering
- Wired `SessionDelegate`, `ContentGuard`, `ToolPolicyGuard` into `serve_command.dart`
- Search agent session directory created at startup; graceful degradation when `ANTHROPIC_API_KEY` missing
- FTS5 `SearchBackend` wired into memory service handlers; memory consolidation in heartbeat
- Content-guard fail-closed when API key available
- `SignalConfig`, `SignalCliManager` (exponential backoff 1s→30s), `SignalChannel` implementing `Channel` interface
- `SignalDmAccessController` + `SignalMentionGating` for DM/group access control
- Webhook route (`/webhook/signal?secret=<token>`) with constant-time secret validation
- Pairing page (SMS/voice/linked device registration flows)
- Settings status card + conditional sidebar nav item
- Message deduplication, Docker-unavailable degradation
- `constantTimeEquals` extracted to `auth/auth_utils.dart`, shared across webhook/signal/token auth

### Changed
- Migrated all 13 templates from inline Dart string builders to `.html` files with Trellis engine (`tl:text` auto-escaping, `tl:utext` trusted HTML, `tl:fragment` for partial rendering)
- `TemplateLoader` pre-loads and validates all templates at startup (smoke-render with empty context)
- 42 render tests covering all templates and fragments
- Trellis upgraded to 0.2.1 (resolves `<tl:block>` fragment, null `tl:each`, `!` negation)
- Version fallback `'unknown'` instead of hardcoded `'0.2.0'`

---

## [0.3.0] — 2026-03-01

Consolidation milestone — template DX, tech debt resolution, system prompt correctness, GOWA v8 alignment. No new features or dependencies.

### Added
- `pageTopbarTemplate()` — single function replaces 4 pages' inline topbar markup
- `KvService.getByPrefix()` for key-range queries
- `Channel.formatResponse()` virtual method for per-channel response formatting
- `PromptStrategy` enum (`append`/`replace`) on `AgentHarness`
- `BehaviorFileService.composeStaticPrompt()` for spawn-time prompt composition

### Changed
- Extracted ~215 lines of inline `<style>` blocks from 6 templates to `components.css`
- Decomposed monolithic templates (`healthDashboard`, `settings`) into sub-functions
- Consolidated formatting helpers (`formatUptime`, `formatBytes`) into `helpers.dart`
- **Per-session concurrency** (TD-003): same-session requests now queue behind active turn instead of returning 409; `SessionLockManager` with `Completer`-based async wait
- **Crash recovery** (TD-004): turn state persisted to `kv.json`; orphaned turns detected and cleaned on restart; client receives recovery banner
- **SessionKey** (TD-008): moved to `dartclaw_core` with composite key format (`agent:<id>:<scope>:<identifiers>`); factory methods for web/peer/channel/cron sessions; lazy migration for existing UUID keys
- **System prompt** (ADR-007): switched to `--append-system-prompt` to preserve Claude Code's built-in prompt (tools, safety, git protocols); MEMORY.md access via MCP tools instead of prompt injection
- Full API realignment to GOWA v8.3.2 contract — CLI args (`rest` subcommand, `--webhook`, `--db-uri`), endpoint paths (`/app/status`, `/send/message`, `/app/login-with-code`), response envelope unwrapping
- Multipart media upload with type-specific routing (image/video/file)
- Webhook parsing for v8 nested envelope (`{event, device_id, payload}`) with `is_from_me` filtering
- Webhook shared secret (`?secret=<token>`) for lightweight endpoint protection
- Config defaults: binary `whatsapp` (was `gowa`), port `3000` (was `3080`)
- Startup cleanup: kill orphaned GOWA process on health check failure
- Guard integration tests (TD-017), search backend contract tests (TD-018)

---

## [0.2.0] — 2026-02-27

Initial public release. Core agent runtime with security hardening.

### Added
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

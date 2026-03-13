# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

---

## [0.8.0] — 2026-03-09

Task orchestration, parallel execution, coding tasks with git worktree isolation, task dashboard, Google Chat channel, agent observability. Post-implementation security hardening, performance, and documentation.

### Added
- **PageRegistry + SDK API** (S01): `DashboardPage` abstract class + `PageRegistry` with `register()`, `resolve()`, `navItems()`; all system pages migrated to registry-based registration; `server.registerDashboardPage()` SDK API for external page plugins
- **Per-profile containers** (S02): per-type container isolation (ADR-012); `workspace` profile (workspace:rw, project:ro) and `restricted` profile (no workspace mount); deterministic naming via `ContainerManager.generateName()`; `ServiceWiring` manages both profiles
- **Task domain model** (S03): `TaskStatus` enum (9 states: draft/queued/running/interrupted/review/accepted/rejected/cancelled/failed) with validated state machine transitions; `TaskType` enum (coding/research/writing/analysis/automation/custom); `Task` + `TaskArtifact` value classes
- **Task persistence** (S04): `TaskService` with SQLite persistence in `tasks.db` (WAL mode); CRUD + lifecycle operations; list queries filterable by status and type
- **Task REST API** (S05): full lifecycle API — `POST /api/tasks`, `GET /api/tasks`, `GET /api/tasks/<id>`, start/checkout/cancel/review actions, artifact endpoints; `TaskStatusChangedEvent` + `TaskReviewReadyEvent` fired via event bus
- **Task executor** (S06): `TaskExecutor` polls queued tasks (FIFO); `SessionKey.taskSession(taskId)` factory; `ArtifactCollector` gathers outputs by type; push-back injects comment and re-queues; task sessions hidden from main sidebar
- **HarnessPool + TurnRunner** (S07): `TurnRunner` extracted from `TurnManager`; `HarnessPool` manages multiple `AgentHarness` instances with acquire/release lifecycle; configurable `tasks.max_concurrent` (default: 3); per-session turn serialization
- **Container dispatch routing** (S08): task type → security profile routing (research → `restricted`, others → `workspace`); `ContainerStartedEvent` / `ContainerCrashedEvent`; container crash transitions in-flight tasks to `failed`
- **WorktreeManager** (S09): git worktree lifecycle — `create(taskId, baseRef)` creates `dartclaw/task-<id>` branch; `FileGuard` integration for worktree path isolation; `--directory` flag passed to `claude` binary; stale detection; configurable base ref via `tasks.worktree.base_ref`
- **Diff review + merge** (S10): diff artifact generated from worktree vs base branch; structured diff data (file list, additions, deletions, hunks); configurable merge strategy (`squash`/`merge` via `tasks.worktree.merge_strategy`); accept → squash-merge + cleanup; merge conflicts keep task in `review` with conflict details
- **Task dashboard** (S11): `/tasks` page registered via `PageRegistry`; filterable list by status/type; running task status cards with elapsed time; SSE live updates; review queue at `/tasks?status=review`; sidebar badge count for pending reviews
- **Task detail page** (S12): `/tasks/<id>` with embedded chat view, type-specific artifact panel (markdown, structured diff), Accept/Reject/Push Back review controls, "New Task" form with type-conditional fields
- **Scheduled tasks** (S13): new `task` job type alongside existing `prompt`; cron fires → auto-creates task with `autoStart: true`; completed tasks enter review queue; scheduling UI updated for task-type jobs
- **Google Chat config + auth** (S14): `GoogleChatConfig` model with YAML parsing; GCP service account OAuth2 (inline JSON / file path / env var); inbound JWT verification (app-url OIDC + project-number self-signed modes); 10min certificate cache
- **Google Chat channel** (S15): `GoogleChatChannel` implementing `Channel` interface; webhook handler at `POST /integrations/googlechat` with JWT verification; Chat REST API client (send, edit, download); per-space rate limiting (1 write/sec); typing indicator pattern for async turns; message chunking at ~4,000 chars
- **Google Chat session + access** (S16): session keying via `SessionScopeConfig.forChannel("googlechat")`; `DmAccessController` reuse (pairing/allowlist/open/disabled); mention gating; `ServiceWiring` registration
- **Google Chat config UI** (S17): `/settings/channels/google_chat` channel detail page; mode selectors, allowlist editor, mention toggle, connection status; config API extended for Google Chat fields
- **Goal model** (S18): `Goal` class (id, title, parentGoalId, mission); `goals` table in `tasks.db`; tasks reference goals via `goalId`; goal + parent goal context injection into task sessions (~200 tokens, 2 levels max); `POST/GET/DELETE /api/goals`
- **Agent observability** (S19): `AgentObserver` tracks per-harness metrics (tokens, turns, errors, current task); `GET /api/agents` + `GET /api/agents/<id>` endpoints; pool status (active/available/max); agent overview section on `/tasks` with SSE live updates
- **Google Chat user guide**: `docs/guide/google-chat.md` — setup, GCP auth, request verification modes, DM/group access, troubleshooting
- **Tasks user guide**: `docs/guide/tasks.md` — task types, lifecycle, review workflow, coding tasks, scheduling integration, configuration
- **Guard audit configurable retention**: `guard_audit.max_entries` config (default 10000); registered in `ConfigMeta`
- **Task artifact disk reporting**: per-task `artifactDiskBytes` in task API responses; aggregate metric on health dashboard
- **Merge conflict UX**: task detail shows conflicting files list + resolution instructions when conflict artifact exists
- **Message tail-window loading**: `getMessagesTail()` + `getMessagesBefore()` APIs; initial chat/task-detail load returns last 200 messages; "Load earlier messages" button for backward pagination
- **Write queue backpressure**: `BoundedWriteQueue` caps pending writes at 1000; warning at 80% capacity; explicit overflow error (no silent drops)

### Security
- **Cookie `Secure` flag**: `auth.cookie_secure` config controls `Secure` attribute on session cookies; enables safe deployment behind TLS
- **Timing side-channel fix**: `constantTimeEquals` no longer leaks string length — pads shorter input to match longer before constant-time byte comparison
- **Auth rate limiting**: `AuthRateLimiter` returns 429 after 5 failed auth attempts per minute; `FailedAuthEvent` fired on all auth failure paths (gateway, login, webhook); successful auth resets counter
- **Auth trusted-proxy model**: `auth.trusted_proxies` config (list of IPs); `X-Forwarded-For` only accepted when connecting socket IP is in the trusted list; defaults to socket address for direct deployments
- **CommandGuard hardening**: broadened interpreter escape patterns to catch combined flag forms (`bash -lc`, `bash -xc`, `sh -lc`); third match path checks interpreter escapes and pipe targets against original command text before quote normalization; blocks `bash -lc 'rm -rf /'` and `cat script | 'bash -x'`

### Changed
- **MessageService cursor tracking**: in-memory `_lineCounts` map for O(1) cursor assignment on insert; one-time file scan on first access per session
- **KvService write-through cache**: reads served from in-memory cache after initial load; cache invalidated on write failure; atomic write pattern preserved
- **Shared `WriteOp`**: extracted from duplicated `_WriteOp` in `MessageService` and `KvService` to `write_op.dart` (internal, not public API)
- **DartclawServer fail-fast validation**: missing required runtime services for enabled features now throw `StateError` at handler build time

### Fixed
- **Task executor parallel dispatch**: pool-mode scheduling now dispatches across all compatible idle runners instead of waiting for one task to finish before starting the next
- **Task cancel propagation**: cancelling a running task now forwards cancellation to the active turn before returning the UI to the task list
- **Squash-merge conflict cleanup**: coding-task review no longer uses `git merge --abort` after `git merge --squash`; squash conflicts now restore state with a squash-safe reset path
- **Login fallback deep links**: browser auth redirects now preserve the requested route via `/login?next=...`, and successful manual sign-in returns to that route
- **Settings Google Chat status**: the settings page now receives live config context and can show configured Google Chat instances even when the channel is not connected
- **Task SSE bootstrap**: the client only opens `/api/tasks/events` when the shell actually renders task UI or the task badge
- **Task detail live refresh**: `/tasks/<id>` now transitions from draft to queued/running state without requiring a manual reload; task SSE refreshes target the active detail page and queued/running detail views use a scoped refresh fallback while a session is being attached
- **Queued task UX**: task detail pages show an explicit queued-state shell and more accurate no-session copy while waiting for a runner
- **Token deep-link bootstrap**: `?token=<valid>` sign-in now works on any GET route, not just `/`, and redirects back to the original path without the token while preserving other query params
- **WhatsApp sidecar adoption**: the server now adopts an already healthy external GOWA service instead of spawning into an occupied port and falling into a reconnect loop

### Tests
- Added regression coverage for parallel task dispatch, squash-vs-merge conflict cleanup, login `next` handling, settings Google Chat configured state, and the repaired dashboard route test harness
- Added task detail template coverage for queued-state rendering and made template tests workspace-root-safe
- Added auth middleware coverage for deep-link token bootstrap and query-param preservation
- Added `GowaManager` coverage for adopting an already healthy external service without spawning
- Added `auth_utils` unit tests for `constantTimeEquals`, `readBounded`, and `requestRemoteKey` trust-boundary cases (direct, trusted proxy, spoofed header)
- Added `AuthRateLimiter` unit tests (threshold, expiry, reset)
- Added `CommandGuard` regression tests for multi-word quoted wrapper bypasses and combined `-lc`/`-xc` flag forms

### Documentation
- Updated the UI smoke test to match the current System navigation and tabbed Settings editor
- Extended UI smoke coverage for `/tasks`, task detail progression, and `/memory`; corrected smoke-test numbering after the audit pass
- Closed the remaining 0.8 validation ledger gaps for empty-task and channel-enabled wireframes after live browser verification

---

## [0.7.0] — 2026-03-09

Session scoping, session maintenance, event bus infrastructure, channel DM access management.

### Added
- **Configurable session scoping** (S02): `SessionScopeConfig` model with `DmScope` (`shared`, `per-contact`, `per-channel-contact`) and `GroupScope` (`shared`, `per-member`) enums; parsed from `sessions:` block in `dartclaw.yaml`; per-channel overrides via `sessions.channels.<name>`; registered in `ConfigMeta` for API exposure
- **Session maintenance service** (S05): `SessionMaintenanceConfig` + `SessionMaintenanceService` — 4-stage pipeline (prune stale → count cap → cron retention → disk budget); `warn`/`enforce` mode; configurable thresholds for `prune_after_days`, `max_sessions`, `max_disk_mb`, `cron_retention_hours`; scheduled via internal cron job (default daily 3 AM)
- **CLI cleanup command** (S06): `dartclaw sessions cleanup` with `--dry-run` and `--enforce` flags; structured summary output (sessions archived, deleted, disk reclaimed)
- **Session scope settings UI** (S07): "Sessions" section on `/settings` with DM/group scope selectors and per-channel overrides; session scope section on channel detail pages (`/settings/channels/<type>`); restart-required banner for scope changes
- **Sidebar archive separation** (S08): collapsible "Archived" subsection with count badge; DM/Group channel subsections; `localStorage` persistence for collapse state
- **Auto-create group sessions** (S09): `GroupSessionInitializer` pre-creates sessions for allowlisted groups on startup and config changes via `EventBus`
- **EventBus** (S10): typed event bus using `StreamController.broadcast()`; sealed `DartclawEvent` hierarchy — `GuardBlockEvent`, `ConfigChangedEvent`, `SessionCreatedEvent`, `SessionEndedEvent`, `SessionErrorEvent`; wired as singleton in `service_wiring.dart`
- **Event bus migrations** (S11): guard audit logging, config change propagation, and session lifecycle all migrated from direct coupling to event bus subscribers
- **Unified DM access controller**: shared `DmAccessController` in `dartclaw_core/channel/`; Signal gains `pairing` mode; `DmAccessMode` enum (`open`, `disabled`, `allowlist`, `pairing`) shared across both channels; Signal allowlist accepts phone numbers and ACI UUIDs
- **Channel access config API**: `GET/PATCH /api/config` includes channel DM/group access fields; dedicated allowlist CRUD (`GET/POST/DELETE /api/config/channels/<type>/dm-allowlist`); live allowlist changes without restart
- **Channel access config UI**: `/settings/channels/whatsapp` and `/settings/channels/signal` detail pages; DM mode selector, allowlist editor, group mode selector, mention gating toggle; closes wireframe deviation #8
- **Pairing flow**: `createPairing()` for unknown senders in `pairing` mode; approval UI with Approve/Reject buttons, expiry countdown, HTMX polling; pairing management API endpoints; notification badge on channel cards

### Changed
- **SessionKey factory refactor** (S01): new factories `dmShared()`, `dmPerContact()`, `dmPerChannelContact()`, `groupShared()`, `groupPerMember()`; old overloaded `channelPeerSession()` removed; `webSession()` scope renamed from `main` to `web`
- **Group session fix** (S03): group messages now route to shared per-group session (was per-user-in-group — P0 bug); `ChannelManager.deriveSessionKey()` uses `SessionScopeConfig` and new factories
- **Signal sender normalization** (S04): `UUID ↔ phone` mapping via `signal-sender-map.json` prevents duplicate sessions from sealed-sender identity shifts; UUID-only messages resolve to cached phone; graceful degradation on missing/corrupt map

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

Initial actual release. Core agent runtime with security hardening.

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

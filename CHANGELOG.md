# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.13.0] — 2026-03-22

Multi-provider support — DartClaw can now run Claude Code and Codex (OpenAI) as interchangeable agent harnesses, with heterogeneous worker pools and per-task/per-session provider overrides.

### Added

#### Phase 1 — Foundation
- **Protocol adapter extraction + HarnessFactory** (S01): Extracted `ClaudeProtocolAdapter` from `ClaudeCodeHarness` behind a new `ProtocolAdapter` abstract interface; `HarnessFactory` instantiates harness implementations by provider identifier (`claude`, `codex`); `TurnRunner` and `HarnessPool` now use factory-based construction — zero direct `ClaudeCodeHarness` references remain
- **Canonical tool taxonomy** (S02): `CanonicalTool` enum (`shell`, `file_read`, `file_write`, `file_edit`, `web_fetch`, `mcp_call`) — provider-agnostic tool names; guards (`CommandGuard`, `FileGuard`, `NetworkGuard`) evaluate canonical names instead of raw provider strings; unmapped tools pass through with `provider:name` prefix and fail-closed on security-sensitive guards
- **Provider config + credential registry** (S03): `providers` config section with per-provider `executable`, `pool_size`, and extensible settings; `credentials` config section with environment variable resolution; `CredentialRegistry` extending existing `CredentialProxy` for multi-provider API key management; startup binary/credential validation (missing default provider = error, secondary = warning)

#### Phase 2 — Codex Core
- **CodexProtocol + CodexHarness MVP** (S04): `CodexProtocolAdapter` for `codex app-server`'s bidirectional JSON-RPC JSONL protocol — handles `initialize`/`initialized` handshake, `thread/start`, streaming notifications (`item/agentMessage/delta`, `turn/completed`, `turn/failed`); Codex events map to standard `BridgeEvent` types; `FakeCodexProcess` test double for unit testing without the real binary
- **CodexHarness turn lifecycle + environment** (S05): Thread-per-session management (first turn creates thread, subsequent turns reuse); message history replay from NDJSON store (Codex runs ephemeral — DartClaw owns continuity); system prompt injection via generated `config.toml` with `developer_instructions`; MCP server config pointing to DartClaw's `/mcp` endpoint; per-worker temp directory with `CODEX_HOME`
- **Guard chain integration + approval flow** (S06): Codex approval requests routed through DartClaw's `GuardChain` with canonical tool names — allow → tool executes, deny → tool blocked; Claude Code switched from `--permission-prompt-tool stdio` to `--dangerously-skip-permissions` (hooks still fire — no security regression, eliminates one IPC round-trip per tool call)

#### Phase 3 — Integration & Hardening
- **Crash recovery + capability declaration** (S07): Exponential backoff restart on process exit (matching `ClaudeCodeHarness` pattern); post-crash: new thread created, history replayed, session resumes; harness capability getters (`supportsCostReporting`, `supportsToolApproval`, `supportsStreaming`, `supportsCachedTokens`) for graceful degradation
- **Heterogeneous pool + provider overrides** (S08): Mixed Claude + Codex workers in `HarnessPool` based on per-provider `pool_size`; `tryAcquireForProvider()` routes to matching provider worker (rejects — never falls back to different provider); per-task provider override via `Task.provider` field; per-session provider override at creation time

#### Phase 4 — Polish & Completeness
- **Provider status API + settings page** (S09): `GET /api/providers` endpoint returning configured providers with binary version, credential status, pool size, and default flag; settings page "Providers" section with read-only status display and clear error states for missing binaries/credentials
- **Provider indicators + cost display** (S10): Provider badge in session sidebar, task list, and task detail page; provider-aware cost display — USD cost for Claude, token counts with "cost unavailable" tooltip for Codex; `cached_input_tokens` displayed when available
- **Exec-mode fallback + container support** (S11): Lightweight `CodexExecHarness` using `codex exec --json` for one-shot task execution — `--full-auto --ephemeral`, no approval chain; Dockerfile updated with both `claude` and `codex` binaries (multi-arch with `TARGETARCH` fallback); sandbox interaction matrix documented
- **Architecture docs + ADR finalization** (S12): ADR-016 status set to "Accepted"; ADR-007 addendum documenting Codex prompt injection approach; `system-architecture.md`, `control-protocol.md`, `security-architecture.md` updated for multi-provider; all marked "Current through 0.13"

### Changed

- **Guard evaluation**: All guards now operate on canonical tool names instead of raw provider-specific strings
- **Claude Code permission model**: Switched to `--dangerously-skip-permissions` — guard chain via hooks is the sole interception point (eliminates redundant `can_use_tool` handler)
- **`ProviderIdentity` normalization**: Centralized provider family mapping (`codex-exec` → `codex`) for consistent credential lookup, validation, and UI labeling across the codebase
- **Unmapped tool kind default**: `CodexProtocolAdapter.mapToolName()` maps unknown `file_change` kinds to `CanonicalTool.fileWrite` (fail-closed) instead of returning `null`; aligns exec-mode adapter with app-server adapter
- **`CredentialEntry.toString()`**: Redacts API key value to prevent accidental log exposure
- **Shared protocol utilities**: Extracted duplicated `_stringifyMessageContent` and `_mapValue` helpers into `codex_protocol_utils.dart`

---

## [0.12.0] — 2026-03-21

Crowd Coding — multi-user collaborative AI agent steering via messaging channels. A group of people in a Google Chat Space (or WhatsApp/Signal group) can collaboratively drive an AI agent to build an application.

### Added

#### Phase 0 — Codebase Hardening
- **DartclawServer builder refactor** (S01): Replaced two-phase construction (factory + `setRuntimeServices()`) with builder pattern; extracted route assembly into composable route groups; WhatsApp pairing routes extracted to dedicated file; `server.dart` reduced from 828 to ~400 LOC
- **Task event centralization + optimistic locking** (S02): `TaskStatusChangedEvent` fired from `TaskService.updateStatus()` only — removed duplicate firing from scattered callers; `version` column on tasks table with conflict detection on stale updates; harness spawned with `--setting-sources` constraints
- **ChannelTaskBridge extraction** (S03): Extracted task logic (trigger parsing, review dispatch, recipient resolution) from `ChannelManager` into dedicated `ChannelTaskBridge`; consolidated duplicate recipient resolution; `ChannelManager` reduced from 487 to ~200 LOC
- **ServiceWiring decomposition** (S04): Split `service_wiring.dart` (1,741 LOC) into domain-specific modules (`SecurityWiring`, `ChannelWiring`, `TaskWiring`, `SchedulingWiring`, `StorageWiring`) with thin coordinator; cleaned 73 `catch (_)` silent catches; removed `ignore_for_file: implementation_imports` from all files

#### Phase A — Sender Attribution & Identity
- **Sender attribution end-to-end** (S05): `Task.createdBy` field with sender identity extraction from channel messages; "Created by" display in task list and Google Chat Cards v2 notifications; sender prefix in task detail chat view

#### Phase B — Thread-Bound Task Sessions
- **ThreadBinding model + thread-aware routing** (S06): Channel-agnostic `ThreadBinding` model mapping `(channelType, threadId) → (taskId, sessionKey)`; bound-thread messages route to task sessions, unbound messages route to shared session; JSON persistence with atomic writes
- **Binding lifecycle + thread commands** (S07): Auto-unbind on terminal task states; idle timeout cleanup; thread commands (accept/reject/push back in bound threads without specifying task ID)

#### Phase C — Runtime Governance
- **Governance config + rate limiting** (S08): `GovernanceConfig` section; `SlidingWindowRateLimiter` — per-sender and global turn rate limiting (admin exempt); all governance features default disabled for backward compatibility
- **Token budget enforcement** (S09): Daily token budget via existing `UsageTracker`; warn mode at 80%, block mode at 100%; midnight reset; per-sender budget tracking
- **Loop detection** (S10): Three-mechanism `LoopDetector` — turn chain depth limit, token velocity tracking, tool fingerprinting (repeated tool call patterns); configurable thresholds, all default disabled

#### Phase D — Emergency Controls
- **Emergency stop** (S11): `/stop` slash command — aborts all in-flight turns, cancels running tasks, admin-only authorization
- **Pause/resume** (S12): `/pause` and `/resume` slash commands — queues messages in-memory during pause, structured per-sender concatenation drain on resume, partitioned by session

#### Phase F — Documentation
- **Crowd coding recipe** (S13): User-facing recipe at `docs/guide/recipes/08-crowd-coding.md` — end-to-end crowd coding setup guide

#### Phase G — Config Restructure
- **`features:` config namespace** (S14): Crowd coding and thread binding config moved under `features:` namespace; prepares for future plugin system (`plugins:` reserved for third-party)

### Changed

- **Architecture docs updated**: `system-architecture.md`, `security-architecture.md`, `data-model.md` updated for crowd coding; new `crowd-coding.md` architecture deep-dive; all marked "Current through 0.12"

---

## [0.11.0] — 2026-03-21

Google Chat Space full participation — DartClaw can now receive ALL messages in Google Chat Spaces without requiring @mention, using Google Workspace Events API + Cloud Pub/Sub.

### Added

#### Phase 1 — Foundation
- **Configuration model extension** (S01): `PubSubConfig` and `SpaceEventsConfig` nested config sections on `GoogleChatConfig`; `ConfigMeta` registration; cross-field validation (enabling space events requires Pub/Sub fields); all new sections default to disabled — fully backward compatible
- **Cloud Pub/Sub pull client** (S02): `PubSubClient` (401 LOC) — REST API v1 pull client with configurable poll interval, batch pull (up to 100 messages), immediate ack/nack, exponential backoff on transient errors (429, 5xx, max 32s), graceful shutdown (drain in-flight within 5s), health reporting (last pull timestamp, consecutive error count); zero new dependencies — direct REST via `GcpAuthService`

#### Phase 2 — Core Pipeline
- **Workspace Events subscription manager** (S03): `WorkspaceEventsManager` (591 LOC) — creates/renews/deletes Google Workspace Events API subscriptions; persists subscription metadata to JSON with atomic writes; proactive renewal at 75% of TTL (1-hour buffer on 4-hour default); startup reconciliation (renew active, recreate expired, prune orphaned); rate-limit aware
- **CloudEvent message adapter** (S04): `CloudEventAdapter` (300 LOC) — parses Pub/Sub CloudEvent payloads into `ChannelMessage` objects; handles `google.workspace.chat.message.v1.created` events; filters bot self-messages; batch processing support
- **Message deduplication** (S05): `MessageDeduplicator` (60 LOC) in `dartclaw_core` — bounded FIFO with configurable capacity (default 1000); first-seen-wins prevents double-processing when @mentioned messages arrive via both webhook and Pub/Sub paths

#### Phase 3 — Integration & Hardening
- **Space join/leave automation + API** (S06): `ADDED_TO_SPACE` webhook auto-subscribes via `WorkspaceEventsManager`; `REMOVED_FROM_SPACE` auto-unsubscribes; REST API endpoints (`GET/POST /api/google-chat/subscriptions`, `DELETE` with body-based `spaceId`) for manual operator control
- **Graceful degradation + health** (S07): `PubSubHealthReporter` tracks Pub/Sub status and surfaces it to health endpoint and dashboard; automatic fallback to webhook-only mode if Pub/Sub becomes unavailable; auto-recovery when connectivity restores

### Changed

- **Health dashboard**: Pub/Sub status section added — shows pull status, last pull timestamp, active subscription count, degradation warnings
- **`docs/guide/use-cases/`** renamed to **`docs/guide/recipes/`**

---

## [0.10.2] — 2026-03-19

Composed config model — decomposed `DartclawConfig` from a 72-field flat class into typed section classes.

### Changed

- **Typed config sections** (S01): 14 typed section classes extracted into `packages/dartclaw_core/lib/src/config/` — `ServerConfig`, `AgentConfig`, `AuthConfig`, `GatewayConfig`, `SessionConfig`, `ContextConfig`, `SecurityConfig`, `MemoryConfig`, `SearchConfig`, `TaskConfig`, `SchedulingConfig`, `WorkspaceConfig`, `LoggingConfig`, `UsageConfig`; each section owns its fields, defaults, and YAML parsing
- **Composed `DartclawConfig`** (S02): `DartclawConfig` rewritten from 72 flat fields to 16 composed section fields; section accessors replace top-level getters
- **Consumer migration** (S03): ~280 access sites across all packages migrated from flat-field access (`config.port`, `config.authToken`) to section-based access (`config.server.port`, `config.auth.token`)
- **Config pipeline updated** (S04): `ConfigSerializer` updated for section-based serialization and deserialization; `ConfigMeta`, `ConfigValidator`, and `ConfigWriter` unchanged (operate on flat YAML paths as before)

### Added

- **Extension config registration** (S05): `registerExtensionParser()` API for P7 custom config sections; typed `extension<T>()` lookup on `DartclawConfig`; enables third-party packages to register and retrieve their own config sections without modifying core

### Removed

- **Deprecated forwarding getters** (S06): all `@Deprecated` flat-field forwarding getters on `DartclawConfig` removed; `dart analyze` clean across all packages; 2,205 tests pass

---

## [0.10.1] — 2026-03-17

SDK architecture hardening before publish.

### Changed

- `dartclaw_core`: removed the config ↔ channel cycle by introducing a neutral `src/scoping/` module for channel config and session scope types, then removed the residual `channel ↔ scoping` edge by moving `ChannelType` to a neutral runtime module
- `dartclaw_core`: narrowed the public barrel while keeping it self-contained; types still referenced by exported public APIs remain available from `package:dartclaw_core/dartclaw_core.dart`, while deeper internals continue to require `package:dartclaw_core/src/...` imports
- `dartclaw_core`: `ChannelManager` now depends on `TaskCreator` / `TaskLister` callbacks instead of the concrete task service
- `dartclaw_server`: `TaskService` and `GoalService` now live here instead of `dartclaw_core`

### Fixed

- First-party packages and tests now compile and run cleanly against the narrowed core barrel
- Wrapper packages now re-export the core types their public APIs expose, so downstream consumers no longer need `dartclaw_core/src/...` imports for channel packages or `dartclaw_testing`
- Google Chat session-key test expectation updated to match the current default DM scope (`perChannelContact`)

## [0.10.0] — 2026-03-16

Design system overhaul, context management foundations, restricted session hardening.

### Added

#### Phase A — Design System Implementation
- **Token alignment** (S01): production `tokens.css` replaced with full design system spec — 7 surface levels (`pit` through `surface2`), hue-aware blue-violet tint shadows, snappy easing curve, `--transition-glow`, light theme semantic color alignment
- **Base, shell & animations** (S02): body diagonal gradient background, mobile sidebar `translateX` slide animation (replacing instant show/hide), sidebar scrim `<button>` with opacity transition, logo gradient text animation (accent→info→accent, 6s)
- **Container taxonomy** (S03): 4 well types (`.well`, `.well-deep`, `.well-content`, `.well-flush`) and 8 card types (default, sunken, elevated, active, panels, metric, tint, featured) with sub-elements, hover effects, and free nesting
- **Status indicators & gradient dividers** (S04): status dots with glow animations (live/error/warning/idle), restyled status badges (pill shape, semantic variants, muted), status pills with gradient fill, scanning bar (animated gradient sweep), gradient dividers (fade and center)
- **Accessibility & reduced motion** (S05): comprehensive `@media (prefers-reduced-motion: reduce)` disabling all animations and transitions; `.sr-only` utility; focus ring treatments on interactive elements; WCAG AA contrast verification for both themes
- **Template migration** (S06): all 18 Trellis templates migrated to new container taxonomy — health dashboard metrics → `.card-metric`, settings cards → card with `.card-header`, task items → `.card-tint-*`, chat code blocks → `.well-deep`; legacy class aliases removed

#### Phase B — Context Management Tier 1
- **Compact instructions** (S07): `# Compact instructions` section appended to system prompt via `BehaviorFileService.composeSystemPrompt()`; configurable via `context.compact_instructions` in `dartclaw.yaml`; included for long-running sessions (web, channel DM, long cron), skipped for short-lived sessions; "Context" section in settings UI
- **Exploration summaries** (S08): `ExplorationSummarizer` produces deterministic structural summaries for files exceeding `context.exploration_summary_threshold` (default 25K tokens); JSON/YAML → key-path + value-type schema; CSV/TSV → column names + row count + samples; source code → top-level declarations; silent fallback to `ResultTrimmer` head+tail for unrecognized types or parse failures
- **Context warning banner** (S09): `ContextMonitor.checkThreshold()` emits SSE `context_warning` event when context usage exceeds `context.warning_threshold` (default 80%); dismissable web UI banner; one-shot per session; per-session scope; `ConfigMeta` registered as live-mutable

#### Phase C — Restricted Session Hardening
- **Restricted session env flag** (S10): `CLAUDE_CODE_SIMPLE=1` passed to `claude` binary for restricted container sessions; disables MCP server loading, hook execution, and CLAUDE.md file loading; workspace and direct sessions unaffected

### Changed
- **Design system tokens**: all CSS custom properties now follow the full design system spec palette; shadows use `rgba(9,9,26,...)` hue-aware tints instead of plain black
- **Sidebar interaction model**: mobile sidebar uses CSS transform transitions instead of JS display toggle; scrim is a semantic `<button>` element driven by CSS combinators
- **Status dot class names**: old `.status-dot.active` / `.status-dot.error` patterns replaced with BEM-style `.status-dot--live` / `.status-dot--error` modifiers (no aliases)

### Fixed
- TD-038: context window usage warning now surfaces to user before session becomes unresponsive

## [0.9.1] — 2026-03-16

Scheduling unification, model/effort overrides, config consistency fixes.

### Added

- **Unified scheduling** (F01): `scheduling.jobs` now supports both `prompt` and `task` job types via a `type` field; `automation.scheduled_tasks` is a deprecated alias — existing configs are converted automatically with a deprecation warning
- **Per-job model/effort overrides** (F02): prompt jobs support `model` and `effort` fields; `ScheduleService` passes overrides to turn dispatch so individual cron jobs can run on a different model or effort level than the global default
- **Per-task overrides** (F03): `ScheduledTaskDefinition` accepts `model`, `effort`, and `token_budget` fields; `ScheduledTaskRunner` merges these into task creation config
- **`agent.effort` config field**: per-agent effort level (`low`, `medium`, `high`, `max`); propagated through `HarnessConfig` to the `--effort` flag on harness spawn
- **Bare model aliases**: `opus`, `sonnet`, `haiku`, and context-window suffixes (`opus[1m]`) accepted as `model` values throughout config; mapped to full model IDs at harness spawn
- **`ScheduledJobType` enum**: `ScheduledJob.fromConfig()` factory with unified `prompt`/`task` branching; task jobs carry a resolved `ScheduledTaskDefinition` instead of a prompt string
- **Missing `ConfigMeta` fields registered**: `search.qmd.host`, `search.qmd.port`, `search.default_depth`, `logging.file`, `logging.redact_patterns`

### Changed

- **Session scope default**: `SessionScopeConfig.defaults()` now uses `DmScope.perChannelContact` (was `DmScope.perContact`); each channel gets its own DM session per contact
- **Agent tool defaults**: non-search agents with no `tools` configured now default to an empty allowlist and log a startup warning; search agents (`id: search`) continue to default to `[WebSearch, WebFetch]`
- **`agent.effort` is now a constrained enum** in `ConfigMeta` (`low`, `medium`, `high`, `max`); the settings UI renders it as a select instead of a free-text input
- **Settings memory field corrected**: `memory_max_bytes` form field renamed to `memory.max_bytes` to match `ConfigMeta` and the config API JSON shape
- **Task CRUD API unified**: `/api/scheduling/tasks` POST/PUT/DELETE now read and write `scheduling.jobs` (type=task entries) instead of the deprecated `automation.scheduled_tasks` path; task jobs created or edited through the web UI are stored under the canonical schema
- **`delivery` not required for task jobs**: `POST /api/scheduling/jobs` with `type: task` no longer requires a `delivery` field
- **Job lookup by `id` or `name`**: job CRUD routes (`PUT`/`DELETE /api/scheduling/jobs/<id>`) resolve jobs by either the `id` or `name` field, consistent with how docs-authored configs use `id:`
- **Scope YAML normalization**: `DmScope` and `GroupScope` now accept both snake_case and kebab-case in YAML; values are normalized to kebab-case on parse

### Fixed

- **`configJson.budget` deprecation warning**: `TaskExecutor` logs a deprecation warning when a task config uses the old `budget` key; use `tokenBudget` instead
- `memory_max_bytes` removed from `ConfigMeta` (superseded by `memory.max_bytes` since 0.6); submitting the old key via config API now returns a validation error instead of silently writing an unknown field

### Removed

- `context_1m` model alias removed from config parser (use `opus[1m]` or `sonnet[1m]`)

## [0.9.0] — 2026-03-15

Package decomposition, SDK publish-readiness, channel-to-task integration, Google Chat enhancements, cookbook audit fixes.

### Added

#### Phase A — Package Decomposition
- **Channel config decoupling** (S01): `ChannelConfigProvider` interface; `TextChunker`, `MentionGating`, `ChannelConfig` moved to core channel base; channel-specific configs isolated from core config barrel
- **`dartclaw_security` package** (S02): guard framework extracted from core (~1,936 LOC); `Guard`, `GuardContext`, `GuardVerdict`, `GuardChain`, all concrete guards, `GuardAuditSubscriber`; callback-based decoupling for event firing (wired at server layer); zero dependency on core
- **`dartclaw_whatsapp` package** (S03): WhatsApp channel extracted from core (~1,078 LOC); `WhatsAppChannel`, `WhatsAppConfig`, `GowaManager`, response formatter, media extractor
- **`dartclaw_signal` package** (S04): Signal channel extracted from core (~1,000 LOC); `SignalChannel`, `SignalConfig`, `SignalCliManager`, `SignalSenderMap`, `SignalDmAccess`
- **`dartclaw_google_chat` package** (S05): Google Chat channel extracted from core (~595 LOC); `GoogleChatChannel`, `GoogleChatConfig`, `GcpAuthService`, `GoogleChatRestClient`; removes `googleapis_auth` from core's transitive dependency graph
- **Leaf services moved to server** (S06): `BehaviorFileService`, `HeartbeatScheduler`, `SelfImprovementService`, `WorkspaceService`, `WorkspaceGitSync`, `SessionMaintenanceService`, `UsageTracker` moved from core to server (~1,278 LOC); core reduced to ≤8,000 LOC
- **`dartclaw_config` package** (S09): config subsystem extracted from server (~1,335 LOC); `ConfigMeta`, `ConfigValidator`, `ConfigWriter`, `ScopeReconciler`; usable from both server and CLI
- **`dartclaw_testing` package** (S09): test doubles for SDK consumers; `FakeAgentHarness`, `InMemorySessionService`, `InMemoryTaskRepository`, `FakeChannel`, `FakeGuard`, `TestEventBus`, `FakeProcess`; example test in package
- **Extension APIs** (S09): `server.registerGuard()`, `server.registerChannel()`, `server.onEvent<T>()` — power user hooks callable before `server.start()`; documented in umbrella README

#### Phase B — SDK Publish-Readiness
- **Package metadata** (S10): MIT LICENSE added to all packages; `repository`, `homepage`, `issue_tracker`, `topics` in all pubspecs; lock-step versioning strategy; per-package CHANGELOGs with 0.9.0 entries
- **Package READMEs** (S11): focused READMEs for all packages (purpose, installation, minimal usage, API reference link); umbrella README rewritten as pub.dev landing page with architecture overview, quick start, package choice table; server + CLI framed as reference implementations
- **Doc comments + pana** (S12): `///` doc comments on all barrel-exported symbols (~50); expanded doc comments on data model classes; `example/` directories with recognized entrypoints; pana validation on zero-dependency packages

#### Phase C — SDK Documentation
- **SDK documentation** (S13): Quick Start guide (`docs/sdk/quick-start.md`) — minimal working agent in <30 lines; Package Choice Guide (`docs/sdk/packages.md`) — decision tree for consumer profiles; `single_turn_cli` runnable example project; repo README with dual-track navigation (User Guide + SDK Guide)

#### Phase D — Channel-to-Task Integration
- **Task trigger config** (S14): per-channel `task_trigger` section in `dartclaw.yaml` (enabled, prefix, default_type, auto_start); `ConfigMeta` registration; trigger parser (prefix-based, case-insensitive, start-of-message only); config API and settings UI toggles
- **Channel→task bridge + notifications** (S15): task trigger messages intercepted in `ChannelManager` before `MessageQueue`; task created via `TaskService.create()` with expanded `TaskOrigin` (recipientId, channelType, contactId); acknowledgment sent to originating channel; `TaskLifecycleEvent` notifications routed to originating channel only; best-effort delivery with logged failures
- **Review-from-channel** (S16): accept/reject tasks via channel message; exact-match parsing ("accept"/"reject" with optional task ID); shared `TaskReviewService` extracted from HTTP route handler; disambiguation prompt for multiple tasks in review; merge conflict → "Review in web UI" fallback

#### Phase E — Google Chat Enhancements
- **Google Chat Cards v2** (S17): `ChatCardBuilder` in `dartclaw_google_chat`; task notification cards (title, status badge, description, Accept/Reject buttons); `CARD_CLICKED` webhook handling; button payloads use flat `Map<String, String>` parameters; plain text fallback; card description truncation at ~2,000 chars
- **Google Chat slash commands** (S18): `/new [<type>:] <description>` → create task, `/reset` → archive session, `/status` → show active tasks/sessions; compatibility parser for both `MESSAGE+slashCommand` and `APP_COMMAND` event shapes; Cards v2 responses

#### Cookbook Audit Fixes
- **Announce delivery** (S19): `DeliveryService` class replaces standalone `deliverResult()` stub; cron job results broadcast to connected SSE web clients + active DM contacts on all registered channels; best-effort channel delivery with per-target error handling; deprecated `deliverResult()` retained for backward compat
- **Memory consolidator extraction** (S19): `MemoryConsolidator` extracted from `HeartbeatScheduler`; shared between heartbeat and `ScheduleService`; post-cron consolidation runs after successful jobs when MEMORY.md exceeds threshold
- **Memory config unification** (S19): `memory.max_bytes` as canonical nested key; backward-compatible fallback to top-level `memory_max_bytes` with deprecation warning; CLI override support for `memory.pruning.*` fields
- **Contact identifier documentation** (S19): WhatsApp JID format (`<phone>@s.whatsapp.net`, `<group-id>@g.us`) documented in `whatsapp.md`; Google Chat resource names (`users/<id>`, `spaces/<id>`) documented in `google-chat.md`

#### Recipes
- **Personal Assistant composite guide**: `docs/guide/recipes/00-personal-assistant.md` — turnkey setup combining morning briefing, knowledge inbox, daily journal, nightly reflection; "Day in the Life" 24-hour walkthrough; complete `dartclaw.yaml` + behavior files; step-by-step getting started
- **Troubleshooting guide**: `docs/guide/recipes/_troubleshooting.md` — common issues for scheduled jobs, memory, git sync, channels, cost optimization
- **Common patterns expanded**: heartbeat vs cron comparison table; monitoring guide (dashboards, logs, agent metrics); concrete SOUL.md example; session maintenance reference; channel-to-task integration guide

### Changed
- **Umbrella re-exports**: `dartclaw` umbrella now re-exports core + security + all channel packages; individual package imports work independently
- **Package DAG**: `dartclaw_core` reduced from ~12,500 LOC to ≤8,000 LOC; zero circular dependencies between extracted packages
- **Config guide updated**: unified Memory section with `memory.max_bytes` (preferred) and `memory_max_bytes` (deprecated alias); `memory.pruning.*` documented
- **Use-case guides updated to 0.9**: all 7 guides audited for config accuracy; `guards.content_guard` → `guards.content`; multi-channel references (WhatsApp/Signal/Google Chat); session scoping and maintenance config; task system and task triggers; announce delivery status noted
- **Example configs updated**: `personal-assistant.yaml` expanded with sessions, maintenance, content guard, input sanitizer, multi-channel comments, task triggers; `production.yaml` model references simplified

### Fixed
- **`announce` delivery stub**: `delivery: announce` was a no-op since 0.2 — now routes results to SSE clients and channel DM contacts
- **Memory consolidation gap**: consolidation only ran during heartbeat; now also runs after successful cron jobs via shared `MemoryConsolidator`
- **`memory_max_bytes` schema inconsistency**: related memory settings split across top-level and nested config; unified under `memory:` section with backward compat
- **Use-case guide `content_guard` references**: guides 04 and 05 used renamed config key `content_guard` instead of `content`
- **Internal session keys exposed in guides**: removed `agent:main:cron:<jobId>:<ISO8601>` format from user-facing workflow descriptions

### Documentation
- **Architecture docs**: `system-architecture.md` updated with new package DAG; `security-architecture.md` updated for `dartclaw_security` package extraction
- **SDK docs**: Quick Start, Package Choice Guide, runnable example project
- **Channel guides**: WhatsApp JID format, Google Chat resource name format, contact identifier sections
- **Configuration guide**: Memory section with `max_bytes` + `pruning`; deprecated `memory_max_bytes` documented
- **Use-case cookbook**: 2 new guides (composite PA, troubleshooting); 9 existing guides updated for 0.9 accuracy

---

## [0.8.0] — 2026-03-08

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
- **Guard audit configurable retention**: `guard_audit.max_retention_days` config (default 30); date-partitioned audit files with scheduled retention cleanup
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

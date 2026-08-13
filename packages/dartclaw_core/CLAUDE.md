# Package Rules — `dartclaw_core`

**Role**: sqlite3-free runtime primitives — `AgentHarness`/`ClaudeCodeHarness`/`CodexHarness`/`AcpHarness`, `Channel`/`ChannelManager`/`ChannelTaskBridge`, shared standard-Markdown/native-chat conversion and chunking, `BridgeEvent` and `DartclawEvent`/`EventBus`, file-backed `SessionService`/`MessageService`/`KvService`, `TaskEvent`/`TaskEventKind`, `TurnTrace`/`TurnTraceSummary`/`ToolCallRecord`, task/goal/execution repository **interfaces**.

## Architecture
- **Harness layer** — provider abstraction. `AgentHarness` (interface; turns carry optional logical-agent identity and an authoritative non-empty scoped system prompt), `ClaudeCodeHarness` (Bun standalone binary), `CodexHarness` (Rust static binary), `AcpHarness` (Agent Client Protocol — stdio JSON-RPC agents via `acp_client.dart`/`acp_protocol_adapter.dart`), `HarnessFactory` (construction + capability probes). Provider-native agent definitions are not part of this boundary; host-dispatched session tools own logical-agent conversations uniformly.
- **Protocol layer** — wire-format adapters between harnesses and the host. `ProtocolAdapter` (interface), `ClaudeProtocolAdapter` (JSONL stream + tool-name normalization to canonical taxonomy), `CodexProtocolAdapter` (JSON-RPC + approval round-trip).
- **Channel layer** — inbound message routing scaffolding plus shared standard-Markdown/native-chat conversion and Unicode-safe/native-markup chunking. `Channel` (interface; concrete impls in `dartclaw_*` channel packages), `ChannelManager` (per-channel ownership via `ownsJid`), `ChannelTaskBridge` (binding → rate limit → review → trigger → fall-through policy).
- **Event bus** — `EventBus` (broadcast, fire-and-forget); `BridgeEvent` (sealed; protocol-stream signals from harnesses); `DartclawEvent` (sealed; app-semantics events surfaced to subscribers).
- **File-backed services** — workspace-state primitives. `SessionService`, `MessageService` (1-based cursor over `messages.ndjson`), `KvService` (atomic JSON via `atomicWriteJson`). `MemoryCorpusService` owns the authenticated member manifest, bounded path/record selectors, sparse compare-and-swap mutation, fingerprint reconciliation, crash recovery, and persisted operator status. Snapshot omission is decided from authenticated metadata before a whole document read; startup adoption/reconciliation may scan successive bounded body batches, while ordinary requests never load the full aggregate corpus.
- **Logical-agent conversations** — `LogicalAgentSessionService` separates creation (`sessions_spawn`: agent + initial message) from continuation (`sessions_send`: returned session handle + follow-up), while enforcing the content-guard boundary around each result. Provider/profile worker acquisition and bounded lease capacity are host-owned in `dartclaw_server`; core owns no pool or concurrency policy.
- **Repository contracts** — interface-only persistence ports: `TaskRepository`, `GoalRepository`, `AgentExecutionRepository`, `WorkflowStepExecutionRepository`. Concrete SQLite impls live in `dartclaw_storage`.
- **Cross-cutting** — `RepoLock` (per-path process mutex for shared mutations), `atomicWriteJson` (the only sanctioned JSON write path), `httpRequest` (`src/util/http_request.dart`; shared one-shot `HttpClient` lifecycle returning `(statusCode, body)` — owns create→open→headers→write→close→utf8-decode→`close(force:true)`, does not interpret status; only for callers that read the full utf8 body and need no response headers/streaming).

## Shape
- **Harness**: `HarnessFactory.create` → `start()` (spawns provider binary) → `runTurn(...)` (writes stdin, reads stdout via `ProtocolAdapter`) → `resetSessionContinuity(sessionId)` when a DartClaw session reset must drop provider-side conversation state → `stop()`. Claude restarts when a reused worker changes logical sessions; ACP creates a fresh provider session and injects bounded persisted history. All mutating ops serialized via `_withLock()`; spawn-generation counter discards stale exit handlers.
- **Inbound channel**: `Channel.handleWebhook(payload)` → `ChannelManager` (`ownsJid` ownership check) → `ChannelTaskBridge` (binding → rate limit → review → trigger → fall-through) → `MessageQueue`, which brackets dispatched turns with three-second best-effort channel typing lifecycle hooks.
- **Events**: producers fire on `EventBus`; `BridgeEvent` carries protocol-stream signals, `DartclawEvent` carries app semantics — both broadcast, fire-and-forget.

## Boundaries
- **Never** add `package:sqlite3` to `pubspec.yaml`. Enforced by `dev/tools/arch_check.dart` (check #2). Concrete SQLite repos belong in `dartclaw_storage`; if you need a new persisted entity, define the interface here (e.g. `TaskRepository` in `src/task/`) and the SQLite impl in `dartclaw_storage`.
- Allowed deps: `dartclaw_models`, `dartclaw_security`, `dartclaw_config`, plus `stream_channel`, `json_rpc_2`, `uuid`, `collection`, `logging`, `meta`, `path`. Do **not** import `dartclaw_storage`, `dartclaw_workflow`, or `dartclaw_server`.
- LOC ceiling: 21 050 (arch_check core-LOC check; warn at 20 700). Barrel ceiling: 110 exports. Prefer adding to existing files / sub-barrels over new top-level exports.
- Never import another workspace package's `lib/src/` (arch_check #3). The exception clause in the barrel for `parseMemoryEntries`/`memoryTimestampRe` is documented and finite — do not extend it.

## Conventions

- Memory safety ceilings live in `MemoryResourceLimits`: 64 MiB per source, 8 MiB per observation partition, and
  1,000 files/64 MiB body bytes per recursive request. Partition overflow rejects without trimming existing records.
- Atomic JSON writes go through `src/storage/atomic_write.dart::atomicWriteJson` — temp file + rename with random suffix. Writers to shared `.git/` or `.session_keys.json` must hold `RepoLock` first.
- Canonical memory writers delegate workspace serialization to `MemoryCorpusService`; sparse writers select exact paths or record owners and preserve unopened members from the authenticated manifest. Post-commit projection failure cannot roll canonical state back. External editors must stop DartClaw or coordinate separately.
- Canonical index entries persist non-negative prompt priority. Rebuilds preserve existing priority and prompt selection orders priority, recency, then stable ID.
- The storage-owned legacy migrator uses `MemoryCorpusService.updateFiles(prepareLegacyCanonical:)` so preview bytes become one revision-1 canonical commit under the same lock and recovery journal.
- Events: define new types in `src/events/<group>_events.dart`, then add to the sealed-export list in `src/events/dartclaw_event.dart` AND to the explicit `show` clause in the barrel. The list in the barrel is hand-maintained — missing exports break server wiring silently.
- `BridgeEvent` (provider-facing) and `DartclawEvent` (app-facing) are distinct sealed hierarchies. Don't blur them — `BridgeEvent` only carries protocol-stream signals; rich semantics live on `DartclawEvent`.
- Harness lifecycle: mutating ops (`start`/`stop`/`restartForExecution`) must be serialized via `_withLock()` future chaining; the spawn-generation counter guards against stale exit handlers.
- `HarnessFactory` is the construction seam — to probe capabilities without spawning, pass `cwd: '/'` per the documented convention in `HarnessFactoryConfig`.
- `provider_execution_compatibility.dart` owns the launch-compatibility vocabulary both surfaces consume: `ProviderLaunchSurface`, `ProviderExecutionVerdict`, `ProviderExecutionSupport`, and the startup `ProviderExecutionInventory`. The type lives here so it carries no CLI dependency; composition roots populate it. Compute compatibility there and consume the verdict — never re-derive "can this provider run here" at a call site.
- Guards: `dartclaw_security` owns evaluation; this package wires verdicts to the EventBus only via `dartclaw_server` (don't fire `GuardBlockEvent` directly from harness code).

## Gotchas
- `EventBus.fire` is fire-and-forget with broadcast semantics — events with no subscriber are dropped. Don't use it for required handoffs.
- The barrel's `show` clauses are exhaustive and authoritative; adding a class to a `src/` file does **not** export it. Many "missing class" errors elsewhere trace here.
- Protocol adapters normalize provider tool names to the canonical taxonomy (`shell`/`file_read`/`file_write`/`file_edit`/`web_fetch`/`web_search`/`memory_apply`/`memory_observe`/`memory_search`/`memory_read`/`sessions_spawn`/`sessions_send`/`mcp_call`) **before** guard evaluation. Exact registered own-MCP tools use semantic canonicals; other MCP calls stay `mcp_call`. Preserve `rawProviderToolName` on `GuardContext` for audit and policy-entry compatibility.
- Harness turns must bind `agentId` for their full active lifetime and clear it in `finally`; asynchronous hook, approval, and reverse-call dispatch must snapshot that identity with the session.
- A non-empty `AgentHarness.turn.systemPrompt` is authoritative; empty selects the configured default. Claude folds append-prompt/model/effort changes into one restart, restarts on logical-session switches, and restores defaults on the next empty turn. Codex replaces only the affected session thread when `developerInstructions` change; ACP prepends the prompt and bounded replay history at message level.
- Every `AgentHarness` implementation must report `isRootProcessTerminationConfirmed` explicitly. Process-owning harnesses return runtime ownership state; processless implementations return `true`. Unknown termination state must fail closed so replacement cannot overlap an unconfirmed root process.
- Direct Claude spawns inherit user-scope Claude settings by default. Only pass `--setting-sources project` when `providers.claude.inherit_user_settings: false`; containerized spawns stay flag-free because the container is the isolation boundary.
- `ContainerExecutor` carries the container's mediation seams, not just its exec surface: `providerBridgeUrl`/`mcpBridgeUrl` are the only endpoints a containerized client may be pointed at (a null MCP URL means the authority was granted no tools, so configure none), and `generatedStateDir` is the per-authority host directory bind-mounted for generated client configuration. Both harnesses write their generated config there; it is destroyed with the container. Never write container config to the project tree or `docker cp` it in.
- `registerAcpAgent` never silently drops a container manager. ACP has no mediated container execution, so a supplied manager fails closed and a `container_isolation_required` registration fails closed without one — both paths throw rather than letting the process land on the host with a discarded boundary. `AcpHarness.containerManager` still exists and is still tested directly, but no factory path can supply it.
- Containerized spawns pass **no host environment**. Claude gets `claudeContainerHardeningEnvVars` (the hardening set with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0` — the scrub is moot inside the boundary and the current CLI reads `=1` as requiring bubblewrap, which cannot run under the container hardening; plus `CLAUDE_CODE_SIMPLE` when restricted); Codex gets only `CODEX_HOME`. The provider credential, host login state, and shared operator MCP bearer must never cross – a bearer in a container MCP config is a defect, not a convenience.
- `CodexEnvironment` has three lifecycles and they must stay distinct: system home, isolated **seeded** home, and `containerAuthClean`. The container one must never call authentication seeding – a logged-in Codex forwards its saved bearer to a custom provider even with `requires_openai_auth = false`, so only a never-seeded home is safe.
- Containerized spawns must translate every host path that crosses the boundary – **including the spawn working directory on `start()` before any turn** (Claude resolves it via `containerPathForHostPath` with a profile-workingDir fallback; Codex does the same). And containerized Codex always spawns `danger-full-access`: its own sandbox tooling cannot start under the hardening and fails every tool call while the turn still reports success (security-architecture § Multi-Provider Sandbox Interaction).
- Container harnesses probe their packaged CLI with `containerExecutableRuns` before spawning, so an image missing a runnable binary rejects at admission instead of surfacing as a dead pipe mid-turn.
- Claude `PreToolUse` registration stays unfiltered so built-ins and dynamically named MCP tools all reach the guard chain; never replace it with a static tool-name list.
- Claude `PreCompact` acknowledgement awaits the host observer so required state capture settles first; observer failure is logged and acknowledged to avoid blocking provider compaction.
- Claude may defer allowlisted tools behind `ToolSearch`. Permit only the exact `claude:ToolSearch`/`ToolSearch` discovery pair after deny checks; the selected tool still requires its own allowlist match.
- Codex approval round-trip is the only guard interception point for the Codex provider. Preserve current command/file request methods, MCP approval elicitations, response-specific result shapes, and camelCase item types; legacy aliases remain accepted. Explicit `on-request` is the broadest available host interception; omitted options inherit Codex configuration, `unless-allow-listed` is partial, and `never` produces no host guard event. String provider options are trimmed before process and request use.
- File-backed `MessageService` uses 1-based line cursors in `messages.ndjson`; cursor is assigned on read, never persisted in the JSON line itself.

## Testing
- Layout mirrors `lib/src/` (e.g. `test/harness/`, `test/channel/`). Barrel surface is locked by `test/barrel_export_test.dart` — update it when you legitimately change the public API.
- `integration` tag is skipped by default (live API creds); `dart test` runs unit + contract. Integration runs via `dart test --run-skipped -t integration packages/dartclaw_core`.
- Shared fakes live in `dartclaw_testing` (`fake_agent_harness.dart`, `fake_codex_process.dart`, `fake_channel.dart`, `in_memory_session_service.dart`, etc.) — reuse them, do not re-roll.
- Harness-test fakes that wrap `dartclaw_security` types (not barrel-eligible) live in `test/harness/harness_test_support.dart` (e.g. `RecordingGuard`, a capture-only `Guard` with `contexts`/`lastContext` and a configurable verdict) — reuse there.
- Async harness loops: never use `(_) async {}` polling without yielding to the timer queue (microtask starvation causes multi-GB leaks; see `dev/state/LEARNINGS.md`).

## Key files
- `lib/dartclaw_core.dart` — barrel; authoritative public API.
- `lib/src/harness/claude_code_harness.dart`, `codex_harness.dart` — provider harnesses.
- `lib/src/harness/harness_factory.dart` — construction + capability probes.
- `lib/src/bridge/bridge_events.dart` — sealed `BridgeEvent` hierarchy.
- `lib/src/events/dartclaw_event.dart` + `event_bus.dart` — sealed event taxonomy + bus.
- `lib/src/channel/channel_task_bridge.dart` — inbound routing precedence (binding → rate limit → review → trigger → fall-through).
- `lib/src/channel/standard_markdown_converter.dart` — shared standard-Markdown → native-chat conversion with platform link rendering.
- `lib/src/channel/text_chunking.dart` — bounded Unicode-safe text and native chat-markup chunking.
- `lib/src/storage/atomic_write.dart` — the only sanctioned JSON write path.
- `lib/src/memory/canonical_memory.dart`, `memory_markdown_codec.dart`, `memory_corpus.dart`, `memory_corpus_service.dart` plus its authority/manifest/scanner parts — canonical values, pure serialization, authenticated inventory, bounded selection, sparse mutation, and recovery.
- `lib/src/turn/turn_trace.dart`, `lib/src/turn/tool_call_record.dart` — turn execution telemetry types.
- `lib/src/task/task_event.dart` — `TaskEvent` sealed hierarchy + `TaskEventKind` enum.

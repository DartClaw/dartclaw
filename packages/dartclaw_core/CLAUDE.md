# Package Rules — `dartclaw_core`

**Role**: sqlite3-free runtime primitives — `AgentHarness`/`ClaudeCodeHarness`/`CodexHarness`, `Channel`/`ChannelManager`/`ChannelTaskBridge`, `BridgeEvent` and `DartclawEvent`/`EventBus`, file-backed `SessionService`/`MessageService`/`KvService`, `LoopDetector`, `SlidingWindowRateLimiter`, abstract `SearchBackend`, task/goal/execution repository **interfaces**.

## Architecture
- **Harness layer** — provider abstraction. `AgentHarness` (interface), `ClaudeCodeHarness` (Bun standalone binary), `CodexHarness` (Rust static binary), `HarnessFactory` (construction + capability probes).
- **Protocol layer** — wire-format adapters between harnesses and the host. `ProtocolAdapter` (interface), `ClaudeProtocolAdapter` (JSONL stream + tool-name normalization to canonical taxonomy), `CodexProtocolAdapter` (JSON-RPC + approval round-trip).
- **Channel layer** — inbound message routing scaffolding. `Channel` (interface; concrete impls in `dartclaw_*` channel packages), `ChannelManager` (per-channel ownership via `ownsJid`), `ChannelTaskBridge` (binding → rate limit → review → trigger → fall-through policy).
- **Event bus** — `EventBus` (broadcast, fire-and-forget); `BridgeEvent` (sealed; protocol-stream signals from harnesses); `DartclawEvent` (sealed; app-semantics events surfaced to subscribers).
- **File-backed services** — workspace-state primitives. `SessionService`, `MessageService` (1-based cursor over `messages.ndjson`), `KvService` (atomic JSON via `atomicWriteJson`).
- **Repository contracts** — interface-only persistence ports: `TaskRepository`, `GoalRepository`, `AgentExecutionRepository`, `WorkflowStepExecutionRepository`, `SearchBackend`. Concrete SQLite impls live in `dartclaw_storage`.
- **Cross-cutting** — `LoopDetector`, `SlidingWindowRateLimiter`, `RepoLock` (advisory file lock for shared `.git/` writes), `atomicWriteJson` (the only sanctioned JSON write path).

## Shape
- **Harness**: `HarnessFactory.create` → `start()` (spawns provider binary) → `runTurn(...)` (writes stdin, reads stdout via `ProtocolAdapter`) → `stop()`. All mutating ops serialized via `_withLock()`; spawn-generation counter discards stale exit handlers.
- **Inbound channel**: `Channel.handleWebhook(payload)` → `ChannelManager` (`ownsJid` ownership check) → `ChannelTaskBridge` (binding → rate limit → review → trigger → fall-through) → task or session.
- **Events**: producers fire on `EventBus`; `BridgeEvent` carries protocol-stream signals, `DartclawEvent` carries app semantics — both broadcast, fire-and-forget.

## Boundaries
- **Never** add `package:sqlite3` to `pubspec.yaml`. Enforced by `dev/tools/arch_check.dart` (check #2). Concrete SQLite repos belong in `dartclaw_storage`; if you need a new persisted entity, define the interface here (e.g. `TaskRepository` in `src/task/`) and the SQLite impl in `dartclaw_storage`.
- Allowed deps: `dartclaw_models`, `dartclaw_security`, `dartclaw_config`, plus `stream_channel`, `uuid`, `collection`, `logging`, `meta`, `path`. Do **not** import `dartclaw_storage`, `dartclaw_workflow`, or `dartclaw_server`.
- LOC ceiling: 13 000 (arch_check check #4). Barrel ceiling: 80 exports. Prefer adding to existing files over new top-level exports.
- Never import another workspace package's `lib/src/` (arch_check #3). The exception clause in the barrel for `parseMemoryEntries`/`memoryTimestampRe` is documented and finite — do not extend it.

## Conventions
- Atomic JSON writes go through `src/storage/atomic_write.dart::atomicWriteJson` — temp file + rename with random suffix. Writers to shared `.git/` or `.session_keys.json` must hold `RepoLock` first.
- Events: define new types in `src/events/<group>_events.dart`, then add to the sealed-export list in `src/events/dartclaw_event.dart` AND to the explicit `show` clause in the barrel. The list in the barrel is hand-maintained — missing exports break server wiring silently.
- `BridgeEvent` (provider-facing) and `DartclawEvent` (app-facing) are distinct sealed hierarchies. Don't blur them — `BridgeEvent` only carries protocol-stream signals; rich semantics live on `DartclawEvent`.
- Harness lifecycle: mutating ops (`start`/`stop`/`restartForExecution`) must be serialized via `_withLock()` future chaining; the spawn-generation counter guards against stale exit handlers.
- `HarnessFactory` is the construction seam — to probe capabilities without spawning, pass `cwd: '/'` per the documented convention in `HarnessFactoryConfig`.
- Guards: `dartclaw_security` owns evaluation; this package wires verdicts to the EventBus only via `dartclaw_server` (don't fire `GuardBlockEvent` directly from harness code).

## Gotchas
- `EventBus.fire` is fire-and-forget with broadcast semantics — events with no subscriber are dropped. Don't use it for required handoffs.
- The barrel's `show` clauses are exhaustive and authoritative; adding a class to a `src/` file does **not** export it. Many "missing class" errors elsewhere trace here.
- `ClaudeProtocolAdapter` normalizes provider tool names to the canonical taxonomy (`shell`/`file_read`/`file_write`/`file_edit`/`web_fetch`/`mcp_call`) **before** guard evaluation — preserve `rawProviderToolName` on `GuardContext` for audit, but route policy by canonical.
- Codex approval round-trip is the ONLY guard interception point for the Codex provider — never spawn `codex` with `--yolo`.
- File-backed `MessageService` uses 1-based line cursors in `messages.ndjson`; cursor is assigned on read, never persisted in the JSON line itself.

## Testing
- Layout mirrors `lib/src/` (e.g. `test/harness/`, `test/channel/`). Barrel surface is locked by `test/barrel_export_test.dart` — update it when you legitimately change the public API.
- `integration` tag is skipped by default (live API creds); `dart test` runs unit + contract. Integration runs via `dart test -t integration`.
- Shared fakes live in `dartclaw_testing` (`fake_agent_harness.dart`, `fake_codex_process.dart`, `fake_channel.dart`, `in_memory_session_service.dart`, etc.) — reuse them, do not re-roll.
- Async harness loops: never use `(_) async {}` polling without yielding to the timer queue (microtask starvation causes multi-GB leaks; see `dev/state/LEARNINGS.md`).

## Key files
- `lib/dartclaw_core.dart` — barrel; authoritative public API.
- `lib/src/harness/claude_code_harness.dart`, `codex_harness.dart` — provider harnesses.
- `lib/src/harness/harness_factory.dart` — construction + capability probes.
- `lib/src/bridge/bridge_events.dart` — sealed `BridgeEvent` hierarchy.
- `lib/src/events/dartclaw_event.dart` + `event_bus.dart` — sealed event taxonomy + bus.
- `lib/src/channel/channel_task_bridge.dart` — inbound routing precedence (binding → rate limit → review → trigger → fall-through).
- `lib/src/storage/atomic_write.dart` — the only sanctioned JSON write path.
- `lib/src/search/search_backend.dart` — abstract interface; concrete impls live in `dartclaw_storage`.

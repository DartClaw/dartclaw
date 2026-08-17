# Package Rules — `dartclaw_storage`

**Role**: SQLite-backed concrete implementations — `MemoryService` (FTS5 chunks), `Fts5SearchBackend` / `QmdSearchBackend` (`SearchBackend` interface from core), `Sqlite{Task,Goal,AgentExecution,WorkflowStepExecution,WorkflowRun}Repository`, `SqliteExecutionRepositoryTransactor`, `TurnStateStore`, `TaskEventService`, `TurnTraceService`, `MemoryPruner`.

## Architecture
- **DB factories** — `xxxDbFactory` typedef + `openXxxDb(path)` / `openXxxDbInMemory()` pairs. `search_db.dart` opens `search.db` (rebuildable index); `task_db.dart` opens `tasks.db` (authoritative + WAL); `state.db` is opened transiently by `TurnStateStore`.
- **SQLite repositories** — concrete impls of `dartclaw_core` interfaces, all bound to the shared `tasks.db` `Database` instance: `SqliteTaskRepository`, `SqliteGoalRepository`, `SqliteAgentExecutionRepository`, `SqliteWorkflowStepExecutionRepository`, `SqliteWorkflowRunRepository`, `SqliteExecutionRepositoryTransactor` (cross-repo transactions).
- **Memory + FTS5** — `MemoryService` owns canonical record normalization plus role/provenance/locator identity in the rebuildable `memory_chunks` content table and its `memory_chunks_ai/ad/au` FTS5 triggers; schema created via `_initSchema()`; column migrations branch on `PRAGMA table_info`.
- **Search backends** — `Fts5SearchBackend` owns lexical encoding; `QmdSearchBackend` owns QMD plus visible FTS fallback; `ComposedSearchBackend` is the single request-level personal/wiki composition, ranking, dedupe, and output top-K seam; `SearchBackendFactory` selects and composes them.
- **Observability writers** — `TurnTraceService` (append-mostly `turns` rows; fire-and-forget via `unawaited()`), `TaskEventService` (synchronous `task_events` audit writes); both backed by `tasks.db`.
- **Crash-recovery state** — `TurnStateStore` (`state.db`; transient rows written at turn-reservation, deleted in `finally`, bulk-cleaned by `detectAndCleanOrphanedTurns()` on boot — any row found at boot is crash evidence).
- **Memory pruning** — `MemoryPruner` selects only index/topic/archive/audit documents through core's `MemoryCorpusService`,
  collapses only canonical exact replays with complete provenance identity, audits removals in the same commit, preserves
  legacy/opaque content, and reconciles derived index rows only after canonical commit.
- **Memory migration** — `LegacyMemoryMigrator` classifies retained preview memory deterministically, preserves opaque bytes plus one no-clobber recovery snapshot, and publishes one bounded pre-index report through core's corpus authority.
- **Index recovery** — `CanonicalIndexReconciler` consumes independently bounded canonical row batches, proves exact SQLite/FTS row parity, re-authenticates the complete canonical union, then closes and atomically swaps the sibling. `IndexHealthStore` persists current/degraded recovery evidence outside disposable `search.db`.
- **Knowledge graph** — `src/knowledge/`: `TemporalKnowledgeGraphService` owns the `kg_facts` table (+ `kg_facts_lookup` index) in `tasks.db` and exposes `KnowledgeFact`/`KnowledgeContradiction`; `normalizeKnowledgeEntity` canonicalizes entity strings.
- **Wiki provenance vocabulary** – `trustedWikiProvenance` / `knownWikiProvenance` (`src/search/wiki_search_source.dart`) are the trust contract for wiki frontmatter `provenance`, owned here because this is the source that ranks it. `dartclaw_server`'s `WikiPageStore` imports `knownWikiProvenance` so the writer can never promote a page into a tier this reader trusts on the strength of not recognising its stored value. Widening the trusted set widens what ingestion will relabel – change both sides together.
- **Wiki + webhook stores** — `WikiSearchSource` (`src/search/wiki_search_source.dart`) feeds wiki pages into search; `WebhookDeliveryStore` (`src/storage/webhook_delivery_store.dart`) persists inbound-webhook delivery reservations for idempotency.

## Boundaries
- Allowed deps: `dartclaw_core`, `dartclaw_workflow` (for `WorkflowRun`/`WorkflowRunRepository` and related types), plus `sqlite3`, `logging`, `path`. **Don't** depend on `dartclaw_server`, `dartclaw_security`, or `dartclaw_config` (config dep is dev-only).
- This is the **only** workspace package allowed to import `package:sqlite3` aside from `dartclaw_server` (and the umbrella). If you need an SQLite-backed entity, the contract goes in `dartclaw_core` (`src/task/`, `src/execution/`, `src/search/`) and the impl lands here.
- No event firing. This package is a persistence layer – events are fired by the wiring layer in `dartclaw_server`. **Exception to the no-HTTP/no-process rule**: `QmdManager` (the optional QMD search backend) starts and supervises deadline-bounded external `qmd` processes with a minimal allowlisted environment and capped output, and talks to its daemon over loopback HTTP with capped response bodies. Timed-out or over-limit processes are terminated, then force-killed after a short grace period. That is the one sanctioned outbound/subprocess path here – keep it isolated in `QmdManager`; everything else stays pure persistence.
- Don't expose raw `Database` from public methods. Repositories take `Database` in their constructor and own statement lifecycle internally.

## Conventions
- DB factories follow the `xxxDbFactory` typedef + `openXxxDb(path)` / `openXxxDbInMemory()` pair (see `search_db.dart`, `task_db.dart`). In-memory variants exist for tests — use them.
- Schemas are created in the constructor via `_initSchema()` with `CREATE TABLE IF NOT EXISTS`. Migrations live alongside (`MemoryService._migrateUserIdColumn`) — additive only, branch on column presence via `PRAGMA table_info`.
- `tasks.db` is the shared DB for all tasks/agent_executions/workflow_step_executions/turns/task_events repos; they receive the same `Database` instance and **must** declare `PRAGMA journal_mode=WAL` once (see `TurnStateStore`). Don't open separate connections to the same file.
- `turns` table writes via `TurnTraceService` are fire-and-forget — callers `unawaited()` them. `task_events` writes are synchronous (audit semantics).
- `Fts5SearchBackend` is the always-on baseline. `QmdSearchBackend` wraps a `QmdManager` and falls back to FTS5 on unreachable QMD — never make QMD a hard dependency.
- FTS5 index uses content-table triggers (`memory_chunks_ai`/`ad`/`au`) — keep the trigger names stable, downstream `dartclaw rebuild-index` relies on the schema shape.
- `MemoryService.replaceMemoryRows` replaces canonical topic/archive/observation/learning rows transactionally while preserving independent wiki/KG sources. Its retired-source cleanup is migration provenance, not a live tool identity.
- Repos implementing core interfaces (`TaskRepository`, `GoalRepository`, etc.) must round-trip enum values via stable string names, not ordinals — `TaskStatus.byName(...)`. Renaming an enum value is a breaking schema change.

## Gotchas
- `package:sqlite3` ships a bundled native asset that codesigning may block on macOS; the documented escape hatch is `pubspec.yaml` `hooks.user_defines.sqlite3.source: system` — uncommitted local edit only, never the default.
- `Fts5SearchBackend` requires SQLite built with FTS5; the system fallback above must be verified before trusting tests.
- `MemoryPruner` operates on `MEMORY.md` and `MEMORY.archive.md` in the workspace dir — opaque content stays byte-for-byte in place, and undated entries are never archived or deduped. Don't add a "best effort" timestamp guess.
- `TurnStateStore` rows are transient: written at turn reservation, deleted in the turn's `finally`, and bulk-cleaned by `detectAndCleanOrphanedTurns()` on startup. Treat any row found at boot as crash evidence.
- `tasks.db` is authoritative for tasks/goals/executions/turns/events; `search.db` is rebuildable from the canonical memory corpus (`dartclaw rebuild-index`). Never store irrecoverable data in `search.db`.

## Testing
- Layout mirrors `lib/src/` (`test/storage/`, `test/search/`, `test/memory/`).
- Tags: `contract` (interface conformance), `component`, `integration` (skipped — live creds), `fitness-shape` (skipped — release-prep only). Default `dart test` runs contract+component; integration via `dart test --run-skipped -t integration`, shape via `dart test -t fitness-shape`.
- Use `openSearchDbInMemory()` / `openTaskDbInMemory()` for fast tests. In-memory SQLite gives identical FTS5 semantics.
- Repository tests should run against both the SQLite impl here and the `in_memory_*` fake from `dartclaw_testing` to verify contract parity.
- This package does **not** consume `dartclaw_testing` (forbidden dep) — package-local fakes of storage-owned types live in package-local support files. Search-backend fakes (e.g. `FakeQmdManager`) live in `test/search/search_test_support.dart`.

## Key files
- `lib/dartclaw_storage.dart` — barrel.
- `lib/src/storage/search_db.dart`, `task_db.dart` — DB open factories.
- `lib/src/storage/memory_service.dart` — FTS5 schema, triggers, `memory_chunks` table.
- `lib/src/storage/index_reconciler.dart` — exact sibling rebuild, target preservation, and durable index-health evidence.
- `lib/src/storage/sqlite_task_repository.dart` (+ goal/agent_execution/workflow_*) — relational repos against `tasks.db`.
- `lib/src/storage/turn_state_store.dart` — transient `state.db` for crash recovery.
- `lib/src/storage/turn_trace_service.dart`, `task_event_service.dart` — append-mostly observability writers in `tasks.db`.
- `lib/src/search/{fts5,qmd}_search_backend.dart`, `search_backend_factory.dart`, `qmd_manager.dart` — `SearchBackend` implementations.
- `lib/src/search/composed_search_backend.dart` — request-level wiki/personal composition and additive degradation.
- `lib/src/memory/memory_pruner.dart` — MEMORY.md archival + dedup.
- `lib/src/memory/legacy_memory_migrator.dart` — one-time lossless canonical migration and startup preflight reporting.

# Package Rules — `dartclaw_storage`

**Role**: SQLite-backed concrete implementations — `MemoryService` (FTS5 chunks), `Fts5SearchBackend` / `QmdSearchBackend` (`SearchBackend` interface from core), `Sqlite{Task,Goal,AgentExecution,WorkflowStepExecution,WorkflowRun}Repository`, `SqliteExecutionRepositoryTransactor`, `TurnStateStore`, `TaskEventService`, `TurnTraceService`, `MemoryPruner`.

## Architecture
- **DB factories** — `xxxDbFactory` typedef + `openXxxDb(path)` / `openXxxDbInMemory()` pairs. `search_db.dart` opens `search.db` (rebuildable index); `task_db.dart` opens `tasks.db` (authoritative + WAL); `state.db` is opened transiently by `TurnStateStore`.
- **SQLite repositories** — concrete impls of `dartclaw_core` interfaces, all bound to the shared `tasks.db` `Database` instance: `SqliteTaskRepository`, `SqliteGoalRepository`, `SqliteAgentExecutionRepository`, `SqliteWorkflowStepExecutionRepository`, `SqliteWorkflowRunRepository`, `SqliteExecutionRepositoryTransactor` (cross-repo transactions).
- **Memory + FTS5** — `MemoryService` owns the `memory_chunks` content table + `memory_chunks_ai/ad/au` FTS5 triggers; schema created via `_initSchema()`; column migrations branch on `PRAGMA table_info`.
- **Search backends** — `Fts5SearchBackend` (always-on baseline), `QmdSearchBackend` (wraps `QmdManager`, falls back to FTS5 on unreachable QMD), `SearchBackendFactory` (selects by config).
- **Observability writers** — `TurnTraceService` (append-mostly `turns` rows; fire-and-forget via `unawaited()`), `TaskEventService` (synchronous `task_events` audit writes); both backed by `tasks.db`.
- **Crash-recovery state** — `TurnStateStore` (`state.db`; transient rows written at turn-reservation, deleted in `finally`, bulk-cleaned by `detectAndCleanOrphanedTurns()` on boot — any row found at boot is crash evidence).
- **Memory pruning** — `MemoryPruner` (operates on `MEMORY.md` + `MEMORY.archive.md` in the workspace dir; undated entries are intentionally never archived nor deduped).

## Boundaries
- Allowed deps: `dartclaw_core` only (workspace), plus `sqlite3`, `logging`, `path`. **Don't** depend on `dartclaw_workflow`, `dartclaw_server`, `dartclaw_security`, or `dartclaw_config` (config dep is dev-only).
- This is the **only** workspace package allowed to import `package:sqlite3` aside from `dartclaw_server` (and the umbrella). If you need an SQLite-backed entity, the contract goes in `dartclaw_core` (`src/task/`, `src/execution/`, `src/search/`) and the impl lands here.
- No HTTP, no process spawning, no event firing. This package is a persistence layer — events are fired by the wiring layer in `dartclaw_server`.
- Don't expose raw `Database` from public methods. Repositories take `Database` in their constructor and own statement lifecycle internally.

## Conventions
- DB factories follow the `xxxDbFactory` typedef + `openXxxDb(path)` / `openXxxDbInMemory()` pair (see `search_db.dart`, `task_db.dart`). In-memory variants exist for tests — use them.
- Schemas are created in the constructor via `_initSchema()` with `CREATE TABLE IF NOT EXISTS`. Migrations live alongside (`MemoryService._migrateUserIdColumn`) — additive only, branch on column presence via `PRAGMA table_info`.
- `tasks.db` is the shared DB for all tasks/agent_executions/workflow_step_executions/turns/task_events repos; they receive the same `Database` instance and **must** declare `PRAGMA journal_mode=WAL` once (see `TurnStateStore`). Don't open separate connections to the same file.
- `turns` table writes via `TurnTraceService` are fire-and-forget — callers `unawaited()` them. `task_events` writes are synchronous (audit semantics).
- `Fts5SearchBackend` is the always-on baseline. `QmdSearchBackend` wraps a `QmdManager` and falls back to FTS5 on unreachable QMD — never make QMD a hard dependency.
- FTS5 index uses content-table triggers (`memory_chunks_ai`/`ad`/`au`) — keep the trigger names stable, downstream `dartclaw rebuild-index` relies on the schema shape.
- Repos implementing core interfaces (`TaskRepository`, `GoalRepository`, etc.) must round-trip enum values via stable string names, not ordinals — `TaskStatus.byName(...)`. Renaming an enum value is a breaking schema change.

## Gotchas
- `package:sqlite3` ships a bundled native asset that codesigning may block on macOS; the documented escape hatch is `pubspec.yaml` `hooks.user_defines.sqlite3.source: system` — uncommitted local edit only, never the default.
- `Fts5SearchBackend` requires SQLite built with FTS5; the system fallback above must be verified before trusting tests.
- `MemoryPruner` operates on `MEMORY.md` and `MEMORY.archive.md` in the workspace dir — undated entries are intentionally never archived nor deduped. Don't add a "best effort" timestamp guess.
- `TurnStateStore` rows are transient: written at turn reservation, deleted in the turn's `finally`, and bulk-cleaned by `detectAndCleanOrphanedTurns()` on startup. Treat any row found at boot as crash evidence.
- `tasks.db` is authoritative for tasks/goals/executions/turns/events; `search.db` is rebuildable from MEMORY.md (`dartclaw rebuild-index`). Never store irrecoverable data in `search.db`.

## Testing
- Layout mirrors `lib/src/` (`test/storage/`, `test/search/`, `test/memory/`).
- Tags: `contract` (interface conformance), `component`, `integration` (skipped — live creds), `fitness-shape` (skipped — release-prep only). Default `dart test` runs contract+component; integration via `dart test --run-skipped -t integration`, shape via `dart test -t fitness-shape`.
- Use `openSearchDbInMemory()` / `openTaskDbInMemory()` for fast tests. In-memory SQLite gives identical FTS5 semantics.
- Repository tests should run against both the SQLite impl here and the `in_memory_*` fake from `dartclaw_testing` to verify contract parity.

## Key files
- `lib/dartclaw_storage.dart` — barrel.
- `lib/src/storage/search_db.dart`, `task_db.dart` — DB open factories.
- `lib/src/storage/memory_service.dart` — FTS5 schema, triggers, `memory_chunks` table.
- `lib/src/storage/sqlite_task_repository.dart` (+ goal/agent_execution/workflow_*) — relational repos against `tasks.db`.
- `lib/src/storage/turn_state_store.dart` — transient `state.db` for crash recovery.
- `lib/src/storage/turn_trace_service.dart`, `task_event_service.dart` — append-mostly observability writers in `tasks.db`.
- `lib/src/search/{fts5,qmd}_search_backend.dart`, `search_backend_factory.dart`, `qmd_manager.dart` — `SearchBackend` implementations.
- `lib/src/memory/memory_pruner.dart` — MEMORY.md archival + dedup.

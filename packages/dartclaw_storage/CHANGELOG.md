All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_storage`.

## Unreleased

### Added
- `SqliteAgentExecutionRepository` with `agent_executions` schema bootstrap and filtering
- Additive `tasks.agent_execution_id` migration to prepare Task-to-AgentExecution linkage
- Joined task hydration plus the S34 migration that backfills AgentExecution rows, removes task-owned runtime columns, and enforces the `tasks.agent_execution_id` foreign key

### Changed
- `tasks.db` now treats `agent_executions` and `workflow_step_executions` as first-class tables in the task domain, with joined hydration supporting the S35 nested task JSON/API shape and the new execution-boundary fitness checks
- `SqliteExecutionRepositoryTransactor` now serializes concurrent `transaction(...)` callers through a single-slot queue, preventing the `cannot start a transaction within a transaction` failure when parallel map iterations (e.g. `maxParallel: 3`) each opened a triple-write against the shared SQLite connection

## 0.9.0

### Added
- MIT LICENSE, pubspec metadata, and a package-level changelog
- SQLite3-backed services: `MemoryService`, `SearchDbFactory`, `openSearchDb`, and `openSearchDbInMemory`
- Search backends: `Fts5SearchBackend`, `QmdSearchBackend`
- `MemoryPruner` for memory lifecycle management

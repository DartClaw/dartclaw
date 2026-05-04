/// SQLite3-backed storage services for DartClaw.
///
/// Provides memory chunk storage, FTS5 search indexing, QMD hybrid search,
/// and memory pruning — all backed by sqlite3.
///
/// The abstract [SearchBackend] interface lives in `dartclaw_core` (sqlite3-free).
/// This package provides the concrete implementations.
library;

// Storage services
export 'src/storage/memory_service.dart' show MemoryService;
export 'src/storage/search_db.dart' show SearchDbFactory, openSearchDb, openSearchDbInMemory;
export 'src/storage/sqlite_agent_execution_repository.dart' show SqliteAgentExecutionRepository;
export 'src/storage/sqlite_execution_repository_transactor.dart' show SqliteExecutionRepositoryTransactor;
export 'src/storage/sqlite_goal_repository.dart' show SqliteGoalRepository;
export 'src/storage/sqlite_task_repository.dart' show SqliteTaskRepository;
export 'src/storage/sqlite_workflow_step_execution_repository.dart' show SqliteWorkflowStepExecutionRepository;
export 'src/storage/sqlite_workflow_run_repository.dart' show SqliteWorkflowRunRepository;
export 'src/storage/task_db.dart' show TaskDbFactory, openTaskDb, openTaskDbInMemory;
export 'src/storage/turn_state_store.dart' show TurnStateStore;
export 'src/storage/task_event_service.dart' show TaskEventService;
export 'src/storage/turn_trace_service.dart' show TurnTraceService, TraceQueryResult;

// Search backends
export 'src/search/fts5_search_backend.dart' show Fts5SearchBackend;
export 'src/search/search_backend_factory.dart' show createSearchBackend;
export 'src/search/qmd_search_backend.dart' show QmdSearchBackend, SearchDepth;
export 'src/search/qmd_manager.dart' show QmdManager;

// Memory
export 'src/memory/memory_pruner.dart' show MemoryPruner, PruneResult;

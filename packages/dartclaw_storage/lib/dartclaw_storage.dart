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
export 'src/storage/search_db.dart'
    show SearchDbFactory, openSearchDb, openSearchDbInMemory;

// Search backends
export 'src/search/fts5_search_backend.dart' show Fts5SearchBackend;
export 'src/search/search_backend_factory.dart' show createSearchBackend;
export 'src/search/qmd_search_backend.dart' show QmdSearchBackend, SearchDepth;
export 'src/search/qmd_manager.dart' show QmdManager;

// Memory
export 'src/memory/memory_pruner.dart' show MemoryPruner;

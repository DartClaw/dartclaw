# dartclaw_storage

SQLite3-backed storage services for DartClaw.

`dartclaw_storage` adds the default persistence layer for DartClaw: a derived
FTS5 memory index, optional QMD hybrid search, task and goal
repositories, and memory pruning. It depends on `dartclaw_core` for the
runtime-facing interfaces and models.

> **Status: Pre-1.0**. The storage APIs are stabilizing, but schema and search
> behavior may still change before 1.0.

## Installation

```sh
dart pub add dartclaw_storage
```

SQLite must be available on the host where the package runs.

## Quick Start

```dart
import 'package:dartclaw_storage/dartclaw_storage.dart';

Future<void> main() async {
  final db = openSearchDbInMemory();
  final memory = MemoryService(db);
  final search = Fts5SearchBackend(memoryService: memory);
  final results = await search.search('rotate tokens');
  print(results.results);
  db.close();
}
```

## Key Types

- `MemoryService`: low-level rebuildable FTS projection and search access.
- `Fts5SearchBackend` and `QmdSearchBackend`: concrete `SearchBackend` implementations.
- `createSearchBackend`, `SearchDbFactory`, `openSearchDb`: helpers for opening and choosing search backends.
- `SqliteTaskRepository` and `SqliteGoalRepository`: SQLite-backed task persistence.
- `MemoryPruner`: automated cleanup for memory files and search state.
- `QmdManager` and `SearchDepth`: QMD hybrid search integration points.

## When to Use This Package

Use `dartclaw_storage` when you want the default DartClaw persistence story:
SQLite-backed memory search and durable task storage. If you need the runtime
without SQLite, depend on [`dartclaw_core`](https://pub.dev/packages/dartclaw_core)
and provide your own persistence implementation.

## Related Packages

- [`dartclaw`](https://pub.dev/packages/dartclaw) for the umbrella SDK.
- [`dartclaw_core`](https://pub.dev/packages/dartclaw_core) for the SQLite-free runtime.

## Documentation

- [API Reference](https://pub.dev/documentation/dartclaw_storage/latest/)
- [Repository](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_storage)

## License

MIT - see [LICENSE](LICENSE).

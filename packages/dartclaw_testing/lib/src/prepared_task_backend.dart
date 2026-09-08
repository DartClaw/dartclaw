import 'package:dartclaw_core/dartclaw_core.dart' show SqliteBackend, SqliteSchemaGate;

/// Opens and prepares an in-memory backend with the current task schema.
Future<SqliteBackend> openPreparedTaskBackend() async {
  final backend = SqliteBackend.openInMemory();
  await SqliteSchemaGate.prepareTasks(backend, storeName: 'tasks.db');
  return backend;
}

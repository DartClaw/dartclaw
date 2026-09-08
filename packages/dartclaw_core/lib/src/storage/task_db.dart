import 'package:sqlite3/sqlite3.dart';

/// Factory for opening a sqlite3 [Database] for task storage.
typedef TaskDbFactory = Database Function(String path);

/// Opens a sqlite3 [Database] for task storage at [path].
Database openTaskDb(String path) {
  final database = sqlite3.open(path);
  try {
    database.execute('PRAGMA journal_mode=WAL');
    database.execute('PRAGMA foreign_keys=ON');
    return database;
  } catch (_) {
    database.close();
    rethrow;
  }
}

/// Opens an in-memory sqlite3 [Database] for task storage.
Database openTaskDbInMemory() {
  final database = sqlite3.openInMemory();
  database.execute('PRAGMA journal_mode=WAL');
  database.execute('PRAGMA foreign_keys=ON');
  return database;
}

import 'package:sqlite3/sqlite3.dart';

/// Factory for opening a sqlite3 [Database] for task storage.
typedef TaskDbFactory = Database Function(String path);

/// Opens a sqlite3 [Database] for task storage at [path].
Database openTaskDb(String path) => sqlite3.open(path);

/// Opens an in-memory sqlite3 [Database] for task storage.
Database openTaskDbInMemory() => sqlite3.openInMemory();

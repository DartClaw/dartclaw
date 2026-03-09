import 'package:sqlite3/sqlite3.dart';

/// Factory for opening a sqlite3 [Database] at the given file path.
typedef SearchDbFactory = Database Function(String path);

/// Opens a sqlite3 [Database] at the given file [path].
Database openSearchDb(String path) => sqlite3.open(path);

/// Opens an in-memory sqlite3 [Database] (useful for tests).
Database openSearchDbInMemory() => sqlite3.openInMemory();

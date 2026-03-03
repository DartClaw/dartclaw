import 'package:sqlite3/sqlite3.dart';

typedef SearchDbFactory = Database Function(String path);

Database openSearchDb(String path) => sqlite3.open(path);
Database openSearchDbInMemory() => sqlite3.openInMemory();

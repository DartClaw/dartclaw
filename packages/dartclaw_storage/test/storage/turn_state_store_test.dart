import 'dart:io';

import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('TurnStateStore', () {
    late Database db;
    late TurnStateStore store;
    late bool storeDisposed;

    setUp(() {
      db = sqlite3.openInMemory();
      store = TurnStateStore(db);
      storeDisposed = false;
    });

    tearDown(() async {
      if (!storeDisposed) {
        await store.dispose();
      }
    });

    group('schema', () {
      test('creates turn_state table', () {
        final tables = db.select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name");
        final names = tables.map((row) => row['name']).toList();

        expect(names, contains('turn_state'));
      });

      test('enables WAL mode for file databases', () async {
        final tempDir = await Directory.systemTemp.createTemp('turn-state-store-');
        try {
          final fileDb = sqlite3.open(p.join(tempDir.path, 'state.db'));
          final fileStore = TurnStateStore(fileDb);
          final rows = fileDb.select('PRAGMA journal_mode');

          expect(rows.single.columnAt(0), 'wal');

          await fileStore.dispose();
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      });
    });

    test('set and getAll round-trip', () async {
      final startedAt = DateTime.parse('2026-03-15T09:30:00Z');

      await store.set('session-1', 'turn-1', startedAt);
      final states = await store.getAll();

      expect(states, hasLength(1));
      expect(states['session-1'], (turnId: 'turn-1', startedAt: startedAt));
    });

    test('delete removes entry', () async {
      await store.set('session-1', 'turn-1', DateTime.parse('2026-03-15T09:30:00Z'));

      await store.delete('session-1');
      final states = await store.getAll();

      expect(states, isEmpty);
    });

    test('set with existing key updates existing entry', () async {
      await store.set('session-1', 'turn-1', DateTime.parse('2026-03-15T09:30:00Z'));
      final updatedAt = DateTime.parse('2026-03-15T09:45:00Z');

      await store.set('session-1', 'turn-2', updatedAt);
      final states = await store.getAll();

      expect(states, hasLength(1));
      expect(states['session-1'], (turnId: 'turn-2', startedAt: updatedAt));
    });

    test('getAll returns empty map when table is empty', () async {
      expect(await store.getAll(), isEmpty);
    });

    test('concurrent set operations on different keys both persist', () async {
      await Future.wait([
        store.set('session-1', 'turn-1', DateTime.parse('2026-03-15T09:30:00Z')),
        store.set('session-2', 'turn-2', DateTime.parse('2026-03-15T09:31:00Z')),
      ]);

      final states = await store.getAll();

      expect(states, hasLength(2));
      expect(states['session-1']?.turnId, 'turn-1');
      expect(states['session-2']?.turnId, 'turn-2');
    });

    test('dispose closes the owned database', () async {
      await store.dispose();
      storeDisposed = true;

      await expectLater(store.getAll(), throwsA(anything));
    });
  });
}

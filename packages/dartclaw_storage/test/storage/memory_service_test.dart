import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late MemoryService memory;

  setUp(() {
    db = sqlite3.openInMemory();
    memory = MemoryService(db);
  });

  tearDown(() {
    db.close();
  });

  group('insertChunk', () {
    test('inserts and returns id', () {
      final id = memory.insertChunk(text: 'Hello world', source: 'test');
      expect(id, greaterThan(0));
    });

    test('throws on empty text', () {
      expect(() => memory.insertChunk(text: '  ', source: 'test'), throwsA(isA<ArgumentError>()));
    });

    test('throws on empty source', () {
      expect(() => memory.insertChunk(text: 'Hello', source: '  '), throwsA(isA<ArgumentError>()));
    });

    test('supports optional category', () {
      final id = memory.insertChunk(text: 'Test', source: 'src', category: 'prefs');
      expect(id, greaterThan(0));
    });

    test('insertChunkIfAbsent keeps one row per exact identity', () {
      expect(memory.insertChunkIfAbsent(text: 'Stable fact', source: 'archive', category: 'prefs'), isTrue);
      expect(memory.insertChunkIfAbsent(text: 'Stable fact', source: 'archive', category: 'prefs'), isFalse);
      expect(memory.insertChunkIfAbsent(text: 'Stable fact', source: 'archive', category: 'project'), isTrue);
      expect(memory.search('"Stable"'), hasLength(2));
    });

    test('deleteChunkIdentity removes only the exact indexed identity', () {
      memory.insertChunkIfAbsent(text: 'Stable fact', source: 'archive', category: 'prefs');
      memory.insertChunkIfAbsent(text: 'Stable fact', source: 'archive', category: 'project');

      expect(memory.deleteChunkIdentity(text: 'Stable fact', source: 'archive', category: 'prefs'), isTrue);
      expect(memory.deleteChunkIdentity(text: 'Stable fact', source: 'archive', category: 'prefs'), isFalse);
      expect(memory.search('"Stable"').single.category, 'project');
    });

    test('canonical rows normalize Markdown and split paragraphs', () {
      final longTail = List.generate(90, (index) => 'segment$index').join(' ');
      final timestamp = DateTime(2026, 2, 23, 10);
      final rows = MemoryService.indexRows(
        text: '**Durable heading**\n\n$longTail',
        source: 'memory_save',
        category: 'project',
        createdAt: timestamp,
      );

      expect(rows, hasLength(greaterThan(1)));
      expect(rows.first.text, 'Durable heading');
      expect(rows.every((row) => row.source == 'memory_save' && row.category == 'project'), isTrue);
      expect(rows.every((row) => row.createdAt == timestamp), isTrue);
    });

    test('canonical undated rows receive one deterministic oldest timestamp', () {
      MemoryIndexRow build() => MemoryService.indexRows(
        text: 'Undated fact',
        source: 'memory_save',
        category: 'general',
        createdAt: null,
      ).single;

      expect(build().createdAt, build().createdAt);
      expect(build().createdAt.isBefore(DateTime(1900)), isTrue);
    });

    test('canonical rows omit Markdown-only text', () {
      expect(
        MemoryService.indexRows(text: '**', source: 'memory_save', category: 'general', createdAt: DateTime(2026)),
        isEmpty,
      );
    });
  });

  group('search', () {
    test('finds matching text via FTS5', () {
      memory.insertChunk(text: 'Dart is a great programming language', source: 'test');
      memory.insertChunk(text: 'Python is also popular', source: 'test');

      final results = memory.search('"Dart"');
      expect(results, hasLength(1));
      expect(results.first.text, contains('Dart'));
      expect(results.first.source, equals('test'));
      expect(results.first.score, isA<double>());
    });

    test('returns empty for no match', () {
      memory.insertChunk(text: 'Hello world', source: 'test');
      final results = memory.search('"nonexistentword"');
      expect(results, isEmpty);
    });

    test('respects limit', () {
      for (var i = 0; i < 10; i++) {
        memory.insertChunk(text: 'Search term $i about testing', source: 'test');
      }
      final results = memory.search('"testing"', limit: 3);
      expect(results.length, lessThanOrEqualTo(3));
    });

    test('returns category in results', () {
      memory.insertChunk(text: 'Categorized fact', source: 'src', category: 'prefs');
      final results = memory.search('"Categorized"');
      expect(results.first.category, equals('prefs'));
    });
  });

  group('user isolation', () {
    test('search returns only chunks for the specified userId', () {
      memory.insertChunk(text: 'Alice secret note about Dart', source: 'a', userId: 'alice');
      memory.insertChunk(text: 'Bob secret note about Dart', source: 'b', userId: 'bob');

      final aliceResults = memory.search('"Dart"', userId: 'alice');
      expect(aliceResults, hasLength(1));
      expect(aliceResults.first.source, equals('a'));

      final bobResults = memory.search('"Dart"', userId: 'bob');
      expect(bobResults, hasLength(1));
      expect(bobResults.first.source, equals('b'));
    });

    test('deleteBySource scoped to userId', () {
      memory.insertChunk(text: 'Shared topic', source: 'shared', userId: 'alice');
      memory.insertChunk(text: 'Shared topic', source: 'shared', userId: 'bob');

      final deleted = memory.deleteBySource('shared', userId: 'alice');
      expect(deleted, equals(1));

      // Bob's chunk survives
      final bobResults = memory.search('"Shared"', userId: 'bob');
      expect(bobResults, hasLength(1));
    });

    test('rebuildIndex scoped to userId', () {
      memory.insertChunk(text: 'Alice data', source: 'a', userId: 'alice');
      memory.insertChunk(text: 'Bob data', source: 'b', userId: 'bob');

      memory.rebuildIndex([
        MemoryIndexRow(text: 'Alice fresh', source: 'a2', category: null, createdAt: DateTime(2026)),
      ], userId: 'alice');

      // Alice got replaced
      final aliceResults = memory.search('"Alice"', userId: 'alice');
      expect(aliceResults, hasLength(1));
      expect(aliceResults.first.source, equals('a2'));

      // Bob untouched
      final bobResults = memory.search('"Bob"', userId: 'bob');
      expect(bobResults, hasLength(1));
    });

    test('default userId is owner', () {
      memory.insertChunk(text: 'Default owner chunk', source: 'test');
      final results = memory.search('"Default"');
      expect(results, hasLength(1));
    });
  });

  group('searchVector', () {
    test('returns empty list (stub)', () {
      final results = memory.searchVector([0.1, 0.2, 0.3]);
      expect(results, isEmpty);
    });
  });

  group('listRecent', () {
    test('orders by source entry time rather than insertion time', () {
      memory.insertChunk(text: 'Current active fact', source: 'memory_save', createdAt: DateTime(2026, 2, 23, 10));
      memory.insertChunk(text: 'Old archived fact', source: 'archive', createdAt: DateTime(2025, 1, 10, 9));

      expect(memory.listRecent().map((result) => result.text), ['Current active fact', 'Old archived fact']);
    });
  });

  group('deleteBySource', () {
    test('deletes chunks by source', () {
      memory.insertChunk(text: 'From source A', source: 'a');
      memory.insertChunk(text: 'From source B', source: 'b');

      final deleted = memory.deleteBySource('a');
      expect(deleted, equals(1));

      final results = memory.search('"source"');
      expect(results, hasLength(1));
      expect(results.first.source, equals('b'));
    });
  });

  group('rebuildIndex', () {
    test('replaces all chunks', () {
      memory.insertChunk(text: 'Old data', source: 'old');

      memory.rebuildIndex([
        MemoryIndexRow(text: 'New data one', source: 'new', category: null, createdAt: DateTime(2026)),
        MemoryIndexRow(text: 'New data two', source: 'new', category: 'cat', createdAt: DateTime(2026)),
      ]);

      final oldResults = memory.search('"Old"');
      expect(oldResults, isEmpty);

      final newResults = memory.search('"New"');
      expect(newResults, hasLength(2));
    });

    test('retains the previous index when replacement fails', () {
      memory.insertChunk(text: 'Stable old data', source: 'old');
      db.execute('''
        CREATE TRIGGER reject_bad_rebuild BEFORE INSERT ON memory_chunks
        WHEN new.text = 'Bad replacement'
        BEGIN
          SELECT RAISE(ABORT, 'injected rebuild failure');
        END
      ''');

      expect(
        () => memory.rebuildIndex([
          MemoryIndexRow(text: 'Partial replacement', source: 'new', category: null, createdAt: DateTime(2026)),
          MemoryIndexRow(text: 'Bad replacement', source: 'new', category: null, createdAt: DateTime(2026)),
        ]),
        throwsA(isA<SqliteException>()),
      );

      expect(memory.search('"Stable"'), hasLength(1));
      expect(memory.search('"Partial"'), isEmpty);
    });

    test('source replacement preserves unrelated rows', () {
      memory.insertChunk(text: 'Stale active', source: 'memory_save', category: 'general');
      memory.insertChunk(text: 'Stale archive', source: 'archive', category: 'general');
      memory.insertChunk(text: 'Independent row', source: 'other');

      memory.replaceSourceRows(
        [
          MemoryIndexRow(
            text: 'Canonical active',
            source: 'memory_save',
            category: 'general',
            createdAt: DateTime(2026),
          ),
        ],
        sources: {'memory_save', 'archive'},
      );

      expect(memory.search('"Stale"'), isEmpty);
      expect(memory.search('"Canonical"'), hasLength(1));
      expect(memory.search('"Independent"'), hasLength(1));
    });

    test('category replacement preserves other categories', () {
      memory.insertChunk(text: 'Old learning', source: 'memory_save', category: 'learning');
      memory.insertChunk(text: 'General fact', source: 'memory_save', category: 'general');

      memory.replaceCategoryRows(
        [MemoryIndexRow(text: 'New learning', source: 'memory_save', category: 'learning', createdAt: DateTime(2026))],
        source: 'memory_save',
        category: 'learning',
      );

      expect(memory.search('"Old"'), isEmpty);
      expect(memory.search('"New"'), hasLength(1));
      expect(memory.search('"General"'), hasLength(1));
    });
  });
}

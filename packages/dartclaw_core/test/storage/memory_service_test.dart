import 'package:dartclaw_core/dartclaw_core.dart';
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

  group('index rows', () {
    test('canonical rows normalize Markdown and split paragraphs', () {
      final longTail = List.generate(90, (index) => 'segment$index').join(' ');
      final timestamp = DateTime(2026, 2, 23, 10);
      final rows = MemoryService.indexRows(
        text: '**Durable heading**\n\n$longTail',
        source: 'topic/project/entry-1',
        category: 'project',
        createdAt: timestamp,
      );

      expect(rows, hasLength(greaterThan(1)));
      expect(rows.first.text, 'Durable heading');
      expect(rows.every((row) => row.source == 'topic/project/entry-1' && row.category == 'project'), isTrue);
      expect(rows.every((row) => row.createdAt == timestamp), isTrue);
    });

    test('canonical undated rows receive one deterministic oldest timestamp', () {
      MemoryIndexRow build() => MemoryService.indexRows(
        text: 'Undated fact',
        source: 'topic/general/entry-1',
        category: 'general',
        createdAt: null,
      ).single;

      expect(build().createdAt, build().createdAt);
      expect(build().createdAt.isBefore(DateTime(1900)), isTrue);
    });

    test('canonical rows omit Markdown-only text', () {
      expect(
        MemoryService.indexRows(
          text: '**',
          source: 'topic/general/entry-1',
          category: 'general',
          createdAt: DateTime(2026),
        ),
        isEmpty,
      );
    });
  });

  group('search', () {
    test('finds matching text via FTS5', () {
      _seed(db, text: 'Dart is a great programming language', source: 'test');
      _seed(db, text: 'Python is also popular', source: 'test');

      final results = memory.search('"Dart"');
      expect(results, hasLength(1));
      expect(results.first.text, contains('Dart'));
      expect(results.first.source, equals('test'));
      expect(results.first.score, isA<double>());
    });

    test('returns empty for no match', () {
      _seed(db, text: 'Hello world', source: 'test');
      final results = memory.search('"nonexistentword"');
      expect(results, isEmpty);
    });

    test('respects limit', () {
      for (var i = 0; i < 10; i++) {
        _seed(db, text: 'Search term $i about testing', source: 'test');
      }
      final results = memory.search('"testing"', limit: 3);
      expect(results.length, lessThanOrEqualTo(3));
    });

    test('returns category in results', () {
      _seed(db, text: 'Categorized fact', source: 'src', category: 'prefs');
      final results = memory.search('"Categorized"');
      expect(results.first.category, equals('prefs'));
    });
  });

  group('user isolation', () {
    test('search returns only chunks for the specified userId', () {
      _seed(db, text: 'Alice secret note about Dart', source: 'a', userId: 'alice');
      _seed(db, text: 'Bob secret note about Dart', source: 'b', userId: 'bob');

      final aliceResults = memory.search('"Dart"', userId: 'alice');
      expect(aliceResults, hasLength(1));
      expect(aliceResults.first.source, equals('a'));

      final bobResults = memory.search('"Dart"', userId: 'bob');
      expect(bobResults, hasLength(1));
      expect(bobResults.first.source, equals('b'));
    });

    test('rebuildIndex scoped to userId', () {
      _seed(db, text: 'Alice data', source: 'a', userId: 'alice');
      _seed(db, text: 'Bob data', source: 'b', userId: 'bob');

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
      _seed(db, text: 'Default owner chunk', source: 'test');
      final results = memory.search('"Default"');
      expect(results, hasLength(1));
    });
  });

  group('listRecent', () {
    test('orders by source entry time rather than insertion time', () {
      _seed(db, text: 'Current active fact', source: 'topic/general/entry-1', createdAt: DateTime(2026, 2, 23, 10));
      _seed(db, text: 'Old archived fact', source: 'archive', createdAt: DateTime(2025, 1, 10, 9));

      expect(memory.listRecent().map((result) => result.text), ['Current active fact', 'Old archived fact']);
    });
  });

  group('rebuildIndex', () {
    test('replaces all chunks', () {
      _seed(db, text: 'Old data', source: 'old');

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
      _seed(db, text: 'Stable old data', source: 'old');
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

    test('memory replacement clears legacy rows and preserves independent sources', () {
      _seed(db, text: 'Stale active', source: 'memory_save', category: 'general');
      _seed(db, text: 'Stale archive', source: 'legacy-archive', category: 'general');
      _seed(db, text: 'Independent row', source: 'wiki');

      memory.replaceMemoryRows([
        MemoryIndexRow(
          text: 'Canonical active',
          source: 'e907c4e7-0c55-43c0-95cd-ebf41c4f6721',
          role: 'topic',
          locator: 'e907c4e7-0c55-43c0-95cd-ebf41c4f6721',
          entryId: 'e907c4e7-0c55-43c0-95cd-ebf41c4f6721',
          entryRevision: 1,
          category: 'general',
          createdAt: DateTime(2026),
        ),
      ]);

      expect(memory.search('"Stale"'), isEmpty);
      expect(memory.search('"Canonical"').single.locator, 'e907c4e7-0c55-43c0-95cd-ebf41c4f6721');
      expect(memory.search('"Independent"').single.source, 'wiki');
    });
  });
}

void _seed(
  Database db, {
  required String text,
  required String source,
  String? category,
  DateTime? createdAt,
  String userId = 'owner',
}) {
  db.execute(
    'INSERT INTO memory_chunks (text, source, category, created_at, user_id, locator) VALUES (?, ?, ?, ?, ?, ?)',
    [text, source, category, (createdAt ?? DateTime(2026)).toIso8601String(), userId, source],
  );
}

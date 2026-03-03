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

      memory.rebuildIndex([(text: 'Alice fresh', source: 'a2', category: null)], userId: 'alice');

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
        (text: 'New data one', source: 'new', category: null),
        (text: 'New data two', source: 'new', category: 'cat'),
      ]);

      final oldResults = memory.search('"Old"');
      expect(oldResults, isEmpty);

      final newResults = memory.search('"New"');
      expect(newResults, hasLength(2));
    });
  });
}

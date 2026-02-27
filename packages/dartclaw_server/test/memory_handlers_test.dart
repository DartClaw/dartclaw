import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late MemoryService memory;
  late MemoryFileService memoryFile;
  late Directory tempDir;
  late ({
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSave,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSearch,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) onRead,
  })
  handlers;

  setUp(() {
    db = sqlite3.openInMemory();
    memory = MemoryService(db);
    tempDir = Directory.systemTemp.createTempSync('handlers_test');
    memoryFile = MemoryFileService(baseDir: tempDir.path);
    handlers = createMemoryHandlers(memory: memory, memoryFile: memoryFile);
  });

  tearDown(() async {
    await memoryFile.dispose();
    db.close();
    tempDir.deleteSync(recursive: true);
  });

  group('onSave', () {
    test('saves text and returns chunk count', () async {
      final result = await handlers.onSave({'text': 'User prefers Dart', 'category': 'prefs'});
      expect(result['ok'], isTrue);
      expect(result['chunks_created'], 1);

      // Verify FTS5 searchable
      final search = memory.search('"Dart"');
      expect(search, isNotEmpty);
    });

    test('splits long text into multiple chunks', () async {
      final longText = List.generate(20, (i) => 'Paragraph $i with enough content to fill it up nicely.').join('\n\n');
      final result = await handlers.onSave({'text': longText});
      expect(result['chunks_created'], greaterThan(1));
    });

    test('rejects empty text', () async {
      await expectLater(handlers.onSave({'text': '  ', 'category': 'x'}), throwsA(isA<ArgumentError>()));
    });

    test('sanitizes category to lowercase alphanumeric', () async {
      await handlers.onSave({'text': 'Test', 'category': 'My Category!!'});
      final content = await memoryFile.readMemory();
      expect(content, contains('## my-category'));
    });

    test('defaults category to general', () async {
      await handlers.onSave({'text': 'No category'});
      final content = await memoryFile.readMemory();
      expect(content, contains('## general'));
    });
  });

  group('onSearch', () {
    test('returns results for matching query', () async {
      await handlers.onSave({'text': 'Dart is a great language'});
      final result = await handlers.onSearch({'query': 'Dart language'});
      final results = result['results'] as List;
      expect(results, isNotEmpty);
      expect(results.first['text'], contains('Dart'));
    });

    test('returns empty for empty query', () async {
      final result = await handlers.onSearch({'query': ''});
      expect((result['results'] as List), isEmpty);
    });

    test('handles FTS5 operator chars safely', () async {
      await handlers.onSave({'text': 'Test data for search'});
      // These should not cause FTS5 syntax errors
      final result = await handlers.onSearch({'query': 'test AND OR * NEAR'});
      expect(result['results'], isA<List<Map<String, dynamic>>>());
    });

    test('respects limit parameter', () async {
      for (var i = 0; i < 5; i++) {
        await handlers.onSave({'text': 'Search entry $i about testing'});
      }
      final result = await handlers.onSearch({'query': 'testing', 'limit': 2});
      expect((result['results'] as List).length, lessThanOrEqualTo(2));
    });
  });

  group('onRead', () {
    test('returns empty content when no MEMORY.md', () async {
      final result = await handlers.onRead({});
      expect(result['content'], isEmpty);
      expect(result['size_bytes'], 0);
    });

    test('returns MEMORY.md content after save', () async {
      await handlers.onSave({'text': 'Remembered fact'});
      final result = await handlers.onRead({});
      expect(result['content'], contains('Remembered fact'));
      expect(result['size_bytes'], greaterThan(0));
    });
  });
}

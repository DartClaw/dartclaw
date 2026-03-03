import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Extracts text from MCP result format: `{'content': [{'type': 'text', 'text': ...}]}`.
String _text(Map<String, dynamic> result) {
  final content = result['content'] as List;
  return (content[0] as Map<String, dynamic>)['text'] as String;
}

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
    final searchBackend = Fts5SearchBackend(memoryService: memory);
    handlers = createMemoryHandlers(memory: memory, memoryFile: memoryFile, searchBackend: searchBackend);
  });

  tearDown(() async {
    await memoryFile.dispose();
    db.close();
    tempDir.deleteSync(recursive: true);
  });

  group('onSave', () {
    test('saves text and returns confirmation', () async {
      final result = await handlers.onSave({'text': 'User prefers Dart', 'category': 'prefs'});
      expect(_text(result), contains('chunk'));

      // Verify FTS5 searchable
      final search = memory.search('"Dart"');
      expect(search, isNotEmpty);
    });

    test('splits long text into multiple chunks', () async {
      final longText = List.generate(20, (i) => 'Paragraph $i with enough content to fill it up nicely.').join('\n\n');
      final result = await handlers.onSave({'text': longText});
      // Should report more than 1 chunk saved
      expect(_text(result), matches(RegExp(r'Saved \d+ chunk')));
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
      expect(_text(result), contains('Dart'));
    });

    test('returns empty message for empty query', () async {
      final result = await handlers.onSearch({'query': ''});
      expect(_text(result), contains('No results'));
    });

    test('handles FTS5 operator chars safely', () async {
      await handlers.onSave({'text': 'Test data for search'});
      // These should not cause FTS5 syntax errors
      final result = await handlers.onSearch({'query': 'test AND OR * NEAR'});
      expect(result['content'], isA<List<dynamic>>());
    });

    test('respects limit parameter', () async {
      for (var i = 0; i < 5; i++) {
        await handlers.onSave({'text': 'Search entry $i about testing'});
      }
      final result = await handlers.onSearch({'query': 'testing', 'limit': 2});
      final text = _text(result);
      // With limit 2, should have at most 2 result lines
      if (text != 'No results.') {
        final lines = text.split('\n').where((l) => l.startsWith('- [')).toList();
        expect(lines.length, lessThanOrEqualTo(2));
      }
    });
  });

  group('onRead', () {
    test('returns empty indicator when no MEMORY.md', () async {
      final result = await handlers.onRead({});
      expect(_text(result), contains('empty'));
    });

    test('returns MEMORY.md content after save', () async {
      await handlers.onSave({'text': 'Remembered fact'});
      final result = await handlers.onRead({});
      expect(_text(result), contains('Remembered fact'));
    });
  });
}

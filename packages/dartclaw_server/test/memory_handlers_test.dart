import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/memory_handlers.dart' show maxMemorySaveCategoryLength, maxMemorySaveTextLength;
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

    test('uses canonical normalization and one source timestamp for all chunks', () async {
      final longTail = List.generate(90, (index) => 'segment$index').join(' ');
      final text = '**Durable heading**\n\n$longTail';
      final expected = MemoryService.indexRows(
        text: text,
        source: 'memory_save',
        category: 'project',
        createdAt: DateTime(2000),
      );

      await handlers.onSave({'text': text, 'category': 'project'});

      final rows = db.select('SELECT text, source, category, created_at FROM memory_chunks ORDER BY id');
      expect(rows.map((row) => row['text']), expected.map((row) => row.text));
      expect(rows.every((row) => row['source'] == 'memory_save' && row['category'] == 'project'), isTrue);
      expect(rows.map((row) => row['created_at']).toSet(), hasLength(1));
      final canonicalTimestamp = parseMemoryEntries(await memoryFile.readMemory()).single.timestamp;
      expect(rows.first['created_at'], canonicalTimestamp!.toIso8601String());
    });

    test('CRLF text produces the same exact rows live and after rebuild', () async {
      final firstParagraph = List.generate(80, (index) => 'first$index').join(' ');
      final secondParagraph = List.generate(80, (index) => 'second$index').join(' ');

      await handlers.onSave({'text': '$firstParagraph\r\n\r\n$secondParagraph\rtrailing line', 'category': 'project'});

      final liveRows = _indexRows(db);
      final persistedEntries = parseMemoryEntries(await memoryFile.readMemory());
      memory.rebuildIndex([
        for (final entry in persistedEntries)
          ...MemoryService.indexRows(
            text: entry.rawText,
            source: 'memory_save',
            category: entry.category,
            createdAt: entry.timestamp,
          ),
      ]);

      expect(liveRows, unorderedEquals(_indexRows(db)));
    });

    test('rejects empty text', () async {
      await expectLater(handlers.onSave({'text': '  ', 'category': 'x'}), throwsA(isA<ArgumentError>()));
    });

    test('accepts text and category at their maximum lengths', () async {
      final text = 'x' * maxMemorySaveTextLength;
      final category = 'c' * maxMemorySaveCategoryLength;

      await handlers.onSave({'text': text, 'category': category});

      expect(await memoryFile.readMemory(), contains('## $category'));
    });

    for (final (field, limit) in [('text', maxMemorySaveTextLength), ('category', maxMemorySaveCategoryLength)]) {
      test('rejects $field over its maximum length before writing', () async {
        await expectLater(
          handlers.onSave({
            'text': field == 'text' ? 'x' * (limit + 1) : 'valid',
            'category': field == 'category' ? 'c' * (limit + 1) : 'valid',
          }),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'message',
              '$field must not exceed $limit characters',
            ),
          ),
        );

        expect(File('${tempDir.path}/MEMORY.md').existsSync(), isFalse);
        expect(db.select('SELECT * FROM memory_chunks'), isEmpty);
      });
    }

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

    test('does not index or report success when a learning write fails', () async {
      final selfImprovement = SelfImprovementService(workspaceDir: tempDir.path);
      addTearDown(selfImprovement.dispose);
      final learningHandlers = createMemoryHandlers(
        memory: memory,
        memoryFile: memoryFile,
        searchBackend: Fts5SearchBackend(memoryService: memory),
        selfImprovement: selfImprovement,
      );
      Directory('${tempDir.path}/learnings.md').createSync();

      await expectLater(
        learningHandlers.onSave({'text': 'must not be indexed', 'category': 'learning'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(db.select("SELECT * FROM memory_chunks WHERE category = 'learning'"), isEmpty);
    });

    test('reconciles capped learning rows to canonical content and timestamps', () async {
      final selfImprovement = SelfImprovementService(workspaceDir: tempDir.path, maxEntries: 3);
      addTearDown(selfImprovement.dispose);
      final learningHandlers = createMemoryHandlers(
        memory: memory,
        memoryFile: memoryFile,
        searchBackend: Fts5SearchBackend(memoryService: memory),
        selfImprovement: selfImprovement,
      );
      await learningHandlers.onSave({'text': 'Keep this preference', 'category': 'prefs'});
      Map<String, dynamic>? result;
      for (var i = 0; i < 4; i++) {
        result = await learningHandlers.onSave({'text': 'Learning $i', 'category': 'learning'});
      }

      expect(_text(result!), 'Saved 1 chunk(s) to memory.');
      final retainedEntries = parseMemoryEntries(await selfImprovement.readLearnings());
      final expectedRows = [
        for (final entry in retainedEntries)
          ...MemoryService.indexRows(
            text: entry.rawText,
            source: 'memory_save',
            category: 'learning',
            createdAt: entry.timestamp,
          ),
      ];
      final learningRows = db.select(
        "SELECT text, created_at FROM memory_chunks WHERE source = 'memory_save' AND category = 'learning' ORDER BY id",
      );

      expect(learningRows.map((row) => row['text']), expectedRows.map((row) => row.text));
      expect(learningRows.map((row) => row['created_at']), expectedRows.map((row) => row.createdAt.toIso8601String()));
      expect(learningRows.map((row) => row['text']), isNot(contains('Learning 0')));
      expect(memory.search('"preference"'), isNotEmpty);
    });

    test('capped learning saves preserve MEMORY.md learning rows across rebuild', () async {
      await handlers.onSave({'text': 'Learning stored in MEMORY', 'category': 'learning'});
      final selfImprovement = SelfImprovementService(workspaceDir: tempDir.path, maxEntries: 2);
      addTearDown(selfImprovement.dispose);
      final learningHandlers = createMemoryHandlers(
        memory: memory,
        memoryFile: memoryFile,
        searchBackend: Fts5SearchBackend(memoryService: memory),
        selfImprovement: selfImprovement,
      );
      for (var i = 0; i < 3; i++) {
        await learningHandlers.onSave({'text': 'Capped learning $i', 'category': 'learning'});
      }

      final liveRows = _indexRows(db);
      final memoryEntries = parseMemoryEntries(await memoryFile.readMemory());
      final learningEntries = parseMemoryEntries(await selfImprovement.readLearnings());
      memory.rebuildIndex([
        for (final entry in [...memoryEntries, ...learningEntries])
          ...MemoryService.indexRows(
            text: entry.rawText,
            source: 'memory_save',
            category: 'learning',
            createdAt: entry.timestamp,
          ),
      ]);

      expect(liveRows, unorderedEquals(_indexRows(db)));
      expect(memory.search('"MEMORY"'), hasLength(1));
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

    for (final (limit, expectedCount) in [(-100, 1), (1000000, 50), (double.maxFinite, 50)]) {
      test('clamps limit $limit to $expectedCount results', () async {
        for (var i = 0; i < 60; i++) {
          memory.insertChunk(text: 'Bounded result $i', source: 'test');
        }

        final result = await handlers.onSearch({'query': 'bounded', 'limit': limit});
        final lines = _text(result).split('\n').where((line) => line.startsWith('- [')).toList();

        expect(lines, hasLength(expectedCount));
      });
    }

    test('rejects a fractional limit', () async {
      await expectLater(handlers.onSearch({'query': 'anything', 'limit': 1.5}), throwsA(isA<ArgumentError>()));
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

List<(String, String, String?, String)> _indexRows(Database db) => db
    .select('SELECT text, source, category, created_at FROM memory_chunks')
    .map(
      (row) =>
          (row['text'] as String, row['source'] as String, row['category'] as String?, row['created_at'] as String),
    )
    .toList(growable: false);

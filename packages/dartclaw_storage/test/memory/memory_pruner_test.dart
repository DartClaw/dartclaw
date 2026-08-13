import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Database db;
  late MemoryService memoryService;
  late MemoryPruner pruner;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('memory_pruner_test');
    db = sqlite3.openInMemory();
    memoryService = MemoryService(db);
    pruner = MemoryPruner(workspaceDir: tempDir.path, memoryService: memoryService);
  });

  tearDown(() {
    db.close();
    tempDir.deleteSync(recursive: true);
  });

  void writeMemory(String content) {
    File('${tempDir.path}/MEMORY.md').writeAsStringSync(content);
  }

  String readMemory() {
    return File('${tempDir.path}/MEMORY.md').readAsStringSync();
  }

  String readArchive() {
    return File('${tempDir.path}/MEMORY.archive.md').readAsStringSync();
  }

  void seed({required String text, required String source, String? category, DateTime? createdAt}) {
    db.execute('INSERT INTO memory_chunks (text, source, category, created_at, locator) VALUES (?, ?, ?, ?, ?)', [
      text,
      source,
      category,
      (createdAt ?? DateTime(2026)).toIso8601String(),
      source,
    ]);
  }

  bool archiveExists() {
    return File('${tempDir.path}/MEMORY.archive.md').existsSync();
  }

  group('parseMemoryEntries', () {
    test('parses simple single-line entries with timestamps', () {
      final entries = parseMemoryEntries(
        '## general\n'
        '- [2026-01-15 10:30] User likes Dart\n'
        '- [2026-02-20 14:00] Prefer short responses\n',
      );

      expect(entries, hasLength(2));
      expect(entries[0].timestamp, DateTime(2026, 1, 15, 10, 30));
      expect(entries[0].rawText, 'User likes Dart');
      expect(entries[0].category, 'general');
      expect(entries[1].timestamp, DateTime(2026, 2, 20, 14, 0));
      expect(entries[1].rawText, 'Prefer short responses');
    });

    test('parses multi-line entries (continuation lines)', () {
      final entries = parseMemoryEntries(
        '## preferences\n'
        '- [2026-01-15 10:30] User likes Dart\n'
        '  and prefers AOT compilation\n'
        '  for production builds\n'
        '- [2026-02-20 14:00] Short responses\n',
      );

      expect(entries, hasLength(2));
      expect(entries[0].rawText, contains('AOT compilation'));
      expect(entries[0].rawText, contains('production builds'));
      expect(entries[0].rawBlock, contains('  and prefers AOT compilation'));
    });

    test('handles multiple categories', () {
      final entries = parseMemoryEntries(
        '## preferences\n'
        '- [2026-01-15 10:30] Likes Dart\n'
        '## workflow\n'
        '- [2026-02-20 14:00] Uses vim keybindings\n',
      );

      expect(entries, hasLength(2));
      expect(entries[0].category, 'preferences');
      expect(entries[1].category, 'workflow');
    });

    test('handles entries without timestamps as undated', () {
      final entries = parseMemoryEntries(
        '## general\n'
        '- [2026-01-15 10:30] Dated entry\n'
        '- [unknown] Undated entry\n',
      );

      expect(entries, hasLength(2));
      expect(entries[0].timestamp, isNotNull);
      expect(entries[1].timestamp, isNull);
    });

    test('returns empty list for empty content', () {
      expect(parseMemoryEntries(''), isEmpty);
      expect(parseMemoryEntries('   '), isEmpty);
    });

    test('returns empty list for file with only headers', () {
      final entries = parseMemoryEntries(
        '## preferences\n'
        '## workflow\n',
      );
      expect(entries, isEmpty);
    });
  });

  group('prune() integration', () {
    test('shared authority bootstraps canonical pruning while owned pruner stays legacy', () async {
      final sharedDir = Directory('${tempDir.path}/shared')..createSync();
      final sharedDb = sqlite3.openInMemory();
      addTearDown(sharedDb.close);
      final authority = MemoryCorpusService(workspaceDir: sharedDir.path);
      final shared = MemoryPruner(
        workspaceDir: sharedDir.path,
        memoryService: MemoryService(sharedDb),
        corpusService: authority,
      );

      await shared.prune();
      writeMemory('## general\n');
      await pruner.prune();

      expect(File('${sharedDir.path}/MEMORY.md').readAsStringSync(), startsWith('# DartClaw Canonical Memory\n'));
      expect(readMemory(), '## general\n');
      await authority.close();
    });

    test('no-op when MEMORY.md does not exist', () async {
      final result = await pruner.prune();
      expect(result.entriesArchived, 0);
      expect(result.duplicatesRemoved, 0);
      expect(result.entriesRemaining, 0);
    });

    test('missing workspace clears stale canonical index rows', () async {
      final removedWorkspace = Directory('${tempDir.path}/removed')..createSync();
      final removedPruner = MemoryPruner(workspaceDir: removedWorkspace.path, memoryService: memoryService);
      await removedPruner.prune();
      seed(text: 'Stale active fact', source: 'legacy-memory');
      seed(text: 'Stale archived fact', source: 'archive');
      seed(text: 'Unrelated indexed fact', source: 'wiki');
      removedWorkspace.deleteSync();

      await removedPruner.prune();

      expect(memoryService.search('"Stale"'), isEmpty);
      expect(memoryService.search('"Unrelated"').single.source, 'wiki');
    });

    test('missing MEMORY.md still reconciles archive and learning index rows', () async {
      File(
        '${tempDir.path}/MEMORY.archive.md',
      ).writeAsStringSync('## project\n- [2025-01-10 09:00] Canonical archived fact\n');
      File('${tempDir.path}/learnings.md').writeAsStringSync('- [2026-08-10 10:00] Canonical learning fact\n');
      seed(text: 'Stale active fact', source: 'legacy-memory');

      await pruner.prune();

      expect(File('${tempDir.path}/MEMORY.md').existsSync(), isFalse);
      expect(memoryService.search('"Stale"'), isEmpty);
      expect(memoryService.search('"archived"').single.source, 'legacy-archive');
      final learning = memoryService.search('"learning"').single;
      expect(learning.source, 'legacy-learning');
      expect(learning.category, 'learning');
    });

    test('no-op when MEMORY.md is empty', () async {
      writeMemory('');
      final result = await pruner.prune();
      expect(result.entriesArchived, 0);
      expect(result.duplicatesRemoved, 0);
    });

    test('whitespace-only memory reports its exact UTF-8 size', () async {
      const content = ' \r\n\t';
      writeMemory(content);

      final result = await pruner.prune();

      expect(readMemory(), content);
      expect(result.finalSizeBytes, utf8.encode(content).length);
    });

    test('opaque-only memory reports its exact UTF-8 size', () async {
      const content = '# Hand-written memory\n\nRemember smörgåsbord.\n';
      writeMemory(content);

      final result = await pruner.prune();

      expect(readMemory(), content);
      expect(result.finalSizeBytes, utf8.encode(content).length);
    });

    test('archives old entries and preserves legacy duplicate text', () async {
      final oldDate = DateTime.now().subtract(const Duration(days: 120));
      final recentDate = DateTime.now().subtract(const Duration(days: 5));
      final oldStr =
          '${oldDate.year}-${oldDate.month.toString().padLeft(2, '0')}-${oldDate.day.toString().padLeft(2, '0')} '
          '${oldDate.hour.toString().padLeft(2, '0')}:${oldDate.minute.toString().padLeft(2, '0')}';
      final recentStr =
          '${recentDate.year}-${recentDate.month.toString().padLeft(2, '0')}-${recentDate.day.toString().padLeft(2, '0')} '
          '${recentDate.hour.toString().padLeft(2, '0')}:${recentDate.minute.toString().padLeft(2, '0')}';

      writeMemory(
        '## general\n'
        '- [$oldStr] Old entry to archive\n'
        '- [$recentStr] Recent entry to keep\n'
        '- [$recentStr] Recent entry to keep\n', // duplicate
      );

      final result = await pruner.prune();
      expect(result.entriesArchived, 1);
      expect(result.duplicatesRemoved, 0);
      expect(result.entriesRemaining, 2);

      final remaining = readMemory();
      expect(remaining, contains('Recent entry to keep'));
      expect(remaining, isNot(contains('Old entry to archive')));

      // Archive should exist with the old entry
      expect(archiveExists(), isTrue);
      final archived = readArchive();
      expect(archived, contains('Old entry to archive'));
      expect(parseMemoryEntries(archived).single.category, 'general');
    });

    test('preserves opaque content while pruning recognized entries', () async {
      final oldDate = DateTime.now().subtract(const Duration(days: 120));
      final recentDate = DateTime.now().subtract(const Duration(days: 5));
      final oldStr =
          '${oldDate.year}-${oldDate.month.toString().padLeft(2, '0')}-${oldDate.day.toString().padLeft(2, '0')} '
          '${oldDate.hour.toString().padLeft(2, '0')}:${oldDate.minute.toString().padLeft(2, '0')}';
      final recentStr =
          '${recentDate.year}-${recentDate.month.toString().padLeft(2, '0')}-${recentDate.day.toString().padLeft(2, '0')} '
          '${recentDate.hour.toString().padLeft(2, '0')}:${recentDate.minute.toString().padLeft(2, '0')}';
      const title = '# Curated memory\n\nThis introduction explains the file.\n\n';
      const manualSection = '## Hand-written notes\n- Keep this plain bullet\n\n---\n\n';
      writeMemory(
        '$title'
        '## general\n'
        '- [$oldStr] Old entry to archive\n'
        '  First detail\n'
        '  \n'
        '  Second detail\n'
        '- [$recentStr] Recent entry to keep\n\n'
        '$manualSection',
      );

      final result = await pruner.prune();

      expect(result.entriesArchived, 1);
      expect(readMemory(), contains(title));
      expect(readMemory(), contains(manualSection));
      expect(readMemory(), contains('Recent entry to keep'));
      expect(readMemory(), isNot(contains('Old entry to archive')));
      expect(readArchive(), contains('Old entry to archive'));
      expect(readArchive(), contains('First detail\n  \n  Second detail'));
    });

    test('does not mistake an inline entry quotation for the parsed source block', () async {
      final oldDate = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${oldDate.year}-${oldDate.month.toString().padLeft(2, '0')}-${oldDate.day.toString().padLeft(2, '0')} '
          '${oldDate.hour.toString().padLeft(2, '0')}:${oldDate.minute.toString().padLeft(2, '0')}';
      final entry = '- [$oldStr] Old entry to archive';
      final quotation = 'Historical example: $entry';
      writeMemory('$quotation\n\n## general\n$entry\n');

      final result = await pruner.prune();

      expect(result.entriesArchived, 1);
      expect(readMemory(), '$quotation\n\n## general\n');
      expect(readArchive(), contains(entry));

      final secondResult = await pruner.prune();
      expect(secondResult.entriesArchived, 0);
      expect(entry.allMatches(readArchive()), hasLength(1));
    });

    test('preserves fenced examples and CRLF while removing adjacent parsed entries', () async {
      final oldDate = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${oldDate.year}-${oldDate.month.toString().padLeft(2, '0')}-${oldDate.day.toString().padLeft(2, '0')} '
          '${oldDate.hour.toString().padLeft(2, '0')}:${oldDate.minute.toString().padLeft(2, '0')}';
      final entry = '- [$oldStr] Old entry';
      final content = '# Examples\r\n```markdown\r\n$entry\r\n```\r\n## general\r\n$entry\r\n$entry\r\n';
      writeMemory(content);

      final result = await pruner.prune();

      expect(result.entriesArchived, 2);
      expect(result.duplicatesRemoved, 0);
      expect(readMemory(), '# Examples\r\n```markdown\r\n$entry\r\n```\r\n## general\r\n');
      expect(entry.allMatches(readArchive()), hasLength(2));
    });

    test('archived entries indexed in FTS5', () async {
      final oldDate = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${oldDate.year}-${oldDate.month.toString().padLeft(2, '0')}-${oldDate.day.toString().padLeft(2, '0')} '
          '${oldDate.hour.toString().padLeft(2, '0')}:${oldDate.minute.toString().padLeft(2, '0')}';

      writeMemory(
        '## general\n'
        '- [$oldStr] Archived searchable entry\n',
      );

      await pruner.prune();

      final results = memoryService.search('searchable');
      expect(results, hasLength(1));
      expect(results[0].source, 'legacy-archive');
    });

    test('archive index uses canonical normalized rows and source timestamp', () async {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final timestamp = DateTime(old.year, old.month, old.day, old.hour, old.minute);
      final oldStr =
          '${old.year}-${old.month.toString().padLeft(2, '0')}-${old.day.toString().padLeft(2, '0')} '
          '${old.hour.toString().padLeft(2, '0')}:${old.minute.toString().padLeft(2, '0')}';
      final longTail = List.generate(90, (index) => 'segment$index').join(' ');
      final expected = MemoryService.indexRows(
        text: '**Archived heading**\n\n$longTail',
        source: 'legacy-archive',
        category: 'project',
        createdAt: timestamp,
      );
      writeMemory('## project\n- [$oldStr] **Archived heading**\n  \n  $longTail\n');

      await pruner.prune();

      final rows = db.select('SELECT text, source, category, created_at FROM memory_chunks ORDER BY id');
      expect(rows.map((row) => row['text']), expected.map((row) => row.text));
      expect(rows.every((row) => row['source'] == 'legacy-archive' && row['category'] == 'project'), isTrue);
      expect(rows.map((row) => row['created_at']).toSet(), {timestamp.toIso8601String()});
    });

    test('reconciles live rows to the complete canonical post-prune index', () async {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final recent = DateTime.now().subtract(const Duration(days: 5));
      String timestamp(DateTime value) =>
          '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
          '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
      final source =
          '## general\n'
          '- [${timestamp(old)}] Archived live fact\n'
          '- [${timestamp(recent)}] Recent duplicate fact\n'
          '- [${timestamp(recent)}] Recent duplicate fact\n';
      const learnings = '- [2026-02-23 10:00] Retained learning fact\n';
      writeMemory(source);
      File('${tempDir.path}/learnings.md').writeAsStringSync(learnings);
      for (final entry in parseMemoryEntries(source)) {
        for (final row in MemoryService.indexRows(
          text: entry.rawText,
          source: 'legacy-memory',
          category: entry.category,
          createdAt: entry.timestamp,
        )) {
          seed(text: row.text, source: row.source, category: row.category, createdAt: row.createdAt);
        }
      }
      final learning = parseMemoryEntries(learnings).single;
      final learningRow = MemoryService.indexRows(
        text: learning.rawText,
        source: 'legacy-learning',
        category: 'learning',
        createdAt: learning.timestamp,
      ).single;
      seed(
        text: learningRow.text,
        source: learningRow.source,
        category: learningRow.category,
        createdAt: learningRow.createdAt,
      );
      seed(text: 'Independent source fact', source: 'other');

      await pruner.prune();

      expect(memoryService.search('"Archived"'), hasLength(1));
      expect(memoryService.search('"Archived"').single.source, 'legacy-archive');
      expect(memoryService.search('"Recent"'), hasLength(2));
      expect(
        memoryService.search('"Recent"'),
        everyElement(isA<MemorySearchResult>().having((row) => row.source, 'source', 'legacy-memory')),
      );
      expect(memoryService.search('"Retained"'), hasLength(1));
      expect(memoryService.search('"Retained"').single.category, 'learning');
      expect(memoryService.search('"Independent"'), hasLength(1));
    });

    test('no-change retry repairs the post-file pre-index crash state', () async {
      const active = '## general\n';
      const archive = '## general\n- [2025-01-10 09:00] Crash-recovered archive fact\n';
      writeMemory(active);
      File('${tempDir.path}/MEMORY.archive.md').writeAsStringSync(archive);
      seed(
        text: 'Crash-recovered archive fact',
        source: 'legacy-archive',
        category: 'general',
        createdAt: DateTime(2025, 1, 10, 9),
      );
      seed(text: 'Stale deleted fact', source: 'legacy-memory', category: 'general');

      await pruner.prune();

      final rebuiltDb = sqlite3.openInMemory();
      addTearDown(rebuiltDb.close);
      final rebuilt = MemoryService(rebuiltDb);
      rebuilt.rebuildIndex([
        for (final entry in parseMemoryEntries(active))
          ...MemoryService.indexRows(
            text: entry.rawText,
            source: 'legacy-memory',
            category: entry.category,
            createdAt: entry.timestamp,
          ),
        for (final entry in parseMemoryEntries(archive))
          ...MemoryService.indexRows(
            text: entry.rawText,
            source: 'legacy-archive',
            category: entry.category,
            createdAt: entry.timestamp,
          ),
      ]);

      expect(_indexRows(db), unorderedEquals(_indexRows(rebuiltDb)));
    });

    test('all recent legacy entries remain distinct', () async {
      final recent = DateTime.now().subtract(const Duration(days: 5));
      final recentStr =
          '${recent.year}-${recent.month.toString().padLeft(2, '0')}-${recent.day.toString().padLeft(2, '0')} '
          '${recent.hour.toString().padLeft(2, '0')}:${recent.minute.toString().padLeft(2, '0')}';

      writeMemory(
        '## general\n'
        '- [$recentStr] Entry A\n'
        '- [$recentStr] Entry A\n'
        '- [$recentStr] Entry B\n',
      );

      final result = await pruner.prune();
      expect(result.entriesArchived, 0);
      expect(result.duplicatesRemoved, 0);
      expect(result.entriesRemaining, 3);
      expect(archiveExists(), isFalse);
    });

    test('all entries old means all archived except undated', () async {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${old.year}-${old.month.toString().padLeft(2, '0')}-${old.day.toString().padLeft(2, '0')} '
          '${old.hour.toString().padLeft(2, '0')}:${old.minute.toString().padLeft(2, '0')}';

      writeMemory(
        '## general\n'
        '- [$oldStr] Old entry A\n'
        '- [$oldStr] Old entry B\n',
      );

      final result = await pruner.prune();
      expect(result.entriesArchived, 2);
      expect(result.entriesRemaining, 0);
    });

    test('atomic replacement leaves no randomized temporary file', () async {
      final recent = DateTime.now().subtract(const Duration(days: 5));
      final recentStr =
          '${recent.year}-${recent.month.toString().padLeft(2, '0')}-${recent.day.toString().padLeft(2, '0')} '
          '${recent.hour.toString().padLeft(2, '0')}:${recent.minute.toString().padLeft(2, '0')}';

      writeMemory(
        '## general\n'
        '- [$recentStr] Entry\n'
        '- [$recentStr] Entry\n',
      );

      await pruner.prune();

      expect(readMemory(), '## general\n- [$recentStr] Entry\n- [$recentStr] Entry\n');
      expect(tempDir.listSync().where((entry) => entry.path.endsWith('.tmp')), isEmpty);
    });

    test('archive is append-only across multiple prunes', () async {
      final old1 = DateTime.now().subtract(const Duration(days: 120));
      final old2 = DateTime.now().subtract(const Duration(days: 150));
      final old1Str =
          '${old1.year}-${old1.month.toString().padLeft(2, '0')}-${old1.day.toString().padLeft(2, '0')} '
          '${old1.hour.toString().padLeft(2, '0')}:${old1.minute.toString().padLeft(2, '0')}';
      final old2Str =
          '${old2.year}-${old2.month.toString().padLeft(2, '0')}-${old2.day.toString().padLeft(2, '0')} '
          '${old2.hour.toString().padLeft(2, '0')}:${old2.minute.toString().padLeft(2, '0')}';

      // First prune
      writeMemory(
        '## general\n'
        '- [$old1Str] First old entry\n',
      );
      await pruner.prune();

      // Second prune with new old entry
      writeMemory(
        '## general\n'
        '- [$old2Str] Second old entry\n',
      );
      await pruner.prune();

      final archived = readArchive();
      expect(archived, contains('First old entry'));
      expect(archived, contains('Second old entry'));
    });

    test('archive preserves categories and remains idempotent', () async {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${old.year}-${old.month.toString().padLeft(2, '0')}-${old.day.toString().padLeft(2, '0')} '
          '${old.hour.toString().padLeft(2, '0')}:${old.minute.toString().padLeft(2, '0')}';
      final sharedBlock = '- [$oldStr] Shared fact';
      writeMemory('## preferences\n$sharedBlock\n');
      await pruner.prune();

      writeMemory('## project\n$sharedBlock\n');
      await pruner.prune();

      final firstArchive = readArchive();
      final entries = parseMemoryEntries(firstArchive);
      expect(entries.map((entry) => entry.category), ['preferences', 'project']);
      expect(memoryService.search('Shared').map((entry) => entry.category).toSet(), {'preferences', 'project'});

      writeMemory('## project\n$sharedBlock\n');
      await pruner.prune();

      expect(readArchive(), firstArchive);
      expect(memoryService.search('Shared'), hasLength(2));
    });

    test('source write failure retries without duplicate archive or index entries', () async {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${old.year}-${old.month.toString().padLeft(2, '0')}-${old.day.toString().padLeft(2, '0')} '
          '${old.hour.toString().padLeft(2, '0')}:${old.minute.toString().padLeft(2, '0')}';
      final entry = '- [$oldStr] Retry-safe archived entry';
      final source = '## general\n$entry\n';
      writeMemory(source);
      var failSourceWrite = true;
      pruner = MemoryPruner(
        workspaceDir: tempDir.path,
        memoryService: memoryService,
        writeFileForTesting: (target, contents) {
          if (target.path.endsWith('MEMORY.md') && failSourceWrite) {
            failSourceWrite = false;
            throw FileSystemException('injected source write failure', target.path);
          }
          secureWriteFileSync(target, contents);
        },
      );

      await expectLater(pruner.prune(), throwsA(isA<FileSystemException>()));

      expect(readMemory(), source);
      expect(archiveExists(), isFalse);
      expect(memoryService.search('Retry'), isEmpty);

      final result = await pruner.prune();

      expect(result.entriesArchived, 1);
      expect(readMemory(), '## general\n');
      expect(entry.allMatches(readArchive()), hasLength(1));
      expect(memoryService.search('Retry'), hasLength(1));
    });

    test('index failure leaves source retryable and retry creates one archive index row', () async {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${old.year}-${old.month.toString().padLeft(2, '0')}-${old.day.toString().padLeft(2, '0')} '
          '${old.hour.toString().padLeft(2, '0')}:${old.minute.toString().padLeft(2, '0')}';
      final entry = '- [$oldStr] Index retry fact';
      final source = '## general\n$entry\n';
      writeMemory(source);
      memoryService = _FailingMemoryService(db);
      pruner = MemoryPruner(workspaceDir: tempDir.path, memoryService: memoryService);

      await expectLater(pruner.prune(), throwsStateError);

      expect(readMemory(), source);
      expect(archiveExists(), isFalse);
      expect(memoryService.search('Index'), isEmpty);

      await pruner.prune();

      expect(readMemory(), '## general\n');
      expect(entry.allMatches(readArchive()), hasLength(1));
      expect(memoryService.search('Index'), hasLength(1));
    });

    test('canonical prune remains committed when derived index reconciliation fails', () async {
      final old = DateTime.now().toUtc().subtract(const Duration(days: 120));
      CanonicalMemoryEntry detail(String id, String content) => CanonicalMemoryEntry(
        id: id,
        revision: 1,
        topic: 'general',
        summary: content,
        content: content,
        created: old,
        updated: old,
        provenance: MemorySourceRef(sourceLocator: 'test'),
      );
      final entries = [
        detail('6fda91a3-f1b4-46c2-acd6-5bb4d13c13b9', 'Durable canonical prune'),
        detail('2277cbfe-f704-46eb-ac2f-08ca4a7ad620', 'Durable   canonical\nprune'),
        detail('c402a342-18be-4810-9887-cf4654c845fd', 'durable canonical prune'),
      ];
      final corpus = CanonicalMemoryCorpus(
        index: MemoryIndexDocument(
          metadata: MemoryCollectionMetadata(collectionId: '07f35d89-16c1-4864-8385-7b0ed720479a', revision: 8),
          entries: [
            for (final entry in entries)
              MemoryIndexEntry(
                id: entry.id,
                revision: entry.revision,
                topic: entry.topic,
                summary: entry.summary,
                updated: entry.updated,
              ),
          ],
        ),
        topics: [MemoryTopicDocument(topic: 'general', entries: entries)],
        archive: MemoryArchiveDocument(),
      );
      for (final member in corpus.byteInventory().entries) {
        final file = File('${tempDir.path}/${member.key}');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(member.value);
      }
      memoryService = _FailingMemoryService(db);
      final authority = MemoryCorpusService(workspaceDir: tempDir.path);
      pruner = MemoryPruner(workspaceDir: tempDir.path, memoryService: memoryService, corpusService: authority);

      final result = await pruner.prune();
      expect(result.entriesArchived, 3);

      final snapshot = await authority.snapshot(
        paths: const ['MEMORY.md', 'MEMORY.archive.md', 'memory/topics/general.md'],
        maxDocuments: 3,
        maxBytes: 1024 * 1024,
      );
      expect(snapshot.collectionRevision, 9);
      expect(snapshot.documents, isNot(contains('memory/topics/general.md')));
      final archive = const MemoryMarkdownCodec().parse(utf8.decode(snapshot.documents['MEMORY.archive.md']!));
      expect(archive, isA<MemoryArchiveDocument>().having((document) => document.entries.length, 'all records', 3));
      expect(memoryService.search('Durable'), hasLength(3));
      await authority.close();
    });

    test('canonical prune preserves equal content with distinct identity and provenance', () async {
      final recent = DateTime.now().toUtc().subtract(const Duration(days: 2));
      CanonicalMemoryEntry detail({required String id, required String topic, required String event}) =>
          CanonicalMemoryEntry(
            id: id,
            revision: 1,
            topic: topic,
            summary: 'Shared fact',
            content: 'The same remembered content.',
            created: recent,
            updated: recent,
            provenance: MemorySourceRef(
              originKind: MemoryOriginKind.turn,
              sourceLocator: 'session/example',
              sourceEvent: event,
              caller: 'assistant',
              sessionRef: 'example',
            ),
          );
      final entries = [
        detail(id: '6fda91a3-f1b4-46c2-acd6-5bb4d13c13b9', topic: 'preferences', event: 'message-1'),
        detail(id: '2277cbfe-f704-46eb-ac2f-08ca4a7ad620', topic: 'workflow', event: 'message-2'),
      ];
      final corpus = CanonicalMemoryCorpus(
        index: MemoryIndexDocument(
          metadata: MemoryCollectionMetadata(collectionId: '07f35d89-16c1-4864-8385-7b0ed720479a', revision: 1),
          entries: [
            for (final entry in entries)
              MemoryIndexEntry(
                id: entry.id,
                revision: entry.revision,
                topic: entry.topic,
                summary: entry.summary,
                updated: entry.updated,
              ),
          ],
        ),
        topics: [
          MemoryTopicDocument(topic: 'preferences', entries: [entries.first]),
          MemoryTopicDocument(topic: 'workflow', entries: [entries.last]),
        ],
      );
      for (final member in corpus.byteInventory().entries) {
        final file = File('${tempDir.path}/${member.key}');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(member.value);
      }
      final authority = MemoryCorpusService(workspaceDir: tempDir.path);
      pruner = MemoryPruner(workspaceDir: tempDir.path, memoryService: memoryService, corpusService: authority);

      final result = await pruner.prune();
      final after = await authority.readCorpus();

      expect(result.duplicatesRemoved, 0);
      expect(
        after.topics.expand((topic) => topic.entries).map((entry) => entry.id),
        unorderedEquals(entries.map((entry) => entry.id)),
      );
      await authority.close();
    });

    test('canonical prune keeps earliest exact replay and audits each collapsed entry', () async {
      final now = DateTime.now().toUtc().subtract(const Duration(days: 2));
      final provenance = MemorySourceRef(
        originKind: MemoryOriginKind.turn,
        sourceLocator: 'session/example',
        sourceEvent: 'turn-42/message-3',
        caller: 'chat',
        sessionRef: 'example',
      );
      final entries = [
        for (var index = 0; index < 3; index++)
          CanonicalMemoryEntry(
            id: [
              '6fda91a3-f1b4-46c2-acd6-5bb4d13c13b9',
              '2277cbfe-f704-46eb-ac2f-08ca4a7ad620',
              'c402a342-18be-4810-9887-cf4654c845fd',
            ][index],
            revision: 1,
            topic: 'preferences',
            summary: 'Shared fact',
            content: index == 1 ? '  The  same\n fact. ' : 'The same fact.',
            created: now.add(Duration(minutes: index)),
            updated: now.add(Duration(minutes: index)),
            provenance: provenance,
          ),
      ];
      final corpus = CanonicalMemoryCorpus(
        index: MemoryIndexDocument(
          metadata: MemoryCollectionMetadata(collectionId: '07f35d89-16c1-4864-8385-7b0ed720479a', revision: 1),
          entries: [
            for (final entry in entries)
              MemoryIndexEntry(
                id: entry.id,
                revision: 1,
                topic: entry.topic,
                summary: entry.summary,
                updated: entry.updated,
              ),
          ],
        ),
        topics: [MemoryTopicDocument(topic: 'preferences', entries: entries)],
      );
      for (final member in corpus.byteInventory().entries) {
        final file = File('${tempDir.path}/${member.key}');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(member.value);
      }
      final authority = MemoryCorpusService(workspaceDir: tempDir.path);
      pruner = MemoryPruner(workspaceDir: tempDir.path, memoryService: memoryService, corpusService: authority);

      final result = await pruner.prune();
      final after = await authority.readCorpus();

      expect(result.duplicatesRemoved, 2);
      expect(after.index.metadata.revision, 2);
      expect(after.topics.single.entries.single.id, entries.first.id);
      expect(
        after.audit!.records.map((record) => record.entryId),
        unorderedEquals(entries.skip(1).map((entry) => entry.id)),
      );
      expect(
        after.audit!.records,
        everyElement(
          isA<MemoryDeletionAudit>().having((record) => record.reason, 'reason', isNot(contains('same fact'))),
        ),
      );
      await authority.close();
    });

    test('prune waits for the canonical memory write lock', () async {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${old.year}-${old.month.toString().padLeft(2, '0')}-${old.day.toString().padLeft(2, '0')} '
          '${old.hour.toString().padLeft(2, '0')}:${old.minute.toString().padLeft(2, '0')}';
      final source = '## general\n- [$oldStr] Old fact\n';
      writeMemory(source);
      final entered = Completer<void>();
      final release = Completer<void>();
      final maintenance = RepoLock().acquire('${tempDir.resolveSymbolicLinksSync()}/MEMORY.md', () async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      var pruneCompleted = false;

      final pendingPrune = Zone.root.run(
        () => pruner.prune().then((result) {
          pruneCompleted = true;
          return result;
        }),
      );
      await pumpEventQueue(times: 20);

      expect(pruneCompleted, isFalse);
      expect(readMemory(), source);
      expect(archiveExists(), isFalse);

      release.complete();
      await maintenance;
      await pendingPrune;
      expect(readMemory(), isNot(contains('Old fact')));
      expect(readArchive(), contains('Old fact'));
    });

    test('propagates archive write failures without mutating MEMORY.md', () async {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${old.year}-${old.month.toString().padLeft(2, '0')}-${old.day.toString().padLeft(2, '0')} '
          '${old.hour.toString().padLeft(2, '0')}:${old.minute.toString().padLeft(2, '0')}';
      final source = '## general\n- [$oldStr] Must remain active\n';
      writeMemory(source);
      pruner = MemoryPruner(
        workspaceDir: tempDir.path,
        memoryService: memoryService,
        writeFileForTesting: (target, contents) {
          if (target.path.endsWith('MEMORY.archive.md')) {
            throw FileSystemException('injected archive write failure', target.path);
          }
          secureWriteFileSync(target, contents);
        },
      );

      await expectLater(pruner.prune(), throwsA(isA<FileSystemException>()));

      expect(readMemory(), source);
      expect(archiveExists(), isFalse);
      expect(memoryService.search('remain'), isEmpty);
    });

    test('rejects an unclosed archive fence before mutating MEMORY.md', () async {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${old.year}-${old.month.toString().padLeft(2, '0')}-${old.day.toString().padLeft(2, '0')} '
          '${old.hour.toString().padLeft(2, '0')}:${old.minute.toString().padLeft(2, '0')}';
      final source = '## general\n- [$oldStr] Must remain active\n';
      final archive =
          '## general\n'
          '- [2020-01-01 00:00] Existing archive fact\n'
          '```markdown\n'
          '- [2020-01-01 00:00] fenced example\n';
      writeMemory(source);
      File('${tempDir.path}/MEMORY.archive.md').writeAsStringSync(archive);

      await expectLater(pruner.prune(), throwsFormatException);

      expect(readMemory(), source);
      expect(readArchive(), archive);
      expect(memoryService.search('remain'), isEmpty);
    });

    test('retry with no new archive entries ignores an unrelated unclosed fence', () async {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${old.year}-${old.month.toString().padLeft(2, '0')}-${old.day.toString().padLeft(2, '0')} '
          '${old.hour.toString().padLeft(2, '0')}:${old.minute.toString().padLeft(2, '0')}';
      final entry = '- [$oldStr] Already archived fact';
      final source = '## general\n$entry\n';
      writeMemory(source);
      File('${tempDir.path}/MEMORY.archive.md').writeAsStringSync('$source\n```markdown\nunrelated opaque tail\n');

      final result = await pruner.prune();

      expect(result.entriesArchived, 1);
      expect(readMemory(), '## general\n');
      expect(entry.allMatches(readArchive()), hasLength(1));
      expect(memoryService.search('Already'), hasLength(1));
    });

    test('rejects a symlinked MEMORY.md without changing its target', () async {
      final external = File('${tempDir.path}/external-memory.md')..writeAsStringSync('external content');
      Link('${tempDir.path}/MEMORY.md').createSync(external.path);

      await expectLater(pruner.prune(), throwsA(isA<FileSystemException>()));

      expect(external.readAsStringSync(), 'external content');
      expect(archiveExists(), isFalse);
    }, skip: Platform.isWindows);

    test('rejects a symlinked archive and leaves source and target unchanged', () async {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${old.year}-${old.month.toString().padLeft(2, '0')}-${old.day.toString().padLeft(2, '0')} '
          '${old.hour.toString().padLeft(2, '0')}:${old.minute.toString().padLeft(2, '0')}';
      final source = '## general\n- [$oldStr] Must stay in source\n';
      writeMemory(source);
      final external = File('${tempDir.path}/external-archive.md')..writeAsStringSync('external content');
      Link('${tempDir.path}/MEMORY.archive.md').createSync(external.path);

      await expectLater(pruner.prune(), throwsA(isA<FileSystemException>()));

      expect(readMemory(), source);
      expect(external.readAsStringSync(), 'external content');
    }, skip: Platform.isWindows);

    test('rejects a non-regular archive and leaves MEMORY.md unchanged', () async {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final oldStr =
          '${old.year}-${old.month.toString().padLeft(2, '0')}-${old.day.toString().padLeft(2, '0')} '
          '${old.hour.toString().padLeft(2, '0')}:${old.minute.toString().padLeft(2, '0')}';
      final source = '## general\n- [$oldStr] Must stay in source\n';
      writeMemory(source);
      Directory('${tempDir.path}/MEMORY.archive.md').createSync();

      await expectLater(pruner.prune(), throwsA(isA<FileSystemException>()));

      expect(readMemory(), source);
    });
  });

  group('config defaults', () {
    test('DartclawConfig has pruning defaults', () {
      final config = DartclawConfig.load(configPath: '/nonexistent');
      expect(config.memory.pruningEnabled, isTrue);
      expect(config.memory.archiveAfterDays, 90);
      expect(config.memory.pruningSchedule, '0 3 * * *');
    });

    test('DartclawConfig parses pruning overrides from YAML', () {
      final yamlContent = '''
memory:
  pruning:
    enabled: false
    archive_after_days: 30
    schedule: "0 6 * * 1"
''';
      final configFile = File('${tempDir.path}/dartclaw.yaml');
      configFile.writeAsStringSync(yamlContent);

      final config = DartclawConfig.load(configPath: configFile.path);
      expect(config.memory.pruningEnabled, isFalse);
      expect(config.memory.archiveAfterDays, 30);
      expect(config.memory.pruningSchedule, '0 6 * * 1');
    });
  });
}

final class _FailingMemoryService extends MemoryService {
  var failNextReplacement = true;

  _FailingMemoryService(super.db);

  @override
  void replaceMemoryRows(Iterable<MemoryIndexRow> rows, {String userId = 'owner'}) {
    if (failNextReplacement) {
      failNextReplacement = false;
      throw StateError('injected index failure');
    }
    super.replaceMemoryRows(rows, userId: userId);
  }
}

List<(String, String, String?, String)> _indexRows(Database db) => db
    .select('SELECT text, source, category, created_at FROM memory_chunks')
    .map(
      (row) =>
          (row['text'] as String, row['source'] as String, row['category'] as String?, row['created_at'] as String),
    )
    .toList(growable: false);

import 'dart:io';

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
    pruner = MemoryPruner(
      workspaceDir: tempDir.path,
      memoryService: memoryService,
    );
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

  group('removeDuplicates', () {
    test('removes exact duplicate entries keeping newest', () {
      final entries = [
        MemoryEntry(
          timestamp: DateTime(2026, 1, 15),
          category: 'general',
          rawText: 'User likes Dart',
          rawBlock: '- [2026-01-15 00:00] User likes Dart',
        ),
        MemoryEntry(
          timestamp: DateTime(2026, 3, 20),
          category: 'general',
          rawText: 'User likes Dart',
          rawBlock: '- [2026-03-20 00:00] User likes Dart',
        ),
      ];

      final result = pruner.removeDuplicates(entries);
      expect(result, hasLength(1));
      expect(result[0].timestamp, DateTime(2026, 3, 20));
    });

    test('keeps entries with different text', () {
      final entries = [
        MemoryEntry(
          timestamp: DateTime(2026, 1, 15),
          category: 'general',
          rawText: 'User likes Dart',
          rawBlock: '- [2026-01-15 00:00] User likes Dart',
        ),
        MemoryEntry(
          timestamp: DateTime(2026, 3, 20),
          category: 'general',
          rawText: 'User likes Python',
          rawBlock: '- [2026-03-20 00:00] User likes Python',
        ),
      ];

      final result = pruner.removeDuplicates(entries);
      expect(result, hasLength(2));
    });

    test('undated entries treated as newest (never removed)', () {
      final entries = [
        MemoryEntry(
          timestamp: DateTime(2026, 3, 20),
          category: 'general',
          rawText: 'User likes Dart',
          rawBlock: '- [2026-03-20 00:00] User likes Dart',
        ),
        MemoryEntry.undated(
          category: 'general',
          rawText: 'User likes Dart',
          rawBlock: '- User likes Dart',
        ),
      ];

      final result = pruner.removeDuplicates(entries);
      expect(result, hasLength(1));
      // Undated entry kept (treated as newest)
      expect(result[0].timestamp, isNull);
    });

    test('normalization collapses whitespace for comparison', () {
      final entries = [
        MemoryEntry(
          timestamp: DateTime(2026, 1, 15),
          category: 'general',
          rawText: 'User  likes   Dart',
          rawBlock: '- [2026-01-15 00:00] User  likes   Dart',
        ),
        MemoryEntry(
          timestamp: DateTime(2026, 3, 20),
          category: 'general',
          rawText: 'User likes Dart',
          rawBlock: '- [2026-03-20 00:00] User likes Dart',
        ),
      ];

      final result = pruner.removeDuplicates(entries);
      expect(result, hasLength(1));
    });
  });

  group('partitionByAge', () {
    test('old entries go to archive list', () {
      final old = MemoryEntry(
        timestamp: DateTime.now().subtract(const Duration(days: 120)),
        category: 'general',
        rawText: 'Old entry',
        rawBlock: '- [old] Old entry',
      );
      final recent = MemoryEntry(
        timestamp: DateTime.now().subtract(const Duration(days: 10)),
        category: 'general',
        rawText: 'Recent entry',
        rawBlock: '- [recent] Recent entry',
      );

      final (:keep, :archive) = pruner.partitionByAge([old, recent], 90);
      expect(keep, hasLength(1));
      expect(keep[0].rawText, 'Recent entry');
      expect(archive, hasLength(1));
      expect(archive[0].rawText, 'Old entry');
    });

    test('undated entries always stay in keep list', () {
      final undated = MemoryEntry.undated(
        category: 'general',
        rawText: 'Undated entry',
        rawBlock: '- Undated entry',
      );

      final (:keep, :archive) = pruner.partitionByAge([undated], 90);
      expect(keep, hasLength(1));
      expect(archive, isEmpty);
    });

    test('entries just inside threshold stay (not archived)', () {
      // Use 89 days ago — clearly inside the 90-day window
      final justInside = MemoryEntry(
        timestamp: DateTime.now().subtract(const Duration(days: 89)),
        category: 'general',
        rawText: 'Boundary entry',
        rawBlock: '- [boundary] Boundary entry',
      );

      final (:keep, :archive) = pruner.partitionByAge([justInside], 90);
      expect(keep, hasLength(1));
      expect(archive, isEmpty);
    });
  });

  group('reconstructMemoryMd', () {
    test('groups entries by category with headers', () {
      final entries = [
        MemoryEntry(
          timestamp: DateTime(2026, 1, 15),
          category: 'preferences',
          rawText: 'Likes Dart',
          rawBlock: '- [2026-01-15 00:00] Likes Dart',
        ),
        MemoryEntry(
          timestamp: DateTime(2026, 2, 20),
          category: 'workflow',
          rawText: 'Uses vim',
          rawBlock: '- [2026-02-20 00:00] Uses vim',
        ),
      ];

      final result = pruner.reconstructMemoryMd(entries);
      expect(result, contains('## preferences'));
      expect(result, contains('## workflow'));
      expect(result, contains('Likes Dart'));
      expect(result, contains('Uses vim'));
    });

    test('returns empty string for empty list', () {
      expect(pruner.reconstructMemoryMd([]), '');
    });
  });

  group('prune() integration', () {
    test('no-op when MEMORY.md does not exist', () async {
      final result = await pruner.prune();
      expect(result.entriesArchived, 0);
      expect(result.duplicatesRemoved, 0);
      expect(result.entriesRemaining, 0);
    });

    test('no-op when MEMORY.md is empty', () async {
      writeMemory('');
      final result = await pruner.prune();
      expect(result.entriesArchived, 0);
      expect(result.duplicatesRemoved, 0);
    });

    test('archives old entries and removes duplicates', () async {
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
      expect(result.duplicatesRemoved, 1);
      expect(result.entriesRemaining, 1);

      final remaining = readMemory();
      expect(remaining, contains('Recent entry to keep'));
      expect(remaining, isNot(contains('Old entry to archive')));

      // Archive should exist with the old entry
      expect(archiveExists(), isTrue);
      final archived = readArchive();
      expect(archived, contains('Old entry to archive'));
      expect(archived, contains('## Archived'));
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
      expect(results[0].source, 'archive');
    });

    test('all entries recent means no archival, only deduplication', () async {
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
      expect(result.duplicatesRemoved, 1);
      expect(result.entriesRemaining, 2);
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

    test('atomic write: no .tmp file remains after prune', () async {
      final recent = DateTime.now().subtract(const Duration(days: 5));
      final recentStr =
          '${recent.year}-${recent.month.toString().padLeft(2, '0')}-${recent.day.toString().padLeft(2, '0')} '
          '${recent.hour.toString().padLeft(2, '0')}:${recent.minute.toString().padLeft(2, '0')}';

      writeMemory(
        '## general\n'
        '- [$recentStr] Entry\n',
      );

      await pruner.prune();

      final tmpFile = File('${tempDir.path}/MEMORY.md.tmp');
      expect(tmpFile.existsSync(), isFalse);
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

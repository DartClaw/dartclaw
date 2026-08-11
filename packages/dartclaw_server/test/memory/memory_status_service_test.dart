import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String workspaceDir;
  late KvService kvService;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('memory_status_test');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(workspaceDir).createSync(recursive: true);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
  });

  tearDown(() async {
    await kvService.dispose();
    tempDir.deleteSync(recursive: true);
  });

  DartclawConfig makeConfig({
    bool pruningEnabled = true,
    String pruningSchedule = '0 3 * * *',
    int archiveAfterDays = 90,
    int memoryMaxBytes = 32768,
  }) {
    return DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path),
      memory: MemoryConfig(
        pruningEnabled: pruningEnabled,
        pruningSchedule: pruningSchedule,
        archiveAfterDays: archiveAfterDays,
        maxBytes: memoryMaxBytes,
      ),
    );
  }

  MemoryStatusService makeService({
    DartclawConfig? config,
    SearchIndexCounter? searchIndexCounter,
    ScheduleService? scheduleService,
  }) {
    return MemoryStatusService(
      workspaceDir: workspaceDir,
      config: config ?? makeConfig(),
      kvService: kvService,
      searchIndexCounter: searchIndexCounter,
      scheduleService: scheduleService,
    );
  }

  group('getStatus', () {
    test('returns complete status with all files present', () async {
      // Create MEMORY.md with entries
      File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync('''
## general
- [2026-01-15 08:30] First memory entry
- [2026-03-03 14:22] Second memory entry
## debugging
- [2026-02-20 10:00] Debug note
''');

      // Create archive
      File(p.join(workspaceDir, 'MEMORY.archive.md')).writeAsStringSync('''
## Archived [2026-01-01]
- [2025-10-01 12:00] Old entry one
- [2025-11-15 09:00] Old entry two
''');

      // Create errors.md
      File(p.join(workspaceDir, 'errors.md')).writeAsStringSync('''
## [2026-03-01 10:00] Error one
Some error detail

## [2026-03-02 11:00] Error two
Another error
''');

      // Create learnings.md
      File(p.join(workspaceDir, 'learnings.md')).writeAsStringSync('''
- [2026-03-01 10:00] Learning one
''');

      final countedSources = <String>[];
      final service = makeService(
        searchIndexCounter: (source) {
          countedSources.add(source);
          return source == 'memory_save' ? 3 : 2;
        },
      );
      final status = await service.getStatus();

      // memoryMd
      final memoryMd = status['memoryMd'] as Map<String, dynamic>;
      expect(memoryMd['entryCount'], 3);
      expect(memoryMd['sizeBytes'], greaterThan(0));
      expect(memoryMd['budgetBytes'], 32768);
      expect(memoryMd['oldestEntry'], contains('2026-01-15'));
      expect(memoryMd['newestEntry'], contains('2026-03-03'));
      final categories = memoryMd['categories'] as List;
      expect(categories, hasLength(2));

      // archiveMd
      final archiveMd = status['archiveMd'] as Map<String, dynamic>;
      expect(archiveMd['entryCount'], 2);
      expect(archiveMd['sizeBytes'], greaterThan(0));

      // errorsMd
      final errorsMd = status['errorsMd'] as Map<String, dynamic>;
      expect(errorsMd['entryCount'], 2);
      expect(errorsMd['cap'], 50);

      // learningsMd
      final learningsMd = status['learningsMd'] as Map<String, dynamic>;
      expect(learningsMd['entryCount'], 1);

      // search
      final search = status['search'] as Map<String, dynamic>;
      expect(search['indexEntries'], 3);
      expect(search['indexArchived'], 2);
      expect(countedSources, ['memory_save', 'archive']);

      // pruner
      final pruner = status['pruner'] as Map<String, dynamic>;
      expect(pruner['enabled'], true);
      expect(pruner['schedule'], '0 3 * * *');
      expect(pruner['status'], 'active');
      expect(pruner['nextRun'], isNotNull);

      // config
      final config = status['config'] as Map<String, dynamic>;
      expect(config['memoryMaxBytes'], 32768);
    });

    test('returns zeros when no files exist', () async {
      final service = makeService();
      final status = await service.getStatus();

      final memoryMd = status['memoryMd'] as Map<String, dynamic>;
      expect(memoryMd['sizeBytes'], 0);
      expect(memoryMd['entryCount'], 0);
      expect(memoryMd['oldestEntry'], isNull);
      expect(memoryMd['newestEntry'], isNull);
      expect(memoryMd['categories'], isEmpty);

      final archiveMd = status['archiveMd'] as Map<String, dynamic>;
      expect(archiveMd['sizeBytes'], 0);
      expect(archiveMd['entryCount'], 0);

      final errorsMd = status['errorsMd'] as Map<String, dynamic>;
      expect(errorsMd['entryCount'], 0);
      expect(errorsMd['sizeBytes'], 0);

      final learningsMd = status['learningsMd'] as Map<String, dynamic>;
      expect(learningsMd['entryCount'], 0);
    });

    test('counts entries written by SelfImprovementService', () async {
      final selfImprovement = SelfImprovementService(workspaceDir: workspaceDir);
      addTearDown(selfImprovement.dispose);

      await selfImprovement.appendError(errorType: 'TEST', sessionId: 'session', context: 'context');
      await selfImprovement.appendLearning(text: 'Learning from production behavior');

      final status = await makeService().getStatus();

      expect((status['errorsMd'] as Map<String, dynamic>)['entryCount'], 1);
      expect((status['learningsMd'] as Map<String, dynamic>)['entryCount'], 1);
    });

    test('does not count encoded multiline markers as self-improvement entries', () async {
      final selfImprovement = SelfImprovementService(workspaceDir: workspaceDir);
      addTearDown(selfImprovement.dispose);

      await selfImprovement.appendError(
        errorType: 'TEST',
        sessionId: 'session',
        context: 'context\n## [forged] continuation',
      );
      await selfImprovement.appendLearning(text: 'learning\n- [forged] continuation');

      final status = await makeService().getStatus();

      expect((status['errorsMd'] as Map<String, dynamic>)['entryCount'], 1);
      expect((status['learningsMd'] as Map<String, dynamic>)['entryCount'], 1);
    });

    test('category breakdown is correct', () async {
      File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync('''
## general
- [2026-01-01 10:00] A
- [2026-01-02 10:00] B
## debugging
- [2026-01-03 10:00] C
- [2026-01-04 10:00] D
- [2026-01-05 10:00] E
## performance
- [2026-01-06 10:00] F
''');

      final service = makeService();
      final status = await service.getStatus();
      final categories = (status['memoryMd'] as Map<String, dynamic>)['categories'] as List;

      final catMap = {for (final c in categories) (c as Map)['name']: c['count']};
      expect(catMap['general'], 2);
      expect(catMap['debugging'], 3);
      expect(catMap['performance'], 1);
    });

    test('undated entries counted correctly', () async {
      File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync('''
## general
- [2026-01-01 10:00] Dated entry
- [some tag] Undated entry
''');

      final service = makeService();
      final status = await service.getStatus();
      final memoryMd = status['memoryMd'] as Map<String, dynamic>;
      expect(memoryMd['entryCount'], 2);
      expect(memoryMd['undatedCount'], 1);
    });

    test('fixed-file status rejects symlink leaves without reading their targets', () async {
      final external = File(p.join(tempDir.path, 'outside.md'))..writeAsStringSync('## [2026-01-01] external-secret');
      for (final target in [
        (name: 'MEMORY.md', statusKey: 'memoryMd'),
        (name: 'MEMORY.archive.md', statusKey: 'archiveMd'),
        (name: 'errors.md', statusKey: 'errorsMd'),
        (name: 'learnings.md', statusKey: 'learningsMd'),
      ]) {
        final link = Link(p.join(workspaceDir, target.name))..createSync(external.path);

        final status = await makeService().getStatus();

        expect((status[target.statusKey] as Map<String, dynamic>)['sizeBytes'], 0, reason: target.name);
        expect(external.readAsStringSync(), contains('external-secret'));
        link.deleteSync();
      }
    }, skip: Platform.isWindows);
  });

  group('pruner status', () {
    test('pruner disabled in config returns disabled status', () async {
      final service = makeService(config: makeConfig(pruningEnabled: false));
      final status = await service.getStatus();
      final pruner = status['pruner'] as Map<String, dynamic>;
      expect(pruner['status'], 'disabled');
    });

    test('prune history in KV populates history and lastRun', () async {
      final history = [
        {
          'timestamp': '2026-03-02T03:00:12Z',
          'entriesArchived': 2,
          'duplicatesRemoved': 0,
          'entriesRemaining': 45,
          'finalSizeBytes': 23000,
        },
        {
          'timestamp': '2026-03-03T03:00:08Z',
          'entriesArchived': 3,
          'duplicatesRemoved': 1,
          'entriesRemaining': 42,
          'finalSizeBytes': 22000,
        },
      ];
      await kvService.set('prune_history', jsonEncode(history));

      final service = makeService();
      final status = await service.getStatus();
      final pruner = status['pruner'] as Map<String, dynamic>;
      expect(pruner['history'], hasLength(2));
      expect(pruner['lastRun'], '2026-03-03T03:00:08Z');
    });

    test('no prune history returns empty history and null lastRun', () async {
      final service = makeService();
      final status = await service.getStatus();
      final pruner = status['pruner'] as Map<String, dynamic>;
      expect(pruner['history'], isEmpty);
      expect(pruner['lastRun'], isNull);
    });

    test('corrupt prune history returns empty', () async {
      await kvService.set('prune_history', 'not-json');

      final service = makeService();
      final status = await service.getStatus();
      final pruner = status['pruner'] as Map<String, dynamic>;
      expect(pruner['history'], isEmpty);
    });
  });

  group('search status', () {
    test('search index counts from callback', () async {
      final service = makeService(searchIndexCounter: (source) => source == 'memory_save' ? 100 : 50);
      final status = await service.getStatus();
      final search = status['search'] as Map<String, dynamic>;
      expect(search['indexEntries'], 100);
      expect(search['indexArchived'], 50);
    });

    test('null counter returns zeros', () async {
      final service = makeService();
      final status = await service.getStatus();
      final search = status['search'] as Map<String, dynamic>;
      expect(search['indexEntries'], 0);
      expect(search['indexArchived'], 0);
    });
  });

  group('daily logs', () {
    test('enumerates daily log files', () async {
      final logDir = Directory(p.join(workspaceDir, 'memory'));
      logDir.createSync(recursive: true);

      for (final date in ['2026-03-01', '2026-03-02', '2026-03-03']) {
        File(p.join(logDir.path, '$date.md')).writeAsStringSync(
          '## 10:00 — "Entry one"\n**User**: "Hello"\n'
          '## 11:00 — "Entry two"\n**User**: "Again"\n'
          '- [12:00] obsolete fixture format\n',
        );
      }

      final service = makeService();
      final status = await service.getStatus();
      final dailyLogs = status['dailyLogs'] as Map<String, dynamic>;
      expect(dailyLogs['fileCount'], 3);
      expect(dailyLogs['totalSizeBytes'], greaterThan(0));

      final recent = dailyLogs['recent'] as List;
      expect(recent, hasLength(3));
      expect((recent[0] as Map)['date'], '2026-03-03');
      expect((recent[0] as Map)['entries'], 2);
    });

    test('reads content only for the newest seven among many daily logs', () async {
      final logDir = Directory(p.join(workspaceDir, 'memory'))..createSync(recursive: true);
      for (var year = 1000; year < 1200; year++) {
        final file = File(p.join(logDir.path, '$year-01-01.md'));
        if (year < 1193) {
          file.writeAsStringSync('old');
          expect(Process.runSync('chmod', ['000', file.path]).exitCode, 0);
        } else {
          file.writeAsStringSync('## 10:00 — "Recent"\n');
        }
      }

      final dailyLogs = (await makeService().getStatus())['dailyLogs'] as Map<String, dynamic>;

      expect(dailyLogs['fileCount'], 200);
      expect(dailyLogs['totalSizeBytes'], greaterThan(200));
      final recent = dailyLogs['recent'] as List;
      expect(recent, hasLength(7));
      expect(recent.map((entry) => (entry as Map)['date']), [
        '1199-01-01',
        '1198-01-01',
        '1197-01-01',
        '1196-01-01',
        '1195-01-01',
        '1194-01-01',
        '1193-01-01',
      ]);
      expect(recent, everyElement(containsPair('entries', 1)));
    }, skip: Platform.isWindows);

    test('counts the complete oversized recent log while retaining full size', () async {
      final logDir = Directory(p.join(workspaceDir, 'memory'))..createSync(recursive: true);
      final bytes = <int>[
        ...utf8.encode('## 10:00 — "Visible"\n'),
        ...List<int>.filled(300 * 1024, 0x20),
        ...utf8.encode('\n## 11:00 — "Beyond limit"\n'),
      ];
      File(p.join(logDir.path, '2026-03-03.md')).writeAsBytesSync(bytes);

      final dailyLogs = (await makeService().getStatus())['dailyLogs'] as Map<String, dynamic>;

      expect(dailyLogs['fileCount'], 1);
      expect(dailyLogs['totalSizeBytes'], bytes.length);
      final recent = (dailyLogs['recent'] as List).single as Map<String, dynamic>;
      expect(recent['sizeBytes'], bytes.length);
      expect(recent['entries'], 2);
    });

    test('counts only canonical daily log headers with valid times', () async {
      final logDir = Directory(p.join(workspaceDir, 'memory'))..createSync(recursive: true);
      File(p.join(logDir.path, '2026-03-03.md')).writeAsStringSync('''
## 00:00 — "Midnight"
## 23:59 — "End of day"
## 24:00 — "Invalid hour"
## 12:60 — "Invalid minute"
## 09:30 - "Wrong dash"
 ## 09:30 — "Indented"
''');

      final dailyLogs = (await makeService().getStatus())['dailyLogs'] as Map<String, dynamic>;

      final recent = (dailyLogs['recent'] as List).single as Map<String, dynamic>;
      expect(recent['entries'], 2);
    });

    test('no log directory returns empty', () async {
      final service = makeService();
      final status = await service.getStatus();
      final dailyLogs = status['dailyLogs'] as Map<String, dynamic>;
      expect(dailyLogs['fileCount'], 0);
      expect(dailyLogs['totalSizeBytes'], 0);
      expect(dailyLogs['recent'], isEmpty);
    });

    test('non-directory log path returns empty', () async {
      File(p.join(workspaceDir, 'memory')).writeAsStringSync('not a directory');

      final dailyLogs = (await makeService().getStatus())['dailyLogs'] as Map<String, dynamic>;

      expect(dailyLogs['fileCount'], 0);
      expect(dailyLogs['totalSizeBytes'], 0);
      expect(dailyLogs['recent'], isEmpty);
    });

    test('ignores non-date files in log directory', () async {
      final logDir = Directory(p.join(workspaceDir, 'memory'));
      logDir.createSync(recursive: true);
      File(p.join(logDir.path, '2026-03-01.md')).writeAsStringSync('## 10:00 — "Entry"\n');
      File(p.join(logDir.path, 'notes.md')).writeAsStringSync('Not a log\n');
      File(p.join(logDir.path, 'readme.txt')).writeAsStringSync('ignore\n');

      final service = makeService();
      final status = await service.getStatus();
      final dailyLogs = status['dailyLogs'] as Map<String, dynamic>;
      expect(dailyLogs['fileCount'], 1);
    });

    test('rejects a symlinked log directory without reading its target', () async {
      final externalDir = Directory(p.join(tempDir.path, 'external-memory'))..createSync();
      final external = File(p.join(externalDir.path, '2026-03-01.md'))..writeAsStringSync('## 10:00 — "External"\n');
      Link(p.join(workspaceDir, 'memory')).createSync(externalDir.path);

      final dailyLogs = (await makeService().getStatus())['dailyLogs'] as Map<String, dynamic>;

      expect(dailyLogs['fileCount'], 0);
      expect(dailyLogs['recent'], isEmpty);
      expect(external.readAsStringSync(), contains('External'));
    }, skip: Platform.isWindows);

    test('rejects symlinked dated leaves without reading their targets', () async {
      final logDir = Directory(p.join(workspaceDir, 'memory'))..createSync();
      File(p.join(logDir.path, '2026-03-02.md')).writeAsStringSync('## 10:00 — "Local"\n');
      final external = File(p.join(tempDir.path, 'external-daily.md'))..writeAsStringSync('## 11:00 — "External"\n');
      Link(p.join(logDir.path, '2026-03-03.md')).createSync(external.path);

      final dailyLogs = (await makeService().getStatus())['dailyLogs'] as Map<String, dynamic>;

      expect(dailyLogs['fileCount'], 1);
      expect((dailyLogs['recent'] as List).single, containsPair('date', '2026-03-02'));
      expect(external.readAsStringSync(), contains('External'));
    }, skip: Platform.isWindows);
  });
}

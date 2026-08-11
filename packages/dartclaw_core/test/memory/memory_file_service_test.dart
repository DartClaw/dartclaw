import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late MemoryFileService service;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('memory_file_test');
    service = MemoryFileService(baseDir: tempDir.path);
  });

  tearDown(() async {
    await service.dispose();
    tempDir.deleteSync(recursive: true);
  });

  void createSparseFile(File file, int sizeBytes, {String prefix = ''}) {
    file.parent.createSync(recursive: true);
    final handle = file.openSync(mode: FileMode.write);
    try {
      handle.writeStringSync(prefix);
      handle.truncateSync(sizeBytes);
    } finally {
      handle.closeSync();
    }
  }

  void expectFilesEqual(File expected, File actual) {
    final expectedHandle = expected.openSync();
    final actualHandle = actual.openSync();
    try {
      while (true) {
        final expectedBytes = expectedHandle.readSync(64 * 1024);
        final actualBytes = actualHandle.readSync(64 * 1024);
        expect(actualBytes, expectedBytes);
        if (expectedBytes.isEmpty) return;
      }
    } finally {
      expectedHandle.closeSync();
      actualHandle.closeSync();
    }
  }

  group('appendMemory + readMemory', () {
    test('creates MEMORY.md on first append', () async {
      await service.appendMemory(text: 'User likes Dart');
      final content = await service.readMemory();
      expect(content, contains('User likes Dart'));
      expect(content, startsWith('## general'));
    });

    test('groups entries by category', () async {
      await service.appendMemory(text: 'Fact A', category: 'preferences');
      await service.appendMemory(text: 'Fact B', category: 'project');
      final content = await service.readMemory();
      expect(content, contains('## preferences'));
      expect(content, contains('## project'));
    });

    test('appends to existing category section', () async {
      await service.appendMemory(text: 'Entry 1', category: 'general');
      await service.appendMemory(text: 'Entry 2', category: 'general');
      final content = await service.readMemory();
      // Only one header for 'general'
      expect('## general'.allMatches(content).length, 1);
      expect(content, contains('Entry 1'));
      expect(content, contains('Entry 2'));
    });

    test('multi-paragraph entry remains intact after another same-category append', () async {
      await service.appendMemory(text: 'First paragraph.\n\nSecond paragraph.', category: 'general');
      await service.appendMemory(text: 'Separate fact.', category: 'general');

      final entries = parseMemoryEntries(await service.readMemory());
      expect(entries.map((entry) => entry.rawText), ['First paragraph.\n\nSecond paragraph.', 'Separate fact.']);
      expect(MemoryFileService.parseMemoryFile('${tempDir.path}/MEMORY.md').map((entry) => entry.text), [
        'First paragraph.\n\nSecond paragraph.',
        'Separate fact.',
      ]);
    });

    test('same-category append stays after an indented unclosed fence in the prior entry', () async {
      await service.appendMemory(text: 'Example:\n```dart\n  nested();', category: 'general');
      await service.appendMemory(text: 'Separate fact.', category: 'general');

      final entries = parseMemoryEntries(await service.readMemory());
      expect(entries.map((entry) => entry.rawText), ['Example:\n```dart\n  nested();', 'Separate fact.']);
      expect(entries.first.sourceEnd, lessThan(entries.last.sourceStart!));
    });

    test('writer and file parser preserve nested list and code indentation', () async {
      const text = 'Parent\n  - child\n    - grandchild\n    code();';
      await service.appendMemory(text: text, category: 'general');

      expect(parseMemoryEntries(await service.readMemory()).single.rawText, text);
      expect(MemoryFileService.parseMemoryFile('${tempDir.path}/MEMORY.md').single.text, text);
    });

    test('appends after fenced headings without modifying the fence', () async {
      const fence = '```markdown\n## example\n- [2020-01-01 00:00] Example only\n```';
      File('${tempDir.path}/MEMORY.md').writeAsStringSync('## general\n$fence\n\n## other\nManual text\n');

      await service.appendMemory(text: 'Saved outside the fence', category: 'general');

      final content = await service.readMemory();
      expect(content, contains(fence));
      final saved = parseMemoryEntries(content).where((entry) => entry.rawText == 'Saved outside the fence').single;
      expect(saved.category, 'general');
      expect(saved.sourceStart, greaterThan(content.indexOf(fence) + fence.length));
    });

    test('creates a real category when its only heading is fenced', () async {
      const fence = '```markdown\n## examples-only\n```';
      File('${tempDir.path}/MEMORY.md').writeAsStringSync('# Examples\n$fence\n');

      await service.appendMemory(text: 'Real saved entry', category: 'examples-only');

      final content = await service.readMemory();
      expect(RegExp(r'^## examples-only$', multiLine: true).allMatches(content), hasLength(2));
      final saved = parseMemoryEntries(content).where((entry) => entry.rawText == 'Real saved entry').single;
      expect(saved.category, 'examples-only');
    });

    test('inserts before an unclosed fence in an existing category', () async {
      const fence = '```markdown\n## example\n- [2020-01-01 00:00] Example only\n';
      File('${tempDir.path}/MEMORY.md').writeAsStringSync('## general\n$fence');

      await service.appendMemory(text: 'Saved before the fence', category: 'general');

      final content = await service.readMemory();
      expect(content, endsWith(fence));
      final saved = parseMemoryEntries(content).where((entry) => entry.rawText == 'Saved before the fence').single;
      expect(saved.category, 'general');
      expect(saved.sourceStart, lessThan(content.indexOf(fence)));
    });

    test('fails closed when a new category would follow an unclosed fence', () async {
      const content = '# Examples\n```markdown\n## examples-only\n';
      final file = File('${tempDir.path}/MEMORY.md')..writeAsStringSync(content);

      await expectLater(
        service.appendMemory(text: 'Must not disappear into the fence', category: 'new-category'),
        throwsFormatException,
      );

      expect(file.readAsStringSync(), content);
    });

    test('returns empty string when MEMORY.md missing', () async {
      expect(await service.readMemory(), isEmpty);
    });

    test('entries have timestamp format', () async {
      await service.appendMemory(text: 'Timestamped');
      final content = await service.readMemory();
      expect(content, matches(RegExp(r'- \[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\]')));
    });

    test('afterWrite receives the timestamp persisted in MEMORY.md', () async {
      final supplied = DateTime(2026, 2, 23, 10, 47, 59, 999);
      DateTime? observed;

      await service.appendMemory(
        text: 'Timestamped callback',
        timestamp: supplied,
        afterWrite: (timestamp) {
          observed = timestamp;
          expect(File('${tempDir.path}/MEMORY.md').existsSync(), isTrue);
        },
      );

      final parsed = parseMemoryEntries(await service.readMemory()).single;
      expect(observed, DateTime(2026, 2, 23, 10, 47));
      expect(parsed.timestamp, observed);
    });

    test('auto-creates base directory on first write', () async {
      final nested = MemoryFileService(baseDir: '${tempDir.path}/sub/dir');
      await nested.appendMemory(text: 'Deep write');
      expect(await nested.readMemory(), contains('Deep write'));
      await nested.dispose();
    });

    test('allows a configured workspace root that is a symlink', () async {
      final realWorkspace = Directory('${tempDir.path}/real-workspace')..createSync();
      final linkedWorkspace = Link('${tempDir.path}/linked-workspace')..createSync(realWorkspace.path);
      final linkedService = MemoryFileService(baseDir: linkedWorkspace.path);
      addTearDown(linkedService.dispose);

      await linkedService.appendMemory(text: 'Stored through linked workspace');

      expect(File('${realWorkspace.path}/MEMORY.md').readAsStringSync(), contains('Stored through linked workspace'));
    }, skip: Platform.isWindows);

    test('rejects MEMORY.md symlinks without changing their target', () async {
      final external = File('${tempDir.path}/external-memory.md')..writeAsStringSync('external content');
      Link('${tempDir.path}/MEMORY.md').createSync(external.path);

      await expectLater(service.appendMemory(text: 'must not escape'), throwsA(isA<FileSystemException>()));
      await expectLater(service.readMemory(), throwsA(isA<FileSystemException>()));

      expect(external.readAsStringSync(), 'external content');
    }, skip: Platform.isWindows);

    test('rejects non-regular MEMORY.md entities', () async {
      Directory('${tempDir.path}/MEMORY.md').createSync();

      await expectLater(service.appendMemory(text: 'must fail closed'), throwsA(isA<FileSystemException>()));
      await expectLater(service.readMemory(), throwsA(isA<FileSystemException>()));
    });

    test('rejects oversized MEMORY.md before allocating its contents', () async {
      createSparseFile(File('${tempDir.path}/MEMORY.md'), MemoryFileService.maxReadableFileBytes + 1);

      await expectLater(service.readMemory(), throwsA(isA<FileSystemException>()));
      expect(service.lastMemorySize, 0);
    });

    test('allows the exact byte limit and rejects repeated crossing appends without changing the file', () async {
      final file = File('${tempDir.path}/MEMORY.md');
      final beforeRejection = File('${tempDir.path}/MEMORY.before.md');
      final timestamp = DateTime(2026, 1, 2, 3, 4);
      const text = 'boundary';
      const renderedEntry = '- [2026-01-02 03:04] boundary';
      final appendBytes = utf8.encode('\n$renderedEntry').length;
      createSparseFile(file, MemoryFileService.maxReadableFileBytes - appendBytes, prefix: '## general\n');

      await service.appendMemory(text: text, category: 'general', timestamp: timestamp);

      expect(file.lengthSync(), MemoryFileService.maxReadableFileBytes);
      expect(await service.readMemory(), contains(renderedEntry));
      file.copySync(beforeRejection.path);

      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          service.appendMemory(text: 'must not be written', category: 'general', timestamp: timestamp),
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.message,
              'message',
              contains('MEMORY.md would exceed the ${MemoryFileService.maxReadableFileBytes}-byte limit'),
            ),
          ),
        );
        expectFilesEqual(beforeRejection, file);
      }
      expect(await service.readMemory(), contains(renderedEntry));
    });
  });

  group('lastMemorySize', () {
    test('is 0 before any read', () {
      expect(service.lastMemorySize, 0);
    });

    test('reflects byte size after readMemory', () async {
      await service.appendMemory(text: 'Test');
      final content = await service.readMemory();
      expect(service.lastMemorySize, utf8.encode(content).length);
    });

    test('updated after appendMemory', () async {
      await service.appendMemory(text: 'First');
      expect(service.lastMemorySize, greaterThan(0));
    });
  });

  group('appendDailyLog', () {
    test('creates daily log file', () async {
      await service.appendDailyLog('## 14:30 — Test Session\n**User**: Hello');
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final logFile = File('${tempDir.path}/memory/$dateStr.md');
      expect(logFile.existsSync(), isTrue);
      expect(logFile.readAsStringSync(), contains('Test Session'));
    });

    test('appends to existing daily log', () async {
      await service.appendDailyLog('Entry 1');
      await service.appendDailyLog('Entry 2');
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final logFile = File('${tempDir.path}/memory/$dateStr.md');
      final content = logFile.readAsStringSync();
      expect(content, contains('Entry 1'));
      expect(content, contains('Entry 2'));
    });

    test('bounds one oversized record with an explicit marker', () async {
      await service.appendDailyLog('## 14:30 — Large\n${'é' * MemoryFileService.maxDailyLogEntryBytes}');

      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final bytes = File('${tempDir.path}/memory/$dateStr.md').readAsBytesSync();

      expect(bytes.length, lessThanOrEqualTo(MemoryFileService.maxDailyLogEntryBytes + 1));
      expect(utf8.decode(bytes), contains('[Daily log record truncated at 512 KiB]'));
    });

    test('drops oldest complete records when the daily file reaches its byte limit', () async {
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final memoryDir = Directory('${tempDir.path}/memory')..createSync();
      final file = File('${memoryDir.path}/$dateStr.md');
      final oldRecord = '## 00:00 — Old\n${'x' * (MemoryFileService.maxDailyLogFileBytes - 32)}\n';
      file.writeAsStringSync(oldRecord);

      await service.appendDailyLog('## 23:59 — New\n**User**: newest record');

      final content = file.readAsStringSync();
      expect(file.lengthSync(), lessThanOrEqualTo(MemoryFileService.maxDailyLogFileBytes));
      expect(content, startsWith('<!-- Older daily-log records removed'));
      expect(content, isNot(contains('## 00:00 — Old')));
      expect(content, contains('## 23:59 — New'));
      expect(content, contains('newest record'));
    });

    test('repairs a pre-upgrade oversized daily file from its bounded complete-record tail', () async {
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final file = File('${tempDir.path}/memory/$dateStr.md');
      file.parent.createSync(recursive: true);
      final recordBody = 'x' * (MemoryFileService.maxDailyLogFileBytes ~/ 2);
      file.writeAsStringSync('## 00:00 — Old\n$recordBody\n## 12:00 — Retained\n$recordBody\n');

      await service.appendDailyLog('## 23:59 — New\n**User**: newest record');

      final content = file.readAsStringSync();
      expect(file.lengthSync(), lessThanOrEqualTo(MemoryFileService.maxDailyLogFileBytes));
      expect(content, startsWith('<!-- Older daily-log records removed'));
      expect(content, isNot(contains('## 00:00 — Old')));
      expect(content, contains('## 12:00 — Retained'));
      expect(content, contains('## 23:59 — New'));
      expect(content, contains('newest record'));
    });

    test('rejects a symlinked memory directory without changing its target', () async {
      final externalDir = Directory('${tempDir.path}/external-logs')..createSync();
      final marker = File('${externalDir.path}/marker')..writeAsStringSync('unchanged');
      Link('${tempDir.path}/memory').createSync(externalDir.path);

      await expectLater(service.appendDailyLog('must not escape'), throwsA(isA<FileSystemException>()));

      expect(marker.readAsStringSync(), 'unchanged');
      expect(externalDir.listSync(), hasLength(1));
    }, skip: Platform.isWindows);

    test('rejects a symlinked daily log without changing its target', () async {
      final memoryDir = Directory('${tempDir.path}/memory')..createSync();
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final external = File('${tempDir.path}/external-daily.md')..writeAsStringSync('external content');
      Link('${memoryDir.path}/$dateStr.md').createSync(external.path);

      await expectLater(service.appendDailyLog('must not escape'), throwsA(isA<FileSystemException>()));

      expect(external.readAsStringSync(), 'external content');
    }, skip: Platform.isWindows);
  });

  group('stripMarkdown', () {
    test('strips headings', () {
      expect(MemoryFileService.stripMarkdown('## Title'), 'Title');
    });

    test('strips bold and italic', () {
      expect(MemoryFileService.stripMarkdown('**bold** and *italic*'), 'bold and italic');
    });

    test('strips links keeping text', () {
      expect(MemoryFileService.stripMarkdown('[click](http://x.com)'), 'click');
    });

    test('strips blockquotes', () {
      expect(MemoryFileService.stripMarkdown('> quoted text'), 'quoted text');
    });

    test('strips backticks', () {
      expect(MemoryFileService.stripMarkdown('`code` here'), 'code here');
    });
  });

  group('splitParagraphs', () {
    test('returns single chunk for short text', () {
      expect(MemoryFileService.splitParagraphs('Short text'), ['Short text']);
    });

    test('splits at paragraph boundaries', () {
      final text = '${'a' * 300}\n\n${'b' * 300}';
      final chunks = MemoryFileService.splitParagraphs(text);
      expect(chunks.length, 2);
      expect(chunks[0], 'a' * 300);
      expect(chunks[1], 'b' * 300);
    });

    test('splits at line boundaries when paragraph too long', () {
      final text = List.generate(20, (i) => 'line $i ' * 10).join('\n');
      final chunks = MemoryFileService.splitParagraphs(text, maxChars: 100);
      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(200)); // allow some overflow from line joining
      }
    });

    test('handles text with no natural break points', () {
      final text = 'x' * 1200;
      final chunks = MemoryFileService.splitParagraphs(text);
      expect(chunks.length, greaterThan(1));
    });
  });

  group('parseMemoryFile', () {
    test('returns empty list for non-existent file', () {
      final entries = MemoryFileService.parseMemoryFile('${tempDir.path}/nonexistent.md');
      expect(entries, isEmpty);
    });

    test('returns empty list for empty file', () {
      File('${tempDir.path}/empty.md').writeAsStringSync('');
      final entries = MemoryFileService.parseMemoryFile('${tempDir.path}/empty.md');
      expect(entries, isEmpty);
    });

    test('returns empty list for headers-only file', () {
      File('${tempDir.path}/headers.md').writeAsStringSync('## general\n## project\n');
      final entries = MemoryFileService.parseMemoryFile('${tempDir.path}/headers.md');
      expect(entries, isEmpty);
    });

    test('parses entries with categories', () {
      final content = '''
## preferences
- [2026-02-23 10:00] User likes Dart
- [2026-02-23 10:05] Prefers dark mode

## project
- [2026-02-23 11:00] Working on DartClaw
''';
      File('${tempDir.path}/test.md').writeAsStringSync(content);
      final entries = MemoryFileService.parseMemoryFile('${tempDir.path}/test.md');

      expect(entries, hasLength(3));
      expect(entries[0].text, equals('User likes Dart'));
      expect(entries[0].category, equals('preferences'));
      expect(entries[1].text, equals('Prefers dark mode'));
      expect(entries[1].category, equals('preferences'));
      expect(entries[2].text, equals('Working on DartClaw'));
      expect(entries[2].category, equals('project'));
    });

    test('defaults to general category when no header', () {
      final content = '- [2026-02-23 10:00] No header entry\n';
      File('${tempDir.path}/noheader.md').writeAsStringSync(content);
      final entries = MemoryFileService.parseMemoryFile('${tempDir.path}/noheader.md');

      expect(entries, hasLength(1));
      expect(entries[0].category, equals('general'));
    });

    test('skips entries with empty text after timestamp', () {
      final content = '## general\n- [2026-02-23 10:00] \n- [2026-02-23 10:05] Valid entry\n';
      File('${tempDir.path}/empty_text.md').writeAsStringSync(content);
      final entries = MemoryFileService.parseMemoryFile('${tempDir.path}/empty_text.md');

      expect(entries, hasLength(1));
      expect(entries[0].text, equals('Valid entry'));
    });

    test('roundtrips with appendMemory output', () async {
      await service.appendMemory(text: 'Memory A', category: 'cat1');
      await service.appendMemory(text: 'Memory B', category: 'cat2');
      final entries = MemoryFileService.parseMemoryFile('${tempDir.path}/MEMORY.md');

      expect(entries, hasLength(2));
      expect(entries[0].text, equals('Memory A'));
      expect(entries[0].category, equals('cat1'));
      expect(entries[1].text, equals('Memory B'));
      expect(entries[1].category, equals('cat2'));
    });
  });

  group('write serialization', () {
    test('concurrent writes are serialized', () async {
      final futures = <Future<void>>[];
      for (var i = 0; i < 5; i++) {
        futures.add(service.appendMemory(text: 'Entry $i'));
      }
      await Future.wait(futures);
      final content = await service.readMemory();
      for (var i = 0; i < 5; i++) {
        expect(content, contains('Entry $i'));
      }
    });

    test('workspace write lock blocks append until maintenance releases it', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final maintenance = RepoLock().acquire('${tempDir.resolveSymbolicLinksSync()}/MEMORY.md', () async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      var saveCompleted = false;

      final save = Zone.root.run(
        () => service.appendMemory(text: 'Saved after maintenance').then((_) => saveCompleted = true),
      );
      await pumpEventQueue(times: 20);

      expect(saveCompleted, isFalse);
      expect(File('${tempDir.path}/MEMORY.md').existsSync(), isFalse);

      release.complete();
      await maintenance;
      await save;
      expect(await service.readMemory(), contains('Saved after maintenance'));
    });

    test('workspace write lock resolves symlink aliases', () async {
      final alias = Link('${tempDir.path}-alias')..createSync(tempDir.path);
      final aliasService = MemoryFileService(baseDir: alias.path);
      addTearDown(() async {
        await aliasService.dispose();
        if (alias.existsSync()) alias.deleteSync();
      });
      final entered = Completer<void>();
      final release = Completer<void>();
      final maintenance = RepoLock().acquire('${tempDir.resolveSymbolicLinksSync()}/MEMORY.md', () async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      var saveCompleted = false;

      final save = Zone.root.run(
        () => aliasService.appendMemory(text: 'Saved through alias').then((_) => saveCompleted = true),
      );
      await pumpEventQueue(times: 20);

      expect(saveCompleted, isFalse);
      release.complete();
      await maintenance;
      await save;
      expect(await service.readMemory(), contains('Saved through alias'));
    }, skip: Platform.isWindows);
  });
}

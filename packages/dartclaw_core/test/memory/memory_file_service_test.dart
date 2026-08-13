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

    test('rejects partition overflow without deleting prior records', () async {
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final memoryDir = Directory('${tempDir.path}/memory')..createSync();
      final file = File('${memoryDir.path}/$dateStr.md');
      final oldRecord = '## 00:00 — Old\n${'x' * (MemoryFileService.maxDailyLogFileBytes - 32)}\n';
      file.writeAsStringSync(oldRecord);
      final before = file.readAsBytesSync();

      await expectLater(
        service.appendDailyLog('## 23:59 — New\n**User**: newest record'),
        throwsA(
          isA<MemoryResourceLimitException>()
              .having((error) => error.role, 'role', MemoryRole.observation)
              .having((error) => error.locator, 'locator', 'memory/$dateStr.md')
              .having((error) => error.currentBytes, 'currentBytes', before.length)
              .having(
                (error) => error.observedBytes,
                'observedBytes',
                greaterThan(MemoryFileService.maxDailyLogFileBytes),
              ),
        ),
      );

      expect(file.readAsBytesSync(), before);
    });

    test('rejects a pre-existing oversized partition without rewriting it', () async {
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final file = File('${tempDir.path}/memory/$dateStr.md');
      file.parent.createSync(recursive: true);
      final recordBody = 'x' * (MemoryFileService.maxDailyLogFileBytes ~/ 2);
      file.writeAsStringSync('## 00:00 — Old\n$recordBody\n## 12:00 — Retained\n$recordBody\n');
      final before = file.readAsBytesSync();

      await expectLater(
        service.appendDailyLog('## 23:59 — New\n**User**: newest record'),
        throwsA(isA<MemoryResourceLimitException>()),
      );

      expect(file.readAsBytesSync(), before);
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

  test('bounded regular-file selection is stable and retains exact omission evidence', () async {
    final root = Directory('${tempDir.path}/tree')..createSync();
    final nested = Directory('${root.path}/nested')..createSync();
    for (final name in ['z.md', 'b.md', 'a.md']) {
      File('${name == 'b.md' ? nested.path : root.path}/$name').writeAsStringSync(name);
    }
    Link('${root.path}/linked.md').createSync('${root.path}/a.md');

    final scan = await MemoryFileService.listRegularFilesBounded(root, limit: 2);

    expect(scan.files.map((file) => file.path.substring(root.path.length + 1).replaceAll('\\', '/')), [
      'a.md',
      'nested/b.md',
    ]);
    expect(scan.complete, isTrue);
    expect(scan.firstOmitted?.path, '${root.path}/z.md');
    expect(scan.omittedCount, 1);
  });

  test('bounded regular-file selection is independent of creation order', () async {
    Future<List<String>> select(String directoryName, List<String> creationOrder) async {
      final root = Directory('${tempDir.path}/$directoryName')..createSync();
      for (final name in creationOrder) {
        File('${root.path}/$name').writeAsStringSync(name);
      }
      final scan = await MemoryFileService.listRegularFilesBounded(root, limit: 2);
      expect(scan.complete, isTrue);
      return scan.files.map((file) => file.path.substring(root.path.length + 1)).toList();
    }

    expect(await select('forward', ['a.md', 'm.md', 'z.md']), ['a.md', 'm.md']);
    expect(await select('reverse', ['z.md', 'm.md', 'a.md']), ['a.md', 'm.md']);
  });

  test('bounded regular-file selection reports the exact known omission count', () async {
    final root = Directory('${tempDir.path}/known-omissions')..createSync();
    for (var index = 0; index < MemoryResourceLimits.recursiveFiles + 1001; index++) {
      File('${root.path}/${index.toString().padLeft(4, '0')}.md').writeAsStringSync('x');
    }

    final scan = await MemoryFileService.listRegularFilesBounded(root);

    expect(scan.complete, isTrue);
    expect(scan.files, hasLength(MemoryResourceLimits.recursiveFiles));
    expect(scan.omittedCount, 1001);
  });

  test('bounded regular-file selection returns no arbitrary prefix when traversal exhausts', () async {
    final root = Directory('${tempDir.path}/wide')..createSync();
    for (var index = 0; index < MemoryResourceLimits.recursiveFiles * 2 + 2; index++) {
      File('${root.path}/${index.toString().padLeft(4, '0')}.md').writeAsStringSync('x');
    }

    final scan = await MemoryFileService.listRegularFilesBounded(root);

    expect(scan.complete, isFalse);
    expect(scan.files, isEmpty);
    expect(scan.firstOmitted, isNull);
    expect(scan.omittedCount, 0);
  });
}

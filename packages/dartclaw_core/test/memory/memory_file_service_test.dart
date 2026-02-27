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

    test('returns empty string when MEMORY.md missing', () async {
      expect(await service.readMemory(), isEmpty);
    });

    test('entries have timestamp format', () async {
      await service.appendMemory(text: 'Timestamped');
      final content = await service.readMemory();
      expect(content, matches(RegExp(r'- \[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\]')));
    });

    test('auto-creates base directory on first write', () async {
      final nested = MemoryFileService(baseDir: '${tempDir.path}/sub/dir');
      await nested.appendMemory(text: 'Deep write');
      expect(await nested.readMemory(), contains('Deep write'));
      await nested.dispose();
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
  });
}

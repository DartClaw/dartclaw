import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/rebuild_index_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<String> output;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_rebuild_idx_test_');
    output = [];
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> runCommand(DartclawConfig config) async {
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));
    await runner.run(['rebuild-index']);
  }

  test('bootstraps and rebuilds an empty canonical corpus', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    await runCommand(config);
    expect(output, hasLength(3));
    expect(output.first, contains('must remain stopped'));
    expect(output[1], contains('Memory preflight: alreadyCurrent'));
    expect(output.last, contains('Rebuilt index: 0 entries'));
  });

  test('--json emits only the machine-readable reconciled outcome', () async {
    final config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path),
      warnings: const ['legacy setting ignored'],
    );
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index', '--json']);

    expect(output, hasLength(1));
    expect(jsonDecode(output.single), {
      'canonicalRevision': 1,
      'indexedRows': 0,
      'health': 'healthy',
      'unchanged': false,
    });
  });

  test('missing canonical files clear stale index rows', () async {
    Directory(p.join(tempDir.path, 'workspace')).createSync();
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final dbPath = p.join(tempDir.path, 'search.db');
    final seededDb = openSearchDb(dbPath);
    MemoryService(seededDb);
    seededDb.execute('INSERT INTO memory_chunks (text, source, created_at, locator) VALUES (?, ?, ?, ?)', [
      'stale searchable row',
      'legacy-memory',
      DateTime(2026).toIso8601String(),
      'legacy-memory',
    ]);
    seededDb.close();
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index']);

    final db = openSearchDb(dbPath);
    expect(MemoryService(db).search('stale'), isEmpty);
    expect(output[1], contains('Memory preflight: alreadyCurrent'));
    db.close();
  });

  test('rebuilds an empty MEMORY.md index', () async {
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(p.join(wsDir.path, 'MEMORY.md')).writeAsStringSync('');
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    await runCommand(config);
    expect(output, hasLength(3));
    expect(output.last, contains('Rebuilt index: 0 entries'));
  });

  test('rebuilds a headers-only MEMORY.md index', () async {
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(p.join(wsDir.path, 'MEMORY.md')).writeAsStringSync('## general\n');
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    await runCommand(config);
    expect(output, hasLength(3));
    expect(output.last, contains('Rebuilt index: 0 entries'));
  });

  test('rebuilds index from valid MEMORY.md', () async {
    final memoryContent = '''
## preferences
- [2026-02-23 10:00] User likes Dart
- [2026-02-23 10:05] User prefers dark mode

## project
- [2026-02-23 11:00] Working on DartClaw
''';
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(p.join(wsDir.path, 'MEMORY.md')).writeAsStringSync(memoryContent);
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));

    // Use file-based DB so we can reopen after command closes it
    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));
    await runner.run(['rebuild-index']);

    expect(output, hasLength(3));
    expect(output.last, contains('Rebuilt index: 3 entries'));

    // Verify entries were actually indexed by reopening the DB
    final db = openSearchDb(dbPath);
    final memory = MemoryService(db);
    final results = memory.search('Dart');
    expect(results, isNotEmpty);
    expect(results.first.text, contains('Dart'));
    db.close();
  });

  test('parses multiline entries correctly', () async {
    final memoryContent = '''
## preferences
- [2026-02-23 10:00] User prefers dark mode
  with high contrast settings
  and reduced motion
- [2026-02-23 10:05] Another preference
''';
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(p.join(wsDir.path, 'MEMORY.md')).writeAsStringSync(memoryContent);
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));

    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));
    await runner.run(['rebuild-index']);

    expect(output, hasLength(3));
    expect(output.last, contains('Rebuilt index: 2 entries'));

    // Verify multiline content is preserved in search index
    final db = openSearchDb(dbPath);
    final memory = MemoryService(db);
    final results = memory.search('high contrast');
    expect(results, isNotEmpty);
    expect(results.first.text, contains('high contrast'));
    db.close();
  });

  test('rebuild uses the live Markdown normalization and chunk boundaries', () async {
    final longTail = List.generate(90, (index) => 'segment$index').join(' ');
    final entryText = '**Durable heading**\n\n$longTail';
    final expectedRows = MemoryService.indexRows(
      text: entryText,
      source: 'legacy-memory',
      category: 'project',
      createdAt: DateTime(2026, 2, 23, 10),
    );
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(
      p.join(wsDir.path, 'MEMORY.md'),
    ).writeAsStringSync('## project\n- [2026-02-23 10:00] **Durable heading**\n  \n  $longTail\n');
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index']);

    final db = openSearchDb(dbPath);
    final rows = db.select('SELECT text, source, category, created_at, locator FROM memory_chunks ORDER BY id');
    expect(rows.map((row) => row['text']), expectedRows.map((row) => row.text));
    expect(rows.every((row) => row['source'] == row['locator'] && row['category'] == 'project'), isTrue);
    expect(rows.map((row) => row['created_at']).toSet(), {DateTime(2026, 2, 23, 10).toUtc().toIso8601String()});
    expect(output.last, contains('Rebuilt index: ${expectedRows.length} entries'));
    db.close();
  });

  test('rebuilds memory and archive entries with their canonical sources', () async {
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(
      p.join(wsDir.path, 'MEMORY.md'),
    ).writeAsStringSync('## preferences\n- [2026-02-23 10:00] Current searchable preference\n');
    File(
      p.join(wsDir.path, 'MEMORY.archive.md'),
    ).writeAsStringSync('## project\n- [2025-01-10 09:00] Archived searchable project\n');
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index']);

    final db = openSearchDb(dbPath);
    final memory = MemoryService(db);
    final current = memory.search('Current searchable').single;
    final archived = memory.search('Archived searchable').single;
    expect((current.role, current.source == current.locator, current.category), ('topic', true, 'preferences'));
    expect((archived.role, archived.source == archived.locator, archived.category), ('archive', true, 'project'));
    expect(output.last, contains('Rebuilt index: 2 entries'));
    db.close();
  });

  test('rebuild preserves source timestamps for recent ordering', () async {
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(
      p.join(wsDir.path, 'MEMORY.md'),
    ).writeAsStringSync('## preferences\n- [2026-02-23 10:00] Current searchable preference\n');
    File(
      p.join(wsDir.path, 'MEMORY.archive.md'),
    ).writeAsStringSync('## project\n- [2025-01-10 09:00] Archived searchable project\n');
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index']);

    final db = openSearchDb(dbPath);
    final recent = MemoryService(db).listRecent();
    expect(recent.map((result) => result.role), ['topic', 'archive']);
    expect(db.select('SELECT created_at FROM memory_chunks ORDER BY created_at DESC').map((row) => row['created_at']), [
      DateTime(2026, 2, 23, 10).toUtc().toIso8601String(),
      DateTime(2025, 1, 10, 9).toUtc().toIso8601String(),
    ]);
    db.close();
  });

  test('rebuild restores learnings with live source and category', () async {
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(p.join(wsDir.path, 'learnings.md')).writeAsStringSync('- [2026-02-23 10:00] **Validate** rebuild recovery\n');
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index']);

    final db = openSearchDb(dbPath);
    final learning = MemoryService(db).search('Validate').single;
    expect(
      (learning.text, learning.role, learning.source == learning.locator, learning.category),
      ('Validate rebuild recovery', 'learning', true, null),
    );
    expect(output.last, contains('Rebuilt index: 1 entries'));
    db.close();
  });

  test('rebuild preserves a stable source timestamp', () async {
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(p.join(wsDir.path, 'MEMORY.md')).writeAsStringSync('## general\n- [2025-01-01 00:00] Dated fact\n');
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index']);
    final firstDb = openSearchDb(dbPath);
    final first = firstDb.select('SELECT created_at FROM memory_chunks').single['created_at'];
    firstDb.close();

    output.clear();
    await runner.run(['rebuild-index']);
    final secondDb = openSearchDb(dbPath);
    final second = secondDb.select('SELECT created_at FROM memory_chunks').single['created_at'];
    secondDb.close();

    expect(second, first);
  });

  test('recovers the index from MEMORY.archive.md alone', () async {
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(
      p.join(wsDir.path, 'MEMORY.archive.md'),
    ).writeAsStringSync('## project\n- [2025-01-10 09:00] Archive-only recovery fact\n');
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index']);

    final db = openSearchDb(dbPath);
    final result = MemoryService(db).search('recovery').single;
    expect((result.role, result.source == result.locator, result.category), ('archive', true, 'project'));
    db.close();
  });

  test('empty canonical files clear stale index rows', () async {
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(p.join(wsDir.path, 'MEMORY.archive.md')).writeAsStringSync('');
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final dbPath = p.join(tempDir.path, 'search.db');
    final seededDb = openSearchDb(dbPath);
    MemoryService(seededDb);
    seededDb.execute('INSERT INTO memory_chunks (text, source, created_at, locator) VALUES (?, ?, ?, ?)', [
      'stale searchable row',
      'archive',
      DateTime(2026).toIso8601String(),
      'archive',
    ]);
    seededDb.close();
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index']);

    final db = openSearchDb(dbPath);
    expect(MemoryService(db).search('stale'), isEmpty);
    expect(output.last, contains('Rebuilt index: 0 entries'));
    db.close();
  });

  test('rejects a symlinked canonical memory file without reading its target', () async {
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    final external = File(p.join(tempDir.path, 'external-memory.md'))
      ..writeAsStringSync('## general\n- [2026-02-23 10:00] External fact\n');
    Link(p.join(wsDir.path, 'MEMORY.archive.md')).createSync(external.path);
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));

    await expectLater(runCommand(config), throwsA(isA<MemoryPreflightException>()));

    expect(external.readAsStringSync(), contains('External fact'));
  }, skip: Platform.isWindows);
}

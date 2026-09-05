import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/rebuild_index_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:dartclaw_testing/dartclaw_testing.dart' show seedCanonicalMemory;

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

  Directory workspaceOf(DartclawConfig config) => Directory(config.workspaceDir)..createSync(recursive: true);

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
      'reconciled': false,
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

  test('rebuilds the index from a canonical corpus', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    workspaceOf(config);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'preferences': ['User likes Dart', 'User prefers dark mode'],
        'project': ['Working on DartClaw'],
      },
    );
    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index']);

    expect(output, hasLength(3));
    expect(output[1], contains('Memory preflight: alreadyCurrent'));
    expect(output.last, contains('Rebuilt index: 3 entries at collection revision 2'));

    final db = openSearchDb(dbPath);
    final results = MemoryService(db).search('Dart');
    expect(results, isNotEmpty);
    expect(results.first.text, contains('Dart'));
    db.close();
  });

  test('rebuild uses the live Markdown normalization and chunk boundaries', () async {
    final longTail = List.generate(90, (index) => 'segment$index').join(' ');
    final entryText = '**Durable heading**\n\n$longTail';
    final expectedTexts = MemoryService.indexRows(
      text: entryText,
      source: 'ignored',
      category: 'project',
      createdAt: DateTime.utc(2026, 2, 23, 10),
    ).map((row) => row.text).toList();
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    workspaceOf(config);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: {
        'project': [entryText],
      },
    );
    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index']);

    final db = openSearchDb(dbPath);
    final rows = db.select('SELECT text, source, category, created_at, locator FROM memory_chunks ORDER BY id');
    expect(rows.map((row) => row['text']), expectedTexts);
    expect(rows.every((row) => row['source'] == row['locator'] && row['category'] == 'project'), isTrue);
    expect(rows.map((row) => row['created_at']).toSet(), {DateTime.utc(2026, 2, 23, 10).toIso8601String()});
    expect(output.last, contains('Rebuilt index: ${expectedTexts.length} entries'));
    db.close();
  });

  test('rebuilds topic, archive, and learning members with their canonical sources', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    workspaceOf(config);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'preferences': ['Current searchable preference'],
      },
      archive: const {
        'project': ['Archived searchable project'],
      },
      learnings: const ['Validate rebuild recovery'],
    );
    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index']);

    final db = openSearchDb(dbPath);
    final memory = MemoryService(db);
    final current = memory.search('Current searchable').single;
    final archived = memory.search('Archived searchable').single;
    final learning = memory.search('Validate').single;
    expect((current.role, current.source == current.locator, current.category), ('topic', true, 'preferences'));
    expect((archived.role, archived.source == archived.locator, archived.category), ('archive', true, 'project'));
    expect((learning.role, learning.source == learning.locator, learning.category), ('learning', true, null));
    expect(output.last, contains('Rebuilt index: 3 entries'));
    db.close();
  });

  test('rebuild preserves canonical timestamps across repeated runs', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    workspaceOf(config);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['Dated fact'],
      },
      updated: DateTime.utc(2025),
    );
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

    expect(first, DateTime.utc(2025).toIso8601String());
    expect(second, first);
  });

  test('a preview-dialect workspace is refused with the same message serve emits', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final wsDir = workspaceOf(config);
    final memory = File(p.join(wsDir.path, 'MEMORY.md'))
      ..writeAsStringSync('## preferences\n- [2026-02-23 10:00] Preview dialect entry\n');

    await expectLater(
      runCommand(config),
      throwsA(
        isA<MemoryPreflightException>()
            .having((error) => error.report, 'report', contains('Stage: legacy-dialect-detected'))
            .having((error) => error.report, 'report', contains('MEMORY.md'))
            .having((error) => error.report, 'report', contains(MemoryPreflight.lastConvertingRelease)),
      ),
    );

    expect(memory.readAsStringSync(), '## preferences\n- [2026-02-23 10:00] Preview dialect entry\n');
    expect(File(p.join(tempDir.path, 'search.db')).existsSync(), isFalse);
  });

  test('rejects a symlinked legacy memory file without reading its target', () async {
    final wsDir = workspaceOf(DartclawConfig(server: ServerConfig(dataDir: tempDir.path)));
    final external = File(p.join(tempDir.path, 'external-memory.md'))
      ..writeAsStringSync('## general\n- [2026-02-23 10:00] External fact\n');
    Link(p.join(wsDir.path, 'MEMORY.archive.md')).createSync(external.path);
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));

    await expectLater(
      runCommand(config),
      throwsA(
        isA<MemoryPreflightException>().having(
          (error) => error.report,
          'report',
          contains('Stage: legacy-dialect-detected'),
        ),
      ),
    );

    expect(external.readAsStringSync(), contains('External fact'));
  }, skip: Platform.isWindows);
}

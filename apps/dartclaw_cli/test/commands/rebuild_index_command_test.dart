import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/rebuild_index_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/storage/index_reconciler.dart' show IndexReconcileTransition;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' hide DatabaseConfig;
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

  test('postgres refuses offline index rebuild before touching local search state', () async {
    final config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path),
      database: const DatabaseConfig(backend: DatabaseBackendKind.postgres, url: 'postgresql://unused.invalid/example'),
    );
    int? code;
    final runner = DartclawRunner()
      ..addCommand(RebuildIndexCommand(config: config, writeLine: output.add, exitFn: (value) => code = value));

    await runner.run(['rebuild-index']);

    expect(code, 1);
    expect(output, ['rebuild-index is unavailable because PostgreSQL memory search is in-process.']);
    expect(File(config.searchDbPath).existsSync(), isFalse);
  });

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
    final seededDb = sqlite3.open(dbPath);
    await SqliteSchemaGate.prepareSearch(SqliteBackend(seededDb), storeName: 'search.db');
    seededDb.execute('INSERT INTO memory_chunks (text, source, created_at, locator) VALUES (?, ?, ?, ?)', [
      'stale searchable row',
      'legacy-memory',
      DateTime(2026).toIso8601String(),
      'legacy-memory',
    ]);
    seededDb.close();
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));

    await runner.run(['rebuild-index']);

    final db = sqlite3.open(dbPath);
    final index = SqliteFtsIndex(SqliteBackend(db), table: SqliteFtsTable.memoryChunks);
    expect(await index.search('stale', userId: 'owner'), isEmpty);
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

    final db = sqlite3.open(dbPath);
    final index = SqliteFtsIndex(SqliteBackend(db), table: SqliteFtsTable.memoryChunks);
    final results = await index.search('Dart', userId: 'owner');
    expect(results, isNotEmpty);
    expect(results.first.chunk, contains('Dart'));
    db.close();
  });

  test('rebuild repairs an incompatible search store and leaves the next reconciliation current', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    workspaceOf(config);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'project': ['Canonical recovery fact'],
      },
    );
    final legacy = sqlite3.open(config.searchDbPath);
    try {
      legacy.execute('''
        CREATE TABLE memory_chunks (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          text TEXT NOT NULL,
          source TEXT NOT NULL,
          category TEXT,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          user_id TEXT NOT NULL DEFAULT 'owner'
        )
      ''');
      legacy.execute("INSERT INTO memory_chunks(text, source) VALUES ('Obsolete row', 'legacy')");
    } finally {
      legacy.close();
    }

    await runCommand(config);

    expect(output.last, 'Rebuilt index: 1 entries at collection revision 2; health=healthy');
    final backend = await SqliteBackend.open(config.searchDbPath);
    try {
      expect(await backend.query('SELECT id, epoch FROM dartclaw_schema'), [
        {'id': 1, 'epoch': 1},
      ]);
      expect(
        (await SqliteSchemaGate.inspect(backend, SchemaIdentity.search, storeName: 'search.db')).state,
        SqliteSchemaState.current,
      );
      await SqliteSchemaGate.prepareSearch(backend, storeName: 'search.db');
      final index = SqliteFtsIndex(backend, table: SqliteFtsTable.memoryChunks);
      expect((await index.search('Canonical recovery', userId: 'owner')).single.chunk, 'Canonical recovery fact');
      expect(await index.search('Obsolete', userId: 'owner'), isEmpty);
    } finally {
      await backend.close();
    }

    final corpusService = MemoryCorpusService(workspaceDir: config.workspaceDir);
    try {
      final manifest = await corpusService.manifest();
      final transitions = <IndexReconcileTransition>[];
      final result =
          await CanonicalIndexReconciler(
            targetPath: config.searchDbPath,
            healthStore: IndexHealthStore(workspaceDir: config.workspaceDir),
            transitionHook: (transition) async => transitions.add(transition),
          ).ensureCurrent(
            corpus: await corpusService.readCorpus(),
            canonicalRevision: manifest.collectionRevision,
            canonicalFingerprint: manifest.fingerprint,
          );
      expect(result.rowCount, 1);
      expect(result.health.isCurrent(manifest.collectionRevision, manifest.fingerprint), isTrue);
      expect(transitions, isEmpty);
    } finally {
      await corpusService.close();
    }
  });

  test('rebuild uses the live Markdown normalization and chunk boundaries', () async {
    final longTail = List.generate(90, (index) => 'segment$index').join(' ');
    final entryText = '**Durable heading**\n\n$longTail';
    final expectedTexts = MemoryIndexProjection.document(
      text: entryText,
      source: 'ignored',
      category: 'project',
      createdAt: DateTime.utc(2026, 2, 23, 10),
    )!.chunks;
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

    final db = sqlite3.open(dbPath);
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

    final db = sqlite3.open(dbPath);
    final index = SqliteFtsIndex(SqliteBackend(db), table: SqliteFtsTable.memoryChunks);
    final current = MemoryIndexProjection.toSearchResult(
      (await index.search('Current searchable', userId: 'owner')).single,
    );
    final archived = MemoryIndexProjection.toSearchResult(
      (await index.search('Archived searchable', userId: 'owner')).single,
    );
    final learning = MemoryIndexProjection.toSearchResult((await index.search('Validate', userId: 'owner')).single);
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
    final firstDb = sqlite3.open(dbPath);
    final first = firstDb.select('SELECT created_at FROM memory_chunks').single['created_at'];
    firstDb.close();

    output.clear();
    await runner.run(['rebuild-index']);
    final secondDb = sqlite3.open(dbPath);
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

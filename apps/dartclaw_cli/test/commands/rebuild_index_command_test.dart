import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/rebuild_index_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:dartclaw_testing/dartclaw_testing.dart';

void main() {
  late Directory tempDir;
  late List<String> output;
  late Map<PostgresFtsTable, InMemoryIndexRebuildTarget> indexes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_rebuild_idx_test_');
    output = [];
    indexes = {
      PostgresFtsTable.memoryChunks: InMemoryIndexRebuildTarget(),
      PostgresFtsTable.conversationChunks: InMemoryIndexRebuildTarget(),
    };
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  RebuildIndexCommand command(DartclawConfig config, {void Function(int)? exitFn}) => RebuildIndexCommand(
    config: config,
    writeLine: output.add,
    exitFn: exitFn,
    taskBackendFactory: (_) => openPreparedTaskBackend(),
    taskBackendIsPrepared: true,
    indexFactory: (_, table) => indexes[table]!.index,
    rebuildTargetFactory: (_, table) => indexes[table]!,
  );

  Future<void> runCommand(DartclawConfig config) async {
    final runner = DartclawRunner()..addCommand(command(config));
    await runner.run(['rebuild-index']);
  }

  Directory workspaceOf(DartclawConfig config) => Directory(config.workspaceDir)..createSync(recursive: true);

  test('postgres connection refusal reports safe guidance without a local search store', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    int? code;
    final runner = DartclawRunner()
      ..addCommand(RebuildIndexCommand(config: config, writeLine: output.add, exitFn: (value) => code = value));

    await runner.run(['rebuild-index']);

    expect(code, 1);
    expect(output.last, contains('database.url'));
    expect(output.last, contains('database.credential'));
    expect(File(config.searchDbPath).existsSync(), isFalse);
    expect(File(IndexHealthStore(workspaceDir: config.workspaceDir).path).existsSync(), isFalse);
  });

  test('hybrid PostgreSQL refusal precedes authoritative preparation and never opens SQLite vectors', () async {
    final config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path),
      search: const SearchConfig(backend: 'hybrid'),
    );
    final backend = PostgresVectorSchemaTestBackend.current(extensionAvailable: false);
    var providerConstructed = false;
    int? code;
    final runner = DartclawRunner()
      ..addCommand(
        RebuildIndexCommand(
          config: config,
          writeLine: output.add,
          exitFn: (value) => code = value,
          taskBackendFactory: (_) async => backend,
          embeddingProviderFactory: () {
            providerConstructed = true;
            throw StateError('Unavailable pgvector must refuse before provider construction');
          },
        ),
      );

    await runner.run(['rebuild-index']);

    expect(code, 1);
    expect(output.last, contains('public'));
    expect(output.last, contains('vector'));
    expect(backend.executed, isEmpty);
    expect(backend.queries, hasLength(1));
    expect(backend.queries.single.sql, contains('pg_catalog.pg_extension'));
    expect(providerConstructed, isFalse);
    expect(File(config.searchDbPath).existsSync(), isFalse);
    expect(File(config.vectorsDbPath).existsSync(), isFalse);
  });

  test('bootstraps and rebuilds an empty canonical corpus', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    await runCommand(config);
    expect(output, hasLength(4));
    expect(output.first, contains('must remain stopped'));
    expect(output[1], contains('Memory preflight: alreadyCurrent'));
    expect(output[2], contains('Rebuilt index: 0 entries'));
    expect(output.last, 'Rebuilt conversation index: 0 messages from 0 sessions');
  });

  test('--json emits only the machine-readable reconciled outcome', () async {
    final config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path),
      warnings: const ['legacy setting ignored'],
    );
    final runner = DartclawRunner()..addCommand(command(config));

    await runner.run(['rebuild-index', '--json']);

    expect(output, hasLength(1));
    expect(jsonDecode(output.single), {
      'canonicalRevision': 1,
      'indexedRows': 0,
      'health': 'healthy',
      'reconciled': false,
      'conversationMessages': 0,
      'conversationSessions': 0,
    });
  });

  test('missing canonical files clear stale index rows', () async {
    Directory(p.join(tempDir.path, 'workspace')).createSync();
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    await indexes[PostgresFtsTable.memoryChunks]!.index.upsert([
      SearchDocument(
        id: 'legacy-memory',
        chunks: const ['stale searchable row'],
        metadata: const {'source': 'legacy-memory'},
        timestamp: DateTime(2026),
      ),
    ], userId: 'owner');
    final runner = DartclawRunner()..addCommand(command(config));

    await runner.run(['rebuild-index']);

    expect(await indexes[PostgresFtsTable.memoryChunks]!.index.search('stale', userId: 'owner'), isEmpty);
    expect(output[1], contains('Memory preflight: alreadyCurrent'));
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
    final runner = DartclawRunner()..addCommand(command(config));

    await runner.run(['rebuild-index']);

    expect(output, hasLength(4));
    expect(output[1], contains('Memory preflight: alreadyCurrent'));
    expect(output[2], contains('Rebuilt index: 3 entries at collection revision 2'));
    expect(output.last, 'Rebuilt conversation index: 0 messages from 0 sessions');

    final results = await indexes[PostgresFtsTable.memoryChunks]!.index.search('Dart', userId: 'owner');
    expect(results, isNotEmpty);
    expect(results.first.chunk, contains('Dart'));
  });

  test('rebuilds explicit workspace corpora independently and reports one failed binding', () async {
    final agentADir = p.join(tempDir.path, 'agents', 'a');
    final agentBDir = p.join(tempDir.path, 'agents', 'b');
    final config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path),
      agent: AgentConfig(
        definitions: [
          AgentDefinition(
            id: 'a',
            description: 'Agent A',
            prompt: 'A',
            workspace: AgentWorkspace.pinned(agentId: 'a', directory: agentADir),
          ),
          AgentDefinition(
            id: 'b',
            description: 'Agent B',
            prompt: 'B',
            workspace: AgentWorkspace.pinned(agentId: 'b', directory: agentBDir),
          ),
        ],
      ),
    );
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['owner-rebuild-marker'],
      },
    );
    await seedCanonicalMemory(
      agentADir,
      topics: const {
        'general': ['agent-a-rebuild-marker'],
      },
    );
    File(p.join(agentBDir, 'MEMORY.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('## general\n- [2026-09-14 10:00] invalid-preview-marker\n');
    int? code;
    final runner = DartclawRunner()..addCommand(command(config, exitFn: (value) => code = value));

    await runner.run(['rebuild-index']);

    final index = indexes[PostgresFtsTable.memoryChunks]!.index;
    expect((await index.search('owner-rebuild-marker', userId: 'owner')).single.chunk, 'owner-rebuild-marker');
    expect((await index.search('agent-a-rebuild-marker', userId: 'agent:a')).single.chunk, 'agent-a-rebuild-marker');
    expect(
      (await index.listRecent(userId: 'agent:a')).map((row) => row.chunk),
      isNot(contains('owner-rebuild-marker')),
    );
    expect(
      (await index.listRecent(userId: 'owner')).map((row) => row.chunk),
      isNot(contains('agent-a-rebuild-marker')),
    );
    expect(await index.search('invalid-preview-marker', userId: 'agent:b'), isEmpty);
    expect(code, 1);
    expect(output, contains(contains('agent:a: rebuilt 1 entries')));
    expect(output, contains(allOf(contains('agent:b'), contains('preflight failed'))));
    expect(output, isNot(contains(contains('agent:b: rebuilt'))));
  });

  test('--json reports configured workspace failures in its single structured result', () async {
    final invalidDir = p.join(tempDir.path, 'agents', 'invalid');
    final config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path),
      agent: AgentConfig(
        definitions: [
          AgentDefinition(
            id: 'invalid',
            description: 'Invalid corpus',
            prompt: '',
            workspace: AgentWorkspace.pinned(agentId: 'invalid', directory: invalidDir),
          ),
        ],
      ),
    );
    File(p.join(invalidDir, 'MEMORY.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('## preview\n- invalid dialect\n');
    int? code;
    final runner = DartclawRunner()..addCommand(command(config, exitFn: (value) => code = value));

    await runner.run(['rebuild-index', '--json']);

    expect(code, 1);
    expect(output, hasLength(1));
    final result = jsonDecode(output.single) as Map<String, dynamic>;
    expect(result['canonicalRevision'], 1);
    final failures = result['workspaceFailures'] as List;
    expect(failures, hasLength(1));
    final failure = failures.single as Map<String, dynamic>;
    expect(failure['principal'], 'agent:invalid');
    expect(failure['stage'], 'memory-corpus-preflight');
    expect(failure['message'], contains('legacy-dialect-detected'));
  });

  test('--json keeps a configured workspace rebuild failure in the structured result', () async {
    final agentDir = p.join(tempDir.path, 'agents', 'a');
    final config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path),
      agent: AgentConfig(
        definitions: [
          AgentDefinition(
            id: 'a',
            description: 'Agent A',
            prompt: '',
            workspace: AgentWorkspace.pinned(agentId: 'a', directory: agentDir),
          ),
        ],
      ),
    );
    await seedCanonicalMemory(
      agentDir,
      topics: const {
        'general': ['agent-a-marker'],
      },
    );
    Directory(p.join(agentDir, '.dartclaw-memory-index.json')).createSync();
    int? code;
    final runner = DartclawRunner()..addCommand(command(config, exitFn: (value) => code = value));

    await runner.run(['rebuild-index', '--json']);

    expect(code, 1);
    expect(output, hasLength(1));
    final result = jsonDecode(output.single) as Map<String, dynamic>;
    final failures = result['workspaceFailures'] as List;
    expect(failures, hasLength(1));
    final failure = failures.single as Map<String, dynamic>;
    expect(failure['principal'], 'agent:a');
    expect(failure['stage'], 'memory-index-rebuild');
    expect(failure['message'], isNotEmpty);
  });

  test('a repeated rebuild stays current and preserves only canonical rows', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    workspaceOf(config);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'project': ['Canonical recovery fact'],
      },
    );
    await indexes[PostgresFtsTable.memoryChunks]!.index.upsert([
      SearchDocument(
        id: 'legacy',
        chunks: const ['Obsolete row'],
        metadata: const {'source': 'legacy'},
        timestamp: DateTime.utc(2025),
      ),
    ], userId: 'owner');

    await runCommand(config);

    expect(output[2], 'Rebuilt index: 1 entries at collection revision 2; health=healthy');
    final index = indexes[PostgresFtsTable.memoryChunks]!.index;
    expect((await index.search('Canonical recovery', userId: 'owner')).single.chunk, 'Canonical recovery fact');
    expect(await index.search('Obsolete', userId: 'owner'), isEmpty);

    final corpusService = MemoryCorpusService(workspaceDir: config.workspaceDir);
    try {
      final manifest = await corpusService.manifest();
      final transitions = <IndexReconcileTransition>[];
      final result =
          await CanonicalIndexReconciler(
            healthStore: IndexHealthStore(workspaceDir: config.workspaceDir),
            target: indexes[PostgresFtsTable.memoryChunks]!,
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
    final runner = DartclawRunner()..addCommand(command(config));

    await runner.run(['rebuild-index']);

    final rows = await indexes[PostgresFtsTable.memoryChunks]!.index.listRecent(userId: 'owner', limit: 100);
    expect(rows.map((row) => row.chunk), expectedTexts);
    expect(rows.every((row) => row.metadata['source'] == row.id && row.metadata['category'] == 'project'), isTrue);
    expect(rows.map((row) => row.timestamp).toSet(), {DateTime.utc(2026, 2, 23, 10)});
    expect(output[2], contains('Rebuilt index: ${expectedTexts.length} entries'));
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
    final runner = DartclawRunner()..addCommand(command(config));

    await runner.run(['rebuild-index']);

    final index = indexes[PostgresFtsTable.memoryChunks]!.index;
    final current = MemoryIndexProjection.toSearchResult((await index.search('Current', userId: 'owner')).single);
    final archived = MemoryIndexProjection.toSearchResult((await index.search('Archived', userId: 'owner')).single);
    final learning = MemoryIndexProjection.toSearchResult((await index.search('Validate', userId: 'owner')).single);
    expect((current.role, current.source == current.locator, current.category), ('topic', true, 'preferences'));
    expect((archived.role, archived.source == archived.locator, archived.category), ('archive', true, 'project'));
    expect((learning.role, learning.source == learning.locator, learning.category), ('learning', true, null));
    expect(output[2], contains('Rebuilt index: 3 entries'));
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
    final runner = DartclawRunner()..addCommand(command(config));

    await runner.run(['rebuild-index']);
    final index = indexes[PostgresFtsTable.memoryChunks]!.index;
    final first = (await index.listRecent(userId: 'owner')).single.timestamp;

    output.clear();
    await runner.run(['rebuild-index']);
    final second = (await index.listRecent(userId: 'owner')).single.timestamp;

    expect(first, DateTime.utc(2025));
    expect(second, first);
  });

  test('a preview-dialect workspace is refused with the same message serve emits', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final wsDir = workspaceOf(config);
    final memory = File(p.join(wsDir.path, 'MEMORY.md'))
      ..writeAsStringSync('## preferences\n- [2026-02-23 10:00] Preview dialect entry\n');
    int? code;
    final runner = DartclawRunner()..addCommand(command(config, exitFn: (value) => code = value));

    await runner.run(['rebuild-index']);

    expect(code, 1);
    expect(output.last, 'Memory index rebuild failed. Check index health and retry rebuild-index.');
    expect(memory.readAsStringSync(), '## preferences\n- [2026-02-23 10:00] Preview dialect entry\n');
    expect(File(p.join(tempDir.path, 'search.db')).existsSync(), isFalse);
  });

  test('rejects a symlinked legacy memory file without reading its target', () async {
    final wsDir = workspaceOf(DartclawConfig(server: ServerConfig(dataDir: tempDir.path)));
    final external = File(p.join(tempDir.path, 'external-memory.md'))
      ..writeAsStringSync('## general\n- [2026-02-23 10:00] External fact\n');
    Link(p.join(wsDir.path, 'MEMORY.archive.md')).createSync(external.path);
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    int? code;
    final runner = DartclawRunner()..addCommand(command(config, exitFn: (value) => code = value));

    await runner.run(['rebuild-index']);

    expect(code, 1);
    expect(output.last, 'Memory index rebuild failed. Check index health and retry rebuild-index.');
    expect(external.readAsStringSync(), contains('External fact'));
  }, skip: Platform.isWindows);
}

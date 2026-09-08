@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/rebuild_index_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show seedCanonicalMemory;
import 'package:test/test.dart';

import '../../../../packages/dartclaw_core/test/storage/postgres_live_support.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('dartclaw_rebuild_postgres_'));
  tearDown(() => temp.deleteSync(recursive: true));

  DartclawConfig config({String language = 'english'}) => DartclawConfig(
    server: ServerConfig(dataDir: temp.path),
    database: DatabaseConfig(backend: DatabaseBackendKind.postgres, ftsLanguage: language),
  );

  test('transactional rebuild retains prior rows on every pre-publication failure', () async {
    await withPostgresBackend((backend, namespace) async {
      final settings = config();
      await seedCanonicalMemory(
        settings.workspaceDir,
        topics: const {
          'snapshots': ['snapshot alpha', 'snapshot beta', 'snapshot gamma'],
        },
      );
      final initial = await _run(settings, namespace);
      expect(initial.code, 0);
      expect(initial.lines.last, 'Rebuilt index: 3 entries at collection revision 2; health=healthy');
      final index = PostgresFtsIndex(backend, table: PostgresFtsTable.memoryChunks, language: 'english');
      await seedCanonicalMemory(
        settings.workspaceDir,
        topics: const {
          'snapshots': ['snapshot alpha', 'snapshot beta', 'snapshot gamma', 'snapshot delta'],
        },
      );
      final corpus = MemoryCorpusService(workspaceDir: settings.workspaceDir);
      final manifest = await corpus.manifest();
      await corpus.close();
      final health = IndexHealthStore(workspaceDir: settings.workspaceDir);
      for (final stage in [
        IndexReconcileTransition.populated,
        IndexReconcileTransition.validated,
        IndexReconcileTransition.beforeSwap,
      ]) {
        final result = await _run(
          settings,
          namespace,
          reconciler: CanonicalIndexReconciler(
            healthStore: health,
            target: TransactionalRebuildTarget(
              backend,
              indexFactory: (tx) =>
                  PostgresFtsIndex.withinTransaction(tx, table: PostgresFtsTable.memoryChunks, language: 'english'),
            ),
            transitionHook: (transition) async {
              if (transition == stage) throw StateError('injected publication failure');
            },
          ),
        );
        expect(result.code, 1, reason: stage.name);
        expect(
          (await index.search('snapshot', userId: 'owner')).map((hit) => hit.chunk),
          unorderedEquals(['snapshot alpha', 'snapshot beta', 'snapshot gamma']),
        );
        final evidence = await health.read(
          canonicalRevision: manifest.collectionRevision,
          canonicalFingerprint: manifest.fingerprint,
        );
        expect(evidence.state, IndexHealthState.degraded);
        expect(evidence.failureStage, stage.name);
      }
      final result = await _run(settings, namespace);
      expect(result.code, 0);
      expect(
        result.lines.last,
        'Rebuilt index: 4 entries at collection revision ${manifest.collectionRevision}; health=healthy',
      );
      expect(
        (await index.search('snapshot', userId: 'owner')).map((hit) => hit.chunk),
        unorderedEquals(['snapshot alpha', 'snapshot beta', 'snapshot gamma', 'snapshot delta']),
      );
      final evidence = await health.read(
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
      );
      expect(evidence.isCurrent(manifest.collectionRevision, manifest.fingerprint), isTrue);
      expect(_databaseFiles(temp), isEmpty);
      final json = await _run(settings, namespace, json: true);
      expect(json.code, 0);
      expect(jsonDecode(json.lines.single), {
        'canonicalRevision': manifest.collectionRevision,
        'indexedRows': 4,
        'health': 'healthy',
        'reconciled': false,
      });
    });
  });

  test('unknown language refuses without writing index health evidence', () async {
    await withPostgresBackend((_, namespace) async {
      final settings = config(language: 'klingon');
      final result = await _run(settings, namespace);
      expect(result.code, 1);
      for (final expected in ['database.fts_language', 'klingon', 'english', 'swedish']) {
        expect(result.lines.last, contains(expected));
      }
      expect(result.lines.join('\n').contains(Platform.environment['DARTCLAW_TEST_POSTGRES_URL']!), isFalse);
      expect(File(IndexHealthStore(workspaceDir: settings.workspaceDir).path).existsSync(), isFalse);
      expect(_databaseFiles(temp), isEmpty);
    });
  });

  test('rebuild applies a changed memory language while preserving output shape', () async {
    await withPostgresBackend((backend, namespace) async {
      final english = config();
      await seedCanonicalMemory(
        english.workspaceDir,
        topics: const {
          'activity': ['hunden springer snabbt'],
        },
      );
      expect((await _run(english, namespace)).code, 0);
      final swedishIndex = PostgresFtsIndex(backend, table: PostgresFtsTable.memoryChunks, language: 'swedish');
      expect(await swedishIndex.search('springa', userId: 'owner'), isEmpty);
      final result = await _run(config(language: 'swedish'), namespace);
      expect(result.code, 0);
      expect(result.lines.last, 'Rebuilt index: 1 entries at collection revision 2; health=healthy');
      expect((await swedishIndex.search('springa', userId: 'owner')).map((hit) => hit.chunk), [
        'hunden springer snabbt',
      ]);
      expect(_databaseFiles(temp), isEmpty);
    });
  });
}

Future<({int code, List<String> lines})> _run(
  DartclawConfig config,
  String namespace, {
  CanonicalIndexReconciler? reconciler,
  bool json = false,
}) async {
  final lines = <String>[];
  var code = 0;
  final uri = Uri.parse(Platform.environment['DARTCLAW_TEST_POSTGRES_URL']!);
  final dsn = uri.replace(queryParameters: {...uri.queryParameters, 'sslmode': 'disable'}).toString();
  final runner = DartclawRunner()
    ..addCommand(
      RebuildIndexCommand(
        config: config,
        writeLine: lines.add,
        exitFn: (value) => code = value,
        indexReconciler: reconciler,
        taskBackendFactory: (_) => PostgresBackend.open(dsn: dsn, poolSize: 3, namespace: namespace),
      ),
    );
  await runner.run(['rebuild-index', if (json) '--json']);
  return (code: code, lines: lines);
}

List<String> _databaseFiles(Directory directory) => directory
    .listSync(recursive: true)
    .whereType<File>()
    .map((file) => file.path)
    .where((path) => path.contains('.db') || path.contains('.dartclaw-rebuild-'))
    .toList();

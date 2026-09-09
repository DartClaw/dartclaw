@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/rebuild_index_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show seedCanonicalMemory, CallbackEmbeddingProvider;
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

  test('hybrid PostgreSQL rebuild reuses both corpora, recovers failures and clears empty sources', () async {
    await withPostgresBackend((backend, namespace) async {
      final settings = DartclawConfig(
        server: ServerConfig(dataDir: temp.path),
        database: const DatabaseConfig(backend: DatabaseBackendKind.postgres),
        search: const SearchConfig(backend: 'hybrid'),
      );
      await seedCanonicalMemory(
        settings.workspaceDir,
        topics: {
          'preferences': ['memoryneedle likes tea'],
        },
      );
      final sessions = SessionService(baseDir: settings.sessionsDir);
      final messages = MessageService(baseDir: settings.sessionsDir);
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'conversationneedle likes coffee');
      await messages.dispose();
      var embedded = 0;
      var failEmbedding = true;
      EmbeddingProvider provider() => CallbackEmbeddingProvider(
        embedDocuments: (documents) async {
          if (failEmbedding) throw const FileSystemException('model unavailable');
          embedded += documents.length;
          return [
            for (final _ in documents) [1.0, 0.0],
          ];
        },
      );

      final degraded = await _run(settings, namespace, json: true, embeddingProviderFactory: provider);
      expect(degraded.code, 0, reason: degraded.lines.join('\n'));
      final degradedData = jsonDecode(degraded.lines.single) as Map<String, dynamic>;
      expect(degradedData['memoryUnembeddedCount'], 1);
      expect(degradedData['conversationUnembeddedCount'], 1);
      expect(degradedData['vectorDegradedCorpora'], ['memory', 'conversation']);
      expect(
        await PostgresFtsIndex(
          backend,
          table: PostgresFtsTable.memoryChunks,
          language: 'english',
        ).search('memoryneedle', userId: 'owner'),
        isNotEmpty,
      );
      expect(
        await PostgresFtsIndex(
          backend,
          table: PostgresFtsTable.conversationChunks,
          language: 'english',
        ).search('conversationneedle', userId: 'owner'),
        isNotEmpty,
      );

      failEmbedding = false;
      final recovered = await _run(settings, namespace, json: true, embeddingProviderFactory: provider);
      expect(recovered.code, 0);
      final recoveredData = jsonDecode(recovered.lines.single) as Map<String, dynamic>;
      expect(recoveredData['memoryUnembeddedCount'], 0);
      expect(recoveredData['conversationUnembeddedCount'], 0);
      expect(embedded, 2);
      expect((await PostgresVectorIndex(backend, table: VectorTable.memoryChunks).list(userId: 'owner')), hasLength(1));
      expect(
        (await PostgresVectorIndex(backend, table: VectorTable.conversationChunks).list(userId: 'owner')),
        hasLength(1),
      );
      expect((await _run(settings, namespace, json: true, embeddingProviderFactory: provider)).code, 0);
      expect(embedded, 2, reason: 'a second lexical publication must reuse matching vector rows');

      await seedCanonicalMemory(settings.workspaceDir);
      await Directory(settings.sessionsDir).delete(recursive: true);
      final cleared = await _run(settings, namespace, json: true, embeddingProviderFactory: provider);
      expect(cleared.code, 0);
      expect(await PostgresVectorIndex(backend, table: VectorTable.memoryChunks).list(userId: 'owner'), isEmpty);
      expect(await PostgresVectorIndex(backend, table: VectorTable.conversationChunks).list(userId: 'owner'), isEmpty);
      expect(_databaseFiles(temp), isEmpty);
    });
  });

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
      expect(initial.lines[2], 'Rebuilt index: 3 entries at collection revision 2; health=healthy');
      expect(initial.lines.last, 'Rebuilt conversation index: 0 messages from 0 sessions');
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
        expect(evidence.failureStage, switch (stage) {
          IndexReconcileTransition.populated => 'populate',
          IndexReconcileTransition.validated => 'validate',
          IndexReconcileTransition.beforeSwap => 'swap',
          _ => throw StateError('Uncovered failure stage'),
        });
      }
      final result = await _run(settings, namespace);
      expect(result.code, 0);
      expect(
        result.lines[2],
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
        'conversationMessages': 0,
        'conversationSessions': 0,
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

  test('rebuild applies a changed language to memory and conversation search', () async {
    await withPostgresBackend((backend, namespace) async {
      final english = config();
      await seedCanonicalMemory(
        english.workspaceDir,
        topics: const {
          'activity': ['hunden springer snabbt'],
        },
      );
      final sessions = SessionService(baseDir: english.sessionsDir);
      final messages = MessageService(baseDir: english.sessionsDir);
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'hunden springer snabbt');
      await messages.dispose();
      expect((await _run(english, namespace)).code, 0);
      final swedishIndex = PostgresFtsIndex(backend, table: PostgresFtsTable.memoryChunks, language: 'swedish');
      final swedishConversation = PostgresFtsIndex(
        backend,
        table: PostgresFtsTable.conversationChunks,
        language: 'swedish',
      );
      expect(await swedishIndex.search('springa', userId: 'owner'), isEmpty);
      expect(await swedishConversation.search('springa', userId: 'owner'), isEmpty);
      final result = await _run(config(language: 'swedish'), namespace);
      expect(result.code, 0);
      expect(result.lines[2], 'Rebuilt index: 1 entries at collection revision 2; health=healthy');
      expect(result.lines.last, 'Rebuilt conversation index: 1 messages from 1 sessions');
      expect((await swedishIndex.search('springa', userId: 'owner')).map((hit) => hit.chunk), [
        'hunden springer snabbt',
      ]);
      expect((await swedishConversation.search('springa', userId: 'owner')).map((hit) => hit.chunk), [
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
  EmbeddingProvider Function()? embeddingProviderFactory,
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
        embeddingProviderFactory: embeddingProviderFactory,
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

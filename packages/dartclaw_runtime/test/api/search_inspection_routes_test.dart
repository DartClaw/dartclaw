import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/api/search_inspection_routes.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Request request(Object? body) =>
    Request('POST', Uri.parse('http://localhost/api/search/inspect'), body: jsonEncode(body));

void main() {
  for (final corpus in ['memory', 'conversation']) {
    for (final fallback in [false, true]) {
      test(
        '$corpus preserves identity, bounded snippets and ${fallback ? 'lexical' : 'hybrid'} order/scores',
        () async {
          final backend = SqliteBackend(sqlite3.openInMemory());
          await SqliteSchemaGate.prepareSearch(backend, storeName: 'search.db');
          addTearDown(backend.close);
          final index = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
          final ids = [for (var i = 1; i <= 3; i++) '00000000-0000-4000-8000-00000000000$i'];
          final text = '${List.filled(241, '😀').join()}SECRET_TAIL';
          final hits = [
            for (var i = 0; i < 3; i++)
              SearchResult(
                id: ids[i],
                chunkIndex: i,
                chunk: text,
                timestamp: DateTime.utc(2026),
                score: fallback ? -30.0 + i : -0.03 + i * 0.01,
                metadata: {
                  'session_id': 'session',
                  'role': corpus == 'memory' ? 'topic' : 'assistant',
                  'entry_id': ids[i],
                  'entry_revision': '2',
                  'provenance': 'fixture',
                  'secret': 'RAW_METADATA',
                },
              ),
          ];
          final evidence = SearchDiagnostics(
            candidates: [
              for (var i = 0; i < 3; i++)
                SearchRankEvidence(
                  documentId: ids[i],
                  chunkIndex: i,
                  keywordRank: i == 1 ? null : i + 1,
                  vectorRank: i == 0 ? null : i + 1,
                  keywordContribution: i == 1 ? 0 : .01,
                  vectorContribution: i == 0 ? 0 : .02,
                  fusedScore: (i == 1 ? 0 : .01) + (i == 0 ? 0 : .02),
                  sourceLayer: corpus,
                ),
            ],
            unembeddedCount: 7,
            degradations: [MemorySearchDegradation(layer: corpus, reason: 'vector_unavailable')],
          );
          String? owner;
          Future<List<SearchResult>> query(
            String value, {
            required String userId,
            required int limit,
            SearchDiagnosticsSink? diagnostics,
          }) async {
            expect(value, ' query ');
            expect(limit, 3);
            owner = userId;
            diagnostics?.call(evidence);
            return hits;
          }

          final router = searchInspectionRoutes(
            inspectMemory: (value, {limit = 20, diagnostics}) =>
                query(value, userId: 'bound-owner', limit: limit, diagnostics: diagnostics),
            conversations: ConversationSearchService(index: index, userId: 'bound-owner', query: query),
          );
          final response = await router.call(request({'corpus': corpus, 'query': ' query ', 'limit': 3}));
          expect(response.statusCode, 200);
          final raw = await response.readAsString();
          expect(raw, isNot(contains('SECRET_TAIL')));
          expect(raw, isNot(contains('RAW_METADATA')));
          final body = jsonDecode(raw) as Map<String, dynamic>;
          expect(body.keys, ['corpus', 'results', 'diagnostics']);
          expect(owner, 'bound-owner');
          final results = body['results'] as List;
          expect(results.map((dynamic result) => result['documentId']), ids);
          expect(results.map((dynamic result) => result['chunkIndex']), [0, 1, 2]);
          expect(results.map((dynamic result) => result['score']), hits.map((hit) => hit.score));
          for (final result in results.cast<Map<String, dynamic>>()) {
            expect((result['snippet'] as String).runes.length, 240);
            expect(
              result.keys.toSet(),
              corpus == 'memory'
                  ? {
                      'documentId',
                      'chunkIndex',
                      'role',
                      'snippet',
                      'provenance',
                      'locator',
                      'score',
                      'entryId',
                      'entryRevision',
                    }
                  : {'documentId', 'chunkIndex', 'messageId', 'sessionId', 'role', 'createdAt', 'snippet', 'score'},
            );
            if (corpus == 'memory') {
              expect(result['locator'], result['documentId']);
              expect(result['entryRevision'], 2);
            } else {
              expect(result['messageId'], result['documentId']);
              expect(result['sessionId'], 'session');
              expect(result['createdAt'], '2026-01-01T00:00:00.000Z');
            }
          }
          final diagnostics = body['diagnostics'] as Map;
          expect(diagnostics.keys, ['candidates', 'unembeddedCount', 'degradations']);
          expect(diagnostics['unembeddedCount'], 7);
          expect((diagnostics['degradations'] as List).single, {
            'layer': corpus,
            'reason': 'vector_unavailable',
            'omittedCount': 0,
          });
          final candidates = diagnostics['candidates'] as List;
          expect(candidates[0]['vectorRank'], isNull);
          expect(candidates[1]['keywordRank'], isNull);
          for (var i = 0; i < 3; i++) {
            expect(candidates[i], {
              'documentId': ids[i],
              'chunkIndex': i,
              'keywordRank': evidence.candidates[i].keywordRank,
              'vectorRank': evidence.candidates[i].vectorRank,
              'keywordContribution': evidence.candidates[i].keywordContribution,
              'vectorContribution': evidence.candidates[i].vectorContribution,
              'fusedScore': evidence.candidates[i].fusedScore,
              'sourceLayer': corpus,
            });
          }
        },
      );
    }
  }

  test('conversation provenance mapping failure does not release earlier diagnostics', () async {
    final backend = SqliteBackend(sqlite3.openInMemory());
    await SqliteSchemaGate.prepareSearch(backend, storeName: 'search.db');
    addTearDown(backend.close);
    final index = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
    final service = ConversationSearchService(
      index: index,
      query: (_, {required userId, required limit, diagnostics}) async {
        diagnostics?.call(SearchDiagnostics(candidates: const []));
        return [SearchResult(id: 'broken', chunk: 'PRIVATE', chunkIndex: 0, timestamp: DateTime.utc(2026), score: 1)];
      },
    );
    final response = await searchInspectionRoutes(conversations: service)
        .call(request({'corpus': 'conversation', 'query': 'x'}));
    expect(response.statusCode, 503);
    expect((jsonDecode(await response.readAsString()) as Map).keys, ['error']);
  });

  final badBodies = <Object?>[
    null,
    [],
    {},
    {'corpus': 'wiki', 'query': 'x'},
    {'corpus': 'memory', 'query': ' '},
    {'corpus': 'memory', 'query': 1},
    {'corpus': 'memory', 'query': 'x', 'unexpected': true},
    for (final limit in [null, 0, 21, 1.5, '2']) {'corpus': 'memory', 'query': 'x', 'limit': limit},
  ];
  for (var i = 0; i < badBodies.length; i++) {
    test('invalid closed request $i is refused before querying', () async {
      final router = searchInspectionRoutes(
        inspectMemory: (_, {limit = 20, diagnostics}) => throw StateError('must not query'),
      );
      final response = await router.call(request(badBodies[i]));
      expect(response.statusCode, 400);
      expect((jsonDecode(await response.readAsString()) as Map)['error']['code'], 'INVALID_INPUT');
    });
  }
  test('malformed JSON is refused and omitted limit is twenty', () async {
    final router = searchInspectionRoutes(
      inspectMemory: (_, {limit = 20, diagnostics}) async {
        expect(limit, 20);
        diagnostics?.call(SearchDiagnostics(candidates: const []));
        return [];
      },
    );
    expect(
      (await router.call(Request('POST', Uri.parse('http://localhost/api/search/inspect'), body: '{'))).statusCode,
      400,
    );
    expect((await router.call(request({'corpus': 'memory', 'query': 'x'}))).statusCode, 200);
  });
  for (final mode in ['unwired', 'no diagnostics', 'failed', 'null with diagnostics']) {
    test('$mode cannot release inspection data', () async {
      final router = searchInspectionRoutes(
        inspectMemory: mode == 'unwired'
            ? null
            : (_, {limit = 20, diagnostics}) async {
                if (mode == 'failed') throw StateError('SECRET');
                if (mode == 'null with diagnostics') {
                  diagnostics?.call(SearchDiagnostics(candidates: const []));
                  return null;
                }
                return [];
              },
      );
      for (final corpus in ['memory', 'conversation']) {
        final response = await router.call(request({'corpus': corpus, 'query': 'x'}));
        expect(response.statusCode, 503);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body.keys, ['error']);
        expect(body['error']['code'], 'SEARCH_INSPECTION_UNAVAILABLE');
        expect(body.toString(), isNot(contains('SECRET')));
      }
    });
  }

  for (final phase in ['stale before', 'changed during', 'health unavailable']) {
    test('$phase in real storage never exposes hits or buffered diagnostics', () async {
      final root = Directory.systemTemp.createTempSync('inspection_health_');
      final config = DartclawConfig(
        server: ServerConfig(dataDir: root.path),
        search: const SearchConfig(backend: 'hybrid'),
      );
      await seedCanonicalMemory(
        config.workspaceDir,
        topics: const {
          'preferences': ['needle prefers tea'],
        },
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final wiring = StorageWiring(
        config: config,
        eventBus: EventBus(),
        exitFn: (code) => throw StateError('$code'),
        searchRelevanceTurn: (_, schema) async => {
          for (final key in (schema['properties'] as Map).keys) key as String: true,
        },
        embeddingProviderFactory: () => CallbackEmbeddingProvider(
          embedQuery: (_) async {
            entered.complete();
            await release.future;
            return [1, 0];
          },
        ),
      );
      await wiring.wire();
      try {
        if (phase == 'stale before') {
          final manifest = await wiring.memoryCorpus.manifest();
          await wiring.indexHealth.recordDegraded(
            canonicalRevision: manifest.collectionRevision,
            canonicalFingerprint: manifest.fingerprint,
            stage: 'fixture',
            reason: 'fixture',
          );
        } else if (phase == 'health unavailable') {
          File(wiring.indexHealth.path).writeAsStringSync('invalid');
        }
        final pending = searchInspectionRoutes(inspectMemory: wiring.inspectMemorySearch)
            .call(request({'corpus': 'memory', 'query': 'needle'}));
        if (phase == 'changed during') {
          await entered.future;
          await wiring.memoryFile.appendDailyLog('new revision');
          release.complete();
        }
        final response = await pending;
        expect(response.statusCode, 503);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body.keys, ['error']);
        expect(body['error']['code'], 'SEARCH_INSPECTION_UNAVAILABLE');
      } finally {
        if (!release.isCompleted) release.complete();
        await wiring.dispose();
        root.deleteSync(recursive: true);
      }
    });
  }
}

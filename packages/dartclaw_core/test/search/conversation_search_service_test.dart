import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late SqliteBackend backend;
  late SqliteFtsIndex index;

  setUp(() async {
    backend = SqliteBackend(sqlite3.openInMemory());
    await SqliteSchemaGate.prepareSearch(backend, storeName: 'search.db');
    index = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
    await index.upsert([_message('owner-message', 'owner-session', 'shared exact marker')], userId: 'owner');
    await index.upsert([_message('agent-message', 'agent-session', 'shared exact marker')], userId: 'agent:a');
  });

  tearDown(() => backend.close());

  test('agent entry point stays principal-local while admin aggregation is explicitly scoped', () async {
    final service = ConversationSearchService(index: index, userId: 'agent:a', userIds: const {'owner', 'agent:a'});

    expect((await service.search('marker')).map((hit) => hit.messageId), ['agent-message']);
    final admin = await service.searchAdministrative('marker');
    expect(admin.succeeded, isTrue);
    expect(admin.total, 2);
    expect(admin.hits.map((hit) => hit.messageId).toSet(), {'owner-message', 'agent-message'});
  });

  test('session scope is applied before total and page limit', () async {
    final service = ConversationSearchService(index: index, userIds: const {'owner', 'agent:a'});

    final outcome = await service.searchAdministrative('marker', sessionIds: const {'agent-session'}, limit: 1);

    expect(outcome.total, 1);
    expect(outcome.hits.single.sessionId, 'agent-session');
    expect(outcome.hits.single.messageId, 'agent-message');
    expect(outcome.hits.single.chunkIndex, 0);
  });

  test('large excluded corpus never consumes scoped candidates or the page budget', () async {
    await index.upsert([
      for (var i = 0; i < 300; i++) _message('excluded-$i', 'excluded-session', 'bounded marker'),
      _message('eligible-a', 'eligible-session', 'bounded marker'),
      _message('eligible-b', 'eligible-session', 'bounded marker'),
      _message('eligible-c', 'eligible-session', 'bounded marker'),
    ], userId: 'owner');
    FullTextSearchScope? receivedScope;
    int? receivedLimit;
    final service = ConversationSearchService(
      index: index,
      query: (query, {required userId, required limit, scope, diagnostics}) {
        receivedScope = scope;
        receivedLimit = limit;
        return index.searchScoped(query, userId: userId, scope: scope!, limit: limit);
      },
    );

    final outcome = await service.searchAdministrative(
      'bounded marker',
      sessionIds: const {'eligible-session'},
      limit: 2,
    );

    expect(receivedScope!.acceptedValues, {'eligible-session'});
    expect(receivedLimit, 2);
    expect(outcome.total, 3);
    expect(outcome.hits, hasLength(2));
    expect(outcome.hits.every((hit) => hit.sessionId == 'eligible-session'), isTrue);
  });

  test('multi-principal merge normalizes backend-native scores by stable principal rank', () async {
    final service = ConversationSearchService(
      index: _RankedIndex({
        'owner': [_result('owner-first', -100), _result('owner-second', -1)],
        'agent:a': [_result('agent-first', 100), _result('agent-second', 1)],
      }),
      userIds: const {'owner', 'agent:a'},
    );

    final outcome = await service.searchAdministrative('marker', limit: 4);

    expect(outcome.total, 4);
    expect(outcome.hits.map((hit) => hit.messageId), ['agent-first', 'owner-first', 'agent-second', 'owner-second']);
    expect(outcome.hits.map((hit) => hit.score), [100, -100, 1, -1]);
  });

  test('backend failure is not reported as an empty successful search', () async {
    final service = ConversationSearchService(index: _FailingIndex());

    final outcome = await service.searchAdministrative('marker');

    expect(outcome.succeeded, isFalse);
    expect(outcome.failure, 'SEARCH_BACKEND_UNAVAILABLE');
    expect(outcome.hits, isEmpty);
  });
}

SearchDocument _message(String id, String sessionId, String content) => SearchDocument(
  id: id,
  chunks: [content],
  metadata: {'session_id': sessionId, 'role': 'user'},
  timestamp: DateTime.utc(2026, 9, 14),
);

final class _FailingIndex implements FullTextIndex {
  @override
  Future<int> count({required String userId, Map<String, String> metadata = const {}}) => throw StateError('offline');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SearchResult _result(String id, double score) => SearchResult(
  id: id,
  chunk: 'marker',
  chunkIndex: 0,
  metadata: const {'session_id': 'session', 'role': 'assistant'},
  timestamp: DateTime.utc(2026),
  score: score,
);

final class _RankedIndex implements ScopedFullTextIndex {
  const new(this.results);

  final Map<String, List<SearchResult>> results;

  @override
  Future<int> countMatches(String naturalLanguageQuery, {required String userId, FullTextSearchScope? scope}) async =>
      results[userId]?.length ?? 0;

  @override
  Future<List<SearchResult>> search(String naturalLanguageQuery, {required String userId, int limit = 20}) async =>
      (results[userId] ?? const []).take(limit).toList(growable: false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

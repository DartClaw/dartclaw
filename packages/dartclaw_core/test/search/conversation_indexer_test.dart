import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late SessionService sessions;
  late MessageService messages;
  late SqliteBackend backend;
  late FullTextIndex index;
  late ConversationIndexer indexer;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('conversation_indexer_');
    sessions = SessionService(baseDir: root.path);
    messages = MessageService(baseDir: root.path);
    backend = SqliteBackend(sqlite3.openInMemory());
    await SqliteSchemaGate.prepareSearch(backend, storeName: 'search.db');
    index = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
    indexer = ConversationIndexer(index: index, sessions: sessions, messages: messages);
    sessions.registerObserver(indexer);
    messages.registerObserver(indexer);
  });

  tearDown(() async {
    await indexer.idle;
    await messages.dispose();
    await backend.close();
    root.deleteSync(recursive: true);
  });

  test('append indexes user and assistant roles while excluding internal content and session types', () async {
    final chat = await sessions.createSession();
    final task = await sessions.createSession(type: SessionType.task);
    final user = await messages.insertMessage(sessionId: chat.id, role: 'user', content: 'retry policy question');
    final assistant = await messages.insertMessage(
      sessionId: chat.id,
      role: 'assistant',
      content: 'retry policy answer retry policy',
    );
    await messages.insertMessage(sessionId: chat.id, role: 'system', content: 'retry policy hidden');
    await messages.insertMessage(sessionId: task.id, role: 'assistant', content: 'retry policy internal');
    await indexer.idle;

    final hits = await ConversationSearchService(index: index).search('retry policy');
    expect(hits.map((hit) => hit.messageId).toSet(), {user.id, assistant.id});
    expect(hits.every((hit) => hit.sessionId == chat.id), isTrue);
    expect(hits.map((hit) => hit.score).toList(), orderedEquals([...hits.map((hit) => hit.score)]..sort()));
  });

  test('queued append followed by delete removes only the deletable session', () async {
    final user = await sessions.createSession();
    final channel = await sessions.createSession(type: SessionType.channel);
    await messages.insertMessage(sessionId: user.id, role: 'user', content: 'delete target');
    final retained = await messages.insertMessage(sessionId: channel.id, role: 'assistant', content: 'keep target');

    await sessions.deleteSession(user.id);
    await expectLater(sessions.deleteSession(channel.id), throwsStateError);
    await indexer.idle;

    expect(Directory('${root.path}/${user.id}').existsSync(), isFalse);
    expect(await index.search('delete', userId: 'owner'), isEmpty);
    expect((await index.search('keep', userId: 'owner')).single.id, retained.id);
  });

  test('allowed deletion with malformed metadata still removes indexed rows', () async {
    final session = await sessions.createSession();
    await messages.insertMessage(sessionId: session.id, role: 'user', content: 'malformed cleanup');
    await indexer.idle;
    File('${root.path}/${session.id}/meta.json').writeAsStringSync('{malformed');

    await sessions.deleteSession(session.id);
    await indexer.idle;

    expect(await index.search('malformed', userId: 'owner'), isEmpty);
  });

  test('clear and archive remove rows and restore reprojects retained NDJSON', () async {
    final cleared = await sessions.createSession();
    final resumed = await sessions.createSession();
    await messages.insertMessage(sessionId: cleared.id, role: 'user', content: 'clearable');
    final retained = await messages.insertMessage(sessionId: resumed.id, role: 'assistant', content: 'resumable');
    await indexer.idle;

    await messages.clearMessages(cleared.id);
    await sessions.updateSessionType(resumed.id, SessionType.archive);
    await indexer.idle;
    expect(await index.search('clearable resumable', userId: 'owner'), isEmpty);
    expect(File('${root.path}/${resumed.id}/messages.ndjson').existsSync(), isTrue);

    await sessions.updateSessionType(resumed.id, SessionType.user);
    await indexer.idle;
    expect((await index.search('resumable', userId: 'owner')).single.id, retained.id);
  });

  test('owner cleanup cannot remove another tenant or memory corpus row', () async {
    final session = await sessions.createSession();
    final message = await messages.insertMessage(sessionId: session.id, role: 'user', content: 'shared marker');
    await indexer.idle;
    await index.upsert([
      SearchDocument(
        id: message.id,
        chunks: const ['other marker'],
        metadata: {'session_id': session.id, 'role': 'user'},
        timestamp: DateTime.utc(2026),
      ),
    ], userId: 'other');
    final memory = SqliteFtsIndex(backend, table: SqliteFtsTable.memoryChunks);
    await memory.upsert([
      SearchDocument(
        id: 'memory',
        chunks: const ['memory marker'],
        metadata: const {'source': 'memory', 'role': 'memory', 'provenance': 'unknown'},
        timestamp: DateTime.utc(2026),
      ),
    ], userId: 'owner');

    await sessions.deleteSession(session.id);
    await indexer.idle;

    expect(await index.fetch([message.id], userId: 'owner'), isEmpty);
    expect((await index.fetch([message.id], userId: 'other')).single.chunks, ['other marker']);
    expect((await memory.fetch(['memory'], userId: 'owner')).single.chunks, ['memory marker']);
  });

  test('index failure does not fail persistence and is logged once', () async {
    final failingRoot = Directory.systemTemp.createTempSync('conversation_index_failure_');
    final failingSessions = SessionService(baseDir: failingRoot.path);
    final failingMessages = MessageService(baseDir: failingRoot.path);
    final failingIndexer = ConversationIndexer(
      index: _ThrowingIndex(),
      sessions: failingSessions,
      messages: failingMessages,
    );
    failingSessions.registerObserver(failingIndexer);
    failingMessages.registerObserver(failingIndexer);
    final records = <LogRecord>[];
    final priorLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await failingIndexer.idle;
      await failingMessages.dispose();
      await subscription.cancel();
      Logger.root.level = priorLevel;
      failingRoot.deleteSync(recursive: true);
    });
    final session = await failingSessions.createSession();

    final message = await failingMessages.insertMessage(sessionId: session.id, role: 'user', content: 'durable');
    await failingIndexer.idle;

    expect((await failingMessages.getMessages(session.id)).single.id, message.id);
    expect(records.where((record) => record.loggerName == 'ConversationIndexer'), hasLength(1));
  });

  group('ConversationSearchService', () {
    test('returns exact provenance fields and degrades to empty', () async {
      final session = await sessions.createSession();
      final message = await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'searchable');
      await indexer.idle;

      final hit = (await ConversationSearchService(index: index).search('searchable')).single;
      expect(hit.messageId, message.id);
      expect(hit.sessionId, session.id);
      expect(hit.role, 'assistant');
      expect(hit.createdAt, message.createdAt.toUtc());
      expect(hit.text, message.content);
      expect(await ConversationSearchService(index: _ThrowingIndex()).search('anything'), isEmpty);
    });
  });
}

final class _ThrowingIndex implements FullTextIndex {
  Never _fail() => throw StateError('index unavailable');

  @override
  Future<int> count({required String userId, Map<String, String> metadata = const {}}) async => _fail();

  @override
  Future<void> delete(Iterable<String> ids, {required String userId}) async => _fail();

  @override
  Future<List<SearchDocument>> fetch(Iterable<String> ids, {required String userId}) async => _fail();

  @override
  Future<List<SearchResult>> listRecent({required String userId, int limit = 20}) async => _fail();

  @override
  Future<void> replaceAll(Iterable<SearchDocument> documents, {required String userId}) async => _fail();

  @override
  Future<List<SearchResult>> search(String naturalLanguageQuery, {required String userId, int limit = 20}) async =>
      _fail();

  @override
  Future<void> upsert(
    Iterable<SearchDocument> documents, {
    required String userId,
    Set<String> retire = const {},
  }) async => _fail();

  @override
  Future<void> verifyIntegrity() async => _fail();
}

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
  late List<_VectorSynchronization> vectorSynchronizations;
  late Future<void> Function(Iterable<String> documentIds, {required String userId}) vectorCallback;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('conversation_indexer_');
    sessions = SessionService(baseDir: root.path);
    messages = MessageService(baseDir: root.path);
    backend = SqliteBackend(sqlite3.openInMemory());
    await SqliteSchemaGate.prepareSearch(backend, storeName: 'search.db');
    index = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
    vectorSynchronizations = [];
    vectorCallback = (documentIds, {required userId}) async {
      final ids = documentIds.toList(growable: false);
      final presentIds = (await index.fetch(
        ids,
        userId: userId,
      )).map((document) => document.id).toList(growable: false);
      vectorSynchronizations.add(_VectorSynchronization(ids: ids, userId: userId, presentIds: presentIds));
    };
    indexer = ConversationIndexer(
      index: index,
      sessions: sessions,
      messages: messages,
      synchronizeVectors: (documentIds, {required userId}) => vectorCallback(documentIds, userId: userId),
    );
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

  test('append and clear synchronize the matching IDs after each lexical mutation', () async {
    final session = await sessions.createSession();
    final message = await messages.insertMessage(sessionId: session.id, role: 'user', content: 'vector lifecycle');
    await indexer.idle;

    expect(vectorSynchronizations, [
      _VectorSynchronization(ids: [message.id], userId: 'owner', presentIds: [message.id]),
    ]);

    await messages.clearMessages(session.id);
    await indexer.idle;

    expect(vectorSynchronizations.last, _VectorSynchronization(ids: [message.id], userId: 'owner', presentIds: []));
  });

  test('archive, resume, and delete synchronize IDs without needing deleted NDJSON', () async {
    final session = await sessions.createSession();
    final message = await messages.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content: 'retained transcript',
    );
    await indexer.idle;
    vectorSynchronizations.clear();

    await sessions.updateSessionType(session.id, SessionType.archive);
    await indexer.idle;
    expect(vectorSynchronizations.single, _VectorSynchronization(ids: [message.id], userId: 'owner', presentIds: []));

    vectorSynchronizations.clear();
    await sessions.updateSessionType(session.id, SessionType.user);
    await indexer.idle;
    expect(
      vectorSynchronizations.single,
      _VectorSynchronization(ids: [message.id], userId: 'owner', presentIds: [message.id]),
    );

    vectorSynchronizations.clear();
    await sessions.deleteSession(session.id);
    await indexer.idle;
    expect(Directory('${root.path}/${session.id}').existsSync(), isFalse);
    expect(vectorSynchronizations.single, _VectorSynchronization(ids: [message.id], userId: 'owner', presentIds: []));
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
    expect(vectorSynchronizations.last.ids, [message.id]);
  });

  test('vector failure preserves persistence and lexical state without blocking the queue', () async {
    var attempts = 0;
    vectorCallback = (documentIds, {required userId}) async {
      attempts++;
      if (attempts == 1) throw StateError('vector unavailable');
    };
    final records = <LogRecord>[];
    final priorLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await subscription.cancel();
      Logger.root.level = priorLevel;
    });
    final session = await sessions.createSession();

    final first = await messages.insertMessage(sessionId: session.id, role: 'user', content: 'durable one');
    final second = await messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'durable two');
    await indexer.idle;

    expect((await messages.getMessages(session.id)).map((message) => message.id), [first.id, second.id]);
    expect((await index.fetch([first.id, second.id], userId: 'owner')).map((document) => document.id).toSet(), {
      first.id,
      second.id,
    });
    expect(attempts, 2);
    expect(records.where((record) => record.loggerName == 'ConversationIndexer'), hasLength(1));
  });

  test('lexical failure skips vector synchronization and leaves persistence intact', () async {
    final session = await sessions.createSession();
    await backend.close();

    final message = await messages.insertMessage(sessionId: session.id, role: 'user', content: 'lexical unavailable');
    await indexer.idle;

    expect((await messages.getMessages(session.id)).single.id, message.id);
    expect(vectorSynchronizations, isEmpty);
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
      await backend.close();
      expect(await ConversationSearchService(index: index).search('anything'), isEmpty);
    });

    test('injected query preserves provenance, source order, score, owner, limit, and diagnostics', () async {
      final expectedDiagnostics = SearchDiagnostics(candidates: const [], unembeddedCount: 2);
      SearchDiagnostics? receivedDiagnostics;
      late String receivedQuery;
      late String receivedUserId;
      late int receivedLimit;
      late SearchDiagnosticsSink? receivedSink;
      final firstTimestamp = DateTime.parse('2026-01-02T03:04:05+02:00');
      final secondTimestamp = DateTime.utc(2025, 12, 1);
      final sourceResults = [
        SearchResult(
          id: 'message-b',
          chunk: 'second-ranked score shape',
          chunkIndex: 0,
          metadata: const {'session_id': 'session-b', 'role': 'assistant'},
          timestamp: firstTimestamp,
          score: 7,
        ),
        SearchResult(
          id: 'message-a',
          chunk: 'first-ranked score shape',
          chunkIndex: 0,
          metadata: const {'session_id': 'session-a', 'role': 'user'},
          timestamp: secondTimestamp,
          score: -3,
        ),
      ];
      void sink(SearchDiagnostics diagnostics) => receivedDiagnostics = diagnostics;
      final service = ConversationSearchService(
        index: index,
        userId: 'tenant-a',
        query: (query, {required userId, required limit, diagnostics}) async {
          receivedQuery = query;
          receivedUserId = userId;
          receivedLimit = limit;
          receivedSink = diagnostics;
          diagnostics?.call(expectedDiagnostics);
          return sourceResults;
        },
      );

      final hits = await service.search('ranking shape', limit: 2, diagnostics: sink);

      expect(receivedQuery, 'ranking shape');
      expect(receivedUserId, 'tenant-a');
      expect(receivedLimit, 2);
      expect(receivedSink, isNotNull);
      expect(receivedDiagnostics, same(expectedDiagnostics));
      expect(hits.map((hit) => hit.messageId), ['message-b', 'message-a']);
      expect(hits.map((hit) => hit.sessionId), ['session-b', 'session-a']);
      expect(hits.map((hit) => hit.role), ['assistant', 'user']);
      expect(hits.map((hit) => hit.createdAt), [firstTimestamp.toUtc(), secondTimestamp]);
      expect(hits.map((hit) => hit.text), ['second-ranked score shape', 'first-ranked score shape']);
      expect(hits.map((hit) => hit.score), [7, -3]);
    });
  });
}

final class _VectorSynchronization {
  const new({required this.ids, required this.userId, required this.presentIds});

  final List<String> ids;
  final String userId;
  final List<String> presentIds;

  @override
  bool operator ==(Object other) =>
      other is _VectorSynchronization &&
      _listEquals(ids, other.ids) &&
      userId == other.userId &&
      _listEquals(presentIds, other.presentIds);

  @override
  int get hashCode => Object.hash(Object.hashAll(ids), userId, Object.hashAll(presentIds));
}

bool _listEquals(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

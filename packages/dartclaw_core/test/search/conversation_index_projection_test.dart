import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('maps only recallable messages with exact persisted provenance', () {
    final message = Message(
      cursor: 9,
      id: 'message-id',
      sessionId: 'session-id',
      role: 'assistant',
      content: 'Persisted answer',
      metadata: '{"ignored":true}',
      createdAt: DateTime.parse('2026-09-08T13:14:15+02:00'),
    );

    final document = ConversationIndexProjection.document(message: message, sessionType: SessionType.user)!;
    expect(document.id, 'message-id');
    expect(document.chunks, ['Persisted answer']);
    expect(document.metadata, {'session_id': 'session-id', 'role': 'assistant'});
    expect(document.timestamp, DateTime.utc(2026, 9, 8, 11, 14, 15));
    expect(
      ConversationIndexProjection.document(
        message: Message(
          cursor: 1,
          id: 'system',
          sessionId: 'session-id',
          role: 'system',
          content: 'hidden',
          createdAt: DateTime.utc(2026),
        ),
        sessionType: SessionType.user,
      ),
      isNull,
    );
    for (final type in SessionType.values.where((type) => !type.isChatFacing)) {
      expect(ConversationIndexProjection.document(message: message, sessionType: type), isNull);
    }
  });

  test('rebuild enumerates NDJSON, skips malformed and internal records, and authenticates its source', () async {
    final root = Directory.systemTemp.createTempSync('conversation_projection_');
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path);
    final database = sqlite3.openInMemory();
    final backend = SqliteBackend(database);
    addTearDown(() async {
      await messages.dispose();
      await backend.close();
      root.deleteSync(recursive: true);
    });
    await SqliteSchemaGate.prepareSearch(backend, storeName: 'search.db');
    final index = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
    final first = await sessions.createSession();
    final second = await sessions.createSession(type: SessionType.channel);
    final task = await sessions.createSession(type: SessionType.task);
    await messages.insertMessage(sessionId: first.id, role: 'user', content: 'one');
    await messages.insertMessage(sessionId: first.id, role: 'assistant', content: 'two');
    await messages.insertMessage(sessionId: first.id, role: 'system', content: 'hidden');
    final queuedAt = DateTime.utc(2026, 9, 14);
    await messages.insertMessageWithIdentity(
      sessionId: first.id,
      messageId: '33333333-3333-4333-8333-333333333333',
      role: 'user',
      content: 'queued and not searchable',
      createdAt: queuedAt,
      notifyObserver: false,
    );
    await sessions.updateConversationState(
      first.id,
      ConversationState().put(
        ConversationSubmissionClaim(
          submissionId: 'queued-submission',
          revisionId: 'queued-revision',
          messageId: '33333333-3333-4333-8333-333333333333',
          queueId: 'queued-work',
          payloadDigest: 'sha256:queued',
          message: 'queued and not searchable',
          commitState: SubmissionCommitState.committed,
          workState: ConversationWorkState.queued,
          createdAt: queuedAt,
          updatedAt: queuedAt,
        ),
      ),
    );
    await messages.insertMessage(sessionId: second.id, role: 'assistant', content: 'three');
    await messages.insertMessage(sessionId: task.id, role: 'assistant', content: 'internal');
    File('${root.path}/${second.id}/messages.ndjson').writeAsStringSync('malformed\n', mode: FileMode.append);
    await index.upsert([
      SearchDocument(
        id: 'stale',
        chunks: const ['stale'],
        metadata: const {'session_id': 'stale-session', 'role': 'user'},
        timestamp: DateTime.utc(2025),
      ),
    ], userId: 'owner');

    final projection = ConversationIndexProjection(sessions: sessions, messages: messages);
    final result = await projection.rebuild(index);

    expect((result.messageCount, result.sessionCount), (3, 2));
    expect(result.principals, {'owner'});
    expect(await index.count(userId: 'owner'), 3);
    expect(await index.fetch(['stale'], userId: 'owner'), isEmpty);
    expect(await projection.authenticateComplete(), isTrue);
    await messages.insertMessage(sessionId: first.id, role: 'user', content: 'source changed');
    expect(await projection.authenticateComplete(), isFalse);
  });

  test('rebuild keeps owner and pinned workspace conversations in separate principal corpora', () async {
    final root = Directory.systemTemp.createTempSync('conversation_projection_scoped_');
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path);
    final backend = SqliteBackend(sqlite3.openInMemory());
    addTearDown(() async {
      await messages.dispose();
      await backend.close();
      root.deleteSync(recursive: true);
    });
    await SqliteSchemaGate.prepareSearch(backend, storeName: 'search.db');
    final index = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
    final owner = await sessions.createSession();
    final agentA = await sessions.createSession(
      workspace: AgentWorkspace.pinned(agentId: 'a', directory: '${root.path}/agent-a'),
    );
    final agentB = await sessions.createSession(
      workspace: AgentWorkspace.pinned(agentId: 'b', directory: '${root.path}/agent-b'),
    );
    await messages.insertMessage(sessionId: owner.id, role: 'user', content: 'owner-only-marker');
    await messages.insertMessage(sessionId: agentA.id, role: 'user', content: 'agent-a-only-marker');
    await messages.insertMessage(sessionId: agentB.id, role: 'user', content: 'agent-b-only-marker');

    final projection = ConversationIndexProjection(
      sessions: sessions,
      messages: messages,
      configuredPrincipals: const {'owner', 'agent:a', 'agent:b'},
    );
    final result = await projection.rebuild(index);

    expect((result.messageCount, result.sessionCount), (3, 3));
    expect(result.principals, {'owner', 'agent:a', 'agent:b'});
    expect((await index.search('marker', userId: 'owner')).single.chunk, 'owner-only-marker');
    expect((await index.search('marker', userId: 'agent:a')).single.chunk, 'agent-a-only-marker');
    expect((await index.search('marker', userId: 'agent:b')).single.chunk, 'agent-b-only-marker');
    final admin = await ConversationSearchService(
      index: index,
      userIds: const {'owner', 'agent:a', 'agent:b'},
    ).searchAdministrative('marker');
    expect(admin.hits.map((hit) => hit.text).toSet(), {
      'owner-only-marker',
      'agent-a-only-marker',
      'agent-b-only-marker',
    });
  });
}

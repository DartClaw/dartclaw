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
    expect(await index.count(userId: 'owner'), 3);
    expect(await index.fetch(['stale'], userId: 'owner'), isEmpty);
    expect(await projection.authenticateComplete(), isTrue);
    await messages.insertMessage(sessionId: first.id, role: 'user', content: 'source changed');
    expect(await projection.authenticateComplete(), isFalse);
  });
}

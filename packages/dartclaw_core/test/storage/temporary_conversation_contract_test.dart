import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late SessionService sessions;
  late MessageService messages;

  setUp(() {
    root = Directory.systemTemp.createTempSync('temporary-conversation-');
    sessions = SessionService(baseDir: root.path, maxProcessSessions: 2);
    messages = MessageService(
      baseDir: root.path,
      retentionForSession: sessions.retentionFor,
      maxProcessMessagesPerSession: 2,
    );
  });

  tearDown(() async {
    await messages.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('temporary and ordinary conversations share authorities with distinct retention', () async {
    final durable = await sessions.createSession();
    final temporary = await sessions.createSession(retention: ConversationRetention.process);
    await messages.insertMessage(sessionId: durable.id, role: 'user', content: 'durable');
    await messages.insertMessage(sessionId: temporary.id, role: 'user', content: 'temporary');
    await sessions.updateConversationState(
      temporary.id,
      ConversationState().recordTelemetry(
        SessionContextTelemetry(
          sessionId: temporary.id,
          source: 'codex',
          observedAt: DateTime.utc(2026, 9, 14),
          availability: ContextMeasurementAvailability.measured,
          usedTokens: 12,
          contextWindowTokens: 100,
        ),
      ),
    );

    expect(Directory('${root.path}/${durable.id}').existsSync(), isTrue);
    expect(Directory('${root.path}/${temporary.id}').existsSync(), isFalse);
    expect((await messages.getMessages(temporary.id)).single.content, 'temporary');
    expect((await sessions.getConversationState(temporary.id)).telemetry?.usedTokens, 12);
    expect(
      ConversationIndexProjection.document(
        message: (await messages.getMessages(temporary.id)).single,
        sessionType: SessionType.user,
        retention: ConversationRetention.process,
      ),
      isNull,
    );

    final restarted = SessionService(baseDir: root.path);
    expect(await restarted.getSession(durable.id), isNotNull);
    expect(await restarted.getSession(temporary.id), isNull);
  });

  test('process retention is bounded and revoked identifiers fail closed', () async {
    final temporary = await sessions.createSession(retention: ConversationRetention.process);
    await messages.insertMessage(sessionId: temporary.id, role: 'user', content: 'one');
    await messages.insertMessage(sessionId: temporary.id, role: 'assistant', content: 'two');
    await expectLater(
      messages.insertMessage(sessionId: temporary.id, role: 'user', content: 'three'),
      throwsStateError,
    );
    await messages.clearMessages(temporary.id);
    await sessions.deleteSession(temporary.id);
    await expectLater(messages.insertMessage(sessionId: temporary.id, role: 'user', content: 'late'), throwsStateError);
  });

  test('process inbox metadata stays memory-only and rejects stale or ended mutations', () async {
    final temporary = await sessions.createSession(retention: ConversationRetention.process);
    final at = DateTime.utc(2026, 9, 14);

    final updated = await sessions.updateInboxMetadata(
      id: temporary.id,
      expectedConversationRevision: 0,
      settledAt: at,
      readMessageCursor: 4,
      attentionReadEventId: 'attention-4',
      dismissedAttentionEventIds: List.generate(205, (index) => 'attention-$index'),
    );

    expect(updated.session.settledAt, at);
    expect(updated.session.readMessageCursor, 4);
    expect(updated.session.attentionReadEventId, 'attention-4');
    expect(updated.session.dismissedAttentionEventIds, hasLength(SessionService.maxDismissedAttentionEventIds));
    expect(updated.session.dismissedAttentionEventIds.first, 'attention-5');
    expect(updated.state.revision, 1);
    expect(Directory('${root.path}/${temporary.id}').existsSync(), isFalse);
    await expectLater(
      sessions.updateInboxMetadata(id: temporary.id, expectedConversationRevision: 0, clearSettledAt: true),
      throwsA(isA<ConversationRevisionMismatch>()),
    );

    sessions.markTemporaryEnding(temporary.id);
    await expectLater(
      sessions.updateInboxMetadata(id: temporary.id, expectedConversationRevision: 1, clearSettledAt: true),
      throwsStateError,
    );
    await sessions.deleteSession(temporary.id);
    expect(await sessions.getSession(temporary.id), isNull);
    expect(Directory('${root.path}/${temporary.id}').existsSync(), isFalse);
    await expectLater(sessions.getConversationState(temporary.id), throwsStateError);
    await expectLater(
      sessions.updateInboxMetadata(id: temporary.id, expectedConversationRevision: 1, clearSettledAt: true),
      throwsStateError,
    );
  });
}

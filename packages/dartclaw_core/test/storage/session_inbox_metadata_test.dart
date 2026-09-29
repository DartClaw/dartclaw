import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  test('inbox metadata is independent, bounded by revision, and legacy-safe', () async {
    final root = Directory.systemTemp.createTempSync('dartclaw_session_inbox_');
    addTearDown(() => root.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: root.path);
    final session = await sessions.createSession();
    expect(session.settledAt, isNull);
    expect(session.readMessageCursor, 0);
    expect(session.dismissedAttentionEventIds, isEmpty);

    final at = DateTime.utc(2026, 9, 14);
    final updated = await sessions.updateInboxMetadata(
      id: session.id,
      expectedConversationRevision: 0,
      settledAt: at,
      readMessageCursor: 7,
      attentionReadEventId: 'event-7',
      dismissedAttentionEventIds: const ['event-1'],
    );
    expect(updated.session.settledAt, at);
    expect(updated.session.readMessageCursor, 7);
    expect(updated.session.attentionReadEventId, 'event-7');
    expect(updated.state.revision, 1);
    final independent = await sessions.updateInboxMetadata(
      id: session.id,
      expectedConversationRevision: 1,
      readMessageCursor: 3,
      dismissedAttentionEventIds: List.generate(205, (index) => 'event-$index'),
    );
    expect(independent.session.readMessageCursor, 7, reason: 'the transcript boundary is monotonic');
    expect(independent.session.attentionReadEventId, 'event-7', reason: 'other inbox mutations retain feed state');
    expect(independent.session.dismissedAttentionEventIds, hasLength(SessionService.maxDismissedAttentionEventIds));
    expect(independent.session.dismissedAttentionEventIds.first, 'event-5');
    expect(independent.state.revision, 2);
    expect(
      () => sessions.updateInboxMetadata(id: session.id, expectedConversationRevision: 0, clearSettledAt: true),
      throwsA(isA<ConversationRevisionMismatch>()),
    );
  });
}

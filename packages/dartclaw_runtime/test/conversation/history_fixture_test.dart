import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'history_test_fixture.dart';

void main() {
  test('large history race and restart fixture uses authoritative persisted state without sleeps', () async {
    final fixture = await HistoryTestFixture.create();
    addTearDown(fixture.dispose);

    expect(fixture.sessionIds, hasLength(HistoryTestFixture.conversationCount));
    expect(fixture.messageIds, hasLength(HistoryTestFixture.messageCount));
    final selectedMessages = await fixture.messages.getMessages(fixture.selectedSessionId);
    expect(selectedMessages, hasLength(HistoryTestFixture.messageCount ~/ HistoryTestFixture.conversationCount));

    await fixture.recordToolState(ConversationRecordState.running);
    await fixture.recordToolState(ConversationRecordState.failed);
    await fixture.recordToolState(ConversationRecordState.failed);
    await fixture.restart();

    final restarted = await fixture.sessions.getConversationState(fixture.selectedSessionId);
    expect(restarted.records, hasLength(1));
    expect(restarted.records.single.id, 'tool-1');
    expect(restarted.records.single.state, ConversationRecordState.failed);
    expect(await fixture.messages.getMessage(fixture.selectedSessionId, fixture.messageIds.first), isNotNull);
    expect(fixture.approvalBarrier.isCompleted, isFalse);
  });
}

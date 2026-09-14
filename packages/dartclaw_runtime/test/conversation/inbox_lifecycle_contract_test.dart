import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/conversation/inbox_service.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';
import 'inbox_test_fixture.dart';

void main() {
  test('row and bulk settle share stale-safe eligibility and reversible membership', () async {
    final fixture = await InboxTestFixture.create(count: 3);
    addTearDown(fixture.dispose);
    final first = fixture.sessionIds[0];
    final second = fixture.sessionIds[1];
    final revision = await fixture.makeEligible(first);

    final results = await fixture.inbox.settleMany([
      (sessionId: first, expectedRevision: revision),
      (sessionId: second, expectedRevision: 0),
    ]);
    expect(results.map((result) => result.accepted), [isTrue, isFalse]);
    expect(results[1].code, 'WORK_NOT_COMPLETED');
    final stale = await fixture.inbox.restore(first, revision);
    expect(stale.code, 'STALE_CONVERSATION_REVISION');
    final restored = await fixture.inbox.restore(first, results.first.revision);
    expect(restored.accepted, isTrue);
    expect((await fixture.inbox.inbox(limit: 3)).entries.map((entry) => entry.session.id), contains(first));
  });

  test('read anchors and exactly three work signals preserve independent state', () async {
    final fixture = await InboxTestFixture.create(count: 1);
    addTearDown(fixture.dispose);
    final id = fixture.sessionIds.single;
    var revision = await fixture.makeEligible(id);
    for (final signal in InboxWorkSignal.values) {
      final settled = await fixture.inbox.settleMany([(sessionId: id, expectedRevision: revision)]);
      expect(settled.single.accepted, isTrue, reason: signal.name);
      final feedMarker = (await fixture.sessions.getSession(id))!.attentionReadEventId;
      await fixture.inbox.handleWorkSignal(id, signal);
      final restored = (await fixture.sessions.getSession(id))!;
      expect(restored.settledAt, isNull, reason: signal.name);
      expect(restored.readMessageCursor, 1, reason: signal.name);
      expect(restored.attentionReadEventId, feedMarker, reason: '${signal.name} must retain feed state');
      revision = (await fixture.sessions.getConversationState(id)).revision;
    }

    final next = await fixture.messages.insertMessage(sessionId: id, role: 'assistant', content: 'New visible result');
    final hidden = await fixture.inbox.advanceRead(
      sessionId: id,
      expectedRevision: revision,
      visibleMessageId: next.id,
      foreground: false,
    );
    expect(hidden.code, 'TAB_NOT_FOREGROUND');
    expect((await fixture.sessions.getSession(id))!.readMessageCursor, 1);
    final visible = await fixture.inbox.advanceRead(
      sessionId: id,
      expectedRevision: revision,
      visibleMessageId: next.id,
      foreground: true,
    );
    expect(visible.accepted, isTrue);
    expect((await fixture.sessions.getSession(id))!.readMessageCursor, next.cursor);
  });

  test('production history producers restore only after a new pending request persists', () async {
    final fixture = await InboxTestFixture.create(count: 1);
    addTearDown(fixture.dispose);
    final id = fixture.sessionIds.single;
    final turns = FakeTurnManager(fixture.messages, FakeAgentHarness());
    final conversation = ConversationService(
      sessions: fixture.sessions,
      messages: fixture.messages,
      turns: turns,
      mutations: fixture.mutations,
      clock: () => InboxTestFixture.now,
    );
    var inputSignals = 0;
    final restored = Completer<void>();
    conversation.setInboxObservers(
      turnStarted: (sessionId) => fixture.inbox.handleWorkSignal(sessionId, InboxWorkSignal.turnStarted),
      inputRequested: (sessionId) async {
        inputSignals += 1;
        await fixture.inbox.handleWorkSignal(sessionId, InboxWorkSignal.inputRequested);
        if (!restored.isCompleted) restored.complete();
      },
    );

    final revision = await fixture.makeEligible(id);
    final settled = await fixture.inbox.settleMany([(sessionId: id, expectedRevision: revision)]);
    expect(settled.single.accepted, isTrue);
    for (final transition in [
      (id: 'tool-running', state: ConversationRecordState.running),
      (id: 'tool-succeeded', state: ConversationRecordState.succeeded),
      (id: 'tool-failed', state: ConversationRecordState.failed),
    ]) {
      await conversation.recordToolTransition(
        sessionId: id,
        attemptId: 'attempt-$id',
        turnId: 'turn-$id',
        toolId: transition.id,
        toolName: 'fixture',
        state: transition.state,
      );
      expect((await fixture.sessions.getSession(id))!.settledAt, isNotNull, reason: transition.state.name);
    }
    await conversation.recordApprovalRequest(
      sessionId: id,
      attemptId: 'attempt-$id',
      turnId: 'turn-$id',
      requestId: 'request-new',
      action: 'write',
      target: '/fixture',
      expiresAt: InboxTestFixture.now.add(const Duration(hours: 1)),
    );
    await restored.future;
    expect((await fixture.sessions.getSession(id))!.settledAt, isNull);
    expect(inputSignals, 1);

    await conversation.recordApprovalRequest(
      sessionId: id,
      attemptId: 'attempt-$id',
      turnId: 'turn-$id',
      requestId: 'request-new',
      action: 'write',
      target: '/fixture',
      expiresAt: InboxTestFixture.now.add(const Duration(hours: 1)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(inputSignals, 1, reason: 'idempotent request replay must not emit another restore signal');
  });
}

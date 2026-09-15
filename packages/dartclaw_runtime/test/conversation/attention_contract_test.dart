import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_runtime/src/conversation/inbox_service.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';
import 'inbox_test_fixture.dart';

void main() {
  test('feed projection pages durable events with independent owner markers', () async {
    final fixture = await InboxTestFixture.create(count: 1);
    addTearDown(fixture.dispose);
    final id = fixture.sessionIds.single;
    final now = InboxTestFixture.now;
    final message = await fixture.messages.insertMessage(sessionId: id, role: 'user', content: 'Deploy');
    final claimed = (await fixture.sessions.getConversationState(id)).put(
      ConversationSubmissionClaim(
        submissionId: 'submission-1',
        revisionId: 'revision-1',
        messageId: message.id,
        attemptId: 'attempt-1',
        payloadDigest: 'fixture',
        message: 'Deploy',
        commitState: SubmissionCommitState.committed,
        workState: ConversationWorkState.running,
        turnId: 'turn-1',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final state = claimed.putRecord(
      ConversationDisplayRecord(
        id: 'request-1',
        attemptId: 'attempt-1',
        turnId: 'turn-1',
        kind: ConversationRecordKind.approval,
        state: ConversationRecordState.pending,
        label: 'Deploy production',
        arguments: 'Requires operator approval',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await fixture.sessions.updateConversationState(id, state);

    final page = await fixture.inbox.attention(limit: 1);
    expect(page.total, 1);
    expect(page.items.single.actionAvailable, isTrue);
    expect(page.items.single.dismissible, isFalse);
    expect(page.items.single.messageId, message.id);
    expect(page.items.single.recordId, 'request-1');
    final refused = await fixture.inbox.dismissAttention(
      sessionId: id,
      expectedRevision: state.revision,
      eventId: 'record:request-1',
    );
    expect(refused.code, 'ATTENTION_PENDING');
    final marked = await fixture.inbox.markAttentionRead(
      sessionId: id,
      expectedRevision: state.revision,
      eventId: 'record:request-1',
    );
    expect(marked.accepted, isTrue);
    expect((await fixture.sessions.getSession(id))!.readMessageCursor, 0);
    expect((await fixture.inbox.attention()).unreadTotal, 0);
  });

  test('feed markers stay separate while exact pending requests resolve once', () async {
    final fixture = await InboxTestFixture.create(count: 1);
    addTearDown(fixture.dispose);
    final id = fixture.sessionIds.single;
    final now = InboxTestFixture.now;
    final state = (await fixture.sessions.getConversationState(id)).putRecord(
      ConversationDisplayRecord(
        id: 'request-1',
        attemptId: 'attempt-1',
        turnId: 'turn-1',
        kind: ConversationRecordKind.approval,
        state: ConversationRecordState.pending,
        label: 'Approve',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await fixture.sessions.updateConversationState(id, state);
    var calls = 0;
    fixture.inbox.bindApprovalResolver(({
      required sessionId,
      required attemptId,
      required turnId,
      required requestId,
      required approved,
      expectedRevision,
    }) async {
      calls += 1;
      final resolved = state.findRecord(requestId)!.copyWith(state: ConversationRecordState.approved, updatedAt: now);
      await fixture.sessions.updateConversationState(sessionId, state.putRecord(resolved));
      return resolved;
    });
    for (final attempt in [
      () => fixture.inbox.resolveAttention(
        principal: 'other',
        eventId: 'record:request-1',
        sessionId: id,
        attemptId: 'attempt-1',
        turnId: 'turn-1',
        requestId: 'request-1',
        expectedRevision: state.revision,
        approved: true,
      ),
      () => fixture.inbox.resolveAttention(
        principal: 'owner',
        eventId: 'record:request-1',
        sessionId: id,
        attemptId: 'wrong-attempt',
        turnId: 'turn-1',
        requestId: 'request-1',
        expectedRevision: state.revision,
        approved: true,
      ),
      () => fixture.inbox.resolveAttention(
        principal: 'owner',
        eventId: 'record:request-1',
        sessionId: id,
        attemptId: 'attempt-1',
        turnId: 'turn-1',
        requestId: 'request-1',
        expectedRevision: state.revision - 1,
        approved: true,
      ),
    ]) {
      await expectLater(attempt(), throwsA(isA<InboxMutationException>()));
      expect(calls, 0);
    }
    final resolved = await fixture.inbox.resolveAttention(
      principal: 'owner',
      eventId: 'record:request-1',
      sessionId: id,
      attemptId: 'attempt-1',
      turnId: 'turn-1',
      requestId: 'request-1',
      expectedRevision: state.revision,
      approved: true,
    );
    expect(resolved.state, ConversationRecordState.approved);
    expect(calls, 1);
    expect((await fixture.sessions.getSession(id))!.attentionReadEventId, isNull);
    await expectLater(
      fixture.inbox.resolveAttention(
        principal: 'owner',
        eventId: 'record:request-1',
        sessionId: id,
        attemptId: 'attempt-1',
        turnId: 'turn-1',
        requestId: 'request-1',
        expectedRevision: (await fixture.sessions.getConversationState(id)).revision,
        approved: true,
      ),
      throwsA(isA<InboxMutationException>()),
    );
    expect(calls, 1);
  });

  test('attention keyset cursor survives dismissal, equal timestamps and a newer insertion', () async {
    final fixture = await InboxTestFixture.create(count: 1);
    addTearDown(fixture.dispose);
    final id = fixture.sessionIds.single;
    var state = await fixture.sessions.getConversationState(id);
    for (var index = 0; index < 5; index += 1) {
      state = state.putRecord(
        ConversationDisplayRecord(
          id: 'terminal-$index',
          attemptId: 'attempt-$index',
          turnId: 'turn-$index',
          kind: ConversationRecordKind.tool,
          state: ConversationRecordState.succeeded,
          label: 'Tool $index',
          createdAt: InboxTestFixture.now,
          updatedAt: InboxTestFixture.now,
        ),
      );
    }
    await fixture.sessions.updateConversationState(id, state);
    final first = await fixture.inbox.attention(limit: 2);
    expect(first.items.map((item) => item.eventId), ['record:terminal-0', 'record:terminal-1']);
    final boundary = first.items.last;
    final dismissed = await fixture.inbox.dismissAttention(
      sessionId: id,
      expectedRevision: boundary.revision,
      eventId: boundary.eventId,
    );
    expect(dismissed.accepted, isTrue);
    state = (await fixture.sessions.getConversationState(id)).putRecord(
      ConversationDisplayRecord(
        id: 'newer',
        attemptId: 'attempt-new',
        turnId: 'turn-new',
        kind: ConversationRecordKind.tool,
        state: ConversationRecordState.succeeded,
        label: 'Newer',
        createdAt: InboxTestFixture.now.add(const Duration(minutes: 1)),
        updatedAt: InboxTestFixture.now.add(const Duration(minutes: 1)),
      ),
    );
    await fixture.sessions.updateConversationState(id, state);
    final second = await fixture.inbox.attention(limit: 2, cursor: first.nextCursor);
    expect(second.items.map((item) => item.eventId), ['record:terminal-2', 'record:terminal-3']);
  });

  test('attention read markers never move backward, including after service restart', () async {
    final fixture = await InboxTestFixture.create(count: 1);
    addTearDown(fixture.dispose);
    final id = fixture.sessionIds.single;
    var state = await fixture.sessions.getConversationState(id);
    for (final (recordId, offset) in [('older', 0), ('newer', 1)]) {
      state = state.putRecord(
        ConversationDisplayRecord(
          id: recordId,
          attemptId: 'attempt-$recordId',
          turnId: 'turn-$recordId',
          kind: ConversationRecordKind.tool,
          state: ConversationRecordState.succeeded,
          label: recordId,
          createdAt: InboxTestFixture.now.add(Duration(minutes: offset)),
          updatedAt: InboxTestFixture.now.add(Duration(minutes: offset)),
        ),
      );
    }
    await fixture.sessions.updateConversationState(id, state);

    final advanced = await fixture.inbox.markAttentionRead(
      sessionId: id,
      expectedRevision: state.revision,
      eventId: 'record:newer',
    );
    expect(advanced.accepted, isTrue);
    final refused = await fixture.inbox.markAttentionRead(
      sessionId: id,
      expectedRevision: advanced.revision,
      eventId: 'record:older',
    );
    expect(refused.accepted, isFalse);
    expect(refused.code, 'ALREADY_READ');
    expect(refused.revision, advanced.revision);
    expect((await fixture.sessions.getSession(id))!.attentionReadEventId, 'record:newer');

    final restartedSessions = SessionService(baseDir: fixture.root.path);
    final restartedMessages = MessageService(baseDir: fixture.root.path);
    final restartedInbox = ConversationInboxService(
      sessions: restartedSessions,
      messages: restartedMessages,
      mutations: SessionMutationCoordinator(),
    );
    addTearDown(() async {
      await restartedInbox.dispose();
      await restartedMessages.dispose();
    });
    final afterRestart = await restartedInbox.markAttentionRead(
      sessionId: id,
      expectedRevision: advanced.revision,
      eventId: 'record:older',
    );
    expect(afterRestart.accepted, isFalse);
    expect(afterRestart.code, 'ALREADY_READ');
    expect((await restartedSessions.getSession(id))!.attentionReadEventId, 'record:newer');
  });

  test('serialized approval authority rejects a revision changed after attention prevalidation', () async {
    final fixture = await InboxTestFixture.create(count: 1);
    addTearDown(fixture.dispose);
    final id = fixture.sessionIds.single;
    final now = InboxTestFixture.now;
    final message = await fixture.messages.insertMessage(sessionId: id, role: 'user', content: 'Approve');
    var state = (await fixture.sessions.getConversationState(id)).put(
      ConversationSubmissionClaim(
        submissionId: 'submission-race',
        revisionId: 'revision-race',
        messageId: message.id,
        attemptId: 'attempt-race',
        payloadDigest: 'fixture',
        message: 'Approve',
        commitState: SubmissionCommitState.committed,
        workState: ConversationWorkState.running,
        turnId: 'turn-race',
        createdAt: now,
        updatedAt: now,
      ),
    );
    state = state.putRecord(
      ConversationDisplayRecord(
        id: 'request-race',
        attemptId: 'attempt-race',
        turnId: 'turn-race',
        kind: ConversationRecordKind.approval,
        state: ConversationRecordState.pending,
        label: 'Approve',
        expiresAt: now.add(const Duration(hours: 1)),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await fixture.sessions.updateConversationState(id, state);
    var responderCalls = 0;
    final conversation = ConversationService(
      sessions: fixture.sessions,
      messages: fixture.messages,
      turns: FakeTurnManager(fixture.messages, FakeAgentHarness()),
      mutations: fixture.mutations,
      clock: () => now,
      approvalValidator: (_, _, _) => true,
      approvalResponder: (_, _, _, _) async => responderCalls += 1,
    );
    final prevalidated = Completer<void>();
    final release = Completer<void>();
    fixture.inbox.bindApprovalResolver(({
      required sessionId,
      required attemptId,
      required turnId,
      required requestId,
      required approved,
      expectedRevision,
    }) async {
      prevalidated.complete();
      await release.future;
      return conversation.resolveApproval(
        sessionId: sessionId,
        attemptId: attemptId,
        turnId: turnId,
        requestId: requestId,
        approved: approved,
        expectedRevision: expectedRevision,
      );
    });

    final action = fixture.inbox.resolveAttention(
      principal: 'owner',
      eventId: 'record:request-race',
      sessionId: id,
      attemptId: 'attempt-race',
      turnId: 'turn-race',
      requestId: 'request-race',
      expectedRevision: state.revision,
      approved: true,
    );
    await prevalidated.future;
    final marker = await fixture.inbox.markAttentionRead(
      sessionId: id,
      expectedRevision: state.revision,
      eventId: 'record:request-race',
    );
    expect(marker.accepted, isTrue);
    release.complete();
    await expectLater(
      action,
      throwsA(
        isA<ConversationMutationException>().having((error) => error.code, 'code', 'STALE_CONVERSATION_REVISION'),
      ),
    );
    expect(responderCalls, 0);
    expect(
      (await fixture.sessions.getConversationState(id)).findRecord('request-race')!.state,
      ConversationRecordState.pending,
    );
  });
}

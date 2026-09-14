import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'inbox_test_fixture.dart';

void main() {
  test('one evaluator keeps auto settle default-off and applies positive thresholds idempotently', () async {
    final disabled = await InboxTestFixture.create(count: 1);
    addTearDown(disabled.dispose);
    expect(await disabled.inbox.autoSettleIdleSessions(), 0);

    final enabled = await InboxTestFixture.create(count: 1, autoSettleIdleDays: 1);
    addTearDown(enabled.dispose);
    final id = enabled.sessionIds.single;
    await enabled.makeEligible(id);
    expect(await enabled.inbox.autoSettleIdleSessions(), 1);
    expect((await enabled.sessions.getSession(id))!.settledAt, InboxTestFixture.now);
    expect(await enabled.inbox.autoSettleIdleSessions(), 0);
  });

  test('local device drafts exclude an otherwise eligible conversation', () async {
    final fixture = await InboxTestFixture.create(count: 1, autoSettleIdleDays: 1);
    addTearDown(fixture.dispose);
    final id = fixture.sessionIds.single;
    await fixture.makeEligible(id);
    expect(await fixture.inbox.autoSettleIdleSessions(localDraftSessionIds: {id}), 0);
    expect((await fixture.sessions.getSession(id))!.settledAt, isNull);
  });

  test('read-transition evaluation uses the reading viewer known drafts', () async {
    final withDraft = await InboxTestFixture.create(count: 1, autoSettleIdleDays: 1);
    addTearDown(withDraft.dispose);
    final draftId = withDraft.sessionIds.single;
    final draftSeed = await _seedUnreadCompleted(withDraft, draftId);
    final readWithDraft = await withDraft.inbox.advanceRead(
      sessionId: draftId,
      expectedRevision: draftSeed.revision,
      visibleMessageId: draftSeed.messageId,
      foreground: true,
      localDraftSessionIds: {draftId},
    );
    expect(readWithDraft.accepted, isTrue);
    expect((await withDraft.sessions.getSession(draftId))!.settledAt, isNull);

    final withoutDraft = await InboxTestFixture.create(count: 1, autoSettleIdleDays: 1);
    addTearDown(withoutDraft.dispose);
    final plainId = withoutDraft.sessionIds.single;
    final plainSeed = await _seedUnreadCompleted(withoutDraft, plainId);
    final readWithoutDraft = await withoutDraft.inbox.advanceRead(
      sessionId: plainId,
      expectedRevision: plainSeed.revision,
      visibleMessageId: plainSeed.messageId,
      foreground: true,
    );
    expect(readWithoutDraft.accepted, isTrue);
    expect((await withoutDraft.sessions.getSession(plainId))!.settledAt, InboxTestFixture.now);
  });
}

Future<({String messageId, int revision})> _seedUnreadCompleted(InboxTestFixture fixture, String sessionId) async {
  final message = await fixture.messages.insertMessage(sessionId: sessionId, role: 'assistant', content: 'Done');
  final state = (await fixture.sessions.getConversationState(sessionId)).put(
    ConversationSubmissionClaim(
      submissionId: 'submission-$sessionId',
      revisionId: 'revision-$sessionId',
      messageId: message.id,
      attemptId: 'attempt-$sessionId',
      payloadDigest: 'fixture',
      message: 'Done',
      commitState: SubmissionCommitState.committed,
      workState: ConversationWorkState.completed,
      turnId: 'turn-$sessionId',
      createdAt: InboxTestFixture.now,
      updatedAt: InboxTestFixture.now,
    ),
  );
  await fixture.sessions.updateConversationState(sessionId, state);
  final marker = await fixture.sessions.updateInboxMetadata(
    id: sessionId,
    expectedConversationRevision: state.revision,
    attentionReadEventId: 'submission:submission-$sessionId',
  );
  return (messageId: message.id, revision: marker.state.revision);
}

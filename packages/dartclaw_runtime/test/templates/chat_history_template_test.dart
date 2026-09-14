import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/templates/chat.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  final now = DateTime.utc(2026, 9, 14, 12, 30);

  ConversationSubmissionClaim submission({ConversationWorkState state = ConversationWorkState.failed}) =>
      ConversationSubmissionClaim(
        submissionId: 'submission-1',
        revisionId: 'revision-1',
        messageId: 'message-1',
        attemptId: 'attempt-1',
        payloadDigest: 'digest',
        message: 'Run <carefully>',
        commitState: SubmissionCommitState.committed,
        workState: state,
        turnId: 'turn-1',
        createdAt: now,
        updatedAt: now,
      );

  test('rendered history exposes stable escaped exact actions and lineage', () {
    final state = ConversationState(
      submissions: [submission()],
      records: [
        ConversationDisplayRecord(
          id: 'tool-1',
          attemptId: 'attempt-1',
          turnId: 'turn-1',
          kind: ConversationRecordKind.tool,
          state: ConversationRecordState.failed,
          label: 'shell <script>',
          arguments: '{"token":"***"}',
          result: '<script>alert(1)</script>',
          isTruncated: true,
          elapsedMs: 1450,
          createdAt: now,
          updatedAt: now,
        ),
        ConversationDisplayRecord(
          id: 'approval-1',
          attemptId: 'attempt-1',
          turnId: 'turn-1',
          kind: ConversationRecordKind.approval,
          state: ConversationRecordState.pending,
          label: 'Write file',
          arguments: '/workspace/<target>',
          expiresAt: now.add(const Duration(minutes: 5)),
          createdAt: now,
          updatedAt: now,
        ),
      ],
      branches: [
        ConversationBranchLink(
          mutationId: 'branch-1',
          kind: ConversationBranchKind.edit,
          sourceSessionId: 'source-1',
          sourceMessageId: 'message-1',
          sourceAttemptId: 'attempt-1',
          destinationSessionId: 'destination-1',
          destinationMessageId: 'destination-message-1',
          destinationAttemptId: 'destination-attempt-1',
          createdAt: now,
        ),
      ],
    );

    final html = messagesHtmlFragment(
      [classifyMessage(id: 'message-1', role: 'user', content: 'Run <carefully>', createdAt: now, cursor: 17)],
      conversationState: state,
      approvalAvailable: (_) => true,
    );

    expect(html, contains('id="message-message-1"'));
    expect(html, contains('data-message-id="message-1"'));
    expect(html, contains('data-cursor="17"'));
    expect(html, contains('datetime="2026-09-14T12:30:00.000Z"'));
    expect(html, contains('aria-label="Copy whole message"'));
    expect(html, contains('data-history-action="retry"'));
    expect(html, contains('data-source-attempt-id="attempt-1"'));
    expect(html, contains('data-approval-request-id="approval-1"'));
    expect(html, contains('id="record-tool-1"'));
    expect(html, contains('id="record-approval-1"'));
    expect(html, contains('data-approval-attempt-id="attempt-1"'));
    expect(html, contains('data-approval-turn-id="turn-1"'));
    expect(html, contains('Approve exact request'));
    expect(html, contains('/sessions/destination-1'));
    expect(html, contains('edit branch'));
    expect(html, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
    expect(html, isNot(contains('<script>alert(1)</script>')));
  });

  test('pending approvals without an exact live provider target render unavailable', () {
    final state = ConversationState(
      submissions: [submission()],
      records: [
        ConversationDisplayRecord(
          id: 'approval-stale',
          attemptId: 'attempt-1',
          turnId: 'turn-1',
          kind: ConversationRecordKind.approval,
          state: ConversationRecordState.pending,
          label: 'Write file',
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );
    final html = messagesHtmlFragment([
      classifyMessage(id: 'message-1', role: 'user', content: 'Write', createdAt: now, cursor: 1),
    ], conversationState: state);

    expect(html, contains('data-state="unavailable"'));
    expect(html, contains('Approval unavailable'));
    expect(html, isNot(contains('data-approval-decision')));
  });

  test('native disclosures expose truthful keyboard and ARIA state', () {
    final state = ConversationState(
      submissions: [submission(state: ConversationWorkState.completed)],
      records: [
        ConversationDisplayRecord(
          id: 'tool-running',
          attemptId: 'attempt-1',
          turnId: 'turn-1',
          kind: ConversationRecordKind.tool,
          state: ConversationRecordState.running,
          label: 'Read',
          arguments: '{}',
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );
    final html = messagesHtmlFragment([
      classifyMessage(id: 'message-1', role: 'user', content: 'Read', createdAt: now, cursor: 1),
    ], conversationState: state);

    expect(html, contains('<details class="tool-call tool-call--pending"'));
    expect(html, contains('<summary class="tool-call-summary">'));
    expect(html, contains('data-tool-id="tool-running"'));
    expect(html, contains('data-state="running"'));
    expect(html, contains('<span class="tool-call-detail">Running</span>'));
    expect(html, isNot(contains('role="button"')));
  });

  test('hard guard blocks never render approval decisions', () {
    final html = messagesHtmlFragment([
      classifyMessage(id: 'guard-1', role: 'assistant', content: '[Blocked by guard: destructive command]'),
    ], conversationState: ConversationState());

    expect(html, contains('GUARD BLOCKED'));
    expect(html, isNot(contains('data-approval-decision')));
    expect(html, isNot(contains('approval-card')));
  });
}

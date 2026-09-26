import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/templates/chat.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  final now = DateTime.utc(2026, 9, 14, 12, 30);

  test('a project move stays visible between old and future messages without trusting its label as HTML', () {
    final state = ConversationState(
      records: [
        ConversationDisplayRecord(
          id: 'move-1',
          attemptId: '',
          turnId: '',
          kind: ConversationRecordKind.contextChange,
          state: ConversationRecordState.succeeded,
          label: 'Moved to <project>. Future messages run there; earlier history stays here.',
          createdAt: now.add(const Duration(minutes: 1)),
          updatedAt: now.add(const Duration(minutes: 1)),
        ),
      ],
    );
    final html = messagesHtmlFragment([
      classifyMessage(id: 'old', role: 'user', content: 'Earlier question', createdAt: now),
      classifyMessage(
        id: 'new',
        role: 'user',
        content: 'Next question',
        createdAt: now.add(const Duration(minutes: 2)),
      ),
    ], conversationState: state);

    expect(html.indexOf('Earlier question'), lessThan(html.indexOf('conversation-context-marker')));
    expect(html.indexOf('conversation-context-marker'), lessThan(html.indexOf('Next question')));
    expect(html, contains('Moved to &lt;project&gt;'));
    expect(html, isNot(contains('<project>')));
  });

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
    expect(html, contains('aria-label="Copy message"'));
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

  // A settled turn should cost one row, not one per call; an unsettled one has
  // to stay open, because a collapsed disclosure hides the thing still running
  // or the thing that failed.
  ConversationDisplayRecord tool(String id, ConversationRecordState state, {int elapsedMs = 1000}) =>
      ConversationDisplayRecord(
        id: id,
        attemptId: 'attempt-1',
        turnId: 'turn-1',
        kind: ConversationRecordKind.tool,
        state: state,
        label: id,
        arguments: '{}',
        elapsedMs: elapsedMs,
        createdAt: now,
        updatedAt: now,
      );

  String renderTools(List<ConversationDisplayRecord> records, {bool withReply = true}) => messagesHtmlFragment(
    [
      classifyMessage(id: 'message-1', role: 'user', content: 'Go', createdAt: now, cursor: 1),
      if (withReply) classifyMessage(id: 'message-2', role: 'assistant', content: 'Done.', createdAt: now, cursor: 2),
    ],
    conversationState: ConversationState(
      submissions: [submission(state: ConversationWorkState.completed)],
      records: records,
    ),
  );

  // Tools are the assistant's work. They are keyed to the attempt, and the
  // attempt is keyed to the user message that opened it, but rendering them
  // there attributes the agent's actions to the person who asked.
  test('the attempt run renders inside the reply that answers it, above the prose', () {
    final html = renderTools([tool('bash', ConversationRecordState.succeeded)]);

    final userBlock = html.substring(html.indexOf('id="message-message-1"'), html.indexOf('id="message-message-2"'));
    expect(userBlock, isNot(contains('tool-call')));
    expect(userBlock, isNot(contains('history-records')));

    final replyBlock = html.substring(html.indexOf('id="message-message-2"'));
    expect(replyBlock, contains('history-records'));
    expect(replyBlock.indexOf('history-records'), lessThan(replyBlock.indexOf('msg-content')));
  });

  test('an attempt that produced no reply gets an assistant-side block of its own', () {
    final html = renderTools([tool('bash', ConversationRecordState.failed)], withReply: false);

    final userBlock = html.substring(html.indexOf('id="message-message-1"'), html.indexOf('msg-assistant--records'));
    expect(userBlock, isNot(contains('tool-call')));
    expect(html, contains('msg msg-assistant msg-assistant--records'));
    expect(html.indexOf('id="message-message-1"'), lessThan(html.indexOf('msg-assistant--records')));
    expect(html, contains('data-tool-id="bash"'));
  });

  test('a settled run of tool calls collapses into one disclosure', () {
    final html = renderTools([
      tool('rg', ConversationRecordState.succeeded, elapsedMs: 300),
      tool('read', ConversationRecordState.succeeded, elapsedMs: 100),
      tool('bash', ConversationRecordState.succeeded, elapsedMs: 11900),
    ]);

    expect(html, contains('tool-group'));
    expect(html, contains('<span class="tool-call-name">3 tools</span>'));
    expect(html, contains('rg · read · bash'));
    expect(html, contains('<span class="tool-call-time">12.3s</span>'));
    expect(html, contains('data-state="succeeded"'));
    expect(html, isNot(contains('tool-group" data-state="succeeded" open')));
  });

  test('a run holding a running or failed call stays expanded and takes its state', () {
    final running = renderTools([
      tool('rg', ConversationRecordState.succeeded),
      tool('bash', ConversationRecordState.running),
    ]);
    expect(running, contains('tool-call--pending tool-group'));
    expect(running, contains('data-state="running" open'));
    expect(running, contains('scan-bar'));

    final failed = renderTools([
      tool('rg', ConversationRecordState.succeeded),
      tool('bash', ConversationRecordState.failed),
    ]);
    expect(failed, contains('tool-call--error tool-group'));
    expect(failed, contains('data-state="failed" open'));
  });

  test('a single call renders as itself rather than a one-item group', () {
    final html = renderTools([tool('bash', ConversationRecordState.succeeded)]);
    expect(html, contains('data-tool-id="bash"'));
    expect(html, isNot(contains('tool-group')));
    expect(html, isNot(contains('tabindex="-1" open')));
  });

  test('a lone unsettled call carries the run\'s open rule itself', () {
    final failed = renderTools([tool('bash', ConversationRecordState.failed)]);
    expect(failed, contains('tabindex="-1" open'));
    final running = renderTools([tool('bash', ConversationRecordState.running)]);
    expect(running, contains('tabindex="-1" open'));
  });

  test('an approval breaks the run so its card is never hidden inside a disclosure', () {
    final html = renderTools([
      tool('rg', ConversationRecordState.succeeded),
      ConversationDisplayRecord(
        id: 'approval-1',
        attemptId: 'attempt-1',
        turnId: 'turn-1',
        kind: ConversationRecordKind.approval,
        state: ConversationRecordState.approved,
        label: 'Write file',
        createdAt: now,
        updatedAt: now,
      ),
      tool('bash', ConversationRecordState.succeeded),
    ]);

    expect(html.indexOf('data-tool-id="rg"'), lessThan(html.indexOf('approval-card')));
    expect(html.indexOf('approval-card'), lessThan(html.indexOf('data-tool-id="bash"')));
    expect(html, isNot(contains('tool-group')));
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

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/api/session_inbox_routes.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

import '../conversation/inbox_test_fixture.dart';
import 'api_test_helpers.dart';

void main() {
  test('read endpoint bounds and forwards viewer-known local drafts', () async {
    final fixture = await InboxTestFixture.create(count: 1, autoSettleIdleDays: 1);
    addTearDown(fixture.dispose);
    final id = fixture.sessionIds.single;
    final message = await fixture.messages.insertMessage(sessionId: id, role: 'assistant', content: 'Done');
    final state = (await fixture.sessions.getConversationState(id)).put(
      ConversationSubmissionClaim(
        submissionId: 'submission-read',
        revisionId: 'revision-read',
        messageId: message.id,
        attemptId: 'attempt-read',
        payloadDigest: 'fixture',
        message: 'Done',
        commitState: SubmissionCommitState.committed,
        workState: ConversationWorkState.completed,
        turnId: 'turn-read',
        createdAt: InboxTestFixture.now,
        updatedAt: InboxTestFixture.now,
      ),
    );
    await fixture.sessions.updateConversationState(id, state);
    final marked = await fixture.sessions.updateInboxMetadata(
      id: id,
      expectedConversationRevision: state.revision,
      attentionReadEventId: 'submission:submission-read',
    );
    final router = Router();
    registerSessionInboxRoutes(router, inbox: fixture.inbox);
    final api = ApiRouteTestClient(router.call);

    final result = await api.expectJsonObject(
      'POST',
      '/api/inbox/$id/read',
      json: {
        'conversation_revision': marked.state.revision,
        'visible_message_id': message.id,
        'foreground': true,
        'local_draft_session_ids': [id],
      },
    );
    expect(result['code'], 'READ_ADVANCED');
    expect((await fixture.sessions.getSession(id))!.settledAt, isNull);

    expect(
      await api.expectJsonErrorCode(
        'POST',
        '/api/inbox/$id/read',
        json: {
          'conversation_revision': result['conversation_revision'],
          'visible_message_id': message.id,
          'foreground': true,
          'local_draft_session_ids': List.generate(201, (index) => 'draft-$index'),
        },
        status: 400,
      ),
      'INVALID_INPUT',
    );
  });
}

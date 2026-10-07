import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        ChannelNotification,
        ChannelNotificationAction,
        ChannelNotificationKind,
        ChannelResponse,
        ChannelRunApprovalAction,
        ChannelRunApprovalFailed,
        ChannelRunApprovalHandler,
        ChannelRunApprovalRefusal,
        ChannelRunApprovalRefused,
        ChannelRunApprovalRequest,
        ChannelRunApprovalResolved,
        ChannelRunApprovalResult,
        ThreadedNotifications;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_google_chat/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGoogleJwtVerifier;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const _actions = [
  ChannelNotificationAction(id: 'run_approve', label: 'Approve'),
  ChannelNotificationAction(id: 'run_reject', label: 'Reject'),
];
const _actionData = {'runId': 'run-1', 'stepId': 'gate', 'nonce': 'n0nce'};

Map<String, dynamic> _click({
  String invokedFunction = 'run_approve',
  Map<String, String> parameters = _actionData,
  String? messageName = 'spaces/AAA/messages/M1',
  Map<String, dynamic>? user = const {'name': 'users/123', 'displayName': 'Alice'},
}) {
  return {
    'type': 'CARD_CLICKED',
    'space': {'name': 'spaces/AAA'},
    'message': ?messageName == null ? null : {'name': messageName},
    'common': {
      'invokedFunction': invokedFunction,
      'parameters': [
        for (final entry in parameters.entries) {'key': entry.key, 'value': entry.value},
      ],
    },
    'user': ?user,
  };
}

Future<Map<String, dynamic>> _post(GoogleChatWebhookHandler handler, Object payload) async {
  final response = await handler.handle(
    Request(
      'POST',
      Uri.parse('http://localhost/integrations/googlechat'),
      headers: const {'authorization': 'Bearer token'},
      body: jsonEncode(payload),
    ),
  );
  return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
}

void main() {
  const builder = ChatCardBuilder();
  late FakeGoogleChatRestClient restClient;
  late ThreadedNotifications threaded;
  late List<ChannelRunApprovalRequest> requests;
  late ChannelRunApprovalResult result;
  late List<(String, String)> reviewCalls;

  GoogleChatWebhookHandler buildHandler({ChannelRunApprovalHandler? runApprovalHandler}) {
    return GoogleChatWebhookHandler(
      channel: GoogleChatChannel(config: const GoogleChatConfig(), restClient: restClient),
      jwtVerifier: FakeGoogleJwtVerifier(),
      config: const GoogleChatConfig(),
      reviewHandler: (taskId, action, {String? comment}) async {
        reviewCalls.add((taskId, action));
        throw StateError('the task review path must not see run clicks');
      },
      runApprovalHandler: runApprovalHandler,
    );
  }

  setUp(() {
    restClient = FakeGoogleChatRestClient();
    threaded = GoogleChatChannel(
      config: const GoogleChatConfig(enabled: true),
      restClient: restClient,
    ).threadedNotifications!;
    requests = [];
    reviewCalls = [];
    result = const ChannelRunApprovalResolved();
  });

  GoogleChatWebhookHandler recordingHandler() => buildHandler(
    runApprovalHandler: (request) async {
      requests.add(request);
      return result;
    },
  );

  const notification = ChannelNotification(
    kind: ChannelNotificationKind.run,
    id: 'run-1',
    text: 'Run run-1 is waiting for approval.',
    title: 'release',
    status: 'awaiting_approval',
    actions: _actions,
    actionData: _actionData,
  );

  group('run card', () {
    test('carries Approve and Reject buttons with run, step and nonce under the action IDs', () {
      final response = threaded.render(notification);

      expect(
        response.structuredPayload,
        builder.runNotification(
          runId: 'run-1',
          title: 'release',
          status: 'awaiting_approval',
          actions: _actions,
          actionData: _actionData,
        ),
      );
      final card = jsonEncode(response.structuredPayload);
      expect(card, allOf(contains('"function":"run_approve"'), contains('"function":"run_reject"')));
      expect(
        card,
        allOf(
          contains('{"key":"runId","value":"run-1"}'),
          contains('{"key":"stepId","value":"gate"}'),
          contains('{"key":"nonce","value":"n0nce"}'),
        ),
      );
    });

    test('a notification without actions renders no buttons', () {
      final response = threaded.render(
        const ChannelNotification(
          kind: ChannelNotificationKind.run,
          id: 'run-1',
          text: 'Run run-1 was approved.',
          title: 'release',
          status: 'started',
        ),
      );

      expect(jsonEncode(response.structuredPayload), isNot(contains('buttonList')));
    });

    test('task review buttons are unchanged by the run action support', () {
      final response = threaded.render(
        const ChannelNotification(
          kind: ChannelNotificationKind.task,
          id: 'task-1',
          text: 'Needs review.',
          title: 'Fix',
          status: 'review',
          reviewActions: true,
        ),
      );

      final card = jsonEncode(response.structuredPayload);
      expect(card, allOf(contains('"function":"task_accept"'), contains('{"key":"taskId","value":"task-1"}')));
      expect(card, isNot(contains('run_approve')));
    });
  });

  group('click routing', () {
    test('approve reaches the run approval handler with the clicker and the clicked message', () async {
      final body = await _post(recordingHandler(), _click());

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.action, ChannelRunApprovalAction.approve);
      expect(request.runId, 'run-1');
      expect(request.stepId, 'gate');
      expect(request.nonce, 'n0nce');
      expect(request.senderId, 'users/123');
      expect(request.senderDisplayName, 'Alice');
      expect(request.channelType, 'googlechat');
      expect(request.postMessageId, 'spaces/AAA/messages/M1');
      expect(body, isEmpty);
      expect(reviewCalls, isEmpty);
    });

    test('reject reaches the handler as a reject', () async {
      await _post(recordingHandler(), _click(invokedFunction: 'run_reject'));

      expect(requests.single.action, ChannelRunApprovalAction.reject);
    });

    test('the clicked message name equals the ThreadedPost message ID the adapter sends', () async {
      final post = await threaded.sendToNewThread('spaces/AAA', threaded.render(notification), threadKey: 'run-1');

      await _post(recordingHandler(), _click(messageName: post!.messageId));

      expect(requests.single.postMessageId, post.messageId);
    });

    test('a missing display name is passed as null', () async {
      await _post(recordingHandler(), _click(user: const {'name': 'users/123'}));

      expect(requests.single.senderDisplayName, isNull);
    });

    test('a refusal is answered as text and the card is not edited', () async {
      result = const ChannelRunApprovalRefused(ChannelRunApprovalRefusal.notAdmin, 'Only admins can approve runs.');

      final body = await _post(recordingHandler(), _click());

      expect(body, {'text': 'Only admins can approve runs.'});
      expect(restClient.editedCards, isEmpty);
    });

    test('a failure is answered as text', () async {
      result = const ChannelRunApprovalFailed('Could not resume the run. Try again.');

      final body = await _post(recordingHandler(), _click());

      expect(body, {'text': 'Could not resume the run. Try again.'});
    });

    test('a resolution is answered with an empty response', () async {
      expect(await _post(recordingHandler(), _click()), isEmpty);
    });

    test('answers that run approvals are unavailable when no handler is bound', () async {
      final body = await _post(buildHandler(), _click());

      expect(body, {'text': 'Run approvals are not available.'});
      expect(reviewCalls, isEmpty);
    });

    for (final missing in const ['runId', 'stepId', 'nonce']) {
      test('refuses without calling the handler when $missing is missing', () async {
        final body = await _post(recordingHandler(), _click(parameters: {..._actionData}..remove(missing)));

        expect(requests, isEmpty);
        expect(body['text'], contains('missing run approval details'));
      });
    }

    test('refuses without calling the handler when the clicker or the message is missing', () async {
      final handler = recordingHandler();

      final noUser = await _post(handler, _click(user: null));
      final noMessage = await _post(handler, _click(messageName: null));

      expect(requests, isEmpty);
      expect(noUser['text'], contains('missing run approval details'));
      expect(noMessage['text'], contains('missing run approval details'));
    });

    test('lets an admin resolve and refuses a non-admin through the handler verdict', () async {
      final handler = buildHandler(
        runApprovalHandler: (request) async {
          requests.add(request);
          return request.senderId == 'users/admin'
              ? const ChannelRunApprovalResolved()
              : const ChannelRunApprovalRefused(ChannelRunApprovalRefusal.notAdmin, 'Only admins can approve runs.');
        },
      );

      final admin = await _post(handler, _click(user: const {'name': 'users/admin', 'displayName': 'Root'}));
      final other = await _post(handler, _click(invokedFunction: 'run_reject'));

      expect(admin, isEmpty);
      expect(other, {'text': 'Only admins can approve runs.'});
      expect([for (final r in requests) r.senderId], ['users/admin', 'users/123']);
    });
  });

  group('edit', () {
    final resolved = builder.runNotification(runId: 'run-1', title: 'release', status: 'started');

    test('patches the card and text of the posted message so the buttons go', () async {
      final ok = await threaded.edit(
        'spaces/AAA',
        'spaces/AAA/messages/M1',
        ChannelResponse(text: 'Approved by Alice in chat', structuredPayload: resolved),
      );

      expect(ok, isTrue);
      final (messageName, card, text) = restClient.editedCards.single;
      expect(messageName, 'spaces/AAA/messages/M1');
      expect(card, resolved);
      expect(text, 'Approved by Alice in chat');
      expect(restClient.editedMessages, isEmpty);
      expect(jsonEncode(card), isNot(contains('buttonList')));
    });

    test('returns false when the patch is refused', () async {
      restClient.failEdit = true;

      final ok = await threaded.edit(
        'spaces/AAA',
        'spaces/AAA/messages/M1',
        ChannelResponse(text: 'Approved', structuredPayload: resolved),
      );

      expect(ok, isFalse);
    });

    test('refuses a text-only response, which would leave the buttons in place', () async {
      final ok = await threaded.edit('spaces/AAA', 'spaces/AAA/messages/M1', const ChannelResponse(text: 'Approved'));

      expect(ok, isFalse);
      expect(restClient.editedCards, isEmpty);
      expect(restClient.editedMessages, isEmpty);
    });
  });
}

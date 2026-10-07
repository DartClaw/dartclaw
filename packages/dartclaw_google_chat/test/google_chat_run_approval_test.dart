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
        ChannelRunApprovalPermitted,
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
  String? dialogEventType,
  String? feedback,
}) {
  return {
    'type': 'CARD_CLICKED',
    'space': {'name': 'spaces/AAA'},
    'message': ?messageName == null ? null : {'name': messageName},
    if (dialogEventType != null) ...{'isDialogEvent': true, 'dialogEventType': dialogEventType},
    'common': {
      'invokedFunction': invokedFunction,
      'parameters': [
        for (final entry in parameters.entries) {'key': entry.key, 'value': entry.value},
      ],
      if (feedback != null)
        'formInputs': {
          'feedback': {
            'stringInputs': {
              'value': [feedback],
            },
          },
        },
    },
    'user': ?user,
  };
}

Map<String, dynamic> _requestDialog({String? messageName = 'spaces/AAA/messages/M1'}) =>
    _click(invokedFunction: 'run_request_changes', dialogEventType: 'REQUEST_DIALOG', messageName: messageName);

Map<String, dynamic> _submitDialog({String? feedback = 'Tighten the intro', String? messageName}) => _click(
  invokedFunction: 'run_request_changes_submit',
  dialogEventType: 'SUBMIT_DIALOG',
  feedback: feedback,
  messageName: messageName ?? 'spaces/AAA/messages/M1',
);

const _dialogOk = {
  'actionResponse': {
    'type': 'DIALOG',
    'dialogAction': {
      'actionStatus': {'statusCode': 'OK'},
    },
  },
};

Map<String, dynamic> _dialogBody(Map<String, dynamic> response) {
  final actionResponse = response['actionResponse'] as Map<String, dynamic>;
  expect(actionResponse['type'], 'DIALOG');
  final dialog = (actionResponse['dialogAction'] as Map<String, dynamic>)['dialog'] as Map<String, dynamic>;
  return dialog['body'] as Map<String, dynamic>;
}

Map<String, dynamic> _errorStatus(String message) => {
  'actionResponse': {
    'type': 'DIALOG',
    'dialogAction': {
      'actionStatus': {'statusCode': 'INVALID_ARGUMENT', 'userFacingMessage': message},
    },
  },
};

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

  group('request changes dialog', () {
    const refusal = ChannelRunApprovalRefused(ChannelRunApprovalRefusal.notAdmin, 'Only admins can request changes.');

    test('the post shows Request changes with OPEN_DIALOG only when the notification carries it', () {
      final withChanges = threaded.render(
        const ChannelNotification(
          kind: ChannelNotificationKind.run,
          id: 'run-1',
          text: 'Run run-1 is waiting for approval.',
          title: 'release',
          status: 'awaiting_approval',
          actions: [
            ..._actions,
            ChannelNotificationAction(id: 'run_request_changes', label: 'Request changes'),
          ],
          actionData: _actionData,
        ),
      );
      final without = threaded.render(notification);

      expect(
        jsonEncode(withChanges.structuredPayload),
        allOf(contains('"function":"run_request_changes"'), contains('"interaction":"OPEN_DIALOG"')),
      );
      expect(jsonEncode(without.structuredPayload), isNot(contains('run_request_changes')));
    });

    test(
      'the button click asks the handler once and a permitted sender gets the form carrying run, step, nonce',
      () async {
        result = const ChannelRunApprovalPermitted();

        final body = await _post(recordingHandler(), _requestDialog());

        expect(requests, hasLength(1));
        final request = requests.single;
        expect(request.action, ChannelRunApprovalAction.checkRequestChanges);
        expect(
          (request.runId, request.stepId, request.nonce, request.senderId, request.postMessageId, request.feedback),
          ('run-1', 'gate', 'n0nce', 'users/123', 'spaces/AAA/messages/M1', null),
        );
        final encoded = jsonEncode(_dialogBody(body));
        expect(
          encoded,
          allOf(
            contains('"textInput"'),
            contains('"name":"feedback"'),
            contains('"function":"run_request_changes_submit"'),
            contains('{"key":"runId","value":"run-1"}'),
            contains('{"key":"stepId","value":"gate"}'),
            contains('{"key":"nonce","value":"n0nce"}'),
            contains('{"key":"postMessageId","value":"spaces/AAA/messages/M1"}'),
          ),
        );
      },
    );

    test('a submission that carries no message identity uses the post the dialog echoed, so the nonce check still binds it', () async {
      result = const ChannelRunApprovalResolved();
      final payload = _click(
        invokedFunction: 'run_request_changes_submit',
        dialogEventType: 'SUBMIT_DIALOG',
        feedback: 'Tighten the intro',
        messageName: null,
        parameters: {..._actionData, 'postMessageId': 'spaces/AAA/messages/M1'},
      );

      final body = await _post(recordingHandler(), payload);

      expect(requests.single.postMessageId, 'spaces/AAA/messages/M1');
      expect(body, _dialogOk);
    });

    test(
      'a refused sender gets a dialog with only the refusal text, so no one types into a form that is refused',
      () async {
        result = refusal;

        final body = await _post(recordingHandler(), _requestDialog());

        expect(requests, hasLength(1));
        final encoded = jsonEncode(_dialogBody(body));
        expect(encoded, contains('Only admins can request changes.'));
        expect(encoded, allOf(isNot(contains('textInput')), isNot(contains('buttonList'))));
      },
    );

    test('the handler verdict alone decides who gets the form, the adapter holds no admin check', () async {
      final handler = buildHandler(
        runApprovalHandler: (request) async {
          requests.add(request);
          return request.senderId == 'users/admin' ? const ChannelRunApprovalPermitted() : refusal;
        },
      );
      final adminClick = _click(
        invokedFunction: 'run_request_changes',
        dialogEventType: 'REQUEST_DIALOG',
        user: const {'name': 'users/admin'},
      );

      final admin = await _post(handler, adminClick);
      final other = await _post(handler, _requestDialog());

      expect(jsonEncode(_dialogBody(admin)), contains('textInput'));
      expect(jsonEncode(_dialogBody(other)), isNot(contains('textInput')));
      expect([for (final r in requests) r.senderId], ['users/admin', 'users/123']);
    });

    test('a failed check answers a dialog holding the failure text', () async {
      result = const ChannelRunApprovalFailed('Could not check the run. Try again.');

      final body = await _post(recordingHandler(), _requestDialog());

      expect(jsonEncode(_dialogBody(body)), contains('Could not check the run. Try again.'));
    });

    test('a button click that is not a dialog request never reaches the handler', () async {
      final body = await _post(recordingHandler(), _click(invokedFunction: 'run_request_changes'));

      expect(requests, isEmpty);
      expect(body, isEmpty);
    });

    test('a submission resolves with the typed feedback verbatim and closes the dialog', () async {
      const typed = '  Tighten the intro\n\nand cut section 2  ';

      final body = await _post(recordingHandler(), _submitDialog(feedback: typed));

      expect(body, _dialogOk);
      final request = requests.single;
      expect(request.action, ChannelRunApprovalAction.requestChanges);
      expect(request.feedback, typed);
      expect(
        (request.runId, request.stepId, request.nonce, request.senderId, request.postMessageId),
        ('run-1', 'gate', 'n0nce', 'users/123', 'spaces/AAA/messages/M1'),
      );
      expect(reviewCalls, isEmpty);
    });

    test('a blank submission is passed through and the refusal answers an error status with its message', () async {
      result = const ChannelRunApprovalRefused(ChannelRunApprovalRefusal.feedbackRequired, 'Say what should change.');

      final blank = await _post(recordingHandler(), _submitDialog(feedback: '   '));
      final missing = await _post(recordingHandler(), _submitDialog(feedback: null));

      expect(blank, _errorStatus('Say what should change.'));
      expect(missing, _errorStatus('Say what should change.'));
      expect([for (final r in requests) r.feedback], ['   ', null]);
    });

    for (final reason in const [
      ChannelRunApprovalRefusal.invalid,
      ChannelRunApprovalRefusal.notPending,
      ChannelRunApprovalRefusal.limitReached,
      ChannelRunApprovalRefusal.changesNotOffered,
    ]) {
      test('a submission refused as $reason answers an error status, not a close', () async {
        result = ChannelRunApprovalRefused(reason, 'Refused: $reason');

        final body = await _post(recordingHandler(), _submitDialog());

        expect(body, _errorStatus('Refused: $reason'));
      });
    }

    test('a failed submission answers an error status so the sender can retry', () async {
      result = const ChannelRunApprovalFailed('Could not send the run back. Try again.');

      expect(await _post(recordingHandler(), _submitDialog()), _errorStatus('Could not send the run back. Try again.'));
    });

    test('a submission without the post message is refused without calling the handler', () async {
      final payload = _submitDialog()..remove('message');

      final body = await _post(recordingHandler(), payload);

      expect(requests, isEmpty);
      expect(body, _errorStatus('Invalid button action: missing run approval details.'));
    });

    test('a submit function outside a SUBMIT_DIALOG event never reaches the handler', () async {
      final body = await _post(recordingHandler(), _click(invokedFunction: 'run_request_changes_submit'));

      expect(requests, isEmpty);
      expect(body, isEmpty);
    });

    test('answers an unavailable notice inside the dialog when no handler is bound', () async {
      final open = await _post(buildHandler(), _requestDialog());
      final submit = await _post(buildHandler(), _submitDialog());

      expect(jsonEncode(_dialogBody(open)), contains('Run approvals are not available.'));
      expect(submit, _errorStatus('Run approvals are not available.'));
    });

    test('Approve and Reject are never answered with a dialog', () async {
      result = const ChannelRunApprovalPermitted();

      final approve = await _post(recordingHandler(), _click());
      result = refusal;
      final reject = await _post(recordingHandler(), _click(invokedFunction: 'run_reject'));

      expect(approve, isEmpty);
      expect(reject, {'text': 'Only admins can request changes.'});
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

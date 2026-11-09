import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show flushAsync;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'support/slack_harness.dart';

const _nonce = 'a3f09c51d27e4b86a3f09c51d27e4b86';
const _responseUrl = 'https://hooks.slack.com/actions/T1/2/click-secret';
const _postTs = '1700000000.000000';
const _feedbackBlock = 'run_request_changes_feedback';
const _feedbackInput = 'feedback';

/// A stand-in for the runtime's handler that refuses as the real one does, so the adapter is
/// proved to pass its answers through rather than decide anything itself.
class _FakeGate {
  final admins = {'U1'};
  String livePost = _postTs;
  String liveNonce = _nonce;
  final requests = <ChannelRunApprovalRequest>[];
  var changesRequested = 0;
  Future<void>? hold;

  Future<ChannelRunApprovalResult> call(ChannelRunApprovalRequest request) async {
    requests.add(request);
    await hold;
    if (!admins.contains(request.senderId)) {
      return const ChannelRunApprovalRefused(
        ChannelRunApprovalRefusal.notAdmin,
        'Only admin senders can resolve approvals',
      );
    }
    if (request.nonce != liveNonce || request.postMessageId != livePost) {
      return const ChannelRunApprovalRefused(ChannelRunApprovalRefusal.invalid, 'This approval is no longer open.');
    }
    switch (request.action) {
      case ChannelRunApprovalAction.checkRequestChanges:
        return const ChannelRunApprovalPermitted();
      case ChannelRunApprovalAction.requestChanges:
        final feedback = request.feedback;
        if (feedback == null || feedback.trim().isEmpty) {
          return const ChannelRunApprovalRefused(ChannelRunApprovalRefusal.feedbackRequired, 'Say what should change.');
        }
        changesRequested++;
        return const ChannelRunApprovalResolved();
      case ChannelRunApprovalAction.approve:
      case ChannelRunApprovalAction.reject:
        return const ChannelRunApprovalResolved();
    }
  }
}

String _approvalValue({String runId = 'run-1', String stepId = 'gate', String nonce = _nonce}) =>
    jsonEncode({runActionRunIdKey: runId, runActionStepIdKey: stepId, runActionNonceKey: nonce});

Map<String, dynamic> _submission({
  String user = 'U1',
  Object? privateMetadata,
  Object? text = 'Tighten the intro.',
  String callbackId = runRequestChangesSubmitActionId,
}) => {
  'type': 'view_submission',
  'user': {'id': user, 'name': 'Ada'},
  'view': {
    'callback_id': callbackId,
    'private_metadata':
        privateMetadata ??
        jsonEncode({
          runActionRunIdKey: 'run-1',
          runActionStepIdKey: 'gate',
          runActionNonceKey: _nonce,
          'postMessageId': _postTs,
        }),
    'state': {
      'values': {
        _feedbackBlock: {
          _feedbackInput: {'type': 'plain_text_input', 'value': ?text},
        },
      },
    },
  },
};

Map<String, Object?> _inlineError(String text) => {
  'response_action': 'errors',
  'errors': {_feedbackBlock: text},
};

void main() {
  for (final mode in const ['socket', 'events']) {
    group('request changes over $mode', () {
      late SlackHarness harness;
      late _FakeGate gate;

      setUp(() async {
        gate = _FakeGate();
        harness = await SlackHarness.start(mode: mode, runApprovalHandler: gate.call);
        harness.logs.clear();
      });

      tearDown(() => harness.close());

      Future<void> click(
        String actionId, {
        String user = 'U1',
        String? triggerId = 'trigger-1',
        String? responseUrl = _responseUrl,
      }) async {
        final interaction = blockAction(
          actionId: actionId,
          value: _approvalValue(),
          user: user,
          name: 'Ada',
          messageTs: _postTs,
          responseUrl: responseUrl,
          triggerId: triggerId,
        );
        if (mode == 'socket') {
          harness.server.sendInteractive(interaction);
          await harness.deliver(const []);
          return;
        }
        final response = await harness.post(
          utf8.encode('payload=${Uri.encodeQueryComponent(jsonEncode(interaction))}'),
          contentType: 'application/x-www-form-urlencoded',
        );
        expect(response.statusCode, 200);
        await flushAsync(10);
      }

      Future<Map<String, dynamic>?> submit(Map<String, dynamic> interaction) => _submitOn(harness, mode, interaction);

      test('an admin click opens one modal within the click, carrying run, step, nonce and post', () async {
        await click(runRequestChangesActionId);

        final opened = harness.api.openedViews.single;
        expect(opened.triggerId, 'trigger-1');
        expect(opened.view['type'], 'modal');
        expect(opened.view['callback_id'], runRequestChangesSubmitActionId);
        final metadata = opened.view['private_metadata'] as String;
        expect(metadata.length, lessThanOrEqualTo(3000), reason: 'Slack refuses a larger private_metadata');
        expect(jsonDecode(metadata), {
          runActionRunIdKey: 'run-1',
          runActionStepIdKey: 'gate',
          runActionNonceKey: _nonce,
          'postMessageId': _postTs,
        });
        final input = ((opened.view['blocks'] as List).single as Map)['element'] as Map;
        expect(((opened.view['blocks'] as List).single as Map)['block_id'], _feedbackBlock);
        expect(input['action_id'], _feedbackInput);
        expect(input['type'], 'plain_text_input');
        expect(input['multiline'], isTrue);
        expect(input['max_length'], 3000, reason: 'a modal cannot send more, so the field says so up front');
        expect(opened.view['submit'], isNotNull);

        expect(gate.requests.map((r) => r.action), [ChannelRunApprovalAction.checkRequestChanges]);
        expect(gate.requests.single.senderId, 'U1');
        expect(gate.requests.single.postMessageId, _postTs);
        expect(gate.changesRequested, 0, reason: 'opening the form resolves nothing');
        expect(harness.api.ephemerals, isEmpty);
      });

      test('a non-admin click is refused privately, no modal opens and the handler is asked once', () async {
        await click(runRequestChangesActionId, user: 'U2');

        expect(harness.api.openedViews, isEmpty, reason: 'a refused sender must never get a form to lose text in');
        expect(harness.api.calls, isNot(contains('views.open')));
        expect(gate.requests, hasLength(1));
        expect(harness.api.ephemerals.single.text, 'Only admin senders can resolve approvals');
      });

      for (final code in const ['expired_trigger_id', 'exchanged_trigger_id', 'invalid_trigger_id', 'internal_error']) {
        test('a views.open failure ($code) is answered with a pointer to the run page', () async {
          harness.api.viewError = SlackApiException('Slack API views.open failed', errorCode: code);

          await click(runRequestChangesActionId);

          expect(harness.api.openedViews, isEmpty);
          final text = harness.api.ephemerals.single.text;
          expect(text, allOf(contains('run page'), contains('workflow_request_changes')));
          expect(text, isNot(contains('http')), reason: 'no URL is known here, so none is invented');
          expect(gate.changesRequested, 0);
        });
      }

      test('a click that carries no trigger id is answered the same way and opens nothing', () async {
        await click(runRequestChangesActionId, triggerId: null);

        expect(harness.api.openedViews, isEmpty);
        expect(harness.api.ephemerals.single.text, contains('run page'));
      });

      test('Approve and Reject behave as before, and open no modal', () async {
        await click(runApproveActionId);
        await click(runRejectActionId);

        expect(gate.requests.map((r) => r.action), [ChannelRunApprovalAction.approve, ChannelRunApprovalAction.reject]);
        expect(harness.api.openedViews, isEmpty);
        expect(harness.api.ephemerals, isEmpty);
      });

      test('the form submission action ID arriving as a click is ignored', () async {
        await click(runRequestChangesSubmitActionId);

        expect(gate.requests, isEmpty);
        expect(harness.api.openedViews, isEmpty);
        expect(harness.api.ephemerals, isEmpty);
      });

      test(
        'an admin submission resolves, the handler gets the text as typed and the clear body closes the modal',
        () async {
          const typed = '  Tighten the intro.\n\nKeep the table.  ';

          final body = await submit(_submission(text: typed));

          expect(body, {'response_action': 'clear'});
          final request = gate.requests.single;
          expect(request.action, ChannelRunApprovalAction.requestChanges);
          expect((request.runId, request.stepId, request.nonce), ('run-1', 'gate', _nonce));
          expect((request.senderId, request.senderDisplayName, request.postMessageId), ('U1', 'Ada', _postTs));
          expect(request.feedback, typed, reason: 'the host never trims or rewrites what the admin wrote');
          expect(gate.changesRequested, 1);
        },
      );

      test('a blank submission answers an inline error on the feedback field and changes nothing', () async {
        final body = await submit(_submission(text: '  \n '));

        expect(body, _inlineError('Say what should change.'));
        expect(gate.requests.single.feedback, '  \n ');
        expect(gate.changesRequested, 0);
        expect(harness.api.ephemerals, isEmpty);
      });

      test('a submission without any value reaches the handler as no feedback and is refused inline', () async {
        final body = await submit(_submission(text: null));

        expect(gate.requests.single.feedback, isNull);
        expect(body, _inlineError('Say what should change.'));
      });

      test('a submission from a superseded post answers an inline error and changes nothing', () async {
        gate.liveNonce = 'b' * 32;

        final body = await submit(_submission());

        expect(body, _inlineError('This approval is no longer open.'));
        expect(gate.changesRequested, 0);
      });

      test('a submission from a sender who is not an admin answers the refusal inline', () async {
        final body = await submit(_submission(user: 'U2'));

        expect(body, _inlineError('Only admin senders can resolve approvals'));
        expect(gate.changesRequested, 0);
      });

      test('a failed resolution is shown inline so the typed text is kept', () async {
        final failing = await SlackHarness.start(
          mode: mode,
          runApprovalHandler: (_) async => const ChannelRunApprovalFailed('Could not resume the run. Try again.'),
        );
        addTearDown(failing.close);
        final body = await _submitOn(failing, mode, _submission());

        expect(body, _inlineError('Could not resume the run. Try again.'));
      });

      test('a handler that throws answers an inline error and logs neither the nonce nor the text', () async {
        final throwing = await SlackHarness.start(
          mode: mode,
          runApprovalHandler: (request) async => throw StateError('lost ${request.nonce} ${request.feedback}'),
        );
        addTearDown(throwing.close);
        throwing.logs.clear();

        final body = await _submitOn(throwing, mode, _submission(text: 'secret-feedback'));

        expect(body, _inlineError('The approval could not be resolved. Try again.'));
        final logged = [for (final r in throwing.logs) '${r.message} ${r.error} ${r.stackTrace}'].join('\n');
        expect(logged, isNot(contains(_nonce)));
        expect(logged, isNot(contains('secret-feedback')));
        expect(throwing.logs.where((r) => r.level >= Level.WARNING), hasLength(1));
      });

      test('a submission with unusable metadata is refused inline without reaching the handler', () async {
        for (final metadata in [
          '',
          'not json',
          jsonEncode({runActionRunIdKey: 'run-1'}),
        ]) {
          final body = await submit(_submission(privateMetadata: metadata));

          expect(body, _inlineError('This form is not valid.'));
        }
        expect(gate.requests, isEmpty);
      });

      test('a submission of another modal is acknowledged empty and ignored', () async {
        final body = await submit(_submission(callbackId: 'something_else'));

        expect(body, isNull);
        expect(gate.requests, isEmpty);
      });

      test('a block action is still acknowledged first and empty, before its handler is done', () async {
        final release = Completer<void>();
        gate.hold = release.future;
        final interaction = blockAction(
          actionId: runApproveActionId,
          value: _approvalValue(),
          user: 'U1',
          messageTs: _postTs,
          responseUrl: _responseUrl,
        );

        if (mode == 'socket') {
          final id = harness.server.sendInteractive(interaction);
          await harness.until(() => harness.server.acknowledgements.contains(id));
          final frame = harness.server.acknowledgementFrames.firstWhere((f) => f['envelope_id'] == id);
          expect(frame.containsKey('payload'), isFalse);
        } else {
          final response = await harness.post(
            utf8.encode('payload=${Uri.encodeQueryComponent(jsonEncode(interaction))}'),
            contentType: 'application/x-www-form-urlencoded',
          );
          expect((response.statusCode, response.body), (200, ''));
        }

        expect(gate.requests, hasLength(1), reason: 'the handler runs on, unfinished');
        release.complete();
      });
    });
  }

  group('an acknowledgement body that takes too long', () {
    for (final mode in const ['socket', 'events']) {
      test('goes out empty over $mode at Slack\'s deadline while the handler finishes', () async {
        final deadline = Completer<void>();
        final handlerRelease = Completer<void>();
        var handlerFinished = false;
        final requestedDelays = <Duration>[];
        final dispatch =
            SlackEnvelopeDispatch(
              delay: (duration) {
                requestedDelays.add(duration);
                return deadline.future;
              },
            )..registerAnswering(SlackEnvelopeKind.viewSubmission, (_) async {
              await handlerRelease.future;
              handlerFinished = true;
              return _inlineError('too late');
            });
        final submission = _submission();

        if (mode == 'socket') {
          final server = FakeSocketModeServer();
          await server.start();
          addTearDown(server.stop);
          final client = SocketModeClient(openUrl: () async => server.url, dispatch: dispatch)..start();
          addTearDown(client.stop);
          await server.waitForConnections(1);
          final id = server.sendInteractive(submission);
          await flushAsync(10);
          expect(server.acknowledgements, isEmpty, reason: 'the acknowledgement waits for the handler');

          deadline.complete();
          await server.waitForAcknowledgements(1);
          expect(server.acknowledgementFrames.single, {'envelope_id': id});
        } else {
          final events = SlackEventsHandler(signingSecret: 'secret', dispatch: dispatch);
          final body = Uint8List.fromList(utf8.encode('payload=${Uri.encodeQueryComponent(jsonEncode(submission))}'));
          final pending = events.handle(
            body,
            signedSlackHeaders('secret', body, contentType: 'application/x-www-form-urlencoded'),
          );
          await flushAsync(10);

          deadline.complete();
          final response = await pending;
          expect((response.statusCode, response.body), (200, ''));
        }

        expect(requestedDelays, [slackAnswerDeadline]);
        expect(slackAnswerDeadline, lessThan(const Duration(seconds: 3)));
        expect(handlerFinished, isFalse, reason: 'the handler is not cancelled by the deadline');
        handlerRelease.complete();
        await flushAsync(10);
        expect(handlerFinished, isTrue);
      });
    }
  });

  group('the Request changes button', () {
    test(
      'is the third button, with the same run, step and nonce as the other two, only when the post carries it',
      () async {
        final harness = await SlackHarness.start(runApprovalHandler: _FakeGate().call);
        addTearDown(harness.close);

        List<Map<String, dynamic>> buttons(List<ChannelNotificationAction> actions) {
          final response = harness.channel.threadedNotifications!.render(
            ChannelNotification(
              kind: ChannelNotificationKind.run,
              id: 'run-1',
              text: 'Run run-1 awaits approval.',
              title: 'release',
              status: 'awaiting approval',
              actions: actions,
              actionData: {runActionRunIdKey: 'run-1', runActionStepIdKey: 'gate', runActionNonceKey: _nonce},
            ),
          );
          final blocks = (response.structuredPayload!['blocks'] as List).cast<Map<String, dynamic>>();
          return (blocks.last['elements'] as List).cast<Map<String, dynamic>>();
        }

        final withChanges = buttons(const [
          ChannelNotificationAction(id: runApproveActionId, label: 'Approve'),
          ChannelNotificationAction(id: runRejectActionId, label: 'Reject'),
          ChannelNotificationAction(id: runRequestChangesActionId, label: 'Request changes'),
        ]);
        final withoutChanges = buttons(const [
          ChannelNotificationAction(id: runApproveActionId, label: 'Approve'),
          ChannelNotificationAction(id: runRejectActionId, label: 'Reject'),
        ]);

        expect(withChanges.map((b) => b['action_id']), [
          runApproveActionId,
          runRejectActionId,
          runRequestChangesActionId,
        ]);
        expect((withChanges.last['text'] as Map)['text'], 'Request changes');
        expect(withChanges.map((b) => b['value']).toSet(), hasLength(1), reason: 'every button carries the same data');
        expect(jsonDecode(withChanges.last['value'] as String), {
          runActionRunIdKey: 'run-1',
          runActionStepIdKey: 'gate',
          runActionNonceKey: _nonce,
        });
        expect(withoutChanges.map((b) => b['action_id']), [runApproveActionId, runRejectActionId]);
      },
    );
  });
}

Future<Map<String, dynamic>?> _submitOn(SlackHarness harness, String mode, Map<String, dynamic> interaction) async {
  if (mode == 'socket') {
    final id = harness.server.sendInteractive(interaction);
    await harness.until(() => harness.server.acknowledgements.contains(id));
    final frame = harness.server.acknowledgementFrames.firstWhere((f) => f['envelope_id'] == id);
    return (frame['payload'] as Map?)?.cast<String, dynamic>();
  }
  final response = await harness.post(
    utf8.encode('payload=${Uri.encodeQueryComponent(jsonEncode(interaction))}'),
    contentType: 'application/x-www-form-urlencoded',
  );
  expect(response.statusCode, 200);
  if (response.body.isEmpty) return null;
  expect(response.contentType, 'application/json');
  return jsonDecode(response.body) as Map<String, dynamic>;
}

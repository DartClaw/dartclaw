import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show flushAsync;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'support/slack_harness.dart';

const _nonce = 'a3f09c51d27e4b86a3f09c51d27e4b86';
const _responseUrl = 'https://hooks.slack.com/actions/T1/2/click-secret';
const _postTs = '1700000000.000000';

void main() {
  for (final mode in const ['socket', 'events']) {
    group('a run approval click arriving over $mode', () {
      late SlackHarness harness;
      late List<ChannelRunApprovalRequest> requests;
      late Future<ChannelRunApprovalResult> Function(ChannelRunApprovalRequest request) answer;

      setUp(() async {
        requests = [];
        answer = (_) async => const ChannelRunApprovalResolved();
        harness = await SlackHarness.start(
          mode: mode,
          runApprovalHandler: (request) {
            requests.add(request);
            return answer(request);
          },
        );
        harness.logs.clear();
      });

      tearDown(() => harness.close());

      Future<void> deliver(Map<String, dynamic> interaction) async {
        if (mode == 'socket') {
          harness.server.sendInteractive(interaction);
          await harness.deliver(const []);
          return;
        }
        final body = 'payload=${Uri.encodeQueryComponent(jsonEncode(interaction))}';
        final response = await harness.post(utf8.encode(body), contentType: 'application/x-www-form-urlencoded');
        expect(response.statusCode, 200, reason: 'Slack is acknowledged whatever the click comes to');
        await flushAsync(10);
      }

      Future<void> clickOn(
        String actionId, {
        Object? value,
        String user = 'U1',
        String? name = 'Ada',
        String? messageTs = _postTs,
        String? responseUrl = _responseUrl,
      }) => deliver(
        blockAction(
          actionId: actionId,
          value: value,
          user: user,
          name: name,
          messageTs: messageTs,
          responseUrl: responseUrl,
        ),
      );

      /// The value the adapter itself rendered on a live approval post.
      String renderedValue({String runId = 'run-1', String stepId = 'gate', String nonce = _nonce}) =>
          renderedButtons(harness, runId: runId, stepId: stepId, nonce: nonce).first['value'] as String;

      test('an admin click reaches the handler once as the decoded request and changes nothing else', () async {
        await clickOn(runApproveActionId, value: renderedValue());

        final request = requests.single;
        expect(request.action, ChannelRunApprovalAction.approve);
        expect((request.runId, request.stepId, request.nonce), ('run-1', 'gate', _nonce));
        expect((request.senderId, request.senderDisplayName), ('U1', 'Ada'));
        expect(request.channelType, 'slack');
        expect(
          request.postMessageId,
          _postTs,
          reason: 'the same string ThreadedPost.messageId carries, so the runtime finds the post it sent',
        );
        expect(harness.api.ephemerals, isEmpty, reason: 'a resolution is acknowledged only');
        expect(harness.api.updates, isEmpty, reason: 'the runtime edits the post, never the adapter');
        expect(harness.api.posts, isEmpty);
        expect(harness.turns, isEmpty);
      });

      test('Reject is read as the reject action', () async {
        await clickOn(runRejectActionId, value: renderedValue());

        expect(requests.single.action, ChannelRunApprovalAction.reject);
      });

      test('a click without a display name still reaches the handler, with the sender ID', () async {
        await clickOn(runApproveActionId, value: renderedValue(), name: null);

        expect(requests.single.senderId, 'U1');
        expect(requests.single.senderDisplayName, isNull);
      });

      test(
        'a refusal is answered privately to the clicker and nothing else changes; a second click is told again',
        () async {
          answer = (_) async => const ChannelRunApprovalRefused(
            ChannelRunApprovalRefusal.alreadyResolved,
            'This approval was already resolved.',
          );

          await clickOn(runApproveActionId, value: renderedValue());
          await clickOn(runApproveActionId, value: renderedValue());

          expect(requests, hasLength(2));
          expect(harness.api.ephemerals.map((e) => (e.url, e.text)), [
            (Uri.parse(_responseUrl), 'This approval was already resolved.'),
            (Uri.parse(_responseUrl), 'This approval was already resolved.'),
          ]);
          expect(harness.api.updates, isEmpty);
          expect(harness.api.posts, isEmpty);
        },
      );

      test('a non-admin refusal text is passed through unchanged and names the clicker to the runtime', () async {
        answer = (_) async => const ChannelRunApprovalRefused(
          ChannelRunApprovalRefusal.notAdmin,
          'Only admin senders can resolve approvals',
        );

        await clickOn(runApproveActionId, value: renderedValue(), user: 'U2');

        expect(requests.single.senderId, 'U2');
        expect(harness.api.ephemerals.single.text, 'Only admin senders can resolve approvals');
        expect(harness.api.updates, isEmpty);
      });

      test('a failed resolution is answered privately, leaves the post alone and the next click resolves', () async {
        var attempts = 0;
        answer = (_) async => ++attempts == 1
            ? const ChannelRunApprovalFailed('Could not resume the run. Try again.')
            : const ChannelRunApprovalResolved();
        final value = renderedValue();

        await clickOn(runApproveActionId, value: value);

        expect(harness.api.ephemerals.single.text, 'Could not resume the run. Try again.');
        expect(harness.api.updates, isEmpty, reason: 'the post and its buttons stay as they are');

        await clickOn(runApproveActionId, value: value);

        expect(requests, hasLength(2));
        expect(requests.last.nonce, _nonce, reason: 'the same nonce is offered again; the adapter keeps no state');
        expect(harness.api.ephemerals, hasLength(1), reason: 'the second click resolved, so it is acknowledged only');
      });

      test('a handler that throws is answered generically and its error text is not logged', () async {
        answer = (request) async => throw StateError('lost ${request.nonce}');

        await clickOn(runApproveActionId, value: renderedValue());

        expect(harness.api.ephemerals.single.text, 'The approval could not be resolved. Try again.');
        expect(harness.logs.where((r) => r.level >= Level.WARNING), hasLength(1));
        expect(_everythingLogged(harness), isNot(contains(_nonce)));
      });

      test(
        'a click with a value that is missing, not JSON or lacks run, step or nonce is refused without the handler',
        () async {
          final cases = <Object?>[
            null,
            'not json',
            '[]',
            jsonEncode({'runId': 'run-1', 'stepId': 'gate'}),
            jsonEncode({'runId': 'run-1', 'nonce': _nonce}),
            jsonEncode({'stepId': 'gate', 'nonce': _nonce}),
            jsonEncode({'runId': 'run-1', 'stepId': 'gate', 'nonce': ''}),
            jsonEncode({'runId': 'run-1', 'stepId': 'gate', 'nonce': 7}),
          ];

          for (final value in cases) {
            await clickOn(runApproveActionId, value: value);
          }

          expect(requests, isEmpty);
          expect(harness.api.ephemerals, hasLength(cases.length));
          expect(harness.api.ephemerals.map((e) => e.text), everyElement('This approval button is not valid.'));
          expect(harness.api.updates, isEmpty);
        },
      );

      test('a click that names no message is refused without the handler', () async {
        await clickOn(runApproveActionId, value: renderedValue(), messageTs: null);

        expect(requests, isEmpty);
        expect(harness.api.ephemerals.single.text, 'This approval button is not valid.');
      });

      test('what the click carries reaches the handler untouched, so the runtime can refuse a forged one', () async {
        await clickOn(
          runApproveActionId,
          value: renderedValue(runId: 'run-2', stepId: 'other', nonce: 'forged'),
        );
        await clickOn(runApproveActionId, value: renderedValue(), messageTs: '1700000099.000000');

        expect(requests.map((r) => (r.runId, r.stepId, r.nonce, r.postMessageId)), [
          ('run-2', 'other', 'forged', _postTs),
          ('run-1', 'gate', _nonce, '1700000099.000000'),
        ]);
      });

      test('a click with no handler bound is answered as unavailable', () async {
        await harness.close();
        harness = await SlackHarness.start(mode: mode);
        harness.logs.clear();

        await clickOn(runApproveActionId, value: renderedValue());

        expect(harness.api.ephemerals.single.text, 'Run approvals are unavailable.');
        expect(requests, isEmpty);
      });

      test('an answer Slack refuses is logged without the response URL and does not fail the click', () async {
        answer = (_) async => const ChannelRunApprovalFailed('try again');
        harness.api.ephemeralError = const SlackApiException('response URL expired');

        await clickOn(runApproveActionId, value: renderedValue());

        expect(harness.api.ephemerals, isEmpty);
        expect(harness.logs.where((r) => r.level >= Level.WARNING), hasLength(1));
        expect(_everythingLogged(harness), isNot(contains('click-secret')));
      });

      test('a click with no usable response URL still reaches the handler and fails quietly', () async {
        answer = (_) async => const ChannelRunApprovalFailed('try again');

        await clickOn(runApproveActionId, value: renderedValue(), responseUrl: null);

        expect(requests, hasLength(1));
        expect(harness.api.ephemerals, isEmpty);
        expect(harness.logs.where((r) => r.level >= Level.WARNING), isEmpty);
      });

      test('no log line holds the nonce, the button value or the response URL, whatever the click came to', () async {
        final results = <ChannelRunApprovalResult Function()>[
          () => const ChannelRunApprovalResolved(),
          () => const ChannelRunApprovalRefused(ChannelRunApprovalRefusal.invalid, 'invalid'),
          () => const ChannelRunApprovalFailed('failed'),
          () => throw StateError('boom'),
        ];
        final value = renderedValue();
        for (final result in results) {
          answer = (_) async => result();
          await clickOn(runApproveActionId, value: value);
        }
        await clickOn(runApproveActionId, value: 'not json $_nonce');

        final logged = _everythingLogged(harness);
        for (final secret in [_nonce, value, 'click-secret']) {
          expect(logged, isNot(contains(secret)));
        }
      });

      group('interactions that are not a run action', () {
        void expectIgnored() {
          expect(requests, isEmpty);
          expect(harness.api.ephemerals, isEmpty);
          expect(harness.api.updates, isEmpty);
          expect(harness.api.posts, isEmpty);
          expect(harness.turns, isEmpty);
          expect(harness.logs.where((r) => r.level >= Level.INFO), isEmpty, reason: 'debug only');
          expect(harness.logs.where((r) => r.level == Level.FINE), isNotEmpty);
        }

        test('an unknown action ID is acknowledged and ignored', () async {
          await clickOn('task_accept', value: renderedValue());

          expectIgnored();
        });

        test('a click on a message that is not an approval post is acknowledged and ignored', () async {
          await clickOn('overflow_menu');
          await deliver({
            'type': 'block_actions',
            'user': {'id': 'U1'},
            'response_url': _responseUrl,
            'container': {'type': 'message', 'message_ts': '1.1', 'channel_id': 'C1'},
            'actions': <Object?>[],
          });

          expectIgnored();
        });

        test('a view submission is acknowledged and ignored', () async {
          await deliver({
            'type': 'view_submission',
            'user': {'id': 'U1'},
            'view': {
              'callback_id': 'run_approve',
              'private_metadata': jsonEncode({'runId': 'run-1', 'stepId': 'gate', 'nonce': _nonce}),
            },
          });

          expectIgnored();
        });
      });
    });
  }
}

String _everythingLogged(SlackHarness harness) => [
  for (final record in harness.logs) ...[record.message, '${record.error}', '${record.stackTrace}'],
].join('\n');

/// The buttons the adapter renders for an awaiting-approval post, as Slack would hand them back.
List<Map<String, dynamic>> renderedButtons(
  SlackHarness harness, {
  required String runId,
  required String stepId,
  required String nonce,
}) {
  final response = harness.channel.threadedNotifications!.render(
    ChannelNotification(
      kind: ChannelNotificationKind.run,
      id: runId,
      text: 'Run $runId awaits approval.',
      title: 'release',
      status: 'awaiting approval',
      actions: const [
        ChannelNotificationAction(id: runApproveActionId, label: 'Approve'),
        ChannelNotificationAction(id: runRejectActionId, label: 'Reject'),
      ],
      actionData: {runActionRunIdKey: runId, runActionStepIdKey: stepId, runActionNonceKey: nonce},
    ),
  );
  final blocks = (response.structuredPayload!['blocks'] as List).cast<Map<String, dynamic>>();
  return (blocks.last['elements'] as List).cast<Map<String, dynamic>>();
}

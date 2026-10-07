import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show ChannelRunApprovalResolved, runApproveActionId;
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'support/slack_harness.dart';

void main() {
  const event = SlackEnvelope(kind: SlackEnvelopeKind.event, payload: {'event': {}});

  test('an envelope reaches the handler registered for its kind, with no socket involved', () async {
    final dispatch = SlackEnvelopeDispatch();
    final received = <SlackEnvelope>[];
    dispatch
      ..register(SlackEnvelopeKind.event, received.add)
      ..register(SlackEnvelopeKind.slashCommand, (_) => fail('wrong kind'));

    await dispatch.dispatch(event);

    expect(received.single, same(event));
  });

  test('every interaction kind has its own slot so later features register beside the event handler', () async {
    final dispatch = SlackEnvelopeDispatch();
    final seen = <SlackEnvelopeKind>[];
    for (final kind in SlackEnvelopeKind.values) {
      dispatch.register(kind, (envelope) => seen.add(envelope.kind));
    }

    for (final kind in SlackEnvelopeKind.values) {
      await dispatch.dispatch(SlackEnvelope(kind: kind, payload: const {}));
    }

    expect(seen, SlackEnvelopeKind.values);
  });

  test('an envelope without a handler is dropped quietly', () async {
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    Logger.root.level = Level.ALL;

    await SlackEnvelopeDispatch().dispatch(const SlackEnvelope(kind: SlackEnvelopeKind.blockAction, payload: {}));

    expect(records.where((r) => r.level >= Level.WARNING), isEmpty);
    expect(records.any((r) => r.level == Level.FINE && r.message.contains('blockAction')), isTrue);
  });

  test('a failing handler is logged and never escapes, so one bad envelope cannot stop the next', () async {
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    Logger.root.level = Level.ALL;
    final dispatch = SlackEnvelopeDispatch();
    var calls = 0;
    dispatch.register(SlackEnvelopeKind.event, (_) {
      calls++;
      if (calls == 1) throw StateError('boom');
    });

    await dispatch.dispatch(event);
    await dispatch.dispatch(event);

    expect(calls, 2);
    expect(records.where((r) => r.level == Level.WARNING), hasLength(1));
  });

  group('on a Slack channel', () {
    late SlackHarness harness;
    final clicks = <String>[];

    setUp(() async {
      clicks.clear();
      harness = await SlackHarness.start(
        runApprovalHandler: (request) async {
          clicks.add(request.runId);
          return const ChannelRunApprovalResolved();
        },
      );
      harness.logs.clear();
    });

    tearDown(() => harness.close());

    test('a block action reaches the run approval handler and a view submission reaches none', () async {
      await harness.channel.dispatch.dispatch(
        SlackEnvelope(
          kind: SlackEnvelopeKind.blockAction,
          payload: blockAction(
            actionId: runApproveActionId,
            user: 'U1',
            messageTs: '1.1',
            value: jsonEncode({'runId': 'run-1', 'stepId': 'gate', 'nonce': 'n'}),
          ),
        ),
      );
      await harness.channel.dispatch.dispatch(
        const SlackEnvelope(kind: SlackEnvelopeKind.viewSubmission, payload: {'type': 'view_submission'}),
      );

      expect(clicks, ['run-1']);
      expect(harness.logs.where((r) => r.level >= Level.INFO), isEmpty);
      expect(harness.logs.any((r) => r.level == Level.FINE && r.message.contains('viewSubmission')), isTrue);
    });
  });
}

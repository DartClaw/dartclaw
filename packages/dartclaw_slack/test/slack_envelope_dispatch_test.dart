import 'dart:async';
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

  group('a kind that answers with a body', () {
    const submission = SlackEnvelope(kind: SlackEnvelopeKind.viewSubmission, payload: {});

    test('is answered only for the kinds registered as answering, so every other kind is acknowledged first', () {
      final dispatch = SlackEnvelopeDispatch()
        ..register(SlackEnvelopeKind.viewSubmission, (_) {})
        ..registerAnswering(SlackEnvelopeKind.blockAction, (_) => null);

      expect(dispatch.answers(SlackEnvelopeKind.blockAction), isTrue);
      expect(SlackEnvelopeKind.values.where(dispatch.answers), [
        SlackEnvelopeKind.blockAction,
      ], reason: 'a plain handler for the same kind does not change when its acknowledgement goes out');
    });

    test('returns the body its handler produced', () async {
      final dispatch = SlackEnvelopeDispatch()
        ..registerAnswering(SlackEnvelopeKind.viewSubmission, (_) async => {'response_action': 'clear'});

      expect(await dispatch.dispatchAnswering(submission), {'response_action': 'clear'});
    });

    test('returns an empty acknowledgement when the handler fails, and logs the failure', () async {
      final records = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(subscription.cancel);
      Logger.root.level = Level.ALL;
      final dispatch = SlackEnvelopeDispatch()
        ..registerAnswering(SlackEnvelopeKind.viewSubmission, (_) => throw StateError('boom'));

      expect(await dispatch.dispatchAnswering(submission), isNull);
      expect(records.where((r) => r.level == Level.WARNING), hasLength(1));
    });

    test('returns an empty acknowledgement at the deadline and lets the handler finish', () async {
      final deadline = Completer<void>();
      final release = Completer<Map<String, Object?>?>();
      Duration? waited;
      final dispatch = SlackEnvelopeDispatch(
        delay: (duration) {
          waited = duration;
          return deadline.future;
        },
      )..registerAnswering(SlackEnvelopeKind.viewSubmission, (_) => release.future);

      final answer = dispatch.dispatchAnswering(submission);
      deadline.complete();

      expect(await answer, isNull);
      expect(waited, slackAnswerDeadline, reason: 'Slack gives a view submission three seconds');
      expect(release.isCompleted, isFalse);
    });
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

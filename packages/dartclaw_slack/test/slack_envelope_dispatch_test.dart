import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

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
}

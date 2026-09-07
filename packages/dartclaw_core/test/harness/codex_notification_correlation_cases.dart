part of 'codex_harness_test.dart';

void registerCodexNotificationCorrelationTests() {
  test('ignores a child thread completion while the parent turn remains active', () async {
    final (:harness, :fake) = await _startedHarness();
    final events = _collectEvents(harness);

    final turnFuture = harness.turn(
      sessionId: 'sess-parent',
      messages: const [
        {'role': 'user', 'content': 'review this change'},
      ],
      systemPrompt: 'test',
    );
    var settled = false;
    unawaited(turnFuture.then((_) => settled = true));

    await respondToLatestThreadStart(fake, threadId: 'thread-parent');
    fake.emitLine({
      'method': 'turn/started',
      'params': {
        'threadId': 'thread-parent',
        'turn': {'id': 'turn-parent'},
      },
    });
    fake.emitLine({
      'method': 'item/completed',
      'params': {
        'threadId': 'thread-child',
        'turnId': 'turn-child',
        'item': {'type': 'agentMessage', 'id': 'message-child', 'text': 'child review report', 'phase': 'final_answer'},
      },
    });
    fake.emitLine({
      'method': 'turn/completed',
      'params': {
        'threadId': 'thread-child',
        'turn': {
          'id': 'turn-child',
          'status': 'completed',
          'items': [
            {'type': 'agentMessage', 'id': 'message-child', 'text': 'child review report', 'phase': 'final_answer'},
          ],
        },
      },
    });
    fake.emitLine({
      'method': 'turn/completed',
      'params': {
        'threadId': 'thread-parent',
        'turn': {
          'id': 'turn-earlier',
          'status': 'completed',
          'items': [
            {'type': 'agentMessage', 'id': 'message-earlier', 'text': 'earlier result', 'phase': 'final_answer'},
          ],
        },
      },
    });
    await pumpEventLoop();

    expect(settled, isFalse, reason: 'a child thread must not settle the active parent turn');
    expect(
      events.whereType<DeltaEvent>().map((event) => event.text),
      isNot(anyOf(contains('child review report'), contains('earlier result'))),
    );

    fake.emitLine({
      'method': 'item/agentMessage/delta',
      'params': {
        'threadId': 'thread-parent',
        'turnId': 'turn-parent',
        'itemId': 'message-parent',
        'delta': 'parent result',
      },
    });
    fake.emitLine({
      'method': 'turn/completed',
      'params': {
        'threadId': 'thread-parent',
        'turn': {
          'id': 'turn-parent',
          'status': 'completed',
          'items': [
            {'type': 'agentMessage', 'id': 'message-parent', 'text': 'parent result', 'phase': 'final_answer'},
          ],
        },
        'usage': {'input_tokens': 10, 'output_tokens': 2},
      },
    });

    final result = await turnFuture;
    expect(result.finalText, 'parent result');
    expect(events.whereType<DeltaEvent>().map((event) => event.text), contains('parent result'));
  });
}

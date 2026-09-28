part of 'codex_harness_test.dart';

void registerCodexNotificationCorrelationTests() {
  test('usage a spawned child thread reports during the turn is credited to it, its completion is not', () async {
    final (:harness, :fake) = await _startedHarness();

    Map<String, dynamic> usage(
      String threadId,
      String turnId, {
      required int input,
      required int cached,
      required int output,
    }) => {
      'method': 'thread/tokenUsage/updated',
      'params': {
        'threadId': threadId,
        'turnId': turnId,
        'tokenUsage': {
          'total': {
            'inputTokens': input,
            'cachedInputTokens': cached,
            'cacheWriteInputTokens': 0,
            'outputTokens': output,
          },
          'last': {'inputTokens': 1, 'cachedInputTokens': 0, 'cacheWriteInputTokens': 0, 'outputTokens': 1},
        },
      },
    };
    Map<String, dynamic> completed(String threadId, String turnId) => {
      'method': 'turn/completed',
      'params': {
        'threadId': threadId,
        'turn': {'id': turnId, 'status': 'completed', 'items': <Object>[]},
      },
    };

    final firstTurn = harness.turn(
      sessionId: 'sess-parent',
      messages: const [
        {'role': 'user', 'content': 'research this'},
      ],
      systemPrompt: 'test',
    );
    var settled = false;
    unawaited(firstTurn.then((_) => settled = true));
    await respondToLatestThreadStart(fake, threadId: 'thread-parent');
    fake.emitLine({
      'method': 'turn/started',
      'params': {
        'threadId': 'thread-parent',
        'turn': {'id': 'turn-parent'},
      },
    });
    fake.emitLine(usage('thread-parent', 'turn-parent', input: 1000, cached: 600, output: 10));
    fake.emitLine(usage('thread-child', 'turn-child', input: 500, cached: 200, output: 40));
    fake.emitLine(completed('thread-child', 'turn-child'));
    await pumpEventLoop();
    expect(settled, isFalse, reason: 'a child thread must not settle the active parent turn');

    fake.emitLine(usage('thread-parent', 'turn-parent', input: 3000, cached: 2400, output: 25));
    fake.emitLine(completed('thread-parent', 'turn-parent'));
    final first = await firstTurn;

    // Parent 3000/2400/25 cumulative plus child 500/200/40; fresh input is total minus cached.
    expect(first.inputTokens, (3000 - 2400) + (500 - 200));
    expect(first.cacheReadTokens, 2400 + 200);
    expect(first.outputTokens, 25 + 40);

    final secondTurn = harness.turn(
      sessionId: 'sess-parent',
      messages: const [
        {'role': 'user', 'content': 'and then'},
      ],
      systemPrompt: 'test',
    );
    await pumpEventLoop();
    fake.emitLine({
      'method': 'turn/started',
      'params': {
        'threadId': 'thread-parent',
        'turn': {'id': 'turn-parent-2'},
      },
    });
    fake.emitLine(usage('thread-parent', 'turn-parent-2', input: 3700, cached: 3000, output: 30));
    fake.emitLine(completed('thread-parent', 'turn-parent-2'));
    final second = await secondTurn;

    expect(second.inputTokens, (3700 - 3000) - (3000 - 2400), reason: 'only the growth since the first turn');
    expect(second.cacheReadTokens, 3000 - 2400);
    expect(second.outputTokens, 5);
  });

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
